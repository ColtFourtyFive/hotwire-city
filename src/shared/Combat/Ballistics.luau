--!strict
-- Ballistics (gta_combat §4.3-4.4, §10.1): pure, deterministic shot math shared by WeaponClient (prediction) and
-- WeaponService (validation). No services, no instances.
--
--  * Spread: cone half-angle in degrees = clamp(base + bloom, base, maxSpread) x movement multipliers, and the result
--    is clamped to Weapons.maxSpread so the server can bound the angle between the aim line and any shot.
--  * Pellets: a shotgun's pellet directions come from an integer seed through our own Park-Miller generator (NOT
--    Random.new: the Lune harness shims Random, and both sides must agree bit for bit). The server regenerates them
--    from the packet's seed and checks every claimed pellet against its regenerated direction.
--  * Falloff, recoil kicks, the muzzle -> crosshair solve and TTK helpers for the balance tests.

local Weapons = require(script.Parent.Parent.Config.Weapons)

type WeaponDef = Weapons.WeaponDef

local Ballistics = {}

local MODULUS = 2147483647
local MULT = 16807

export type MoveState = { aiming: boolean, moving: boolean, sprinting: boolean, airborne: boolean }

-- Park-Miller "minimal standard" generator. Returns (nextState, value in [0, 1)). State must be 1..MODULUS-1.
function Ballistics.nextRandom(state: number): (number, number)
	local s = (state * MULT) % MODULUS
	return s, (s - 1) / (MODULUS - 1)
end

-- Normalizes any integer seed into a valid generator state.
function Ballistics.seedState(seed: number): number
	local s = math.floor(math.abs(seed)) % MODULUS
	if s == 0 then
		s = 1
	end
	return s
end

