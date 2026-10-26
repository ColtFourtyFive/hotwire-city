--!strict
-- CombatService (SPEC §6): cartoon combat tools — Bonk Bat, Zapper ("taser"), Spike Strip ("spikes").
--
-- Tools are Tool instances built from parts (no meshes) and handed out for every owned tool (data.tools; the bat
-- is always owned, the Zapper also comes with the Zapper Pass). Clients detect activation and fire
-- ToolAction(toolId, aim); the server decides everything else: ownership, equipped, per-tool cooldown (Zapper
-- Pass halves the Zapper cooldown), not stunned, range / cone / server raycast, spawn + locked-garage protection.
--
-- Mild-rated: nothing takes damage and nobody dies. Hits stun (player attribute Stunned), knock the victim back
-- (Knockback remote, applied by the victim's own client) and pop drivers out of their car (VehicleService.eject).
--
-- Effects sent (Effect remote, rendered by EffectsController; `sound` is played by the client with the effect):
--   Bonk { position, sound = "Bonk" }        Zap { from, to, hit, sound = "Zap" }
--   TirePop { position, sound = "Poof" }     SpikeDrop { position, sound = "MetalHit" }
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

local CombatService = {}

-- Fired after every successful hit: (attacker: Player, victim: Player, toolId: string, ejectedCar: any?)
CombatService.Hit = Signal.new()

-- Tuning (beyond Config/Economy) -----------------------------------------------------------------------------------
local BAT_RANGE_SLACK = 2 -- lag compensation on top of Economy.BAT_RANGE
local BAT_MIN_DOT = 0.3 -- "in front" cone (horizontal)
local BAT_POINT_BLANK = 3 -- closer than this always counts as "in front" (players overlapping)
local BAT_UP = 35
local TASER_KNOCK = 28
local TASER_UP = 22
local TASER_SPHERE_RADIUS = 1.25 -- forgiving beam thickness
local SPAWN_PROTECTION = 3
local STUN_IMMUNITY_AFTER = 1 -- after a stun ends you can't be stunned again for this long (no stun-lock)
local COOLDOWN_TOLERANCE = 0.12 -- network jitter allowance
local ASSAULT_HEAT_COOLDOWN = 5 -- at most one assault star per attacker per this many seconds
local EFFECT_RADIUS = 250
local ZAP_EFFECT_RADIUS = 300
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
	Wood = Color3.fromRGB(226, 160, 92),
	WoodDark = Color3.fromRGB(196, 126, 66),
	Tape = Color3.fromRGB(38, 38, 52),
	Pink = Color3.fromRGB(255, 52, 140),
	Cyan = Color3.fromRGB(0, 214, 255),
	Orange = Color3.fromRGB(255, 140, 30),
	Purple = Color3.fromRGB(140, 70, 255),
	Lime = Color3.fromRGB(140, 255, 120),
	Yellow = Color3.fromRGB(255, 205, 50),
	Steel = Color3.fromRGB(46, 48, 62),
	White = Color3.fromRGB(245, 245, 255),
}

-- Part cylinders run along local X; these rotate that axis onto Y / Z.
local ALONG_Y = CFrame.Angles(0, 0, math.rad(90))
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0)
local DIAMOND = CFrame.Angles(math.rad(45), 0, math.rad(45))

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests and reuse)
-------------------------------------------------------------------------------------------------------------------------

export type Candidate = { key: any, position: Vector3 }
export type CooldownBook = { [string]: number } -- toolId -> clock time when the tool is ready again
export type AssaultContext = {
	attackerInOwnGarage: boolean, -- defending your own garage is never a crime
	victimInAttackerGarage: boolean, -- a raider inside your garage
	victimStealingFromAttacker: boolean, -- the victim is driving off with your car
	victimWanted: number, -- stars; bonking wanted criminals is vigilante justice, not assault
}

-- Nearest candidate within `range` of origin that lies in front of ANY of `forwards` (horizontal dot > minDot).
-- Candidates closer than `pointBlank` count regardless of direction. Returns the candidate's key or nil.
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

