--!strict
-- VFXLibrary: the premium effects toolkit every client controller shares (not a boot controller: no init/start).
--
--  * Builds ParticleEmitters / Trails / Beams / glare sprites from Config/VFX presets (our uploaded textures, with
--    built-in fallbacks when an id is missing).
--  * burst(name, at, opts): pooled one-shot emission. Each preset owns a small ring of emitters (VFX preset .pool)
--    on one anchored host part; an emitter is moved to the burst point and Emit()s. Instances are created once per
--    slot, never per burst / per frame. Particles live in world space, so one slot serves many bursts.
--  * stream(name, parent, opts) + setStream(stream, on, intensity): continuous emitters on a caller's attachment
--    (tire smoke, nitro, dust). Rates are written only when they change.
--  * Budget: every burst reserves its particles against a live-particle cap (quality tier); active streams count
--    their steady-state load (rate x lifetime) and are throttled when the load nears the cap.
--  * Quality tier: "high" | "medium" | "low" from UserGameSettings.SavedQualityLevel (1-3 low, 4-7 medium, 8-10 high;
--    Automatic = medium on phones, high elsewhere), re-read every VFX.QUALITY_REFRESH s; setQualityOverride() wins.
--  * Distance: bursts farther than VFX.MAX_DISTANCE (250) from the camera are skipped (opts.force overrides).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VFX = require(Shared:WaitForChild("Config"):WaitForChild("VFX"))

type Preset = VFX.Preset

local VFXLibrary = {}
VFXLibrary.Config = VFX

local HIDDEN = CFrame.new(0, -10000, 0)
local DEFAULT_POOL = 3

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

function VFXLibrary.texture(key: string): string
	local id = VFX.Textures[key]
	if type(id) == "string" and id ~= "" then
		return id
	end
	return VFX.Fallback[key] or ""
end

