--!strict
-- VFX: the premium effects library's data. Texture ids (our own renders, tools/vfx/*) + emitter / trail / beam
-- presets that client/Controllers/VFXLibrary turns into pooled ParticleEmitters, Trails and Beams.
--
-- Textures are mostly white / greyscale with straight alpha, so ParticleEmitter.Color (or Trail/Beam.Color) tints
-- them; the impact star keeps its dark comic outline, the coin is gold, the bill is green. Flipbooks are square,
-- row-major. Regenerate: tools/vfx/gen_textures.py + render_blender.py -> upload.py -> gen_luau.py.
--
-- Preset fields (all optional unless noted). Sizes are studs, speeds studs/s, times seconds, angles degrees:
--   texture (required)  key into VFX.Textures
--   kind (required)     "burst" (pooled, Emit(count) at a position) | "stream" (an emitter on an attachment, Rate)
--   count / rate        particles per burst / per second at "high" quality (Quality tiers scale them down)
--   lifetime, speed, rotation, rotSpeed, spread      { min, max } (spread = { x, y })
--   size, transparency, squash                      NumberSequence keys: K(time, value, envelope?)
--   color                                           ColorSequence keys: C(time, r, g, b)
--   flipbook            { layout = "Grid2x2" | "Grid4x4" | "Grid8x8", mode = "Loop" | "OneShot" | "PingPong" |
--                         "Random", fps = { min, max }?, startRandom = boolean? }
--   orientation         Enum.ParticleOrientation name;  emissionDirection: Enum.NormalId name
--   pool                burst slots in the ring (one emitter each; concurrent bursts with different colors need
--                       different slots because Color/Size changes apply to live particles too)

export type NumKey = { t: number, v: number, e: number? }
export type ColorKey = { t: number, c: Color3 }
export type Flipbook = { layout: string, mode: string, fps: { number }?, startRandom: boolean? }
export type Preset = {
	texture: string,
	kind: string,
	count: number?,
	rate: number?,
	lifetime: { number },
	speed: { number }?,
	spread: { number }?,
	rotation: { number }?,
	rotSpeed: { number }?,
	size: { NumKey },
	transparency: { NumKey },
	squash: { NumKey }?,
	color: { ColorKey }?,
	lightEmission: number?,
	lightInfluence: number?,
	brightness: number?,
	acceleration: Vector3?,
	drag: number?,
	orientation: string?,
	emissionDirection: string?,
	zOffset: number?,
	lockedToPart: boolean?,
	timeScale: number?,
	flipbook: Flipbook?,
	pool: number?,
}
export type TrailPreset = {
	texture: string,
	lifetime: number,
	minLength: number,
	textureLength: number,
	textureMode: string,
	color: { ColorKey },
	transparency: { NumKey },
	widthScale: { NumKey }?,
	lightEmission: number,
	lightInfluence: number,
	faceCamera: boolean,
	width: number, -- studs between the two attachments (one tire width)
}
export type BeamPreset = {
	texture: string,
	textureMode: string,
	textureLength: number,
	textureSpeed: number,
	width0: number,
	width1: number,
	length: number, -- studs from Attachment0 to Attachment1
	color: { ColorKey },
	transparency: { NumKey },
	lightEmission: number,
	lightInfluence: number,
	brightness: number,
	faceCamera: boolean,
	segments: number,
}
export type SpritePreset = { texture: string, size: number, lightInfluence: number, maxDistance: number }
export type QualityTier = { rate: number, count: number, maxParticles: number, trailLife: number, extras: boolean }

local function K(t: number, v: number, e: number?): NumKey
	return { t = t, v = v, e = e }
end

local function C(t: number, r: number, g: number, b: number): ColorKey
	return { t = t, c = Color3.fromRGB(r, g, b) }
end

local VFX = {}
VFX.K = K
VFX.C = C

