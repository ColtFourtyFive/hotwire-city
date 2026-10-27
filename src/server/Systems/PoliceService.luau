--!strict
-- PoliceService: physical police pursuit AI + police helicopter + BUSTED detection.
--
-- Units are real server-owned physics cars (VehicleService kind "Police", Cars.Police def) driven by the shared
-- VehicleController with AI input. Every AI_TICK each unit decides:
--   * suspect within PURSUIT_RANGE with line of sight -> pure pursuit to a predicted intercept point
--     (role-based: chaser / flanker / interceptor so a pack of cops boxes the suspect in)
--   * otherwise -> Manhattan routing on the road grid via intersections (never through a block interior)
--   * steering law, brake-on-sharp-angle, corner speed control, reverse-into-target, unstuck
-- Rubber-banding repositions hidden far-away units onto a lane behind the suspect, out of view.
-- At HELI_AT_STARS a cartoon chopper hovers over the suspect with a searchlight (keeps them "seen" while it has
-- line of sight; it matches 90% of a fast car's top speed, so nitro and buildings break its view). The server keeps
-- the heli's logical state and publishes HeliCFrame / SpotPos model attributes at ~10 Hz; EffectsController renders.
-- Cruisers' top speed scales with stars AND with the suspect's car (a Legendary can't just outrun a 5-star chase).
-- Officers (docs/ART_PASS.md AP3): every cruiser gets a seated officer: an NPCService humanoid (police outfit) where
-- it can be seen (NPCService.driverVisible: not inside the closed police_unit shell), else TrafficService's block
-- dummy in police blue (also until NPCService is ready / over budget; visible dummies are upgraded by the manage pass,
-- OFFICER_UPGRADES_PER_PASS, out of view). A wrecked cruiser's officer is yeeted out (NPCService.ejectComic; a dummy
-- hands its seat to a humanoid for that). On WantedService.Busted an officer steps out beside the
-- busted player (nearest cruiser's side) for BUST_OFFICER_TIME seconds: purely visual.
--
-- Public API (docs/SPEC.md §6):
--   isSeen(player): boolean      a cruiser's vision cone (100° / 150 studs + 40 studs all round), the heli's 110-stud
--                                circle or an on-foot officer's cone (PoliceCombatService) has the suspect with line of
--                                sight (WantedService evade timer; gta_combat §9.4)
-- Extra public helpers: getUnitCount(player?): number, buildHeli(): Model (harness-compatible builder)
-- Combat v2 (gta_combat §9, §13.2): getUnits(player): { UnitView }, getHeli(player): Model?, unitRole(unitView),
--   copsNear(pos, radius): boolean (witnesses), spawnRoadblockCar(cframe): car?, registerBustSource(fn).
--   Search: while nobody has seen the suspect for SEARCH_AFTER seconds, units route to random points inside
--   WantedService's search circle around the last known position instead of to the suspect. A cruiser whose model
--   attribute OfficersOut > 0 holds position (its officers are fighting on foot).
-- Pure helpers (tests/spec/police.spec.luau, incl. kinematic driving + chase simulations): _steerToward,
--   _nextWaypoint (grid routing w/ turn feasibility + hysteresis), _drive (control law: corner speed, K-turns,
--   anti-orbit), _usePursuit, _roadAnchor, _roadLines, _updateStuck, _newStuck, _isRam, _allocateUnits,
--   _orientedLane, _spawnCandidates, _carTopSpeed, _unitSpeedMult, _heliMaxSpeed, _isClearOf, _bustOfficerSpot
-- Fairness: cops spawn behind you out of view, 1-star cops are slower than you, rubber-banding only happens out
-- of sight, ramming heat only counts when YOU hit THEM, hiding in your own garage is a safe house (cops wait
-- outside, no bust, no "seen"), and cops overshoot corners if you juke them at speed.
-- Player attribute written here: BustProgress (0..1) for the HUD bust ring.
-- Police car model attributes: SuspectUserId, Siren (bool; false = leaving / wrecked, clients stop the lights),
-- SpeedMultiplier (VehicleController hook). PoliceHeli model attributes: SuspectUserId, HeliCFrame, SpotPos.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Trove = require(Shared.Util.Trove)
local MapLayout = require(Shared.Util.MapLayout)
local MapConfig = require(Shared.Config.Map)
local PoliceConfig = require(Shared.Config.Police)
local VehicleConfig = require(Shared.Config.Vehicle)
local Cars = require(Shared.Config.Cars)
local PoliceAim = require(Shared.Combat.PoliceAim)
local WantedService = require(script.Parent.WantedService)

local PoliceService = {}

-- TUNING ------------------------------------------------------------------------------------------------

local S = MapConfig.GRID_SPACING
local ROAD_HALF = MapConfig.ROAD_WIDTH / 2
local LMIN, LMAX = MapConfig.LINE_MIN, MapConfig.LINE_MAX
local EXT = MapConfig.HALF_EXTENT
local ANCHOR_INSET = 6 -- road anchors stay this far inside the road edge

local AI_TICK = PoliceConfig.AI_TICK
local BUST_TICK = 0.25
local MANAGE_TICK = 0.5

local PURSUIT_RANGE = 150 -- pure pursuit when closer than this with line of sight
local CLOSE_SEE_RANGE = PoliceConfig.CLOSE_SEE_RANGE -- a unit this close always "sees" you (sirens, engine noise)
local CRUISER_CONE = PoliceConfig.CONES.cruiser
local SEARCH_AFTER = 2 -- seconds unseen before units stop homing on the suspect and search the area
local SEARCH_REACHED = 25 -- a search point closer than this is done: roll the next one
local SEARCH_REROLL = 12 -- ...or after this long
local STEER_FULL_ANGLE = 35
local TURN_ANGLE = 45 -- aim further off-nose than this: hold the speed down to CORNER_SPEED
local UTURN_ANGLE = 100 -- aim behind us: K-turn (brake, reverse on opposite lock, drive off)
local KTURN_SPEED = 6 -- start backing up once slower than this
local KTURN_STRAIGHT_BRAKE_SPEED = 25
local BACKUP_RANGE = 35 -- an aim point this close behind us is reversed onto rather than K-turned toward
local PURSUIT_MAX_ANGLE = 55 -- pure pursuit only when the suspect is within this angle of our nose...
local PURSUIT_CLOSE = 45 -- ...or closer than this, or we are slow enough to turn hard
local RADIUS_SPEED_FACTOR = 2 -- max speed per stud of turning radius (arcade yaw rate is ~2.2 rad/s)
local MIN_TURN_SPEED = 10
local HANDBRAKE_MIN_ANGLE, HANDBRAKE_MAX_ANGLE, HANDBRAKE_MIN_SPEED = 50, 120, 62
local CORNER_SPEED = 42 -- studs/s through a 90° intersection turn
local CORNER_DECEL = 70 -- planned deceleration when approaching a turn
local TURN_IN_DIST = 28 -- be at CORNER_SPEED this far before the intersection center (box edge + one AI tick)
local TURN_PENALTY = 40 -- routing cost per extra turn
local BEHIND_PENALTY = 30 -- routing cost for a waypoint behind the car (U-turn)
local TURN_NOW_BASE = 20 -- routing cost of a first leg that needs a turn right now...
local TURN_NOW_PER_SPEED = 0.8 -- ...plus this per stud/s of current speed
local ROUTE_HYSTERESIS = 60 -- keep last tick's turn unless a new route is cheaper by this much
local PLAN_BRAKE_DECEL = 80 -- braking assumed when judging whether a turn ahead is still makeable
local LATE_TURN_PENALTY = 300
local REVERSE_TIME = 1.2
local STUCK_SPEED = 3
local REVERSE_INTO_RANGE = 30
local BOX_SPEED = 20 -- suspect slower than this gets boxed in (cops stop around them)
local BOX_RADIUS = 11
local FLANK_OFFSET = 9
local INTERCEPT_LEAD = 2.5 -- seconds of suspect velocity interceptors route toward
local UP3 = Vector3.new(0, 3, 0)

local SPAWN_STAGGER = 1.2
local FIRST_SPAWN_DELAY = 1.5
local WRECK_RESPAWN_DELAY = 6
local WRECK_CLEANUP_AFTER = 4
local SPAWN_MIN_DIST, SPAWN_MAX_DIST = 170, 330
local SPAWN_CLEARANCE = 16
local SPAWN_SPEED = 45
local LEAVE_TIME = 3
local LEAVE_MAX_TIME = 12
local LEAVE_VIEW_RADIUS = 140
local RUBBER_BAND_COOLDOWN = 8
local RUBBER_BAND_HIDDEN_TIME = 2
local STUCK_RESCUE_COUNT = 3
local RAM_SPEED = 40
local RAM_COOLDOWN = 10
local POLICE_DAMAGE_MULT = 1
local POLICE_NITRO_SECONDS = 3
local BUST_OFFICER_TIME = 4 -- the BUSTED officer stands beside the player this long (visual only)
local BUST_OFFICER_OFFSET = 4.5 -- studs from the player toward the nearest cruiser
local BUST_OFFICER_UNIT_RANGE = 80 -- a cruiser farther than this: the officer stands at the player's right
local OFFICER_UPGRADES_PER_PASS = 1 -- block-dummy officers swapped for humanoids per manage pass...
local OFFICER_UPGRADE_HIDDEN_DIST = 120 -- ...only in cruisers at least this far from every player

-- Stars -> top speed multiplier: 1-star cops are beatable, 5-star cops are relentless.
local SPEED_MULT_BY_STARS = { 0.82, 0.9, 0.97, 1.03, 1.08 }
local CATCHUP_BONUS = 0.12 -- extra multiplier while a unit is far behind and can't see the suspect
-- Fast getaway cars: cruisers are also tuned to the suspect's car top speed, at 85% (1 star) .. 105% (5 stars),
-- so a Legendary still outruns 1-3 star cops but not a 5-star pursuit (nitro still buys a gap).
local SUSPECT_MATCH_BASE = 0.8
local SUSPECT_MATCH_PER_STAR = 0.05
local MAX_SPEED_MULT = 2.5 -- VehicleController clamps SpeedMultiplier to 3

local HELI_ALTITUDE = 80
local HELI_CLEARANCE = 30 -- above the tallest thing below / ahead of it
local HELI_MAX_SPEED = 95 -- slow and mid cars can't outrun the chopper...
local HELI_SUSPECT_SPEED = 0.9 -- ...and it flies at 90% of a faster car's top speed (nitro can still outrun it)
local HELI_SIGHT = PoliceConfig.CONES.heli.range -- horizontal radius in which the chopper's searchlight "sees"
local MAX_HELIS = 3
local HELI_SCALE = 1.25
local HELI_LEAVE_TIME = 5
local HELI_PUBLISH = 0.1 -- pose attributes for EffectsController's renderer (rotor, sirens and smoothing are client-side)
local HELI_SPOT_EPSILON = 0.25 -- republish SpotPos only when it moved more than this

-- TYPES -------------------------------------------------------------------------------------------------

export type Stuck = {
	stuckTime: number,
	reverseUntil: number,
	reverseSteer: number, -- steer to use while recovering
	recoverThrottle: number, -- -1 = back out (was blocked going forward), +1 = pull forward (blocked reversing)
	count: number,
}

type Input = { throttle: number, steer: number, handbrake: boolean, nitro: boolean }

type Unit = {
	id: number,
	suspect: Player,
	car: any,
	model: Model,
	chassis: BasePart,
	controller: any,
	trove: any,
	input: Input,
	role: number,
	mode: string, -- "chase" | "leaving" | "wrecked"
	alive: boolean,
	broken: boolean,
	leaveAt: number,
	wreckedAt: number,
	spawnedAt: number,
	lastTeleport: number,
	dist: number,
	hasLOS: boolean,
	seen: boolean,
	lastLosAt: number,
	lastRubberBand: number,
	lastVel: Vector3,
	routeWp: Vector3?, -- committed turn waypoint (routing hysteresis)
	searchPoint: Vector3?, -- search mode: current random point inside the search circle
	searchPointAt: number,
	health: number,
	speedMult: number,
	stuck: Stuck,
	npc: Model?, -- the seated officer (NPCService humanoid or TrafficService block dummy)
}

type Heli = {
	model: Model,
	body: BasePart,
	disc: BasePart?,
	beam: Beam?,
	pos: Vector3,
	vel: Vector3,
	yaw: number,
	spot: Vector3,
	ceiling: number,
	nextCeilingAt: number,
	seen: boolean,
	leaving: boolean,
	leaveAt: number,
	awayDir: Vector3,
	publishAt: number,
	publishedSpot: Vector3?,
}

type Suspect = {
	player: Player,
	units: { Unit },
	heli: Heli?,
	bustTime: number,
	bustShown: number,
	lastCopHit: number,
	nextSpawnAt: number,
	valid: boolean,
	pos: Vector3,
	vel: Vector3,
	look: Vector3,
	onFoot: boolean,
	topSpeed: number, -- top speed of the car the suspect drives (0 on foot)
	safe: boolean,
	plotIndex: number?,
	lastSeenAt: number, -- any unit / heli / officer had the suspect in view (search mode after SEARCH_AFTER)
}

-- STATE -------------------------------------------------------------------------------------------------

local suspects: { [Player]: Suspect } = {}
local units: { [number]: Unit } = {}
local unitByCar: { [any]: Unit } = {}
local helis: { Heli } = {}
local nextUnitId = 0
local losParams: RaycastParams? = nil
local effectsFolder: Instance? = nil
local spawnArgMode: string? = nil -- "def" | "id" once we know which VehicleService.spawn accepts
local warnedNoController = false
local searchRng = Random.new()
local bustSources: { (Player) -> boolean } = {} -- extra "an officer is right here" checks (on-foot officers)

local systemCache: { [string]: any } = {}
local function sys(name: string): any
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local inst = script.Parent and script.Parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok then
			systemCache[name] = mod
			return mod
		end
		warn(("[PoliceService] could not load %s: %s"):format(name, tostring(mod)))
	end
	return nil
end

local VehicleControllerModule: any = nil
local function getVehicleController(): any
	if VehicleControllerModule then
		return VehicleControllerModule
	end
	local folder = Shared:FindFirstChild("Vehicle")
	local m = folder and folder:FindFirstChild("VehicleController")
	if m and m:IsA("ModuleScript") then
		local ok, mod = pcall(require, m :: any)
		if ok then
			VehicleControllerModule = mod
			return mod
		end
		warn("[PoliceService] VehicleController failed to load: " .. tostring(mod))
	end
	return nil
end

-- MATH HELPERS ------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function sign(x: number): number
	return if x < 0 then -1 else 1
end

local function lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end

local function rotateY(v: Vector3, degrees: number): Vector3
	local r = math.rad(degrees)
	local c, s = math.cos(r), math.sin(r)
	return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end

-- PURE AI HELPERS (tested) ------------------------------------------------------------------------------

-- Vision cone test (flat), see PoliceAim.inCone.
function PoliceService._inCone(pos: Vector3, look: Vector3, cone: PoliceConfig.Cone, target: Vector3): boolean
	return PoliceAim.inCone(pos, look, cone, target)
end

-- Steering toward a direction. Returns (steer -1..1, signed angle in degrees). Positive = target is to the
-- right of fwd (SteerFloat +1 = right turn).
function PoliceService._steerToward(fwd: Vector3, toTarget: Vector3): (number, number)
	local f = flat(fwd)
	local t = flat(toTarget)
	if f.Magnitude < 1e-4 or t.Magnitude < 1e-4 then
		return 0, 0
	end
	f = f.Unit
	local right = Vector3.new(-f.Z, 0, f.X)
	local angle = math.deg(math.atan2(t:Dot(right), t:Dot(f)))
	return math.clamp(angle / STEER_FULL_ANGLE, -1, 1), angle
end

-- Which road strips contain pos. Returns (xLine, zLine):
--   xLine: pos is on the road running along Z at x = xLine * S
--   zLine: pos is on the road running along X at z = zLine * S
-- Both non-nil = inside an intersection. Both nil = off-road.
function PoliceService._roadLines(pos: Vector3): (number?, number?)
	local lim = EXT + ROAD_HALF
	if math.abs(pos.X) > lim or math.abs(pos.Z) > lim then
		return nil, nil
	end
	local xl = math.clamp(math.round(pos.X / S), LMIN, LMAX)
	local zl = math.clamp(math.round(pos.Z / S), LMIN, LMAX)
	local onZRoad = math.abs(pos.X - xl * S) <= ROAD_HALF
	local onXRoad = math.abs(pos.Z - zl * S) <= ROAD_HALF
	return (if onZRoad then xl else nil), (if onXRoad then zl else nil)
end

-- Nearest drivable point on the road grid (kept ANCHOR_INSET inside the strip edge). Off-map points are
-- clamped onto the ring road first.
function PoliceService._roadAnchor(pos: Vector3): Vector3
	local x = math.clamp(pos.X, -EXT, EXT)
	local z = math.clamp(pos.Z, -EXT, EXT)
	local xl = math.round(x / S)
	local zl = math.round(z / S)
	local dx = x - xl * S
	local dz = z - zl * S
	local lim = ROAD_HALF - ANCHOR_INSET
	local onZ = math.abs(dx) <= ROAD_HALF
	local onX = math.abs(dz) <= ROAD_HALF
	if onZ and onX then
		-- inside an intersection: already drivable
		return Vector3.new(x, MapConfig.ROAD_Y, z)
	end
	if onZ then
		x = xl * S + math.clamp(dx, -lim, lim)
	elseif onX then
		z = zl * S + math.clamp(dz, -lim, lim)
	elseif math.abs(dx) <= math.abs(dz) then
		x = xl * S + sign(dx) * lim
	else
		z = zl * S + sign(dz) * lim
	end
	return Vector3.new(x, MapConfig.ROAD_Y, z)
end

-- Routing cost of driving from pos to intersection W=(wx, wz) and on to the road anchor tA (Manhattan + turn
-- costs). A leg that is not roughly straight ahead costs extra the faster we go: you can't turn at 100 studs/s.
local function routeCost(
	pos: Vector3,
	wx: number,
	wz: number,
	tA: Vector3,
	tx: number?,
	tz: number?,
	f: Vector3?,
	speed: number
): number
	local legX, legZ = wx - pos.X, wz - pos.Z
	local leg = math.abs(legX) + math.abs(legZ)
	local rest = math.abs(wx - tA.X) + math.abs(wz - tA.Z)
	local cost = leg + rest + leg * 0.001
	-- from W, is the target on one of W's roads (one more leg) or does it need another turn?
	local wxl, wzl = math.round(wx / S), math.round(wz / S)
	if not ((tx ~= nil and tx == wxl) or (tz ~= nil and tz == wzl)) then
		cost += TURN_PENALTY
	end
	if f then
		local len = math.sqrt(legX * legX + legZ * legZ)
		local d = if len > 1e-3 then (legX * f.X + legZ * f.Z) / len else 1
		if d < 0.7 then
			cost += TURN_NOW_BASE + math.max(0, speed) * TURN_NOW_PER_SPEED
			if speed > CORNER_SPEED + 12 then
				cost += LATE_TURN_PENALTY -- far too fast to turn here: physically impossible
			end
		elseif speed > CORNER_SPEED then
			-- a turn at W we can't brake for in time: carry on and take a later junction instead
			local need = (speed * speed - CORNER_SPEED * CORNER_SPEED) / (2 * PLAN_BRAKE_DECEL) + TURN_IN_DIST * 0.5
			if len < need then
				cost += LATE_TURN_PENALTY
			end
		end
		if d < 0 then
			cost += BEHIND_PENALTY
		end
	end
	return cost
end

local function isIntersection(p: Vector3): boolean
	return math.abs(p.X - math.round(p.X / S) * S) < 0.5 and math.abs(p.Z - math.round(p.Z / S) * S) < 0.5
end

-- Cheapest junction on the road(s) through pos (xLine px / zLine pz), excluding the junction pos is inside.
local function bestJunction(
	pos: Vector3,
	px: number?,
	pz: number?,
	tA: Vector3,
	tx: number?,
	tz: number?,
	f: Vector3?,
	v: number
): (Vector3?, number)
	local best: Vector3? = nil
	local bestCost = math.huge
	for pass = 1, 2 do
		local line = if pass == 1 then px else pz
		if line ~= nil then
			for c = LMIN, LMAX do
				local wx = if pass == 1 then line * S else c * S
				local wz = if pass == 1 then c * S else line * S
				if not (math.abs(pos.X - wx) <= ROAD_HALF and math.abs(pos.Z - wz) <= ROAD_HALF) then
					local cost = routeCost(pos, wx, wz, tA, tx, tz, f, v)
					if cost < bestCost then
						bestCost = cost
						best = Vector3.new(wx, MapConfig.ROAD_Y, wz)
					end
				end
			end
		end
	end
	return best, bestCost
end

-- Grid routing. Returns (waypoint, isTurn). The straight segment pos -> waypoint always stays on one road strip
-- (or, when pos is off-road, it is the short hop back onto the nearest road). isTurn = waypoint is an
-- intersection where the car must change roads (slow down for it); false = waypoint is the target itself.
-- Optional: fwd + speed make turning right now (or turning around) cost more; keep = the turn waypoint chosen
-- last tick, kept unless another route is clearly better (stops near-tied routes flip-flopping mid-junction).
function PoliceService._nextWaypoint(
	pos: Vector3,
	target: Vector3,
	fwd: Vector3?,
	speed: number?,
	keep: Vector3?
): (Vector3, boolean)
	local tA = PoliceService._roadAnchor(target)
	local px, pz = PoliceService._roadLines(pos)
	if px == nil and pz == nil then
		return PoliceService._roadAnchor(pos), true
	end
	local tx, tz = PoliceService._roadLines(tA)
	if (px ~= nil and px == tx) or (pz ~= nil and pz == tz) then
		return tA, false
	end

	local f: Vector3? = nil
	if fwd then
		local ff = flat(fwd)
		f = if ff.Magnitude > 1e-3 then ff.Unit else nil
	end
	local v = speed or 0
	local best, bestCost = bestJunction(pos, px, pz, tA, tx, tz, f, v)
	if best == nil then
		return tA, false
	end
	-- Collapse straight-through junctions so the waypoint is where we really turn (no needless corner braking).
	local dir = flat(best - pos)
	if dir.Magnitude > 1e-3 then
		dir = dir.Unit
		for _ = 1, LMAX - LMIN do
			local bx, bz = math.round(best.X / S), math.round(best.Z / S)
			if (tx ~= nil and tx == bx) or (tz ~= nil and tz == bz) then
				break -- the target's road: a real turn here
			end
			local nxt = bestJunction(best, bx, bz, tA, tx, tz, dir, v)
			if nxt == nil or flat(nxt - best).Unit:Dot(dir) < 0.99 then
				break
			end
			best = nxt
		end
		bestCost = routeCost(pos, best.X, best.Z, tA, tx, tz, f, v)
	end
	if keep and keep ~= best and isIntersection(keep) then
		local onKeepRoad = (px ~= nil and math.abs(keep.X - px * S) < 0.5)
			or (pz ~= nil and math.abs(keep.Z - pz * S) < 0.5)
		local insideKeep = math.abs(pos.X - keep.X) <= ROAD_HALF and math.abs(pos.Z - keep.Z) <= ROAD_HALF
		if
			onKeepRoad
			and not insideKeep
			and routeCost(pos, keep.X, keep.Z, tA, tx, tz, f, v) <= bestCost + ROUTE_HYSTERESIS
		then
			return Vector3.new(keep.X, MapConfig.ROAD_Y, keep.Z), true
		end
	end
	return best :: Vector3, true
end

function PoliceService._newStuck(): Stuck
	return { stuckTime = 0, reverseUntil = -math.huge, reverseSteer = 1, recoverThrottle = -1, count = 0 }
end

-- Unstuck state machine: throttle applied (either way) but speed < STUCK_SPEED for STUCK_TIME -> drive the other
-- way with the opposite steer for REVERSE_TIME. Returns true while recovering (caller then uses
-- throttle = s.recoverThrottle, steer = s.reverseSteer). Coasting / holding (throttle 0) never counts.
function PoliceService._updateStuck(
	s: Stuck,
	speed: number,
	throttle: number,
	steer: number,
	dt: number,
	now: number
): boolean
	if now < s.reverseUntil then
		return true
	end
	if math.abs(throttle) > 0.5 and speed < STUCK_SPEED then
		s.stuckTime += dt
	else
		s.stuckTime = 0
	end
	if s.stuckTime >= PoliceConfig.STUCK_TIME then
		s.stuckTime = 0
		s.reverseUntil = now + REVERSE_TIME
		s.recoverThrottle = if throttle > 0 then -1 else 1
		if math.abs(steer) < 0.2 then
			-- no preferred side: alternate so repeated attempts try both ways
			s.reverseSteer = if s.count % 2 == 0 then 1 else -1
		else
			s.reverseSteer = -sign(steer)
		end
		s.count += 1
		return true
	end
	return false
end

-- Did the player's car ram the cop (not the other way round)? Returns (isRam, relativeSpeed).
function PoliceService._isRam(
	playerPos: Vector3,
	playerVel: Vector3,
	copPos: Vector3,
	copVel: Vector3
): (boolean, number)
	local d = flat(copPos - playerPos)
	local rel = flat(playerVel - copVel).Magnitude
	if d.Magnitude < 0.01 then
		return false, rel
	end
	local dir = d.Unit
	local playerClosing = flat(playerVel):Dot(dir)
	local copClosing = flat(copVel):Dot(-dir)
	return rel > RAM_SPEED and playerClosing > 10 and playerClosing > copClosing, rel
end

-- Top speed (studs/s) of a VehicleService car record: its def, else the Cars config by carId; 0 when unknown.
function PoliceService._carTopSpeed(car: any): number
	if typeof(car) ~= "table" then
		return 0
	end
	local def = car.def
	if typeof(def) ~= "table" and typeof(car.carId) == "string" then
		def = Cars.get(car.carId)
	end
	local top = if typeof(def) == "table" then def.topSpeed else nil
	if typeof(top) ~= "number" or top ~= top or top <= 0 then
		return 0
	end
	return top
end

-- SpeedMultiplier for a chasing unit: the per-star base, raised so cruisers keep up with fast getaway cars
-- (suspect top speed vs a cruiser's, scaled 85% at 1 star .. 105% at 5 stars), plus the catch-up bonus while the
-- unit is far behind and out of sight. Rounded so the replicated attribute only changes when it means something.
function PoliceService._unitSpeedMult(stars: number, suspectTopSpeed: number, farBehind: boolean): number
	local s = math.clamp(math.floor(if stars == stars then stars else 1), 1, #SPEED_MULT_BY_STARS)
	local match = 0
	if suspectTopSpeed == suspectTopSpeed and suspectTopSpeed > 0 then
		match = suspectTopSpeed / Cars.Police.topSpeed * (SUSPECT_MATCH_BASE + SUSPECT_MATCH_PER_STAR * s)
	end
	local mult = math.max(SPEED_MULT_BY_STARS[s], match) + (if farBehind then CATCHUP_BONUS else 0)
	return math.min(math.floor(mult * 100 + 0.5) / 100, MAX_SPEED_MULT)
end

-- Chopper top speed: HELI_MAX_SPEED, or 90% of a faster suspect car's top speed.
function PoliceService._heliMaxSpeed(suspectTopSpeed: number): number
	if suspectTopSpeed ~= suspectTopSpeed or suspectTopSpeed <= 0 then
		return HELI_MAX_SPEED
	end
	return math.max(HELI_MAX_SPEED, suspectTopSpeed * HELI_SUSPECT_SPEED)
end

-- Fair share of the global unit cap. desired[i] = units suspect i wants (ordered by priority).
function PoliceService._allocateUnits(desired: { number }, cap: number): { number }
	local alloc = table.create(#desired, 0)
	local remaining = math.max(0, math.floor(cap))
	local progressed = true
	while remaining > 0 and progressed do
		progressed = false
		for i, want in desired do
			if remaining <= 0 then
				break
			end
			if alloc[i] < want then
				alloc[i] += 1
				remaining -= 1
				progressed = true
			end
		end
	end
	return alloc
end

-- Lane CFrame nearest p, facing (along its road) toward `towards`.
function PoliceService._orientedLane(p: Vector3, towards: Vector3): CFrame
	local lane = MapLayout.nearestLane(p)
	local look = lane.LookVector
	local lp = lane.Position
	local axis: MapLayout.Axis = if math.abs(look.X) > 0.5 then "X" else "Z"
	local line, along, delta
	if axis == "X" then
		line = math.round(lp.Z / S)
		along = lp.X
		delta = towards.X - along
	else
		line = math.round(lp.X / S)
		along = lp.Z
		delta = towards.Z - along
	end
	return MapLayout.laneCFrame(axis, line, along, if delta >= 0 then 1 else -1)
end

-- Candidate spawn points around the suspect, best first: straight behind them, then fanning out, ahead last.
function PoliceService._spawnCandidates(origin: Vector3, behind: Vector3, distances: { number }): { Vector3 }
	local b = flat(behind)
	if b.Magnitude < 1e-3 then
		b = Vector3.new(0, 0, 1)
	end
	b = b.Unit
	local out = {}
	for _, angle in { 0, 30, -30, 60, -60, 95, -95, 135, -135, 180 } do
		local dir = rotateY(b, angle)
		for _, d in distances do
			table.insert(out, origin + dir * d)
		end
	end
	return out
end

-- WORLD QUERIES -----------------------------------------------------------------------------------------

local function refreshLosFilter()
	local params = losParams
	if not params then
		return
	end
	local list: { Instance } = {}
	-- NPCs: pedestrians (a knocked-down one lying in the road) never block a cop's view
	for _, name in { "Vehicles", "Effects", "Dealership", "NPCs" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	params.FilterDescendantsInstances = list
end

local function hasLineOfSight(a: Vector3, b: Vector3): boolean
	local params = losParams
	if not params then
		return true
	end
	local dir = b - a
	if dir.Magnitude < 1 then
		return true
	end
	return Workspace:Raycast(a, dir, params) == nil
end

local function anyPlayerNear(pos: Vector3, radius: number): boolean
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and flatDist(root.Position, pos) <= radius then
			return true
		end
	end
	return false
end

local function getSuspect(player: Player): Suspect
	local st = suspects[player]
	if not st then
		st = {
			player = player,
			units = {},
			heli = nil,
			bustTime = 0,
			bustShown = -1,
			lastCopHit = -math.huge,
			nextSpawnAt = 0,
			valid = false,
			pos = Vector3.zero,
			vel = Vector3.zero,
			look = Vector3.new(0, 0, -1),
			onFoot = true,
			topSpeed = 0,
			safe = false,
			plotIndex = nil,
			lastSeenAt = os.clock(),
		}
		suspects[player] = st
	end
	return st
end

local function updateSuspectInfo(st: Suspect)
	local player = st.player
	st.valid = false
	local VehicleService = sys("VehicleService")
	local car: any = nil
	if VehicleService and typeof(VehicleService.getDriving) == "function" then
		local ok, res = pcall(VehicleService.getDriving, player)
		if ok then
			car = res
		end
	end
	local chassis = car and car.chassis
	st.topSpeed = 0
	if typeof(chassis) == "Instance" and chassis:IsA("BasePart") and chassis.Parent then
		st.pos = chassis.Position
		st.vel = chassis.AssemblyLinearVelocity
		st.look = chassis.CFrame.LookVector
		st.onFoot = false
		st.valid = true
		st.topSpeed = PoliceService._carTopSpeed(car)
	else
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			st.pos = root.Position
			st.vel = root.AssemblyLinearVelocity
			st.look = root.CFrame.LookVector
			st.onFoot = true
			st.valid = true
		end
	end
	local plot = player:GetAttribute("PlotIndex")
	st.plotIndex = if typeof(plot) == "number" then plot else nil
	st.safe = st.valid and st.plotIndex ~= nil and MapLayout.plotAt(st.pos) == st.plotIndex
end

local function setBustProgress(st: Suspect, value: number)
	local v = math.clamp(math.floor(value * 100 + 0.5) / 100, 0, 1)
	if v ~= st.bustShown then
		st.bustShown = v
		pcall(function()
			st.player:SetAttribute("BustProgress", v)
		end)
	end
end

-- UNIT LIFECYCLE ----------------------------------------------------------------------------------------

local function hasHumanoid(npc: Model?): boolean
	return npc ~= nil and npc:FindFirstChildOfClass("Humanoid") ~= nil
end

local function removeUnit(unit: Unit)
	if not unit.alive then
		return
	end
	unit.alive = false
	units[unit.id] = nil
	unitByCar[unit.car] = nil
	local st = suspects[unit.suspect]
	if st then
		local idx = table.find(st.units, unit)
		if idx then
			table.remove(st.units, idx)
		end
	end
	pcall(function()
		unit.trove:Destroy()
	end)
	if unit.controller and typeof(unit.controller.destroy) == "function" then
		pcall(unit.controller.destroy, unit.controller)
	end
end

local function despawnUnit(unit: Unit, reason: string)
	local car = unit.car
	removeUnit(unit)
	local VehicleService = sys("VehicleService")
	local ok = false
	if VehicleService and typeof(VehicleService.destroy) == "function" then
		ok = pcall(VehicleService.destroy, car, reason)
	end
	if not ok and unit.model.Parent then
		unit.model:Destroy()
	end
end

local function sendAway(unit: Unit, now: number)
	if unit.mode ~= "chase" then
		return
	end
	unit.mode = "leaving"
	unit.leaveAt = now + LEAVE_TIME
	unit.model:SetAttribute("Siren", false)
end

local function markWrecked(unit: Unit, now: number)
	if unit.mode == "wrecked" then
		return
	end
	unit.mode = "wrecked"
	unit.wreckedAt = now
	local input = unit.input
	input.throttle, input.steer, input.handbrake, input.nitro = 0, 0, false, false
	if unit.controller then
		pcall(unit.controller.setInput, unit.controller, input)
	end
	unit.model:SetAttribute("Siren", false)
	local st = suspects[unit.suspect]
	if st then
		st.nextSpawnAt = math.max(st.nextSpawnAt, now + WRECK_RESPAWN_DELAY)
	end
	-- the officer gets yeeted out of the wreck (comic ragdoll). A block dummy (closed shell) hands its seat to a
	-- real humanoid just for the gag; without one the dummy stays in its seat.
	local npc = unit.npc
	local NPCService = sys("NPCService")
	if npc and npc.Parent and not hasHumanoid(npc) and NPCService and typeof(NPCService.spawnDriver) == "function" then
		local seat = unit.car.seat
		if typeof(seat) == "Instance" and seat:IsA("BasePart") and seat.Parent then
			local ok, human = pcall(NPCService.spawnDriver, seat, "police")
			if ok and typeof(human) == "Instance" and human:IsA("Model") then
				npc:Destroy()
				npc = human
				unit.npc = human
			end
		end
	end
	if npc and npc.Parent and hasHumanoid(npc) then
		local eject = NPCService and (NPCService.eject or NPCService.ejectComic)
		if typeof(eject) == "function" then
			unit.npc = nil
			local fling = unit.chassis.AssemblyLinearVelocity * 0.5 + unit.chassis.CFrame.RightVector * 30
			pcall(eject, npc, fling)
		end
	end
end

local function damageUnit(unit: Unit, amount: number, now: number)
	if amount <= 0 then
		return
	end
	local VehicleService = sys("VehicleService")
	if VehicleService and typeof(VehicleService.damage) == "function" then
		pcall(VehicleService.damage, unit.car, amount, nil)
	else
		unit.health -= amount
		unit.model:SetAttribute("Health", math.max(0, unit.health))
		if unit.health <= 0 then
			markWrecked(unit, now)
		end
	end
end

-- BUSTED officer spot (ground-level CFrame facing the suspect): BUST_OFFICER_OFFSET from the suspect toward the
-- nearest cruiser (it "stepped out" of it) when one is within BUST_OFFICER_UNIT_RANGE, else at the suspect's right.
function PoliceService._bustOfficerSpot(suspectPos: Vector3, suspectLook: Vector3, unitPos: Vector3?): CFrame
	local toward: Vector3
	local d = if unitPos then flatDist(unitPos, suspectPos) else math.huge
	if unitPos and d > 1 and d <= BUST_OFFICER_UNIT_RANGE then
		toward = flat(unitPos - suspectPos).Unit
	else
		local look = flat(suspectLook)
		look = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)
		toward = look:Cross(Vector3.yAxis)
	end
	local p = suspectPos + toward * BUST_OFFICER_OFFSET
	return CFrame.lookAt(p, Vector3.new(suspectPos.X, p.Y, suspectPos.Z))
end

-- Top of the ground under `p` (characters, cars and NPCs ignored).
local function groundBelow(p: Vector3): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true
	local exclude: { Instance } = {}
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(exclude, pl.Character)
		end
	end
	for _, name in { "Vehicles", "NPCs", "Effects" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(p + Vector3.new(0, 6, 0), Vector3.new(0, -40, 0), params)
	return if hit then hit.Position.Y else nil
end

-- BUSTED moment: an officer steps out beside the busted player (visual only, gone after BUST_OFFICER_TIME).
local function onBusted(player: Player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return -- died-while-wanted bust: no body to stand next to
	end
	local NPCService = sys("NPCService")
	if not NPCService or typeof(NPCService.spawnOfficerAt) ~= "function" then
		return
	end
	local pos = root.Position
	local unitPos: Vector3? = nil
	local best = math.huge
	local st = suspects[player]
	if st then
		for _, u in st.units do
			if u.alive and u.chassis.Parent then
				local d = flatDist(u.chassis.Position, pos)
				if d < best then
					best, unitPos = d, u.chassis.Position
				end
			end
		end
	end
	local spot = PoliceService._bustOfficerSpot(pos, root.CFrame.LookVector, unitPos)
	local y = groundBelow(spot.Position) or (pos.Y - 3)
	NPCService.spawnOfficerAt(spot + Vector3.new(0, y - spot.Position.Y, 0), BUST_OFFICER_TIME)
end

-- Is `pos` at least SPAWN_CLEARANCE (flat) away from every blocker position?
function PoliceService._isClearOf(pos: Vector3, blockers: { Vector3 }): boolean
	for _, b in blockers do
		if flatDist(b, pos) < SPAWN_CLEARANCE then
			return false
		end
	end
	return true
end

-- Positions of every police unit and every vehicle, gathered once per lane search (one VehicleService.all() call
-- instead of one per candidate lane).
local function collectBlockers(): { Vector3 }
	local list: { Vector3 } = {}
	for _, u in units do
		if u.chassis.Parent then
			table.insert(list, u.chassis.Position)
		end
	end
	local VehicleService = sys("VehicleService")
	if VehicleService and typeof(VehicleService.all) == "function" then
		local ok, cars = pcall(VehicleService.all)
		if ok and typeof(cars) == "table" then
			for _, car in cars do
				local ch = car.chassis
				if typeof(ch) == "Instance" and ch:IsA("BasePart") then
					table.insert(list, ch.Position)
				end
			end
		end
	end
	return list
end

-- Finds a lane CFrame between minD and maxD from the suspect, preferably behind them and out of their view.
local function findSpawnLane(st: Suspect, minD: number, maxD: number, allowHQ: boolean): CFrame?
	local base = flat(st.vel)
	if base.Magnitude < 8 then
		base = flat(st.look)
	end
	if base.Magnitude < 0.1 then
		base = Vector3.new(0, 0, -1)
	end
	local behind = -base.Unit
	local lanes: { CFrame } = {}
	if allowHQ then
		for _, cf in MapLayout.policeSpawns() do
			table.insert(lanes, PoliceService._orientedLane(cf.Position, st.pos))
		end
	end
	local mid = (minD + maxD) / 2
	for _, p in PoliceService._spawnCandidates(st.pos, behind, { mid, minD + 10, maxD - 10 }) do
		table.insert(lanes, PoliceService._orientedLane(p, st.pos))
	end
	local eye = st.pos + UP3
	local blockers: { Vector3 }? = nil -- collected lazily, once, when the first lane passes the cheap checks
	for pass = 1, 2 do
		for _, lane in lanes do
			local lp = lane.Position
			local d = flatDist(lp, st.pos)
			if d < minD * 0.85 or d > maxD or math.abs(lp.X) > EXT + 1 or math.abs(lp.Z) > EXT + 1 then
				continue
			end
			if not blockers then
				blockers = collectBlockers()
			end
			-- clearance before the line-of-sight raycast: the ray only runs for lanes we could actually use
			if
				PoliceService._isClearOf(lp, blockers :: { Vector3 })
				and (pass == 2 or not hasLineOfSight(eye, lp + UP3))
			then
				return lane
			end
		end
	end
	return nil
end

local function teleportUnit(unit: Unit, lane: CFrame, speed: number, now: number)
	local ride = unit.model:GetAttribute("RideHeight")
	local h = if typeof(ride) == "number" then ride else 2
	unit.model:PivotTo(lane * CFrame.new(0, h + 0.3, 0))
	local chassis = unit.chassis
	chassis.AssemblyLinearVelocity = lane.LookVector * speed
	chassis.AssemblyAngularVelocity = Vector3.zero
	unit.lastVel = chassis.AssemblyLinearVelocity
	unit.lastTeleport = now
	unit.stuck = PoliceService._newStuck()
	unit.routeWp = nil
end

local function rubberBand(unit: Unit, st: Suspect, now: number): boolean
	if not st.valid then
		return false
	end
	local sight = PoliceConfig.SIGHT_RANGE
	local lane = findSpawnLane(st, sight + 30, sight + 120, false)
	if not lane then
		return false
	end
	teleportUnit(unit, lane, math.min(flat(st.vel).Magnitude, 80), now)
	unit.lastRubberBand = now
	return true
end

local function trySpawnCar(VehicleService: any, lane: CFrame): any
	local attempts: { string } = if spawnArgMode then { spawnArgMode } else { "def", "id" }
	for _, mode in attempts do
		local carArg: any = if mode == "def" then Cars.Police else Cars.Police.id
		local ok, car = pcall(VehicleService.spawn, carArg, "None", lane, "Police")
		if ok and typeof(car) == "table" and car.model and car.chassis then
			spawnArgMode = mode
			return car
		end
		if not ok and spawnArgMode == nil then
			warn(("[PoliceService] VehicleService.spawn(%s) failed: %s"):format(mode, tostring(car)))
		end
	end
	return nil
end

local onUnitTouched: (Unit, BasePart) -> ()

-- Would a seated officer in this cruiser be seen? (NPCService.driverVisible: not in the closed police_unit shell)
local function driverVisible(NPCService: any, model: Model): boolean
	if typeof(NPCService.driverVisible) ~= "function" then
		return true
	end
	local ok, visible = pcall(NPCService.driverVisible, model)
	return not ok or visible == true
end

-- Seats an officer in a cruiser: NPCService's police humanoid where it can be seen, else (allowDummy)
-- TrafficService's block dummy in police blue. nil when neither is available.
local function attachOfficer(car: any, model: Model, chassis: BasePart, allowDummy: boolean): Model?
	local seat = car.seat
	if typeof(seat) ~= "Instance" or not seat:IsA("BasePart") then
		seat = model:FindFirstChild("DriverSeat")
	end
	if typeof(seat) ~= "Instance" or not seat:IsA("BasePart") or seat.Parent == nil then
		return nil
	end
	local NPCService = sys("NPCService")
	if NPCService and typeof(NPCService.spawnDriver) == "function" and driverVisible(NPCService, model) then
		local ok, npc = pcall(NPCService.spawnDriver, seat, "police")
		if ok and typeof(npc) == "Instance" and npc:IsA("Model") then
			return npc
		end
	end
	if not allowDummy then
		return nil
	end
	local TrafficService = sys("TrafficService")
	if TrafficService and typeof(TrafficService.attachDummy) == "function" then
		local ok, npc = pcall(TrafficService.attachDummy, model, seat, chassis, TrafficService.POLICE_PALETTE)
		if ok and typeof(npc) == "Instance" and npc:IsA("Model") then
			return npc
		end
	end
	return nil
end

-- Swap block-dummy officers (or empty seats) for NPCService humanoids: at most `limit` per call, only in cruisers
-- whose officer can be seen (not a closed shell) and that are out of every player's close view (no pop-in).
local function upgradeOfficers(limit: number)
	local NPCService = sys("NPCService")
	if not NPCService or typeof(NPCService.isReady) ~= "function" or not NPCService.isReady() then
		return
	end
	local n = 0
	for _, unit in units do
		if n >= limit then
			break
		end
		local old = unit.npc
		if not unit.alive or unit.mode == "wrecked" or hasHumanoid(old) or not unit.model.Parent then
			continue
		end
		if not driverVisible(NPCService, unit.model) then
			continue
		end
		if anyPlayerNear(unit.chassis.Position, OFFICER_UPGRADE_HIDDEN_DIST) then
			continue
		end
		local human = attachOfficer(unit.car, unit.model, unit.chassis, false)
		if not human then
			break -- not ready / over budget
		end
		unit.npc = human
		if old then
			old:Destroy()
		end
		n += 1
	end
end

local function spawnUnit(st: Suspect, now: number): boolean
	local VehicleService = sys("VehicleService")
	if not VehicleService or typeof(VehicleService.spawn) ~= "function" then
		return false
	end
	local VehicleController = getVehicleController()
	if not VehicleController then
		if not warnedNoController then
			warnedNoController = true
			warn("[PoliceService] Shared.Vehicle.VehicleController missing; police disabled")
		end
		return false
	end
	local lane = findSpawnLane(st, SPAWN_MIN_DIST, SPAWN_MAX_DIST, true)
	if not lane then
		return false
	end
	local car = trySpawnCar(VehicleService, lane)
	if not car then
		return false
	end
	local model: Model = car.model
	local chassis: BasePart = car.chassis
	chassis.Anchored = false
	pcall(chassis.SetNetworkOwner, chassis, nil)
	local okC, controller =
		pcall(VehicleController.new, model, Cars.Police, { isServer = true, nitroSeconds = POLICE_NITRO_SECONDS })
	if not okC or controller == nil then
		warn("[PoliceService] VehicleController.new failed: " .. tostring(controller))
		pcall(VehicleService.destroy, car, "error")
		return false
	end
	if not CollectionService:HasTag(model, "Police") then
		CollectionService:AddTag(model, "Police")
	end
	model:SetAttribute("SuspectUserId", st.player.UserId)
	model:SetAttribute("Siren", true)
	if typeof(car.data) == "table" then
		car.data.police = { suspectUserId = st.player.UserId }
	end
	chassis.AssemblyLinearVelocity = lane.LookVector * SPAWN_SPEED

	nextUnitId += 1
	local unit: Unit = {
		id = nextUnitId,
		suspect = st.player,
		car = car,
		model = model,
		chassis = chassis,
		controller = controller,
		trove = Trove.new(),
		input = { throttle = 1, steer = 0, handbrake = false, nitro = false },
		role = #st.units + 1,
		mode = "chase",
		alive = true,
		broken = false,
		leaveAt = 0,
		wreckedAt = 0,
		spawnedAt = now,
		lastTeleport = now,
		dist = flatDist(chassis.Position, st.pos),
		hasLOS = false,
		seen = false,
		lastLosAt = now,
		lastRubberBand = now,
		lastVel = chassis.AssemblyLinearVelocity,
		routeWp = nil,
		searchPoint = nil,
		searchPointAt = 0,
		health = VehicleConfig.MAX_HEALTH,
		speedMult = 1,
		stuck = PoliceService._newStuck(),
		npc = attachOfficer(car, model, chassis, true),
	}
	unit.trove:Connect(chassis.Touched, function(hit: BasePart)
		onUnitTouched(unit, hit)
	end)
	units[unit.id] = unit
	unitByCar[car] = unit
	table.insert(st.units, unit)
	return true
end

-- RAMMING -----------------------------------------------------------------------------------------------

onUnitTouched = function(unit: Unit, hit: BasePart)
	if not unit.alive or unit.mode == "wrecked" or not hit or not hit.Parent then
		return
	end
	local model = hit:FindFirstAncestorOfClass("Model")
	if not model or model == unit.model then
		return
	end
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if not vehicles or model.Parent ~= vehicles then
		return
	end
	local VehicleService = sys("VehicleService")
	if not VehicleService or typeof(VehicleService.fromModel) ~= "function" then
		return
	end
	local ok, car = pcall(VehicleService.fromModel, model)
	if not ok or typeof(car) ~= "table" then
		return
	end
	local driver = car.driver
	if typeof(driver) ~= "Instance" or not driver:IsA("Player") or driver.Parent ~= Players then
		return
	end
	local pc = car.chassis
	if typeof(pc) ~= "Instance" or not pc:IsA("BasePart") then
		return
	end
	local st = getSuspect(driver)
	local now = os.clock()
	if now - st.lastCopHit < RAM_COOLDOWN then
		return
	end
	local isRam = PoliceService._isRam(
		pc.Position,
		pc.AssemblyLinearVelocity,
		unit.chassis.Position,
		unit.chassis.AssemblyLinearVelocity
	)
	if not isRam then
		return
	end
	st.lastCopHit = now
	local before = WantedService.getStars(driver)
	WantedService.addHeat(driver, PoliceConfig.Heat.copHit, "copHit")
	if WantedService.getStars(driver) > before then
		pcall(Net.fireClient, "Notify", driver, "warning", "You rammed a police car.", 2.5)
	end
end

-- AI ----------------------------------------------------------------------------------------------------

local function applyInput(unit: Unit, throttle: number, steer: number, handbrake: boolean, nitro: boolean)
	local input = unit.input
	input.throttle = throttle
	input.steer = steer
	input.handbrake = handbrake
	input.nitro = nitro
	local controller = unit.controller
	if controller and not unit.broken then
		local ok, err = pcall(controller.setInput, controller, input)
		if not ok then
			unit.broken = true
			warn("[PoliceService] controller:setInput failed: " .. tostring(err))
		end
	end
end

-- Pure driving law toward an aim point: steering, brake-on-sharp-angle, corner speed, handbrake slides.
-- Returns (throttle, steer, handbrake, signedAngleDeg).
function PoliceService._drive(
	fwd: Vector3,
	fwdSpeed: number,
	toAim: Vector3,
	cornering: boolean,
	wpDist: number
): (number, number, boolean, number)
	local steer, angle = PoliceService._steerToward(fwd, toAim)
	local absAngle = math.abs(angle)
	if absAngle > UTURN_ANGLE then
		-- police K-turn: a forward U-turn doesn't fit a 40-stud road, so brake, then back up on opposite lock
		-- (the nose swings toward the aim) until it is in front of us
		if fwdSpeed > KTURN_SPEED then
			-- brake in a straight line from speed (steering while braking hard slides us off the road)
			return -1, if fwdSpeed > KTURN_STRAIGHT_BRAKE_SPEED then 0 else steer, false, angle
		end
		if flat(toAim).Magnitude < BACKUP_RANGE then
			return -1, sign(angle), false, angle -- close behind us: just back onto it
		end
		return -1, -sign(angle), false, angle
	end
	-- speed limit for the turn we are in / approaching
	local limit = math.huge
	if absAngle > TURN_ANGLE then
		limit = CORNER_SPEED
	end
	-- don't orbit a close aim point: reaching it needs radius R = d / (2 sin a); yaw rate ~2.2 rad/s => v <= ~2R
	local d = flat(toAim).Magnitude
	local sinA = math.sin(math.rad(math.min(absAngle, 90)))
	if sinA > 0.17 then
		limit = math.min(limit, math.max(MIN_TURN_SPEED, RADIUS_SPEED_FACTOR * d / (2 * sinA)))
	end
	if cornering then
		-- slow to CORNER_SPEED by TURN_IN_DIST before the intersection we will turn at
		local approach = math.sqrt(CORNER_SPEED * CORNER_SPEED + 2 * CORNER_DECEL * math.max(0, wpDist - TURN_IN_DIST))
		limit = math.min(limit, approach)
	end
	local throttle = 1
	if fwdSpeed > limit + 6 then
		throttle = -1
	elseif fwdSpeed > limit then
		throttle = 0
	end
	local handbrake = absAngle > HANDBRAKE_MIN_ANGLE
		and absAngle < HANDBRAKE_MAX_ANGLE
		and fwdSpeed > HANDBRAKE_MIN_SPEED
	return throttle, steer, handbrake, angle
end

-- Pure pursuit (straight at the suspect) only when that turn is physically makeable; otherwise the grid router,
-- which knows which junctions we can still brake for, takes over.
function PoliceService._usePursuit(los: boolean, dist: number, absAngle: number, fwdSpeed: number): boolean
	return los
		and dist < PURSUIT_RANGE
		and (dist < PURSUIT_CLOSE or absAngle < PURSUIT_MAX_ANGLE or fwdSpeed < CORNER_SPEED + 10)
end

local function think(unit: Unit, st: Suspect, stars: number, now: number)
	local chassis = unit.chassis
	if not chassis.Parent then
		return
	end
	local cf = chassis.CFrame
	local pos = cf.Position
	local fwd = flat(cf.LookVector)
	fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else Vector3.new(0, 0, -1)
	local vel = chassis.AssemblyLinearVelocity
	local hvel = flat(vel)
	local speed = hvel.Magnitude
	local fwdSpeed = vel:Dot(fwd)

	-- crash damage (police have no driver, so VehicleService's per-driver sampling never sees them)
	local dv = (hvel - flat(unit.lastVel)).Magnitude
	unit.lastVel = vel
	if
		dv > VehicleConfig.CRASH_DAMAGE_THRESHOLD
		and now - unit.lastTeleport > 0.6
		and now - unit.spawnedAt > 1
		and unit.mode ~= "wrecked"
	then
		damageUnit(
			unit,
			(dv - VehicleConfig.CRASH_DAMAGE_THRESHOLD) * VehicleConfig.CRASH_DAMAGE_SCALE * POLICE_DAMAGE_MULT,
			now
		)
	end
	local health = unit.car.health
	if typeof(health) ~= "number" then
		health = unit.model:GetAttribute("Health")
	end
	if typeof(health) == "number" and health <= 0 then
		markWrecked(unit, now)
	end
	if unit.mode == "wrecked" then
		unit.seen = false
		return
	end

	if unit.mode == "leaving" then
		-- head away from the suspect along the road grid (sirens off), despawned out of view by managePass
		unit.seen = false
		local away = if st.valid then flat(pos - st.pos) else fwd
		if away.Magnitude < 1 then
			away = fwd
		end
		local wp, isTurn = PoliceService._nextWaypoint(pos, pos + away.Unit * 400, fwd, fwdSpeed, unit.routeWp)
		unit.routeWp = if isTurn then wp else nil
		local throttle, steer, handbrake = PoliceService._drive(fwd, fwdSpeed, wp - pos, isTurn, flatDist(wp, pos))
		if PoliceService._updateStuck(unit.stuck, speed, throttle, steer, AI_TICK, now) then
			applyInput(unit, unit.stuck.recoverThrottle, unit.stuck.reverseSteer, false, false)
		else
			applyInput(unit, throttle, steer, handbrake, false)
		end
		return
	end

	if not st.valid then
		-- suspect has no body right now (respawning): idle with the brakes on
		unit.seen = false
		applyInput(unit, if fwdSpeed > 2 then -1 else 0, 0, false, false)
		return
	end

	local toT = flat(st.pos - pos)
	local dist = toT.Magnitude
	unit.dist = dist
	local los = false
	if dist <= PoliceConfig.SIGHT_RANGE + 40 then
		los = hasLineOfSight(pos + UP3, st.pos + UP3)
	end
	unit.hasLOS = los
	if los then
		unit.lastLosAt = now
	end
	-- vision cone (gta_combat §9.4): 100° / 150 studs ahead with line of sight, or within 40 studs all round
	local inCone = PoliceService._inCone(pos, fwd, CRUISER_CONE, st.pos)
	unit.seen = (not st.safe) and ((inCone and los) or dist <= CLOSE_SEE_RANGE)

	-- officers out on foot: the cruiser stays where they left it (PoliceCombatService sets OfficersOut)
	local out = unit.model:GetAttribute("OfficersOut")
	if typeof(out) == "number" and out > 0 and not st.safe then
		unit.routeWp = nil
		applyInput(unit, if fwdSpeed > 2 then -1 elseif fwdSpeed < -2 then 1 else 0, 0, false, false)
		return
	end

	-- search mode: nobody has seen the suspect for SEARCH_AFTER seconds -> drive to random points inside the search
	-- circle around the last known position (WantedService) instead of homing on the real position
	if not st.safe and not unit.seen and now - st.lastSeenAt > SEARCH_AFTER then
		local center, radius = nil, nil
		local okA, c, r = pcall(function()
			if typeof(WantedService.getSearchArea) == "function" then
				return WantedService.getSearchArea(st.player)
			end
			return nil, nil
		end)
		if okA then
			center, radius = c, r
		end
		if typeof(center) == "Vector3" and typeof(radius) == "number" then
			local sp = unit.searchPoint
			if sp == nil or flatDist(sp, pos) < SEARCH_REACHED or now - unit.searchPointAt > SEARCH_REROLL then
				sp = PoliceService._roadAnchor(
					PoliceAim.searchPoint(center, radius, searchRng:NextNumber(), searchRng:NextNumber())
				)
				unit.searchPoint = sp
				unit.searchPointAt = now
			end
			local target = sp :: Vector3
			local wp, isTurn = PoliceService._nextWaypoint(pos, target, fwd, fwdSpeed, unit.routeWp)
			unit.routeWp = if isTurn then wp else nil
			local throttle, steer, handbrake = PoliceService._drive(fwd, fwdSpeed, wp - pos, isTurn, flatDist(wp, pos))
			if PoliceService._updateStuck(unit.stuck, speed, throttle, steer, AI_TICK, now) then
				applyInput(unit, unit.stuck.recoverThrottle, unit.stuck.reverseSteer, false, false)
			else
				applyInput(unit, throttle * 0.8, steer, handbrake, false)
			end
			return
		end
	end
	unit.searchPoint = nil

	local suspectVel = flat(st.vel)
	local suspectSpeed = suspectVel.Magnitude
	local _, suspectSignedAngle = PoliceService._steerToward(fwd, toT)
	local suspectAngle = math.abs(suspectSignedAngle)
	local role = unit.role
	local roleKind = (role - 1) % 3 -- 0 chaser, 1 flanker, 2 interceptor
	local flankSide = if (role // 3) % 2 == 0 then 1 else -1

	-- 1) where do we want to go?
	local holdAt: Vector3? = nil
	if st.safe and st.plotIndex then
		-- suspect hid in their own garage: line up outside the door and wait (no entry, no bust)
		local G = MapConfig.Garage
		local okO, origin = pcall(MapLayout.plotOrigin, st.plotIndex)
		if okO then
			holdAt = (origin * CFrame.new(((role - 1) % 3 - 1) * 13, 0, G.FRONT_Z - 28)).Position
		end
	elseif suspectSpeed < BOX_SPEED and dist < 70 and los then
		-- box them in: each cop stops on its own side of the suspect
		local side = flat(pos - st.pos)
		side = if side.Magnitude > 0.5 then side.Unit else -fwd
		holdAt = st.pos + side * BOX_RADIUS
	end

	local aim: Vector3
	local cornering = false
	local wpDist = 0
	if holdAt then
		local hd = flatDist(holdAt, pos)
		if hd > PURSUIT_RANGE or not hasLineOfSight(pos + UP3, holdAt + UP3) then
			local wp, isTurn = PoliceService._nextWaypoint(pos, holdAt, fwd, fwdSpeed, unit.routeWp)
			unit.routeWp = if isTurn then wp else nil
			aim, cornering, wpDist = wp, isTurn, flatDist(wp, pos)
		else
			unit.routeWp = nil
			aim = holdAt
		end
	elseif PoliceService._usePursuit(los, dist, suspectAngle, fwdSpeed) then
		-- pure pursuit with prediction
		unit.routeWp = nil
		local lead = math.clamp(dist / 60, 0.3, 1.5) * (PoliceConfig.AI_LOOKAHEAD / 0.6)
		if roleKind == 2 then
			lead *= 1.6
		end
		local pred = st.pos + suspectVel * lead
		if roleKind == 1 and suspectSpeed > 5 then
			local sRight = Vector3.new(-suspectVel.Z, 0, suspectVel.X) / suspectSpeed
			pred += sRight * FLANK_OFFSET * flankSide * math.clamp((dist - 15) / 40, 0, 1)
		end
		if not MapLayout.isOnRoad(pred) and MapLayout.isOnRoad(st.pos) then
			pred = PoliceService._roadAnchor(pred)
		end
		if flatDist(pred, st.pos) > 4 and not hasLineOfSight(pos + UP3, pred + UP3) then
			pred = st.pos
		end
		aim = pred
	else
		local routeTarget = st.pos
		if roleKind == 2 and suspectSpeed > 25 then
			local p = st.pos + suspectVel * INTERCEPT_LEAD
			routeTarget = Vector3.new(math.clamp(p.X, -EXT, EXT), p.Y, math.clamp(p.Z, -EXT, EXT))
		end
		local wp, isTurn = PoliceService._nextWaypoint(pos, routeTarget, fwd, fwdSpeed, unit.routeWp)
		unit.routeWp = if isTurn then wp else nil
		aim, cornering, wpDist = wp, isTurn, flatDist(wp, pos)
	end

	-- 2) controls
	local throttle, steer, handbrake, angle = PoliceService._drive(fwd, fwdSpeed, aim - pos, cornering, wpDist)
	local absAngle = math.abs(angle)
	local nitro = false
	if holdAt then
		local hd = flatDist(holdAt, pos)
		if absAngle > 115 and hd < REVERSE_INTO_RANGE and fwdSpeed < 15 then
			-- overshot our slot: back into it instead of looping round in a slow U-turn
			throttle = -1
			steer = sign(angle)
		else
			local desired = math.clamp((hd - 3) * 2.2, 0, 140)
			if fwdSpeed > desired + 5 then
				throttle = -1
			elseif fwdSpeed > desired then
				throttle = 0
			end
		end
		if hd < 5 then
			-- in position: hold still (positive throttle brakes a car that is rolling backwards)
			throttle = if fwdSpeed > 2 then -1 elseif fwdSpeed < -2 then 1 else 0
			steer = 0
		end
	end
	if stars >= PoliceConfig.HELI_AT_STARS and absAngle < 10 and dist > 120 and not cornering and not holdAt then
		nitro = true
	end
	if PoliceService._updateStuck(unit.stuck, speed, throttle, steer, AI_TICK, now) then
		throttle = unit.stuck.recoverThrottle
		steer = unit.stuck.reverseSteer
		handbrake = false
		nitro = false
	end
	applyInput(unit, throttle, steer, handbrake, nitro)
end

-- HELICOPTER --------------------------------------------------------------------------------------------

local function heliPart(
	model: Model,
	name: string,
	shape: Enum.PartType?,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	transparency: number?
): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	p.Size = size * HELI_SCALE
	p.CFrame = CFrame.new(cf.Position * HELI_SCALE) * cf.Rotation
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = (transparency or 0) < 0.5
	p.Parent = model
	return p
end

local function weldTo(root: BasePart, part: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = part
	w.Parent = part
end

-- Builds the cartoon police chopper at the origin (forward = -Z). Pure instance construction (Lune-safe).
-- Root "Body" is anchored; every other part is welded to it except "SpotDisc" (anchored, moved separately).
-- The rotor hub hangs off a Weld named "RotorWeld". At runtime the server only publishes the pose attributes
-- HeliCFrame / SpotPos; EffectsController moves Body + SpotDisc, spins RotorWeld.C0 and blinks the sirens locally.
function PoliceService.buildHeli(): Model
	local model = Instance.new("Model")
	model.Name = "PoliceHeli"
	local WHITE = Color3.fromRGB(245, 246, 250)
	local NAVY = Color3.fromRGB(22, 34, 72)
	local DARK = Color3.fromRGB(42, 44, 52)
	local NEON_BLUE = Color3.fromRGB(0, 170, 255)
	local GLASS = Color3.fromRGB(120, 200, 255)
	local LIGHT = Color3.fromRGB(255, 244, 196)
	local AXIS_Y = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y
	local AXIS_Z = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis X -> Z
	local Block, Ball, Cyl = Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder

	local body = heliPart(model, "Body", Block, Vector3.new(7, 5.6, 10), CFrame.new(0, 0, 0.4), WHITE)
	body.Anchored = true
	model.PrimaryPart = body

	local parts: { BasePart } = {
		heliPart(
			model,
			"Cockpit",
			Ball,
			Vector3.new(6.6, 6.6, 6.6),
			CFrame.new(0, 0.6, -4.3),
			GLASS,
			Enum.Material.Glass,
			0.2
		),
		heliPart(model, "NoseCap", Ball, Vector3.new(6.4, 6.4, 6.4), CFrame.new(0, -1.3, -3.9), NAVY),
		heliPart(model, "Belly", Block, Vector3.new(6.6, 1.4, 9), CFrame.new(0, -3.1, 0.8), NAVY),
		heliPart(
			model,
			"Stripe",
			Block,
			Vector3.new(7.15, 0.6, 9.4),
			CFrame.new(0, -1.1, 0.6),
			NEON_BLUE,
			Enum.Material.Neon
		),
		heliPart(model, "RoofCowl", Block, Vector3.new(5, 1.6, 6.2), CFrame.new(0, 3.5, 1.4), WHITE),
		heliPart(model, "Mast", Cyl, Vector3.new(1.6, 1.1, 1.1), CFrame.new(0, 4.9, 0.9) * AXIS_Y, DARK),
		heliPart(
			model,
			"RotorBlur",
			Cyl,
			Vector3.new(0.12, 29, 29),
			CFrame.new(0, 6.05, 0.9) * AXIS_Y,
			Color3.fromRGB(205, 210, 220),
			nil,
			0.82
		),
		heliPart(model, "TailBoom", Cyl, Vector3.new(11.5, 1.6, 1.6), CFrame.new(0, 1.1, 10.6) * AXIS_Z, WHITE),
		heliPart(
			model,
			"TailStripe",
			Cyl,
			Vector3.new(3, 1.7, 1.7),
			CFrame.new(0, 1.1, 12.5) * AXIS_Z,
			NEON_BLUE,
			Enum.Material.Neon
		),
		heliPart(model, "TailWing", Block, Vector3.new(5.2, 0.35, 1.6), CFrame.new(0, 1.1, 14.6), NAVY),
		heliPart(model, "TailRotor", Cyl, Vector3.new(0.3, 3.8, 3.8), CFrame.new(0.75, 3.1, 16.2), DARK, nil, 0.35),
		heliPart(model, "SkidL", Cyl, Vector3.new(12, 0.6, 0.6), CFrame.new(-3.3, -5.3, 0.6) * AXIS_Z, DARK),
		heliPart(model, "SkidR", Cyl, Vector3.new(12, 0.6, 0.6), CFrame.new(3.3, -5.3, 0.6) * AXIS_Z, DARK),
		heliPart(model, "StrutFL", Block, Vector3.new(0.4, 1.8, 0.4), CFrame.new(-3.0, -4.4, -2.4), DARK),
		heliPart(model, "StrutFR", Block, Vector3.new(0.4, 1.8, 0.4), CFrame.new(3.0, -4.4, -2.4), DARK),
		heliPart(model, "StrutRL", Block, Vector3.new(0.4, 1.8, 0.4), CFrame.new(-3.0, -4.4, 3.6), DARK),
		heliPart(model, "StrutRR", Block, Vector3.new(0.4, 1.8, 0.4), CFrame.new(3.0, -4.4, 3.6), DARK),
	}

	-- vertical tail fin: WedgePart (slope faces -Z/up, tall face at +Z)
	local fin = Instance.new("WedgePart")
	fin.Name = "TailFin"
	fin.Size = Vector3.new(0.5, 4.4, 3.2) * HELI_SCALE
	fin.CFrame = CFrame.new(Vector3.new(0, 3.2, 15.6) * HELI_SCALE)
	fin.Color = NAVY
	fin.Material = Enum.Material.SmoothPlastic
	fin.Anchored = false
	fin.CanCollide = false
	fin.CanQuery = false
	fin.CanTouch = false
	fin.Massless = true
	fin.Parent = model
	table.insert(parts, fin)

	local sirenRed = heliPart(
		model,
		"SirenRed",
		Block,
		Vector3.new(1.3, 0.5, 0.9),
		CFrame.new(-1.4, 4.55, 3.6),
		Color3.fromRGB(255, 40, 40),
		Enum.Material.Neon
	)
	local sirenBlue = heliPart(
		model,
		"SirenBlue",
		Block,
		Vector3.new(1.3, 0.5, 0.9),
		CFrame.new(1.4, 4.55, 3.6),
		Color3.fromRGB(40, 120, 255),
		Enum.Material.Neon
	)
	local searchlight = heliPart(
		model,
		"Searchlight",
		Block,
		Vector3.new(1.6, 0.8, 1.6),
		CFrame.new(0, -4.0, -2.6),
		LIGHT,
		Enum.Material.Neon
	)
	table.insert(parts, sirenRed)
	table.insert(parts, sirenBlue)
	table.insert(parts, searchlight)
	for _, p in parts do
		weldTo(body, p)
	end

	-- spinning rotor: hub on a Weld (C0 animated), blades welded to the hub
	local hubPos = Vector3.new(0, 5.9, 0.9) * HELI_SCALE
	local hub = heliPart(model, "RotorHub", Cyl, Vector3.new(0.8, 2.2, 2.2), CFrame.new(0, 5.9, 0.9) * AXIS_Y, DARK)
	local rotorWeld = Instance.new("Weld")
	rotorWeld.Name = "RotorWeld"
	rotorWeld.Part0 = body
	rotorWeld.Part1 = hub
	rotorWeld.C0 = body.CFrame:Inverse() * CFrame.new(hubPos) * AXIS_Y
	rotorWeld.C1 = CFrame.identity
	rotorWeld.Parent = hub
	for i, size in { Vector3.new(29, 0.25, 1.4), Vector3.new(1.4, 0.25, 29) } do
		local blade = heliPart(model, "Blade" .. i, Block, size, CFrame.new(0, 6.1, 0.9), DARK)
		weldTo(hub, blade)
	end

	-- POLICE lettering on both doors
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Label" .. face.Name
		gui.Face = face
		gui.CanvasSize = Vector2.new(400, 280)
		gui.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 0.42)
		label.Position = UDim2.fromScale(0, 0.12)
		label.Text = "POLICE"
		label.TextScaled = true
		label.Font = Enum.Font.FredokaOne
		label.TextColor3 = NAVY
		label.Parent = gui
		gui.Parent = body
	end

	-- searchlight: SpotLight (range-capped by the engine) + a camera-facing light cone (Beam) + glowing ground disc
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Bottom
	spot.Angle = 45
	spot.Range = 60
	spot.Brightness = 6
	spot.Color = LIGHT
	spot.Shadows = false
	spot.Parent = searchlight
	local a0 = Instance.new("Attachment")
	a0.Name = "BeamStart"
	a0.Position = Vector3.new(0, -0.4, 0)
	a0.Parent = searchlight

	local disc = Instance.new("Part")
	disc.Name = "SpotDisc"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.15, 30, 30)
	disc.CFrame = CFrame.new(0, -80, 0) * AXIS_Y
	disc.Color = LIGHT
	disc.Material = Enum.Material.Neon
	disc.Transparency = 0.72
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.Parent = model
	local a1 = Instance.new("Attachment")
	a1.Name = "BeamEnd"
	a1.Parent = disc
	local glow = Instance.new("PointLight")
	glow.Range = 26
	glow.Brightness = 2.5
	glow.Color = LIGHT
	glow.Shadows = false
	glow.Parent = disc

	local beam = Instance.new("Beam")
	beam.Name = "LightCone"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = 2.5
	beam.Width1 = 30
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Segments = 1
	beam.Color = ColorSequence.new(LIGHT)
	beam.Transparency = NumberSequence.new(0.55, 0.88)
	beam.Parent = searchlight

	CollectionService:AddTag(model, "PoliceHeli")
	return model
end

local function getEffectsFolder(): Instance
	local f = effectsFolder
	if f and f.Parent then
		return f
	end
	local found = Workspace:FindFirstChild("Effects")
	if not found then
		found = Instance.new("Folder")
		found.Name = "Effects"
		found.Parent = Workspace
	end
	effectsFolder = found
	return found
end

local function groundUnder(p: Vector3, fallbackY: number): Vector3
	local y
	if math.abs(p.X) <= EXT + ROAD_HALF and math.abs(p.Z) <= EXT + ROAD_HALF then
		y = if MapLayout.isOnRoad(p) then MapConfig.ROAD_Y else MapLayout.CURB_TOP
	else
		y = fallbackY
	end
	return Vector3.new(p.X, y + 0.12, p.Z)
end

-- Heli pose (body CFrame incl. pitch / roll) for its logical state.
local function heliPose(heli: Heli): CFrame
	local yawCF = CFrame.Angles(0, heli.yaw, 0)
	local localVel = yawCF:VectorToObjectSpace(flat(heli.vel))
	local pitch = math.clamp(localVel.Z / HELI_MAX_SPEED, -1, 1) * math.rad(14)
	local roll = -math.clamp(localVel.X / HELI_MAX_SPEED, -1, 1) * math.rad(10)
	return CFrame.new(heli.pos) * yawCF * CFrame.Angles(pitch, 0, roll)
end

-- Publishes the heli's pose for EffectsController (attributes HeliCFrame / SpotPos, ~10 Hz). The server never
-- moves the body / disc parts after spawning: per-frame anchored CFrame + rotor C0 writes replicated ~180 property
-- changes/s per chopper and looked choppy; the client interpolates, spins the rotor and blinks the sirens.
local function publishHeli(heli: Heli, now: number, force: boolean?)
	if not force and now < heli.publishAt then
		return
	end
	heli.publishAt = now + HELI_PUBLISH
	local model = heli.model
	model:SetAttribute("HeliCFrame", heliPose(heli))
	local last = heli.publishedSpot
	if force or not last or (last - heli.spot).Magnitude > HELI_SPOT_EPSILON then
		heli.publishedSpot = heli.spot
		model:SetAttribute("SpotPos", heli.spot)
	end
end

local function spawnHeli(st: Suspect, now: number)
	local model = PoliceService.buildHeli()
	local body = model.PrimaryPart :: BasePart
	local disc = model:FindFirstChild("SpotDisc")
	local searchlight = model:FindFirstChild("Searchlight")
	local beam = searchlight and searchlight:FindFirstChild("LightCone")
	local base = flat(st.vel)
	if base.Magnitude < 5 then
		base = flat(st.look)
	end
	base = if base.Magnitude > 0.01 then base.Unit else Vector3.new(0, 0, -1)
	local startPos = st.pos - base * 260 + Vector3.new(0, HELI_ALTITUDE + 60, 0)
	local heli: Heli = {
		model = model,
		body = body,
		disc = if disc and disc:IsA("BasePart") then disc else nil,
		beam = if beam and beam:IsA("Beam") then beam else nil,
		pos = startPos,
		vel = base * HELI_MAX_SPEED * 0.8,
		yaw = math.atan2(-base.X, -base.Z),
		spot = groundUnder(st.pos, st.pos.Y - 2.5),
		ceiling = 0,
		nextCeilingAt = 0,
		seen = false,
		leaving = false,
		leaveAt = 0,
		awayDir = -base,
		publishAt = now,
		publishedSpot = nil,
	}
	model:SetAttribute("SuspectUserId", st.player.UserId)
	-- initial pose only (replicates once with the model); from here on the client renders from the attributes
	model:PivotTo(heliPose(heli))
	if heli.disc then
		heli.disc.CFrame = CFrame.new(heli.spot) * CFrame.Angles(0, 0, math.rad(90))
	end
	publishHeli(heli, now, true)
	model.Parent = getEffectsFolder()
	st.heli = heli
	table.insert(helis, heli)
	pcall(Net.fireClient, "Notify", st.player, "warning", "Police helicopter inbound. Break line of sight.", 4)
end

local function destroyHeli(heli: Heli)
	local idx = table.find(helis, heli)
	if idx then
		table.remove(helis, idx)
	end
	for _, st in suspects do
		if st.heli == heli then
			st.heli = nil
		end
	end
	heli.model:Destroy()
end

local function heliLeave(heli: Heli, now: number)
	if heli.leaving then
		return
	end
	heli.leaving = true
	heli.seen = false
	heli.leaveAt = now + HELI_LEAVE_TIME
	local away = flat(heli.vel)
	heli.awayDir = if away.Magnitude > 1 then away.Unit else heli.awayDir
	if heli.disc then
		heli.disc.Transparency = 1
		local glow = heli.disc:FindFirstChildOfClass("PointLight")
		if glow then
			glow.Enabled = false
		end
	end
	if heli.beam then
		heli.beam.Enabled = false
	end
end

local function updateHeliCeiling(heli: Heli, now: number)
	if now < heli.nextCeilingAt then
		return
	end
	heli.nextCeilingAt = now + 0.5
	local params = losParams
	if not params then
		return
	end
	local top = 0
	for _, probe in { heli.pos, heli.pos + flat(heli.vel) * 1.2 } do
		local hit = Workspace:Raycast(Vector3.new(probe.X, 900, probe.Z), Vector3.new(0, -1000, 0), params)
		if hit then
			top = math.max(top, hit.Position.Y)
		end
	end
	heli.ceiling = top
end

local function updateHeli(heli: Heli, st: Suspect?, dt: number, now: number)
	local body = heli.body
	if not body.Parent then
		destroyHeli(heli)
		return
	end
	local target: Vector3
	if heli.leaving or not st or not st.valid then
		if not heli.leaving then
			heliLeave(heli, now)
		end
		target = heli.pos + heli.awayDir * 300 + Vector3.new(0, 120, 0)
	else
		updateHeliCeiling(heli, now)
		local lagged = st.pos - flat(st.vel) * 0.35
		local alt = math.max(st.pos.Y + HELI_ALTITUDE, heli.ceiling + HELI_CLEARANCE)
		target = Vector3.new(lagged.X, alt, lagged.Z)
	end

	local maxSpeed = PoliceService._heliMaxSpeed(if st and st.valid then st.topSpeed else 0)
	local desiredVel = (target - heli.pos) * 1.8
	if desiredVel.Magnitude > maxSpeed then
		desiredVel = desiredVel.Unit * maxSpeed
	end
	heli.vel = heli.vel:Lerp(desiredVel, math.min(1, dt * 2.5))
	heli.pos += heli.vel * dt

	local hv = flat(heli.vel)
	local face = hv
	if hv.Magnitude < 12 and st and st.valid then
		face = flat(st.pos - heli.pos)
	end
	if face.Magnitude > 0.5 then
		local unit = face.Unit
		heli.yaw = lerpAngle(heli.yaw, math.atan2(-unit.X, -unit.Z), math.min(1, dt * 2.2))
	end

	if st and st.valid and not heli.leaving then
		heli.spot = heli.spot:Lerp(groundUnder(st.pos, st.pos.Y - 2.5), math.min(1, dt * 5))
	end
	publishHeli(heli, now)

	if heli.leaving and now >= heli.leaveAt then
		destroyHeli(heli)
	end
end

local function heliSight(heli: Heli, st: Suspect)
	if heli.leaving or not st.valid or st.safe then
		heli.seen = false
		return
	end
	if flatDist(heli.pos, st.pos) > HELI_SIGHT then
		heli.seen = false
		return
	end
	heli.seen = hasLineOfSight(heli.pos - Vector3.new(0, 7, 0), st.pos + UP3)
end

-- PASSES ------------------------------------------------------------------------------------------------

local function aiPass(now: number)
	for player, st in suspects do
		local stars = WantedService.getStars(player)
		if stars > 0 or #st.units > 0 or st.heli then
			updateSuspectInfo(st)
		end
		for _, unit in table.clone(st.units) do
			if unit.alive then
				local ok, err = pcall(think, unit, st, stars, now)
				if not ok then
					warn("[PoliceService] AI error: " .. tostring(err))
				end
			end
		end
		local heli = st.heli
		if heli then
			heliSight(heli, st)
		end
		if stars > 0 and PoliceService.isSeen(player) then
			st.lastSeenAt = now
		end
	end
end

local function bustPass()
	for player, st in suspects do
		local stars = WantedService.getStars(player)
		if stars > 0 and st.valid and not st.safe and not WantedService.isInGrace(player) then
			local slow = st.onFoot or flat(st.vel).Magnitude < PoliceConfig.BUST_SPEED
			local near = false
			for _, u in st.units do
				if u.mode == "chase" and u.chassis.Parent then
					local p = u.chassis.Position
					if flatDist(p, st.pos) <= PoliceConfig.BUST_RADIUS and math.abs(p.Y - st.pos.Y) < 10 then
						near = true
						break
					end
				end
			end
			if not near then
				for _, src in bustSources do
					local okS, res = pcall(src, player)
					if okS and res == true then
						near = true
						break
					end
				end
			end
			if near and slow then
				st.bustTime += BUST_TICK
			else
				st.bustTime = math.max(0, st.bustTime - BUST_TICK * 1.5)
			end
			if st.bustTime >= PoliceConfig.BUST_TIME then
				st.bustTime = 0
				setBustProgress(st, 0)
				local ok, err = pcall(WantedService.bust, player)
				if not ok then
					warn("[PoliceService] bust failed: " .. tostring(err))
				end
			else
				setBustProgress(st, st.bustTime / PoliceConfig.BUST_TIME)
			end
		else
			st.bustTime = 0
			setBustProgress(st, 0)
		end
	end
end

local function maintainUnit(unit: Unit, st: Suspect, stars: number, now: number)
	local chassis = unit.chassis
	if not chassis.Parent or not unit.model.Parent then
		removeUnit(unit)
		return
	end
	if unit.broken then
		despawnUnit(unit, "despawn")
		st.nextSpawnAt = math.max(st.nextSpawnAt, now + WRECK_RESPAWN_DELAY)
		return
	end
	if chassis.Anchored then
		chassis.Anchored = false
	end
	local okOwner, owner = pcall(chassis.GetNetworkOwner, chassis)
	if okOwner and owner ~= nil then
		pcall(chassis.SetNetworkOwner, chassis, nil)
	end

	if unit.mode == "wrecked" then
		if now - unit.wreckedAt > WRECK_CLEANUP_AFTER then
			despawnUnit(unit, "wrecked")
		end
		return
	end
	if unit.mode == "leaving" then
		if
			now >= unit.leaveAt
			and (now >= unit.leaveAt + LEAVE_MAX_TIME or not anyPlayerNear(chassis.Position, LEAVE_VIEW_RADIUS))
		then
			despawnUnit(unit, "despawn")
		end
		return
	end

	-- chase maintenance: fell off the world / into the sea, rubber band, chronic stuck
	local pos = chassis.Position
	local lost = pos.Y < MapConfig.WATER_LEVEL - 6
		or math.abs(pos.X) > MapConfig.SAND_EXTENT
		or math.abs(pos.Z) > MapConfig.SAND_EXTENT
	if lost then
		if not rubberBand(unit, st, now) then
			despawnUnit(unit, "despawn")
		end
		return
	end
	if
		st.valid
		and unit.dist > PoliceConfig.RESPAWN_IF_FARTHER
		and now - unit.lastLosAt > RUBBER_BAND_HIDDEN_TIME
		and now - unit.lastRubberBand > RUBBER_BAND_COOLDOWN
	then
		rubberBand(unit, st, now)
	elseif unit.stuck.count >= STUCK_RESCUE_COUNT and not unit.hasLOS then
		unit.stuck.count = 0
		rubberBand(unit, st, now)
	end

	local farBehind = unit.dist > PoliceConfig.SIGHT_RANGE and not unit.hasLOS
	local mult = PoliceService._unitSpeedMult(stars, if st.valid then st.topSpeed else 0, farBehind)
	if mult ~= unit.speedMult then
		unit.speedMult = mult
		unit.model:SetAttribute("SpeedMultiplier", mult)
	end
end

local function managePass(now: number)
	refreshLosFilter()
	upgradeOfficers(OFFICER_UPGRADES_PER_PASS)

	-- per-unit upkeep
	for player, st in suspects do
		local stars = WantedService.getStars(player)
		for _, unit in table.clone(st.units) do
			if unit.alive then
				local ok, err = pcall(maintainUnit, unit, st, stars, now)
				if not ok then
					warn("[PoliceService] maintain error: " .. tostring(err))
				end
			end
		end
	end

	-- allocation: who gets how many cruisers
	local order: { Suspect } = {}
	for player, st in suspects do
		if WantedService.getStars(player) > 0 and st.valid and not WantedService.isInGrace(player) then
			table.insert(order, st)
		end
	end
	table.sort(order, function(a, b)
		return WantedService.getStars(a.player) > WantedService.getStars(b.player)
	end)
	local desired = table.create(#order, 0)
	for i, st in order do
		local stars = WantedService.getStars(st.player)
		desired[i] = PoliceConfig.UNITS_PER_STAR[math.clamp(stars, 1, #PoliceConfig.UNITS_PER_STAR)] or 1
	end
	local totalAlive, wrecked = 0, 0
	for _, u in units do
		totalAlive += 1
		if u.mode == "wrecked" then
			wrecked += 1
		end
	end
	local alloc = PoliceService._allocateUnits(desired, PoliceConfig.MAX_UNITS_GLOBAL - wrecked)

	for i, st in order do
		local want = alloc[i]
		local chasing: { Unit } = {}
		local leaving: Unit? = nil
		for _, u in st.units do
			if u.mode == "chase" then
				table.insert(chasing, u)
			elseif u.mode == "leaving" and not leaving then
				leaving = u
			end
		end
		if #chasing < want then
			if leaving then
				-- cops turn around and rejoin instead of spawning fresh ones
				leaving.mode = "chase"
				leaving.model:SetAttribute("Siren", true)
			elseif totalAlive < PoliceConfig.MAX_UNITS_GLOBAL and now >= st.nextSpawnAt then
				st.nextSpawnAt = now + SPAWN_STAGGER
				local ok, res = pcall(spawnUnit, st, now)
				if ok and res then
					totalAlive += 1
				elseif not ok then
					warn("[PoliceService] spawn error: " .. tostring(res))
				end
			end
		elseif #chasing > want then
			table.sort(chasing, function(a, b)
				return a.dist > b.dist
			end)
			for k = 1, #chasing - want do
				sendAway(chasing[k], now)
			end
		end
		-- roles in spawn order: chaser, flanker, interceptor, ...
		local idx = 0
		for _, u in st.units do
			if u.mode == "chase" then
				idx += 1
				u.role = idx
			end
		end
	end

	-- helicopters
	for player, st in suspects do
		local stars = WantedService.getStars(player)
		local heli = st.heli
		if stars >= PoliceConfig.HELI_AT_STARS and st.valid then
			if heli and heli.leaving then
				st.heli = nil -- let it fly off; a fresh one comes in
				heli = nil
			end
			if not heli and #helis < MAX_HELIS then
				local ok, err = pcall(spawnHeli, st, now)
				if not ok then
					warn("[PoliceService] heli spawn failed: " .. tostring(err))
				end
			end
		elseif heli and not heli.leaving then
			heliLeave(heli, now)
		end
	end
end

-- PUBLIC ------------------------------------------------------------------------------------------------

function PoliceService.isSeen(player: Player): boolean
	local st = suspects[player]
	if not st or st.safe then
		return false
	end
	for _, u in st.units do
		if u.alive and u.mode == "chase" and u.seen then
			return true
		end
	end
	local heli = st.heli
	if heli and heli.seen then
		return true
	end
	local PoliceCombat = sys("PoliceCombatService")
	if PoliceCombat and typeof(PoliceCombat.officerSees) == "function" then
		local okO, sees = pcall(PoliceCombat.officerSees, player)
		if okO and sees == true then
			return true
		end
	end
	if st.valid then
		-- cops chasing someone else still notice a wanted player right next to them
		for _, u in units do
			if u.alive and u.mode == "chase" and u.suspect ~= player and u.chassis.Parent then
				if flatDist(u.chassis.Position, st.pos) <= CLOSE_SEE_RANGE then
					return true
				end
			end
		end
	end
	return false
end

-- COMBAT V2 HOOKS ----------------------------------------------------------------------------------------------

export type UnitView = {
	id: number,
	model: Model,
	chassis: BasePart,
	mode: string,
	role: number,
	speed: number,
	seen: boolean,
	hasLOS: boolean,
	car: any,
}

local function viewOf(u: Unit): UnitView
	return {
		id = u.id,
		model = u.model,
		chassis = u.chassis,
		mode = u.mode,
		role = u.role,
		speed = u.chassis.AssemblyLinearVelocity.Magnitude,
		seen = u.seen,
		hasLOS = u.hasLOS,
		car = u.car,
	}
end

-- Live cruisers chasing `player` (alive, in the world).
function PoliceService.getUnits(player: Player): { UnitView }
	local out = {}
	local st = suspects[player]
	if not st then
		return out
	end
	for _, u in st.units do
		if u.alive and u.chassis.Parent then
			table.insert(out, viewOf(u))
		end
	end
	return out
end

-- Every live cruiser (any suspect), for witnesses / brandishing.
function PoliceService.allUnits(): { UnitView }
	local out = {}
	for _, u in units do
		if u.alive and u.chassis.Parent and u.mode ~= "wrecked" then
			table.insert(out, viewOf(u))
		end
	end
	return out
end

function PoliceService.getHeli(player: Player): Model?
	local st = suspects[player]
	local heli = st and st.heli
	return if heli then heli.model else nil
end

-- "chaser" | "flanker" | "interceptor" (role order in the pack).
function PoliceService.unitRole(view: UnitView): string
	local k = (view.role - 1) % 3
	return if k == 0 then "chaser" elseif k == 1 then "flanker" else "interceptor"
end

-- Any police (cruiser, heli, on-foot officer) within radius of pos: crimes are witnessed / shots are heard.
function PoliceService.copsNear(pos: Vector3, radius: number): boolean
	for _, u in units do
		if u.alive and u.mode ~= "wrecked" and u.chassis.Parent and flatDist(u.chassis.Position, pos) <= radius then
			return true
		end
	end
	for _, heli in helis do
		if not heli.leaving and flatDist(heli.pos, pos) <= radius then
			return true
		end
	end
	local PoliceCombat = sys("PoliceCombatService")
	if PoliceCombat and typeof(PoliceCombat.officersNear) == "function" then
		local ok, near = pcall(PoliceCombat.officersNear, pos, radius)
		return ok and near == true
	end
	return false
end

-- Extra bust-proximity source: fn(player) -> true while an officer (e.g. on foot) is close enough to arrest.
function PoliceService.registerBustSource(fn: (Player) -> boolean)
	table.insert(bustSources, fn)
end

-- A parked, anchored, siren-on cruiser (roadblocks). Not a pursuit unit: PoliceCombatService owns and removes it.
function PoliceService.spawnRoadblockCar(cframe: CFrame): any
	local VehicleService = sys("VehicleService")
	if not VehicleService or typeof(VehicleService.spawn) ~= "function" then
		return nil
	end
	local car = trySpawnCar(VehicleService, cframe)
	if not car then
		return nil
	end
	local chassis: BasePart = car.chassis
	chassis.Anchored = true
	if not CollectionService:HasTag(car.model, "Police") then
		CollectionService:AddTag(car.model, "Police")
	end
	car.model:SetAttribute("Siren", true)
	car.model:SetAttribute("Roadblock", true)
	return car
end

function PoliceService.getUnitCount(player: Player?): number
	if player then
		local st = suspects[player]
		return if st then #st.units else 0
	end
	local n = 0
	for _ in units do
		n += 1
	end
	return n
end

local function releaseSuspect(st: Suspect, now: number)
	for _, u in table.clone(st.units) do
		sendAway(u, now)
	end
	if st.heli then
		heliLeave(st.heli, now)
	end
	st.bustTime = 0
	setBustProgress(st, 0)
end

local function onPlayerRemoving(player: Player)
	local st = suspects[player]
	if not st then
		return
	end
	for _, u in table.clone(st.units) do
		despawnUnit(u, "despawn")
	end
	if st.heli then
		destroyHeli(st.heli)
	end
	suspects[player] = nil
end

function PoliceService.init()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	params.IgnoreWater = true
	losParams = params
	getEffectsFolder()

	WantedService.Changed:Connect(function(player: Player, stars: number, old: number)
		if player.Parent ~= Players then
			return
		end
		local st = getSuspect(player)
		local now = os.clock()
		if stars <= 0 then
			releaseSuspect(st, now)
		elseif old <= 0 then
			st.nextSpawnAt = now + FIRST_SPAWN_DELAY
		end
	end)

	WantedService.Busted:Connect(function(player: Player)
		if typeof(player) ~= "Instance" or player.Parent ~= Players then
			return
		end
		local ok, err = pcall(onBusted, player)
		if not ok then
			warn("[PoliceService] busted officer failed: " .. tostring(err))
		end
	end)

	local VehicleService = sys("VehicleService")
	if VehicleService and VehicleService.Destroyed then
		VehicleService.Destroyed:Connect(function(car: any, reason: any)
			local unit = unitByCar[car]
			if not unit then
				return
			end
			local wasWreck = unit.mode == "wrecked"
				or (typeof(reason) == "string" and reason:lower():find("wreck") ~= nil)
			local st = suspects[unit.suspect]
			removeUnit(unit)
			if wasWreck and st then
				st.nextSpawnAt = math.max(st.nextSpawnAt, os.clock() + WRECK_RESPAWN_DELAY)
			end
		end)
	else
		warn("[PoliceService] VehicleService unavailable at init; police units will not be tracked on destroy")
	end
end

function PoliceService.start()
	-- dummy officers get their humanoids from the manage pass (upgradeOfficers: gated, out of view), not in a burst
	-- when NPCService becomes ready
	local function onPlayerAdded(player: Player)
		local st = getSuspect(player)
		setBustProgress(st, 0)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- physics: step every police controller before each simulation step
	RunService.PreSimulation:Connect(function(dt: number)
		local d = math.min(dt, VehicleConfig.MAX_DT)
		for _, unit in units do
			if unit.alive and not unit.broken then
				local ok, err = pcall(unit.controller.step, unit.controller, d)
				if not ok then
					unit.broken = true
					warn("[PoliceService] controller:step failed: " .. tostring(err))
				end
			end
		end
	end)

	local aiAcc, bustAcc, manageAcc = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		aiAcc += dt
		bustAcc += dt
		manageAcc += dt
		if manageAcc >= MANAGE_TICK then
			manageAcc = 0
			local ok, err = pcall(managePass, now)
			if not ok then
				warn("[PoliceService] manage pass failed: " .. tostring(err))
			end
		end
		if aiAcc >= AI_TICK then
			aiAcc = math.min(aiAcc - AI_TICK, AI_TICK)
			local ok, err = pcall(aiPass, now)
			if not ok then
				warn("[PoliceService] AI pass failed: " .. tostring(err))
			end
		end
		if bustAcc >= BUST_TICK then
			bustAcc = math.min(bustAcc - BUST_TICK, BUST_TICK)
			local ok, err = pcall(bustPass)
			if not ok then
				warn("[PoliceService] bust pass failed: " .. tostring(err))
			end
		end
		for _, heli in if helis[1] then table.clone(helis) else helis do
			local owner: Suspect? = nil
			for _, st in suspects do
				if st.heli == heli then
					owner = st
					break
				end
			end
			local ok, err = pcall(updateHeli, heli, owner, dt, now)
			if not ok then
				warn("[PoliceService] heli update failed: " .. tostring(err))
				pcall(destroyHeli, heli)
			end
		end
	end)
end

return PoliceService