-- Cooldown of a tool for a player (Zapper Pass halves the Zapper cooldown). Unknown tools never become ready.
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

-- SPEC: hitting a player outside your own garage adds `assault` heat unless the victim is stealing from you or wanted.
function CombatService.shouldAddAssaultHeat(ctx: AssaultContext): boolean
	if ctx.attackerInOwnGarage or ctx.victimInAttackerGarage then
		return false
	end
	if ctx.victimStealingFromAttacker then
		return false
	end
	return ctx.victimWanted <= 0
end

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
-- Geometry builders (pure instance construction — harness compatible)
-------------------------------------------------------------------------------------------------------------------------

local function newPart(
	parent: Instance?,
	name: string,
	shape: Enum.PartType,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	if parent then
		p.Parent = parent
	end
	return p
end

local function newWedge(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): WedgePart
	local p = Instance.new("WedgePart")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function weldAll(tool: Tool, handle: BasePart)
	handle.Massless = true
	handle.Anchored = false
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") and d ~= handle then
			d.Massless = true
			d.Anchored = false
			local w = Instance.new("WeldConstraint")
			w.Part0 = handle
			w.Part1 = d
			w.Parent = d
		end
	end
end

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

-- Bonk Bat: chunky cartoon wooden bat, taped grip, neon band. Bat axis = handle +Y (points up out of the fist).
local function buildBat(): Tool
	local tool = newTool("bat", "Bonk Bat", "Bonk thieves out of your cars!")
	-- hand sits 0.35 below the handle center; bat leans back over the shoulder a little
	tool.Grip = (CFrame.Angles(math.rad(20), 0, 0) * CFrame.new(0, 0.35, 0)):Inverse()

	local o = CFrame.new()
	local handle = newPart(tool, "Handle", Enum.PartType.Block, Vector3.new(0.5, 1.7, 0.5), o, COLORS.Tape)
	handle.Transparency = 1
	handle.CanTouch = false

	local function y(v: number): CFrame
		return o * CFrame.new(0, v, 0) * ALONG_Y
	end
	newPart(
		tool,
		"GripTape",
		Enum.PartType.Cylinder,
		Vector3.new(1.7, 0.5, 0.5),
		y(0),
		COLORS.Tape,
		Enum.Material.Fabric
	)
	newPart(tool, "TapeBand", Enum.PartType.Cylinder, Vector3.new(0.16, 0.55, 0.55), y(-0.45), COLORS.Pink)
	newPart(tool, "TapeBand", Enum.PartType.Cylinder, Vector3.new(0.16, 0.55, 0.55), y(0.35), COLORS.Pink)
	newPart(tool, "Knob", Enum.PartType.Cylinder, Vector3.new(0.24, 0.8, 0.8), y(-0.95), COLORS.Tape)
	newPart(
		tool,
		"Taper",
		Enum.PartType.Cylinder,
		Vector3.new(1.0, 0.68, 0.68),
		y(1.3),
		COLORS.WoodDark,
		Enum.Material.Wood
	)
	newPart(
		tool,
		"Barrel",
		Enum.PartType.Cylinder,
		Vector3.new(2.1, 1.02, 1.02),
		y(2.85),
		COLORS.Wood,
		Enum.Material.Wood
	)
	newPart(
		tool,
		"NeonBand",
		Enum.PartType.Cylinder,
		Vector3.new(0.28, 1.06, 1.06),
		y(2.15),
		COLORS.Cyan,
		Enum.Material.Neon
	)
	newPart(
		tool,
		"Cap",
		Enum.PartType.Ball,
		Vector3.new(1.02, 1.02, 1.02),
		o * CFrame.new(0, 3.88, 0),
		COLORS.Wood,
		Enum.Material.Wood
	)

	-- swing trail (enabled locally by CombatClient during a swing)
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailBottom"
	a0.Position = Vector3.new(0, 1.6, 0)
	a0.Parent = handle
	local a1 = Instance.new("Attachment")
	a1.Name = "TrailTop"
	a1.Position = Vector3.new(0, 4.3, 0)
	a1.Parent = handle
	local trail = Instance.new("Trail")
	trail.Name = "SwingTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(COLORS.White, COLORS.Pink)
	trail.Transparency = NumberSequence.new(0.15, 1)
	trail.Lifetime = 0.16
	trail.MinLength = 0
	trail.FaceCamera = true
	trail.LightEmission = 0.6
	trail.Enabled = false
	trail.Parent = handle

	weldAll(tool, handle)
	return tool
end

-- Zapper: chunky toy sci-fi blaster (orange body, white barrel, glowing lime coil, pink tip). Forward = handle -Z.
local function buildZapper(): Tool
	local tool = newTool("taser", "Zapper", "Zap thieves from range - stuns them and pops them out of cars!")
	tool.Grip = CFrame.new(0, -0.2, 0)

	local o = CFrame.new()
	local handle = newPart(
		tool,
		"Handle",
		Enum.PartType.Block,
		Vector3.new(0.45, 1.15, 0.6),
		o,
		COLORS.Purple,
		Enum.Material.SmoothPlastic
	)
	newPart(
		tool,
		"Body",
		Enum.PartType.Block,
		Vector3.new(0.85, 0.8, 1.9),
		o * CFrame.new(0, 0.85, -0.55),
		COLORS.Orange
	)
	newPart(
		tool,
		"BodyBack",
		Enum.PartType.Ball,
		Vector3.new(1.15, 1.15, 1.15),
		o * CFrame.new(0, 0.88, 0.35),
		COLORS.Orange
	)
	newWedge(tool, "Fin", Vector3.new(0.16, 0.5, 0.9), o * CFrame.new(0, 1.5, 0.05), COLORS.Cyan)
	newPart(
		tool,
		"Barrel",
		Enum.PartType.Cylinder,
		Vector3.new(1.5, 0.5, 0.5),
		o * CFrame.new(0, 0.85, -2.1) * ALONG_Z,
		COLORS.White
	)
	for i, z in { -1.7, -2.05, -2.4 } do
		newPart(
			tool,
			"Coil" .. i,
			Enum.PartType.Cylinder,
			Vector3.new(0.13, 0.74, 0.74),
			o * CFrame.new(0, 0.85, z) * ALONG_Z,
			COLORS.Lime,
			Enum.Material.Neon
		)
	end
	local tipPart = newPart(
		tool,
		"Tip",
		Enum.PartType.Ball,
		Vector3.new(0.62, 0.62, 0.62),
		o * CFrame.new(0, 0.85, -2.95),
		COLORS.Pink,
		Enum.Material.Neon
	)
	newPart(tool, "Guard", Enum.PartType.Block, Vector3.new(0.2, 0.12, 0.6), o * CFrame.new(0, 0.2, -0.5), COLORS.Steel)
	newPart(
		tool,
		"Trigger",
		Enum.PartType.Block,
		Vector3.new(0.14, 0.32, 0.14),
		o * CFrame.new(0, 0.36, -0.38),
		COLORS.Yellow
	)

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0, -0.3)
	muzzle.Parent = tipPart
	local glow = Instance.new("PointLight")
	glow.Name = "Glow"
	glow.Color = COLORS.Lime
	glow.Range = 6
	glow.Brightness = 1.2
	glow.Shadows = false
	glow.Parent = tipPart

	weldAll(tool, handle)
	return tool