-- BEGIN GENERATED TEXTURES (tools/vfx/gen_luau.py from assets/vfx/manifest.json; do not edit by hand)
VFX.Textures = {
	backfire_burst = "rbxassetid://76984985572572",
	cash_bill = "rbxassetid://139544741852293",
	cash_flutter = "rbxassetid://104344730175189",
	coin_spin = "rbxassetid://105312686304563",
	confetti = "rbxassetid://81647794662805",
	debris_chips = "rbxassetid://92326460960108",
	dust_puff = "rbxassetid://82416394494633",
	fire_flipbook = "rbxassetid://128967429912577",
	glare = "rbxassetid://83452262865374",
	glow_dot = "rbxassetid://129685408276433",
	headlight_beam = "rbxassetid://81577505740546",
	impact_star = "rbxassetid://92452831173719",
	nitro_jet = "rbxassetid://103514078561994",
	shockwave_ring = "rbxassetid://96750041428796",
	skid_mark = "rbxassetid://80732619274146",
	smoke_flipbook = "rbxassetid://77373203636884",
	smoke_puff_a = "rbxassetid://111617455268587",
	smoke_puff_b = "rbxassetid://126794732952388",
	smoke_puff_c = "rbxassetid://137296444788818",
	spark_streak = "rbxassetid://97303621128187",
	sparkle_star = "rbxassetid://86530372677621",
	speed_line = "rbxassetid://120619575858093",
	tire_smoke = "rbxassetid://93725101722578",
	underglow = "rbxassetid://124996636404412",
	water_splash = "rbxassetid://103314128852444",
} :: { [string]: string }
-- END GENERATED TEXTURES

-- Built-in engine textures used when a key has no uploaded id (offline place, moderation pending in a test place).
VFX.Fallback = {
	smoke_puff_a = "rbxasset://textures/particles/smoke_main.dds",
	smoke_puff_b = "rbxasset://textures/particles/smoke_main.dds",
	smoke_puff_c = "rbxasset://textures/particles/smoke_main.dds",
	smoke_flipbook = "rbxasset://textures/particles/smoke_main.dds",
	tire_smoke = "rbxasset://textures/particles/smoke_main.dds",
	dust_puff = "rbxasset://textures/particles/smoke_main.dds",
	fire_flipbook = "rbxasset://textures/particles/fire_main.dds",
	backfire_burst = "rbxasset://textures/particles/fire_main.dds",
	nitro_jet = "rbxasset://textures/particles/fire_main.dds",
	spark_streak = "rbxasset://textures/particles/sparkles_main.dds",
	speed_line = "rbxasset://textures/particles/sparkles_main.dds",
	glow_dot = "rbxasset://textures/particles/sparkles_main.dds",
	sparkle_star = "rbxasset://textures/sparkle.png",
	glare = "rbxasset://textures/particles/sparkles_main.dds",
	shockwave_ring = "rbxasset://textures/particles/sparkles_main.dds",
	impact_star = "rbxasset://textures/sparkle.png",
	debris_chips = "rbxasset://textures/particles/sparkles_main.dds",
	water_splash = "rbxasset://textures/particles/smoke_main.dds",
	cash_bill = "rbxasset://textures/particles/sparkles_main.dds",
	cash_flutter = "rbxasset://textures/particles/sparkles_main.dds",
	coin_spin = "rbxasset://textures/particles/sparkles_main.dds",
	confetti = "rbxasset://textures/particles/sparkles_main.dds",
	skid_mark = "",
	headlight_beam = "",
	underglow = "",
} :: { [string]: string }

-- Flipbook layout of each flipbook texture (presets must match; asserted in tests).
VFX.FlipbookLayouts = {
	smoke_flipbook = "Grid4x4",
	tire_smoke = "Grid4x4",
	fire_flipbook = "Grid4x4",
	backfire_burst = "Grid2x2",
	debris_chips = "Grid4x4",
	water_splash = "Grid2x2",
	cash_flutter = "Grid4x4",
	coin_spin = "Grid4x4",
	confetti = "Grid4x4",
} :: { [string]: string }

-------------------------------------------------------------------------------------------------------------------------
-- Budget / quality
-------------------------------------------------------------------------------------------------------------------------
VFX.MAX_DISTANCE = 250 -- studs from the camera: farther effects are not emitted at all
VFX.QUALITY_REFRESH = 5 -- seconds between re-reads of the player's graphics quality setting
VFX.Quality = {
	high = { rate = 1, count = 1, maxParticles = 1600, trailLife = 1, extras = true },
	medium = { rate = 0.65, count = 0.7, maxParticles = 900, trailLife = 0.75, extras = true },
	low = { rate = 0.4, count = 0.45, maxParticles = 500, trailLife = 0.5, extras = false },
} :: { [string]: QualityTier }

-- Speed fractions (of top speed) where the arcade "gearbox" upshifts: crossing one upward under throttle pops the
-- exhaust (backfire). Purely cosmetic.
VFX.GEAR_SHIFTS = { 0.22, 0.42, 0.62, 0.82 }

