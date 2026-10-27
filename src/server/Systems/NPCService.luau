--!strict
-- NPCService (docs/ART_PASS.md AP3, gta_combat §9.2 / §9.5): the city's humans - traffic / police drivers, sidewalk
-- pedestrians, shopkeepers, the BUSTED officer and armed on-foot officers. Moderate rating, no gore: pedestrians and
-- on-foot officers can be DOWNED by weapons (NPCService.damage keeps their health in the record; the Humanoid's own
-- health and Dead state stay off so the engine never breaks joints), then ragdoll with every joint intact and fade
-- out after DOWNED_FADE seconds. Drivers / shopkeepers are never damageable.
--
--  * TEMPLATES (built once in start(), off the boot path): one R15 model per role from the curated catalog outfits
--    (Server/Config/NPCOutfits) via Players:CreateHumanoidModelFromDescription(desc, R15) inside pcall (full outfit,
--    then clothing only). A role whose avatar can't load within TEMPLATE_TIMEOUT gets the procedural R15 rig instead
--    (NPCService.buildRig: plain Parts + correctly named Motor6Ds, so the default R15 animations and the seated pose
--    work on it too); a late avatar replaces it for later spawns. Templates are sanitized (no scripts, no name /
--    health display, no HumanoidDescription) and get a seated twin (hips / knees / shoulders posed via Motor6D C0).
--    Ready fires once every role has a template; until then spawnDriver returns nil and callers use their fallback
--    (TrafficService's block dummy), which they upgrade on Ready.
--  * DRIVERS: spawnDriver(seat, role) clones the seated twin, scales it under the roof (Model:ScaleTo), welds its
--    HumanoidRootPart to the seat ("ToCar"), every part Massless / non-colliding, Humanoid PlatformStand with the
--    state machine off (EvaluateStateMachine = false, states disabled): no physics or humanoid cost while driving.
--    ejectComic(npc, velocity) yeets one out: unwelded, Motor6Ds -> BallSocketConstraints (ragdoll), flung, gone
--    after EJECT_TIME.
--  * PEDESTRIANS: 10-14 civilians (PED_MIN + 1 per extra player) walk the sidewalk ring of blocks near players
--    (_sidewalkRing: block edge inset SIDEWALK_INSET from the curb, at curb height) with Humanoid:MoveTo, playing the
--    default R15 walk / idle animations (Animator:LoadAnimation, pcall). Server-owned (SetNetworkOwner(nil)), steered
--    at <= 4 Hz. They flee sideways from fast cars heading at them (_fleeDecision), fall over when a car hits them
--    (_carHitsPed sweeps each car's path since the last tick: PlatformStand FALL_TIME, then get up and keep walking)
--    and are despawned / respawned to stay within PED_DESPAWN_DIST of some player.
--  * SHOPKEEPERS: anchored, idle-animated, non-colliding: the gear shop clerk behind MapLayout.gearShopCounter(),
--    the car salesman in the Dealership (in front of the restock sign, or behind a part named "*Desk*" if one
--    exists), the hotdog vendor behind the plaza hotdog_stand AssetSlot (a small procedural cart when there is none).
--    They get knocked over by cars too, then pop back to their spot.
--  * OFFICER: spawnOfficerAt(groundCFrame, lifetime) - a visual-only cop standing there for a few seconds
--    (PoliceService: the BUSTED moment).
--  * BUDGET: at most BUDGET.total humanoids (per-kind caps: traffic / police drivers, pedestrians, shopkeepers,
--    officers; ejected ones count until removed). Over budget, spawnDriver returns nil (callers fall back to their
--    humanoid-free dummy) and no more pedestrians spawn.
--
-- Public API: Ready (Signal), isReady(), spawnDriver(seat, role?): Model?, driverVisible(car): boolean (callers skip
--   humanoid drivers in closed hero shells), eject(npc, fromVelocity?) (alias ejectComic),
--   spawnOfficerAt(cframe, lifetime?): Model?, canSpawn(kind): boolean, getCounts(), buildRig(look?, rng?): Model
--   (harness-compatible procedural R15 rig).
-- Combat v2: spawnOfficerOnFoot(cframe, loadout): Model? (budget "officerFoot"), damage(model, amount, attacker?, info?)
--   -> { applied, killed, kind, taken }, isDowned(model), witnessesNear(pos, radius): boolean, panic(pos, radius)
--   (gunfire: 70 % flee / 30 % cower), getRecordKind(model), setOfficerWeapon(model, weaponId).
--   Downed: Signal(kind, model, attacker?). Walking NPCs' body parts are CanQuery (bullets hit head / limbs).
-- Pure helpers (tests/spec/npc.spec.luau): _sidewalkRing, _clampToBlock, _fleeDecision, _carHitsPed, _budgetAllows,
--   _pedTarget, _seatedScale, _pickSpawn, _shopkeeperSpots, _poseSeated, _measure, _solveJoints, _ragdoll; test
--   hooks _buildTemplates(useAvatars), _reset().

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local CarBuilder = require(Shared.Vehicle.CarBuilder)
local MapConfig = require(Shared.Config.Map)
local MapLayout = require(Shared.Util.MapLayout)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Ragdoll = require(Shared.Combat.Ragdoll)
local WeaponModels = require(Shared.Combat.WeaponModels)
local Weapons = require(Shared.Config.Weapons)
local Animations = require(Shared.Config.Animations)
local PoliceConfig = require(Shared.Config.Police)
local NPCOutfits = require(script.Parent.Parent.Config.NPCOutfits)
local VehicleService = require(script.Parent.VehicleService)

type Car = VehicleService.Car

local NPCService = {}

NPCService.Ready = Signal.new() -- () once every role has a template
NPCService.Downed = Signal.new() -- (kind: string, model: Model, attacker: Player?)

-- TUNING -------------------------------------------------------------------------------------------------------------

local S = MapConfig.GRID_SPACING
local CURB_TOP = MapLayout.CURB_TOP
local BLOCK_HALF = (S - MapConfig.ROAD_WIDTH) / 2 -- 60: block edge (curb) from the block center

-- officerFoot is its own pool (on top of `total`): armed officers must be able to get out even when the city's
-- drivers and pedestrians fill the shared budget.
NPCService.BUDGET = {
	total = 40,
	traffic = 16,
	police = 8,
	pedestrian = 14,
	shopkeeper = 3,
	officer = 2,
	officerFoot = PoliceConfig.OFFICER_FOOT_MAX, -- armed on-foot officers (PoliceCombatService)
} :: { [string]: number }
NPCService.PED_HEALTH = 100
NPCService.DOWNED_FADE = PoliceConfig.DOWNED_FADE_AFTER -- seconds a downed body lies there before fading
NPCService.FADE_TIME = 0.6
NPCService.PANIC_RADIUS = 80
NPCService.PANIC_FLEE_CHANCE = 0.7
NPCService.COWER_TIME = 4
NPCService.WITNESS_EYE = 2 -- studs above the root for witness line of sight
NPCService.TEMPLATE_TIMEOUT = 20 -- seconds to wait for avatar templates before using procedural rigs
NPCService.PED_TICK = 0.25 -- pedestrian steering / hit / flee pass (4 Hz)
NPCService.MANAGE_TICK = 1 -- spawn / despawn pass
NPCService.PED_MIN = 10
NPCService.PED_MAX = 14
NPCService.PED_DESPAWN_DIST = 400
NPCService.PED_SPAWN_MIN = 45 -- never spawn closer than this to any player
NPCService.PED_SPAWN_MAX = 220
NPCService.PED_NEAR = 250 -- "this player's" pedestrians (spawns go to the player with the fewest)
NPCService.PED_SPAWNS_PER_TICK = 2
NPCService.SIDEWALK_INSET = 4 -- walking line: this far inside the curb (sidewalks are 8 wide)
NPCService.RING_SPACING = 28 -- max gap between ring waypoints
NPCService.WALK_SPEED = { 5.5, 8 }
NPCService.RUN_SPEED = 18
NPCService.WALK_ANIM_REF = 12.8 -- WalkSpeed at which the walk animation plays at 1x
NPCService.ARRIVE_DIST = 2.5
NPCService.MOVE_REISSUE = 4 -- re-issue MoveTo well before Humanoid's 8 s MoveTo timeout
NPCService.CORNER_PAUSE_CHANCE = 0.2
NPCService.PAUSE_TIME = { 2, 4.5 }
NPCService.FLEE_RADIUS = 25
NPCService.FLEE_SPEED = 30 -- cars slower than this don't scare anyone
NPCService.FLEE_LANE = 8 -- flee when the car's line passes closer than this
NPCService.FLEE_DIST = 12
NPCService.FLEE_TIME = 2.5
NPCService.HIT_SPEED = 12
NPCService.PED_RADIUS = 1.2
NPCService.FALL_TIME = 2
NPCService.STUCK_TIME = 2 -- walking but not moving this long: turn around (twice, then respawn)
NPCService.LOST_DIST = 30 -- this far from any sidewalk ring after a fall / flee: respawn
NPCService.EJECT_TIME = 3
NPCService.MIN_DRIVER_SCALE = 0.5
NPCService.ROOF_MARGIN = 0.3
NPCService.SEAT_BACK = 0.3 -- hips this far behind the seat center (knees stay inside the car)
NPCService.FOOT_CLEARANCE = 0.1 -- seated drivers' feet stay this far above the car floor (legs stretch in low cars)
NPCService.FLOOR_MARGIN = 0.1 -- drivers sit at least this far above the chassis bottom (never under the car)
NPCService.OFFICER_LIFETIME = 4
NPCService.LATE_STAND_CHECK = 30 -- seconds after Ready: look once more for a plaza hotdog_stand slot
NPCService.SPAWN_SKINS = { 1, 3, 5 } -- NPCOutfits.SKIN_TONES indices used for spawned drivers / pedestrians
-- Hero shells with an open seat (the rider shows). Every other shell is one opaque mesh with painted windows: a
-- seated humanoid in it is never seen (driverVisible).
NPCService.OPEN_TOP_SHELLS = {
	toilet_turbo = true,
	rubber_ducky = true,
	couch_cruiser = true,
	rocket_car = true,
	diamond_dragster = true,
} :: { [string]: boolean }

local ANIMS = {
	walk = "rbxassetid://507777826",
	idle = "rbxassetid://507766388",
}
local FACE_TEXTURE = "rbxasset://textures/face.png" -- built-in classic face (no network)
local SKIN_ATTR = "Skin"

-- TYPES ---------------------------------------------------------------------------------------------------------------

type Rec = {
	model: Model,
	kind: string, -- "traffic" | "police" | "pedestrian" | "shopkeeper" | "officer" | "ejected"
	humanoid: Humanoid?,
	root: BasePart?,
	ring: { Vector3 }?,
	perSide: number,
	idx: number,
	dir: number,
	bx: number,
	bz: number,
	state: string, -- "walk" | "idle" | "flee" | "fallen" | "stand"
	stateUntil: number,
	walkSpeed: number,
	target: Vector3?,
	lastMoveTo: number,
	lastPos: Vector3,
	prevPos: Vector3,
	stillSince: number?,
	stuckFlips: number,
	tracks: { [string]: any },
	playing: string?,
	animSpeed: number,
	home: CFrame?, -- anchored shopkeepers: where they stand
	hitAt: number,
	-- combat v2
	health: number,
	armor: number,
	downed: boolean,
	weaponId: string?, -- on-foot officers: the gun they carry
}

type FastCar = {
	pos: Vector3,
	prev: Vector3,
	vel: Vector3,
	look: Vector3,
	speed: number,
	halfLen: number,
	halfWidth: number,
}

type TemplatePlan = { key: string, outfit: string, alternate: number?, look: string? }

-- STATE ---------------------------------------------------------------------------------------------------------------

local rng = Random.new()
local ready = false
local templates: { [string]: Model } = {}
local seatedTemplates: { [string]: Model } = {}
local civilianKeys: { string } = {}
local npcs: { [Model]: Rec } = {}
local counts: { [string]: number } = {}
local folderRef: Folder? = nil
local animObjects: { [string]: Animation } = {}
local ringCache: { [string]: { Vector3 } } = {}
local lastCarPos: { [any]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any
local carBuf: { Car } = {}
local fastCars: { FastCar } = {}
local fastCount = 0
local hotdogCart: Model? = nil
local hotdogVendor: Rec? = nil

-- SMALL HELPERS -------------------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
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

local function blockKey(bx: number, bz: number): string
	return bx .. "," .. bz
end

local function try(fn: () -> ()): boolean
	return (pcall(fn))
end

local function npcFolder(): Folder
	local f = folderRef
	if f and f.Parent then
		return f
	end
	local existing = Workspace:FindFirstChild("NPCs")
	if existing and existing:IsA("Folder") then
		folderRef = existing
		return existing
	end
	local nf = Instance.new("Folder")
	nf.Name = "NPCs"
	nf.Parent = Workspace
	folderRef = nf
	return nf
end

local function playerRoots(): ({ Vector3 }, { Vector3 })
	local roots, looks = {}, {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(roots, root.CFrame.Position)
			table.insert(looks, root.CFrame.LookVector)
		end
	end
	return roots, looks
end

local function getHumanoid(model: Model): Humanoid?
	return model:FindFirstChildOfClass("Humanoid")
end

-- PURE GEOMETRY / DECISIONS --------------------------------------------------------------------------------------------

-- Sidewalk walking ring of block (bx, bz): a closed loop SIDEWALK_INSET inside the curb at curb height, corners first
-- on each side (NW, NE, SE, SW), with at most RING_SPACING between consecutive points. Returns (points, perSide):
-- point (k - 1) * perSide + 1 is corner k.
function NPCService._sidewalkRing(bx: number, bz: number): ({ Vector3 }, number)
	local c = MapLayout.blockCenter(bx, bz)
	local h = BLOCK_HALF - NPCService.SIDEWALK_INSET
	local corners = {
		Vector3.new(c.X - h, CURB_TOP, c.Z - h),
		Vector3.new(c.X + h, CURB_TOP, c.Z - h),
		Vector3.new(c.X + h, CURB_TOP, c.Z + h),
		Vector3.new(c.X - h, CURB_TOP, c.Z + h),
	}
	local n = math.max(1, math.ceil(2 * h / NPCService.RING_SPACING))
	local out = table.create(4 * n)
	for k = 1, 4 do
		local a, b = corners[k], corners[k % 4 + 1]
		for i = 0, n - 1 do
			table.insert(out, a:Lerp(b, i / n))
		end
	end
	return out, n
end

local function ringFor(bx: number, bz: number): ({ Vector3 }, number)
	local key = blockKey(bx, bz)
	local cached = ringCache[key]
	if cached then
		return cached, #cached // 4
	end
	local ring, n = NPCService._sidewalkRing(bx, bz)
	ringCache[key] = ring
	return ring, n
end

local function isCityBlock(bx: number, bz: number): boolean
	return bx >= MapConfig.BLOCK_MIN
		and bx <= MapConfig.BLOCK_MAX
		and bz >= MapConfig.BLOCK_MIN
		and bz <= MapConfig.BLOCK_MAX
end

-- Keep a point on block (bx, bz) (curb height, MARGIN inside the curb): fleeing pedestrians never run into the road.
function NPCService._clampToBlock(p: Vector3, bx: number, bz: number): Vector3
	local c = MapLayout.blockCenter(bx, bz)
	local lim = BLOCK_HALF - 1.5
	return Vector3.new(c.X + math.clamp(p.X - c.X, -lim, lim), CURB_TOP, c.Z + math.clamp(p.Z - c.Z, -lim, lim))
end

-- Should a pedestrian at pedPos flee from a car at carPos moving at carVel? Returns the (flat, unit) direction to run
-- (sideways out of the car's line), or nil. Only fast cars within FLEE_RADIUS whose line passes within FLEE_LANE.
function NPCService._fleeDecision(pedPos: Vector3, carPos: Vector3, carVel: Vector3): Vector3?
	local v = flat(carVel)
	local speed = v.Magnitude
	if speed < NPCService.FLEE_SPEED then
		return nil
	end
	local rel = flat(pedPos - carPos)
	local d = rel.Magnitude
	if d > NPCService.FLEE_RADIUS then
		return nil
	end
	local vdir = v / speed
	local ahead = rel:Dot(vdir)
	if ahead < -2 then
		return nil -- already past us
	end
	local lateralVec = rel - vdir * ahead
	local lateral = lateralVec.Magnitude
	if lateral > NPCService.FLEE_LANE then
		return nil
	end
	if lateral < 0.1 then
		return vdir:Cross(Vector3.yAxis) -- dead ahead: dive to the car's right
	end
	return lateralVec / lateral
end

-- Did a car sweeping from carPrev to carNow (heading look, half length / width) run into a pedestrian at pedPos?
-- The car's body is a capsule along its path, radius halfWidth + PED_RADIUS. Flat test plus a height check.
function NPCService._carHitsPed(
	pedPos: Vector3,
	carPrev: Vector3,
	carNow: Vector3,
	look: Vector3,
	halfLen: number,
	halfWidth: number
): boolean
	if math.abs(pedPos.Y - carNow.Y) > 7 then
		return false
	end
	local travel = flat(carNow - carPrev)
	local dir = if travel.Magnitude > 0.5 then travel.Unit else flat(look)
	if dir.Magnitude < 0.01 then
		dir = Vector3.new(0, 0, -1)
	else
		dir = dir.Unit
	end
	local a = flat(carPrev) - dir * halfLen
	local b = flat(carNow) + dir * halfLen
	local p = flat(pedPos)
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = if len2 > 1e-6 then math.clamp((p - a):Dot(ab) / len2, 0, 1) else 0
	local closest = a + ab * t
	return (p - closest).Magnitude <= halfWidth + NPCService.PED_RADIUS
end

-- Budget check for one more humanoid of `kind` given the live counts (ejected ones count toward the total).
function NPCService._budgetAllows(kind: string, live: { [string]: number }): boolean
	local cap = NPCService.BUDGET[kind]
	if cap == nil or kind == "total" then
		return false
	end
	if (live[kind] or 0) >= cap then
		return false
	end
	if kind == "officerFoot" then
		return true -- separate pool (see BUDGET)
	end
	local total = 0
	for k, n in live do
		if k ~= "total" and k ~= "officerFoot" then
			total += n
		end
	end
	return total < NPCService.BUDGET.total
end

-- Pedestrians wanted for this many players: none for an empty server, PED_MIN + 1 per extra player, PED_MAX cap.
function NPCService._pedTarget(players: number): number
	if players <= 0 then
		return 0
	end
	return math.min(NPCService.PED_MAX, NPCService.PED_MIN + players - 1)
end

-- Uniform scale that fits a seated figure (thighHalf + aboveHip tall at scale 1) into `room` studs above the seat.
function NPCService._seatedScale(room: number?, thighHalf: number, aboveHip: number): number
	local need = thighHalf + aboveHip
	if room == nil or need <= 0 then
		return 0.85
	end
	return math.clamp(room / need, NPCService.MIN_DRIVER_SCALE, 1)
end

-- A spawn waypoint for a pedestrian near `center`: a sidewalk ring point PED_SPAWN_MIN..PED_SPAWN_MAX from center
-- and at least PED_SPAWN_MIN from every player, preferring points behind `look` (out of that player's view).
-- Returns (bx, bz, index) or nil.
function NPCService._pickSpawn(
	center: Vector3,
	look: Vector3?,
	roots: { Vector3 },
	r: Random
): (number?, number, number)
	local reach = NPCService.PED_SPAWN_MAX + BLOCK_HALF * 1.5
	local behind: { { number } } = {}
	local any: { { number } } = {}
	local lookFlat = if look then flat(look) else Vector3.zero
	for bx = MapConfig.BLOCK_MIN, MapConfig.BLOCK_MAX do
		for bz = MapConfig.BLOCK_MIN, MapConfig.BLOCK_MAX do
			if flatDist(MapLayout.blockCenter(bx, bz), center) > reach then
				continue
			end
			local ring = ringFor(bx, bz)
			for i, p in ring do
				local d = flatDist(p, center)
				if d < NPCService.PED_SPAWN_MIN or d > NPCService.PED_SPAWN_MAX then
					continue
				end
				if minDist(p, roots) < NPCService.PED_SPAWN_MIN then
					continue
				end
				local entry = { bx, bz, i }
				table.insert(any, entry)
				if lookFlat.Magnitude > 0.1 and flat(p - center):Dot(lookFlat) < 0 then
					table.insert(behind, entry)
				end
			end
		end
	end
	local list = if #behind > 0 then behind else any
	if #list == 0 then
		return nil, 0, 0
	end
	local e = list[r:NextInteger(1, #list)]
	return e[1], e[2], e[3]
end

-- Default shopkeeper spots (ground CFrames, LookVector = facing): gear shop clerk behind the counter facing the
-- customers, car salesman in the showroom in front of the restock sign facing the open north side, hotdog vendor
-- behind the plaza cart (cart CFrame returned too: front faces the plaza center).
function NPCService._shopkeeperSpots(): { gear: CFrame, dealer: CFrame, hotdog: CFrame, cart: CFrame }
	local counter = MapLayout.gearShopCounter()
	local gear = counter * CFrame.new(0, 0.2, 3) -- local +Z = behind the counter (its front faces the street)
	local dc = MapLayout.poiCenter("Dealership")
	local dp = dc + Vector3.new(0, 0.2, 35)
	local dealer = CFrame.lookAt(dp, dp + Vector3.new(0, 0, -1))
	local pc = MapLayout.poiCenter("SpawnPlaza")
	local cp = pc + Vector3.new(12, 0, -38)
	local cart = CFrame.lookAt(cp, cp + Vector3.new(0, 0, 1))
	local hotdog = cart * CFrame.new(0, 0, 2.8)
	return { gear = gear, dealer = dealer, hotdog = hotdog, cart = cart }
end

-- RIGS ------------------------------------------------------------------------------------------------------------------

-- Procedural R15 layout in the rest pose (feet on y = 0, facing -Z). { part, size, center, joint, parent, jointPos }.
local R15_SPEC: { { any } } = {
	{
		"LowerTorso",
		Vector3.new(2, 0.4, 1),
		Vector3.new(0, 2.5, 0),
		"Root",
		"HumanoidRootPart",
		Vector3.new(0, 2.5, 0),
	},
	{ "UpperTorso", Vector3.new(2, 1.6, 1), Vector3.new(0, 3.5, 0), "Waist", "LowerTorso", Vector3.new(0, 2.7, 0) },
	{ "Head", Vector3.new(1.3, 1.3, 1.3), Vector3.new(0, 4.95, 0), "Neck", "UpperTorso", Vector3.new(0, 4.3, 0) },
}
for _, side in { { "Left", -1 }, { "Right", 1 } } do
	local n, sx = side[1], side[2]
	local ax, lx = 1.5 * sx, 0.5 * sx
	table.insert(R15_SPEC, {
		n .. "UpperArm",
		Vector3.new(1, 1.1, 1),
		Vector3.new(ax, 3.75, 0),
		n .. "Shoulder",
		"UpperTorso",
		Vector3.new(ax, 4.05, 0),
	})
	table.insert(R15_SPEC, {
		n .. "LowerArm",
		Vector3.new(1, 1, 1),
		Vector3.new(ax, 2.7, 0),
		n .. "Elbow",
		n .. "UpperArm",
		Vector3.new(ax, 3.2, 0),
	})
	table.insert(R15_SPEC, {
		n .. "Hand",
		Vector3.new(1, 0.35, 1),
		Vector3.new(ax, 2.025, 0),
		n .. "Wrist",
		n .. "LowerArm",
		Vector3.new(ax, 2.2, 0),
	})
	table.insert(R15_SPEC, {
		n .. "UpperLeg",
		Vector3.new(1, 1, 1),
		Vector3.new(lx, 1.8, 0),
		n .. "Hip",
		"LowerTorso",
		Vector3.new(lx, 2.3, 0),
	})
	table.insert(R15_SPEC, {
		n .. "LowerLeg",
		Vector3.new(1, 1, 1),
		Vector3.new(lx, 0.8, 0),
		n .. "Knee",
		n .. "UpperLeg",
		Vector3.new(lx, 1.3, 0),
	})
	table.insert(R15_SPEC, {
		n .. "Foot",
		Vector3.new(1, 0.3, 1.2),
		Vector3.new(lx, 0.15, -0.1),
		n .. "Ankle",
		n .. "LowerLeg",
		Vector3.new(lx, 0.3, 0),
	})
end
local RIG_HIP_HEIGHT = 2.3
local RIG_ROOT_CENTER = Vector3.new(0, 3.3, 0)

-- Every R15 body part name (avatar templates: all of them take the skin color under the clothing).
local R15_BODY: { [string]: boolean } = { HumanoidRootPart = true }
for _, spec in R15_SPEC do
	R15_BODY[spec[1]] = true
end

local SEATED_POSE: { [string]: CFrame } = {
	LeftHip = CFrame.Angles(math.rad(90), 0, 0), -- thighs forward
	RightHip = CFrame.Angles(math.rad(90), 0, 0),
	LeftKnee = CFrame.Angles(math.rad(-90), 0, 0), -- shins down
	RightKnee = CFrame.Angles(math.rad(-90), 0, 0),
	LeftShoulder = CFrame.Angles(math.rad(62), 0, math.rad(-6)), -- hands on the wheel
	RightShoulder = CFrame.Angles(math.rad(62), 0, math.rad(6)),
	LeftElbow = CFrame.Angles(math.rad(22), 0, 0),
	RightElbow = CFrame.Angles(math.rad(22), 0, 0),
}

local function randomCivilianLook(r: Random): NPCOutfits.Look
	local hats = { "none", "none", "cap", "cap", "straw", "fedora" }
	local hairs = { "short", "short", "long", "spiky" }
	local function pick<T>(list: { T }): T
		return list[r:NextInteger(1, #list)]
	end
	return {
		shirt = pick(NPCOutfits.CivilianShirts),
		pants = pick(NPCOutfits.CivilianPants),
		shoes = Color3.fromRGB(35, 35, 40),
		hat = pick(hats),
		hatColor = pick(NPCOutfits.HatColors),
		hair = pick(hairs),
		hairColor = pick(NPCOutfits.HairColors),
	}
end

local function rigPart(
	model: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
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
	p.Parent = model
	return p
end

-- Build the procedural R15 NPC (harness-compatible, no assets): plain Parts named like an R15 body joined by Motor6Ds
-- named like R15 joints (so the default R15 animations, the seated pose and the ragdoll all work), a Humanoid
-- (R15, HipHeight 2.3), a built-in face decal, and a role look (police cap + badge, chef toque, fedoras, hair).
-- look nil = a random civilian. Feet on y = 0, facing -Z, PrimaryPart = HumanoidRootPart.
function NPCService.buildRig(look: NPCOutfits.Look?, r: Random?): Model
	local rr = r or rng
	local lk: NPCOutfits.Look = look or randomCivilianLook(rr)
	local skin = NPCOutfits.SKIN_TONES[rr:NextInteger(1, #NPCOutfits.SKIN_TONES)]
	local shortSleeves = look == nil
	local model = Instance.new("Model")
	model.Name = "NPC"
	local root = rigPart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), CFrame.new(RIG_ROOT_CENTER), skin)
	root.Transparency = 1
	root.CanCollide = true
	root.Massless = false
	local parts: { [string]: BasePart } = { HumanoidRootPart = root }
	for _, spec in R15_SPEC do
		local name: string = spec[1]
		local color = skin
		if name == "UpperTorso" or name:find("UpperArm") then
			color = lk.shirt
		elseif name:find("LowerArm") then
			color = if shortSleeves then skin else lk.shirt
		elseif name == "LowerTorso" or name:find("Leg") then
			color = lk.pants
		elseif name:find("Foot") then
			color = lk.shoes
		end
		local p = rigPart(
			model,
			name,
			spec[2],
			CFrame.new(spec[3]),
			color,
			if name == "Head" then Enum.PartType.Ball else nil
		)
		if color == skin then
			p:SetAttribute(SKIN_ATTR, true)
		end
		parts[name] = p
	end
	for _, spec in R15_SPEC do
		local p1 = parts[spec[1]]
		local p0 = parts[spec[5]]
		local at = CFrame.new(spec[6])
		local m = Instance.new("Motor6D")
		m.Name = spec[4]
		m.Part0 = p0
		m.Part1 = p1
		m.C0 = p0.CFrame:Inverse() * at
		m.C1 = p1.CFrame:Inverse() * at
		m.Parent = p1
	end
	local head = parts.Head
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Face = Enum.NormalId.Front
	face.Texture = FACE_TEXTURE
	face.Parent = head

	-- accessories: welded to the head / torso, never collide
	local H = head.CFrame
	local function acc(name: string, size: Vector3, cf: CFrame, color: Color3, attach: BasePart, shape: Enum.PartType?)
		local p = rigPart(model, name, size, cf, color, shape)
		p.CastShadow = false
		p:SetAttribute("Accessory", true)
		local w = Instance.new("WeldConstraint")
		w.Part0 = attach
		w.Part1 = p
		w.Parent = p
		return p
	end
	local hat = lk.hat
	if lk.hair ~= "none" then
		if hat == "none" or hat == "toque" then
			local topH = if lk.hair == "spiky" then 0.5 else 0.32
			acc(
				"HairTop",
				Vector3.new(1.34, topH, 1.3),
				H * CFrame.new(0, 0.5 + topH / 2 - 0.12, 0.05),
				lk.hairColor,
				head
			)
		end
		local backH = if lk.hair == "long" then 1.35 else 0.75
		acc("HairBack", Vector3.new(1.34, backH, 0.34), H * CFrame.new(0, 0.5 - backH / 2, 0.52), lk.hairColor, head)
	end
	local VERTICAL = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (local X) -> up
	if hat == "police" or hat == "cap" then
		acc("HatCrown", Vector3.new(1.36, 0.46, 1.36), H * CFrame.new(0, 0.66, 0.04), lk.hatColor, head)
		acc("HatBrim", Vector3.new(1.3, 0.12, 0.62), H * CFrame.new(0, 0.45, -0.72), lk.hatColor, head)
		if lk.badge then
			acc(
				"HatBadge",
				Vector3.new(0.34, 0.3, 0.08),
				H * CFrame.new(0, 0.7, -0.68),
				Color3.fromRGB(255, 205, 60),
				head
			).Material =
				Enum.Material.Neon
		end
	elseif hat == "toque" then
		acc(
			"HatToque",
			Vector3.new(1.3, 1.25, 1.25),
			H * CFrame.new(0, 1.08, 0) * VERTICAL,
			lk.hatColor,
			head,
			Enum.PartType.Cylinder
		)
	elseif hat == "fedora" or hat == "straw" then
		local brim = if hat == "straw" then 2.3 else 1.9
		local hc = if hat == "straw" then Color3.fromRGB(236, 206, 128) else lk.hatColor
		acc(
			"HatBrim",
			Vector3.new(0.12, brim, brim),
			H * CFrame.new(0, 0.5, 0) * VERTICAL,
			hc,
			head,
			Enum.PartType.Cylinder
		)
		acc("HatCrown", Vector3.new(1.08, 0.58, 1.08), H * CFrame.new(0, 0.82, 0), hc, head)
	end
	local torso = parts.UpperTorso
	if lk.tie then
		acc("Tie", Vector3.new(0.28, 1.05, 0.08), torso.CFrame * CFrame.new(0, 0.1, -0.52), lk.tie, torso)
	end
	if lk.badge then
		acc(
			"Badge",
			Vector3.new(0.34, 0.38, 0.08),
			torso.CFrame * CFrame.new(-0.5, 0.35, -0.52),
			Color3.fromRGB(255, 205, 60),
			torso
		).Material =
			Enum.Material.Neon
	end

	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.HipHeight = RIG_HIP_HEIGHT
	hum.Parent = model
	local animator = Instance.new("Animator")
	animator.Parent = hum
	try(function()
		(hum :: any).AutomaticScalingEnabled = false
	end)
	model.PrimaryPart = root
	return model
end

-- HumanoidDescription for an outfit (skin under the clothing).
local function makeDescription(fields: NPCOutfits.DescriptionFields, skin: Color3): HumanoidDescription
	local d = Instance.new("HumanoidDescription")
	d.Shirt = fields.Shirt
	d.Pants = fields.Pants
	d.HatAccessory = fields.HatAccessory
	d.HairAccessory = fields.HairAccessory
	d.FaceAccessory = fields.FaceAccessory
	for _, prop in { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" } do
		try(function()
			(d :: any)[prop] = skin
		end)
	end
	return d
end

-- Avatar R15 model for an outfit (yields: loads catalog assets). nil when the engine can't build it (Lune harness,
-- asset outage): the full outfit first, then clothing only.
local function buildAvatar(outfit: NPCOutfits.Outfit, skin: Color3): Model?
	local create = (Players :: any).CreateHumanoidModelFromDescription
	if typeof(create) ~= "function" then
		return nil
	end
	local full = NPCOutfits.descriptionFields(outfit)
	local attempts: { NPCOutfits.DescriptionFields } = {
		full,
		{ Shirt = full.Shirt, Pants = full.Pants, HatAccessory = "", HairAccessory = "", FaceAccessory = "" },
	}
	for _, fields in attempts do
		local ok, model = pcall(function()
			return (Players :: any):CreateHumanoidModelFromDescription(
				makeDescription(fields, skin),
				Enum.HumanoidRigType.R15
			)
		end)
		if
			ok
			and typeof(model) == "Instance"
			and model:IsA("Model")
			and model:FindFirstChildOfClass("Humanoid")
			and model:FindFirstChild("HumanoidRootPart")
		then
			return model
		end
		if not ok then
			warn(("[NPCService] avatar %q failed: %s"):format(outfit.name, tostring(model)))
		end
	end
	return nil
end

-- Template hygiene: no scripts / sounds / descriptions, no name or health display, never dies, nothing collides
-- except the root, nothing is touchable / queryable, skin parts marked, every part in the NPC collision group (cars
-- pass through NPCs: VehicleService.ensureCollisionGroups; clones, seated twins and ragdolls inherit it).
local function sanitize(model: Model, avatar: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("HumanoidDescription") or d:IsA("Sound") or d:IsA("ForceField") then
			d:Destroy()
		end
	end
	model.Name = "NPC"
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		model.PrimaryPart = root
		root.Transparency = 1
	end
	local grouped = VehicleService.ensureCollisionGroups()
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanTouch = false
			if grouped then
				d.CollisionGroup = VehicleService.NPC_GROUP
			end
			if d ~= root then
				d.CanCollide = false
				d.CanQuery = false
			end
			if avatar and R15_BODY[d.Name] and d.Parent == model and d ~= root then
				d:SetAttribute(SKIN_ATTR, true)
			end
			if d.Parent and d.Parent:IsA("Accessory") then
				d.Massless = true
				d.CastShadow = false
			end
		end
	end
	local hum = getHumanoid(model)
	if hum then
		local props: { [string]: any } = {
			DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None,
			HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff,
			BreakJointsOnDeath = false,
			RequiresNeck = false,
			MaxHealth = 100,
			Health = 100,
			AutoRotate = true,
			WalkSpeed = 7,
		}
		for prop, value in props do
			try(function()
				(hum :: any)[prop] = value
			end)
		end
		if not hum:FindFirstChildOfClass("Animator") then
			local animator = Instance.new("Animator")
			animator.Parent = hum
		end
	end
	model:SetAttribute("NPC", true)
end

local function motorOf(model: Model, partName: string, jointName: string): Motor6D?
	local p = model:FindFirstChild(partName)
	local m = p and p:FindFirstChild(jointName)
	return if m and m:IsA("Motor6D") then m else nil
end

-- Rest-pose metrics of a rig: hip-joint midpoint relative to the root (root space), thigh half thickness (thigh depth
-- / 2, its vertical extent once seated) and the height of the top of the figure (hat included) above the hips.
function NPCService._measure(model: Model): (Vector3?, number, number)
	local root = model.PrimaryPart
	local l = motorOf(model, "LeftUpperLeg", "LeftHip")
	local r = motorOf(model, "RightUpperLeg", "RightHip")
	if not root or not l or not r then
		return nil, 0, 0
	end
	local l0, r0 = l.Part0, r.Part0
	if not l0 or not r0 then
		return nil, 0, 0
	end
	local hip = ((l0.CFrame * l.C0).Position + (r0.CFrame * r.C0).Position) / 2
	local thigh = l.Part1
	local thighHalf = if thigh then thigh.Size.Z / 2 else 0.5
	local top = -math.huge
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			local cf, s = d.CFrame, d.Size
			local half = 0.5
				* (math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z)
			top = math.max(top, cf.Position.Y + half)
		end
	end
	return root.CFrame:PointToObjectSpace(hip), thighHalf, math.max(top - hip.Y, 0)
end

-- Uniform scale about the root (what Model:ScaleTo does for a rig): part sizes and offsets, joint / attachment
-- offsets, HipHeight. Fallback for when ScaleTo is unavailable.
function NPCService._scaleRig(model: Model, s: number)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local pivot = root.CFrame
	local function scaled(cf: CFrame): CFrame
		return CFrame.new(cf.Position * s) * cf.Rotation
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local rel = pivot:ToObjectSpace(d.CFrame)
			d.Size = d.Size * s
			d.CFrame = pivot * scaled(rel)
		elseif d:IsA("Motor6D") or d:IsA("Weld") then
			d.C0 = scaled(d.C0)
			d.C1 = scaled(d.C1)
		elseif d:IsA("Attachment") then
			d.CFrame = scaled(d.CFrame)
		elseif d:IsA("SpecialMesh") and d.MeshType == Enum.MeshType.FileMesh then
			d.Scale = d.Scale * s
		end
	end
	local hum = getHumanoid(model)
	if hum then
		try(function()
			hum.HipHeight = hum.HipHeight * s
		end)
	end
end

-- Rest-pose knee height above the feet (ground under the root: HumanoidRootPart bottom is HipHeight above it).
function NPCService._shinLength(model: Model): number
	local root = model.PrimaryPart
	local knee = motorOf(model, "LeftLowerLeg", "LeftKnee")
	local hum = getHumanoid(model)
	if not root or not knee or not knee.Part0 or not hum then
		return 1.3
	end
	local hipHeight = 2
	try(function()
		hipHeight = hum.HipHeight
	end)
	local groundY = root.CFrame.Position.Y - root.Size.Y / 2 - hipHeight
	return math.max(((knee.Part0 :: BasePart).CFrame * knee.C0).Position.Y - groundY, 0.2)
end

-- Driver pose: thighs forward, shins down, hands forward on the wheel (Motor6D C0 rotations at the joints).
function NPCService._poseSeated(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			local rot = SEATED_POSE[d.Name]
			if rot then
				d.C0 = d.C0 * rot
			end
		end
	end
	model:SetAttribute("Seated", true)
end

-- Place every jointed part from the root outward (Motor6D / Weld: Part0 * C0 = Part1 * C1; WeldConstraint keeps the
-- offset it had before). The engine does this itself; used so freshly posed clones (and Lune previews / tests) have
-- consistent part CFrames before they are parented.
function NPCService._solveJoints(model: Model)
	local root = model.PrimaryPart
	if not root then
		return
	end
	local edges: { [BasePart]: { { any } } } = {}
	local function link(a: BasePart, b: BasePart, e: { any })
		edges[a] = edges[a] or {}
		table.insert(edges[a], e)
		edges[b] = edges[b] or {}
		table.insert(edges[b], e)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") or d:IsA("Weld") then
			local j = d :: any
			if j.Part0 and j.Part1 and j.Enabled ~= false then
				link(j.Part0, j.Part1, { j.Part0, j.Part1, j.C0 * j.C1:Inverse() })
			end
		elseif d:IsA("WeldConstraint") then
			local p0, p1 = d.Part0, d.Part1
			if p0 and p1 and p0:IsDescendantOf(model) and p1:IsDescendantOf(model) then
				link(p0, p1, { p0, p1, p0.CFrame:Inverse() * p1.CFrame })
			end
		end
	end
	local done: { [BasePart]: boolean } = { [root] = true }
	local queue: { BasePart } = { root }
	local head = 1
	while head <= #queue do
		local cur = queue[head]
		head += 1
		for _, e in edges[cur] or {} do
			local p0: BasePart, p1: BasePart, rel: CFrame = e[1], e[2], e[3]
			if p0 == cur and not done[p1] then
				p1.CFrame = cur.CFrame * rel
				done[p1] = true
				table.insert(queue, p1)
			elseif p1 == cur and not done[p0] then
				p0.CFrame = cur.CFrame * rel:Inverse()
				done[p0] = true
				table.insert(queue, p0)
			end
		end
	end
end

-- Ragdoll: every Motor6D but the root joint becomes a limited BallSocketConstraint (motor disabled). Shared/Combat/
-- Ragdoll owns the conversion (player deaths use it too).
function NPCService._ragdoll(model: Model)
	Ragdoll.enable(model)
end

-- TEMPLATES ------------------------------------------------------------------------------------------------------------

local function templatePlans(): { TemplatePlan }
	local plans: { TemplatePlan } = {
		{ key = "police", outfit = "police_officer", look = "police" },
		{ key = "chef", outfit = "chef_vendor", look = "chef" },
		{ key = "salesman", outfit = "car_salesman", look = "salesman" },
		{ key = "gearkeeper", outfit = "car_salesman", alternate = 1, look = "gearkeeper" },
	}
	for _, civ in NPCOutfits.civilians() do
		table.insert(plans, { key = civ, outfit = civ })
	end
	return plans
end

local function seedOf(key: string): number
	local h = 7
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 1000003
	end
	return h + 1
end

local function installTemplate(key: string, model: Model, avatar: boolean)
	sanitize(model, avatar)
	local offset, thighHalf, aboveHip = NPCService._measure(model)
	model:SetAttribute("TemplateKey", key)
	model:SetAttribute("Avatar", avatar)
	local seated = model:Clone()
	seated:SetAttribute("HipOffset", offset or Vector3.new(0, -1, 0))
	seated:SetAttribute("ThighHalf", if offset then thighHalf else 0.5)
	seated:SetAttribute("AboveHip", if offset then aboveHip else 3.5)
	seated:SetAttribute("ShinLength", NPCService._shinLength(model))
	NPCService._poseSeated(seated)
	NPCService._solveJoints(seated)
	for _, d in seated:GetDescendants() do
		if d:IsA("BasePart") then
			d.Massless = true
			d.CanCollide = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
	local old, oldSeated = templates[key], seatedTemplates[key]
	templates[key] = model
	seatedTemplates[key] = seated
	if old then
		old:Destroy()
	end
	if oldSeated then
		oldSeated:Destroy()
	end
	if key:sub(1, 9) == "civilian_" and not table.find(civilianKeys, key) then
		table.insert(civilianKeys, key)
		table.sort(civilianKeys)
	end
end

local placeShopkeepers: () -> ()

local announced = false
local function announceReady()
	ready = true
	if not announced then
		announced = true
		NPCService.Ready:Fire()
	end
end

-- Builds every role's template (yields while avatars load, up to TEMPLATE_TIMEOUT), fills the gaps with procedural
-- rigs, then marks the service ready (fires Ready unless quiet: start() places the shopkeepers first so the Ready
-- handlers' driver upgrades can't take their budget). useAvatars false (tests): procedural only, no yields.
function NPCService._buildTemplates(useAvatars: boolean, quiet: boolean?): number
	local plans = templatePlans()
	local avatars = 0
	if useAvatars then
		local pending = 0
		for _, plan in plans do
			local outfit = NPCOutfits.get(plan.outfit, plan.alternate)
			if not outfit then
				continue
			end
			pending += 1
			task.spawn(function()
				local skin = NPCOutfits.SKIN_TONES[(seedOf(plan.key) % #NPCOutfits.SKIN_TONES) + 1]
				local ok, model = pcall(buildAvatar, outfit, skin)
				if ok and model then
					local okI, err = pcall(installTemplate, plan.key, model, true)
					if okI then
						avatars += 1
					else
						warn(("[NPCService] template %s unusable: %s"):format(plan.key, tostring(err)))
					end
				end
				pending -= 1
			end)
		end
		local deadline = os.clock() + NPCService.TEMPLATE_TIMEOUT
		while pending > 0 and os.clock() < deadline do
			task.wait(0.25)
		end
	end
	for _, plan in plans do
		if templates[plan.key] == nil then
			local look = if plan.look then NPCOutfits.Looks[plan.look] else nil
			installTemplate(plan.key, NPCService.buildRig(look, Random.new(seedOf(plan.key))), false)
		end
	end
	ready = true
	if not quiet then
		announceReady()
	end
	return avatars
end

-- Pool remixes of the civilians (more variety once the base set exists; sequential, background).
local function buildRemixes()
	local pool = NPCOutfits.Pool
	for i, civ in NPCOutfits.civilians() do
		local base = NPCOutfits.get(civ)
		if base then
			local variant = NPCOutfits.poolVariant(base, pool, i)
			local skin = NPCOutfits.SKIN_TONES[((seedOf(civ) + 3) % #NPCOutfits.SKIN_TONES) + 1]
			local ok, model = pcall(buildAvatar, variant, skin)
			if ok and model then
				pcall(installTemplate, civ .. "_remix", model, true)
			end
		end
	end
end

local function pickKey(role: string): string?
	if role == "civilian" then
		if #civilianKeys == 0 then
			return nil
		end
		return civilianKeys[rng:NextInteger(1, #civilianKeys)]
	end
	if templates[role] then
		return role
	end
	return nil
end

-- REGISTRY / BUDGET ------------------------------------------------------------------------------------------------------

local function register(model: Model, kind: string): Rec
	local hum = getHumanoid(model)
	local root = model.PrimaryPart
	local pos = if root then root.CFrame.Position else Vector3.zero
	local rec: Rec = {
		model = model,
		kind = kind,
		humanoid = hum,
		root = root,
		ring = nil,
		perSide = 1,
		idx = 1,
		dir = 1,
		bx = 0,
		bz = 0,
		state = "stand",
		stateUntil = 0,
		walkSpeed = 7,
		target = nil,
		lastMoveTo = 0,
		lastPos = pos,
		prevPos = pos,
		stillSince = nil,
		stuckFlips = 0,
		tracks = {},
		playing = nil,
		animSpeed = 1,
		home = nil,
		hitAt = 0,
		health = NPCService.PED_HEALTH,
		armor = 0,
		downed = false,
		weaponId = nil,
	}
	npcs[model] = rec
	counts[kind] = (counts[kind] or 0) + 1
	return rec
end

local function setKind(rec: Rec, kind: string)
	counts[rec.kind] = math.max(0, (counts[rec.kind] or 0) - 1)
	rec.kind = kind
	counts[kind] = (counts[kind] or 0) + 1
end

local function unregister(rec: Rec)
	if npcs[rec.model] ~= rec then
		return
	end
	npcs[rec.model] = nil
	counts[rec.kind] = math.max(0, (counts[rec.kind] or 0) - 1)
	if hotdogVendor == rec then
		hotdogVendor = nil
	end
end

local function despawn(rec: Rec)
	unregister(rec)
	for _, track in rec.tracks do
		pcall(track.Stop, track, 0)
	end
	if rec.model.Parent then
		rec.model:Destroy()
	end
end

-- Drop records whose model is gone (destroyed with its car, removed after an eject, ...).
local function sweep()
	for model, rec in npcs do
		if model.Parent == nil or not model:IsDescendantOf(Workspace) then
			unregister(rec)
		end
	end
end

function NPCService.canSpawn(kind: string): boolean
	if NPCService._budgetAllows(kind, counts) then
		return true
	end
	sweep() -- counts may include NPCs that left with a destroyed car since the last pass
	return NPCService._budgetAllows(kind, counts)
end

function NPCService.getCounts(): { [string]: number }
	local out = table.clone(counts)
	local total = 0
	for _, n in counts do
		total += n
	end
	out.total = total
	return out
end

function NPCService.isReady(): boolean
	return ready
end

-- CLONES ----------------------------------------------------------------------------------------------------------------

-- Skin tone for a spawned driver / pedestrian: one of the few SPAWN_SKINS (light / medium / dark), so clients can reuse
-- the clothing composites of identical-looking humanoids instead of baking one per random tone.
function NPCService._spawnSkin(r: Random): Color3
	local idx = NPCService.SPAWN_SKINS[r:NextInteger(1, #NPCService.SPAWN_SKINS)]
	return NPCOutfits.SKIN_TONES[idx] or NPCOutfits.SKIN_TONES[1]
end

local function applySkin(model: Model, skin: Color3)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute(SKIN_ATTR) == true then
			d.Color = skin
		elseif d:IsA("BodyColors") then
			try(function()
				d.HeadColor3 = skin
				d.TorsoColor3 = skin
				d.LeftArmColor3 = skin
				d.RightArmColor3 = skin
				d.LeftLegColor3 = skin
				d.RightLegColor3 = skin
			end)
		end
	end
end

local DRIVER_STATES_OFF = {
	Enum.HumanoidStateType.Dead,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.GettingUp,
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Freefall,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.Landed,
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.Running,
	Enum.HumanoidStateType.RunningNoPhysics,
	Enum.HumanoidStateType.StrafingNoPhysics,
}
local WALKER_STATES_OFF = {
	Enum.HumanoidStateType.Dead,
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Flying,
}

local function disableStates(hum: Humanoid, states: { Enum.HumanoidStateType })
	for _, st in states do
		try(function()
			hum:SetStateEnabled(st, false)
		end)
	end
end

-- Never dies: pinned to full health (Dead is disabled too).
local function keepAlive(hum: Humanoid)
	try(function()
		if hum.Health < hum.MaxHealth then
			hum.Health = hum.MaxHealth
		end
	end)
end

local function freezeHumanoid(hum: Humanoid)
	hum.PlatformStand = true
	try(function()
		(hum :: any).EvaluateStateMachine = false
	end)
	disableStates(hum, DRIVER_STATES_OFF)
end

-- Where a driver sits in a car: (sit, room, legRoom) - sit = how far above the seat top the thighs rest (the car
-- floor: low sports cars sink their seat below the chassis bottom), room = height from there to under the roof (hero
-- shell roof when it wears one), legRoom = from there down to the floor. room / legRoom nil when unknown.
local function seatFit(car: Instance?, seat: BasePart): (number, number?, number?)
	if not car or not car:IsA("Model") then
		return 0, nil, nil
	end
	local height = if car:GetAttribute("HeroMesh") == true then car:GetAttribute("ShellHeight") else nil
	if typeof(height) ~= "number" then
		height = car:GetAttribute("Height")
	end
	local ride = car:GetAttribute("RideHeight")
	local chassis = car.PrimaryPart
	if typeof(height) ~= "number" or typeof(ride) ~= "number" or not chassis then
		return 0, nil, nil
	end
	local groundY = chassis.CFrame.Position.Y - ride
	local floorY = chassis.CFrame.Position.Y - chassis.Size.Y / 2
	local seatTop = seat.CFrame.Position.Y + seat.Size.Y / 2
	local base = math.max(seatTop, floorY + NPCService.FLOOR_MARGIN)
	return base - seatTop, groundY + height - NPCService.ROOF_MARGIN - base, base - floorY
end

-- Knee bend (degrees, 90 = shins straight down) that keeps the feet FOOT_CLEARANCE above the car floor for hips
-- hipHeight above it and shins shinLength long: low sports-car seats stretch the legs forward.
function NPCService._kneeAngle(hipHeight: number?, shinLength: number): number
	if hipHeight == nil or shinLength <= 0 then
		return 90
	end
	local sine = math.clamp((hipHeight - NPCService.FOOT_CLEARANCE) / shinLength, 0.34, 1)
	return math.deg(math.asin(sine))
end

-- Would a seated driver in this car be seen? False for a car wearing a closed hero shell: callers keep their cheap
-- humanoid-free dummy there (and only spawn a humanoid for a bail-out); true for procedural bodies (glass) and
-- open-top shells (OPEN_TOP_SHELLS, or CarBuilder.OPEN_TOP when it exports one).
function NPCService.driverVisible(car: Instance?): boolean
	if typeof(car) ~= "Instance" or car:GetAttribute("HeroMesh") ~= true then
		return true
	end
	local key = CarBuilder.shellKey(car)
	if key == nil then
		return true
	end
	local open = (CarBuilder :: any).OPEN_TOP
	if type(open) == "table" and open[key] ~= nil then
		return open[key] == true
	end
	return NPCService.OPEN_TOP_SHELLS[key] == true
end

-- A seated humanoid driver welded into the car seat (see the header). role "police" uses the police outfit; anything
-- else a random civilian. nil when not ready, over budget or the seat is unusable (callers keep their fallback).
function NPCService.spawnDriver(seatPart: BasePart, role: string?): Model?
	if not ready or typeof(seatPart) ~= "Instance" or not seatPart:IsA("BasePart") or seatPart.Parent == nil then
		return nil
	end
	local kind = if role == "police" then "police" else "traffic"
	if not NPCService.canSpawn(kind) then
		return nil
	end
	local key = pickKey(if role == "police" then "police" else "civilian")
	local tpl = key and seatedTemplates[key]
	if not tpl then
		return nil
	end
	local car = seatPart:FindFirstAncestorOfClass("Model")
	local npc = tpl:Clone()
	npc.Name = "NPCDriver"
	if kind == "traffic" then
		applySkin(npc, NPCService._spawnSkin(rng))
	end
	local offsetAttr = npc:GetAttribute("HipOffset")
	local thighAttr = npc:GetAttribute("ThighHalf")
	local aboveAttr = npc:GetAttribute("AboveHip")
	local offset: Vector3 = if typeof(offsetAttr) == "Vector3" then offsetAttr else Vector3.new(0, -1, 0)
	local thighHalf: number = if typeof(thighAttr) == "number" then thighAttr else 0.5
	local aboveHip: number = if typeof(aboveAttr) == "number" then aboveAttr else 3.5
	local sit, room, legRoom = seatFit(car, seatPart)
	local s = NPCService._seatedScale(room, thighHalf, aboveHip)
	if s < 0.999 then
		local scaled = try(function()
			(npc :: any):ScaleTo(s)
		end)
		if not scaled then
			NPCService._scaleRig(npc, s) -- no Model:ScaleTo (Lune harness / older engine): same thing by hand
		end
	end
	local root = npc.PrimaryPart
	local hum = getHumanoid(npc)
	if not root or not hum then
		npc:Destroy()
		return nil
	end
	local shinAttr = npc:GetAttribute("ShinLength")
	local shin = (if typeof(shinAttr) == "number" then shinAttr else 1.3) * s
	local knee = NPCService._kneeAngle(if legRoom then legRoom + thighHalf * s else nil, shin)
	if knee < 89.5 then
		local straighten = CFrame.Angles(math.rad(90 - knee), 0, 0)
		for _, name in { "LeftKnee", "RightKnee" } do
			local m = motorOf(npc, name:sub(1, -5) .. "LowerLeg", name)
			if m then
				m.C0 = m.C0 * straighten
			end
		end
	end
	local seatCF = seatPart.CFrame
	local hip = seatCF * Vector3.new(0, seatPart.Size.Y / 2 + sit + thighHalf * s, NPCService.SEAT_BACK * s)
	npc:PivotTo(CFrame.new(hip) * seatCF.Rotation * CFrame.new(-offset * s))
	NPCService._solveJoints(npc)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "ToCar"
	weld.Part0 = root
	weld.Part1 = seatPart
	weld.Parent = root
	freezeHumanoid(hum)
	npc.Parent = car or seatPart.Parent
	register(npc, kind)
	return npc
end

-- Bail-out (carjack, ram, wreck): unweld from the car, ragdoll, fling along fromVelocity's horizontal direction
-- (25..50 studs/s, random when it is ~zero) plus an upward pop and a tumble, then gone after EJECT_TIME.
function NPCService.ejectComic(npcModel: Model, fromVelocity: Vector3?)
	if typeof(npcModel) ~= "Instance" or not npcModel:IsA("Model") or npcModel.Parent == nil then
		return
	end
	local npc = npcModel
	local root = npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		npc:Destroy()
		return
	end
	local rec = npcs[npc]
	if rec then
		if rec.kind ~= "ejected" then
			setKind(rec, "ejected")
		end
	else
		rec = register(npc, "ejected")
	end
	-- 1) unweld from the car (any joint to a part outside the NPC)
	for _, d in npc:GetDescendants() do
		if d:IsA("WeldConstraint") or d:IsA("Weld") then
			local p0, p1 = d.Part0, d.Part1
			if (p0 and not p0:IsDescendantOf(npc)) or (p1 and not p1:IsDescendantOf(npc)) then
				d:Destroy()
			end
		end
	end
	-- 2) out of the car model (a despawning car must not take it along), above the roof
	local v = if typeof(fromVelocity) == "Vector3" then flat(fromVelocity) else Vector3.zero
	local dir = if v.Magnitude > 0.5 then v.Unit else flat(rng:NextUnitVector())
	if dir.Magnitude < 0.1 then
		dir = Vector3.new(1, 0, 0)
	else
		dir = dir.Unit
	end
	local speed = math.clamp(v.Magnitude, 25, 50)
	npc.Name = "NPCEjected"
	npc.Parent = npcFolder()
	npc:PivotTo(root.CFrame + Vector3.new(0, 3.5, 0) + dir * 3)
	-- 3) physics on: body parts collide (so they tumble on the ground), the root and accessories don't
	for _, d in npc:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanTouch = false
			local body = d.Parent == npc and d ~= root and R15_BODY[d.Name] == true
			d.Massless = not body
			d.CanCollide = body
		end
	end
	NPCService._ragdoll(npc)
	local hum = getHumanoid(npc)
	if hum then
		freezeHumanoid(hum)
		keepAlive(hum)
	end
	local fling = dir * speed + Vector3.new(0, rng:NextNumber(50, 70), 0)
	local spin = dir:Cross(Vector3.yAxis) * rng:NextNumber(-14, -8) + Vector3.new(0, rng:NextNumber(-6, 6), 0)
	for _, d in npc:GetDescendants() do
		if d:IsA("BasePart") then
			try(function()
				d.AssemblyLinearVelocity = fling
				d:SetNetworkOwner(nil)
			end)
		end
	end
	local torso = npc:FindFirstChild("UpperTorso")
	if torso and torso:IsA("BasePart") then
		try(function()
			torso.AssemblyAngularVelocity = spin
		end)
	end
	task.delay(NPCService.EJECT_TIME, function()
		if npc.Parent then
			npc:Destroy()
		end
		unregister(rec :: Rec)
	end)
end

NPCService.eject = NPCService.ejectComic -- v2 name (gta_combat §13.2); ejectComic stays for older callers

-- A standing NPC (feet at groundCF, facing its LookVector) in the NPCs folder. anchored: a non-colliding statue
-- that only animates (shopkeepers / officer).
local function spawnStanding(key: string, groundCF: CFrame, anchored: boolean, kind: string, skin: Color3?): Rec?
	local tpl = templates[key]
	if not tpl then
		return nil
	end
	local npc = tpl:Clone()
	if skin then
		applySkin(npc, skin)
	end
	local root = npc.PrimaryPart
	local hum = getHumanoid(npc)
	if not root or not hum then
		npc:Destroy()
		return nil
	end
	local hip = 2
	try(function()
		hip = hum.HipHeight
	end)
	npc:PivotTo(groundCF * CFrame.new(0, hip + root.Size.Y / 2, 0))
	if anchored then
		root.Anchored = true
		for _, d in npc:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanQuery = false
			end
		end
	else
		root.CanCollide = true -- walkers: the root is their collision box (limbs never collide)
		-- ...but every body part is hittable by bullets (head, limbs: the client's hit ray must reach them; the
		-- templates turn CanQuery off everywhere but the root). Accessories and carried guns stay unqueryable, and
		-- limbs keep CanCollide = false, so car wheel rays (RespectCanCollide) still ignore them.
		for _, d in npc:GetChildren() do
			if d:IsA("BasePart") and R15_BODY[d.Name] then
				d.CanQuery = true
			end
		end
	end
	npc.Name = if kind == "pedestrian"
		then "Pedestrian"
		elseif kind == "officer" or kind == "officerFoot" then "Officer"
		else "Shopkeeper"
	npc.Parent = npcFolder()
	disableStates(hum, WALKER_STATES_OFF)
	keepAlive(hum)
	local rec = register(npc, kind)
	if anchored then
		rec.home = root.CFrame
	end
	return rec
end

-- ANIMATION -------------------------------------------------------------------------------------------------------------

local function animation(name: string): Animation
	local a = animObjects[name]
	if a == nil then
		a = Instance.new("Animation")
		a.Name = name
		a.AnimationId = ANIMS[name]
		animObjects[name] = a
	end
	return a :: Animation
end

local function loadTracks(rec: Rec)
	local hum = rec.humanoid
	if not hum then
		return
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for name in ANIMS do
		local ok, track = pcall(function()
			return (animator :: any):LoadAnimation(animation(name))
		end)
		if ok and track then
			try(function()
				track.Looped = true
				track.Priority = if name == "walk" then Enum.AnimationPriority.Movement else Enum.AnimationPriority.Idle
			end)
			rec.tracks[name] = track
		end
	end
end

-- Switch the looping track (and its speed) only when it changes: every call replicates.
local function playAnim(rec: Rec, name: string?, speed: number?)
	local switched = rec.playing ~= name
	if switched then
		local old = rec.playing and rec.tracks[rec.playing]
		if old then
			pcall(old.Stop, old, 0.2)
		end
		rec.playing = name
		local track = name and rec.tracks[name]
		if track then
			pcall(track.Play, track, 0.2)
		end
	end
	local track = name and rec.tracks[name]
	if track and speed then
		local sp = math.clamp(speed, 0.4, 2)
		if switched or math.abs(sp - rec.animSpeed) > 0.05 then
			rec.animSpeed = sp
			pcall(track.AdjustSpeed, track, sp)
		end
	end
end

-- OFFICER (BUSTED moment) ---------------------------------------------------------------------------------------------

-- A visual-only police officer standing at groundCFrame (feet; facing its LookVector) for `lifetime` seconds.
function NPCService.spawnOfficerAt(cframe: CFrame, lifetime: number?): Model?
	if typeof(cframe) ~= "CFrame" or not ready or not NPCService.canSpawn("officer") then
		return nil
	end
	local rec = spawnStanding("police", cframe, true, "officer")
	if not rec then
		return nil
	end
	loadTracks(rec)
	playAnim(rec, "idle")
	local model = rec.model
	local life = if typeof(lifetime) == "number" then math.clamp(lifetime, 0.5, 30) else NPCService.OFFICER_LIFETIME
	task.delay(life, function()
		despawn(rec)
		if model.Parent then
			model:Destroy()
		end
	end)
	return model
end

-- PEDESTRIANS -----------------------------------------------------------------------------------------------------------

local function moveTo(rec: Rec, target: Vector3, now: number)
	rec.target = target
	rec.lastMoveTo = now
	local hum = rec.humanoid
	if hum then
		try(function()
			hum:MoveTo(target)
		end)
	end
end

local function advance(rec: Rec)
	local ring = rec.ring
	if ring then
		rec.idx = ((rec.idx - 1 + rec.dir) % #ring) + 1
	end
end

-- Back to the nearest point of a sidewalk ring (this block's, or the block it ended up on). False = lost: respawn.
local function rejoin(rec: Rec, now: number): boolean
	local root = rec.root
	if not root then
		return false
	end
	local pos = root.CFrame.Position
	local bx, bz = MapLayout.blockAt(pos)
	local candidates = { { rec.bx, rec.bz } }
	if isCityBlock(bx, bz) and (bx ~= rec.bx or bz ~= rec.bz) then
		table.insert(candidates, { bx, bz })
	end
	local best, bestD, bestBlock = 0, math.huge, candidates[1]
	for _, b in candidates do
		local ring = ringFor(b[1], b[2])
		for i, p in ring do
			local d = flatDist(p, pos)
			if d < bestD then
				best, bestD, bestBlock = i, d, b
			end
		end
	end
	if bestD > NPCService.LOST_DIST then
		return false
	end
	local ring, perSide = ringFor(bestBlock[1], bestBlock[2])
	rec.ring, rec.perSide = ring, perSide
	rec.bx, rec.bz = bestBlock[1], bestBlock[2]
	rec.idx = best
	rec.state = "walk"
	rec.stillSince = nil
	rec.stuckFlips = 0
	local hum = rec.humanoid
	if hum then
		hum.WalkSpeed = rec.walkSpeed
	end
	moveTo(rec, ring[best], now)
	return true
end

local function knockDown(rec: Rec, vel: Vector3, now: number)
	local root, hum = rec.root, rec.humanoid
	if not root or not hum then
		return
	end
	rec.state = "fallen"
	rec.stateUntil = now + NPCService.FALL_TIME
	rec.hitAt = now
	playAnim(rec, nil)
	if rec.home then
		root.Anchored = false
		root.CanCollide = true -- anchored statues don't collide; a tumbling one must land on the floor
	end
	hum.PlatformStand = true
	local v = flat(vel)
	local push = if v.Magnitude > 0.5
		then v.Unit * math.clamp(v.Magnitude * 0.7, 18, 45)
		else flat(rng:NextUnitVector()) * 20
	local axis = if push.Magnitude > 0.1 then push.Unit:Cross(Vector3.yAxis) else Vector3.xAxis
	local pos = root.CFrame.Position
	try(function()
		root.AssemblyLinearVelocity = push + Vector3.new(0, rng:NextNumber(28, 40), 0)
		root.AssemblyAngularVelocity = axis * -rng:NextNumber(6, 10) + Vector3.new(0, rng:NextNumber(-4, 4), 0)
		root:SetNetworkOwner(nil)
	end)
	pcall(Net.fireNear, "Sound", pos, 120, "BodyFall", pos)
end

local function getUp(rec: Rec, now: number)
	local root, hum = rec.root, rec.humanoid
	if not root or not hum then
		despawn(rec)
		return
	end
	hum.PlatformStand = false
	keepAlive(hum)
	try(function()
		root.AssemblyAngularVelocity = Vector3.zero
		root.AssemblyLinearVelocity = Vector3.zero
	end)
	local home = rec.home
	if home then
		root.CanCollide = false
		rec.model:PivotTo(home)
		root.Anchored = true
		rec.state = "stand"
		return
	end
	-- back on its feet where it landed (keeping its heading)
	local p = root.CFrame.Position + Vector3.new(0, 1, 0)
	local look = flat(root.CFrame.LookVector)
	if look.Magnitude < 0.1 then
		look = Vector3.new(0, 0, -1)
	end
	root.CFrame = CFrame.lookAt(p, p + look.Unit)
	try(function()
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)
	if not rejoin(rec, now) then
		despawn(rec)
	end
end

local function startFlee(rec: Rec, pos: Vector3, dir: Vector3, now: number)
	rec.state = "flee"
	rec.stateUntil = now + NPCService.FLEE_TIME
	local hum = rec.humanoid
	if hum then
		hum.WalkSpeed = NPCService.RUN_SPEED
	end
	moveTo(rec, NPCService._clampToBlock(pos + dir * NPCService.FLEE_DIST, rec.bx, rec.bz), now)
	playAnim(rec, "walk", NPCService.RUN_SPEED / NPCService.WALK_ANIM_REF)
end

-- COMBAT (v2) -----------------------------------------------------------------------------------------------------------

local gunAnimObjects: { [string]: Animation } = {}

local function playGunHold(rec: Rec, weaponId: string)
	local def = Weapons.get(weaponId)
	local hum = rec.humanoid
	if not def or not hum then
		return
	end
	local key = def.anims.idle
	local anim = Animations[key]
	if not anim or anim.id == "" then
		return
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local a = gunAnimObjects[key]
	if not a then
		a = Instance.new("Animation")
		a.AnimationId = anim.id
		gunAnimObjects[key] = a
	end
	pcall(function()
		local track = (animator :: any):LoadAnimation(a)
		track.Priority = anim.priority
		track.Looped = true
		track:Play(0.2)
		rec.tracks.gun = track
	end)
end

-- Puts a weapon model in the NPC's right hand (visual; PoliceCombatService does the shooting).
local function armNpc(model: Model, weaponId: string)
	local def = Weapons.get(weaponId)
	local hand = model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")
	if not def or not hand or not hand:IsA("BasePart") then
		return
	end
	local gun = Instance.new("Model")
	gun.Name = "Weapon"
	local handle = WeaponModels.assemble(gun, def.asset.model, def.asset.scale)
	WeaponModels.weld(gun, handle)
	local grip = hand:FindFirstChild("RightGripAttachment")
	local gripCF = if grip and grip:IsA("Attachment") then grip.CFrame else CFrame.new(0, -hand.Size.Y / 2, 0)
	handle.CFrame = hand.CFrame * gripCF * def.asset.grip:Inverse()
	for _, d in gun:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.Massless = true
		end
	end
	local w = Instance.new("WeldConstraint")
	w.Part0 = hand
	w.Part1 = handle
	w.Parent = handle
	gun.Parent = model
end

-- An armed police officer on foot at groundCFrame (feet), server-owned and walking (PoliceCombatService steers it).
-- loadout: { weapon: string, armor: number? }. Budget "officerFoot" (PoliceConfig.OFFICER_FOOT_MAX).
function NPCService.spawnOfficerOnFoot(cframe: CFrame, loadout: { weapon: string, armor: number? }): Model?
	if typeof(cframe) ~= "CFrame" or not ready or not NPCService.canSpawn("officerFoot") then
		return nil
	end
	local rec = spawnStanding("police", cframe, false, "officerFoot")
	if not rec then
		return nil
	end
	rec.health = PoliceConfig.OFFICER_HEALTH
	rec.armor = math.max(0, loadout.armor or 0)
	rec.weaponId = loadout.weapon
	rec.state = "stand"
	local root, hum = rec.root, rec.humanoid
	if hum then
		hum.WalkSpeed = 15
	end
	if root then
		try(function()
			root:SetNetworkOwner(nil)
		end)
	end
	if loadout.weapon ~= "taser" then
		armNpc(rec.model, loadout.weapon)
	else
		armNpc(rec.model, "pistol") -- holstered look until the custom taser model; tasing is server-side
	end
	loadTracks(rec)
	playAnim(rec, "idle")
	playGunHold(rec, loadout.weapon)
	rec.model:SetAttribute("Officer", true)
	return rec.model
end

-- Swap an on-foot officer's gun (PoliceCombatService: a 1-star taser officer draws his star's gun when the chase
-- escalates): the hand model and the hold animation follow.
function NPCService.setOfficerWeapon(model: Model, weaponId: string)
	local rec = npcs[model]
	if not rec or rec.downed or rec.kind ~= "officerFoot" or rec.weaponId == weaponId then
		return
	end
	rec.weaponId = weaponId
	local old = model:FindFirstChild("Weapon")
	if old and old:IsA("Model") then
		old:Destroy()
	end
	armNpc(model, if weaponId == "taser" then "pistol" else weaponId)
	local held = rec.tracks.gun
	if held then
		pcall(function()
			held:Stop(0.2)
		end)
		rec.tracks.gun = nil
	end
	playGunHold(rec, weaponId)
end

-- Walk / idle animation for externally steered NPCs (PoliceCombatService).
function NPCService.setMoving(model: Model, moving: boolean, speed: number?)
	local rec = npcs[model]
	if not rec or rec.downed then
		return
	end
	if moving then
		playAnim(rec, "walk", (speed or 12) / NPCService.WALK_ANIM_REF)
	else
		playAnim(rec, "idle")
	end
end

function NPCService.isDowned(model: Model): boolean
	local rec = npcs[model]
	return rec ~= nil and rec.downed
end

function NPCService.getRecordKind(model: Model): string?
	local rec = npcs[model]
	return rec and rec.kind
end

local function fadeOut(rec: Rec)
	local model = rec.model
	task.delay(NPCService.DOWNED_FADE, function()
		if model.Parent == nil then
			unregister(rec)
			return
		end
		local steps = 6
		for i = 1, steps do
			local tr = i / steps
			for _, d in model:GetDescendants() do
				local fades = (d:IsA("BasePart") and d.Name ~= "HumanoidRootPart") or d:IsA("Decal")
				if fades then
					local item = d :: any
					item.Transparency = math.max(item.Transparency, tr)
				end
			end
			task.wait(NPCService.FADE_TIME / steps)
		end
		despawn(rec)
	end)
end

-- Downed: ragdoll with every joint intact (no blood, no limb loss), fade after DOWNED_FADE. No persistence.
local function down(rec: Rec, fromDir: Vector3?, attacker: Player?)
	if rec.downed then
		return
	end
	rec.downed = true
	rec.state = "downed"
	local model = rec.model
	local root, hum = rec.root, rec.humanoid
	for _, track in rec.tracks do
		pcall(track.Stop, track, 0.1)
	end
	rec.playing = nil
	if rec.home and root then
		root.Anchored = false
	end
	if hum then
		hum.PlatformStand = true
		try(function()
			hum:MoveTo(root and root.Position or Vector3.zero)
		end)
	end
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanQuery = false
			d.CanTouch = false
			local body = d ~= root and R15_BODY[d.Name] == true
			d.CanCollide = body
		end
	end
	Ragdoll.enable(model)
	local push = if fromDir and fromDir.Magnitude > 0.1 then flat(fromDir).Unit * 6 else Vector3.zero
	if root then
		try(function()
			root.AssemblyLinearVelocity = push + Vector3.new(0, 4, 0)
			root:SetNetworkOwner(nil)
		end)
		pcall(Net.fireNear, "Sound", root.Position, 120, "BodyFall", root.Position)
	end
	local kind = rec.kind
	NPCService.Downed:Fire(kind, model, attacker)
	fadeOut(rec)
end

-- Weapon damage to an NPC (gta_combat §9.5). Only pedestrians and on-foot officers can be hurt. Officers' armor
-- absorbs first. Returns { applied, killed, kind, taken }.
function NPCService.damage(model: Model, amount: number, attacker: Player?, info: any): { [string]: any }
	local rec = npcs[model]
	if not rec or rec.downed or typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return { applied = false, killed = false }
	end
	local kind = rec.kind
	local damageable = kind == "pedestrian" or kind == "officerFoot"
	if not damageable then
		return { applied = false, killed = false }
	end
	local raw = math.min(amount, 1e4)
	local fromArmor = math.min(rec.armor, raw)
	rec.armor -= fromArmor
	local taken = raw - fromArmor
	rec.health = math.max(0, rec.health - taken)
	rec.hitAt = os.clock()
	local fromDir: Vector3? = nil
	if typeof(info) == "table" and typeof(info.from) == "Vector3" and rec.root then
		fromDir = rec.root.Position - info.from
	end
	local outKind = if kind == "officerFoot" then "officer" else "pedestrian"
	if rec.health <= 0 then
		down(rec, fromDir, attacker)
		return { applied = true, killed = true, kind = outKind, taken = taken + fromArmor }
	end
	-- hit but standing: pedestrians run from where the shot came from
	if kind == "pedestrian" and rec.root and rec.ring then
		local away = if fromDir then flat(fromDir) else flat(rng:NextUnitVector())
		if away.Magnitude > 0.1 then
			startFlee(rec, rec.root.Position, away.Unit, os.clock())
		end
	end
	return { applied = true, killed = false, kind = outKind, taken = taken + fromArmor }
end

local witnessParams: RaycastParams? = nil

local function lineOfSight(a: Vector3, b: Vector3): boolean
	local p = witnessParams
	if not p then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.IgnoreWater = true
		p.RespectCanCollide = true
		witnessParams = p
	end
	local exclude: { Instance } = { npcFolder() }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(exclude, pl.Character)
		end
	end
	for _, name in { "Vehicles", "Effects" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	p.FilterDescendantsInstances = exclude
	local dir = b - a
	if dir.Magnitude < 1 then
		return true
	end
	return Workspace:Raycast(a, dir, p) == nil
end

-- Does any pedestrian or on-foot officer within `radius` of pos have line of sight to it?
function NPCService.witnessesNear(pos: Vector3, radius: number): boolean
	local eyeUp = Vector3.new(0, NPCService.WITNESS_EYE, 0)
	for model, rec in npcs do
		if not rec.downed and (rec.kind == "pedestrian" or rec.kind == "officerFoot" or rec.kind == "shopkeeper") then
			local root = rec.root
			if root and model.Parent then
				local p = root.CFrame.Position
				if (p - pos).Magnitude <= radius and lineOfSight(p + eyeUp, pos + eyeUp) then
					return true
				end
			end
		end
	end
	return false
end

-- Gunfire panic: pedestrians within `radius` flee (70 %) or cower in place (30 %).
function NPCService.panic(pos: Vector3, radius: number?)
	local r = radius or NPCService.PANIC_RADIUS
	local now = os.clock()
	for _, rec in npcs do
		if rec.kind == "pedestrian" and not rec.downed and rec.root and rec.state ~= "fallen" then
			local p = rec.root.CFrame.Position
			local away = flat(p - pos)
			if away.Magnitude <= r and rec.state ~= "flee" and rec.state ~= "cower" then
				if rng:NextNumber() < NPCService.PANIC_FLEE_CHANCE then
					local dir = if away.Magnitude > 0.5 then away.Unit else flat(rng:NextUnitVector())
					if dir.Magnitude > 0.1 then
						startFlee(rec, p, dir.Unit, now)
						rec.stateUntil = now + NPCService.FLEE_TIME * 2
					end
				else
					rec.state = "cower"
					rec.stateUntil = now + NPCService.COWER_TIME
					local hum = rec.humanoid
					if hum then
						try(function()
							hum:MoveTo(p)
						end)
					end
					playAnim(rec, "idle")
				end
			end
		end
	end
end

-- Every car moving at HIT_SPEED+ (position now and at the last pass, velocity, footprint).
local function collectCars()
	fastCount = 0
	for _, car in VehicleService.allInto(carBuf) do
		if car.destroyed then
			lastCarPos[car] = nil
			continue
		end
		local ch = car.chassis
		if not ch or not ch.Parent then
			continue
		end
		local pos = ch.CFrame.Position
		local prev = lastCarPos[car]
		lastCarPos[car] = pos
		local vel = ch.AssemblyLinearVelocity
		local speed = math.sqrt(vel.X * vel.X + vel.Z * vel.Z)
		if speed < NPCService.HIT_SPEED then
			continue
		end
		-- a teleport (recycle / rubber band) is not a sweep
		if prev == nil or (pos - prev).Magnitude > speed * NPCService.PED_TICK * 2 + 10 then
			prev = pos
		end
		local model = car.model
		local len = model:GetAttribute("Length")
		local width = model:GetAttribute("Width")
		fastCount += 1
		local fc = fastCars[fastCount]
		if fc == nil then
			fc = {
				pos = pos,
				prev = pos,
				vel = vel,
				look = Vector3.zero,
				speed = 0,
				halfLen = 0,
				halfWidth = 0,
			}
			fastCars[fastCount] = fc
		end
		local f = fc :: FastCar
		f.pos, f.prev, f.vel, f.speed = pos, prev :: Vector3, vel, speed
		f.look = ch.CFrame.LookVector
		f.halfLen = if typeof(len) == "number" then len / 2 else 7
		f.halfWidth = if typeof(width) == "number" then width / 2 else 3.5
	end
	table.clear(carBuf)
end

local function hitBy(pos: Vector3, prevPos: Vector3): FastCar?
	for i = 1, fastCount do
		local c = fastCars[i]
		if
			NPCService._carHitsPed(pos, c.prev, c.pos, c.look, c.halfLen, c.halfWidth)
			or NPCService._carHitsPed(prevPos, c.prev, c.pos, c.look, c.halfLen, c.halfWidth)
		then
			return c
		end
	end
	return nil
end

local function fleeDir(pos: Vector3): Vector3?
	for i = 1, fastCount do
		local c = fastCars[i]
		local dir = NPCService._fleeDecision(pos, c.pos, c.vel)
		if dir then
			return dir
		end
	end
	return nil
end

local function stepWalker(rec: Rec, now: number)
	if rec.downed then
		return -- lying there until fadeOut removes it
	end
	local root, hum = rec.root, rec.humanoid
	if not root or not hum or root.Parent == nil or rec.model.Parent == nil then
		despawn(rec)
		return
	end
	keepAlive(hum)
	local pos = root.CFrame.Position
	local prevPos = rec.prevPos
	rec.prevPos = pos
	if rec.state ~= "fallen" and now - rec.hitAt > 0.5 then
		local car = hitBy(pos, prevPos)
		if car then
			knockDown(rec, car.vel, now)
			return
		end
	end
	if rec.state == "fallen" then
		if now >= rec.stateUntil then
			getUp(rec, now)
		end
		return
	end
	if rec.kind ~= "pedestrian" then
		playAnim(rec, "idle")
		return
	end
	local ring = rec.ring
	if not ring then
		despawn(rec)
		return
	end
	if rec.state == "flee" or rec.state == "cower" then
		if now >= rec.stateUntil then
			if not rejoin(rec, now) then
				despawn(rec)
			end
		end
		return
	end
	local dir = fleeDir(pos)
	if dir then
		startFlee(rec, pos, dir, now)
		return
	end
	if rec.state == "idle" then
		playAnim(rec, "idle")
		if now >= rec.stateUntil then
			rec.state = "walk"
			rec.lastPos = pos
			rec.stillSince = nil
			moveTo(rec, ring[rec.idx], now)
		end
		return
	end
	-- walking the ring
	local target = rec.target or ring[rec.idx]
	if flatDist(pos, target) <= NPCService.ARRIVE_DIST then
		advance(rec)
		local corner = (rec.idx - 1) % rec.perSide == 0
		if corner and rng:NextNumber() < NPCService.CORNER_PAUSE_CHANCE then
			rec.state = "idle"
			rec.stateUntil = now + rng:NextNumber(NPCService.PAUSE_TIME[1], NPCService.PAUSE_TIME[2])
			rec.target = ring[rec.idx]
			try(function()
				hum:MoveTo(pos)
			end)
			playAnim(rec, "idle")
			return
		end
		moveTo(rec, ring[rec.idx], now)
	elseif now - rec.lastMoveTo >= NPCService.MOVE_REISSUE then
		moveTo(rec, target, now)
	end
	-- stuck on something: turn around, then give up
	if flatDist(pos, rec.lastPos) < 0.6 then
		local since = rec.stillSince or now
		rec.stillSince = since
		if now - since > NPCService.STUCK_TIME then
			rec.stuckFlips += 1
			if rec.stuckFlips > 2 then
				despawn(rec)
				return
			end
			rec.dir = -rec.dir
			advance(rec)
			rec.stillSince = now
			moveTo(rec, ring[rec.idx], now)
		end
	else
		rec.stillSince = nil
		rec.lastPos = pos
		rec.stuckFlips = 0 -- real progress (arriving at the waypoint it stands on does not count)
	end
	playAnim(rec, "walk", rec.walkSpeed / NPCService.WALK_ANIM_REF)
end

local function spawnPedestrian(center: Vector3, look: Vector3?, roots: { Vector3 }): boolean
	local key = pickKey("civilian")
	if not key then
		return false
	end
	local bx, bz, idx = NPCService._pickSpawn(center, look, roots, rng)
	if bx == nil then
		return false
	end
	local ring, perSide = ringFor(bx, bz :: number)
	local dir = if rng:NextNumber() < 0.5 then 1 else -1
	local here = ring[idx]
	local nextIdx = ((idx - 1 + dir) % #ring) + 1
	local nxt = ring[nextIdx]
	local skin = NPCService._spawnSkin(rng)
	local rec = spawnStanding(key, CFrame.lookAt(here, Vector3.new(nxt.X, here.Y, nxt.Z)), false, "pedestrian", skin)
	if not rec then
		return false
	end
	rec.ring, rec.perSide = ring, perSide
	rec.bx, rec.bz = bx, bz :: number
	rec.dir = dir
	rec.idx = nextIdx
	rec.state = "walk"
	rec.walkSpeed = rng:NextNumber(NPCService.WALK_SPEED[1], NPCService.WALK_SPEED[2])
	local root, hum = rec.root, rec.humanoid
	if hum then
		hum.WalkSpeed = rec.walkSpeed
	end
	if root then
		rec.lastPos = root.CFrame.Position
		rec.prevPos = root.CFrame.Position
		try(function()
			root:SetNetworkOwner(nil) -- server-driven: the server simulates them, no client owns them
		end)
	end
	loadTracks(rec)
	local now = os.clock()
	moveTo(rec, nxt, now)
	playAnim(rec, "walk", rec.walkSpeed / NPCService.WALK_ANIM_REF)
	return true
end

-- SHOPKEEPERS -----------------------------------------------------------------------------------------------------------

-- Ground CFrame behind a hotdog stand (AssetSlot role "hotdog_stand", or a model named like one) near the plaza.
local function findHotdogStand(): CFrame?
	local plaza = MapLayout.poiCenter("SpawnPlaza")
	local best: Instance? = nil
	local bestD = 150
	local function consider(inst: Instance)
		if inst == hotdogCart or not inst:IsA("PVInstance") or not inst:IsDescendantOf(Workspace) then
			return
		end
		local d = flatDist(inst:GetPivot().Position, plaza)
		if d < bestD then
			best, bestD = inst, d
		end
	end
	for _, inst in CollectionService:GetTagged("AssetSlot") do
		if inst:GetAttribute("Role") == "hotdog_stand" then
			consider(inst)
		end
	end
	if best == nil then
		local map = Workspace:FindFirstChild("Map")
		if map then
			for _, d in map:GetDescendants() do
				if d:IsA("Model") and d.Name:lower():gsub("_", ""):find("hotdogstand") then
					consider(d)
				end
			end
		end
	end
	local stand = best
	local cf: CFrame, size: Vector3
	if stand and stand:IsA("Model") then
		cf, size = stand:GetBoundingBox()
	elseif stand and stand:IsA("BasePart") then
		cf, size = stand.CFrame, stand.Size
	else
		return nil
	end
	local look = flat(cf.LookVector)
	look = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, 1)
	local ground = Vector3.new(cf.Position.X, cf.Position.Y - size.Y / 2, cf.Position.Z)
	local p = ground - look * (size.Z / 2 + 1.6)
	return CFrame.lookAt(p, p + look)
end

-- Ground CFrame behind a dealership desk (a part / model named "*Desk*" in the showroom), if one exists.
local function findDealerDesk(): CFrame?
	local center = MapLayout.poiCenter("Dealership")
	for _, folderName in { "Dealership", "Map" } do
		local f = Workspace:FindFirstChild(folderName)
		if f then
			for _, d in f:GetDescendants() do
				if (d:IsA("BasePart") or d:IsA("Model")) and d.Name:lower():find("desk") then
					local pv = d :: PVInstance
					local pos = pv:GetPivot().Position
					if flatDist(pos, center) < BLOCK_HALF then
						local p = Vector3.new(pos.X, CURB_TOP + 0.2, pos.Z + 2.5)
						return CFrame.lookAt(p, p + Vector3.new(0, 0, -1))
					end
				end
			end
		end
	end
	return nil
end

-- Small procedural hotdog cart (only when the city has no hotdog_stand of its own).
local function buildCart(cf: CFrame): Model
	local m = Instance.new("Model")
	m.Name = "HotdogCart"
	local function p(name: string, size: Vector3, at: CFrame, color: Color3, shape: Enum.PartType?, collide: boolean?)
		local part = Instance.new("Part")
		part.Name = name
		if shape then
			part.Shape = shape
		end
		part.Size = size
		part.CFrame = at
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Anchored = true
		part.CanCollide = collide == true
		part.CanTouch = false
		part.Parent = m
		return part
	end
	local body = p("Body", Vector3.new(6, 2.6, 3), cf * CFrame.new(0, 1.9, 0), Color3.fromRGB(230, 50, 50), nil, true)
	p("Trim", Vector3.new(6.1, 0.4, 3.1), cf * CFrame.new(0, 2.6, 0), Color3.fromRGB(255, 205, 40))
	p("Counter", Vector3.new(6.4, 0.3, 3.4), cf * CFrame.new(0, 3.35, 0), Color3.fromRGB(235, 235, 240))
	for _, x in { -2.2, 2.2 } do
		p(
			"Wheel",
			Vector3.new(0.4, 1.3, 1.3),
			cf * CFrame.new(x, 0.65, -1.2),
			Color3.fromRGB(35, 35, 40),
			Enum.PartType.Cylinder
		)
	end
	p("Pole", Vector3.new(0.25, 5, 0.25), cf * CFrame.new(0, 5.9, 0.6), Color3.fromRGB(200, 200, 210))
	p(
		"Umbrella",
		Vector3.new(0.4, 7.5, 7.5),
		cf * CFrame.new(0, 8.5, 0.6) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(255, 215, 60),
		Enum.PartType.Cylinder
	)
	p("Hotdog", Vector3.new(1.6, 0.45, 0.45), cf * CFrame.new(-1.4, 3.75, -0.6), Color3.fromRGB(210, 120, 60))
	p("Bun", Vector3.new(1.4, 0.3, 0.7), cf * CFrame.new(-1.4, 3.6, -0.6), Color3.fromRGB(240, 200, 120))
	m.PrimaryPart = body
	return m
end

local function spawnShopkeeper(key: string, cf: CFrame): Rec?
	if not NPCService.canSpawn("shopkeeper") then
		return nil
	end
	local rec = spawnStanding(key, cf, true, "shopkeeper")
	if rec then
		rec.state = "stand"
		loadTracks(rec)
		playAnim(rec, "idle")
	end
	return rec
end

local function placeHotdogVendor()
	local spots = NPCService._shopkeeperSpots()
	local cf = findHotdogStand()
	if cf == nil then
		if not hotdogCart then
			local cart = buildCart(spots.cart)
			cart.Parent = npcFolder()
			hotdogCart = cart
		end
		cf = spots.hotdog
	end
	local key = if templates.chef then "chef" else "salesman"
	hotdogVendor = spawnShopkeeper(key, cf :: CFrame)
end

placeShopkeepers = function()
	local spots = NPCService._shopkeeperSpots()
	spawnShopkeeper(if templates.gearkeeper then "gearkeeper" else "salesman", spots.gear)
	spawnShopkeeper("salesman", findDealerDesk() or spots.dealer)
	placeHotdogVendor()
end

-- A plaza hotdog_stand slot created after we placed our own cart: move the vendor there, drop the cart.
local function recheckHotdogStand()
	local cart = hotdogCart
	if not cart then
		return
	end
	local cf = findHotdogStand()
	if not cf then
		return
	end
	hotdogCart = nil
	cart:Destroy()
	local vendor = hotdogVendor
	if vendor and vendor.model.Parent then
		local root = vendor.root
		local hip = 2
		local hum = vendor.humanoid
		if hum then
			try(function()
				hip = hum.HipHeight
			end)
		end
		local home = cf * CFrame.new(0, hip + (if root then root.Size.Y / 2 else 1), 0)
		vendor.home = home
		vendor.model:PivotTo(home)
	else
		placeHotdogVendor()
	end
end

-- PASSES ----------------------------------------------------------------------------------------------------------------

local function pedPass(now: number)
	collectCars()
	for _, rec in npcs do
		if rec.kind == "pedestrian" or rec.kind == "shopkeeper" then
			local ok, err = pcall(stepWalker, rec, now)
			if not ok then
				warn("[NPCService] walker step failed: " .. tostring(err))
				despawn(rec)
			end
		end
	end
end

local function managePass()
	sweep()
	local roots, looks = playerRoots()
	local pedCount = 0
	local near = table.create(#roots, 0)
	for _, rec in npcs do
		if rec.kind ~= "pedestrian" then
			continue
		end
		local root = rec.root
		local pos = if root then root.CFrame.Position else Vector3.zero
		if #roots == 0 or not root or minDist(pos, roots) > NPCService.PED_DESPAWN_DIST or pos.Y < CURB_TOP - 30 then
			despawn(rec)
			continue
		end
		pedCount += 1
		for i, r in roots do
			if flatDist(pos, r) <= NPCService.PED_NEAR then
				near[i] += 1
			end
		end
	end
	if not ready or #roots == 0 then
		return
	end
	local target = NPCService._pedTarget(#roots)
	local spawned = 0
	while pedCount < target and spawned < NPCService.PED_SPAWNS_PER_TICK and NPCService.canSpawn("pedestrian") do
		-- the player with the fewest pedestrians around gets the next one
		local best = 1
		for i = 2, #roots do
			if near[i] < near[best] then
				best = i
			end
		end
		if not spawnPedestrian(roots[best], looks[best], roots) then
			break
		end
		near[best] += 1
		pedCount += 1
		spawned += 1
	end
end

-- LIFECYCLE -------------------------------------------------------------------------------------------------------------

-- Test / preview hooks (the live game drives these from start() and the passes).
function NPCService._placeShopkeepers()
	placeShopkeepers()
end

function NPCService._spawnPedestrian(center: Vector3, look: Vector3?, roots: { Vector3 }): boolean
	return spawnPedestrian(center, look, roots)
end

function NPCService._stepPedestrians(now: number)
	pedPass(now)
end

function NPCService._manage()
	managePass()
end

function NPCService._record(model: Model): any
	return npcs[model]
end

-- Tests: forget every template / NPC record (instances are left alone).
function NPCService._reset()
	ready = false
	announced = false
	table.clear(templates)
	table.clear(seatedTemplates)
	table.clear(civilianKeys)
	table.clear(npcs)
	table.clear(counts)
	hotdogCart = nil
	hotdogVendor = nil
end

function NPCService.init()
	npcFolder()
	VehicleService.ensureCollisionGroups() -- before any template part joins the NPC group
end

function NPCService.start()
	task.spawn(function()
		local ok, res = pcall(NPCService._buildTemplates, true, true)
		if not ok then
			warn("[NPCService] template build failed: " .. tostring(res))
			-- last resort: procedural rigs only (no yields)
			local ok2, err2 = pcall(NPCService._buildTemplates, false, true)
			if not ok2 then
				warn("[NPCService] procedural rigs failed: " .. tostring(err2))
				return
			end
		end
		local okS, errS = pcall(placeShopkeepers)
		if not okS then
			warn("[NPCService] shopkeepers failed: " .. tostring(errS))
		end
		announceReady() -- now the traffic / police dummies get their humanoids
		if ok and typeof(res) == "number" and res > 0 then
			pcall(buildRemixes)
		end
		task.delay(NPCService.LATE_STAND_CHECK, function()
			pcall(recheckHotdogStand)
		end)
	end)

	-- gunfire panic (any player's shot; PoliceCombatService calls panic for police fire)
	local weaponModule = script.Parent:FindFirstChild("WeaponService")
	if weaponModule and weaponModule:IsA("ModuleScript") then
		local okW, WeaponService = pcall(require, weaponModule :: any)
		if okW and typeof(WeaponService) == "table" and WeaponService.Fired then
			local lastPanic = 0
			WeaponService.Fired:Connect(function(_player: Player, _weaponId: string, origin: Vector3)
				local t = os.clock()
				if t - lastPanic < 0.25 or typeof(origin) ~= "Vector3" then
					return
				end
				lastPanic = t
				pcall(NPCService.panic, origin, NPCService.PANIC_RADIUS)
			end)
		end
	end

	local pedAcc, manageAcc = 0, 0
	local lastErr: { [string]: number } = {}
	local function report(name: string, err: any)
		local t = os.clock()
		if t - (lastErr[name] or -math.huge) > 10 then
			lastErr[name] = t
			warn(("[NPCService] %s failed: %s"):format(name, tostring(err)))
		end
	end
	RunService.Heartbeat:Connect(function(dt: number)
		pedAcc += dt
		manageAcc += dt
		if pedAcc >= NPCService.PED_TICK then
			pedAcc = 0
			local ok, err = pcall(pedPass, os.clock())
			if not ok then
				report("pedestrian pass", err)
			end
		end
		if manageAcc >= NPCService.MANAGE_TICK then
			manageAcc = 0
			local ok, err = pcall(managePass)
			if not ok then
				report("manage pass", err)
			end
		end
	end)
end

return NPCService
