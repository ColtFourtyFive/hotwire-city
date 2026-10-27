--!strict
-- CombatService (SPEC §6, v2 gta_combat §3 / §13.2): the two GADGETS - the Kessler Stun Gun ("taser") and the
-- Stinger Strip ("spikes") - plus the stun state, police spike strips and the shared melee target picker.
-- Guns and melee weapons (including the free Slugger Bat that replaced v1's Bonk Bat) are WeaponService's.
--
-- Gadgets are Tools built from Shared/Combat/WeaponModels (realistic yellow / black polymer, black steel: no neon, no
-- cartoon colours) and handed out for every owned gadget (data.tools; the Zapper Pass also grants the stun gun and
-- halves its cooldown). Clients fire ToolAction(toolId, aim); the server decides everything else: ownership,
-- equipped (the strip deploys from the driver's seat), per-tool cooldown, not stunned, range + server raycast,
-- DamageService protection (spawn protection, safe zones, passive, rookie, revenge immunity).
--
-- Stun gun: non-lethal. A hit stuns (player attribute Stunned), knocks the victim back (Knockback remote, applied by
-- the victim's own client) and drops a driver out of their seat (VehicleService.eject). Assault heat uses the
-- CrimeRules defense rules. Stinger Strip: dropped behind the player's car; any other car that crosses it gets its
-- tires deflated (TiresPopped) for SPIKES_POP_TIME. PoliceCombatService drops police strips at 4-star roadblocks.
--
-- Effects sent (Effect remote; ShotFxController renders): TaserShot { from, to, hit }, TireBurst { position },
-- StripDrop { position }.
--
-- All cross-system calls are lazy (required inside functions) so this module also loads in the Lune harness.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Economy = require(Shared.Config.Economy)
local PoliceConfig = require(Shared.Config.Police)
local MapLayout = require(Shared.Util.MapLayout)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local CrimeRules = require(Shared.Combat.CrimeRules)
local WeaponModels = require(Shared.Combat.WeaponModels)

local CombatService = {}

-- Fired after every successful gadget hit: (attacker: Player, victim: Player, toolId: string, ejectedCar: any?)
CombatService.Hit = Signal.new()

-- Tuning (beyond Config/Economy) -----------------------------------------------------------------------------------
local TASER_KNOCK = 16
local TASER_UP = 10
local TASER_SPHERE_RADIUS = 1.0 -- probe spread: a little forgiving
local SPAWN_PROTECTION = 3
local STUN_IMMUNITY_AFTER = 1 -- after a stun ends you can't be stunned again for this long (no stun-lock)
local COOLDOWN_TOLERANCE = 0.12 -- network jitter allowance
local EFFECT_RADIUS = 250
local TASER_EFFECT_RADIUS = 300
local SPIKE_BEHIND = 12 -- studs behind the car's center
local SPIKE_WIDTH = 14 -- across the lane
local SPIKE_DEPTH = 2.6 -- along the lane
local SPIKE_HIT_MARGIN_X = 1.5
local SPIKE_HIT_MARGIN_Z = 1.4
local SPIKE_HIT_HEIGHT = 9 -- chassis centers up to this high above the strip count (monster trucks)
local SPIKE_POLL = 0.1
local SPIKE_MIN_SPEED = 3 -- parked / settled cars don't get popped
local MAX_STRIPS_PER_PLAYER = 2
local MAX_STRIPS = 16

local COLORS = {
	Steel = Color3.fromRGB(38, 39, 42),
	SteelWorn = Color3.fromRGB(70, 72, 76),
	Rubber = Color3.fromRGB(22, 22, 24),
	Caution = Color3.fromRGB(214, 176, 44),
}

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests and reuse)
-------------------------------------------------------------------------------------------------------------------------

export type Candidate = { key: any, position: Vector3 }
export type CooldownBook = { [string]: number } -- toolId -> clock time when the tool is ready again
export type AssaultContext = CrimeRules.AssaultContext

-- Nearest candidate within `range` of origin that lies in front of ANY of `forwards` (horizontal dot > minDot).
-- Candidates closer than `pointBlank` count regardless of direction. Returns the candidate's key or nil.
-- (WeaponService's melee uses this too.)
function CombatService.selectTarget(
	origin: Vector3,
	forwards: { Vector3 },
	candidates: { Candidate },
	range: number,
	minDot: number,
	pointBlank: number
): any?
	local best: any = nil
	local bestDist = math.huge
	for _, c in candidates do
		local offset = c.position - origin
		local dist = offset.Magnitude
		if dist <= range and dist < bestDist then
			local inFront = dist <= pointBlank
			if not inFront then
				local flat = Vector3.new(offset.X, 0, offset.Z)
				if flat.Magnitude < 1e-3 then
					inFront = true -- straight above/below
				else
					local dir = flat.Unit
					for _, f in forwards do
						local ff = Vector3.new(f.X, 0, f.Z)
						if ff.Magnitude > 1e-3 and dir:Dot(ff.Unit) > minDot then
							inFront = true
							break
						end
					end
				end
			end
			if inFront then
				best = c.key
				bestDist = dist
			end
		end
	end
	return best
end

-- Cooldown of a tool for a player (Zapper Pass halves the stun gun cooldown). Unknown tools never become ready.
function CombatService.cooldownFor(toolId: string, hasTaserPass: boolean): number
	local def = Economy.Tools[toolId]
	if not def then
		return math.huge
	end
	local cd = def.cooldown
	if toolId == "taser" and hasTaserPass then
		cd *= 0.5
	end
	return cd
end

function CombatService.cooldownReady(book: CooldownBook, toolId: string, now: number, tolerance: number?): boolean
	local readyAt = book[toolId]
	return readyAt == nil or now >= readyAt - (tolerance or 0)
end

function CombatService.startCooldown(book: CooldownBook, toolId: string, now: number, duration: number)
	book[toolId] = now + duration
end

-- v1 rule (now Shared/Combat/CrimeRules): hitting a player outside your own garage is assault unless the victim is
-- stealing from you, raiding your garage, or wanted.
CombatService.shouldAddAssaultHeat = CrimeRules.shouldAddAssaultHeat

-- Does the segment p0 -> p1 (strip-local space: X across the strip, Z along the road, Y up from the strip) pass over
-- the strip footprint (|x| <= halfWidth, |z| <= halfDepth) at a height in [-2, height]? Swept so fast cars that jump
-- over the strip between two samples still count.
function CombatService.segmentCrossesStrip(
	p0: Vector3,
	p1: Vector3,
	halfWidth: number,
	halfDepth: number,
	height: number
): boolean
	local minZ = math.min(p0.Z, p1.Z)
	local maxZ = math.max(p0.Z, p1.Z)
	if maxZ < -halfDepth or minZ > halfDepth then
		return false
	end
	local dz = p1.Z - p0.Z
	local t: number
	if math.abs(dz) < 1e-4 then
		t = 0.5
	else
		-- clamp the z=0 crossing into the part of the segment that overlaps the footprint
		t = math.clamp(-p0.Z / dz, 0, 1)
	end
	local x = p0.X + (p1.X - p0.X) * t
	local y = p0.Y + (p1.Y - p0.Y) * t
	return math.abs(x) <= halfWidth and y >= -2 and y <= height
end

-- Daily contract "defend" (bonk3): see CrimeRules.countsAsThiefBonk.
CombatService.countsAsThiefBonk = CrimeRules.countsAsThiefBonk

-- Is `value` (Player, userId number, or nil) the given player?
function CombatService.isSamePlayer(value: any, player: Player): boolean
	if value == nil then
		return false
	end
	if value == player then
		return true
	end
	if typeof(value) == "number" then
		return value == player.UserId
	end
	return false
end

-------------------------------------------------------------------------------------------------------------------------
-- Builders (pure instance construction — harness compatible)
-------------------------------------------------------------------------------------------------------------------------

local function newTool(toolId: string, name: string, tip: string): Tool
	local tool = Instance.new("Tool")
	tool.Name = name
	tool.ToolTip = tip
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.ManualActivationOnly = false
	tool:SetAttribute("ToolId", toolId)
	return tool
end

-- Builds a fresh gadget Tool for toolId ("taser" | "spikes"), or nil for anything else (guns, melee: WeaponService).
function CombatService.buildTool(toolId: string): Tool?
	local def = Economy.Tools[toolId]
	if not def or (toolId ~= "taser" and toolId ~= "spikes") then
		return nil
	end
	local tool = newTool(toolId, def.name, def.description)
	if toolId == "spikes" then
		tool.Grip = CFrame.new(0, 0.1, 0.2)
	end
	-- the stun gun's probes leave from the Handle's "Muzzle" attachment (the cartridge face)
	local handle = WeaponModels.assemble(tool, toolId)
	WeaponModels.weld(tool, handle)
	return tool
end

local function stripPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Anchored = true
	p.Parent = parent
	return p
end

-- Builds the deployed Stinger Strip at groundCFrame (position on the road surface, -Z = the dropping car's forward).
-- Returns an anchored Model (PrimaryPart "Base") with an invisible "Trigger" volume for Touched. Black steel bars,
-- rows of steel spikes, caution end caps.
function CombatService.buildSpikeStrip(groundCFrame: CFrame): Model
	local model = Instance.new("Model")
	model.Name = "SpikeStrip"
	local base = stripPart(
		model,
		"Base",
		Vector3.new(SPIKE_WIDTH, 0.2, SPIKE_DEPTH),
		groundCFrame * CFrame.new(0, 0.1, 0),
		COLORS.Rubber,
		Enum.Material.Fabric
	)
	for _, sz in { -1, 1 } do
		stripPart(
			model,
			"Rail",
			Vector3.new(SPIKE_WIDTH, 0.24, 0.22),
			groundCFrame * CFrame.new(0, 0.12, (SPIKE_DEPTH / 2 - 0.12) * sz),
			COLORS.Steel,
			Enum.Material.Metal
		)
		stripPart(
			model,
			"EndCap",
			Vector3.new(0.5, 0.36, SPIKE_DEPTH + 0.2),
			groundCFrame * CFrame.new((SPIKE_WIDTH / 2 + 0.2) * sz, 0.18, 0),
			COLORS.Caution,
			Enum.Material.SmoothPlastic
		)
	end
	local n = 12
	for i = 1, n do
		local x = -SPIKE_WIDTH / 2 + 0.7 + (i - 1) * (SPIKE_WIDTH - 1.4) / (n - 1)
		for _, z in { -0.55, 0.55 } do
			stripPart(
				model,
				"Spike",
				Vector3.new(0.12, 0.42, 0.12),
				groundCFrame * CFrame.new(x, 0.38, z) * CFrame.Angles(math.rad(if z < 0 then -18 else 18), 0, 0),
				COLORS.SteelWorn,
				Enum.Material.Metal
			)
		end
	end
	local trigger = stripPart(
		model,
		"Trigger",
		Vector3.new(SPIKE_WIDTH + 3, 7, SPIKE_DEPTH + 2.4),
		groundCFrame * CFrame.new(0, 3.5, 0),
		COLORS.Steel,
		Enum.Material.SmoothPlastic
	)
	trigger.Transparency = 1
	trigger.CanTouch = true
	model.PrimaryPart = base
	return model
end

-------------------------------------------------------------------------------------------------------------------------
-- Runtime state
-------------------------------------------------------------------------------------------------------------------------

type Strip = {
	model: Model,
	cframe: CFrame,
	owner: Player?, -- nil: a police strip
	ownerCar: Model?,
	expiresAt: number,
	popped: { [Model]: boolean },
	trove: Trove.Trove,
	timer: thread?,
}

local templates: { [string]: Tool } = {}
local cooldowns: { [Player]: CooldownBook } = {}
local spawnedAt: { [Player]: number } = {}
local stunUntil: { [Player]: number } = {}
local immuneUntil: { [Player]: number } = {}
local playerTroves: { [Player]: Trove.Trove } = {}
local strips: { Strip } = {}
local prevChassisPos: { [Model]: Vector3 } = {}

local zapParams: RaycastParams? = nil
local groundParams: RaycastParams? = nil

-- Lazy system access (require inside functions; see SPEC §4). Cached once a system loaded successfully.
local systemCache: { [string]: any } = {}
local function getSystem(name: string): any
	local cached = systemCache[name]
	if cached then
		return cached
	end
	local folder = script.Parent
	local mod = folder and folder:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	if ok and typeof(result) == "table" then
		systemCache[name] = result
		return result
	end
	return nil
end

-- Calls System.fn(...) if it exists; never throws. Returns (ok, result).
local function callSystem(systemName: string, fnName: string, ...: any): (boolean, any)
	local sys = getSystem(systemName)
	local fn = sys and sys[fnName]
	if typeof(fn) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn(("[CombatService] %s.%s failed: %s"):format(systemName, fnName, tostring(result)))
		return false, nil
	end
	return true, result
end

local function getEffectsFolder(): Folder
	local f = Workspace:FindFirstChild("Effects")
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "Effects"
	nf.Parent = Workspace
	return nf
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character or not character.Parent then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getAliveHumanoid(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function getData(player: Player): any
	local ok, data = callSystem("DataService", "get", player)
	if ok and typeof(data) == "table" then
		return data
	end
	return nil
end

local function hasPass(player: Player, key: string): boolean
	local ok, result = callSystem("MonetizationService", "hasPass", player, key)
	return ok and result == true
end

local function getDrivingCar(player: Player): any
	local ok, car = callSystem("VehicleService", "getDriving", player)
	if ok and typeof(car) == "table" then
		return car
	end
	return nil
end

local function notify(player: Player, kind: string, text: string)
	if player.Parent then
		Net.fireClient("Notify", player, kind, text)
	end
end

-- Set of gadget ids this player owns right now.
local function ownedTools(player: Player, data: any): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	local tools = data and data.tools
	if typeof(tools) == "table" then
		for _, id in Economy.GadgetOrder do
			if tools[id] == true then
				owned[id] = true
			end
		end
	end
	if hasPass(player, "taser") then
		owned.taser = true
	end
	return owned
end

local function isEquipped(character: Model, toolId: string): boolean
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("ToolId") == toolId then
			return true
		end
	end
	return false
end

local function equippedMuzzle(character: Model, toolId: string): Vector3?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("ToolId") == toolId then
			local handle = child:FindFirstChild("Handle")
			local m = handle and handle:FindFirstChild("Muzzle")
			if m and m:IsA("Attachment") then
				return m.WorldPosition
			end
		end
	end
	return nil
end

-- Is this player currently immune to gadget hits? (dead, spawn protection, stun immunity, DamageService rules)
local function isProtected(attacker: Player, victim: Player, now: number): boolean
	local root = getRoot(victim)
	if not root or not getAliveHumanoid(victim) then
		return true
	end
	if now - (spawnedAt[victim] or -math.huge) < SPAWN_PROTECTION then
		return true
	end
	if now < (immuneUntil[victim] or -math.huge) then
		return true
	end
	local ok, allowed = callSystem("DamageService", "canDamage", attacker, victim)
	if ok and allowed == false then
		return true
	end
	local okP, plotIndex = callSystem("PlotService", "getPlotIndex", victim)
	if okP and typeof(plotIndex) == "number" then
		local lockedOk, locked = callSystem("PlotService", "isLocked", plotIndex)
		if lockedOk and locked == true and MapLayout.plotAt(root.Position) == plotIndex then
			return true
		end
	end
	return false
end

-- Resolve a raycast hit to the player it belongs to (character part, accessory, or a car with a driver).
local function playerFromHit(inst: Instance): Player?
	local node: Instance? = inst
	while node and node ~= Workspace do
		if node:IsA("Model") then
			local p = Players:GetPlayerFromCharacter(node)
			if p then
				return p
			end
			if CollectionService:HasTag(node, "Vehicle") then
				local seat = node:FindFirstChild("DriverSeat")
				if seat and seat:IsA("VehicleSeat") and seat.Occupant then
					return Players:GetPlayerFromCharacter(seat.Occupant.Parent)
				end
				return nil
			end
		end
		node = node.Parent
	end
	return nil
end

local function fireEffectNear(name: string, position: Vector3, radius: number, data: { [string]: any })
	Net.fireNear("Effect", position, radius, name, data)
end

-- Fire an effect to everyone within radius of either endpoint (wires / tracers).
local function fireEffectNearSegment(name: string, a: Vector3, b: Vector3, radius: number, data: { [string]: any })
	for _, p in Players:GetPlayers() do
		local root = getRoot(p)
		if root and ((root.Position - a).Magnitude <= radius or (root.Position - b).Magnitude <= radius) then
			Net.fireClient("Effect", p, name, data)
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Stun / hit resolution
-------------------------------------------------------------------------------------------------------------------------

-- Stun a player for `seconds` (player attribute Stunned=true; clients freeze controls). Also used by police tasers and
-- heavy melee hits. No stun-lock: while a stun runs and for STUN_IMMUNITY_AFTER after it, further stuns are refused
-- (they neither land nor extend the current one) unless `force` (the BUSTED freeze). Returns true when it landed;
-- callers only knock the victim down when it did.
function CombatService.stun(victim: Player, seconds: number, force: boolean?): boolean
	if seconds <= 0 or not victim.Parent then
		return false
	end
	local now = os.clock()
	if not force and now < (immuneUntil[victim] or -math.huge) then
		return false
	end
	local untilTime = math.max(stunUntil[victim] or 0, now + seconds)
	stunUntil[victim] = untilTime
	immuneUntil[victim] = untilTime + STUN_IMMUNITY_AFTER
	victim:SetAttribute("Stunned", true)
	task.delay(seconds + 0.05, function()
		if not victim.Parent then
			return
		end
		local u = stunUntil[victim]
		if u == nil or u <= os.clock() + 0.02 then
			stunUntil[victim] = nil
			victim:SetAttribute("Stunned", false)
		end
	end)
	return true
end

function CombatService.isStunned(player: Player): boolean
	return player:GetAttribute("Stunned") == true
end

-- Is the victim currently driving off with a car stolen from `attacker`?
local function isStealingFrom(victim: Player, attacker: Player, victimCar: any): boolean
	if victimCar and victimCar.kind == "Stolen" then
		local theft = victimCar.data and victimCar.data.theft
		if typeof(theft) == "table" and CombatService.isSamePlayer(theft.victim, attacker) then
			return true
		end
	end
	local ok, active = callSystem("TheftService", "getActiveTheft", victim)
	if ok and typeof(active) == "table" then
		local rec = active
		if typeof(active.data) == "table" and typeof(active.data.theft) == "table" then
			rec = active.data.theft
		end
		if CombatService.isSamePlayer(rec.victim, attacker) then
			return true
		end
	end
	return false
end

local function isInOwnGarage(player: Player, position: Vector3): boolean
	local ok, plotIndex = callSystem("PlotService", "getPlotIndex", player)
	return ok and typeof(plotIndex) == "number" and MapLayout.plotAt(position) == plotIndex
end

type HitOptions = {
	toolId: string,
	stunSeconds: number,
	knockback: Vector3,
}

local function applyHit(attacker: Player, victim: Player, opts: HitOptions)
	local victimRoot = getRoot(victim)
	local attackerRoot = getRoot(attacker)
	if not victimRoot or not attackerRoot then
		return
	end

	-- read everything we need BEFORE the eject changes vehicle state
	local car = getDrivingCar(victim)
	local stealingFromAttacker = isStealingFrom(victim, attacker, car)
	local defended = car ~= nil and car.kind == "Stolen" and stealingFromAttacker
	local wanted = victim:GetAttribute("Wanted")
	local victimWanted = if typeof(wanted) == "number" then wanted else 0
	local thiefBonk = car ~= nil and CrimeRules.countsAsThiefBonk(car.kind, victimWanted)
	local heat = CrimeRules.shouldAddAssaultHeat({
		attackerInOwnGarage = isInOwnGarage(attacker, attackerRoot.Position),
		victimInAttackerGarage = isInOwnGarage(attacker, victimRoot.Position),
		victimStealingFromAttacker = stealingFromAttacker,
		victimWanted = victimWanted,
	})

	CombatService.stun(victim, opts.stunSeconds)
	-- TheftService records the hit BEFORE the eject: the eject drops a stolen car synchronously, and the knockout feed
	-- line / revenge read the hitter it stores (DECISIONS.md: onThiefHit is called before any eject)
	callSystem("TheftService", "onThiefHit", attacker, victim)
	local ejected = false
	if car then
		ejected = callSystem("VehicleService", "eject", car)
	end
	Net.fireClient("Knockback", victim, opts.knockback, opts.stunSeconds)
	callSystem("DamageService", "markCombat", attacker)
	callSystem("DamageService", "markCombat", victim)

	if thiefBonk and ejected then
		callSystem("RewardsService", "progress", attacker, "defend", 1)
	end
	if defended then
		notify(attacker, "success", "Thief stunned. Get your car back.")
	end
	if heat then
		callSystem("DamageService", "reportCrime", attacker, "assault", attackerRoot.Position, false)
	end
	CombatService.Hit:Fire(attacker, victim, opts.toolId, car)
end

-------------------------------------------------------------------------------------------------------------------------
-- Gadget actions
-------------------------------------------------------------------------------------------------------------------------

local function getZapParams(exclude: { Instance }): RaycastParams
	local params = zapParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		zapParams = params
	end
	params.FilterDescendantsInstances = exclude
	return params
end

local function doTaser(player: Player, character: Model, root: BasePart, aim: Vector3?)
	local head = character:FindFirstChild("Head")
	local origin = if head and head:IsA("BasePart") then head.Position else root.Position + Vector3.new(0, 1.5, 0)
	local dir = root.CFrame.LookVector
	if aim then
		local d = aim - origin
		if d.Magnitude > 0.5 then
			dir = d.Unit
		end
	end
	local range = Economy.TASER_RANGE
	local exclude: { Instance } = { character, getEffectsFolder() }
	local myCar = getDrivingCar(player)
	if myCar and myCar.model then
		table.insert(exclude, myCar.model)
	end
	local params = getZapParams(exclude)

	-- precise ray first (also our wall check), then a forgiving sphere that may not go further than the ray did
	local ray = Workspace:Raycast(origin, dir * range, params)
	local hitPos = if ray then ray.Position else origin + dir * range
	local victim: Player? = if ray then playerFromHit(ray.Instance) else nil
	if not victim then
		local ok, sphere = pcall(function()
			return Workspace:Spherecast(origin, TASER_SPHERE_RADIUS, dir * range, params)
		end)
		if ok and sphere then
			local maxDist = if ray then ray.Distance + 0.5 else range
			if sphere.Distance <= maxDist then
				local p = playerFromHit(sphere.Instance)
				if p then
					victim = p
					hitPos = sphere.Position
				end
			end
		end
	end

	local now = os.clock()
	local hit = victim ~= nil and victim ~= player and not isProtected(player, victim, now)
	local fromPos = equippedMuzzle(character, "taser") or (origin + dir * 1.5)
	if hit and victim then
		local victimRoot = getRoot(victim)
		local flat = Vector3.new(dir.X, 0, dir.Z)
		local knockDir = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zero
		applyHit(player, victim, {
			toolId = "taser",
			stunSeconds = Economy.TASER_STUN,
			knockback = knockDir * TASER_KNOCK + Vector3.new(0, TASER_UP, 0),
		})
		if victimRoot then
			hitPos = victimRoot.Position
		end
	end
	fireEffectNearSegment("TaserShot", fromPos, hitPos, TASER_EFFECT_RADIUS, {
		from = fromPos,
		to = hitPos,
		hit = hit,
	})
end

local function removeStrip(strip: Strip)
	local idx = table.find(strips, strip)
	if idx then
		table.remove(strips, idx)
	end
	local timer = strip.timer
	strip.timer = nil
	if timer and timer ~= coroutine.running() and coroutine.status(timer) ~= "dead" then
		pcall(task.cancel, timer)
	end
	strip.trove:Destroy()
	if #strips == 0 then
		table.clear(prevChassisPos)
	end
end

local function occupantPlayer(model: Model): Player?
	local seat = model:FindFirstChild("DriverSeat")
	if seat and seat:IsA("VehicleSeat") and seat.Occupant then
		return Players:GetPlayerFromCharacter(seat.Occupant.Parent)
	end
	return nil
end

local function popTires(strip: Strip, model: Model, chassis: BasePart)
	if strip.popped[model] or model == strip.ownerCar or not model.Parent then
		return
	end
	if chassis.Anchored or chassis.AssemblyLinearVelocity.Magnitude < SPIKE_MIN_SPEED then
		return
	end
	if strip.owner == nil and CollectionService:HasTag(model, "Police") then
		return -- police strips never get police cars
	end
	strip.popped[model] = true
	local deadline = Workspace:GetServerTimeNow() + Economy.SPIKES_POP_TIME
	model:SetAttribute("TiresPopped", deadline)
	chassis:SetAttribute("TiresPopped", deadline)
	local pos = chassis.Position
	fireEffectNear("TireBurst", pos, EFFECT_RADIUS, { position = pos })
	local driver = occupantPlayer(model)
	if driver then
		notify(driver, "warning", "Your tires are shredded.")
	end
	local owner = strip.owner
	if owner and owner.Parent and driver ~= owner then
		notify(owner, "success", "Stinger Strip hit.")
	end
end

local function onStripTouched(strip: Strip, hit: BasePart)
	if hit.Name ~= "Chassis" then
		return
	end
	local model = hit.Parent
	if not model or not model:IsA("Model") then
		return
	end
	if not CollectionService:HasTag(model, "Vehicle") then
		return
	end
	popTires(strip, model, hit)
end

local function getGroundParams(): RaycastParams
	local params = groundParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		groundParams = params
	end
	local exclude: { Instance } = { getEffectsFolder() }
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if vehicles then
		table.insert(exclude, vehicles)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	return params
end

local function placeStrip(groundCFrame: CFrame, owner: Player?, ownerCar: Model?, duration: number): Strip
	local model = CombatService.buildSpikeStrip(groundCFrame)
	local trove = Trove.new()
	trove:Add(model)
	local strip: Strip = {
		model = model,
		cframe = groundCFrame,
		owner = owner,
		ownerCar = ownerCar,
		expiresAt = os.clock() + duration,
		popped = {},
		trove = trove,
	}
	local trigger = model:FindFirstChild("Trigger")
	if trigger and trigger:IsA("BasePart") then
		trove:Connect(trigger.Touched, function(hit: BasePart)
			if model.Parent then
				onStripTouched(strip, hit)
			end
		end)
	end
	model:SetAttribute("OwnerUserId", if owner then owner.UserId else 0)
	model.Parent = getEffectsFolder()
	table.insert(strips, strip)
	strip.timer = task.delay(duration, function()
		if table.find(strips, strip) then
			removeStrip(strip)
		end
	end)
	fireEffectNear("StripDrop", groundCFrame.Position, EFFECT_RADIUS, { position = groundCFrame.Position })
	return strip
end

local function doSpikes(player: Player, car: any)
	local chassis: BasePart? = car.chassis
	local carModel: Model? = car.model
	if not chassis or not chassis.Parent or not carModel then
		return
	end
	-- caps: oldest strip of this player (then globally) makes room
	local mine: { Strip } = {}
	for _, s in strips do
		if s.owner == player then
			table.insert(mine, s)
		end
	end
	if #mine >= MAX_STRIPS_PER_PLAYER then
		removeStrip(mine[1])
	end
	if #strips >= MAX_STRIPS then
		removeStrip(strips[1])
	end

	local cf = chassis.CFrame
	local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	fwd = if fwd.Magnitude > 0.1 then fwd.Unit else Vector3.new(0, 0, -1)
	local behind = chassis.Position - fwd * SPIKE_BEHIND
	local ground = Workspace:Raycast(behind + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), getGroundParams())
	local rideHeight = carModel:GetAttribute("RideHeight")
	local groundY = if ground
		then ground.Position.Y
		else behind.Y - (if typeof(rideHeight) == "number" then rideHeight else 2)
	local pos = Vector3.new(behind.X, groundY, behind.Z)
	placeStrip(CFrame.lookAt(pos, pos + fwd), player, carModel, Economy.SPIKES_DURATION)
end

-- Police roadblock strip (PoliceCombatService, 4+ stars): `groundCFrame` -Z = toward the oncoming suspect.
function CombatService.dropPoliceStrip(groundCFrame: CFrame, duration: number?): Model?
	if #strips >= MAX_STRIPS then
		removeStrip(strips[1])
	end
	local params = getGroundParams()
	local p = groundCFrame.Position
	local ground = Workspace:Raycast(p + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), params)
	local y = if ground then ground.Position.Y else p.Y
	local cf = CFrame.new(p.X, y, p.Z) * (groundCFrame - groundCFrame.Position)
	local strip = placeStrip(cf, nil, nil, duration or PoliceConfig.ROADBLOCK_LIFETIME)
	return strip.model
end

function CombatService.removePoliceStrip(model: Instance)
	for _, s in table.clone(strips) do
		if s.model == model then
			removeStrip(s)
		end
	end
end

-- Swept polling backup for Touched (fast cars, client-owned physics): every SPIKE_POLL seconds while strips exist.
local function pollStrips()
	if #strips == 0 then
		return
	end
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if not vehicles then
		return
	end
	local halfW = SPIKE_WIDTH / 2 + SPIKE_HIT_MARGIN_X
	local halfD = SPIKE_DEPTH / 2 + SPIKE_HIT_MARGIN_Z
	for _, model in vehicles:GetChildren() do
		if model:IsA("Model") then
			local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
			if chassis and chassis:IsA("BasePart") and not chassis.Anchored then
				local pos = chassis.Position
				local prev = prevChassisPos[model] or pos
				prevChassisPos[model] = pos
				for _, strip in strips do
					if not strip.popped[model] and model ~= strip.ownerCar then
						local p0 = strip.cframe:PointToObjectSpace(prev)
						local p1 = strip.cframe:PointToObjectSpace(pos)
						if CombatService.segmentCrossesStrip(p0, p1, halfW, halfD, SPIKE_HIT_HEIGHT) then
							popTires(strip, model, chassis)
						end
					end
				end
			end
		end
	end
	for model in prevChassisPos do
		if not model.Parent then
			prevChassisPos[model] = nil
		end
	end
end

local function onToolAction(player: Player, toolId: any, aim: any)
	-- 1. types (gadgets only; "bat" is a WeaponService melee weapon now)
	if toolId ~= "taser" and toolId ~= "spikes" then
		return
	end
	if aim ~= nil and not Net.isFiniteVector(aim) then
		return
	end
	local aimVec: Vector3? = if aim ~= nil then aim :: Vector3 else nil
	-- 2. state
	local character = player.Character
	if not character or not character.Parent then
		return
	end
	local humanoid = getAliveHumanoid(player)
	local root = getRoot(player)
	if not humanoid or not root then
		return
	end
	if player:GetAttribute("Stunned") == true then
		return
	end
	-- 3. permission
	local data = getData(player)
	if not data then
		return
	end
	if not ownedTools(player, data)[toolId] then
		return
	end
	local car = if toolId == "spikes" then getDrivingCar(player) else nil
	if not isEquipped(character, toolId) and not (toolId == "spikes" and car) then
		return
	end
	if toolId == "taser" then
		local ok, kind = callSystem("DamageService", "safeZoneKind", player)
		if ok and typeof(kind) == "string" and kind ~= "garage" then
			return
		end
	end
	-- 4. cooldown
	local book = cooldowns[player]
	if not book then
		book = {}
		cooldowns[player] = book
	end
	local now = os.clock()
	if not CombatService.cooldownReady(book, toolId, now, COOLDOWN_TOLERANCE) then
		return
	end
	if toolId == "spikes" and not car then
		notify(player, "warning", "Deploy the Stinger Strip from behind the wheel.")
		return
	end
	CombatService.startCooldown(book, toolId, now, CombatService.cooldownFor(toolId, hasPass(player, "taser")))

	if toolId == "taser" then
		doTaser(player, character, root, aimVec)
	elseif toolId == "spikes" then
		doSpikes(player, car)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Tool distribution
-------------------------------------------------------------------------------------------------------------------------

local function getTemplate(toolId: string): Tool?
	local t = templates[toolId]
	if t then
		return t
	end
	local built = CombatService.buildTool(toolId)
	if built then
		templates[toolId] = built
	end
	return built
end

local function toolsIn(container: Instance?): { Tool }
	local out: { Tool } = {}
	if container then
		for _, child in container:GetChildren() do
			if child:IsA("Tool") and typeof(child:GetAttribute("ToolId")) == "string" then
				table.insert(out, child)
			end
		end
	end
	return out
end

-- Ensures the player's Backpack holds exactly one of every owned gadget (and drops v1 tools such as the old Bonk
-- Bat Tool). Safe to call any time (ShopService calls it after BuyTool).
function CombatService.giveTools(player: Player)
	if not player.Parent then
		return
	end
	local data = getData(player)
	if not data then
		return
	end
	local owned = ownedTools(player, data)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local starterGear = player:FindFirstChild("StarterGear")

	-- live tools (character first so the equipped copy is the one we keep)
	local have: { [string]: boolean } = {}
	local live = toolsIn(player.Character)
	for _, t in toolsIn(backpack) do
		table.insert(live, t)
	end
	for _, tool in live do
		local id = tool:GetAttribute("ToolId") :: string
		if not owned[id] or have[id] then
			tool:Destroy()
		else
			have[id] = true
		end
	end
	-- v1 put copies in StarterGear; v2 rebuilds on every spawn instead
	for _, tool in toolsIn(starterGear) do
		tool:Destroy()
	end

	for _, id in Economy.GadgetOrder do
		if owned[id] and backpack and not have[id] then
			local template = getTemplate(id)
			if template then
				template:Clone().Parent = backpack
			end
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local function cleanupPlayer(player: Player)
	local trove = playerTroves[player]
	if trove then
		trove:Destroy()
		playerTroves[player] = nil
	end
	cooldowns[player] = nil
	spawnedAt[player] = nil
	stunUntil[player] = nil
	immuneUntil[player] = nil
	for i = #strips, 1, -1 do
		local s = strips[i]
		if s.owner == player then
			removeStrip(s)
		end
	end
end

local function setupPlayer(player: Player)
	if playerTroves[player] or not player.Parent then
		return
	end
	local trove = Trove.new()
	playerTroves[player] = trove
	cooldowns[player] = {}
	player:SetAttribute("Stunned", false)

	local function onCharacter(character: Model)
		spawnedAt[player] = os.clock()
		stunUntil[player] = nil
		immuneUntil[player] = nil
		player:SetAttribute("Stunned", false)
		task.defer(function()
			if player.Parent and player.Character == character then
				CombatService.giveTools(player)
			end
		end)
	end
	trove:Connect(player.CharacterAdded, onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
	local ok, loaded = callSystem("DataService", "isLoaded", player)
	if ok and loaded == true then
		CombatService.giveTools(player)
	end
end

function CombatService.init()
	for _, id in Economy.GadgetOrder do
		getTemplate(id)
	end
	Net.on("ToolAction", onToolAction, 5)
end

function CombatService.start()
	local DataService = getSystem("DataService")
	if DataService and typeof(DataService.Loaded) == "table" then
		DataService.Loaded:Connect(function(player: Player)
			setupPlayer(player)
			CombatService.giveTools(player)
		end)
	end
	local Monetization = getSystem("MonetizationService")
	if Monetization and typeof(Monetization.PassChanged) == "table" then
		Monetization.PassChanged:Connect(function(player: Player, key: string)
			if key == "taser" then
				CombatService.giveTools(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(cleanupPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(setupPlayer, player)
	end

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		if #strips == 0 then
			acc = 0
			return
		end
		acc += dt
		if acc < SPIKE_POLL then
			return
		end
		acc = 0
		pollStrips()
	end)
end

return CombatService