-- Off-road dust colors by surface material name (raycast hit .Material.Name; terrain + part materials).
VFX.SurfaceDust = {
	Grass = Color3.fromRGB(150, 128, 92),
	LeafyGrass = Color3.fromRGB(140, 122, 88),
	Ground = Color3.fromRGB(150, 120, 86),
	Mud = Color3.fromRGB(110, 86, 60),
	Sand = Color3.fromRGB(226, 202, 150),
	Sandstone = Color3.fromRGB(205, 170, 120),
	Snow = Color3.fromRGB(240, 244, 250),
	Salt = Color3.fromRGB(235, 232, 225),
	Limestone = Color3.fromRGB(205, 196, 176),
} :: { [string]: Color3 }

VFX.CONFETTI_COLORS = {
	Color3.fromRGB(255, 52, 140),
	Color3.fromRGB(0, 214, 255),
	Color3.fromRGB(255, 205, 50),
	Color3.fromRGB(70, 235, 110),
	Color3.fromRGB(175, 80, 255),
	Color3.fromRGB(255, 120, 40),
}

-------------------------------------------------------------------------------------------------------------------------
-- Particle presets
-------------------------------------------------------------------------------------------------------------------------
local FIRE_COLOR = { C(0, 255, 255, 235), C(0.2, 255, 214, 90), C(0.55, 255, 120, 30), C(1, 200, 40, 20) }
local NITRO_COLOR = { C(0, 255, 255, 255), C(0.15, 140, 235, 255), C(0.5, 0, 170, 255), C(1, 130, 50, 255) }

