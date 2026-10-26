--!strict
-- EffectsController (SPEC §7): every cosmetic world effect on the client.
--
--  * Effect remote router: (name, data) -> CarWreck, Confetti, Zap, Bonk, TirePop, SpikeDrop, CashBurst, BigSteal.
--    data.position (Vector3) is the anchor (also accepted: data.cframe, data.model / data.instance, data.from).
--    data.sound (Config/Sounds key) is played with the effect through SoundController. Unknown names are ignored.
--  * Rarity tags: BillboardGui over every "Vehicle"-tagged car that is Parked / Traffic / HotDrop / unoccupied Loot,
--    rarity order >= 3 (Rare+), within 150 studs: "EPIC • Phantom GT • $260/s" with a rarity-colored glow,
--    mutation label on top. Steal prompts (Hotwire / Carjack / StealPrompt) on those cars get their HoldDuration
--    scaled locally by the player attribute HoldMultiplier (the server validates with the same multiplier).
--  * Police lights: SirenRed / SirenBlue neon flashing + one local PointLight flipping red/blue (~6 Hz, <= 300 studs).
--
-- Everything is pooled: one Heartbeat drives all moving bits (BulkMoveTo), bolts and comic billboards are reused,
-- particle bursts come from a ring of emitter hosts. Built-in textures only.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Cars = require(Config:WaitForChild("Cars"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Util = Shared:WaitForChild("Util")
local EconomyMath = require(Util:WaitForChild("EconomyMath"))
local Format = require(Util:WaitForChild("Format"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

local EffectsController = {}

local player = Players.LocalPlayer
local rng = Random.new()

local TEX_SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TEX_STAR = "rbxasset://textures/sparkle.png"

local CULL_DISTANCE = 380 -- effects farther than this from the camera are skipped
local TAG_RANGE = 150
local TAG_MIN_ORDER = 3 -- Rare+
local TAG_POOL_MAX = 30
local TAG_TICK = 0.25
local SIREN_RANGE = 300
local SIREN_INTERVAL = 1 / 6
local MAX_PARTS = 420
local HOST_COUNT = 6
local COMIC_COUNT = 6
local HIDDEN = CFrame.new(0, -10000, 0)
local UP = Vector3.new(0, 1, 0)

local CONFETTI_COLORS = {
	Theme.Colors.Primary,
	Theme.Colors.Secondary,
	Theme.Colors.Gold,
	Theme.Colors.Cash,
	Color3.fromRGB(175, 80, 255),
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(255, 120, 40),
}
local SIREN_RED = Color3.fromRGB(255, 40, 60)
local SIREN_BLUE = Color3.fromRGB(40, 110, 255)

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

-- Should a car get a floating rarity tag?
function EffectsController.shouldShowRarityTag(
	kind: any,
	rarityOrder: number,
	occupied: boolean,
	distance: number
): boolean
	if distance > TAG_RANGE or rarityOrder < TAG_MIN_ORDER then
		return false
	end
	if kind == "Parked" or kind == "Traffic" or kind == "HotDrop" then
		return true
	end
	return kind == "Loot" and not occupied
end

-- Jagged lightning polyline from a to b: segments+1 points, ends pinned, interior jittered perpendicular to the bolt
-- (amplitude tapers toward both ends).
function EffectsController.boltPoints(
	a: Vector3,
	b: Vector3,
	segments: number,
	amplitude: number,
	random: Random
): { Vector3 }
	local points = { a }
	local dir = b - a
	local len = dir.Magnitude
	if len < 1e-3 then
		table.insert(points, b)
		return points
	end
	local unit = dir / len
	local side = unit:Cross(UP)
	if side.Magnitude < 1e-3 then
		side = unit:Cross(Vector3.new(1, 0, 0))
	end
	side = side.Unit
	local up2 = side:Cross(unit).Unit
	for i = 1, segments - 1 do
		local t = i / segments
		local taper = math.sin(t * math.pi)
		local off = side * random:NextNumber(-1, 1) * amplitude * taper
			+ up2 * random:NextNumber(-1, 1) * amplitude * taper
		table.insert(points, a + dir * t + off)
	end
	table.insert(points, b)
	return points
end

local function hex(c: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

-- Readable tag color for a rarity (Secret is black -> render it as a pale violet so it still reads at night).
local function tagColor(def: Rarity.RarityDef): Color3
	local c = def.color
	if c.R + c.G + c.B < 0.45 then
		return Color3.fromRGB(220, 200, 255)
	end
	return c
end

-- Rich text for a rarity tag line: "EPIC • Phantom GT • $260/s".
function EffectsController.tagText(carId: string, mutation: string): string?
	local def = Cars.get(carId)
	if not def then
		return nil
	end
	local rdef = Rarity.Tiers[def.rarity]
	if not rdef then
		return nil
	end
	local income = EconomyMath.carIncome(carId, mutation :: any)
	local rarityHex = hex(tagColor(rdef))
	local cashHex = hex(Theme.Colors.Cash)
	local rarityName = string.upper(def.rarity)
	local incomeText = Format.cash(income)
	return `<font color="{rarityHex}">{rarityName}</font> • {def.name} • <font color="{cashHex}">{incomeText}/s</font>`
end

-------------------------------------------------------------------------------------------------------------------------
-- Optional controllers (lazy)
-------------------------------------------------------------------------------------------------------------------------

local soundController: any = nil
local function playSound(key: string, position: Vector3?)
	if soundController == nil then
		local mod = script.Parent:FindFirstChild("SoundController")
		if mod then
			local ok, result = pcall(require, mod :: any)
			soundController = if ok and typeof(result) == "table" then result else false
		else
			soundController = false
		end
	end
	if soundController and typeof(soundController.play) == "function" then
		pcall(soundController.play, key, position)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Part pool + bit simulation
-------------------------------------------------------------------------------------------------------------------------

local fxFolder: Folder? = nil
local freeParts: { Part } = {}
local totalParts = 0

local function getFxFolder(): Folder
	local f = fxFolder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "ClientFX"
	nf.Parent = Workspace
	fxFolder = nf
	return nf
end

local function acquirePart(): Part?
	local p = table.remove(freeParts)
	if p and p.Parent then
		return p
	end
	if totalParts >= MAX_PARTS then
		return nil
	end
	totalParts += 1
	local np = Instance.new("Part")
	np.Name = "FX"
	np.Anchored = true
	np.CanCollide = false
	np.CanQuery = false
	np.CanTouch = false
	np.CastShadow = false
	np.TopSurface = Enum.SurfaceType.Smooth
	np.BottomSurface = Enum.SurfaceType.Smooth
	np.Transparency = 1
	np.CFrame = HIDDEN
	np.Parent = getFxFolder()
	return np
end

local function releasePart(p: Part)
	p.Transparency = 1
	p.CFrame = HIDDEN
	if p.Parent then
		table.insert(freeParts, p)
	else
		totalParts -= 1
	end
end

type Bit = {
	part: Part,
	pos: Vector3,
	vel: Vector3,
	rot: CFrame,
	spinAxis: Vector3,
	spinRate: number,
	age: number,
	life: number,
	gravity: number,
	drag: number,
	fadeStart: number,
	baseTransparency: number,
	size0: Vector3,
	size1: Vector3?,
	groundY: number?,
	bounce: number,
}

type BitSpec = {
	shape: Enum.PartType?,
	size: Vector3,
	size1: Vector3?,
	color: Color3,
	material: Enum.Material?,
	pos: Vector3,
	vel: Vector3?,
	rot: CFrame?,
	spin: number?,
	life: number,
	gravity: number?,
	drag: number?,
	fadeStart: number?,
	transparency: number?,
	groundY: number?,
	bounce: number?,
}

local bits: { Bit } = {}
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function spawnBit(spec: BitSpec)
	local part = acquirePart()
	if not part then
		return
	end
	part.Shape = spec.shape or Enum.PartType.Block
	part.Size = spec.size
	part.Color = spec.color
	part.Material = spec.material or Enum.Material.SmoothPlastic
	local t = spec.transparency or 0
	part.Transparency = t
	local rot = spec.rot or CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28))
	part.CFrame = CFrame.new(spec.pos) * rot
	local spin = spec.spin or 0
	local axis = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
	table.insert(bits, {
		part = part,
		pos = spec.pos,
		vel = spec.vel or Vector3.zero,
		rot = rot,
		spinAxis = if axis.Magnitude > 1e-3 then axis.Unit else UP,
		spinRate = spin,
		age = 0,
		life = math.max(spec.life, 0.05),
		gravity = spec.gravity or 0,
		drag = spec.drag or 0,
		fadeStart = spec.fadeStart or 0.6,
		baseTransparency = t,
		size0 = spec.size,
		size1 = spec.size1,
		groundY = spec.groundY,
		bounce = spec.bounce or 0.4,
	})
end

local function stepBits(dt: number)
	if #bits == 0 then
		return
	end
	table.clear(moveParts)
	table.clear(moveCFrames)
	local i = 1
	while i <= #bits do
		local b = bits[i]
		b.age += dt
		local a = b.age / b.life
		if a >= 1 or not b.part.Parent then
			releasePart(b.part)
			bits[i] = bits[#bits]
			bits[#bits] = nil
		else
			local v = b.vel
			if b.drag > 0 then
				v *= math.max(0, 1 - b.drag * dt)
			end
			if b.gravity ~= 0 then
				v -= Vector3.new(0, b.gravity * dt, 0)
			end
			local pos = b.pos + v * dt
			local gy = b.groundY
			if gy then
				local floor = gy + b.part.Size.Y * 0.5
				if pos.Y < floor then
					pos = Vector3.new(pos.X, floor, pos.Z)
					v = Vector3.new(v.X * 0.6, math.abs(v.Y) * b.bounce, v.Z * 0.6)
					b.spinRate *= 0.6
				end
			end
			b.vel = v
			b.pos = pos
			if b.spinRate ~= 0 then
				b.rot = b.rot * CFrame.fromAxisAngle(b.spinAxis, b.spinRate * dt)
			end
			local s1 = b.size1
			if s1 then
				local e = 1 - (1 - a) ^ 3
				b.part.Size = b.size0:Lerp(s1, e)
			end
			if a > b.fadeStart then
				local f = (a - b.fadeStart) / math.max(1 - b.fadeStart, 1e-3)
				b.part.Transparency = b.baseTransparency + (1 - b.baseTransparency) * f
			end
			table.insert(moveParts, b.part)
			table.insert(moveCFrames, CFrame.new(pos) * b.rot)
			i += 1
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Lightning bolts
-------------------------------------------------------------------------------------------------------------------------

type Bolt = {
	from: Vector3,
	to: Vector3,
	outer: { Part },
	core: { Part },
	age: number,
	life: number,
	nextJitter: number,
	segments: number,
}
local bolts: { Bolt } = {}

local function layoutBolt(bolt: Bolt)
	local len = (bolt.to - bolt.from).Magnitude
	local amp = math.clamp(len * 0.07, 0.4, 3)
	local pts = EffectsController.boltPoints(bolt.from, bolt.to, bolt.segments, amp, rng)
	for i = 1, bolt.segments do
		local p0, p1 = pts[i], pts[i + 1]
		local mid = (p0 + p1) / 2
		local segLen = (p1 - p0).Magnitude
		local cf = CFrame.lookAt(mid, p1)
		local outer = bolt.outer[i]
		if outer then
			outer.Size = Vector3.new(0.38, 0.38, segLen + 0.2)
			outer.CFrame = cf
		end
		local core = bolt.core[i]
		if core then
			core.Size = Vector3.new(0.14, 0.14, segLen + 0.1)
			core.CFrame = cf
		end
	end
end

local function spawnBolt(from: Vector3, to: Vector3, color: Color3, life: number)
	local len = (to - from).Magnitude
	local segments = math.clamp(math.floor(len / 5) + 3, 4, 12)
	local bolt: Bolt = {
		from = from,
		to = to,
		outer = {},
		core = {},
		age = 0,
		life = life,
		nextJitter = 0.07,
		segments = segments,
	}
	for _ = 1, segments do
		local o = acquirePart()
		local c = acquirePart()
		if not o or not c then
			if o then
				releasePart(o)
			end
			if c then
				releasePart(c)
			end
			break
		end
		o.Shape = Enum.PartType.Block
		o.Material = Enum.Material.Neon
		o.Color = color
		o.Transparency = 0.15
		c.Shape = Enum.PartType.Block
		c.Material = Enum.Material.Neon
		c.Color = Color3.new(1, 1, 1)
		c.Transparency = 0
		table.insert(bolt.outer, o)
		table.insert(bolt.core, c)
	end
	if #bolt.outer == 0 then
		return
	end
	bolt.segments = #bolt.outer
	layoutBolt(bolt)
	table.insert(bolts, bolt)
end

local function stepBolts(dt: number)
	local i = 1
	while i <= #bolts do
		local bolt = bolts[i]
		bolt.age += dt
		if bolt.age >= bolt.life then
			for _, p in bolt.outer do
				releasePart(p)
			end
			for _, p in bolt.core do
				releasePart(p)
			end
			bolts[i] = bolts[#bolts]
			bolts[#bolts] = nil
		else
			if bolt.age >= bolt.nextJitter then
				bolt.nextJitter += 0.07
				layoutBolt(bolt)
			end
			local f = bolt.age / bolt.life
			for _, p in bolt.outer do
				p.Transparency = 0.15 + 0.85 * f
			end
			for _, p in bolt.core do
				p.Transparency = f * f
			end
			i += 1
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Emitter hosts (particle bursts + light flashes)
-------------------------------------------------------------------------------------------------------------------------

type Host = {
	part: Part,
	sparkle: ParticleEmitter,
	smoke: ParticleEmitter,
	star: ParticleEmitter,
	fire: ParticleEmitter,
	light: PointLight,
}
local hosts: { Host } = {}
local hostIndex = 0

local function newEmitter(parent: Instance, name: string, texture: string): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Texture = texture
	e.Enabled = false
	e.Rate = 0
	e.LockedToPart = false
	e.LightEmission = 0.6
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-180, 180)
	e.Parent = parent
	return e
end

local function buildHost(): Host
	local part = Instance.new("Part")
	part.Name = "FXHost"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = HIDDEN
	local sparkle = newEmitter(part, "Sparkle", TEX_SPARKLES)
	sparkle.Lifetime = NumberRange.new(0.4, 0.8)
	sparkle.Speed = NumberRange.new(18, 34)
	sparkle.Drag = 4
	sparkle.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	local smoke = newEmitter(part, "Smoke", TEX_SMOKE)
	smoke.Lifetime = NumberRange.new(0.7, 1.2)
	smoke.Speed = NumberRange.new(6, 14)
	smoke.Drag = 3
	smoke.LightEmission = 0
	smoke.Acceleration = Vector3.new(0, 8, 0)
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(1, 8),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	local star = newEmitter(part, "Star", TEX_STAR)
	star.Lifetime = NumberRange.new(0.5, 0.9)
	star.Speed = NumberRange.new(12, 24)
	star.Drag = 3
	star.LightEmission = 1
	star.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	local fire = newEmitter(part, "Fire", TEX_FIRE)
	fire.Lifetime = NumberRange.new(0.25, 0.45)
	fire.Speed = NumberRange.new(10, 20)
	fire.Drag = 5
	fire.LightEmission = 1
	fire.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2.5),
		NumberSequenceKeypoint.new(1, 0.5),
	})
	fire.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	local light = Instance.new("PointLight")
	light.Brightness = 0
	light.Range = 18
	light.Shadows = false
	light.Parent = part
	part.Parent = getFxFolder()
	return { part = part, sparkle = sparkle, smoke = smoke, star = star, fire = fire, light = light }
end

local function hostAt(position: Vector3): Host
	hostIndex = hostIndex % HOST_COUNT + 1
	local h = hosts[hostIndex]
	if not h or not h.part.Parent then
		h = buildHost()
		hosts[hostIndex] = h
	end
	h.part.CFrame = CFrame.new(position)
	return h
end

local function burst(e: ParticleEmitter, count: number, color: Color3?)
	if color then
		e.Color = ColorSequence.new(color)
	end
	e:Emit(count)
end

local function flash(h: Host, color: Color3, brightness: number, duration: number)
	h.light.Color = color
	h.light.Brightness = brightness
	TweenService:Create(h.light, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0,
	}):Play()
end

-------------------------------------------------------------------------------------------------------------------------
-- Comic text billboards ("KAPOW!", "BONK!", "POP!")
-------------------------------------------------------------------------------------------------------------------------

type Comic = {
	anchor: Part,
	gui: BillboardGui,
	scale: UIScale,
	body: Frame,
	backs: { Frame },
	fronts: { Frame },
	label: TextLabel,
	token: number,
	startedAt: number,
}
local comics: { Comic } = {}

local function buildComic(): Comic
	local anchor = Instance.new("Part")
	anchor.Name = "ComicAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = HIDDEN
	anchor.Parent = getFxFolder()
	local gui = Kit.new("BillboardGui", {
		Name = "Comic",
		Adornee = anchor,
		Size = UDim2.fromOffset(220, 140),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 260,
		ClipsDescendants = false,
		Enabled = false,
		ResetOnSpawn = false,
		Parent = anchor,
	}) :: BillboardGui
	local body = Kit.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	}) :: Frame
	local scale = Kit.new("UIScale", { Scale = 0, Parent = body }) :: UIScale
	-- 12-point starburst = 3 squares at 0/30/60 degrees; dark copies behind form the outline
	local backs: { Frame } = {}
	local fronts: { Frame } = {}
	for layer = 1, 2 do
		for k = 0, 2 do
			-- RelativeYY: both axes measured against the height -> squares; 0.72 keeps rotated corners inside
			local sq = Kit.new("Frame", {
				Name = if layer == 1 then "Outline" else "Fill",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = if layer == 1 then UDim2.fromScale(0.72, 0.72) else UDim2.fromScale(0.64, 0.64),
				SizeConstraint = Enum.SizeConstraint.RelativeYY,
				Rotation = k * 30 + 8,
				BorderSizePixel = 0,
				BackgroundColor3 = if layer == 1 then Theme.Colors.Stroke else Theme.Colors.Gold,
				ZIndex = layer,
				Parent = body,
			}) :: Frame
			table.insert(if layer == 1 then backs else fronts, sq)
		end
	end
	local label = Kit.label("", 44, {
		Name = "Text",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.96, 0.46),
		TextScaled = true,
		TextWrapped = false,
		Rotation = -8,
		ZIndex = 3,
		Parent = body,
	})
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 4
	end
	return {
		anchor = anchor,
		gui = gui,
		scale = scale,
		body = body,
		backs = backs,
		fronts = fronts,
		label = label,
		token = 0,
		startedAt = -math.huge,
	}
