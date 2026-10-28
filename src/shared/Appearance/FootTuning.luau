--!strict
-- FootTuning (C4a characters): the on-foot GTA feel as numbers and pure functions, shared by the client controllers
-- (FootCamera, FootMovement, NameTags), the server's fall damage (FootService) and the tests. No Instances, no
-- services.
--
-- Scale: 1 stud ~ 0.28 m (gta_realism_gap §1). Gravity stays 196.2 studs/s^2 (vehicle tuning depends on it), so the
-- fall thresholds are expressed as drop heights and converted with the live gravity.

local FootTuning = {}

-------------------------------------------------------------------------------------------------------------------------
-- Movement
-------------------------------------------------------------------------------------------------------------------------

FootTuning.WALK = 10 -- hold Left Alt (or a light thumbstick tilt)
FootTuning.JOG = 16 -- default
FootTuning.SPRINT = 24 -- hold Shift / L3 / the touch SPRINT button, costs stamina
FootTuning.AIM_WALK = 9 -- aiming a gun: GTA slows you to a walk
FootTuning.JUMP_HEIGHT = 4.5 -- studs (~1.3 m): a heavy, short hop, not the floaty Roblox jump
FootTuning.JUMP_COOLDOWN = 0.45 -- seconds after landing before the next jump (no bunny hopping)