VFX.Presets = {
	-------------------------------------------------------------------------------------------------- wreck / impacts
	WreckSmoke = {
		texture = "smoke_flipbook",
		kind = "burst",
		count = 16,
		pool = 2,
		lifetime = { 1.7, 2.6 },
		speed = { 7, 17 },
		spread = { 180, 180 },
		rotation = { 0, 360 },
		rotSpeed = { -35, 35 },
		size = { K(0, 5, 1), K(0.25, 10, 2), K(1, 16, 3) },
		transparency = { K(0, 0.05), K(0.55, 0.2), K(1, 1) },
		color = { C(0, 255, 176, 96), C(0.12, 96, 96, 104), C(1, 150, 150, 158) },
		lightEmission = 0,
		lightInfluence = 0.6,
		acceleration = Vector3.new(0, 7, 0),
		drag = 2.4,
		flipbook = { layout = "Grid4x4", mode = "OneShot" },
	},
	Fireball = {
		texture = "backfire_burst",
		kind = "burst",
		count = 7,
		pool = 2,
		lifetime = { 0.5, 0.8 },
		speed = { 5, 13 },
		spread = { 180, 180 },
		rotation = { 0, 360 },
		rotSpeed = { -90, 90 },
		size = { K(0, 6, 1), K(0.3, 12, 2), K(1, 14, 2) },
		transparency = { K(0, 0), K(0.6, 0.15), K(1, 1) },
		color = FIRE_COLOR,
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 2,
		drag = 3,
		zOffset = 1,
		flipbook = { layout = "Grid2x2", mode = "OneShot" },
	},
	Debris = {
		texture = "debris_chips",
		kind = "burst",
		count = 12,
		pool = 3,
		lifetime = { 1.1, 1.7 },
		speed = { 32, 58 },
		spread = { 65, 65 },
		emissionDirection = "Top",
		rotation = { 0, 360 },
		rotSpeed = { -260, 260 },
		size = { K(0, 1.2, 0.45), K(1, 1.1, 0.4) },
		transparency = { K(0, 0), K(0.85, 0), K(1, 1) },
		color = { C(0, 110, 114, 126), C(1, 110, 114, 126) },
		lightEmission = 0,
		lightInfluence = 1,
		acceleration = Vector3.new(0, -115, 0),
		drag = 0.5,
		flipbook = { layout = "Grid4x4", mode = "Loop", fps = { 14, 26 }, startRandom = true },
	},
	Sparks = {
		texture = "spark_streak",
		kind = "burst",
		count = 26,
		pool = 4,
		lifetime = { 0.28, 0.6 },
		speed = { 36, 72 },
		spread = { 70, 70 },
		emissionDirection = "Top",
		size = { K(0, 0.85, 0.25), K(1, 0.15) },
		squash = { K(0, 1.6), K(1, 1.1) },
		transparency = { K(0, 0), K(0.7, 0.1), K(1, 1) },
		color = { C(0, 255, 255, 240), C(0.35, 255, 214, 110), C(1, 255, 110, 40) },
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 3,
		acceleration = Vector3.new(0, -85, 0),
		drag = 2.5,
		orientation = "VelocityParallel",
	},
	Shockwave = {
		texture = "shockwave_ring",
		kind = "burst",
		count = 1,
		pool = 3,
		lifetime = { 0.42, 0.42 },
		speed = { 0.05, 0.05 },
		spread = { 0, 0 },
		emissionDirection = "Top",
		size = { K(0, 2), K(0.4, 18), K(1, 26) },
		transparency = { K(0, 0.05), K(0.5, 0.35), K(1, 1) },
		color = { C(0, 255, 236, 170), C(1, 255, 200, 110) },
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 1.5,
		orientation = "VelocityPerpendicular",
	},
	ImpactStar = {
		texture = "impact_star",
		kind = "burst",
		count = 1,
		pool = 3,
		lifetime = { 0.42, 0.42 },
		speed = { 0, 0 },
		rotation = { -25, 25 },
		rotSpeed = { -50, 50 },
		size = { K(0, 1.5), K(0.14, 8), K(0.3, 6.6), K(0.75, 7), K(1, 2.5) },
		transparency = { K(0, 0), K(0.75, 0), K(1, 1) },
		color = { C(0, 255, 214, 64), C(1, 255, 214, 64) },
		lightEmission = 0,
		lightInfluence = 0,
		zOffset = 3,
	},
	Flash = {
		texture = "glow_dot",
		kind = "burst",
		count = 1,
		pool = 4,
		lifetime = { 0.2, 0.2 },
		speed = { 0, 0 },
		size = { K(0, 7), K(1, 13) },
		transparency = { K(0, 0), K(1, 1) },
		color = { C(0, 255, 200, 120), C(1, 255, 150, 60) },
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 4,
		zOffset = 2,
	},
	Sparkle = {
		texture = "sparkle_star",
		kind = "burst",
		count = 22,
		pool = 4,
		lifetime = { 0.5, 0.95 },
		speed = { 10, 28 },
		spread = { 180, 180 },
		rotation = { -20, 20 },
		size = { K(0, 1.6, 0.4), K(0.5, 1.2, 0.3), K(1, 0) },
		transparency = { K(0, 0), K(1, 0.3) },
		color = { C(0, 255, 230, 140), C(1, 255, 205, 50) },
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 2,
		drag = 3,
	},
	------------------------------------------------------------------------------------------------- rewards
	Confetti = {
		texture = "confetti",
		kind = "burst",
		count = 12, -- per color (x CONFETTI_COLORS)
		pool = 8,
		lifetime = { 2.2, 3.2 },
		speed = { 34, 62 },
		spread = { 38, 38 },
		emissionDirection = "Top",
		rotation = { 0, 360 },
		rotSpeed = { -220, 220 },
		size = { K(0, 1.5, 0.3), K(1, 1.5, 0.3) },
		transparency = { K(0, 0), K(0.82, 0), K(1, 1) },
		color = { C(0, 255, 255, 255), C(1, 255, 255, 255) },
		lightEmission = 0.12,
		lightInfluence = 0.35,
		acceleration = Vector3.new(0, -36, 0),
		drag = 1.7,
		flipbook = { layout = "Grid4x4", mode = "Loop", fps = { 16, 30 }, startRandom = true },
	},
	CashFlutter = {
		texture = "cash_flutter",
		kind = "burst",
		count = 16,
		pool = 2,
		lifetime = { 1.9, 2.7 },
		speed = { 26, 46 },
		spread = { 34, 34 },
		emissionDirection = "Top",
		rotation = { 0, 360 },
		rotSpeed = { -60, 60 },
		size = { K(0, 4.4, 0.6), K(1, 4.4, 0.6) },
		transparency = { K(0, 0), K(0.8, 0), K(1, 1) },
		lightEmission = 0.05,
		lightInfluence = 0.4,
		acceleration = Vector3.new(0, -26, 0),
		drag = 1.8,
		flipbook = { layout = "Grid4x4", mode = "Loop", fps = { 12, 24 }, startRandom = true },
	},
	Coins = {
		texture = "coin_spin",
		kind = "burst",
		count = 12,
		pool = 2,
		lifetime = { 1.2, 1.8 },
		speed = { 30, 52 },
		spread = { 28, 28 },
		emissionDirection = "Top",
		size = { K(0, 1.8, 0.25), K(1, 1.8, 0.25) },
		transparency = { K(0, 0), K(0.85, 0), K(1, 1) },
		lightEmission = 0.15,
		lightInfluence = 0.25,
		acceleration = Vector3.new(0, -95, 0),
		drag = 0.7,
		flipbook = { layout = "Grid4x4", mode = "Loop", fps = { 20, 30 }, startRandom = true },
	},
	------------------------------------------------------------------------------------------------- ground / car
	DustPuff = {
		texture = "dust_puff",
		kind = "burst",
		count = 8,
		pool = 3,
		lifetime = { 0.7, 1.15 },
		speed = { 6, 13 },
		spread = { 80, 80 },
		emissionDirection = "Top",
		rotation = { 0, 360 },
		rotSpeed = { -30, 30 },
		size = { K(0, 2, 0.5), K(1, 6.5, 1) },
		transparency = { K(0, 0.2), K(1, 1) },
		color = { C(0, 205, 182, 140), C(1, 190, 170, 132) },
		lightEmission = 0,
		lightInfluence = 1,
		acceleration = Vector3.new(0, 2, 0),
		drag = 3,
	},
	Backfire = {
		texture = "backfire_burst",
		kind = "burst",
		count = 2,
		pool = 3,
		lifetime = { 0.16, 0.24 },
		speed = { 6, 11 },
		spread = { 12, 12 },
		emissionDirection = "Top", -- bursts aim Top along BurstOpts.direction (the exhaust's rearward axis)
		rotation = { 0, 360 },
		size = { K(0, 1.3), K(1, 2.8) },
		transparency = { K(0, 0), K(1, 0.6) },
		color = FIRE_COLOR,
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 3,
		zOffset = 0.5,
		flipbook = { layout = "Grid2x2", mode = "OneShot" },
	},
	WaterSplash = {
		texture = "water_splash",
		kind = "burst",
		count = 2,
		pool = 3,
		lifetime = { 0.55, 0.75 },
		speed = { 1, 3 },
		spread = { 20, 20 },
		emissionDirection = "Top",
		size = { K(0, 5, 1), K(1, 7, 1) },
		transparency = { K(0, 0), K(0.7, 0.1), K(1, 1) },
		color = { C(0, 235, 248, 255), C(1, 200, 232, 255) },
		lightEmission = 0.15,
		lightInfluence = 0.7,
		flipbook = { layout = "Grid2x2", mode = "OneShot" },
	},
	------------------------------------------------------------------------------------------------- streams
	TireSmoke = {
		texture = "tire_smoke",
		kind = "stream",
		rate = 34,
		lifetime = { 1.1, 1.8 },
		speed = { 3, 8 },
		spread = { 30, 30 },
		emissionDirection = "Back",
		rotation = { 0, 360 },
		rotSpeed = { -40, 40 },
		size = { K(0, 1.6, 0.4), K(0.3, 5.5, 1), K(1, 11, 2) },
		transparency = { K(0, 0.4), K(0.2, 0.25), K(1, 1) },
		color = { C(0, 240, 240, 246), C(1, 214, 214, 224) },
		lightEmission = 0.04,
		lightInfluence = 0.75,
		acceleration = Vector3.new(0, 5, 0),
		drag = 1.8,
		flipbook = { layout = "Grid4x4", mode = "OneShot" },
	},
	NitroFlame = {
		texture = "fire_flipbook",
		kind = "stream",
		rate = 100,
		lifetime = { 0.1, 0.2 },
		speed = { 26, 36 },
		spread = { 8, 8 },
		emissionDirection = "Back",
		rotation = { -15, 15 },
		size = { K(0, 2.6, 0.3), K(1, 0.8) },
		squash = { K(0, 0.6), K(1, 0.3) },
		transparency = { K(0, 0), K(0.65, 0.25), K(1, 1) },
		color = NITRO_COLOR,
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 2,
		zOffset = 1,
		orientation = "VelocityParallel", -- flame tips point away from the tailpipe
		flipbook = { layout = "Grid4x4", mode = "Loop", fps = { 24, 30 }, startRandom = true },
	},
	NitroCore = {
		texture = "glow_dot",
		kind = "stream",
		rate = 28,
		lifetime = { 0.08, 0.12 },
		speed = { 0, 0 },
		size = { K(0, 3.2, 0.4), K(1, 2.4) },
		transparency = { K(0, 0.05), K(1, 0.6) },
		color = { C(0, 200, 250, 255), C(1, 120, 160, 255) },
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 3,
		zOffset = 1.5,
		lockedToPart = true,
	},
	Dust = {
		texture = "dust_puff",
		kind = "stream",
		rate = 30,
		lifetime = { 0.9, 1.4 },
		speed = { 4, 9 },
		spread = { 40, 40 },
		emissionDirection = "Back",
		rotation = { 0, 360 },
		rotSpeed = { -25, 25 },
		size = { K(0, 1.5, 0.4), K(1, 7.5, 1.5) },
		transparency = { K(0, 0.4), K(1, 1) },
		color = { C(0, 190, 165, 125), C(1, 190, 165, 125) },
		lightEmission = 0,
		lightInfluence = 1,
		acceleration = Vector3.new(0, 3, 0),
		drag = 2,
	},
	WaterSpray = {
		texture = "water_splash",
		kind = "stream",
		rate = 16,
		lifetime = { 0.45, 0.65 },
		speed = { 7, 13 },
		spread = { 30, 30 },
		emissionDirection = "Top",
		size = { K(0, 3, 0.6), K(1, 5, 1) },
		transparency = { K(0, 0.1), K(1, 1) },
		color = { C(0, 235, 248, 255), C(1, 205, 235, 255) },
		lightEmission = 0.1,
		lightInfluence = 0.7,
		acceleration = Vector3.new(0, -30, 0),
		flipbook = { layout = "Grid2x2", mode = "OneShot" },
	},
	SpeedLines = {
		texture = "speed_line",
		kind = "stream",
		rate = 6, -- per ring attachment (8 of them)
		lifetime = { 0.22, 0.32 },
		speed = { 120, 160 },
		spread = { 0, 0 },
		emissionDirection = "Back",
		size = { K(0, 0.35), K(1, 0.35) },
		squash = { K(0, 3), K(1, 3) },
		transparency = { K(0, 1), K(0.2, 0.45), K(0.8, 0.45), K(1, 1) },
		color = { C(0, 230, 245, 255), C(1, 230, 245, 255) },
		lightEmission = 1,
		lightInfluence = 0,
		orientation = "VelocityParallel",
		lockedToPart = true,
	},
} :: { [string]: Preset }

-------------------------------------------------------------------------------------------------------------------------
-- Trails / beams / sprites
-------------------------------------------------------------------------------------------------------------------------
VFX.Trails = {
	SkidMark = {
		texture = "skid_mark",
		lifetime = 4.5,
		minLength = 1.2,
		textureLength = 4,
		textureMode = "Wrap",
		color = { C(0, 22, 22, 24), C(1, 22, 22, 24) },
		transparency = { K(0, 0.3), K(0.7, 0.45), K(1, 1) },
		lightEmission = 0,
		lightInfluence = 1,
		faceCamera = false,
		width = 1.1,
	},
} :: { [string]: TrailPreset }

VFX.Beams = {
	NitroJet = {
		texture = "nitro_jet",
		textureMode = "Stretch",
		textureLength = 1,
		textureSpeed = 0,
		width0 = 2,
		width1 = 0.6,
		length = 4.5,
		color = { C(0, 255, 255, 255), C(0.3, 0, 214, 255), C(1, 175, 80, 255) },
		transparency = { K(0, 0), K(1, 0.15) },
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 3,
		faceCamera = true,
		segments = 1,
	},
	HeadlightCone = {
		texture = "headlight_beam",
		textureMode = "Stretch",
		textureLength = 1,
		textureSpeed = 0,
		width0 = 1.2,
		width1 = 9,
		length = 26,
		color = { C(0, 255, 246, 220), C(1, 255, 236, 200) },
		transparency = { K(0, 0.55), K(1, 1) },
		lightEmission = 1,
		lightInfluence = 0,
		brightness = 1.2,
		faceCamera = true,
		segments = 1,
	},
} :: { [string]: BeamPreset }

VFX.Sprites = {
	SirenGlare = { texture = "glare", size = 7, lightInfluence = 0, maxDistance = 300 },
} :: { [string]: SpritePreset }

return VFX