end

local function acquireComic(): Comic
	local oldest: Comic? = nil
	for _, c in comics do
		if not c.gui.Enabled and c.anchor.Parent then
			return c
		end
		if not oldest or c.startedAt < oldest.startedAt then
			oldest = c
		end
	end
	if #comics < COMIC_COUNT then
		local c = buildComic()
		table.insert(comics, c)
		return c
	end
	return oldest :: Comic
end

local POP_IN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In)
local FLOAT = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function showComic(position: Vector3, text: string, textColor: Color3, burstColor: Color3, size: number)
	local c = acquireComic()
	c.token += 1
	local token = c.token
	c.startedAt = os.clock()
	c.anchor.CFrame = CFrame.new(position)
	c.gui.Size = UDim2.fromOffset(220 * size, 140 * size)
	c.gui.StudsOffsetWorldSpace = Vector3.zero
	c.label.Text = text
	c.label.TextColor3 = textColor
	c.label.Rotation = rng:NextNumber(-12, 6)
	for _, f in c.fronts do
		f.BackgroundColor3 = burstColor
	end
	local spin = rng:NextNumber(-10, 10)
	c.body.Rotation = spin
	c.scale.Scale = 0.2
	c.gui.Enabled = true
	TweenService:Create(c.scale, POP_IN, { Scale = 1 }):Play()
	TweenService:Create(c.body, FLOAT, { Rotation = -spin * 0.5 }):Play()
	TweenService:Create(c.gui, FLOAT, { StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0) }):Play()
	task.delay(0.8, function()
		if c.token ~= token then
			return
		end
		TweenService:Create(c.scale, POP_OUT, { Scale = 0 }):Play()
		task.delay(0.2, function()
			if c.token == token then
				c.gui.Enabled = false
				c.anchor.CFrame = HIDDEN
			end
		end)
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Effect building blocks
-------------------------------------------------------------------------------------------------------------------------

local groundParams: RaycastParams? = nil
local function groundBelow(pos: Vector3): number
	local params = groundParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = false
		groundParams = params
	end
	local exclude: { Instance } = { getFxFolder() }
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if vehicles then
		table.insert(exclude, vehicles)
	end
	local character = player.Character
	if character then
		table.insert(exclude, character)
	end
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -60, 0), params)
	return if hit then hit.Position.Y else pos.Y - 3