-- Stamina 0..1 (the HUD's third bar reads the local "Stamina" attribute)
FootTuning.STAMINA_DRAIN = 1 / 9 -- per second of sprinting: 9 s from full
FootTuning.STAMINA_REGEN = 1 / 6 -- per second once recovering: 6 s to refill
FootTuning.STAMINA_REGEN_DELAY = 1.0 -- seconds after the last sprint before it refills
FootTuning.STAMINA_RECOVER = 0.3 -- after running dry, sprint again only above this

export type MoveMode = "walk" | "jog" | "sprint"

-- WalkSpeed for a movement mode (aiming always walks).
function FootTuning.speedFor(mode: MoveMode, aiming: boolean?): number
	if aiming then
		return FootTuning.AIM_WALK
	end
	if mode == "walk" then
		return FootTuning.WALK
	elseif mode == "sprint" then
		return FootTuning.SPRINT
	end
	return FootTuning.JOG
end

-- The mode this frame: sprint needs the sprint input, stamina (not exhausted), movement and not aiming.
function FootTuning.modeFor(
	sprintHeld: boolean,
	walkHeld: boolean,
	moving: boolean,
	aiming: boolean,
	exhausted: boolean
): MoveMode
	if sprintHeld and moving and not aiming and not exhausted then
		return "sprint"
	end
	if walkHeld then
		return "walk"
	end
	return "jog"
end

-- Arbitration with the other client writers of Humanoid.WalkSpeed / JumpHeight (CombatClient's stun freeze writes 0
-- and restores what it saved; WeaponWheel halves the speed while open): FootMovement writes only while the humanoid
-- still holds the value it wrote last, or one of its own values / the spawn default (someone restored ours). Any other
-- value is another system's temporary override and is left alone until they put ours back.
function FootTuning.mayWrite(current: number, lastWritten: number?, ours: { number }): boolean
	if lastWritten == nil then
		return true
	end
	if math.abs(current - lastWritten) < 0.01 then
		return true
	end
	for _, v in ours do
		if math.abs(current - v) < 0.01 then
			return true
		end
	end
	return false
end

-- The speeds FootMovement itself writes (and the StarterPlayer spawn default, = JOG).
function FootTuning.ownSpeeds(): { number }
	return { FootTuning.WALK, FootTuning.JOG, FootTuning.SPRINT, FootTuning.AIM_WALK }
end

-- JumpHeight now: 0 during the landing cooldown, else JUMP_HEIGHT.
function FootTuning.jumpHeightFor(sinceLanded: number): number
	return if sinceLanded < FootTuning.JUMP_COOLDOWN then 0 else FootTuning.JUMP_HEIGHT
end

-- One stamina step. Returns (stamina, exhausted, sinceSprint).
function FootTuning.stepStamina(
	stamina: number,
	sprinting: boolean,
	exhausted: boolean,
	sinceSprint: number,
	dt: number
): (number, boolean, number)
	local s = math.clamp(if stamina == stamina then stamina else 1, 0, 1)
	local d = math.max(0, dt)
	if sprinting then
		s = math.max(0, s - FootTuning.STAMINA_DRAIN * d)
		local dry = s <= 0
		return s, exhausted or dry, 0
	end
	local since = sinceSprint + d
	if since >= FootTuning.STAMINA_REGEN_DELAY then
		s = math.min(1, s + FootTuning.STAMINA_REGEN * d)
	end
	local ex = exhausted and s < FootTuning.STAMINA_RECOVER
	return s, ex, since
end

-------------------------------------------------------------------------------------------------------------------------
-- Camera (gta_ui_language §2.17, §5.17; gta_realism_gap §2.14)
-------------------------------------------------------------------------------------------------------------------------

FootTuning.FOV = 58 -- vertical, on foot (Roblox's 70 reads "kid game")
FootTuning.FOV_SPRINT = 64 -- sprint kick
FootTuning.FOV_RATE = 4 -- 1/s exponential approach
FootTuning.PIVOT_HEIGHT = 1.7 -- above the root: upper chest
FootTuning.SHOULDER = 1.25 -- studs right of the pivot (slightly over the right shoulder)
FootTuning.DIST_MIN = 7
FootTuning.DIST_MAX = 16
FootTuning.DIST_DEFAULT = 11.5
FootTuning.FIRST_PERSON = 1.5 -- the default camera's zoom below this = first person: leave it alone
FootTuning.LAG_XZ = 0.09 -- pivot smooth time (s), horizontal
FootTuning.LAG_Y = 0.16 -- vertical (softer over steps, kerbs and jumps)
FootTuning.SNAP = 12 -- studs: a bigger jump of the target (teleport, respawn, seat exit) snaps
FootTuning.COLLIDE_RADIUS = 0.45
FootTuning.PULL_IN = 0.05 -- smooth time toward a nearer wall (fast, never through it)
FootTuning.EASE_OUT = 0.35 -- smooth time back out once clear (no pop)
FootTuning.MIN_DIST = 0.8
FootTuning.THIN = 1.2 -- occluders thinner than this on two axes (poles, posts, signs) do not pull the camera in
FootTuning.RECENTER_DELAY = 0.9 -- seconds without camera input before it swings behind a running player
FootTuning.RECENTER_RATE = 2.2 -- 1/s exponential
FootTuning.RECENTER_MIN_SPEED = 13 -- studs/s (jogging or faster)
FootTuning.RECENTER_PITCH = math.rad(-11) -- pitch it eases toward while running
FootTuning.RECENTER_PITCH_RATE = 0.8
FootTuning.RECENTER_MAX_ANGLE = math.rad(110) -- running back toward the camera never flips it round
FootTuning.ZOOM_SMOOTH = 0.18 -- smooth time of a zoom change (wheel, pinch, leaving a car)
FootTuning.BLEND_IN = 0.3 -- seconds to ease in after another camera (aim, death cam, creator) lets go
FootTuning.SEAT_FOV_HOLD = 0.6 -- seconds after leaving a seat with no FOV writes (VehicleClient's restore tween)
FootTuning.CAR_MAX_ZOOM = 60 -- CameraMaxZoomDistance while seated (the chase cam needs room)
FootTuning.INPUT_EPS = 1e-4 -- radians of look change between frames that count as the player's own camera input

-- Critically damped spring (same integrator as ShoulderCamera._smoothDamp). Returns (value, velocity).
function FootTuning.smoothDamp(
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

-- Shortest signed angle from a to b (radians, -pi..pi).
function FootTuning.angleDelta(a: number, b: number): number
	local d = (b - a) % (2 * math.pi)
	if d > math.pi then
		d -= 2 * math.pi
	end
	return d
end

-- Yaw (radians, Roblox convention: 0 looks down -Z) of a direction.
function FootTuning.yawOf(x: number, z: number): number
	return math.atan2(-x, -z)
end

-- One recentre step: the camera yaw eased toward the character's heading. Returns the new yaw.
function FootTuning.recenterYaw(camYaw: number, heading: number, dt: number): number
	local k = 1 - math.exp(-FootTuning.RECENTER_RATE * math.max(0, dt))
	return camYaw + FootTuning.angleDelta(camYaw, heading) * k
end

-- Should the camera recentre now? `offAngle` (optional) = |angle| between the camera yaw and the heading: running
-- back toward the lens (beyond RECENTER_MAX_ANGLE) never swings the camera round.
function FootTuning.shouldRecenter(speed: number, sinceInput: number, firstPerson: boolean, offAngle: number?): boolean
	if offAngle and math.abs(offAngle) > FootTuning.RECENTER_MAX_ANGLE then
		return false
	end
	return not firstPerson and speed >= FootTuning.RECENTER_MIN_SPEED and sinceInput >= FootTuning.RECENTER_DELAY
end

-- Pitch (radians) of a look vector's Y component.
function FootTuning.pitchOf(lookY: number): number
	return math.asin(math.clamp(lookY, -0.999, 0.999))
end

-- Did the look change between the camera we wrote last frame and what the default camera produced this frame (the
-- player turned the camera)? Angles in radians.
function FootTuning.lookInput(lastYaw: number?, lastPitch: number?, yaw: number, pitch: number): boolean
	if lastYaw == nil or lastPitch == nil then
		return false
	end
	return math.abs(FootTuning.angleDelta(lastYaw, yaw)) > FootTuning.INPUT_EPS
		or math.abs(pitch - lastPitch) > FootTuning.INPUT_EPS
end

-- Shoulder offset (studs to the right) at a camera distance: full from DIST_MIN out, fading to 0 by first person
-- (a close camera centred on the head, as GTA's).
function FootTuning.shoulderAt(dist: number): number
	local k = math.clamp((dist - FootTuning.FIRST_PERSON) / (FootTuning.DIST_MIN - FootTuning.FIRST_PERSON), 0, 1)
	return FootTuning.SHOULDER * k
end

-- The camera's zoom limits for the current state: (min, max). Seated -> the car's room; on foot -> the GTA range.
function FootTuning.zoomLimits(seated: boolean): (number, number)
	if seated then
		return 0.5, FootTuning.CAR_MAX_ZOOM
	end
	return 0.5, FootTuning.DIST_MAX
end

-- Who drives the on-foot camera this frame. FootCamera only post-processes the default camera: anything else that
-- holds the view (a Scriptable camera: aim, death, cinematics, the creator; a seat: VehicleClient) wins.
export type CamCtx = {
	cameraType: string, -- Enum.CameraType name
	alive: boolean,
	seated: boolean,
	shoulderEngaged: boolean,
	creatorOpen: boolean,
	subjectIsHumanoid: boolean,
}
function FootTuning.footCamActive(c: CamCtx): boolean
	return c.cameraType == "Custom"
		and c.alive
		and not c.seated
		and not c.shoulderEngaged
		and not c.creatorOpen
		and c.subjectIsHumanoid
end

-- Camera distance this frame: desired (from the zoom), the free distance the collision cast found (nil = clear) and
-- the current smoothed distance. Pulls in fast and never past the wall; eases back out slowly. Returns (dist, vel).
function FootTuning.collisionStep(
	current: number,
	velocity: number,
	desired: number,
	free: number?,
	dt: number
): (number, number)
	local limit = if free then math.max(FootTuning.MIN_DIST, math.min(desired, free)) else desired
	local smooth = if limit < current then FootTuning.PULL_IN else FootTuning.EASE_OUT
	local d, v = FootTuning.smoothDamp(current, limit, velocity, smooth, dt)
	if free and d > limit then
		-- the spring may lag a fast-closing wall: clamp so the lens never ends up inside it
		d = limit
		v = 0
	end
	return d, v
end

-- Map the default camera's requested zoom to the on-foot distance.
function FootTuning.footDistance(zoom: number?): number
	if typeof(zoom) ~= "number" or zoom ~= zoom then
		return FootTuning.DIST_DEFAULT
	end
	return math.clamp(zoom, FootTuning.DIST_MIN, FootTuning.DIST_MAX)
end

-- Is an occluder thin (a pole / post / sign) on at least two axes?
function FootTuning.isThin(size: Vector3): boolean
	local n = 0
	for _, v in { size.X, size.Y, size.Z } do
		if v < FootTuning.THIN then
			n += 1
		end
	end
	return n >= 2
end

-- FOV target on foot.
function FootTuning.targetFov(sprinting: boolean): number
	return if sprinting then FootTuning.FOV_SPRINT else FootTuning.FOV
end

-- Exponential approach (FOV, pitch...).
function FootTuning.approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * math.max(0, dt)))
end

-------------------------------------------------------------------------------------------------------------------------
-- Falls (server: FootService)
-------------------------------------------------------------------------------------------------------------------------

FootTuning.FALL_SAFE = 14 -- studs (~4 m): no damage below
FootTuning.FALL_LETHAL = 62 -- studs (~17 m, five storeys): lethal from here
FootTuning.FALL_RAGDOLL = 24 -- studs (~7 m): a brief ragdoll on landing (when it does not kill)
FootTuning.RAGDOLL_MIN = 1.4 -- seconds
FootTuning.RAGDOLL_MAX = 2.6
FootTuning.FALL_MAX_HP = 100

-- Drop height (studs) that produces an impact speed under gravity g.
function FootTuning.dropFromSpeed(impactSpeed: number, gravity: number): number
	local g = if gravity > 0 then gravity else 196.2
	local v = math.max(0, impactSpeed)
	return v * v / (2 * g)
end

-- Impact speed of a drop of h studs.
function FootTuning.speedFromDrop(h: number, gravity: number): number
	local g = if gravity > 0 then gravity else 196.2
	return math.sqrt(2 * g * math.max(0, h))
end

-- (damage 0..100, ragdoll seconds 0..) for a landing at impactSpeed (studs/s, downward, positive).
function FootTuning.fallDamage(impactSpeed: number, gravity: number): (number, number)
	local h = FootTuning.dropFromSpeed(impactSpeed, gravity)
	if h < FootTuning.FALL_SAFE then
		return 0, 0
	end
	local t = math.clamp((h - FootTuning.FALL_SAFE) / (FootTuning.FALL_LETHAL - FootTuning.FALL_SAFE), 0, 1)
	-- eased: small drops sting, the top of the range kills
	local damage = math.floor(FootTuning.FALL_MAX_HP * (0.08 + 0.92 * t * t) + 0.5)
	if h >= FootTuning.FALL_LETHAL then
		damage = FootTuning.FALL_MAX_HP
	end
	local rag = 0
	if h >= FootTuning.FALL_RAGDOLL then
		local k = math.clamp((h - FootTuning.FALL_RAGDOLL) / (FootTuning.FALL_LETHAL - FootTuning.FALL_RAGDOLL), 0, 1)
		rag = FootTuning.RAGDOLL_MIN + (FootTuning.RAGDOLL_MAX - FootTuning.RAGDOLL_MIN) * k
	end
	return damage, rag
end

-- Landing detector over server samples of the root's vertical velocity: the previous sample was falling faster than
-- the safe-drop speed and this one has (nearly) stopped. Returns the impact speed (0 when no hard landing).
function FootTuning.landingImpact(prevVy: number, vy: number, gravity: number): number
	local safe = FootTuning.speedFromDrop(FootTuning.FALL_SAFE, gravity)
	if prevVy < -safe and vy > prevVy * 0.25 then
		return -prevVy
	end
	return 0
end

-------------------------------------------------------------------------------------------------------------------------
-- Name tags (NameTags controller)
-------------------------------------------------------------------------------------------------------------------------

FootTuning.TAG_DISTANCE = 40 -- studs
FootTuning.TAG_SIZE = 13 -- px, Montserrat

function FootTuning.tagVisible(
	distance: number,
	localInCombat: boolean,
	hudHidden: boolean,
	targetHidden: boolean
): boolean
	return distance <= FootTuning.TAG_DISTANCE and not localInCombat and not hudHidden and not targetHidden
end

-- Fade near the range limit (0 = opaque, 1 = invisible).
function FootTuning.tagFade(distance: number): number
	local start = FootTuning.TAG_DISTANCE * 0.75
	if distance <= start then
		return 0
	end
	return math.clamp((distance - start) / (FootTuning.TAG_DISTANCE - start), 0, 1)
end

-------------------------------------------------------------------------------------------------------------------------
-- Touch SPRINT button (shares the HUD's touch layout: UI/HudLayout + WeaponClient.touchRects)
-------------------------------------------------------------------------------------------------------------------------

FootTuning.SPRINT_BUTTON = 64
FootTuning.SPRINT_GAP = 12

export type Rect = { x: number, y: number, w: number, h: number }

-- `edge`: the left-most x of the jump / phone / map buttons (WeaponClient.touchRects uses the same edge for FIRE);
-- `bottom`: the jump button's bottom; `fireSize`: the combat FIRE button. Unarmed: left of the jump button on the
-- bottom row (where FIRE goes when a gun is out). Armed: above the FIRE button.
function FootTuning.sprintRect(edge: number, bottom: number, armed: boolean, fireSize: number): Rect
	local S, G = FootTuning.SPRINT_BUTTON, FootTuning.SPRINT_GAP
	local x = edge - G - S
	if armed then
		return { x = x, y = bottom - fireSize - G - S, w = S, h = S }
	end
	return { x = x, y = bottom - S, w = S, h = S }
end

return FootTuning
