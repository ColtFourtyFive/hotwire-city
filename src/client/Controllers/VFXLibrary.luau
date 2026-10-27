--!strict
-- VFXLibrary: the premium effects toolkit every client controller shares (not a boot controller: no init/start).
--
--  * Builds ParticleEmitters / Trails / Beams / glare sprites from Config/VFX presets (our uploaded textures, with
--    built-in fallbacks when an id is missing).
--  * burst(name, at, opts): pooled one-shot emission. Each preset owns a few emitters (VFX preset .pool) on one
--    anchored host part; an emitter is moved to the burst point and Emit()s. Instances are created once per slot,
--    never per burst / per frame. Particles live in world space, so one slot serves many bursts. Size / Color writes
--    also change particles still in the air, so a burst uses a slot already showing its look (scale + color), else an
--    idle slot (all its particles dead), else grows the pool (2x, VFX.POOL_HARD_CAP), else is skipped: live particles
--    are never re-looked.
--  * attach(name, parent) + emit(attached, count): a burst preset on a caller's attachment (the exhaust backfire):
--    moves with the car, quality-scaled + budgeted like a pooled burst.
--  * stream(name, parent, opts) + setStream(stream, on, intensity): continuous emitters on a caller's attachment
--    (tire smoke, nitro, dust). Rates are written only when they change.
--  * Budget: every burst reserves its particles against a live-particle cap (quality tier); active streams count
--    their steady-state load (rate x lifetime x preset cost) and may use VFX.STREAM_SHARE of the cap. rebalance()
--    re-rates every active stream (on each stream change + every VFX.REBALANCE_INTERVAL): priority streams (the local
--    car's) are served first, the rest share what is left (never below VFX.MIN_STREAM_SCALE).
--  * Quality tier: "high" | "medium" | "low" from UserGameSettings.SavedQualityLevel (1-3 low, 4-7 medium, 8-10 high;
--    Automatic = medium on phones, high elsewhere), re-read every VFX.QUALITY_REFRESH s; setQualityOverride() wins.
--    A tier change re-applies stream sizes (tierSize presets) and trail lifetimes on the next rebalance.
--  * Distance: library calls farther than VFX.MAX_DISTANCE (250) from the camera are skipped (opts.force overrides;
--    EffectsController forces, it culls whole effects itself).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VFX = require(Shared:WaitForChild("Config"):WaitForChild("VFX"))

type Preset = VFX.Preset

local VFXLibrary = {}
VFXLibrary.Config = VFX

local HIDDEN = CFrame.new(0, -10000, 0)
local DEFAULT_POOL = 3
local SAME_FRAME = 1 / 240 -- s: a slot that emitted this recently is treated as used this frame
local TRAIL_HEIGHT_EPS = 0.01 -- studs: smaller skid-height changes skip the Attachment write

-- Injectable clock (tests drive time explicitly).
local clock: () -> number = os.clock

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

-- Rate multipliers (priority, other) for streams whose combined load nears the cap (they may use STREAM_SHARE of it):
-- priority streams (the local car) are served first, the others share what is left.
function VFXLibrary.streamShares(cap: number, priorityLoad: number, otherLoad: number): (number, number)
	local share = cap * VFX.STREAM_SHARE
	local floor = VFX.MIN_STREAM_SCALE
	local p = if priorityLoad > share and priorityLoad > 0 then math.max(floor, share / priorityLoad) else 1
	local left = math.max(0, share - priorityLoad * p)
	local o = if otherLoad <= left or otherLoad <= 0 then 1 else math.max(floor, left / otherLoad)
	return p, o
end

-- Rate multiplier for non-priority streams when their combined load nears the cap.
function VFXLibrary.streamScale(cap: number, load: number): number
	local _, o = VFXLibrary.streamShares(cap, 0, load)
	return o
end

-- Burst Size multiplier snapped to 0.05 steps, so near-equal scales share a pooled slot's look.
function VFXLibrary.quantizeScale(scale: number): number
	return math.max(0.05, math.floor(scale * 20 + 0.5) / 20)
end

export type SlotLook = { scale: number, color: Color3?, busyUntil: number, emittedAt: number }

-- Which pooled slot a burst with this look (scale, color) may use without changing particles still in the air:
--  1. a slot already showing this look that did not emit this frame (nothing to rewrite),
--  2. an idle slot (all its particles have died): it is re-looked,
--  3. a new slot (#slots + 1) while the pool is under maxSlots,
--  4. a slot showing this look that emitted this frame (two bursts, one emitter, same frame),
--  else nil: every slot is busy showing another look -> skip the burst.
function VFXLibrary.pickSlot(slots: { SlotLook }, scale: number, color: Color3?, now: number, maxSlots: number): number?
	local idle: number? = nil
	local sameFrame: number? = nil
	for i, slot in slots do
		if slot.scale == scale and slot.color == color then
			if now - slot.emittedAt > SAME_FRAME then
				return i
			end
			sameFrame = sameFrame or i
		elseif idle == nil and slot.busyUntil <= now then
			idle = i
		end
	end
	if idle then
		return idle
	end
	if #slots < maxSlots then
		return #slots + 1
	end
	return sameFrame
end

-- Burst slots a preset may grow to while busy (2x its pool, at most VFX.POOL_HARD_CAP).
function VFXLibrary.maxSlots(pool: number): number
	return math.max(pool, math.min(VFX.POOL_HARD_CAP, pool * 2))
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

-- Gear tracking with hysteresis: up as soon as a shift point is crossed, down only `hysteresis` below it.
-- Returns (gear, upshifted).
function VFXLibrary.nextGear(current: number, frac: number, shifts: { number }?, hysteresis: number?): (number, boolean)
	local list = shifts or VFX.GEAR_SHIFTS
	local target = VFXLibrary.gearOf(frac, list)
	if target > current then
		return target, true
	end
	local h = hysteresis or 0.04
	local g = current
	while g > target and frac < (list[g] or 0) - h do
		g -= 1
	end
	return g, false
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
local tierEpoch = 0 -- bumped whenever the tier changes (rebalance re-applies sizes / trail lifetimes)
local budget = VFXLibrary.newBudget(VFX.Quality.high.maxParticles)
VFXLibrary.budget = budget

local function isPhone(): boolean
	local ok, phone = pcall(function()
		return UserInputService.TouchEnabled
			and not UserInputService.KeyboardEnabled
			and not UserInputService.MouseEnabled
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
	local now = clock()
	if now - tierReadAt >= VFX.QUALITY_REFRESH then
		tierReadAt = now
		local tier = qualityOverride or VFXLibrary.qualityTier(readSavedQuality(), isPhone())
		if tier ~= cachedTier then
			cachedTier = tier
			tierEpoch += 1
		end
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
	e.VelocityInheritance = preset.velocityInheritance or 0
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

-- A slot = one emitter on its own attachment (rigs[i]) + what it currently shows (looks[i], see pickSlot).
type SlotRig = { attachment: Attachment, emitter: ParticleEmitter }
type Pool = { name: string, preset: Preset, looks: { SlotLook }, rigs: { SlotRig }, size: number, max: number }

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
	if host then
		-- the old host's slots died with it (pool records stay valid: callers may hold one)
		for _, pool in pools do
			table.clear(pool.looks)
			table.clear(pool.rigs)
		end
	end
	host = p
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
	local size = math.max(1, preset.pool or DEFAULT_POOL)
	pool = { name = name, preset = preset, looks = {}, rigs = {}, size = size, max = VFXLibrary.maxSlots(size) }
	pools[name] = pool
	return pool
end

-- The slot at `index` (built when new, rebuilt when its instances died: then it shows the preset's own look).
local function slotAt(pool: Pool, index: number): (SlotRig?, SlotLook?)
	local rig = pool.rigs[index]
	if rig and rig.emitter.Parent and rig.attachment.Parent then
		return rig, pool.looks[index]
	end
	local parent = getHost() -- (a rebuilt host clears every pool's slots)
	if index > #pool.rigs + 1 then
		index = #pool.rigs + 1
	end
	local att = Instance.new("Attachment")
	att.Name = "VFX_" .. pool.name .. index
	att.CFrame = HIDDEN -- host sits at the origin, so local = world
	local e = VFXLibrary.newEmitter(pool.name)
	if not e then
		att:Destroy()
		return nil, nil
	end
	e.Parent = att
	att.Parent = parent
	local fresh: SlotRig = { attachment = att, emitter = e }
	local look: SlotLook = { scale = 1, color = nil, busyUntil = -math.huge, emittedAt = -math.huge }
	pool.rigs[index] = fresh
	pool.looks[index] = look
	return fresh, look
end

local function applyLook(e: ParticleEmitter, preset: Preset, slot: SlotLook, scale: number, color: Color3?)
	if scale ~= slot.scale then
		slot.scale = scale
		e.Size = VFXLibrary.numberSequence(preset.size, scale)
	end
	if color ~= slot.color then
		slot.color = color
		if color then
			e.Color = ColorSequence.new(color)
		elseif preset.color then
			e.Color = VFXLibrary.colorSequence(preset.color)
		else
			e.Color = ColorSequence.new(Color3.new(1, 1, 1))
		end
	end
end

export type BurstOpts = {
	count: number?, -- overrides preset.count (still quality-scaled + budgeted)
	scale: number?, -- Size multiplier (snapped to 0.05 steps)
	color: Color3?, -- constant color instead of the preset's sequence
	direction: Vector3?, -- EmissionDirection Top points along this
	force: boolean?, -- ignore the distance cull
}

-- Emit a pooled burst. Returns the number of particles actually emitted (0: culled, over budget, or every slot busy
-- showing another look).
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
	local preset = pool.preset
	local tier = VFXLibrary.tier()
	local now = clock()
	local scale = VFXLibrary.quantizeScale(o.scale or 1)
	local index = VFXLibrary.pickSlot(pool.looks, scale, o.color, now, pool.max)
	if not index then
		return 0
	end
	local wanted = VFXLibrary.scaledCount(o.count or preset.count or 1, tier.count)
	local life = preset.lifetime[2] or preset.lifetime[1] or 1
	local n = budget:reserve(wanted, now, life)
	if n <= 0 then
		return 0
	end
	local rig, look = slotAt(pool, index)
	if not rig or not look then
		return 0
	end
	local e = rig.emitter
	applyLook(e, preset, look, scale, o.color)
	look.busyUntil = math.max(look.busyUntil, now + life)
	look.emittedAt = now
	rig.attachment.WorldCFrame = cf
	emitFn(e, n)
	return n
end

-------------------------------------------------------------------------------------------------------------------------
-- Attached bursts (an emitter that rides a caller's attachment, e.g. the exhaust backfire)
-------------------------------------------------------------------------------------------------------------------------

export type Attached = { name: string, preset: Preset, emitter: ParticleEmitter }

-- A burst preset's emitter on `parent` (an Attachment / BasePart owned by the caller; destroyed with it).
function VFXLibrary.attach(name: string, parent: Instance, opts: { scale: number?, color: Color3? }?): Attached?
	local preset = VFX.Presets[name]
	if not preset or preset.kind ~= "burst" then
		return nil
	end
	local e = VFXLibrary.newEmitter(name, opts)
	if not e then
		return nil
	end
	e.Parent = parent
	return { name = name, preset = preset, emitter = e }
end

local function worldPosition(inst: Instance?): Vector3?
	if not inst then
		return nil
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	elseif inst:IsA("BasePart") then
		return inst.Position
	end
	return nil
end

-- Emit an attached burst (count defaults to the preset's): quality-scaled, budgeted, distance-culled unless force.
function VFXLibrary.emit(a: Attached?, count: number?, force: boolean?): number
	if not a then
		return 0
	end
	local e = a.emitter
	local parent = e.Parent
	if not parent then
		return 0
	end
	if not force then
		local pos = worldPosition(parent)
		if pos and not VFXLibrary.inRange(pos) then
			return 0
		end
	end
	local tier = VFXLibrary.tier()
	local wanted = VFXLibrary.scaledCount(count or a.preset.count or 1, tier.count)
	local life = a.preset.lifetime[2] or a.preset.lifetime[1] or 1
	local n = budget:reserve(wanted, clock(), life)
	if n > 0 then
		emitFn(e, n)
	end
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
	priority: boolean, -- the local player's own effects: served first when the budget is tight
	scale: number, -- caller's Size multiplier (x the tier's sizeScale for tierSize presets)
	sizeEpoch: number, -- tierEpoch the Size was last written for
	load: number,
	rate: number,
}

local activeStreams: { [Stream]: boolean } = {}
-- every live stream / trail rig (weak: callers own them), for tier changes
local allStreams: { [Stream]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local allTrails: { [TrailRig]: VFX.TrailPreset } = setmetatable({}, { __mode = "k" }) :: any
local appliedEpoch = 0
local rebalanceAt = -math.huge

-- Size multiplier of a stream on a tier (tierSize presets shrink on medium / low).
function VFXLibrary.streamSize(preset: Preset, scale: number?, tier: VFX.QualityTier): number
	return (scale or 1) * (if preset.tierSize then tier.sizeScale else 1)
end

-- Steady-state budget weight of a stream emitting `rate`/s: particles alive x the preset's cost.
local function weightedLoad(preset: Preset, rate: number): number
	return VFXLibrary.streamLoad(rate, preset.lifetime) * (preset.cost or 1)
end

-- Re-rate every active stream from the current tier and load (priority streams first), write the rates that moved,
-- and after a tier change re-apply stream sizes and trail lifetimes. Cheap: a few dozen streams at most.
function VFXLibrary.rebalance()
	local tier = VFXLibrary.tier()
	rebalanceAt = clock()
	if appliedEpoch ~= tierEpoch then
		appliedEpoch = tierEpoch
		for s in allStreams do
			if s.emitter.Parent and s.preset.tierSize and s.sizeEpoch ~= tierEpoch then
				s.sizeEpoch = tierEpoch
				s.emitter.Size =
					VFXLibrary.numberSequence(s.preset.size, VFXLibrary.streamSize(s.preset, s.scale, tier))
			end
		end
		for rig, p in allTrails do
			if rig.trail.Parent then
				rig.trail.Lifetime = p.lifetime * tier.trailLife
			end
		end
	end
	local priorityLoad, otherLoad = 0, 0
	for s in activeStreams do
		if not s.emitter.Parent then
			activeStreams[s] = nil
			s.active = false
			continue
		end
		local want = VFXLibrary.streamRate(s.preset.rate or 0, s.rateScale, s.intensity, tier.rate, math.huge, 0)
		if s.priority then
			priorityLoad += weightedLoad(s.preset, want)
		else
			otherLoad += weightedLoad(s.preset, want)
		end
	end
	local pScale, oScale = VFXLibrary.streamShares(budget.cap, priorityLoad, otherLoad)
	local total = 0
	for s in activeStreams do
		local want = VFXLibrary.streamRate(s.preset.rate or 0, s.rateScale, s.intensity, tier.rate, math.huge, 0)
		local rate = want * (if s.priority then pScale else oScale)
		if (s.rate <= 0 and rate > 0) or math.abs(rate - s.rate) > math.max(0.5, s.rate * 0.08) then
			s.rate = rate
			s.emitter.Rate = rate
		end
		s.load = weightedLoad(s.preset, s.rate)
		total += s.load
	end
	budget.streamLoad = total
end

-- One Heartbeat (made on the first stream): re-rates active streams every VFX.REBALANCE_INTERVAL, so a load or tier
-- change also reaches streams that are already running.
local ticker: RBXScriptConnection? = nil
local function ensureTicker()
	if ticker then
		return
	end
	local ok, conn = pcall(function()
		return RunService.Heartbeat:Connect(function()
			if
				clock() - rebalanceAt >= VFX.REBALANCE_INTERVAL
				and (next(activeStreams) ~= nil or appliedEpoch ~= tierEpoch)
			then
				VFXLibrary.rebalance()
			end
		end)
	end)
	if ok then
		ticker = conn
	end
end

-- A continuous emitter parented to `parent` (an Attachment or BasePart owned by the caller; destroyed with it).
-- priority: the local player's own effects (served first when the budget is tight).
function VFXLibrary.stream(
	name: string,
	parent: Instance,
	opts: { scale: number?, color: Color3?, rateScale: number?, priority: boolean? }?
): Stream?
	local preset = VFX.Presets[name]
	if not preset or preset.kind ~= "stream" then
		return nil
	end
	local scale = (opts and opts.scale) or 1
	local tier = VFXLibrary.tier()
	local e =
		VFXLibrary.newEmitter(name, { scale = VFXLibrary.streamSize(preset, scale, tier), color = opts and opts.color })
	if not e then
		return nil
	end
	e.Parent = parent
	local s: Stream = {
		name = name,
		preset = preset,
		emitter = e,
		active = false,
		intensity = 1,
		rateScale = (opts and opts.rateScale) or 1,
		priority = opts ~= nil and opts.priority == true,
		scale = scale,
		sizeEpoch = tierEpoch,
		load = 0,
		rate = 0,
	}
	allStreams[s] = true
	ensureTicker()
	return s
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

-- Turn a stream on/off; intensity scales its rate. A call that changes nothing is free (safe every frame); a change
-- re-rates every active stream (rebalance). Property writes only when something changed.
function VFXLibrary.setStream(s: Stream, on: boolean, intensity: number?)
	local e = s.emitter
	if not e.Parent then
		if activeStreams[s] then
			activeStreams[s] = nil
			s.active = false
			VFXLibrary.rebalance()
		end
		return
	end
	local k = intensity or 1
	if on then
		if s.active and math.abs(k - s.intensity) < 1e-6 then
			return
		end
		s.intensity = k
		local starting = not s.active
		s.active = true
		activeStreams[s] = true
		VFXLibrary.rebalance()
		if starting then
			e.Enabled = true
		end
	elseif s.active then
		s.active = false
		e.Enabled = false
		activeStreams[s] = nil
		s.load = 0
		VFXLibrary.rebalance()
	end
end

-- Forget a stream (its emitter is destroyed with the caller's instance, or here when destroy=true).
function VFXLibrary.releaseStream(s: Stream?, destroy: boolean?)
	if not s then
		return
	end
	allStreams[s] = nil
	if activeStreams[s] then
		activeStreams[s] = nil
		VFXLibrary.rebalance()
	end
	s.active = false
	if destroy then
		s.emitter:Destroy()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Trails / beams / sprites
-------------------------------------------------------------------------------------------------------------------------

export type TrailRig = { trail: Trail, a0: Attachment, a1: Attachment, y: number }

-- A flat ground trail (e.g. a skid mark) between two attachments placed at `center` +- `right` * width/2 in the
-- parent part's space. Starts disabled. Its Lifetime follows the quality tier (re-applied on tier changes).
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
	local rig: TrailRig = { trail = t, a0 = a0, a1 = a1, y = center.Y }
	allTrails[rig] = p
	return rig
end

-- Move a trail's attachments to height `y` (parent space; X/Z kept), e.g. a skid mark following the tyre's contact
-- patch as the suspension moves. Writes only when it moved more than TRAIL_HEIGHT_EPS.
function VFXLibrary.setTrailHeight(rig: TrailRig, y: number)
	if math.abs(y - rig.y) <= TRAIL_HEIGHT_EPS then
		return
	end
	rig.y = y
	local p0, p1 = rig.a0.Position, rig.a1.Position
	rig.a0.Position = Vector3.new(p0.X, y, p0.Z)
	rig.a1.Position = Vector3.new(p1.X, y, p1.Z)
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

-- A camera-facing glare sprite (BillboardGui + ImageLabel) on `adornee`, pulled preset.towardCamera studs toward the
-- viewer (StudsOffset Z: camera space) so the body it sits on does not cut it in half. Starts disabled.
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
	gui.StudsOffset = Vector3.new(0, 0, p.towardCamera or 0)
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

-- Replace the clock (seconds) every pool / budget / tier decision reads; nil restores os.clock.
function VFXLibrary._setClock(fn: (() -> number)?)
	clock = fn or os.clock
	tierReadAt = -math.huge
end

function VFXLibrary._reset()
	for _, pool in pools do
		for _, rig in pool.rigs do
			rig.attachment:Destroy()
		end
	end
	table.clear(pools)
	table.clear(activeStreams)
	table.clear(allStreams)
	table.clear(allTrails)
	table.clear(budget.entries)
	budget.streamLoad = 0
	tierReadAt = -math.huge
	rebalanceAt = -math.huge
end

-- (slots built, pool size, max slots) of a burst preset's pool.
function VFXLibrary._poolInfo(name: string): (number, number, number)
	local pool = pools[name]
	if not pool then
		return 0, 0, 0
	end
	return #pool.rigs, pool.size, pool.max
end

return VFXLibrary