end

local function randomFlat(): Vector3
	local a = rng:NextNumber(0, math.pi * 2)
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

local function ring(pos: Vector3, color: Color3, diameter: number, life: number)
	spawnBit({
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(0.25, 1, 1),
		size1 = Vector3.new(0.25, diameter, diameter),
		rot = CFrame.Angles(0, 0, math.pi / 2),
		color = color,
		material = Enum.Material.Neon,
		pos = pos,
		life = life,
		fadeStart = 0,
		transparency = 0.1,
	})
end

local function puffs(
	pos: Vector3,
	count: number,
	color: Color3,
	size0: number,
	size1: number,
	speed: number,
	life: number
)
	for _ = 1, count do
		local dir = randomFlat()
		local s0 = size0 * rng:NextNumber(0.8, 1.2)
		local s1 = size1 * rng:NextNumber(0.8, 1.2)
		local shade = rng:NextNumber(0.88, 1)
		spawnBit({
			shape = Enum.PartType.Ball,
			size = Vector3.new(s0, s0, s0),
			size1 = Vector3.new(s1, s1, s1),
			color = Color3.new(color.R * shade, color.G * shade, color.B * shade),
			pos = pos + dir * rng:NextNumber(0.3, 1.5) + UP * rng:NextNumber(0, 1.5),
			vel = dir * speed * rng:NextNumber(0.5, 1.2) + UP * speed * rng:NextNumber(0.4, 0.9),
			life = life * rng:NextNumber(0.85, 1.15),
			gravity = -4,
			drag = 3,
			fadeStart = 0.35,
			transparency = 0.05,
		})
	end