function VFXLibrary.numberSequence(keys: { VFX.NumKey }, scale: number?): NumberSequence
	local k = scale or 1
	local points = table.create(#keys)
	for i, key in keys do
		points[i] = NumberSequenceKeypoint.new(key.t, key.v * k, (key.e or 0) * k)
	end
	return NumberSequence.new(points)
end

function VFXLibrary.colorSequence(keys: { VFX.ColorKey }): ColorSequence
	local points = table.create(#keys)
	for i, key in keys do
		points[i] = ColorSequenceKeypoint.new(key.t, key.c)
	end
	return ColorSequence.new(points)
end

local function range(r: { number }?, default: number): NumberRange
	if r and #r >= 1 then
		return NumberRange.new(r[1], r[2] or r[1])
	end
	return NumberRange.new(default)
end

-- SavedQualityLevel (0 = Automatic, 1..10) + phone flag -> tier name.
function VFXLibrary.qualityTier(savedLevel: number, phone: boolean): string
	if savedLevel <= 0 then
		return if phone then "medium" else "high"
	elseif savedLevel <= 3 then
		return "low"
	elseif savedLevel <= 7 then
		return "medium"
	end
	return "high"
end

-- Scale a particle count by a quality factor: never below 1 for a requested positive count.
function VFXLibrary.scaledCount(n: number, factor: number): number
	if n <= 0 or factor <= 0 then
		return 0
	end
	return math.max(1, math.floor(n * factor + 0.5))
end

-- Steady-state particle load of a stream emitting `rate`/s with the preset's mean lifetime.
function VFXLibrary.streamLoad(rate: number, lifetime: { number }): number
	local lo = lifetime[1] or 0
	local hi = lifetime[2] or lo
	return math.max(0, rate) * (lo + hi) / 2
end

-- Rate multiplier for streams when their combined load nears the cap (they may use 60% of it).
function VFXLibrary.streamScale(cap: number, load: number): number
	local share = cap * 0.6
	if load <= share or load <= 0 then
		return 1
	end
	return math.max(0.25, share / load)
end

-- Arcade gear for a speed fraction: number of shift points at or below it (0 = first gear).
function VFXLibrary.gearOf(frac: number, shifts: { number }?): number
	local list = shifts or VFX.GEAR_SHIFTS
	local gear = 0
	for _, s in list do
		if frac >= s then
			gear += 1
		end
	end
	return gear
end

-- Dust color for a surface material name, nil for paved / hard surfaces.
function VFXLibrary.dustColor(materialName: string): Color3?
	return VFX.SurfaceDust[materialName]
end

-- CFrame at `pos` whose +Y (EmissionDirection Top) points along `dir`.
function VFXLibrary.alignUp(pos: Vector3, dir: Vector3?): CFrame
	if not dir or dir.Magnitude < 1e-4 then
		return CFrame.new(pos)
	end
	local u = dir.Unit
	if u.Y > 0.999 then
		return CFrame.new(pos)
	elseif u.Y < -0.999 then
		return CFrame.new(pos) * CFrame.Angles(math.pi, 0, 0)
	end
	return CFrame.lookAt(pos, pos + u) * CFrame.Angles(-math.pi / 2, 0, 0)
end

-------------------------------------------------------------------------------------------------------------------------
-- Budget (pure object; one shared instance below)
-------------------------------------------------------------------------------------------------------------------------

export type Budget = {
	cap: number,
	streamLoad: number,
	entries: { { n: number, untilT: number } },
	live: (self: Budget, now: number) -> number,
	reserve: (self: Budget, count: number, now: number, life: number) -> number,
}

local BudgetMT = {}
BudgetMT.__index = BudgetMT

function BudgetMT.live(self: Budget, now: number): number
	local total = 0
	local entries = self.entries
	local i = 1
	while i <= #entries do
		local e = entries[i]
		if e.untilT <= now then
			entries[i] = entries[#entries]
			entries[#entries] = nil
		else
			total += e.n
			i += 1
		end
	end
	return total
end

-- How many of `count` particles living `life` seconds fit under the cap (bursts + stream load). Records them.
function BudgetMT.reserve(self: Budget, count: number, now: number, life: number): number
	local free = self.cap - self:live(now) - self.streamLoad
	local allowed = math.clamp(math.floor(math.min(count, free)), 0, count)
	if allowed > 0 then
		table.insert(self.entries, { n = allowed, untilT = now + life })
	end
	return allowed
end

function VFXLibrary.newBudget(cap: number): Budget
	return setmetatable({ cap = cap, streamLoad = 0, entries = {} }, BudgetMT) :: any
end

-------------------------------------------------------------------------------------------------------------------------
-- Quality + camera
-------------------------------------------------------------------------------------------------------------------------

local qualityOverride: string? = nil
local cachedTier = "high"
local tierReadAt = -math.huge
local budget = VFXLibrary.newBudget(VFX.Quality.high.maxParticles)
VFXLibrary.budget = budget

local function isPhone(): boolean
	local ok, phone = pcall(function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.MouseEnabled
	end)
	return ok and phone == true
end

local function readSavedQuality(): number
	local ok, level = pcall(function()
		local settings = (UserSettings :: any)():GetService("UserGameSettings")
		return settings.SavedQualityLevel.Value
	end)
	return if ok and type(level) == "number" then level else 0
end

function VFXLibrary.setQualityOverride(tier: string?)
	qualityOverride = if tier and VFX.Quality[tier] then tier else nil
	tierReadAt = -math.huge
end

function VFXLibrary.quality(): string
	local now = os.clock()
	if now - tierReadAt >= VFX.QUALITY_REFRESH then
		tierReadAt = now
		cachedTier = qualityOverride or VFXLibrary.qualityTier(readSavedQuality(), isPhone())
		budget.cap = VFX.Quality[cachedTier].maxParticles
	end
	return cachedTier
end

function VFXLibrary.tier(): VFX.QualityTier
	return VFX.Quality[VFXLibrary.quality()]
end

local cameraOverride: Vector3? = nil
local function cameraPosition(): Vector3?
	if cameraOverride then
		return cameraOverride
	end
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else nil
end

function VFXLibrary.inRange(pos: Vector3, maxDistance: number?): boolean
	local cam = cameraPosition()
	if not cam then
		return true
	end
	return (pos - cam).Magnitude <= (maxDistance or VFX.MAX_DISTANCE)
end

-------------------------------------------------------------------------------------------------------------------------
-- Emitter configuration
-------------------------------------------------------------------------------------------------------------------------

local function enumItem(enum: any, name: string?): any
	if not name then
		return nil
	end
	local ok, item = pcall(function()
		return enum[name]
	end)
	return if ok then item else nil
end

-- Apply every preset property to an emitter. scale multiplies Size; color (Color3) replaces the color sequence.
function VFXLibrary.configure(e: ParticleEmitter, preset: Preset, scale: number?, color: Color3?)
	e.Texture = VFXLibrary.texture(preset.texture)
	e.Lifetime = range(preset.lifetime, 1)
	e.Speed = range(preset.speed, 0)
	local spread = preset.spread
	e.SpreadAngle = if spread then Vector2.new(spread[1], spread[2] or spread[1]) else Vector2.zero
	e.Rotation = range(preset.rotation, 0)
	e.RotSpeed = range(preset.rotSpeed, 0)
	e.Size = VFXLibrary.numberSequence(preset.size, scale)
	e.Transparency = VFXLibrary.numberSequence(preset.transparency)
	e.Squash = if preset.squash then VFXLibrary.numberSequence(preset.squash) else NumberSequence.new(0)
	if color then
		e.Color = ColorSequence.new(color)
	elseif preset.color then
		e.Color = VFXLibrary.colorSequence(preset.color)
	else
		e.Color = ColorSequence.new(Color3.new(1, 1, 1))
	end
	e.LightEmission = preset.lightEmission or 0
	e.LightInfluence = preset.lightInfluence or 1
	e.Brightness = preset.brightness or 1
	e.Acceleration = preset.acceleration or Vector3.zero
	e.Drag = preset.drag or 0
	e.ZOffset = preset.zOffset or 0
	e.LockedToPart = preset.lockedToPart == true
	e.TimeScale = preset.timeScale or 1
	e.Orientation = enumItem(Enum.ParticleOrientation, preset.orientation) or Enum.ParticleOrientation.FacingCamera
	e.EmissionDirection = enumItem(Enum.NormalId, preset.emissionDirection) or Enum.NormalId.Top
	local fb = preset.flipbook
	if fb then
		e.FlipbookLayout = enumItem(Enum.ParticleFlipbookLayout, fb.layout) or Enum.ParticleFlipbookLayout.None
		e.FlipbookMode = enumItem(Enum.ParticleFlipbookMode, fb.mode) or Enum.ParticleFlipbookMode.Loop
		local fps = fb.fps
		e.FlipbookFramerate = if fps then NumberRange.new(fps[1], fps[2] or fps[1]) else NumberRange.new(30)
		e.FlipbookStartRandom = fb.startRandom == true
	else
		e.FlipbookLayout = Enum.ParticleFlipbookLayout.None
	end
end

function VFXLibrary.newEmitter(name: string, opts: { scale: number?, color: Color3? }?): ParticleEmitter?
	local preset = VFX.Presets[name]
	if not preset then
		return nil
	end
	local e = Instance.new("ParticleEmitter")
	e.Name = "VFX_" .. name
	e.Enabled = false
	e.Rate = 0
	VFXLibrary.configure(e, preset, opts and opts.scale, opts and opts.color)
	return e
end

-------------------------------------------------------------------------------------------------------------------------
-- Burst pools
-------------------------------------------------------------------------------------------------------------------------

type Slot = { attachment: Attachment, emitter: ParticleEmitter, scale: number, color: Color3? }
type Pool = { name: string, preset: Preset, slots: { Slot }, size: number, cursor: number }

local pools: { [string]: Pool } = {}
local host: Part? = nil

-- Emission is injectable so the headless harness (no ParticleEmitter:Emit) can record calls.
local emitFn: (ParticleEmitter, number) -> () = function(e, n)
	e:Emit(n)
end

local function getHost(): Part
	local h = host
	if h and h.Parent then
		return h
	end
	local folder = Workspace:FindFirstChild("ClientVFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ClientVFX"
		folder.Parent = Workspace
	end
	local p = Instance.new("Part")
	p.Name = "VFXHost"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.identity
	p.Parent = folder
	host = p
	-- the old host's slots died with it
	table.clear(pools)
	return p
end

local function getPool(name: string): Pool?
	local pool = pools[name]
	if pool then
		return pool
	end
	local preset = VFX.Presets[name]
	if not preset or preset.kind ~= "burst" then
		return nil
	end
	pool = { name = name, preset = preset, slots = {}, size = math.max(1, preset.pool or DEFAULT_POOL), cursor = 0 }
	pools[name] = pool
	return pool
end

local function nextSlot(pool: Pool): Slot?
	pool.cursor = pool.cursor % pool.size + 1
	local slot = pool.slots[pool.cursor]
	if slot and slot.emitter.Parent and slot.attachment.Parent then
		return slot
	end
	local parent = getHost()
	local att = Instance.new("Attachment")
	att.Name = "VFX_" .. pool.name .. pool.cursor
	att.CFrame = HIDDEN -- host sits at the origin, so local = world
	local e = VFXLibrary.newEmitter(pool.name)
	if not e then
		att:Destroy()
		return nil
	end
	e.Parent = att
	att.Parent = parent
	slot = { attachment = att, emitter = e, scale = 1, color = nil }
	pool.slots[pool.cursor] = slot
	return slot
end

export type BurstOpts = {
	count: number?, -- overrides preset.count (still quality-scaled + budgeted)
	scale: number?, -- Size multiplier
	color: Color3?, -- constant color instead of the preset's sequence
	direction: Vector3?, -- EmissionDirection Top points along this
	force: boolean?, -- ignore the distance cull
}

-- Emit a pooled burst. Returns the number of particles actually emitted.
function VFXLibrary.burst(name: string, at: Vector3 | CFrame, opts: BurstOpts?): number
	local pool = getPool(name)
	if not pool then
		return 0
	end
	local o: BurstOpts = opts or {}
	local cf: CFrame
	if typeof(at) == "CFrame" then
		cf = at
	else
		cf = VFXLibrary.alignUp(at :: Vector3, o.direction)
	end
	if not o.force and not VFXLibrary.inRange(cf.Position) then
		return 0
	end
	local tier = VFXLibrary.tier()
	local wanted = VFXLibrary.scaledCount(o.count or pool.preset.count or 1, tier.count)
	local life = pool.preset.lifetime[2] or pool.preset.lifetime[1] or 1
	local n = budget:reserve(wanted, os.clock(), life)
	if n <= 0 then
		return 0
	end
	local slot = nextSlot(pool)
	if not slot then
		return 0
	end
	local e = slot.emitter
	local scale = o.scale or 1
	if scale ~= slot.scale then
		slot.scale = scale
		e.Size = VFXLibrary.numberSequence(pool.preset.size, scale)
	end
	if o.color ~= slot.color then
		slot.color = o.color
		if o.color then
			e.Color = ColorSequence.new(o.color)
		elseif pool.preset.color then
			e.Color = VFXLibrary.colorSequence(pool.preset.color)
		else
			e.Color = ColorSequence.new(Color3.new(1, 1, 1))
		end
	end
	slot.attachment.WorldCFrame = cf
	emitFn(e, n)
	return n
end

-------------------------------------------------------------------------------------------------------------------------
-- Streams
-------------------------------------------------------------------------------------------------------------------------

export type Stream = {
	name: string,
	preset: Preset,
	emitter: ParticleEmitter,
	active: boolean,
	intensity: number,
	rateScale: number,
	load: number,
	rate: number,
}

local activeStreams: { [Stream]: boolean } = {}

local function recomputeStreamLoad()
	local total = 0
	for s in activeStreams do
		total += s.load
	end
	budget.streamLoad = total
end

-- A continuous emitter parented to `parent` (an Attachment or BasePart owned by the caller; destroyed with it).
function VFXLibrary.stream(
	name: string,
	parent: Instance,
	opts: { scale: number?, color: Color3?, rateScale: number? }?
): Stream?
	local preset = VFX.Presets[name]
	if not preset or preset.kind ~= "stream" then
		return nil
	end
	local e = VFXLibrary.newEmitter(name, opts)
	if not e then
		return nil
	end
	e.Parent = parent
	return {
		name = name,
		preset = preset,
		emitter = e,
		active = false,
		intensity = 1,
		rateScale = (opts and opts.rateScale) or 1,
		load = 0,
		rate = 0,
	}
end

-- Rate for a stream at an intensity (0..1+), quality + budget scaled. Pure given the tier/cap/load.
function VFXLibrary.streamRate(
	baseRate: number,
	rateScale: number,
	intensity: number,
	tierRate: number,
	cap: number,
	load: number
): number
	return baseRate * rateScale * math.max(intensity, 0) * tierRate * VFXLibrary.streamScale(cap, load)
end

-- Turn a stream on/off; intensity scales its rate. Property writes only when something changed.
function VFXLibrary.setStream(s: Stream, on: boolean, intensity: number?)
	local e = s.emitter
	if not e.Parent then
		if activeStreams[s] then
			activeStreams[s] = nil
			recomputeStreamLoad()
		end
		return
	end
	local k = intensity or 1
	if on then
		local tier = VFXLibrary.tier()
		local others = budget.streamLoad - (if activeStreams[s] then s.load else 0)
		local rate = VFXLibrary.streamRate(s.preset.rate or 0, s.rateScale, k, tier.rate, budget.cap, others)
		if math.abs(rate - s.rate) > math.max(0.5, s.rate * 0.08) or not s.active then
			s.rate = rate
			e.Rate = rate
		end
		s.load = VFXLibrary.streamLoad(s.rate, s.preset.lifetime)
		activeStreams[s] = true
		recomputeStreamLoad()
		if not s.active then
			s.active = true
			e.Enabled = true
		end
		s.intensity = k
	elseif s.active then
		s.active = false
		e.Enabled = false
		activeStreams[s] = nil
		recomputeStreamLoad()
	end
end

-- Forget a stream (its emitter is destroyed with the caller's instance, or here when destroy=true).
function VFXLibrary.releaseStream(s: Stream?, destroy: boolean?)
	if not s then
		return
	end
	if activeStreams[s] then
		activeStreams[s] = nil
		recomputeStreamLoad()
	end
	s.active = false
	if destroy then
		s.emitter:Destroy()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Trails / beams / sprites
-------------------------------------------------------------------------------------------------------------------------

export type TrailRig = { trail: Trail, a0: Attachment, a1: Attachment }

-- A flat ground trail (e.g. a skid mark) between two attachments placed at `center` +- `right` * width/2 in the
-- parent part's space. Starts disabled.
function VFXLibrary.trail(name: string, parent: BasePart, center: Vector3, right: Vector3?): TrailRig?
	local p = VFX.Trails[name]
	if not p then
		return nil
	end
	local side = (right or Vector3.new(1, 0, 0)) * (p.width / 2)
	local a0 = Instance.new("Attachment")
	a0.Name = "VFX_" .. name .. "0"
	a0.Position = center - side
	local a1 = Instance.new("Attachment")
	a1.Name = "VFX_" .. name .. "1"
	a1.Position = center + side
	local t = Instance.new("Trail")
	t.Name = "VFX_" .. name
	t.Attachment0 = a0
	t.Attachment1 = a1
	t.Texture = VFXLibrary.texture(p.texture)
	t.TextureMode = enumItem(Enum.TextureMode, p.textureMode) or Enum.TextureMode.Wrap
	t.TextureLength = p.textureLength
	t.Lifetime = p.lifetime * VFXLibrary.tier().trailLife
	t.MinLength = p.minLength
	t.Color = VFXLibrary.colorSequence(p.color)
	t.Transparency = VFXLibrary.numberSequence(p.transparency)
	if p.widthScale then
		t.WidthScale = VFXLibrary.numberSequence(p.widthScale)
	end
	t.LightEmission = p.lightEmission
	t.LightInfluence = p.lightInfluence
	t.FaceCamera = p.faceCamera
	t.Enabled = false
	a0.Parent = parent
	a1.Parent = parent
	t.Parent = parent
	return { trail = t, a0 = a0, a1 = a1 }
end

export type BeamRig = { beam: Beam, a0: Attachment, a1: Attachment }

-- A beam from `origin` along `dir` (parent space) for the preset length. Starts disabled.
function VFXLibrary.beam(name: string, parent: BasePart, origin: Vector3, dir: Vector3, color: Color3?): BeamRig?
	local p = VFX.Beams[name]
	if not p then
		return nil
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "VFX_" .. name .. "0"
	a0.Position = origin
	local a1 = Instance.new("Attachment")
	a1.Name = "VFX_" .. name .. "1"
	a1.Position = origin + dir.Unit * p.length
	local b = Instance.new("Beam")
	b.Name = "VFX_" .. name
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.Texture = VFXLibrary.texture(p.texture)
	b.TextureMode = enumItem(Enum.TextureMode, p.textureMode) or Enum.TextureMode.Stretch
	b.TextureLength = p.textureLength
	b.TextureSpeed = p.textureSpeed
	b.Width0 = p.width0
	b.Width1 = p.width1
	b.Color = if color then ColorSequence.new(color) else VFXLibrary.colorSequence(p.color)
	b.Transparency = VFXLibrary.numberSequence(p.transparency)
	b.LightEmission = p.lightEmission
	b.LightInfluence = p.lightInfluence
	b.Brightness = p.brightness
	b.FaceCamera = p.faceCamera
	b.Segments = p.segments
	b.Enabled = false
	a0.Parent = parent
	a1.Parent = parent
	b.Parent = parent
	return { beam = b, a0 = a0, a1 = a1 }
end

-- A camera-facing glare sprite (BillboardGui + ImageLabel) on `adornee`. Starts disabled.
function VFXLibrary.sprite(name: string, adornee: BasePart, color: Color3): (BillboardGui?, ImageLabel?)
	local p = VFX.Sprites[name]
	if not p then
		return nil, nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "VFX_" .. name
	gui.Adornee = adornee
	gui.Size = UDim2.fromScale(p.size, p.size)
	gui.LightInfluence = p.lightInfluence
	gui.MaxDistance = p.maxDistance
	gui.AlwaysOnTop = false
	gui.ResetOnSpawn = false
	gui.Enabled = false
	local img = Instance.new("ImageLabel")
	img.Name = "Glare"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = VFXLibrary.texture(p.texture)
	img.ImageColor3 = color
	img.Parent = gui
	local localPlayer = Players.LocalPlayer
	local pg = localPlayer and localPlayer:FindFirstChild("PlayerGui")
	gui.Parent = pg or adornee
	return gui, img
end

-------------------------------------------------------------------------------------------------------------------------
-- Test hooks (harness only)
-------------------------------------------------------------------------------------------------------------------------

function VFXLibrary._setEmitter(fn: ((ParticleEmitter, number) -> ())?)
	emitFn = fn or function(e, n)
		e:Emit(n)
	end
end

function VFXLibrary._setCamera(pos: Vector3?)
	cameraOverride = pos
end

function VFXLibrary._reset()
	for _, pool in pools do
		for _, slot in pool.slots do
			slot.attachment:Destroy()
		end
	end
	table.clear(pools)
	table.clear(activeStreams)
	table.clear(budget.entries)
	budget.streamLoad = 0
	tierReadAt = -math.huge
end

function VFXLibrary._poolInfo(name: string): (number, number)
	local pool = pools[name]
	if not pool then
		return 0, 0
	end
	local built = 0
	for _ in pool.slots do
		built += 1
	end
	return built, pool.size
end

return VFXLibrary
