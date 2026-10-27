--!strict
-- PoliceCombatService (gta_combat §9): police that get out and shoot back, tuned so it is never oppressive.
--
-- Per star (Config/Police.Combat): 1 = arrest only (taser <= 25 studs, 1.5 s stun, 4 s cooldown); 2 = lethal only
-- against an ARMED suspect (fired in the last 10 s or aiming at cops) and never at a car doing 20+ studs/s; 3 =
-- lethal, vests, passenger fire from cruisers within 60 studs, roadblocks; 4 = carbines + pumps, spike strips at
-- roadblocks; 5 = everything harder. (Heli sniper and SWAT are phase C3.)
--
-- On-foot officers (state machine Exit -> Cover -> Engage -> Advance -> Arrest -> Return):
--   * Exit: the suspect is on foot (or in a stopped car) within 60 studs of a stopped cruiser -> an armed officer
--     (NPCService.spawnOfficerOnFoot, budget "officerFoot", 8 per server) steps out of the driver door; the cruiser
--     holds while its officers are out (model attribute OfficersOut).
--   * Cover: behind their own cruiser on the far side from the suspect, or the nearest "CoverPoint"-tagged part
--     within 25 studs. Engage: face, line of sight from head height, and fire ONLY when the firing director grants a
--     shot. Advance: out of sight for 4 s -> move on the last known position. Arrest (1-2 stars, unarmed suspect):
--     walk up; within reach PoliceService's bust ring runs (registerBustSource). Return: suspect gone / in a fast car /
--     far away -> walk back to the cruiser and get in (despawn).
--   * Downed officers ragdoll and fade (NPCService) and drop an ammo pickup (1 magazine for the player's weapon,
--     20 s) - big chases sustain themselves without a cash grant.
-- Fairness (PoliceAim): P(hit) = acc x distance x motion x cover x vehicle x mercy; reaction delay after acquiring;
-- the first 2 shots at a new target always miss (visible impacts 2-4 studs away + whiz); a per-target DPS director;
-- hold fire on protected / passive / rookie / surrendering / safe-zone / just-respawned players, and never fire
-- through or near (3 studs of the line) a bystander player or a pedestrian.
-- Vision (§9.4): officerSees(player) = an officer's 70° / 90-stud cone with line of sight (PoliceService.isSeen).
-- Brandishing: aiming at an officer / cruiser within 40 studs for 1.5 s is a crime (min 1 star, 2 if already wanted).
--
-- Public: officerSees(player), officersNear(pos, radius), isArmed(player), onOfficerDowned(model, killer?),
--   getOfficerCount(), _director helpers live in Shared/Combat/PoliceAim.
-- Remote: PoliceShotFx (unreliable) to clients near the shot.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Police = require(Shared.Config.Police)
local Weapons = require(Shared.Config.Weapons)
local PoliceAim = require(Shared.Combat.PoliceAim)
local DamageModel = require(Shared.Combat.DamageModel)
local Ballistics = require(Shared.Combat.Ballistics)

local PoliceCombatService = {}

PoliceCombatService.COVER_TAG = "CoverPoint"
PoliceCombatService.RETURN_DIST = 110 -- suspect farther than this from an officer's cruiser: back to the car
PoliceCombatService.RETURN_SPEED = 25 -- suspect driving faster than this: back to the car
PoliceCombatService.MAX_RETURN_TIME = 10
PoliceCombatService.BYSTANDER_CLEARANCE = 3
PoliceCombatService.PICKUP_RADIUS = 4.5
PoliceCombatService.BRANDISH_ANGLE = 20
PoliceCombatService.PASSENGER_INTERVAL = { 0.9, 1.5 }
PoliceCombatService.ROADBLOCK_MIN_SPEED = 35
PoliceCombatService.ROADBLOCK_PASSED = 150
PoliceCombatService.STRIP_AHEAD = 28

type OfficerState = "Cover" | "Engage" | "Advance" | "Arrest" | "Return"

type Officer = {
	id: number,
	model: Model,
	root: BasePart,
	humanoid: Humanoid,
	suspect: Player?,
	unitModel: Model?, -- the cruiser it came from (nil: roadblock officer)
	weapon: string,
	state: OfficerState,
	cover: Vector3?,
	acquired: boolean,
	readyAt: number, -- reaction delay end
	shots: number, -- shots at the current acquisition (warning shots first)
	nextShotAt: number,
	lostSince: number?,
	lastSeenPos: Vector3?,
	sees: boolean,
	spawnedAt: number,
	stateAt: number,
	taserReadyAt: number,
	home: Vector3,
	roadblock: boolean,
}

type Roadblock = {
	cars: { any },
	officers: { Officer },
	center: Vector3,
	towardSuspect: Vector3,
	expiresAt: number,
	strip: Instance?,
}

type Suspect = {
	player: Player,
	director: PoliceAim.Director,
	stars: number,
	armedUntil: number,
	aimSince: number?,
	officers: { Officer },
	roadblock: Roadblock?,
	lastRoadblockAt: number,
	passengerReadyAt: { [number]: number },
	passengerShots: { [number]: number }, -- shots per unit at the current acquisition (warning shots first)
}

type Pickup = { part: BasePart, expiresAt: number }

