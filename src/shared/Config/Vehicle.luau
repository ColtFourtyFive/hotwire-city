--!strict
-- Arcade raycast-vehicle tuning shared by players' cars and police AI.
-- Units: studs, seconds, Workspace.Gravity = 196.2. Every acceleration is multiplied by the chassis
-- AssemblyMass at runtime, so tuning is mass-independent (read AssemblyMass live: Massless parts change it).
--
-- Model (see docs/SPEC.md §8): single assembly; per-wheel VectorForce for suspension (RelativeTo=World,
-- ApplyAtCenterOfMass=false), one center VectorForce "Drive" for drive/brake/grip/downforce, yaw written
-- directly to AssemblyAngularVelocity, and an "Upright" AlignOrientation enabled only when airborne/tilted.

local Vehicle = {
	-- Suspension (per wheel). L = SUSPENSION_REST + wheelRadius; comp = L - hitDistance
	-- a = clamp(SPRING_K * comp + SPRING_C * compressionVelocity, 0, 4g); force = M * a along ground normal.
	SUSPENSION_REST = 1.6,
	SPRING_K = 68, -- ≈45% static sag, ω ≈ 16.5 rad/s
	SPRING_C = 4.2, -- ζ ≈ 0.5
	MAX_SUSPENSION_ACCEL_G = 4,

	-- Drive (studs/s^2 unless noted). Car topSpeed/accel come from Config/Cars; these shape them.
	-- aDrive = throttle * accel * (1 - (vF/vMax)^2)
	BRAKE_DECEL = 90,
	REVERSE_ACCEL = 25,
	REVERSE_MAX_SPEED = 45,
	ROLLING_RESISTANCE = 6,
	AIR_DRAG = 0.0005, -- * vF * |vF|
	MIN_GROUNDED_WHEELS = 2,

	-- Grip: aLat = clamp(-vR * GRIP_RATE * car.grip, ±LATERAL_MAX_G * g)
	GRIP_RATE = 10,
	HANDBRAKE_GRIP_RATE = 1.5,
	GRIP_RECOVER_TIME = 0.4,
	LATERAL_MAX_G = 1.2,
	DRIFT_SLIP_SPEED = 12, -- |vR| above this counts as drifting (FX + contract seconds)

	-- Steering: targetYaw = -steer * MAX_YAW_RATE * clamp(|vF|/15, 0, 1) * (1 - FALLOFF * clamp(|vF|/vMax)) * sign(vF)
	MAX_YAW_RATE = 2.4,
	YAW_RESPONSE = 8, -- yawNow += (target - yawNow) * min(1, YAW_RESPONSE * dt)
	HIGH_SPEED_STEER_FALLOFF = 0.45,
	AIR_YAW_RATE = 1,

	-- Downforce while grounded: aDown = DOWNFORCE_BASE_G * g + DOWNFORCE_SPEED * vF^2
	DOWNFORCE_BASE_G = 0.25,
	DOWNFORCE_SPEED = 0.002,

	-- Upright AlignOrientation (enabled only when 0 wheels grounded or up·worldUp < 0.5)
	UPRIGHT_RESPONSIVENESS = 10,
	UPRIGHT_MAX_ANGULAR_VELOCITY = 6,
	UPRIGHT_TORQUE_PER_MASS = 400,
	AUTO_FLIP_DOT = 0.3, -- up·worldUp below this...
	AUTO_FLIP_AFTER = 1.5, -- ...for this long at speed < AUTO_FLIP_MAX_SPEED -> flip upright
	AUTO_FLIP_MAX_SPEED = 10,

	MAX_DT = 1 / 30, -- clamp simulation dt (low FPS stability)

	-- Nitro
	NITRO_SPEED_MULT = 1.3,
	NITRO_ACCEL_MULT = 1.8,
	NITRO_REFILL_PER_SEC = 0.12, -- fraction of tank per second when not boosting

	-- Damage
	MAX_HEALTH = 100,
	CRASH_DAMAGE_THRESHOLD = 55, -- studs/s of sudden velocity change before damage applies
	CRASH_DAMAGE_SCALE = 0.6, -- damage per stud/s above threshold

	-- Feel / camera
	FOV_BASE = 70,
	FOV_MAX_BONUS = 18,
	CAMERA_SHAKE_ON_CRASH = 0.6,

	-- Ownership / lifetime / anti-cheat
	ABANDON_DESPAWN = 45, -- loot cars with no driver despawn after this (if no players nearby)
	PARK_ANCHOR_AFTER = 10, -- unoccupied cars at rest get anchored after this many seconds
	OWNED_RETURN_AFTER = 20, -- player's own car with no driver goes back to its slot after this
	NEAR_PLAYER_RADIUS = 120,
	SPEED_CAP_MULT = 1.35, -- server watchdog: horizontal speed <= topSpeed * this (* NITRO_SPEED_MULT if nitro allowed) ...
	SPEED_CAP_GRACE = 1.2, -- ...multiplied by this lag tolerance
	WATCHDOG_TELEPORT_SLACK = 10, -- per-tick displacement allowance beyond speed*dt
	WATCHDOG_REVOKE_SECONDS = 2, -- on violation, server takes ownership back this long and rewinds
}

return Vehicle