end

-- Spike Strip (held): folded hazard case with neon spikes on top.
local function buildSpikesItem(): Tool
	local tool = newTool("spikes", "Spike Strip", "Drop behind your car to pop the tires of anyone chasing you!")
	tool.Grip = CFrame.new(0, 0.3, 0.45)

	local o = CFrame.new()
	local handle =
		newPart(tool, "Handle", Enum.PartType.Block, Vector3.new(2.2, 0.55, 1.2), o, COLORS.Steel, Enum.Material.Metal)
	for _, sx in { -1, 1 } do
		newPart(
			tool,
			"Cap",
			Enum.PartType.Block,
			Vector3.new(0.22, 0.66, 1.3),
			o * CFrame.new(1.15 * sx, 0, 0),
			COLORS.Yellow
		)
		newPart(
			tool,
			"Stripe",
			Enum.PartType.Block,
			Vector3.new(0.3, 0.04, 1.22),
			o * CFrame.new(0.58 * sx, 0.295, 0),
			COLORS.Yellow
		)
	end
	for i, x in { -0.85, -0.3, 0.3, 0.85 } do
		newPart(
			tool,
			"Spike",
			Enum.PartType.Block,
			Vector3.new(0.28, 0.28, 0.28),
			o * CFrame.new(x, 0.42, 0) * DIAMOND,
			if i % 2 == 0 then COLORS.White else COLORS.Pink,
			Enum.Material.Neon
		)
	end
	newPart(tool, "Strap", Enum.PartType.Block, Vector3.new(1.0, 0.12, 0.16), o * CFrame.new(0, 0.36, 0.5), COLORS.Tape)

	weldAll(tool, handle)
	return tool