end

local function confettiBurst(pos: Vector3, count: number, power: number)
	for _ = 1, count do
		spawnBit({
			size = Vector3.new(rng:NextNumber(0.5, 0.8), 0.06, rng:NextNumber(0.3, 0.45)),
			color = CONFETTI_COLORS[rng:NextInteger(1, #CONFETTI_COLORS)],
			pos = pos + UP * 1.5,
			vel = randomFlat() * rng:NextNumber(6, 26) * power + UP * rng:NextNumber(45, 85) * power,
			spin = rng:NextNumber(8, 18),
			life = rng:NextNumber(2.2, 3.2),
			gravity = 40,
			drag = 2.5,
			fadeStart = 0.7,
		})
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Effect handlers
-------------------------------------------------------------------------------------------------------------------------

type Handler = (data: { [string]: any }, pos: Vector3?) -> ()
local handlers: { [string]: Handler } = {}

handlers.CarWreck = function(data, pos)
	if not pos then
		return
	end
	local ground = groundBelow(pos)
	local debrisColor: Color3? = if typeof(data.color) == "Color3" then data.color else nil
	puffs(pos, 10, Color3.fromRGB(235, 235, 240), 2.4, 8, 18, 1.1)
	puffs(pos + UP * 1.5, 4, Color3.fromRGB(120, 120, 130), 2, 6, 10, 1.3)
	for i = 1, 10 do
		local s = rng:NextNumber(0.5, 1.2)
		spawnBit({
			size = Vector3.new(s, s * rng:NextNumber(0.5, 1), s),
			color = if debrisColor and i % 2 == 0
				then debrisColor
				else (if i % 3 == 0 then Theme.Colors.Gold else Color3.fromRGB(70, 72, 84)),
			pos = pos + UP,
			vel = randomFlat() * rng:NextNumber(16, 38) + UP * rng:NextNumber(40, 75),
			spin = rng:NextNumber(6, 14),
			life = rng:NextNumber(1.4, 2.1),
			gravity = 150,
			drag = 0.3,
			fadeStart = 0.65,
			groundY = ground,
			bounce = 0.45,
		})
	end
	ring(Vector3.new(pos.X, ground + 0.4, pos.Z), Color3.fromRGB(255, 230, 140), 26, 0.4)
	local h = hostAt(pos + UP)
	burst(h.fire, 14, Color3.fromRGB(255, 170, 60))
	burst(h.sparkle, 30, Theme.Colors.Gold)
	burst(h.smoke, 10, Color3.fromRGB(200, 200, 205))
	flash(h, Color3.fromRGB(255, 170, 60), 10, 0.5)
	showComic(pos + UP * 5, "KAPOW!", Theme.Colors.Danger, Theme.Colors.Gold, 1.25)
end

handlers.Confetti = function(_data, pos)
	if not pos then
		return
	end
	confettiBurst(pos, 46, 1)
	local h = hostAt(pos + UP * 2)
	burst(h.sparkle, 30, Theme.Colors.Gold)
	burst(h.star, 14, Theme.Colors.Secondary)
end

handlers.Zap = function(data, _pos)
	local from = data.from
	local to = data.to
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return
	end
	if (to - from).Magnitude > 400 then
		return
	end
	spawnBolt(from, to, Theme.Colors.Secondary, 0.25)
	spawnBolt(from, to, Color3.fromRGB(150, 255, 140), 0.18)
	local h = hostAt(to)
	burst(h.sparkle, if data.hit then 26 else 12, Theme.Colors.Secondary)
	flash(h, Theme.Colors.Secondary, if data.hit then 8 else 4, 0.3)
	local h2 = hostAt(from)
	burst(h2.star, 4, Color3.fromRGB(150, 255, 140))
	if data.hit == true then
		ring(to, Theme.Colors.Secondary, 8, 0.25)
		showComic(to + UP * 3, "ZAP!", Color3.fromRGB(255, 255, 255), Theme.Colors.Secondary, 0.8)
	end
end

handlers.Bonk = function(_data, pos)
	if not pos then
		return
	end
	for _ = 1, 7 do
		local dir = randomFlat()
		spawnBit({
			size = Vector3.new(0.5, 0.5, 0.5),
			color = Theme.Colors.Gold,
			material = Enum.Material.Neon,
			pos = pos,
			vel = dir * rng:NextNumber(14, 24) + UP * rng:NextNumber(10, 22),
			spin = rng:NextNumber(10, 18),
			life = rng:NextNumber(0.5, 0.8),
			gravity = 50,
			drag = 2,
			fadeStart = 0.5,
		})
	end
	ring(pos, Color3.fromRGB(255, 255, 255), 9, 0.25)
	local h = hostAt(pos)
	burst(h.star, 12, Theme.Colors.Gold)
	flash(h, Color3.fromRGB(255, 240, 180), 5, 0.25)
	showComic(pos + UP * 2.5, "BONK!", Theme.Colors.Primary, Color3.fromRGB(255, 255, 255), 1)
end

handlers.TirePop = function(_data, pos)
	if not pos then
		return
	end
	local ground = groundBelow(pos)
	for _ = 1, 7 do
		local s = rng:NextNumber(0.35, 0.7)
		spawnBit({
			size = Vector3.new(s, s * 0.5, s * 1.4),
			color = Color3.fromRGB(28, 28, 34),
			pos = Vector3.new(pos.X, ground + 0.8, pos.Z),
			vel = randomFlat() * rng:NextNumber(10, 24) + UP * rng:NextNumber(18, 36),
			spin = rng:NextNumber(8, 16),
			life = rng:NextNumber(0.9, 1.3),
			gravity = 120,
			drag = 0.5,
			fadeStart = 0.6,
			groundY = ground,
		})
	end
	puffs(Vector3.new(pos.X, ground + 0.6, pos.Z), 4, Color3.fromRGB(210, 210, 215), 1.2, 4, 8, 0.7)
	showComic(pos + UP * 3, "POP!", Color3.fromRGB(255, 255, 255), Theme.Colors.Danger, 0.8)
end

handlers.SpikeDrop = function(_data, pos)
	if not pos then
		return
	end
	puffs(pos + UP * 0.3, 5, Color3.fromRGB(215, 200, 170), 1, 3.5, 7, 0.6)
	local h = hostAt(pos + UP * 0.5)
	burst(h.sparkle, 10, Theme.Colors.Primary)
end

handlers.CashBurst = function(_data, pos)
	if not pos then
		return
	end
	for i = 1, 20 do
		spawnBit({
			size = Vector3.new(1, 0.06, 0.5),
			color = if i % 3 == 0 then Theme.Colors.CashDark else Theme.Colors.Cash,
			pos = pos + UP,
			vel = randomFlat() * rng:NextNumber(8, 20) + UP * rng:NextNumber(35, 60),
			spin = rng:NextNumber(6, 12),
			life = rng:NextNumber(1.8, 2.4),
			gravity = 40,
			drag = 2.2,
			fadeStart = 0.7,
		})
	end
	local h = hostAt(pos + UP)
	burst(h.sparkle, 24, Theme.Colors.Cash)
	flash(h, Theme.Colors.Cash, 5, 0.4)
end

handlers.BigSteal = function(data, pos)
	if not pos then
		return
	end
	confettiBurst(pos, 64, 1.25)
	ring(pos + UP * 0.5, Theme.Colors.Gold, 34, 0.55)
	ring(pos + UP * 0.6, Theme.Colors.Primary, 20, 0.4)
	spawnBit({
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(90, 1.5, 1.5),
		size1 = Vector3.new(90, 7, 7),
		rot = CFrame.Angles(0, 0, math.pi / 2),
		color = Theme.Colors.Gold,
		material = Enum.Material.Neon,
		pos = pos + UP * 45,
		life = 1.5,
		fadeStart = 0.15,
		transparency = 0.35,
	})
	local h = hostAt(pos + UP * 3)
	burst(h.sparkle, 40, Theme.Colors.Gold)
	burst(h.star, 20, Theme.Colors.Primary)
	flash(h, Theme.Colors.Gold, 12, 0.8)
	local text = if typeof(data.text) == "string"
			and #data.text > 0
			and #data.text <= 24
		then string.upper(data.text)
		else "BIG STEAL!"
	showComic(pos + UP * 7, text, Theme.Colors.Gold, Theme.Colors.Primary, 1.5)
end

local DEFAULT_SOUNDS: { [string]: string } = {
	CarWreck = "Poof",
}

local function resolvePosition(data: { [string]: any }): Vector3?
	local p = data.position
	if typeof(p) == "Vector3" then
		return p
	end
	local cf = data.cframe
	if typeof(cf) == "CFrame" then
		return cf.Position
	end
	local inst = data.model or data.instance
	if typeof(inst) == "Instance" and inst:IsA("PVInstance") and inst.Parent then
		return inst:GetPivot().Position
	end
	local from = data.from
	if typeof(from) == "Vector3" then
		return from
	end
	return nil
end

local function cameraPosition(): Vector3?
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else nil
end

-- Play a cosmetic effect locally (also used by the Effect remote). data.sound plays a Config/Sounds key with it.
function EffectsController.play(name: string, data: { [string]: any }?)
	local handler = handlers[name]
	if not handler then
		return
	end
	local d = data or {}
	local pos = resolvePosition(d)
	local cam = cameraPosition()
	if cam then
		local near = pos == nil or (pos - cam).Magnitude <= CULL_DISTANCE
		if not near and typeof(d.to) == "Vector3" then
			near = ((d.to :: Vector3) - cam).Magnitude <= CULL_DISTANCE
		end
		if not near then
			return
		end
	end
	local ok, err = pcall(handler, d, pos)
	if not ok then
		warn("[EffectsController] " .. name .. " failed: " .. tostring(err))
	end
	local sound = if typeof(d.sound) == "string" then d.sound else DEFAULT_SOUNDS[name]
	if sound then
		playSound(sound, pos)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Rarity tags
-------------------------------------------------------------------------------------------------------------------------

type TagRec = {
	model: Model,
	gui: BillboardGui?,
	key: string?,
	pulse: Tween?,
}
local tracked: { [Model]: TagRec } = {}
local tagPool: { BillboardGui } = {}
local tagCount = 0
local playerGui: Instance? = nil

local function buildTag(): BillboardGui
	local gui = Kit.new("BillboardGui", {
		Name = "RarityTag",
		Size = UDim2.fromOffset(460, 66),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = TAG_RANGE + 15,
		ResetOnSpawn = false,
		ClipsDescendants = false,
		Enabled = false,
	}) :: BillboardGui
	local holder = Kit.new("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	Kit.new("UIScale", { Name = "Pulse", Parent = holder })
	local pill = Kit.new("Frame", {
		Name = "Pill",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -2),
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Parent = holder,
	})
	Kit.corner(UDim.new(1, 0)).Parent = pill
	local glow = Kit.stroke(Color3.new(1, 1, 1), 3)
	glow.Name = "Glow"
	glow.Parent = pill
	Kit.new("UIGradient", {
		Name = "Shine",
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 200, 200)),
			ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 200, 200)),
		}),
		Parent = glow,
	})
	Kit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
		Parent = pill,
	})
	Kit.label("", 19, {
		Name = "Text",
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		Parent = pill,
	})
	Kit.label("", 16, {
		Name = "Mutation",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -36),
		Size = UDim2.new(1, 0, 0, 20),
		Visible = false,
		Parent = holder,
	})
	return gui