-- Orthonormal basis (right, up) perpendicular to a unit direction.
function Ballistics.basis(dir: Vector3): (Vector3, Vector3)
	local ref = if math.abs(dir.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis
	local right = dir:Cross(ref).Unit
	local up = right:Cross(dir).Unit
	return right, up
end

-- Direction inside a cone of half-angle `spreadDeg` around unit `dir`, from two uniforms u, v in [0, 1).
-- sqrt(u) gives a uniform disc (no clustering in the middle).
function Ballistics.coneDirection(dir: Vector3, spreadDeg: number, u: number, v: number): Vector3
	if spreadDeg <= 0 then
		return dir
	end
	local right, up = Ballistics.basis(dir)
	local angle = math.rad(spreadDeg) * math.sqrt(u)
	local roll = 2 * math.pi * v
	local tanA = math.tan(angle)
	return (dir + (right * math.cos(roll) + up * math.sin(roll)) * tanA).Unit
end

-- `count` deterministic directions for a seed (pellet 1..count). Used for every gun: single-pellet guns use pellet 1.
function Ballistics.pellets(dir: Vector3, spreadDeg: number, seed: number, count: number): { Vector3 }
	local out = table.create(count)
	local state = Ballistics.seedState(seed)
	for i = 1, count do
		local u, v
		state, u = Ballistics.nextRandom(state)
		state, v = Ballistics.nextRandom(state)
		out[i] = Ballistics.coneDirection(dir, spreadDeg, u, v)
	end
	return out
end

-- Angle between two directions, degrees.
function Ballistics.angleBetween(a: Vector3, b: Vector3): number
	local ma, mb = a.Magnitude, b.Magnitude
	if ma < 1e-9 or mb < 1e-9 then
		return 180
	end
	local c = math.clamp(a:Dot(b) / (ma * mb), -1, 1)
	return math.deg(math.acos(c))
end

-- Current cone half-angle for a shot. bloom = degrees accumulated by recent shots.
function Ballistics.spreadAngle(def: WeaponDef, bloom: number, state: MoveState): number
	if def.fireMode == "Pump" then
		-- fixed pattern: no bloom, no movement penalty (the server regenerates it exactly)
		return if state.aiming then def.spreadAim else def.spreadHip
	end
	local base = if state.aiming then def.spreadAim else def.spreadHip
	local maxSpread = Weapons.maxSpread(def)
	local s = math.clamp(base + math.max(0, bloom), base, math.max(base, maxSpread))
	if state.airborne then
		s *= Weapons.AIR_SPREAD
	elseif state.sprinting then
		s *= Weapons.SPRINT_SPREAD
	elseif state.moving then
		s *= Weapons.MOVE_SPREAD
	end
	return math.min(s, maxSpread)
end

-- Bloom after one more shot.
function Ballistics.addBloom(def: WeaponDef, bloom: number): number
	local per = def.bloomPerShot or 0
	local cap = Weapons.maxSpread(def)
	return math.clamp(bloom + per, 0, cap)
end

-- Bloom recovery: nothing for BLOOM_RECOVER_DELAY after the last shot, then BLOOM_RECOVER_RATE deg/s.
function Ballistics.recoverBloom(bloom: number, dt: number, sinceShot: number): number
	if sinceShot < Weapons.BLOOM_RECOVER_DELAY then
		return bloom
	end
	return math.max(0, bloom - Weapons.BLOOM_RECOVER_RATE * dt)
end

-- Damage multiplier for distance d: 1 inside fullDist, lerping to minMult at zeroDist and beyond.
function Ballistics.falloff(def: WeaponDef, d: number): number
	local full, zero, minMult = def.fullDist, def.zeroDist, def.minMult
	if full == nil or zero == nil or minMult == nil or zero <= full then
		return minMult or 1
	end
	local t = math.clamp((d - full) / (zero - full), 0, 1)
	return 1 + (minMult - 1) * t
end

-- Camera kick for one shot: (pitchDeg up, yawDeg) from two uniforms. Mobile kicks less (thumbs can't counter-pull).
function Ballistics.recoilKick(def: WeaponDef, u: number, v: number, mobile: boolean): (number, number)
	local r = def.recoil
	local pitch = r.pitchMin + (r.pitchMax - r.pitchMin) * u
	local yaw = r.yaw * (v * 2 - 1)
	if mobile then
		pitch *= Weapons.MOBILE_RECOIL
		yaw *= Weapons.MOBILE_RECOIL
	end
	return pitch, yaw
end

-- Accumulated recoil never exceeds TOTAL_RECOIL_MULT x the weapon's max pitch.
function Ballistics.clampRecoil(def: WeaponDef, accumulated: number): number
	return math.min(accumulated, def.recoil.pitchMax * Weapons.TOTAL_RECOIL_MULT)
end

-- Exponential recoil recovery: RECOIL_DECAY per 1/60 s.
function Ballistics.decayRecoil(value: number, dt: number): number
	return value * Weapons.RECOIL_DECAY ^ (dt * 60)
end

-- GTA shoulder-cam aim: the camera ray picks the crosshair point; the bullet flies muzzle -> point. When the point is
-- closer than `minDist` (or behind the muzzle) the camera direction is used as is.
function Ballistics.muzzleToPoint(muzzle: Vector3, point: Vector3, cameraDir: Vector3, minDist: number?): Vector3
	local d = point - muzzle
	local mag = d.Magnitude
	if mag < (minDist or 1.5) or d:Dot(cameraDir) <= 0 then
		return cameraDir.Unit
	end
	return d / mag
end

-- Reload duration (tactical vs empty).
function Ballistics.reloadTime(def: WeaponDef, magNow: number): number
	local base = def.perShellReload or def.reloadTime or 1.5
	if def.perShellReload then
		return base
	end
	return if magNow <= 0 then base + Weapons.EMPTY_RELOAD_EXTRA else base
end

-- How many rounds a full reload moves from reserve into the magazine.
function Ballistics.reloadAmount(def: WeaponDef, mag: number, reserve: number): number
	local cap = def.mag or 0
	if def.perShellReload then
		return math.min(1, math.max(0, cap - mag), reserve)
	end
	return math.max(0, math.min(cap - mag, reserve))
end

-- BALANCE HELPERS (tests) ----------------------------------------------------------------------------------------------

-- Shots needed to deal `hp` (health + armor: armor absorbs everything first, so it just adds HP) at point blank.
function Ballistics.shotsToKill(def: WeaponDef, hp: number, headshot: boolean): number
	local per = def.damage * (if headshot then def.headMult else 1) * (def.pellets or 1)
	if per <= 0 then
		return math.huge
	end
	return math.ceil(hp / per - 1e-9)
end

-- Time to kill in seconds: (shots - 1) x interval.
function Ballistics.ttk(def: WeaponDef, hp: number, headshot: boolean): number
	local n = Ballistics.shotsToKill(def, hp, headshot)
	return (n - 1) * Weapons.interval(def)
end

return Ballistics