end

-- Builds a fresh Tool for toolId ("bat" | "taser" | "spikes"), or nil for unknown ids.
function CombatService.buildTool(toolId: string): Tool?
	if toolId == "bat" then
		return buildBat()
	elseif toolId == "taser" then
		return buildZapper()
	elseif toolId == "spikes" then
		return buildSpikesItem()
	end
	return nil
end

-- Builds the dropped spike strip at groundCFrame (position on the road surface, -Z = the dropping car's forward).
-- Returns an anchored Model (PrimaryPart "Base") with an invisible "Trigger" volume for Touched.
function CombatService.buildSpikeStrip(groundCFrame: CFrame): Model
	local model = Instance.new("Model")
	model.Name = "SpikeStrip"
	local base = newPart(
		model,
		"Base",
		Enum.PartType.Block,
		Vector3.new(SPIKE_WIDTH, 0.25, SPIKE_DEPTH),
		groundCFrame * CFrame.new(0, 0.125, 0),
		COLORS.Steel,
		Enum.Material.Metal
	)
	for _, sz in { -1, 1 } do
		newPart(
			model,
			"Rail",
			Enum.PartType.Block,
			Vector3.new(SPIKE_WIDTH, 0.3, 0.25),
			groundCFrame * CFrame.new(0, 0.15, (SPIKE_DEPTH / 2 - 0.12) * sz),
			COLORS.Yellow
		)
		newPart(
			model,
			"EndCap",
			Enum.PartType.Block,
			Vector3.new(0.6, 0.5, SPIKE_DEPTH + 0.3),
			groundCFrame * CFrame.new((SPIKE_WIDTH / 2 + 0.2) * sz, 0.25, 0),
			COLORS.Yellow
		)
	end
	local n = 9
	for i = 1, n do
		local x = -SPIKE_WIDTH / 2 + 1 + (i - 1) * (SPIKE_WIDTH - 2) / (n - 1)
		newPart(
			model,
			"Spike",
			Enum.PartType.Block,
			Vector3.new(0.75, 0.75, 0.75),
			groundCFrame * CFrame.new(x, 0.55, 0) * DIAMOND,
			if i % 2 == 0 then COLORS.White else COLORS.Pink,
			Enum.Material.Neon
		)
	end
	local trigger = newPart(
		model,
		"Trigger",
		Enum.PartType.Block,
		Vector3.new(SPIKE_WIDTH + 3, 7, SPIKE_DEPTH + 2.4),
		groundCFrame * CFrame.new(0, 3.5, 0),
		COLORS.Steel
	)
	trigger.Transparency = 1
	trigger.CanTouch = true
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	model.PrimaryPart = base
	return model
end

-------------------------------------------------------------------------------------------------------------------------
-- Runtime state
-------------------------------------------------------------------------------------------------------------------------

type Strip = {
	model: Model,
	cframe: CFrame,
	owner: Player,
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
local lastAssaultHeat: { [Player]: number } = {}
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

-- Set of tool ids this player owns right now.
local function ownedTools(player: Player, data: any): { [string]: boolean }
	local owned: { [string]: boolean } = { bat = true }
	local tools = data and data.tools
	if typeof(tools) == "table" then
		for id, v in tools do
			if v == true and typeof(id) == "string" and Economy.Tools[id] then
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

local function equippedToolPart(character: Model, toolId: string, partName: string): BasePart?
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("ToolId") == toolId then
			local p = child:FindFirstChild(partName)
			if p and p:IsA("BasePart") then
				return p
			end
		end
	end
	return nil
end

-- Is this player currently immune to hits? (spawn protection, stun immunity, own locked garage, dead)
local function isProtected(victim: Player, now: number): boolean
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
	local ok, plotIndex = callSystem("PlotService", "getPlotIndex", victim)
	if ok and typeof(plotIndex) == "number" then
		local lockedOk, locked = callSystem("PlotService", "isLocked", plotIndex)
		if lockedOk and locked == true and MapLayout.plotAt(root.Position) == plotIndex then
			return true
		end
	end
	return false
end

local function isInOwnGarage(player: Player, position: Vector3): boolean
	local ok, plotIndex = callSystem("PlotService", "getPlotIndex", player)
	return ok and typeof(plotIndex) == "number" and MapLayout.plotAt(position) == plotIndex
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

-- Fire an effect to everyone within radius of either endpoint (beams).
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

-- Stun a player for `seconds` (player attribute Stunned=true; clients freeze controls). Extra public helper.
function CombatService.stun(victim: Player, seconds: number)
	if seconds <= 0 or not victim.Parent then
		return
	end
	local now = os.clock()
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
	local now = os.clock()

	-- read everything we need BEFORE the eject changes vehicle state
	local car = getDrivingCar(victim)
	local stealingFromAttacker = isStealingFrom(victim, attacker, car)
	local defended = car ~= nil and car.kind == "Stolen" and stealingFromAttacker
	local wanted = victim:GetAttribute("Wanted")
	local heat = CombatService.shouldAddAssaultHeat({
		attackerInOwnGarage = isInOwnGarage(attacker, attackerRoot.Position),
		victimInAttackerGarage = isInOwnGarage(attacker, victimRoot.Position),
		victimStealingFromAttacker = stealingFromAttacker,
		victimWanted = if typeof(wanted) == "number" then wanted else 0,
	})

	CombatService.stun(victim, opts.stunSeconds)
	if car then
		callSystem("VehicleService", "eject", car)
	end
	Net.fireClient("Knockback", victim, opts.knockback, opts.stunSeconds)

	callSystem("TheftService", "onThiefHit", attacker, victim)
	if defended then
		callSystem("RewardsService", "progress", attacker, "defend", 1)
		notify(attacker, "success", "THIEF BONKED! Go grab your car back!")
	end
	if heat and now - (lastAssaultHeat[attacker] or -math.huge) >= ASSAULT_HEAT_COOLDOWN then
		lastAssaultHeat[attacker] = now
		callSystem("WantedService", "addHeat", attacker, PoliceConfig.Heat.assault, "assault")
	end
	CombatService.Hit:Fire(attacker, victim, opts.toolId, car)
end

-------------------------------------------------------------------------------------------------------------------------
-- Tool actions
-------------------------------------------------------------------------------------------------------------------------

local function doBat(player: Player, root: BasePart, aim: Vector3?)
	local origin = root.Position
	local forwards = { root.CFrame.LookVector }
	if aim then
		local d = aim - origin
		if d.Magnitude > 0.5 and d.Magnitude < 500 then
			table.insert(forwards, d)
		end
	end
	local now = os.clock()
	local candidates: { Candidate } = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local otherRoot = getRoot(other)
			if otherRoot and not isProtected(other, now) then
				table.insert(candidates, { key = other, position = otherRoot.Position })
			end
		end
	end
	local target = CombatService.selectTarget(
		origin,
		forwards,
		candidates,
		Economy.BAT_RANGE + BAT_RANGE_SLACK,
		BAT_MIN_DOT,
		BAT_POINT_BLANK
	)
	if not target then
		return
	end
	local victim = target :: Player
	local victimRoot = getRoot(victim)
	if not victimRoot then
		return
	end
	local flat = Vector3.new(victimRoot.Position.X - origin.X, 0, victimRoot.Position.Z - origin.Z)
	local dir = if flat.Magnitude > 0.1
		then flat.Unit
		else Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
	applyHit(player, victim, {
		toolId = "bat",
		stunSeconds = Economy.BAT_STUN,
		knockback = dir * Economy.BAT_KNOCKBACK + Vector3.new(0, BAT_UP, 0),
	})
	local fxPos = victimRoot.Position + Vector3.new(0, 2.5, 0)
	fireEffectNear("Bonk", fxPos, EFFECT_RADIUS, { position = fxPos, sound = "Bonk" })
end

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

local function doZap(player: Player, character: Model, root: BasePart, aim: Vector3?)
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
	local hit = victim ~= nil and victim ~= player and not isProtected(victim, now)
	local tip = equippedToolPart(character, "taser", "Tip")
	local fromPos = if tip then tip.Position else origin + dir * 1.5
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
	fireEffectNearSegment("Zap", fromPos, hitPos, ZAP_EFFECT_RADIUS, {
		from = fromPos,
		to = hitPos,
		hit = hit,
		sound = "Zap",
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
	strip.popped[model] = true
	local deadline = Workspace:GetServerTimeNow() + Economy.SPIKES_POP_TIME
	model:SetAttribute("TiresPopped", deadline)
	chassis:SetAttribute("TiresPopped", deadline)
	local pos = chassis.Position
	fireEffectNear("TirePop", pos, EFFECT_RADIUS, { position = pos, sound = "Poof" })
	local driver = occupantPlayer(model)
	if driver then
		notify(driver, "warning", "POP! Your tires got spiked!")
	end
	if strip.owner.Parent and driver ~= strip.owner then
		notify(strip.owner, "success", "Spikes popped a tire!")
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
	local groundCFrame = CFrame.lookAt(pos, pos + fwd)

	local model = CombatService.buildSpikeStrip(groundCFrame)
	local trove = Trove.new()
	trove:Add(model)
	local strip: Strip = {
		model = model,
		cframe = groundCFrame,
		owner = player,
		ownerCar = carModel,
		expiresAt = os.clock() + Economy.SPIKES_DURATION,
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
	model:SetAttribute("OwnerUserId", player.UserId)
	model.Parent = getEffectsFolder()
	table.insert(strips, strip)
	strip.timer = task.delay(Economy.SPIKES_DURATION, function()
		if table.find(strips, strip) then
			removeStrip(strip)
		end
	end)
	fireEffectNear("SpikeDrop", pos, EFFECT_RADIUS, { position = pos, sound = "MetalHit" })
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
	-- 1. types
	if typeof(toolId) ~= "string" or not Economy.Tools[toolId] then
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
		notify(player, "warning", "Hop in a car to drop spikes!")
		return
	end
	CombatService.startCooldown(book, toolId, now, CombatService.cooldownFor(toolId, hasPass(player, "taser")))

	if toolId == "bat" then
		doBat(player, root, aimVec)
	elseif toolId == "taser" then
		doZap(player, character, root, aimVec)
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

-- Ensures the player's Backpack (and StarterGear, so tools persist on respawn) holds exactly one of every owned tool.
-- Removes duplicates and tools the player no longer owns. Safe to call any time (ShopService calls it after BuyTool).
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
	local gear: { [string]: boolean } = {}
	for _, tool in toolsIn(starterGear) do
		local id = tool:GetAttribute("ToolId") :: string
		if not owned[id] or gear[id] then
			tool:Destroy()
		else
			gear[id] = true
		end
	end

	for _, id in Economy.ToolOrder do
		if owned[id] then
			local template = getTemplate(id)
			if template then
				if backpack and not have[id] then
					template:Clone().Parent = backpack
				end
				if starterGear and not gear[id] then
					template:Clone().Parent = starterGear
				end
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
	lastAssaultHeat[player] = nil
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
	for _, id in Economy.ToolOrder do
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