end

local function releaseTag(rec: TagRec)
	local gui = rec.gui
	if not gui then
		return
	end
	rec.gui = nil
	rec.key = nil
	if rec.pulse then
		rec.pulse:Cancel()
		rec.pulse = nil
	end
	gui.Enabled = false
	gui.Adornee = nil
	if gui.Parent and #tagPool < TAG_POOL_MAX then
		table.insert(tagPool, gui)
	else
		tagCount -= 1
		gui:Destroy()
	end
end

local function acquireTag(): BillboardGui?
	local gui = table.remove(tagPool)
	if gui and gui.Parent then
		return gui
	end
	if tagCount >= TAG_POOL_MAX then
		return nil
	end
	tagCount += 1
	local g = buildTag()
	g.Parent = playerGui
	return g
end

local function styleTag(rec: TagRec, gui: BillboardGui, carId: string, mutation: string)
	local def = Cars.get(carId)
	if not def then
		return
	end
	local rdef = Rarity.Tiers[def.rarity]
	local color = tagColor(rdef)
	local holder = gui:FindFirstChild("Holder") :: Frame
	local pill = holder:FindFirstChild("Pill") :: Frame
	local text = pill:FindFirstChild("Text") :: TextLabel
	text.Text = EffectsController.tagText(carId, mutation) or def.name
	local glow = pill:FindFirstChild("Glow") :: UIStroke
	glow.Color = color
	glow.Thickness = if rdef.order >= 5 then 4 else 3
	local mut = holder:FindFirstChild("Mutation") :: TextLabel
	local mdef = Rarity.getMutation(mutation :: any)
	if mdef.id ~= "None" then
		mut.Visible = true
		mut.Text = `✨ {mdef.label} ✨`
		mut.TextColor3 = mdef.color or Theme.Colors.Primary
	else
		mut.Visible = false
	end
	local pulse = holder:FindFirstChild("Pulse") :: UIScale
	pulse.Scale = 1
	if rec.pulse then
		rec.pulse:Cancel()
		rec.pulse = nil
	end
	if rdef.order >= 5 then
		local tw = TweenService:Create(
			pulse,
			TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.08 }
		)
		tw:Play()
		rec.pulse = tw
	end
