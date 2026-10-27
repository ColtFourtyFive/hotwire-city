--!strict
-- PoliceAim (gta_combat §9.1-9.4): pure police fairness math. PoliceCombatService (server) asks; nothing here reads
-- the world.
--
--   P(hit)   = acc[stars] * fDist * fMotion * fCover * fVehicle * fMercy
--   fDist    = clamp(1 - (d - 20) / 180, 0.25, 1)
--   fMotion  = 1 / (1 + v / 25)                 v = target speed (studs/s): sprint ~0.53, car at 60 ~0.29
--   fCover   = visible fraction (3 rays: head, torso, legs)
--   fVehicle = 0.7 in a car (and 60 % of "hits" strike the car body instead of the driver)
--   fMercy   = 0.5 for 4 s once per life when the target drops under 30 HP
-- Firing director: one token bucket per TARGET refilling at DPSbudget / averageShotDamage shots per second. Officers
-- request shots; only granted requests fire, so ten officers never out-damage the star's budget.

local Police = require(script.Parent.Parent.Config.Police)

local PoliceAim = {}

PoliceAim.VEHICLE_MULT = 0.7
PoliceAim.VEHICLE_BODY_SHARE = 0.6
PoliceAim.MERCY_MULT = 0.5
PoliceAim.DIRECTOR_CAP_SECONDS = 1 -- a director can bank at most 1 s of budget (no stored-up volleys)

export type Director = { tokens: number, rate: number, cap: number, last: number, granted: number, denied: number }
export type FireFlags = {
	protected: boolean?, -- spawn protection / rookie / passive / safe zone / surrendering
	recentlySpawned: boolean?, -- within HOLD_FIRE_RESPAWN of a respawn or release
	lethal: boolean, -- star rules allow lethal fire at this suspect right now
}

function PoliceAim.starCombat(stars: number): Police.StarCombat
	local list = Police.Combat
	return list[math.clamp(math.floor(stars), 1, #list)]
end

function PoliceAim.fDist(d: number): number
	return math.clamp(1 - (d - 20) / 180, 0.25, 1)
end

function PoliceAim.fMotion(speed: number): number
	return 1 / (1 + math.max(0, speed) / 25)
end

function PoliceAim.hitChance(
	stars: number,
	distance: number,
	speed: number,
	visibleFraction: number,
	inVehicle: boolean,
	mercy: boolean
): number
	local acc = PoliceAim.starCombat(stars).accuracy
	local p = acc
		* PoliceAim.fDist(distance)
		* PoliceAim.fMotion(speed)
		* math.clamp(visibleFraction, 0, 1)
		* (if inVehicle then PoliceAim.VEHICLE_MULT else 1)
		* (if mercy then PoliceAim.MERCY_MULT else 1)
	return math.clamp(p, 0, 1)
end

-- Is this star level willing to use lethal force on this suspect right now?
--  1 star: never (taser / arrest). 2 stars: only an ARMED suspect (fired recently or aiming at cops), and never at a
--  car moving faster than NO_FIRE_SPEED (cops ram instead). 3+: always.
function PoliceAim.lethal(stars: number, armed: boolean, inVehicle: boolean, speed: number): boolean
	local rule = PoliceAim.starCombat(stars).lethal
	if stars <= 0 or rule == "never" then
		return false
	end
	if rule == "armed" then
		if not armed then
			return false
		end
		if inVehicle and speed > Police.NO_FIRE_SPEED then
			return false
		end
	end
	return true
end

-- Hold fire on protected / passive / rookie / surrendering / safe-zone / just-respawned targets.
function PoliceAim.mayFire(flags: FireFlags): boolean
	if flags.protected or flags.recentlySpawned then
		return false
	end
	return flags.lethal
end

-- The first WARNING_SHOTS shots at a newly acquired target always miss.
function PoliceAim.isWarningShot(shotsAtTarget: number): boolean
	return shotsAtTarget < Police.WARNING_SHOTS
end

-- Reaction delay after acquiring line of sight, from a uniform u in [0, 1).
function PoliceAim.reactionDelay(stars: number, u: number): number
	local r = PoliceAim.starCombat(stars).reaction
	return r[1] + (r[2] - r[1]) * math.clamp(u, 0, 1)
end

-- Of a "hit" on a target inside a car, does the bullet strike the car body instead (u uniform)?
function PoliceAim.hitsCarBody(u: number): boolean
	return u < PoliceAim.VEHICLE_BODY_SHARE
end

-- DIRECTOR ------------------------------------------------------------------------------------------------------------

function PoliceAim.newDirector(dpsBudget: number, avgShotDamage: number, now: number): Director
	local rate = if avgShotDamage > 0 then math.max(0, dpsBudget) / avgShotDamage else 0
	local cap = math.max(1, rate * PoliceAim.DIRECTOR_CAP_SECONDS)
	return { tokens = math.min(1, cap), rate = rate, cap = cap, last = now, granted = 0, denied = 0 }
end

-- Re-tune for a new star level (keeps the banked tokens, clamped).
function PoliceAim.setBudget(d: Director, dpsBudget: number, avgShotDamage: number)
	d.rate = if avgShotDamage > 0 then math.max(0, dpsBudget) / avgShotDamage else 0
	d.cap = math.max(1, d.rate * PoliceAim.DIRECTOR_CAP_SECONDS)
	d.tokens = math.min(d.tokens, d.cap)
end

function PoliceAim.request(d: Director, now: number): boolean
	d.tokens = math.min(d.cap, d.tokens + math.max(0, now - d.last) * d.rate)
	d.last = now
	if d.rate <= 0 or d.tokens < 1 then
		d.denied += 1
		return false
	end
	d.tokens -= 1
	d.granted += 1
	return true
end

-- VISION (§9.4) -------------------------------------------------------------------------------------------------------

-- Is `target` inside the cone (flat angle) of an observer at `pos` looking along `look`? near = 360° radius.
function PoliceAim.inCone(pos: Vector3, look: Vector3, cone: Police.Cone, target: Vector3): boolean
	local dx, dz = target.X - pos.X, target.Z - pos.Z
	local d = math.sqrt(dx * dx + dz * dz)
	if cone.near and d <= cone.near then
		return true
	end
	if d > cone.range then
		return false
	end
	if cone.fov >= 360 or d < 1e-3 then
		return true
	end
	local lx, lz = look.X, look.Z
	local lm = math.sqrt(lx * lx + lz * lz)
	if lm < 1e-3 then
		return true
	end
	local cosA = (dx * lx + dz * lz) / (d * lm)
	return cosA >= math.cos(math.rad(cone.fov / 2))
end

-- Search area radius for a star count.
function PoliceAim.searchRadius(stars: number): number
	local list = Police.SEARCH_RADIUS
	return list[math.clamp(math.floor(stars), 1, #list)]
end

-- One evade-timer step. Returns the new remaining seconds (<= 0 = evaded). Seen resets to the full time; outside the
-- search area the timer runs EVADE_OUTSIDE_MULT times faster.
function PoliceAim.evadeStep(remaining: number, full: number, dt: number, seen: boolean, insideSearch: boolean): number
	if seen then
		return full
	end
	local rate = if insideSearch then 1 else Police.EVADE_OUTSIDE_MULT
	return remaining - dt * rate
end

-- Random point inside the search circle (u, v uniforms) on the XZ plane at the center's height.
function PoliceAim.searchPoint(center: Vector3, radius: number, u: number, v: number): Vector3
	local r = radius * math.sqrt(math.clamp(u, 0, 1))
	local a = 2 * math.pi * v
	return center + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
end

return PoliceAim