local suspects: { [Player]: Suspect } = {}
local officers: { [Model]: Officer } = {}
local pickups: { Pickup } = {}
local nextId = 0
local rng = Random.new()
local losParams: RaycastParams? = nil

-- HOOKS ----------------------------------------------------------------------------------------------------------------
local systemCache: { [string]: any } = {}
local function sys(name: string): any
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local inst = script.Parent and script.Parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok and typeof(mod) == "table" then
			systemCache[name] = mod
			return mod
		end
	end
	return nil
end

local function call(name: string, fn: string, ...: any): (boolean, any)
	local mod = sys(name)
	local f = mod and mod[fn]
	if typeof(f) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(f, ...)
	if not ok then
		warn(("[PoliceCombatService] %s.%s failed: %s"):format(name, fn, tostring(res)))
		return false, nil
	end
	return true, res
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function starsOf(player: Player): number
	local ok, n = call("WantedService", "getStars", player)
	if ok and typeof(n) == "number" then
		return n
	end
	local a = player:GetAttribute("Wanted")
	return if typeof(a) == "number" then a else 0
end

-- PURE (tested) --------------------------------------------------------------------------------------------------------

-- Distance from point p to the segment a-b.
function PoliceCombatService._segmentDistance(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = if len2 > 1e-6 then math.clamp((p - a):Dot(ab) / len2, 0, 1) else 0
	return (p - (a + ab * t)).Magnitude
end

-- Average damage of one police shot for a star level's loadout (director refill = budget / this).
function PoliceCombatService._avgShotDamage(stars: number): number
	local loadout = PoliceAim.starCombat(stars).weapons
	local sum, n = 0, 0
	for _, id in loadout do
		local def = Weapons.get(id)
		if def then
			sum += def.damage * (def.pellets or 1) * 0.6 -- pellets: ~60 % of a blast lands at police ranges
			n += 1
		end
	end
	return if n > 0 then sum / n else 25
end

-- Which body part a police hit lands on, from a uniform u: torso 60 %, limbs 30 %, head 10 %.
function PoliceCombatService._hitPart(u: number): string
	if u < 0.6 then
		return "UpperTorso"
	elseif u < 0.9 then
		return "LeftUpperArm"
	end
	return "Head"
end

-- A warning-shot / miss impact point 2-4 studs from the target (u, v, w uniforms).
function PoliceCombatService._missPoint(target: Vector3, u: number, v: number, w: number): Vector3
	local r = 2 + 2 * u
	local a = 2 * math.pi * v
	return target + Vector3.new(math.cos(a) * r, (w - 0.6) * 2.5, math.sin(a) * r)
end

-- WORLD -----------------------------------------------------------------------------------------------------------------

local function getLos(): RaycastParams
	local p = losParams
	if not p then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.IgnoreWater = true
		p.RespectCanCollide = true
		losParams = p
	end
	local exclude: { Instance } = {}
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(exclude, pl.Character)
		end
	end
	for _, name in { "NPCs", "Effects" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	p.FilterDescendantsInstances = exclude
	return p
end

local function clear(a: Vector3, b: Vector3, extra: { Instance }?): boolean
	local params = getLos()
	if extra and #extra > 0 then
		local list = params.FilterDescendantsInstances
		for _, e in extra do
			table.insert(list, e)
		end
		params.FilterDescendantsInstances = list
	end
	local d = b - a
	if d.Magnitude < 1 then
		return true
	end
	return Workspace:Raycast(a, d, params) == nil
end

type SuspectInfo = {
	valid: boolean,
	root: BasePart?,
	pos: Vector3,
	head: Vector3,
	vel: Vector3,
	speed: number,
	inVehicle: boolean,
	car: any,
}

local function suspectInfo(player: Player): SuspectInfo
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not hum or hum.Health <= 0 then
		return {
			valid = false,
			root = nil,
			pos = Vector3.zero,
			head = Vector3.zero,
			vel = Vector3.zero,
			speed = 0,
			inVehicle = false,
			car = nil,
		}
	end
	local okC, car = call("VehicleService", "getDriving", player)
	local inVehicle = hum.SeatPart ~= nil
	local vel = root.AssemblyLinearVelocity
	local head = char:FindFirstChild("Head")
	return {
		valid = true,
		root = root,
		pos = root.Position,
		head = if head and head:IsA("BasePart") then head.Position else root.Position + Vector3.new(0, 1.5, 0),
		vel = vel,
		speed = flat(vel).Magnitude,
		inVehicle = inVehicle,
		car = if okC then car else nil,
	}
end

-- Bystanders near the line of fire (non-wanted / passive players, pedestrians): hold fire.
local function bystanderOnLine(a: Vector3, b: Vector3, suspect: Player): boolean
	local clearance = PoliceCombatService.BYSTANDER_CLEARANCE
	for _, p in Players:GetPlayers() do
		if p ~= suspect then
			local w = p:GetAttribute("Wanted")
			local innocent = not (typeof(w) == "number" and w > 0) or p:GetAttribute("Passive") == true
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if innocent and root and root:IsA("BasePart") then
				if PoliceCombatService._segmentDistance(root.Position, a, b) < clearance then
					return true
				end
			end
		end
	end
	local npcs = Workspace:FindFirstChild("NPCs")
	if npcs then
		for _, m in npcs:GetChildren() do
			if m:IsA("Model") and m.Name == "Pedestrian" then
				local root = m:FindFirstChild("HumanoidRootPart")
				if
					root
					and root:IsA("BasePart")
					and PoliceCombatService._segmentDistance(root.Position, a, b) < clearance
				then
					return true
				end
			end
		end
	end
	return false
end

-- SUSPECT STATE -----------------------------------------------------------------------------------------------------------

local function getSuspect(player: Player): Suspect
	local sc = suspects[player]
	if not sc then
		local now = os.clock()
		sc = {
			player = player,
			director = PoliceAim.newDirector(0, 25, now),
			stars = 0,
			armedUntil = 0,
			aimSince = nil,
			officers = {},
			roadblock = nil,
			lastRoadblockAt = -math.huge,
			passengerReadyAt = {},
			passengerShots = {},
		}
		suspects[player] = sc
	end
	return sc
end

function PoliceCombatService.isArmed(player: Player): boolean
	local sc = suspects[player]
	if not sc then
		return false
	end
	return os.clock() < sc.armedUntil or sc.aimSince ~= nil
end

function PoliceCombatService.officerSees(player: Player): boolean
	for _, o in officers do
		if o.suspect == player and o.sees then
			return true
		end
	end
	return false
end

function PoliceCombatService.officersNear(pos: Vector3, radius: number): boolean
	for _, o in officers do
		if o.root.Parent and flatDist(o.root.Position, pos) <= radius then
			return true
		end
	end
	return false
end

function PoliceCombatService.getOfficerCount(): number
	local n = 0
	for _ in officers do
		n += 1
	end
	return n
end

-- OFFICERS --------------------------------------------------------------------------------------------------------------

local function bumpOfficersOut(unitModel: Model?, delta: number)
	if not unitModel or not unitModel.Parent then
		return
	end
	local n = unitModel:GetAttribute("OfficersOut")
	local v = math.max(0, (if typeof(n) == "number" then n else 0) + delta)
	unitModel:SetAttribute("OfficersOut", v)
end

local function removeOfficer(o: Officer, destroy: boolean)
	if officers[o.model] ~= o then
		return
	end
	officers[o.model] = nil
	if o.suspect then
		local sc = suspects[o.suspect]
		if sc then
			local idx = table.find(sc.officers, o)
			if idx then
				table.remove(sc.officers, idx)
			end
		end
	end
	if not o.roadblock then
		bumpOfficersOut(o.unitModel, -1)
	end
	if destroy and o.model.Parent then
		local downed = false
		local NPC = sys("NPCService")
		if NPC and typeof(NPC.isDowned) == "function" then
			local ok, res = pcall(NPC.isDowned, o.model)
			downed = ok and res == true
		end
		if not downed then
			o.model:Destroy()
		end
	end
end

local function loadoutWeapon(stars: number): string
	local list = PoliceAim.starCombat(stars).weapons
	return list[rng:NextInteger(1, #list)]
end

local function spawnOfficer(sc: Suspect, at: CFrame, unitModel: Model?, roadblock: boolean): Officer?
	local stars = math.max(1, sc.stars)
	local combat = PoliceAim.starCombat(stars)
	local weapon = loadoutWeapon(stars)
	local ok, model = call("NPCService", "spawnOfficerOnFoot", at, { weapon = weapon, armor = combat.officerArmor })
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not hum then
		model:Destroy()
		return nil
	end
	nextId += 1
	local now = os.clock()
	local o: Officer = {
		id = nextId,
		model = model,
		root = root,
		humanoid = hum,
		suspect = sc.player,
		unitModel = unitModel,
		weapon = weapon,
		state = "Cover",
		cover = nil,
		acquired = false,
		readyAt = now,
		shots = 0,
		nextShotAt = now,
		lostSince = nil,
		lastSeenPos = nil,
		sees = false,
		spawnedAt = now,
		stateAt = now,
		taserReadyAt = now + 1,
		home = at.Position,
		roadblock = roadblock,
	}
	officers[model] = o
	table.insert(sc.officers, o)
	if not roadblock then
		bumpOfficersOut(unitModel, 1)
	end
	return o
end

-- Cover point: behind the officer's own cruiser on the far side from the suspect, else the nearest CoverPoint.
local function pickCover(o: Officer, suspectPos: Vector3): Vector3?
	local unit = o.unitModel
	local chassis = unit and unit.PrimaryPart
	if chassis then
		local away = flat(chassis.Position - suspectPos)
		if away.Magnitude > 0.5 then
			return chassis.Position + away.Unit * 4.5
		end
	end
	local best, bestD = nil, Police.OFFICER_COVER_RADIUS
	for _, part in CollectionService:GetTagged(PoliceCombatService.COVER_TAG) do
		if part:IsA("BasePart") then
			local d = flatDist(part.Position, o.root.Position)
			if d < bestD then
				local away = flat(part.Position - suspectPos)
				local spot = if away.Magnitude > 0.5
					then part.Position + away.Unit * (part.Size.Magnitude * 0.35 + 1.5)
					else part.Position
				best, bestD = spot, d
			end
		end
	end
	return best
end

local function moveTo(o: Officer, target: Vector3)
	pcall(function()
		o.humanoid.AutoRotate = true
		o.humanoid:MoveTo(target)
	end)
	call("NPCService", "setMoving", o.model, true, o.humanoid.WalkSpeed)
end

local function stopAndFace(o: Officer, target: Vector3)
	pcall(function()
		o.humanoid.AutoRotate = false
		o.humanoid:MoveTo(o.root.Position)
		local p = o.root.Position
		o.root.CFrame = CFrame.lookAt(p, Vector3.new(target.X, p.Y, target.Z))
	end)
	call("NPCService", "setMoving", o.model, false)
end

local function setState(o: Officer, state: OfficerState, now: number)
	if o.state ~= state then
		o.state = state
		o.stateAt = now
	end
end

-- FIRE ------------------------------------------------------------------------------------------------------------------

local function fx(key: number, weaponId: string, origin: Vector3, endpoints: { Vector3 }, kinds: { number })
	local points = { origin }
	for _, e in endpoints do
		table.insert(points, e)
	end
	pcall(
		Net.fireNearUnreliable,
		"PoliceShotFx",
		points,
		Weapons.FX_RADIUS,
		nil,
		key,
		Weapons.Index[weaponId] or 0,
		origin,
		endpoints,
		kinds
	)
	call("NPCService", "panic", origin, 80)
end

-- One police shot at the suspect from `origin`. Returns true when fired (granted).
local function policeShot(
	sc: Suspect,
	info: SuspectInfo,
	weaponId: string,
	origin: Vector3,
	key: number,
	firstShots: number
): boolean
	local player = sc.player
	local def = Weapons.get(weaponId)
	if not def or not info.valid or not info.root then
		return false
	end
	local now = os.clock()
	if not PoliceAim.request(sc.director, now) then
		return false
	end
	local target = info.pos + Vector3.new(0, 0.5, 0)
	local dist = (target - origin).Magnitude
	-- visible fraction: head, torso, legs
	local vis = 0
	for _, p in { info.head, info.pos, info.pos - Vector3.new(0, 2, 0) } do
		if clear(origin, p, if info.car and info.car.model then { info.car.model } else nil) then
			vis += 1
		end
	end
	local mercy = false
	local okM, m = call("DamageService", "mercyActive", player)
	mercy = okM and m == true
	local chance = PoliceAim.hitChance(sc.stars, dist, info.speed, vis / 3, info.inVehicle, mercy)
	local warning = PoliceAim.isWarningShot(firstShots)
	local hit = not warning and vis > 0 and rng:NextNumber() < chance
	local endpoints: { Vector3 } = {}
	local kinds: { number } = {}
	if hit then
		if info.inVehicle and info.car and PoliceAim.hitsCarBody(rng:NextNumber()) then
			local chassis = info.car.chassis
			local hitPos = if chassis then chassis.Position else info.pos
			call(
				"VehicleService",
				"bulletHit",
				info.car,
				chassis,
				hitPos,
				def.damage * (def.pellets or 1) * 0.6 * Weapons.CAR_DAMAGE_MULT,
				nil
			)
			table.insert(endpoints, hitPos)
			table.insert(kinds, 3)
		else
			local part = PoliceCombatService._hitPart(rng:NextNumber())
			local raw = DamageModel.raw(def, part, dist, info.inVehicle)
			if (def.pellets or 1) > 1 then
				raw *= (def.pellets or 1) * 0.6
			end
			call("DamageService", "applyDamage", player, {
				amount = raw,
				police = true,
				weapon = weaponId,
				part = part,
				position = target,
				from = origin,
			})
			table.insert(endpoints, target)
			table.insert(kinds, 2)
		end
	else
		local miss = PoliceCombatService._missPoint(target, rng:NextNumber(), rng:NextNumber(), rng:NextNumber())
		table.insert(endpoints, miss)
		table.insert(kinds, 1)
	end
	if (def.pellets or 1) > 1 then
		local dirs = Ballistics.pellets((target - origin).Unit, def.spreadHip, rng:NextInteger(1, 2 ^ 30), 4)
		for _, d in dirs do
			table.insert(endpoints, origin + d * dist)
			table.insert(kinds, 1)
		end
	end
	fx(key, weaponId, origin, endpoints, kinds)
	return true
end

local function taser(o: Officer, sc: Suspect, info: SuspectInfo, now: number)
	if now < o.taserReadyAt or info.inVehicle or not info.root then
		return
	end
	local origin = o.root.Position + Vector3.new(0, 1.2, 0) + o.root.CFrame.LookVector
	if (info.pos - origin).Magnitude > Police.TASER_RANGE then
		return
	end
	o.taserReadyAt = now + Police.TASER_COOLDOWN
	-- stun immunity applies to tasers too (no stun-lock): the wire still flies, but only a landed stun knocks down
	local okS, landed = call("CombatService", "stun", sc.player, Police.TASER_STUN)
	if okS and landed == true then
		local dir = flat(info.pos - o.root.Position)
		local push = if dir.Magnitude > 0.1 then dir.Unit * 10 else Vector3.zero
		pcall(Net.fireClient, "Knockback", sc.player, push + Vector3.new(0, 6, 0), Police.TASER_STUN)
	end
	pcall(Net.fireNear, "Effect", origin, 250, "TaserShot", { from = origin, to = info.pos, hit = okS and landed == true })
end

-- OFFICER THINK ---------------------------------------------------------------------------------------------------------

local function officerThink(o: Officer, sc: Suspect, info: SuspectInfo, now: number)
	if not o.model.Parent or not o.root.Parent then
		removeOfficer(o, false)
		return
	end
	local NPC = sys("NPCService")
	if NPC and typeof(NPC.isDowned) == "function" then
		local ok, downed = pcall(NPC.isDowned, o.model)
		if ok and downed then
			removeOfficer(o, false)
			return
		end
	end
	local stars = sc.stars
	local eye = o.root.Position + Vector3.new(0, 1.5, 0)
	-- an officer who got out at 1 star carries a taser; once the chase escalates he draws his star's gun
	if o.weapon == "taser" and stars >= 2 then
		o.weapon = loadoutWeapon(stars)
		if NPC and typeof(NPC.setOfficerWeapon) == "function" then
			pcall(NPC.setOfficerWeapon, o.model, o.weapon)
		end
	end
	-- suspect gone / cleared / in a fast car / far from the cruiser: go back to the car
	local unitPos = if o.unitModel and o.unitModel.PrimaryPart then o.unitModel.PrimaryPart.Position else o.home
	local tooFar = info.valid and flatDist(info.pos, unitPos) > PoliceCombatService.RETURN_DIST
	local fastCar = info.valid and info.inVehicle and info.speed > PoliceCombatService.RETURN_SPEED
	if stars <= 0 or not info.valid or ((tooFar or fastCar) and not o.roadblock) then
		if o.state ~= "Return" then
			setState(o, "Return", now)
			moveTo(o, unitPos)
		end
		o.sees = false
		if flatDist(o.root.Position, unitPos) < 6 or now - o.stateAt > PoliceCombatService.MAX_RETURN_TIME then
			removeOfficer(o, true)
		end
		return
	end
	-- vision: cone + line of sight
	local inCone = PoliceAim.inCone(o.root.Position, o.root.CFrame.LookVector, Police.CONES.foot, info.pos)
	local dist = (info.pos - eye).Magnitude
	local los = dist <= Police.CONES.foot.range * 1.6
		and clear(eye, info.head, if info.car and info.car.model then { info.car.model } else nil)
	o.sees = inCone and los
	if los then
		o.lostSince = nil
		o.lastSeenPos = info.pos
		if not o.acquired then
			o.acquired = true
			o.shots = 0
			o.readyAt = now + PoliceAim.reactionDelay(math.max(stars, 1), rng:NextNumber())
		end
	else
		o.acquired = false
		o.lostSince = o.lostSince or now
	end

	local armed = PoliceCombatService.isArmed(sc.player)
	-- 1-2 stars with an unarmed suspect (or 1 star always): arrest
	if (stars <= 1 or (stars <= 2 and not armed)) and not info.inVehicle then
		setState(o, "Arrest", now)
		if dist > Police.OFFICER_ARREST_RANGE - 1 then
			moveTo(o, info.pos)
		else
			stopAndFace(o, info.pos)
		end
		if stars <= 1 and los then
			local okHold, hold = call("DamageService", "policeHoldFire", sc.player)
			if not (okHold and hold == true) then
				taser(o, sc, info, now)
			end
		end
		return
	end
	if o.state == "Cover" then
		local cover = o.cover or pickCover(o, info.pos)
		o.cover = cover
		if cover and flatDist(o.root.Position, cover) > 2.5 and now - o.stateAt < 4 then
			moveTo(o, cover)
			return
		end
		setState(o, "Engage", now)
	end
	if not los then
		if o.lostSince and now - o.lostSince > Police.OFFICER_ADVANCE_AFTER then
			setState(o, "Advance", now)
			local okA, center = call("WantedService", "getSearchArea", sc.player)
			local goal = if okA and typeof(center) == "Vector3" then center else (o.lastSeenPos or info.pos)
			moveTo(o, goal)
		end
		return
	end
	-- Engage: face and fire when allowed. Hold fire (protected, surrendering, safe zone, just released...) covers the
	-- taser too.
	setState(o, "Engage", now)
	stopAndFace(o, info.pos)
	local okHold, hold = call("DamageService", "policeHoldFire", sc.player)
	local holding = okHold and hold == true
	if o.weapon == "taser" then
		if not holding then
			taser(o, sc, info, now)
		end
		return
	end
	local lethal = PoliceAim.lethal(stars, armed, info.inVehicle, info.speed)
	local fire = PoliceAim.mayFire({ protected = holding, lethal = lethal })
	if not fire or now < o.readyAt or now < o.nextShotAt then
		return
	end
	local def = Weapons.get(o.weapon)
	local muzzle = eye + o.root.CFrame.LookVector * 1.5 + o.root.CFrame.RightVector * 0.6
	if not def or (info.pos - muzzle).Magnitude > def.maxRange or bystanderOnLine(muzzle, info.pos, sc.player) then
		return
	end
	if policeShot(sc, info, o.weapon, muzzle, o.id, o.shots) then
		o.shots += 1
		local interval = math.max(Weapons.interval(def), 0.4)
		o.nextShotAt = now + interval + rng:NextNumber(0, 0.4)
	else
		o.nextShotAt = now + 0.25 -- denied by the director: ask again next think
	end
end

-- EXIT (officers leave stopped cruisers) --------------------------------------------------------------------------------

local function maybeExit(sc: Suspect, info: SuspectInfo, _now: number)
	if not info.valid or (info.inVehicle and info.speed > 5) then
		return
	end
	local combat = PoliceAim.starCombat(math.max(sc.stars, 1))
	local footCount = 0
	for _, o in sc.officers do
		if not o.roadblock then
			footCount += 1
		end
	end
	if footCount >= combat.maxOnFoot then
		return
	end
	local ok, units = call("PoliceService", "getUnits", sc.player)
	if not ok or typeof(units) ~= "table" then
		return
	end
	for _, u in units do
		if footCount >= combat.maxOnFoot then
			return
		end
		local out = u.model:GetAttribute("OfficersOut")
		local already = if typeof(out) == "number" then out else 0
		local perCar = if sc.stars >= 3 then 2 else 1
		if
			u.mode == "chase"
			and u.speed < 4
			and already < perCar
			and flatDist(u.chassis.Position, info.pos) <= Police.OFFICER_EXIT_RANGE
		then
			local cf = u.chassis.CFrame
			local door = cf * CFrame.new(-4.5 - already * 2, 0, -1 + already * 2)
			local groundY = cf.Position.Y - 1.5
			local spot = CFrame.lookAt(
				Vector3.new(door.Position.X, groundY, door.Position.Z),
				Vector3.new(info.pos.X, groundY, info.pos.Z)
			)
			if spawnOfficer(sc, spot, u.model, false) then
				footCount += 1
			end
		end
	end
end

-- PASSENGER FIRE (3+ stars) ----------------------------------------------------------------------------------------------

local function passengerFire(sc: Suspect, info: SuspectInfo, now: number)
	local combat = PoliceAim.starCombat(math.max(sc.stars, 1))
	if not combat.passengerFire or not info.valid then
		return
	end
	local okHold, hold = call("DamageService", "policeHoldFire", sc.player)
	if okHold and hold == true then
		return
	end
	local ok, units = call("PoliceService", "getUnits", sc.player)
	if not ok or typeof(units) ~= "table" then
		return
	end
	for _, u in units do
		if u.mode == "chase" and u.speed > 5 then
			local readyAt = sc.passengerReadyAt[u.id] or 0
			local pos = u.chassis.Position
			local inRange = flatDist(pos, info.pos) <= Police.PASSENGER_RANGE
			if not inRange then
				sc.passengerShots[u.id] = nil -- target lost: the next acquisition starts with warning shots again
			elseif now >= readyAt then
				local cf = u.chassis.CFrame
				local origin = (cf * CFrame.new(2.6, 2.2, -1)).Position
				if not clear(origin, info.pos + Vector3.new(0, 1, 0), { u.model }) then
					sc.passengerShots[u.id] = nil
				elseif not bystanderOnLine(origin, info.pos, sc.player) then
					local range = PoliceCombatService.PASSENGER_INTERVAL
					sc.passengerReadyAt[u.id] = now + rng:NextNumber(range[1], range[2])
					-- §9.3: the first WARNING_SHOTS at a newly acquired target always miss, from a window too
					local shots = sc.passengerShots[u.id] or 0
					if policeShot(sc, info, "pistol", origin, 100000 + u.id, shots) then
						sc.passengerShots[u.id] = shots + 1
						if
							not PoliceAim.isWarningShot(shots)
							and info.inVehicle
							and info.car
							and rng:NextNumber() < Police.PASSENGER_TIRE_CHANCE
						then
							call("VehicleService", "popTires", info.car, Weapons.TIRE_POP_TIME)
						end
					end
				end
			end
		end
	end
end

-- ROADBLOCKS (3+ stars) --------------------------------------------------------------------------------------------------

local function removeRoadblock(sc: Suspect)
	local rb = sc.roadblock
	if not rb then
		return
	end
	sc.roadblock = nil
	for _, o in table.clone(rb.officers) do
		removeOfficer(o, true)
	end
	for _, car in rb.cars do
		call("VehicleService", "destroy", car, "despawn")
	end
	if rb.strip and rb.strip.Parent then
		call("CombatService", "removePoliceStrip", rb.strip)
	end
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

local function maybeRoadblock(sc: Suspect, info: SuspectInfo, now: number)
	local combat = PoliceAim.starCombat(math.max(sc.stars, 1))
	local rb = sc.roadblock
	if rb then
		-- passed it, or expired: clean up once nobody is looking
		local past = info.valid and (info.pos - rb.center):Dot(-rb.towardSuspect) > PoliceCombatService.ROADBLOCK_PASSED
		if (now > rb.expiresAt or past or sc.stars < 3) and not anyPlayerNear(rb.center, 140) then
			removeRoadblock(sc)
		end
		return
	end
	if
		not combat.roadblock
		or not info.valid
		or not info.inVehicle
		or info.speed < PoliceCombatService.ROADBLOCK_MIN_SPEED
	then
		return
	end
	if now - sc.lastRoadblockAt < Police.ROADBLOCK_COOLDOWN then
		return
	end
	local okP, Police_ = pcall(function()
		return sys("PoliceService")
	end)
	if not okP or not Police_ or typeof(Police_._roadAnchor) ~= "function" then
		return
	end
	sc.lastRoadblockAt = now
	local heading = flat(info.vel).Unit
	local ahead = rng:NextNumber(Police.ROADBLOCK_AHEAD[1], Police.ROADBLOCK_AHEAD[2])
	local anchor = Police_._roadAnchor(info.pos + heading * ahead)
	if anyPlayerNear(anchor, 120) then
		return -- would pop in right in front of someone
	end
	local toward = flat(info.pos - anchor)
	toward = if toward.Magnitude > 1 then toward.Unit else -heading
	local across = toward:Cross(Vector3.yAxis).Unit
	local cars = {}
	for _, side in { -1, 1 } do
		local p = anchor + across * (8 * side)
		local look = (toward * 0.5 + across * (0.86 * side)).Unit
		local cf = CFrame.lookAt(p, p + look)
		local okC, car = call("PoliceService", "spawnRoadblockCar", cf)
		if okC and car then
			table.insert(cars, car)
		end
	end
	if #cars == 0 then
		return
	end
	local newRb: Roadblock = {
		cars = cars,
		officers = {},
		center = anchor,
		towardSuspect = toward,
		expiresAt = now + Police.ROADBLOCK_LIFETIME,
		strip = nil,
	}
	sc.roadblock = newRb
	for i, car in cars do
		local chassis = car.chassis
		if chassis then
			local behind = chassis.Position - toward * 5 + across * (if i == 1 then -1 else 1)
			local groundY = anchor.Y + 0.1
			local spot =
				CFrame.lookAt(Vector3.new(behind.X, groundY, behind.Z), Vector3.new(info.pos.X, groundY, info.pos.Z))
			local o = spawnOfficer(sc, spot, car.model, true)
			if o then
				o.cover = Vector3.new(behind.X, groundY, behind.Z)
				table.insert(newRb.officers, o)
			end
		end
	end
	if combat.roadblockSpikes then
		local p = anchor + toward * PoliceCombatService.STRIP_AHEAD
		local okS, strip =
			call("CombatService", "dropPoliceStrip", CFrame.lookAt(p, p - toward), Police.ROADBLOCK_LIFETIME)
		if okS and typeof(strip) == "Instance" then
			newRb.strip = strip
		end
	end
end

-- BRANDISH (aiming at police) ----------------------------------------------------------------------------------------------

local function aimingAtPolice(root: BasePart): boolean
	local look = flat(root.CFrame.LookVector)
	if look.Magnitude < 0.1 then
		return false
	end
	look = look.Unit
	local cosMax = math.cos(math.rad(PoliceCombatService.BRANDISH_ANGLE))
	local function check(pos: Vector3): boolean
		local d = flat(pos - root.Position)
		local m = d.Magnitude
		return m > 1 and m <= Police.BRANDISH_RANGE and d.Unit:Dot(look) >= cosMax
	end
	for _, o in officers do
		if o.root.Parent and check(o.root.Position) then
			return true
		end
	end
	local ok, units = call("PoliceService", "allUnits")
	if ok and typeof(units) == "table" then
		for _, u in units do
			if check(u.chassis.Position) then
				return true
			end
		end
	end
	return false
end

-- Aiming a gun we actually hold (the server's Aiming flag is cleared on every holster, but never trust one flag for
-- a crime).
local function aimingGun(player: Player): boolean
	local okA, aiming = call("WeaponService", "isAiming", player)
	if not okA or aiming ~= true then
		return false
	end
	local okE, equipped = call("WeaponService", "equipped", player)
	return okE and typeof(equipped) == "string" and Weapons.isGun(Weapons.get(equipped))
end

local function brandishPass(now: number)
	for _, player in Players:GetPlayers() do
		local sc = suspects[player]
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and aimingGun(player) and aimingAtPolice(root) then
			sc = sc or getSuspect(player)
			sc.aimSince = sc.aimSince or now
			if now - (sc.aimSince :: number) >= Police.BRANDISH_TIME then
				sc.armedUntil = math.max(sc.armedUntil, now + Police.ARMED_WINDOW)
				call("DamageService", "reportCrime", player, "brandish", root.Position, true)
				sc.aimSince = now -- next escalation needs another full BRANDISH_TIME
			end
		elseif sc then
			sc.aimSince = nil
		end
	end
end

-- PICKUPS ------------------------------------------------------------------------------------------------------------------

local function buildPickup(pos: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = "AmmoPickup"
	part.Size = Vector3.new(0.9, 0.5, 0.55)
	part.Color = Color3.fromRGB(74, 83, 58)
	part.Material = Enum.Material.Metal
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.new(pos) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local lid = Instance.new("Part")
	lid.Name = "Lid"
	lid.Size = Vector3.new(0.92, 0.08, 0.57)
	lid.Color = Color3.fromRGB(58, 64, 46)
	lid.Material = Enum.Material.Metal
	lid.Anchored = true
	lid.CanCollide = false
	lid.CanQuery = false
	lid.CanTouch = false
	lid.CFrame = part.CFrame * CFrame.new(0, 0.29, 0)
	lid.Parent = part
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(240, 200, 80)
	light.Range = 5
	light.Brightness = 0.6
	light.Shadows = false
	light.Parent = part
	part:SetAttribute("Pickup", "ammo")
	CollectionService:AddTag(part, "AmmoPickup")
	return part
end
PoliceCombatService._buildPickup = buildPickup

-- DamageService: an officer went down. A player's kill drops an ammo pickup for 20 s.
function PoliceCombatService.onOfficerDowned(model: Model, killer: Player?)
	local o = officers[model]
	if o then
		removeOfficer(o, false)
	end
	if not killer then
		return
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local effects = Workspace:FindFirstChild("Effects")
	if not effects then
		return
	end
	local part = buildPickup(root.Position - Vector3.new(0, 2.2, 0))
	part.Parent = effects
	table.insert(pickups, { part = part, expiresAt = os.clock() + Police.AMMO_PICKUP_LIFETIME })
end

local function pickupPass(now: number)
	for i = #pickups, 1, -1 do
		local pk = pickups[i]
		local alive = pk.part.Parent ~= nil and now < pk.expiresAt
		if alive then
			for _, p in Players:GetPlayers() do
				local char = p.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if
					root
					and root:IsA("BasePart")
					and (root.Position - pk.part.Position).Magnitude <= PoliceCombatService.PICKUP_RADIUS
				then
					local ok, added = call("WeaponService", "addMagazineForClass", p)
					if ok and added == true then
						pcall(Net.fireClient, "Sound", p, "Pickup")
						alive = false
						break
					end
				end
			end
		end
		if not alive then
			if pk.part.Parent then
				pk.part:Destroy()
			end
			table.remove(pickups, i)
		end
	end
end

-- PASSES ---------------------------------------------------------------------------------------------------------------------

function PoliceCombatService._pass(now: number)
	for _, player in Players:GetPlayers() do
		local stars = starsOf(player)
		local sc = suspects[player]
		if stars > 0 or (sc and (#sc.officers > 0 or sc.roadblock ~= nil)) then
			sc = sc or getSuspect(player)
			if sc.stars ~= stars then
				sc.stars = stars
				local combat = PoliceAim.starCombat(math.max(stars, 1))
				PoliceAim.setBudget(
					sc.director,
					if stars > 0 then combat.dpsBudget else 0,
					PoliceCombatService._avgShotDamage(stars)
				)
			end
			local info = suspectInfo(player)
			if stars > 0 then
				local ok, err = pcall(maybeExit, sc, info, now)
				if not ok then
					warn("[PoliceCombatService] exit failed: " .. tostring(err))
				end
				ok, err = pcall(passengerFire, sc, info, now)
				if not ok then
					warn("[PoliceCombatService] passenger fire failed: " .. tostring(err))
				end
			end
			local okR, errR = pcall(maybeRoadblock, sc, info, now)
			if not okR then
				warn("[PoliceCombatService] roadblock failed: " .. tostring(errR))
			end
			for _, o in table.clone(sc.officers) do
				local ok, err = pcall(officerThink, o, sc, info, now)
				if not ok then
					warn("[PoliceCombatService] officer think failed: " .. tostring(err))
					removeOfficer(o, true)
				end
			end
		end
	end
	brandishPass(now)
	pickupPass(now)
end

local function onPlayerRemoving(player: Player)
	local sc = suspects[player]
	if not sc then
		return
	end
	removeRoadblock(sc)
	for _, o in table.clone(sc.officers) do
		removeOfficer(o, true)
	end
	suspects[player] = nil
end

function PoliceCombatService.init() end

function PoliceCombatService.start()
	local Weapon = sys("WeaponService")
	if Weapon and Weapon.Fired then
		Weapon.Fired:Connect(function(player: Player)
			local sc = getSuspect(player)
			sc.armedUntil = os.clock() + Police.ARMED_WINDOW
		end)
	end
	local PoliceService = sys("PoliceService")
	if PoliceService and typeof(PoliceService.registerBustSource) == "function" then
		-- an arresting officer on foot right next to a slow suspect counts for the bust ring (1-2 stars)
		PoliceService.registerBustSource(function(player: Player): boolean
			local sc = suspects[player]
			if not sc or sc.stars > 2 then
				return false
			end
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") then
				return false
			end
			for _, o in sc.officers do
				if o.state == "Arrest" and flatDist(o.root.Position, root.Position) <= Police.OFFICER_ARREST_RANGE then
					return true
				end
			end
			return false
		end)
	end
	local NPC = sys("NPCService")
	if NPC and NPC.Downed then
		NPC.Downed:Connect(function(_kind: string, model: Model)
			local o = officers[model]
			if o then
				removeOfficer(o, false)
			end
		end)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < Police.OFFICER_THINK then
			return
		end
		acc = 0
		local ok, err = pcall(PoliceCombatService._pass, os.clock())
		if not ok then
			warn("[PoliceCombatService] pass failed: " .. tostring(err))
		end
	end)
end

return PoliceCombatService