end

local function isOccupied(model: Model): boolean
	local seat = model:FindFirstChild("DriverSeat")
	if seat and seat:IsA("VehicleSeat") and seat.Occupant ~= nil then
		return true
	end
	local uid = model:GetAttribute("DriverUserId")
	return typeof(uid) == "number" and uid > 0
end

local function topOffset(model: Model, chassis: BasePart): number
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and cf and size then
		return (cf.Position.Y + size.Y / 2) - chassis.Position.Y + 2.2
	end
	return 5
end

local function trackVehicle(inst: Instance)
	if inst:IsA("Model") and not tracked[inst] then
		tracked[inst] = { model = inst }
	end
end

local function untrackVehicle(inst: Instance)
	if inst:IsA("Model") then
		local rec = tracked[inst]
		if rec then
			releaseTag(rec)
			tracked[inst] = nil
		end
	end
end

local function updateTags()
	local cam = cameraPosition()
	if not cam then
		return
	end
	local focus = cam
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		focus = root.Position
	end
	for model, rec in tracked do
		if not model.Parent then
			releaseTag(rec)
			tracked[model] = nil
			continue
		end
		local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
		local show = false
		local carId = model:GetAttribute("CarId")
		local mutation = model:GetAttribute("Mutation")
		local mut = if typeof(mutation) == "string" then mutation else "None"
		if chassis and chassis:IsA("BasePart") and typeof(carId) == "string" then
			local def = Cars.get(carId)
			if def then
				local rid = model:GetAttribute("Rarity")
				local rdef = Rarity.Tiers[if typeof(rid) == "string" then rid :: any else def.rarity]
					or Rarity.Tiers[def.rarity]
				show = EffectsController.shouldShowRarityTag(
					model:GetAttribute("Kind"),
					rdef.order,
					isOccupied(model),
					(chassis.Position - focus).Magnitude
				)
			end
		end
		if show and chassis and chassis:IsA("BasePart") then
			local key = `{carId}|{mut}`
			if not rec.gui then
				local gui = acquireTag()
				if gui then
					rec.gui = gui
					gui.Adornee = chassis
					gui.StudsOffsetWorldSpace = Vector3.new(0, topOffset(model, chassis), 0)
				end
			end
			local gui = rec.gui
			if gui then
				if rec.key ~= key then
					rec.key = key
					styleTag(rec, gui, carId :: string, mut)
				end
				gui.Adornee = chassis
				gui.Enabled = true
			end
		elseif rec.gui then
			releaseTag(rec)
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Local hold-duration scaling for steal prompts on vehicles
-------------------------------------------------------------------------------------------------------------------------

