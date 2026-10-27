--!strict
-- TrafficService (docs/SPEC.md §6): ambient AI traffic that makes the city feel alive and gives players cars to jack.
--
--  * ~BASE_COUNT cars (x EventService.getTrafficMultiplier(), e.g. Rush Hour) spawned on lanes 150-450 studs from a
--    random player (ahead of fast drivers) so density follows the players. A car that ends up far from everyone is
--    recycled: teleported onto a fresh lane near a player (only its CFrame replicates) instead of destroyed and
--    rebuilt; a share (all of them during luck events) is rebuilt anyway so the rolls keep changing (PERF-04).
--  * Movement: VehicleService kind "Traffic" cars, chassis unanchored + server-owned, driven by a LinearVelocity
--    (heading * speed + a dead-banded pull toward a virtual "carrot") and an AlignOrientation (OneAttachment). Both
--    targets are quantized and written only when they change (at most every MOVER_WRITE_INTERVAL /
--    HEADING_WRITE_INTERVAL), so a car cruising a straight lane replicates no mover writes at all (PERF-02).
--    The carrot follows a pure lane state machine: right-hand lanes on the 160-stud grid, and at every
--    intersection a random straight / left / right (never a U-turn, never off the grid) driven as a smooth
--    quarter-circle arc from box edge to box edge.
--  * Spacing: cars brake for anything in a narrow cone ahead (cars, players' cars, people on foot), crawl past
--    pedestrians, honk at players blocking them, and break intersection deadlocks with a short "patience" ghost.
--    Police cars, hot drops and anchored cars are "hard" blockers: never ghosted into; a car stuck behind one
--    vanishes out of view after STATIC_GIVEUP (in view after HARD_GIVEUP).
--  * NPC driver: a seated R15 humanoid from NPCService.spawnDriver (catalog outfit, welded to the seat, no physics)
--    where it can be seen (NPCService.driverVisible: procedural bodies, open-top shells). Closed hero shells, cars
--    while NPCService isn't ready, and anything over its humanoid budget get the little block-figure dummy (no
--    Humanoid); visible dummies are upgraded UPGRADES_PER_TICK per manage pass, out of players' close view (no burst
--    when NPCService becomes ready). A bail-out from a closed shell swaps its dummy for a humanoid on the spot.
--  * "Carjack" prompt (hold = rarity hotwireTime x 0.9; the car brakes as soon as someone starts holding): the NPC
--    gets yeeted out of the car (NPCService.ejectComic ragdoll / the dummy's comic tumble, removed after 3s),
--    kind -> Loot, the player is seated (no heat or credit if seat() refuses), heat max(Heat.carjack,
--    rarity.wantedOnSteal) (DECISIONS §1).
--  * A player-driven car hitting a traffic car at > RAM_SPEED relative speed releases it to physics: NPC bails,
--    kind -> unowned Loot (VehicleService settles it on its suspension), VehicleService's abandon rules clean it up.
--
-- Public API: none required by the spec. Extras: getCount(): number, release(car, reason?), buildDriver(seatCFrame, scale,
--   rng, palette?): Model (harness-compatible), attachDummy(model, seat, weldTo, palette?): Model (PoliceService's
--   fallback too), driverScale(model, seat): number, POLICE_PALETTE. Pure path helpers prefixed with _ are
--   exposed for tests/spec/vehicleservice.spec.luau.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MapConfig = require(Shared.Config.Map)
local PoliceConfig = require(Shared.Config.Police)
local Rarity = require(Shared.Config.Rarity)
local Net = require(Shared.Net)
local Rolls = require(Shared.Util.Rolls)
local Trove = require(Shared.Util.Trove)
local VehicleService = require(script.Parent.VehicleService)

type Car = VehicleService.Car

local TrafficService = {}

-- TUNING -------------------------------------------------------------------------------------------------------------

local S = MapConfig.GRID_SPACING
local LMIN, LMAX = MapConfig.LINE_MIN, MapConfig.LINE_MAX
local EXT = MapConfig.HALF_EXTENT
local ROAD_Y = MapConfig.ROAD_Y

TrafficService.BASE_COUNT = 18
TrafficService.MAX_COUNT = 36
-- 1 stud inside MapLayout's lane line: keeps the widest cars clear of curb-parked cars and oncoming traffic
TrafficService.LANE_OFFSET = MapConfig.LANE_OFFSET - 1
TrafficService.BOX_HALF = MapConfig.ROAD_WIDTH / 2 -- turns start/end at the intersection box edge
TrafficService.CRUISE = { 30, 45 }
TrafficService.TURN_SPEED = { right = 16, left = 20 }
TrafficService.ACCEL = 18
TrafficService.BRAKE = 45
TrafficService.TURN_DECEL = 28
TrafficService.SPAWN_RING = { 150, 450 }
TrafficService.SPAWN_LEAD = 250 -- spawn ring centered this far ahead of a player moving faster than...
TrafficService.SPAWN_LEAD_MIN_SPEED = 40 -- ...this (so fast drivers don't strand new cars behind them)
TrafficService.RECYCLES_PER_TICK = 6
TrafficService.REROLL_CHANCE = 0.2 -- share of far cars rebuilt (new roll) instead of recycled (always during luck)
TrafficService.MIN_SPAWN_PLAYER_DIST = 130
TrafficService.SPAWN_CLEARANCE = 20
TrafficService.DESPAWN_DIST = 650
TrafficService.SPAWNS_PER_TICK = 2
TrafficService.STOP_DIST = 14 -- center-to-center: another car this close ahead = stop
TrafficService.SLOW_DIST = 34
TrafficService.PED_STOP_DIST = 9
TrafficService.PED_SLOW_DIST = 24
TrafficService.PED_CAUTION_RADIUS = 13 -- someone on foot this close (any side): crawl so they can carjack
TrafficService.PED_CAUTION_SPEED = 11
TrafficService.CONE_BASE = 6 -- half-width of the "ahead" cone at the bumper (~two chassis half-widths)...
TrafficService.CONE_SLOPE = 0.05 -- ...widening by this per stud ahead (still clear of curb-parked cars)
-- Left turns pull into the box this far before turning (and straighten out the same distance), so opposing
-- left-turners pass each other instead of meeting in the middle of the intersection.
TrafficService.LEFT_LEAD = 14
TrafficService.PATIENCE = { 2.5, 4.5 } -- stuck behind traffic this long -> ghost through for GHOST_TIME
TrafficService.GHOST_TIME = 2.5
TrafficService.STATIC_GIVEUP = 8 -- stuck behind a non-moving non-player obstacle: despawn (out of view) or ghost
TrafficService.HARD_GIVEUP = 20 -- stuck behind a hard blocker (police / hot drop / anchored) this long: despawn
TrafficService.HONK_AFTER = 1.5
TrafficService.HONK_COOLDOWN = 5
TrafficService.RAM_SPEED = 35
TrafficService.KNOCKED_OFF_DIST = 25 -- chassis this far from its carrot = shoved off the road: release it
TrafficService.CARJACK_HOLD_MULT = 0.9
TrafficService.NPC_DEBRIS_TIME = 3
TrafficService.UPGRADES_PER_TICK = 2 -- block dummies swapped for NPCService humanoids per manage pass...
TrafficService.UPGRADE_HIDDEN_DIST = 120 -- ...only for cars at least this far from every player
TrafficService.SCAN_TICK = 0.1
TrafficService.MANAGE_TICK = 1
TrafficService.ALIGN_RESPONSIVENESS = 25 -- AlignOrientation
-- LinearVelocity mover: velocity = heading * speed + POS_GAIN * (error beyond POS_DEADBAND), capped at
-- MAX_CORRECTION, quantized to VEL_QUANTUM (speeds too, so the carrot and the car move at the same exact speed).
TrafficService.POS_GAIN = 2.5
TrafficService.POS_DEADBAND = 0.5
TrafficService.MAX_CORRECTION = 12
TrafficService.VEL_QUANTUM = 0.5
TrafficService.MOVER_WRITE_INTERVAL = 0.1 -- seconds between velocity writes while it changes (turns, braking)...
TrafficService.VEL_URGENT = 6 -- ...unless it changed by at least this much (studs/s)
TrafficService.HEADING_WRITE_INTERVAL = 0.05
TrafficService.HEADING_EPS_DOT = math.cos(math.rad(1)) -- heading changes under ~1 degree are not written

local TURN_WEIGHTS = { straight = 0.5, right = 0.25, left = 0.25 }

export type Axis = "X" | "Z"
export type Turn = "straight" | "left" | "right"

-- Pure lane-following state (no Instances). mode "lane": on road (axis, line) heading dir, at along-coordinate s,
-- approaching intersection index `cross` where it will do `nextTurn`. mode "turn": straight `lead`, quarter arc
-- (p0, f -> f2, radius), straight `lead`, having travelled `td` of `tlen`; then it continues on (naxis, nline, ndir).
export type PathState = {
	mode: string,
	axis: Axis,
	line: number,
	dir: number,
	s: number,
	cross: number,
	nextTurn: Turn,
	p0: Vector3,
	f: Vector3,
	f2: Vector3,
	radius: number,
	lead: number,
	td: number,
	tlen: number,
	turnKind: Turn,
	naxis: Axis,
	nline: number,
	ndir: number,
}

type Entry = {
	car: Car,
	model: Model,
	chassis: BasePart,
	path: PathState,
	v: number,
	cruise: number,
	obstacleLimit: number,
	yOffset: number,
	lv: LinearVelocity?,
	ao: AlignOrientation?,
	lastVel: Vector3, -- last value written to lv.VectorVelocity
	lastVelWrite: number,
	lastHeading: Vector3, -- last heading written to ao.CFrame
	lastHeadingWrite: number,
	npc: Model?,
	prompt: ProximityPrompt?,
	trove: Trove.Trove,
	released: boolean,
	blockedSince: number?,
	blockerKind: string?,
	patience: number,
	ghostUntil: number,
	holdStopUntil: number,
	lastHonk: number,
	nearPed: boolean,
}

type Obstacle = { pos: Vector3, car: any, isPed: boolean, isPlayerCar: boolean, isTraffic: boolean, isHard: boolean }

local entries: { [Car]: Entry } = {}
local rng = Random.new()
local effectsFolder: Folder? = nil

-- HELPERS ------------------------------------------------------------------------------------------------------------

local systemCache: { [string]: any } = {}
local function sys(name: string): any
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local parent = script.Parent
	local inst = parent and parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok and type(mod) == "table" then
			systemCache[name] = mod
			return mod
		end
	end
	return nil
end

local function callNumber(name: string, fn: string, default: number): number
	local mod = sys(name)
	local f = mod and mod[fn]
	if typeof(f) ~= "function" then
		return default
	end
	local ok, v = pcall(f)
	if ok and typeof(v) == "number" and v == v then
		return v
	end
	return default
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function getEffectsFolder(): Folder
	local f = effectsFolder
	if f and f.Parent then
		return f
	end
	local existing = Workspace:FindFirstChild("Effects")
	if existing and existing:IsA("Folder") then
		effectsFolder = existing
		return existing
	end
	local nf = Instance.new("Folder")
	nf.Name = "Effects"
	nf.Parent = Workspace
	effectsFolder = nf
	return nf
end

-- PURE PATH HELPERS ----------------------------------------------------------------------------------------------------

function TrafficService._forward(axis: Axis, dir: number): Vector3
	return if axis == "X" then Vector3.new(dir, 0, 0) else Vector3.new(0, 0, dir)
end

-- Right-hand side of travel (LookVector x Up), matches MapLayout.laneCFrame's offset direction.
function TrafficService._right(axis: Axis, dir: number): Vector3
	return TrafficService._forward(axis, dir):Cross(Vector3.yAxis)
end

-- Lane center point at road height. offset defaults to TrafficService.LANE_OFFSET.
function TrafficService._lanePoint(axis: Axis, line: number, dir: number, s: number, offset: number?): Vector3
	local c = line * S
	local base = if axis == "X" then Vector3.new(s, ROAD_Y, c) else Vector3.new(c, ROAD_Y, s)
	return base + TrafficService._right(axis, dir) * (offset or TrafficService.LANE_OFFSET)
end

-- Index of the next intersection ahead whose turn-start (box edge) has not been passed yet.
function TrafficService._nextCross(s: number, dir: number): number
	local k = if dir > 0 then math.floor(s / S) + 1 else math.ceil(s / S) - 1
	if dir * (k * S - s) < TrafficService.BOX_HALF then
		k += dir
	end
	return k
end

-- (axis, line, dir) of the road after taking `turn` at intersection `cross`.
function TrafficService._turnTarget(
	axis: Axis,
	line: number,
	dir: number,
	cross: number,
	turn: Turn
): (Axis, number, number)
	if turn == "straight" then
		return axis, line, dir
	end
	local naxis: Axis = if axis == "X" then "Z" else "X"
	local ndir
	if axis == "X" then
		ndir = if turn == "right" then dir else -dir
	else
		ndir = if turn == "right" then -dir else dir
	end
	return naxis, cross, ndir
end

-- Legal moves at intersection `cross` for a car on (axis, line, dir): never a U-turn, never off the grid.
function TrafficService._turnOptions(axis: Axis, line: number, dir: number, cross: number): { Turn }
	local out: { Turn } = {}
	if cross + dir >= LMIN and cross + dir <= LMAX then
		table.insert(out, "straight")
	end
	for _, t: Turn in { "right", "left" } :: { Turn } do
		local _, _, ndir = TrafficService._turnTarget(axis, line, dir, cross, t)
		if line + ndir >= LMIN and line + ndir <= LMAX then
			table.insert(out, t)
		end
	end
	return out
end

-- Weighted pick (straight 50%, right/left 25%) among the legal options. r in [0, 1).
function TrafficService._chooseTurn(options: { Turn }, r: number): Turn
	if #options == 0 then
		return "straight"
	end
	local total = 0
	for _, t in options do
		total += TURN_WEIGHTS[t] or 0
	end
	local x = math.clamp(r, 0, 0.999999) * total
	for _, t in options do
		x -= TURN_WEIGHTS[t] or 0
		if x < 0 then
			return t
		end
	end
	return options[#options]
end

-- Straight lead-in (= lead-out) of a turn. lead + radius = BOX_HALF -/+ LANE_OFFSET puts the exit on the new lane.
function TrafficService._turnLead(turn: Turn): number
	if turn == "left" then
		return math.clamp(TrafficService.LEFT_LEAD, 0, TrafficService.BOX_HALF + TrafficService.LANE_OFFSET - 4)
	end
	return 0
end

function TrafficService._turnRadius(turn: Turn): number
	if turn == "right" then
		return TrafficService.BOX_HALF - TrafficService.LANE_OFFSET
	end
	return TrafficService.BOX_HALF + TrafficService.LANE_OFFSET - TrafficService._turnLead(turn)
end

-- Total path length of a turn.
function TrafficService._turnLength(turn: Turn): number
	return 2 * TrafficService._turnLead(turn) + TrafficService._turnRadius(turn) * math.pi / 2
end

-- Point + unit heading at distance d along a turn from p0 (heading f) to heading f2: `lead` straight, a quarter arc
-- of radius R, `lead` straight.
function TrafficService._turnPoint(
	p0: Vector3,
	f: Vector3,
	f2: Vector3,
	radius: number,
	d: number,
	lead: number?
): (Vector3, Vector3)
	local a = lead or 0
	if d <= a then
		return p0 + f * math.max(d, 0), f
	end
	local arcLen = radius * math.pi / 2
	local start = p0 + f * a
	if d >= a + arcLen then
		return start + (f + f2) * radius + f2 * (d - a - arcLen), f2
	end
	local theta = (d - a) / radius
	local c, s = math.cos(theta), math.sin(theta)
	local pos = start + (f2 * (1 - c) + f * s) * radius
	local heading = f2 * s + f * c
	return pos, heading.Unit
end

local function pickWith(pick: ((options: { Turn }) -> Turn)?): (options: { Turn }) -> Turn
	return pick or function(options: { Turn }): Turn
		return TrafficService._chooseTurn(options, 0)
	end
end

function TrafficService._newPath(
	axis: Axis,
	line: number,
	dir: number,
	s: number,
	pick: ((options: { Turn }) -> Turn)?
): PathState
	local choose = pickWith(pick)
	local cross = TrafficService._nextCross(s, dir)
	local st: PathState = {
		mode = "lane",
		axis = axis,
		line = line,
		dir = dir,
		s = s,
		cross = cross,
		nextTurn = "straight",
		p0 = Vector3.zero,
		f = Vector3.zero,
		f2 = Vector3.zero,
		radius = 1,
		lead = 0,
		td = 0,
		tlen = 0,
		turnKind = "straight",
		naxis = axis,
		nline = line,
		ndir = dir,
	}
	st.nextTurn = choose(TrafficService._turnOptions(axis, line, dir, cross))
	return st
end

-- Distance along the lane until the next turn starts (0 while turning).
function TrafficService._distToTurn(st: PathState): number
	if st.mode == "turn" then
		return 0
	end
	return st.dir * (st.cross * S - st.dir * TrafficService.BOX_HALF - st.s)
end

-- Advance the carrot `dist` studs along the path (crossing any number of intersections / arcs).
function TrafficService._advance(st: PathState, dist: number, pick: ((options: { Turn }) -> Turn)?)
	local choose = pickWith(pick)
	local remaining = dist
	local guard = 0
	while remaining > 1e-9 and guard < 16 do
		guard += 1
		if st.mode == "lane" then
			local turnStart = st.cross * S - st.dir * TrafficService.BOX_HALF
			local toTurn = st.dir * (turnStart - st.s)
			if remaining < toTurn then
				st.s += st.dir * remaining
				return
			end
			remaining -= math.max(toTurn, 0)
			st.s = turnStart
			if st.nextTurn == "straight" then
				st.cross += st.dir
				if st.cross < LMIN or st.cross > LMAX then
					-- invalid state (should never happen): turn around rather than leave the grid
					st.dir = -st.dir
					st.cross = TrafficService._nextCross(st.s, st.dir)
				end
				st.nextTurn = choose(TrafficService._turnOptions(st.axis, st.line, st.dir, st.cross))
			else
				local naxis, nline, ndir = TrafficService._turnTarget(st.axis, st.line, st.dir, st.cross, st.nextTurn)
				st.mode = "turn"
				st.turnKind = st.nextTurn
				st.p0 = TrafficService._lanePoint(st.axis, st.line, st.dir, st.s)
				st.f = TrafficService._forward(st.axis, st.dir)
				st.f2 = TrafficService._forward(naxis, ndir)
				st.radius = TrafficService._turnRadius(st.nextTurn)
				st.lead = TrafficService._turnLead(st.nextTurn)
				st.td = 0
				st.tlen = TrafficService._turnLength(st.nextTurn)
				st.naxis, st.nline, st.ndir = naxis, nline, ndir
			end
		else
			local left = st.tlen - st.td
			if remaining < left then
				st.td += remaining
				return
			end
			remaining -= left
			local oldLine = st.line
			st.mode = "lane"
			st.axis, st.line, st.dir = st.naxis, st.nline, st.ndir
			st.s = oldLine * S + st.dir * TrafficService.BOX_HALF
			st.cross = oldLine + st.dir
			st.td = 0
			st.nextTurn = choose(TrafficService._turnOptions(st.axis, st.line, st.dir, st.cross))
		end
	end
end

-- Carrot position (road height) and unit heading.
function TrafficService._pose(st: PathState): (Vector3, Vector3)
	if st.mode == "turn" then
		return TrafficService._turnPoint(st.p0, st.f, st.f2, st.radius, st.td, st.lead)
	end
	return TrafficService._lanePoint(st.axis, st.line, st.dir, st.s), TrafficService._forward(st.axis, st.dir)
end

-- Speed cap from turn planning: decelerate to the turn speed before the arc, hold it through the arc.
function TrafficService._turnSpeedCap(st: PathState): number
	if st.mode == "turn" then
		return TrafficService.TURN_SPEED[st.turnKind] or 18
	end
	if st.nextTurn == "straight" then
		return math.huge
	end
	local vt = TrafficService.TURN_SPEED[st.nextTurn] or 18
	local d = math.max(0, TrafficService._distToTurn(st))
	return math.sqrt(vt * vt + 2 * TrafficService.TURN_DECEL * d)
end

-- Snap a world point to a spawnable lane position: (axis, line, s) on the nearest road, clear of intersection
-- boxes and the ring-road ends. Returns nil axis when the point is hopelessly outside the grid.
function TrafficService._snapToRoad(p: Vector3): (Axis?, number, number)
	if p.X ~= p.X or p.Z ~= p.Z then
		return nil, 0, 0
	end
	local lx = math.clamp(math.round(p.X / S), LMIN, LMAX)
	local lz = math.clamp(math.round(p.Z / S), LMIN, LMAX)
	local dx = math.abs(p.X - lx * S)
	local dz = math.abs(p.Z - lz * S)
	local axis: Axis
	local line: number
	local s: number
	if dx < dz then
		axis, line, s = "Z", lx, p.Z
	else
		axis, line, s = "X", lz, p.X
	end
	local margin = TrafficService.BOX_HALF + 12
	s = math.clamp(s, -EXT + margin, EXT - margin)
	local nearest = math.round(s / S) * S
	if math.abs(s - nearest) < margin then
		s = nearest + (if s >= nearest then margin else -margin)
	end
	s = math.clamp(s, -EXT + margin, EXT - margin)
	return axis, line, s
end

-- Distance ahead (center to center) if `other` sits in the cone in front of pos/fwd, else nil. right (optional) =
-- fwd x up, precomputed once per car by the scan.
function TrafficService._aheadDistance(
	pos: Vector3,
	fwd: Vector3,
	other: Vector3,
	coneBase: number?,
	right: Vector3?
): number?
	local rel = flat(other - pos)
	local ahead = rel:Dot(fwd)
	if ahead <= 0 or ahead > TrafficService.SLOW_DIST then
		return nil
	end
	local r = right or fwd:Cross(Vector3.yAxis)
	local lateral = math.abs(rel:Dot(r))
	if lateral > (coneBase or TrafficService.CONE_BASE) + ahead * TrafficService.CONE_SLOPE then
		return nil
	end
	return ahead
end

-- True when another car's heading crosses ours (not a same-way queue): candidates for deadlock breaking.
function TrafficService._isCrossing(fwd: Vector3, otherLook: Vector3): boolean
	local o = flat(otherLook)
	if o.Magnitude < 0.1 then
		return true
	end
	return o.Unit:Dot(fwd) < 0.7
end

-- Speed limit for something `ahead` studs in front (math.huge = no limit).
function TrafficService._limitFromGap(ahead: number, stopDist: number, slowDist: number, cruise: number): number
	if ahead <= stopDist then
		return 0
	end
	if ahead >= slowDist then
		return math.huge
	end
	return cruise * (ahead - stopDist) / (slowDist - stopDist)
end

-- Stars for carjacking a car of this rarity: rarer cars are hotter wherever they're taken from (DECISIONS §1).
function TrafficService._carjackStars(rarity: string?): number
	local tier = Rarity.Tiers[rarity :: any] or Rarity.Tiers.Common
	return math.max(PoliceConfig.Heat.carjack, tier.wantedOnSteal)
end

function TrafficService._quantize(x: number, step: number?): number
	local q = step or TrafficService.VEL_QUANTUM
	return math.round(x / q) * q
end

-- LinearVelocity target: travel at `speed` along `heading`, plus a pull toward the carrot `target` (ride height
-- included) once the error leaves the dead band. Quantized: identical inputs on a straight lane give an identical
-- vector, so nothing is re-written (and nothing replicates) while cruising.
function TrafficService._moverVelocity(pos: Vector3, target: Vector3, heading: Vector3, speed: number): Vector3
	local err = target - pos
	local m = err.Magnitude
	local vel = heading * speed
	if m > TrafficService.POS_DEADBAND and m == m then
		local pull =
			math.min(TrafficService.POS_GAIN * (m - TrafficService.POS_DEADBAND), TrafficService.MAX_CORRECTION)
		vel += err * (pull / m)
	end
	local q = TrafficService.VEL_QUANTUM
	return Vector3.new(
		TrafficService._quantize(vel.X, q),
		TrafficService._quantize(vel.Y, q),
		TrafficService._quantize(vel.Z, q)
	)
end

-- NPC DRIVER -----------------------------------------------------------------------------------------------------------

local SKINS = {
	Color3.fromRGB(255, 221, 180),
	Color3.fromRGB(241, 194, 125),
	Color3.fromRGB(224, 172, 105),
	Color3.fromRGB(198, 134, 66),
	Color3.fromRGB(141, 85, 36),
	Color3.fromRGB(255, 205, 148),
}
local SHIRTS = {
	Color3.fromRGB(255, 85, 85),
	Color3.fromRGB(70, 160, 255),
	Color3.fromRGB(255, 200, 40),
	Color3.fromRGB(120, 220, 90),
	Color3.fromRGB(190, 110, 255),
	Color3.fromRGB(255, 140, 40),
	Color3.fromRGB(40, 200, 200),
	Color3.fromRGB(245, 245, 245),
}
local HATS = {
	Color3.fromRGB(35, 35, 45),
	Color3.fromRGB(220, 50, 50),
	Color3.fromRGB(40, 120, 255),
	Color3.fromRGB(255, 210, 0),
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(255, 110, 190),
}

local FIGURE_HEIGHT = 3.15 -- seated figure height (seat top -> hat top) at scale 1

export type Palette = { shirt: Color3?, hat: Color3? }

-- Police cruiser dummies (PoliceService's fallback when NPCService has no officer for it).
TrafficService.POLICE_PALETTE = {
	shirt = Color3.fromRGB(40, 90, 210),
	hat = Color3.fromRGB(28, 50, 130),
} :: Palette

-- Builds the seated dummy driver (8 parts, no Humanoid) on a seat. Harness-compatible (pure construction).
-- palette overrides the random shirt / hat colors (the random picks are still drawn, so sequences stay stable).
function TrafficService.buildDriver(seatCFrame: CFrame, scale: number, r: Random, palette: Palette?): Model
	local model = Instance.new("Model")
	model.Name = "NPCDriver"
	local s = math.clamp(scale, 0.4, 1.2)
	local shirt = SHIRTS[r:NextInteger(1, #SHIRTS)]
	local skin = SKINS[r:NextInteger(1, #SKINS)]
	local hat = HATS[r:NextInteger(1, #HATS)]
	if palette then
		shirt = palette.shirt or shirt
		hat = palette.hat or hat
	end
	local function part(name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = shape
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.CastShadow = false
		p.Parent = model
		return p
	end
	local seatTop = seatCFrame * CFrame.new(0, 0.15, 0)
	local torsoCF = seatTop * CFrame.new(0, 0.85 * s, 0.15 * s)
	local torso = part("Torso", Enum.PartType.Block, Vector3.new(1.7, 1.7, 0.9) * s, torsoCF, shirt)
	local headCF = torsoCF * CFrame.new(0, 1.47 * s, 0)
	part("Head", Enum.PartType.Ball, Vector3.one * (1.25 * s), headCF, skin)
	local black = Color3.fromRGB(25, 25, 30)
	part(
		"EyeL",
		Enum.PartType.Ball,
		Vector3.one * (0.26 * s),
		headCF * CFrame.new(-0.24 * s, 0.1 * s, -0.52 * s),
		black
	)
	part("EyeR", Enum.PartType.Ball, Vector3.one * (0.26 * s), headCF * CFrame.new(0.24 * s, 0.1 * s, -0.52 * s), black)
	part("Hat", Enum.PartType.Block, Vector3.new(1.3, 0.42, 1.3) * s, headCF * CFrame.new(0, 0.62 * s, 0.05 * s), hat)
	part(
		"Brim",
		Enum.PartType.Block,
		Vector3.new(1.3, 0.14, 0.62) * s,
		headCF * CFrame.new(0, 0.45 * s, -0.78 * s),
		hat
	)
	part(
		"ArmL",
		Enum.PartType.Block,
		Vector3.new(0.45, 0.45, 1.35) * s,
		torsoCF * CFrame.new(-1.05 * s, 0.4 * s, -0.6 * s),
		shirt
	)
	part(
		"ArmR",
		Enum.PartType.Block,
		Vector3.new(0.45, 0.45, 1.35) * s,
		torsoCF * CFrame.new(1.05 * s, 0.4 * s, -0.6 * s),
		shirt
	)
	for _, child in model:GetChildren() do
		if child ~= torso and child:IsA("BasePart") then
			local w = Instance.new("WeldConstraint")
			w.Part0 = torso
			w.Part1 = child
			w.Parent = child
		end
	end
	model.PrimaryPart = torso
	return model
end

-- Figure scale that keeps the driver's hat under the car's roof line.
function TrafficService.driverScale(model: Model, seat: BasePart): number
	local height = model:GetAttribute("Height")
	local ride = model:GetAttribute("RideHeight")
	local chassis = model.PrimaryPart
	if typeof(height) ~= "number" or typeof(ride) ~= "number" or not chassis then
		return 0.85
	end
	local groundY = chassis.CFrame.Position.Y - ride
	local seatTop = seat.CFrame.Position.Y + 0.15 - groundY
	return math.clamp((height - 0.35 - seatTop) / FIGURE_HEIGHT, 0.6, 1)
end

-- The block dummy, welded ("ToCar") to `weldTo` and parented to the car model.
function TrafficService.attachDummy(model: Model, seat: BasePart, weldTo: BasePart, palette: Palette?): Model
	local npc = TrafficService.buildDriver(seat.CFrame, TrafficService.driverScale(model, seat), rng, palette)
	local torso = npc.PrimaryPart
	if torso then
		local w = Instance.new("WeldConstraint")
		w.Name = "ToCar"
		w.Part0 = torso
		w.Part1 = weldTo
		w.Parent = torso
	end
	npc.Parent = model
	return npc
end

-- NPCService, when it is loaded and exposes the driver API (it boots after us: always looked up lazily).
local function npcService(): any
	local mod = sys("NPCService")
	if mod and typeof(mod.spawnDriver) == "function" and typeof(mod.ejectComic) == "function" then
		return mod
	end
	return nil
end

local function isHumanoidDriver(npc: Model?): boolean
	return npc ~= nil and npc:FindFirstChildOfClass("Humanoid") ~= nil
end

-- Is a humanoid worth it in this car? (no: a closed hero shell hides its driver)
local function wantsHuman(NPC: any, car: Car): boolean
	if typeof(NPC.driverVisible) ~= "function" then
		return true
	end
	local ok, visible = pcall(NPC.driverVisible, car.model)
	return not ok or visible == true
end

-- A humanoid civilian from NPCService when it can give one (ready, under budget) and its driver can be seen, else
-- (allowDummy) the block dummy.
local function attachDriver(car: Car, allowDummy: boolean): Model?
	local seat = car.seat
	local NPC = npcService()
	if NPC and seat and seat.Parent and wantsHuman(NPC, car) then
		local ok, npc = pcall(NPC.spawnDriver, seat, "civilian")
		if ok and typeof(npc) == "Instance" and npc:IsA("Model") then
			return npc
		end
	end
	if not allowDummy or not seat then
		return nil
	end
	return TrafficService.attachDummy(car.model, seat, car.chassis)
end

-- Comic NPC bail-out: unweld, tumble away from `away`, gone after NPC_DEBRIS_TIME. Humanoid drivers get
-- NPCService.ejectComic (ragdoll); the block dummy tumbles as one piece.
local function ejectNPC(e: Entry, away: Vector3?)
	local npc = e.npc
	e.npc = nil
	if not npc or not npc.Parent then
		return
	end
	local chassis = e.chassis
	local dir = if away and flat(away).Magnitude > 0.1 then flat(away).Unit else -chassis.CFrame.RightVector
	if not isHumanoidDriver(npc) then
		-- a dummy (closed shell / early boot): a real humanoid takes its seat just for the bail-out gag
		local NPC = npcService()
		local seat = e.car.seat
		if NPC and seat and seat.Parent then
			local ok, human = pcall(NPC.spawnDriver, seat, "civilian")
			if ok and typeof(human) == "Instance" and human:IsA("Model") then
				npc:Destroy()
				npc = human
			end
		end
	end
	if isHumanoidDriver(npc) then
		local NPC = npcService()
		local fling = dir * rng:NextNumber(28, 42) + flat(chassis.AssemblyLinearVelocity) * 0.4
		if NPC and pcall(NPC.ejectComic, npc, fling) then
			return
		end
	end
	local torso = npc.PrimaryPart
	if not torso then
		npc:Destroy()
		return
	end
	pcall(function()
		local toCar = torso:FindFirstChild("ToCar")
		if toCar then
			toCar:Destroy()
		end
		local grouped = VehicleService.ensureCollisionGroups() -- the tumbling dummy is no wall for cars either
		for _, d in npc:GetDescendants() do
			if d:IsA("BasePart") then
				d.Massless = false
				d.CanCollide = d == torso
				if grouped then
					d.CollisionGroup = VehicleService.NPC_GROUP
				end
			end
		end
		npc.Parent = getEffectsFolder()
		npc:PivotTo(torso.CFrame + Vector3.new(0, 3, 0) + dir * 3)
		pcall(torso.SetNetworkOwner, torso, nil)
		torso.AssemblyLinearVelocity = dir * rng:NextNumber(28, 42) + Vector3.new(0, rng:NextNumber(55, 75), 0)
		torso.AssemblyAngularVelocity =
			Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-6, 6), rng:NextNumber(-12, 12))
	end)
	task.delay(TrafficService.NPC_DEBRIS_TIME, function()
		if npc.Parent then
			npc:Destroy()
		end
	end)
end

-- LIFECYCLE OF ONE TRAFFIC CAR -------------------------------------------------------------------------------------------

local function setAttr(inst: Instance?, name: string, value: any)
	if inst then
		pcall(inst.SetAttribute, inst, name, value)
	end
end

-- Stop simulating a traffic car. reason "rammed"/"knocked": it becomes unowned Loot abandoned on the street;
-- "despawn": the car is about to be destroyed (the dummy goes with it instead of bailing out).
local function release(e: Entry, reason: string?, away: Vector3?)
	if e.released then
		return
	end
	e.released = true
	if entries[e.car] == e then
		entries[e.car] = nil
	end
	if reason ~= "despawn" then
		ejectNPC(e, away) -- before the trove clean, which would take the dummy down with the car
	end
	e.lv = nil
	e.ao = nil
	e.prompt = nil
	e.trove:Clean()
	local car = e.car
	if car.destroyed then
		return
	end
	if (reason == "rammed" or reason == "knocked") and car.kind == "Traffic" then
		car.ownerUserId = nil
		setAttr(car.model, "OwnerUserId", 0)
		car.data.source = "traffic"
		car.lastDriverAt = os.clock()
		VehicleService.setKind(car, "Loot")
		VehicleService.settle(car) -- rest on its suspension, not on the bump stops (F4)
	end
end

function TrafficService.release(car: Car, reason: string?)
	local e = entries[car]
	if e then
		release(e, reason)
	end
end

local function canCarjack(e: Entry, player: Player): (boolean, string?)
	local car = e.car
	if e.released or car.destroyed or car.wrecked or car.kind ~= "Traffic" or entries[car] ~= e then
		return false, nil
	end
	if player:GetAttribute("Stunned") == true then
		return false, nil
	end
	if VehicleService.getDriving(player) ~= nil then
		return false, "You're already driving!"
	end
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
		return false, nil
	end
	return true, nil
end

-- Returns false when the player never got in (seat() refused): no heat, credit or announcement then.
local function onCarjack(e: Entry, player: Player): boolean
	local car = e.car
	local npcTorso = e.npc and e.npc.PrimaryPart
	local fxPos = if npcTorso then npcTorso.CFrame.Position + Vector3.new(0, 2, 0) else car.chassis.CFrame.Position
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local away = if root and root:IsA("BasePart") then car.chassis.CFrame.Position - root.Position else nil
	release(e, "carjack", away)
	car.data.source = "traffic"
	local seated, why = VehicleService.seat(car, player)
	if not seated then
		-- the NPC is already out: leave an empty, unowned Loot car (abandon rules clean it up)
		warn(("[TrafficService] carjack: could not seat %s: %s"):format(player.Name, tostring(why)))
		car.ownerUserId = nil
		setAttr(car.model, "OwnerUserId", 0)
		car.lastDriverAt = os.clock()
		VehicleService.setKind(car, "Loot")
		VehicleService.settle(car)
		return false
	end
	VehicleService.setKind(car, "Loot")
	car.ownerUserId = player.UserId
	setAttr(car.model, "OwnerUserId", player.UserId)
	local heat = VehicleService.addStealHeat(player, TrafficService._carjackStars(car.rarity), "carjack")
	VehicleService.contractProgress(player, "steal", 1)
	VehicleService.announceSteal(player, car, "carjacked")
	pcall(Net.fireNear, "Effect", fxPos, 220, "Bonk", { position = fxPos, sound = "Bonk" })
	if heat > 0 then
		pcall(Net.fireClient, "Notify", player, "warning", `🚨 Carjacking! +{heat}★`, 2.5)
	end
	return true
end

local function onTouched(e: Entry, hit: BasePart)
	if e.released or not hit or not hit.Parent then
		return
	end
	local other = VehicleService.fromModel(hit)
	if not other or other == e.car then
		return
	end
	local driver = other.driver
	if driver == nil then
		return
	end
	local mine = e.chassis.AssemblyLinearVelocity
	local theirs = other.chassis.AssemblyLinearVelocity
	if (theirs - mine).Magnitude <= TrafficService.RAM_SPEED then
		return
	end
	local pos = e.chassis.CFrame.Position
	release(e, "rammed", flat(theirs - mine))
	pcall(Net.fireNear, "Effect", pos + Vector3.new(0, 3, 0), 220, "Bonk", { position = pos + Vector3.new(0, 3, 0) })
end

local function rollCar(): (string, string)
	local def = Rolls.car("street", math.max(1, callNumber("EventService", "getLuck", 1)), rng)
	return def.id, Rolls.mutation(1, rng)
end

local function pick(options: { Turn }): Turn
	return TrafficService._chooseTurn(options, rng:NextNumber())
end

-- Writes the movers' targets for this frame: only when the (quantized) value changed, and at most every
-- MOVER_WRITE_INTERVAL / HEADING_WRITE_INTERVAL unless `force` (every write is a replicated property change).
local function driveMovers(
	e: Entry,
	pos: Vector3,
	target: Vector3,
	heading: Vector3,
	speed: number,
	now: number,
	force: boolean
)
	local lv = e.lv
	if lv then
		local vel = TrafficService._moverVelocity(pos, target, heading, speed)
		if
			vel ~= e.lastVel
			and (
				force
				or now - e.lastVelWrite >= TrafficService.MOVER_WRITE_INTERVAL
				or (vel - e.lastVel).Magnitude >= TrafficService.VEL_URGENT
			)
		then
			lv.VectorVelocity = vel
			e.lastVel = vel
			e.lastVelWrite = now
		end
	end
	local ao = e.ao
	if
		ao
		and heading:Dot(e.lastHeading) < TrafficService.HEADING_EPS_DOT
		and (force or now - e.lastHeadingWrite >= TrafficService.HEADING_WRITE_INTERVAL)
	then
		ao.CFrame = CFrame.lookAt(Vector3.zero, heading)
		e.lastHeading = heading
		e.lastHeadingWrite = now
	end
end

local function spawnTraffic(axis: Axis, line: number, dir: number, s: number): Entry?
	local path = TrafficService._newPath(axis, line, dir, s, pick)
	local pos, heading = TrafficService._pose(path)
	local ground = CFrame.lookAt(pos, pos + heading)
	local carId, mutation = rollCar()
	local ok, carOrErr = pcall(VehicleService.spawn, carId, mutation, ground, "Traffic")
	if not ok or type(carOrErr) ~= "table" then
		warn("[TrafficService] spawn failed: " .. tostring(carOrErr))
		return nil
	end
	local car: Car = carOrErr
	local model, chassis = car.model, car.chassis
	car.data.source = "traffic"
	local trove = Trove.new()
	-- quantized like the mover velocity, so a car at cruise holds one exact speed
	local cruise = TrafficService._quantize(rng:NextNumber(TrafficService.CRUISE[1], TrafficService.CRUISE[2]))
	local now = os.clock()
	local e: Entry = {
		car = car,
		model = model,
		chassis = chassis,
		path = path,
		v = cruise * 0.6,
		cruise = cruise,
		obstacleLimit = math.huge,
		yOffset = chassis.CFrame.Position.Y - ROAD_Y,
		lv = nil,
		ao = nil,
		lastVel = Vector3.zero,
		lastVelWrite = now,
		lastHeading = heading,
		lastHeadingWrite = now,
		npc = nil,
		prompt = nil,
		trove = trove,
		released = false,
		blockedSince = nil,
		blockerKind = nil,
		patience = rng:NextNumber(TrafficService.PATIENCE[1], TrafficService.PATIENCE[2]),
		ghostUntil = 0,
		holdStopUntil = 0,
		lastHonk = 0,
		nearPed = false,
	}

	-- movers
	local mass = math.max(chassis.AssemblyMass, 500)
	local att = Instance.new("Attachment")
	att.Name = "TrafficAttachment"
	att.Parent = chassis
	trove:Add(att)
	local vel0 = TrafficService._moverVelocity(Vector3.zero, Vector3.zero, heading, TrafficService._quantize(e.v))
	local lv = Instance.new("LinearVelocity")
	lv.Name = "TrafficLinearVelocity"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = mass * Workspace.Gravity * 10
	lv.VectorVelocity = vel0
	lv.Parent = chassis
	trove:Add(lv)
	e.lastVel = vel0
	local ao = Instance.new("AlignOrientation")
	ao.Name = "TrafficAlignOrientation"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.RigidityEnabled = false
	ao.MaxTorque = 1e9
	ao.MaxAngularVelocity = 8
	ao.Responsiveness = TrafficService.ALIGN_RESPONSIVENESS
	ao.CFrame = CFrame.lookAt(Vector3.zero, heading)
	ao.Parent = chassis
	trove:Add(ao)
	e.lv = lv
	e.ao = ao
	pcall(function()
		chassis.AssemblyLinearVelocity = vel0
	end)

	-- driver: NPCService humanoid, or the block dummy until NPCService can give one
	e.npc = attachDriver(car, true)
	trove:Add(function()
		-- if the car is despawned with its driver still inside, the dummy goes with it
		if e.npc and e.npc.Parent == model then
			e.npc:Destroy()
		end
	end)

	-- carjack prompt
	local tier = Rarity.Tiers[car.rarity] or Rarity.Tiers.Common
	local hold = tier.hotwireTime * TrafficService.CARJACK_HOLD_MULT
	e.prompt = VehicleService.addStealPrompt(car, {
		actionText = "Carjack",
		holdDuration = hold,
		objectText = VehicleService.carLabel(car),
		canSteal = function(player: Player): (boolean, string?)
			return canCarjack(e, player)
		end,
		onStolen = function(player: Player): boolean
			return onCarjack(e, player)
		end,
		onHoldBegan = function()
			e.holdStopUntil = os.clock() + hold * 1.3 + 1.5 -- the driver notices and brakes
		end,
	})
	trove:Add(e.prompt)

	pcall(function()
		trove:Connect(chassis.Touched, function(hit: BasePart)
			onTouched(e, hit)
		end)
	end)

	entries[car] = e
	return e
end

-- PASSES ---------------------------------------------------------------------------------------------------------------

local obstacles: { Obstacle } = {}
local obstacleCount = 0
local scanCars: { Car } = {}
local manageCars: { Car } = {}
local farBuf: { Entry } = {}
local rootsBuf: { Vector3 } = {}
local velsBuf: { Vector3 } = {}

local function playerRoots(): { Vector3 }
	local out = {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(out, root.Position)
		end
	end
	return out
end

-- Fills rootsBuf / velsBuf (positions and velocities of every player's root; seated = their car's). Returns the count.
local function collectPlayers(): number
	table.clear(rootsBuf)
	table.clear(velsBuf)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(rootsBuf, root.Position)
			table.insert(velsBuf, root.AssemblyLinearVelocity)
		end
	end
	return #rootsBuf
end

local function minDist(pos: Vector3, points: { Vector3 }): number
	local best = math.huge
	for _, p in points do
		local d = flatDist(pos, p)
		if d < best then
			best = d
		end
	end
	return best
end

local function pushObstacle(
	pos: Vector3,
	car: any,
	isPed: boolean,
	isPlayerCar: boolean,
	isTraffic: boolean,
	isHard: boolean
)
	obstacleCount += 1
	local o = obstacles[obstacleCount]
	if o then
		o.pos, o.car, o.isPed, o.isPlayerCar, o.isTraffic, o.isHard = pos, car, isPed, isPlayerCar, isTraffic, isHard
	else
		obstacles[obstacleCount] = {
			pos = pos,
			car = car,
			isPed = isPed,
			isPlayerCar = isPlayerCar,
			isTraffic = isTraffic,
			isHard = isHard,
		}
	end
end

local function honk(e: Entry, now: number)
	if now - e.lastHonk < TrafficService.HONK_COOLDOWN then
		return
	end
	e.lastHonk = now
	local pos = e.chassis.CFrame.Position
	pcall(Net.fireNear, "Sound", pos, 140, "Horn", pos)
end

local function scanPass(now: number)
	obstacleCount = 0
	for _, car in VehicleService.allInto(scanCars) do
		if car.destroyed or car.kind == "Parked" or car.kind == "Dealership" then
			continue
		end
		local chassis = car.chassis
		if chassis.Parent then
			local isTraffic = entries[car] ~= nil
			local isPlayerCar = car.driver ~= nil
			-- police, hot drops and anchored cars are never shoved aside by a patience ghost (F7 / F12)
			local isHard = not isTraffic
				and not isPlayerCar
				and (car.kind == "Police" or car.kind == "HotDrop" or chassis.Anchored)
			pushObstacle(chassis.CFrame.Position, car, false, isPlayerCar, isTraffic, isHard)
		end
	end
	table.clear(scanCars)
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 and humanoid.SeatPart == nil then
			pushObstacle(root.Position, nil, true, false, false, false)
		end
	end

	-- nothing farther than this can be in a cone (SLOW_DIST ahead, cone half-width ~8) or within the ped radius
	local reach = TrafficService.SLOW_DIST + TrafficService.CONE_BASE + 10
	local reachSq = reach * reach
	local cautionSq = TrafficService.PED_CAUTION_RADIUS * TrafficService.PED_CAUTION_RADIUS
	local roots: { Vector3 }? = nil -- players' positions, fetched only if a car gives up
	for car, e in entries do
		if e.released then
			continue
		end
		local cf = e.chassis.CFrame
		local pos = cf.Position
		local fwd = flat(cf.LookVector)
		fwd = if fwd.Magnitude > 0.1 then fwd.Unit else Vector3.new(0, 0, -1)
		local right = fwd:Cross(Vector3.yAxis)
		local ghost = now < e.ghostUntil
		local limit = math.huge
		local blocker: string? = nil
		local blockerCar: any = nil
		local nearPed = false
		for i = 1, obstacleCount do
			local o = obstacles[i]
			if o.car == car then
				continue
			end
			local op = o.pos
			local dx, dz = op.X - pos.X, op.Z - pos.Z
			local d2 = dx * dx + dz * dz
			if d2 > reachSq then
				continue
			end
			if o.isPed then
				if d2 <= cautionSq then
					nearPed = true
				end
				local ahead = TrafficService._aheadDistance(pos, fwd, op, 2.5, right)
				if ahead then
					local l = TrafficService._limitFromGap(
						ahead,
						TrafficService.PED_STOP_DIST,
						TrafficService.PED_SLOW_DIST,
						e.cruise
					)
					if l < limit then
						limit, blocker = l, "ped"
					end
				end
			elseif not (ghost and not o.isPlayerCar and not o.isHard) then
				local ahead = TrafficService._aheadDistance(pos, fwd, op, nil, right)
				if ahead then
					local l = TrafficService._limitFromGap(
						ahead,
						TrafficService.STOP_DIST,
						TrafficService.SLOW_DIST,
						e.cruise
					)
					if l < limit then
						limit = l
						blocker = if o.isPlayerCar
							then "player"
							elseif o.isTraffic then "traffic"
							elseif o.isHard then "hard"
							else "static"
						blockerCar = o.car
					end
				end
			end
		end
		e.obstacleLimit = limit
		e.nearPed = nearPed
		if limit <= 0.5 and blocker then
			if e.blockedSince == nil or e.blockerKind ~= blocker then
				e.blockedSince = now
				e.blockerKind = blocker
			end
			local waited = now - (e.blockedSince :: number)
			if blocker == "traffic" and waited > e.patience then
				-- only a crossing car can be a deadlock; a queue behind a same-way car just waits its turn
				e.blockedSince = nil
				local other = if type(blockerCar) == "table" then blockerCar.chassis else nil
				if other == nil or TrafficService._isCrossing(fwd, other.CFrame.LookVector) then
					e.ghostUntil = now + TrafficService.GHOST_TIME
				end
			elseif blocker == "static" and waited > TrafficService.STATIC_GIVEUP then
				e.blockedSince = nil
				if roots == nil then
					roots = playerRoots()
				end
				if minDist(pos, roots :: { Vector3 }) > 150 then
					release(e, "despawn")
					VehicleService.destroy(car, "stuck")
				else
					e.ghostUntil = now + TrafficService.GHOST_TIME
				end
			elseif blocker == "hard" and waited > TrafficService.STATIC_GIVEUP then
				-- never ghost into a cop / hot drop / anchored car: vanish out of view, or after HARD_GIVEUP anyway
				if roots == nil then
					roots = playerRoots()
				end
				if waited > TrafficService.HARD_GIVEUP or minDist(pos, roots :: { Vector3 }) > 150 then
					release(e, "despawn")
					VehicleService.destroy(car, "stuck")
				end
			elseif (blocker == "player" or blocker == "ped") and waited > TrafficService.HONK_AFTER then
				honk(e, now)
			end
		else
			e.blockedSince = nil
			e.blockerKind = nil
		end
	end
end

local function step(dt: number)
	local now = os.clock()
	for car, e in entries do
		if e.released then
			continue
		end
		if car.destroyed then
			release(e, nil)
			continue
		end
		if car.kind ~= "Traffic" or car.wrecked or car.driver ~= nil then
			release(e, nil)
			continue
		end
		local chassis = e.chassis
		if chassis.Anchored then
			chassis.Anchored = false
		end
		local path = e.path
		local desired = math.min(e.cruise, TrafficService._turnSpeedCap(path), e.obstacleLimit)
		if e.nearPed then
			desired = math.min(desired, TrafficService.PED_CAUTION_SPEED)
		end
		if now < e.holdStopUntil then
			desired = 0
		end
		if e.v < desired then
			e.v = math.min(desired, e.v + TrafficService.ACCEL * dt)
		else
			e.v = math.max(desired, e.v - TrafficService.BRAKE * dt)
		end
		-- the carrot moves at the same quantized speed the mover drives, so they never drift apart on a straight
		local speed = TrafficService._quantize(e.v)
		if speed > 0 then
			TrafficService._advance(path, speed * dt, pick)
		end
		local pos, heading = TrafficService._pose(path)
		local target = Vector3.new(pos.X, ROAD_Y + e.yOffset, pos.Z)
		local here = chassis.Position
		if (here - target).Magnitude > TrafficService.KNOCKED_OFF_DIST then
			release(e, "knocked")
			continue
		end
		driveMovers(e, here, target, heading, speed, now, false)
	end
end

-- Swap block dummies for NPCService humanoids (at most `limit`; with `roots`, only cars out of players' close view).
local function upgradeDrivers(limit: number, roots: { Vector3 }?)
	if npcService() == nil then
		return
	end
	local n = 0
	for car, e in entries do
		if n >= limit then
			break
		end
		local old = e.npc
		if e.released or car.destroyed or old == nil or old.Parent == nil or isHumanoidDriver(old) then
			continue
		end
		if roots and minDist(e.chassis.CFrame.Position, roots) < TrafficService.UPGRADE_HIDDEN_DIST then
			continue
		end
		if not wantsHuman(npcService(), car) then
			continue -- closed shell: the dummy stays (nobody can see it)
		end
		local human = attachDriver(car, false)
		if not human then
			break -- not ready / over budget
		end
		e.npc = human
		old:Destroy()
		n += 1
	end
end

local function countEntries(): number
	local n = 0
	for _ in entries do
		n += 1
	end
	return n
end

function TrafficService.getCount(): number
	return countEntries()
end

local function targetCount(playerCount: number): number
	if playerCount <= 0 then
		return 0
	end
	local mult = math.clamp(callNumber("EventService", "getTrafficMultiplier", 1), 0, 4)
	return math.min(TrafficService.MAX_COUNT, math.floor(TrafficService.BASE_COUNT * mult + 0.5))
end

-- A free lane spot 150-450 studs from a random player (ring centered SPAWN_LEAD ahead of a fast one), not too close
-- to any player, not beyond the despawn range, clear of other cars. Returns (axis?, line, dir, s, lanePos).
local function findLane(
	roots: { Vector3 },
	vels: { Vector3 },
	occupied: { Vector3 }
): (Axis?, number, number, number, Vector3)
	if #roots == 0 then
		return nil, 0, 0, 0, Vector3.zero
	end
	local i = rng:NextInteger(1, #roots)
	local center = roots[i]
	local v = flat(vels[i] or Vector3.zero)
	if v.Magnitude > TrafficService.SPAWN_LEAD_MIN_SPEED then
		center += v.Unit * TrafficService.SPAWN_LEAD
	end
	for _ = 1, 8 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(TrafficService.SPAWN_RING[1], TrafficService.SPAWN_RING[2])
		local axis, line, s =
			TrafficService._snapToRoad(center + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
		if not axis then
			continue
		end
		local dir = if rng:NextNumber() < 0.5 then 1 else -1
		local pos = TrafficService._lanePoint(axis, line, dir, s)
		local d = minDist(pos, roots)
		if d < TrafficService.MIN_SPAWN_PLAYER_DIST or d > TrafficService.DESPAWN_DIST - 50 then
			continue
		end
		if minDist(pos, occupied) < TrafficService.SPAWN_CLEARANCE then
			continue
		end
		return axis, line, dir, s, pos
	end
	return nil, 0, 0, 0, Vector3.zero
end

local function trySpawnNear(roots: { Vector3 }, vels: { Vector3 }, occupied: { Vector3 }): boolean
	local axis, line, dir, s, pos = findLane(roots, vels, occupied)
	if not axis then
		return false
	end
	local e = spawnTraffic(axis, line, dir, s)
	if e then
		table.insert(occupied, pos)
		return true
	end
	return false
end

-- PERF-04: move a far-away car onto a fresh lane near a player instead of destroying it and building a new one
-- (a new car is a full CarBuilder model + NPC replicated to everyone; a teleport is one CFrame).
local function relocate(e: Entry, roots: { Vector3 }, vels: { Vector3 }, occupied: { Vector3 }): boolean
	local car = e.car
	if e.released or car.destroyed or car.wrecked or car.kind ~= "Traffic" or car.driver ~= nil then
		return false
	end
	local axis, line, dir, s, lanePos = findLane(roots, vels, occupied)
	if not axis then
		return false
	end
	local path = TrafficService._newPath(axis, line, dir, s, pick)
	local pos, heading = TrafficService._pose(path)
	local chassis = e.chassis
	pcall(function()
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
	end)
	VehicleService.teleport(car, CFrame.lookAt(pos, pos + heading) * CFrame.new(0, e.yOffset, 0))
	e.path = path
	e.v = e.cruise * 0.6
	e.obstacleLimit = math.huge
	e.blockedSince = nil
	e.blockerKind = nil
	e.ghostUntil = 0
	e.holdStopUntil = 0
	e.nearPed = false
	e.patience = rng:NextNumber(TrafficService.PATIENCE[1], TrafficService.PATIENCE[2])
	local target = Vector3.new(pos.X, ROAD_Y + e.yOffset, pos.Z)
	local speed = TrafficService._quantize(e.v)
	driveMovers(e, target, target, heading, speed, os.clock(), true)
	pcall(function()
		chassis.AssemblyLinearVelocity = heading * speed
	end)
	if car.health < car.maxHealth then
		car.health = car.maxHealth -- VehicleService's life pass syncs the Health attribute
	end
	table.insert(occupied, lanePos)
	return true
end

local function managePass()
	for car, e in entries do
		if car.destroyed then
			release(e, nil)
		end
	end
	local players = Players:GetPlayers()
	local nRoots = collectPlayers()
	local roots, vels = rootsBuf, velsBuf
	local target = targetCount(#players)

	local occupied: { Vector3 }? = nil
	local function getOccupied(): { Vector3 }
		local o = occupied
		if o == nil then
			o = {}
			for _, car in VehicleService.allInto(manageCars) do
				if not car.destroyed and car.kind ~= "Parked" then
					table.insert(o, car.chassis.CFrame.Position)
				end
			end
			table.clear(manageCars)
			occupied = o
		end
		return o
	end

	-- far-away traffic (or everything when nobody is around): recycled near a player while we still want the cars,
	-- destroyed otherwise. A share is rebuilt anyway (all of it during a luck event) so the rolls keep changing.
	local count = 0
	table.clear(farBuf)
	for _, e in entries do
		if nRoots == 0 or minDist(e.chassis.CFrame.Position, roots) > TrafficService.DESPAWN_DIST then
			table.insert(farBuf, e)
		else
			count += 1
		end
	end
	local boosted = callNumber("EventService", "getLuck", 1) > 1
	local recycled = 0
	for _, e in farBuf do
		local moved = false
		if
			count < target
			and recycled < TrafficService.RECYCLES_PER_TICK
			and not boosted
			and rng:NextNumber() >= TrafficService.REROLL_CHANCE
		then
			moved = relocate(e, roots, vels, getOccupied())
		end
		if moved then
			recycled += 1
			count += 1
		else
			release(e, "despawn")
			VehicleService.destroy(e.car, "despawn")
		end
	end
	table.clear(farBuf)
	-- rush hour over: trim the farthest extra car (out of view only)
	if count > target + 2 then
		local farCar: Car? = nil
		local farDist = 250
		for car, e in entries do
			local d = minDist(e.chassis.CFrame.Position, roots)
			if d > farDist then
				farCar, farDist = car, d
			end
		end
		if farCar then
			TrafficService.release(farCar, "despawn")
			VehicleService.destroy(farCar, "despawn")
			count -= 1
		end
	end

	if nRoots > 0 then
		local NPC = npcService()
		if NPC and typeof(NPC.isReady) == "function" and NPC.isReady() then
			upgradeDrivers(TrafficService.UPGRADES_PER_TICK, roots)
		end
	end

	if count >= target or nRoots == 0 then
		return
	end
	local occ = getOccupied()
	for _ = 1, math.min(TrafficService.SPAWNS_PER_TICK, target - count) do
		trySpawnNear(roots, vels, occ)
	end
end

-- LIFECYCLE ------------------------------------------------------------------------------------------------------------

function TrafficService.init()
	VehicleService.Destroyed:Connect(function(car: any)
		local e = entries[car]
		if e then
			release(e, nil)
		end
	end)
end

function TrafficService.start()
	-- block dummies get their humanoids from the manage pass (UPGRADES_PER_TICK, out of view) once NPCService is
	-- ready: no all-at-once upgrade burst on NPCService.Ready
	local scanAcc, manageAcc = 0, 0
	local frameDt = 0
	local lastErr: { [string]: number } = {}
	local function report(name: string, err: any)
		local now = os.clock()
		if now - (lastErr[name] or -math.huge) > 10 then
			lastErr[name] = now
			warn(("[TrafficService] %s failed: %s"):format(name, tostring(err)))
		end
	end
	local function stepNow()
		step(frameDt)
	end
	RunService.Heartbeat:Connect(function(dt: number)
		frameDt = math.min(dt, 0.1)
		scanAcc += dt
		manageAcc += dt
		if scanAcc >= TrafficService.SCAN_TICK then
			scanAcc = 0
			local ok, err = pcall(scanPass, os.clock())
			if not ok then
				report("scan", err)
			end
		end
		if manageAcc >= TrafficService.MANAGE_TICK then
			manageAcc = 0
			local ok, err = pcall(managePass)
			if not ok then
				report("manage", err)
			end
		end
		local ok, err = pcall(stepNow)
		if not ok then
			report("step", err)
		end
	end)
end

return TrafficService