local shownPrompts: { [ProximityPrompt]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local baseHold: { [ProximityPrompt]: number } = setmetatable({}, { __mode = "k" }) :: any
local appliedHold: { [ProximityPrompt]: number } = setmetatable({}, { __mode = "k" }) :: any

local function isStealPrompt(prompt: ProximityPrompt): boolean
	local n = prompt.Name
	if n == "Hotwire" or n == "Carjack" or n == "StealPrompt" then
		return true
	end
	local a = prompt.ActionText
	return a == "Hotwire" or a == "Carjack" or a:sub(1, 5) == "Steal"
end

local function vehicleOf(prompt: ProximityPrompt): Model?
	local node = prompt.Parent
	while node and node ~= Workspace do
		if node:IsA("Model") and CollectionService:HasTag(node, "Vehicle") then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function holdMultiplier(): number
	local m = player:GetAttribute("HoldMultiplier")
	if typeof(m) ~= "number" or m ~= m or m <= 0 then
		return 1
	end
	return math.clamp(m, 0.05, 4)
end

local function applyHold(prompt: ProximityPrompt)
	local attrBase = prompt:GetAttribute("BaseHoldDuration")
	if typeof(attrBase) ~= "number" then
		attrBase = prompt:GetAttribute("BaseHold") -- GarageService's name for the same thing
	end
	local base: number
	if typeof(attrBase) == "number" then
		base = attrBase
	else
		local current = prompt.HoldDuration
		local applied = appliedHold[prompt]
		local cached = baseHold[prompt]
		if applied and cached and math.abs(current - applied) < 1e-3 then
			base = cached -- our own override is still in place
		else
			base = current -- fresh value from the server
			baseHold[prompt] = current
		end
	end
	local target = base * holdMultiplier()
	appliedHold[prompt] = target
	if math.abs(prompt.HoldDuration - target) > 1e-3 then
		prompt.HoldDuration = target
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Police siren lights
-------------------------------------------------------------------------------------------------------------------------

type PoliceRec = {
	model: Model,
	reds: { BasePart },
	blues: { BasePart },
	light: PointLight?,
	scannedAt: number,
}
local policeCars: { [Model]: PoliceRec } = {}
local sirenPhase = false

local function policeModelOf(inst: Instance): Model?
	if inst:IsA("Model") then
		return inst
	end
	return inst:FindFirstAncestorWhichIsA("Model")
end

local function scanSirens(rec: PoliceRec)
	rec.scannedAt = os.clock()
	table.clear(rec.reds)
	table.clear(rec.blues)
	for _, d in rec.model:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Name == "SirenRed" then
				table.insert(rec.reds, d)
			elseif d.Name == "SirenBlue" then
				table.insert(rec.blues, d)
			end
		end
	end
end

local function trackPolice(inst: Instance)
	local model = policeModelOf(inst)
	if model and not policeCars[model] then
		local rec: PoliceRec = { model = model, reds = {}, blues = {}, light = nil, scannedAt = -math.huge }
		scanSirens(rec)
		policeCars[model] = rec
	end
end

local function untrackPolice(inst: Instance)
	local model = policeModelOf(inst)
	if model then
		local rec = policeCars[model]
		if rec then
			if rec.light then
				rec.light:Destroy()
			end
			policeCars[model] = nil
		end
	end
end

local function updateSirens()
	local cam = cameraPosition()
	if not cam then
		return
	end
	local now = os.clock()
	for model, rec in policeCars do
		if not model.Parent then
			if rec.light then
				rec.light:Destroy()
			end
			policeCars[model] = nil
			continue
		end
		local near = (model:GetPivot().Position - cam).Magnitude <= SIREN_RANGE
		if not near then
			if rec.light then
				rec.light.Enabled = false
			end
			continue
		end
		if #rec.reds + #rec.blues == 0 and now - rec.scannedAt > 1 then
			scanSirens(rec)
		end
		local redOn = sirenPhase
		for _, p in rec.reds do
			p.Transparency = if redOn then 0 else 0.8
		end
		for _, p in rec.blues do
			p.Transparency = if redOn then 0.8 else 0
		end
		local light = rec.light
		if not light or not light.Parent then
			local host = rec.reds[1] or rec.blues[1]
			if host and host.Parent then
				light = Instance.new("PointLight")
				light.Name = "SirenFlash"
				light.Range = 24
				light.Brightness = 4
				light.Shadows = false
				light.Parent = host
				rec.light = light
			end
		end
		if light then
			light.Enabled = true
			light.Color = if redOn then SIREN_RED else SIREN_BLUE
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function EffectsController.init() end

function EffectsController.start()
	getFxFolder()
	playerGui = player:WaitForChild("PlayerGui")

	Net.listen("Effect", function(name: any, data: any)
		if typeof(name) ~= "string" then
			return
		end
		EffectsController.play(name, if typeof(data) == "table" then data else nil)
	end)

	-- vehicles (rarity tags)
	CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(trackVehicle)
	CollectionService:GetInstanceRemovedSignal("Vehicle"):Connect(untrackVehicle)
	for _, inst in CollectionService:GetTagged("Vehicle") do
		trackVehicle(inst)
	end

	-- police lights
	CollectionService:GetInstanceAddedSignal("Police"):Connect(trackPolice)
	CollectionService:GetInstanceRemovedSignal("Police"):Connect(untrackPolice)
	for _, inst in CollectionService:GetTagged("Police") do
		trackPolice(inst)
	end

	-- prompt hold scaling
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if isStealPrompt(prompt) and vehicleOf(prompt) then
			shownPrompts[prompt] = true
			applyHold(prompt)
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		shownPrompts[prompt] = nil
	end)
	player:GetAttributeChangedSignal("HoldMultiplier"):Connect(function()
		for prompt in shownPrompts do
			if prompt.Parent then
				applyHold(prompt)
			end
		end
	end)

	local tagAcc = 0
	local sirenAcc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		stepBits(dt)
		if #bolts > 0 then
			stepBolts(dt)
		end
		tagAcc += dt
		if tagAcc >= TAG_TICK then
			tagAcc = 0
			updateTags()
		end
		if next(policeCars) ~= nil then
			sirenAcc += dt
			if sirenAcc >= SIREN_INTERVAL then
				sirenAcc = 0
				sirenPhase = not sirenPhase
				updateSirens()
			end
		end
	end)
end

return EffectsController
