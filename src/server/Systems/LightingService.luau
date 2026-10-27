--!strict
-- LightingService: bold cartoon look + day/night cycle (SPEC §6).
--
-- * Lighting: Future technology (also set in default.project.json), Atmosphere, default Sky (no custom ids),
--   Bloom, vibrant ColorCorrection, SunRays, Terrain Clouds.
-- * Cycle: 12 real minutes of day (ClockTime 06:00 -> 18:00) then 4 minutes of night (18:00 -> 06:00). ClockTime is
--   advanced on the server at 1 Hz (steps of ~0.017 h by day: invisible, but every replicated ClockTime change makes
--   each client re-evaluate sun + shadows); the look is blended from keyframes every 2 s (smoothstep per segment).
-- * Look (art pass): warm golden-hour afternoons (new servers start at golden hour), a moody neon night (thicker
--   violet Atmosphere haze, stronger + wider bloom with a lower threshold so neon signs glow, saturated, punchier
--   ColorCorrection) and pink/blue dusk + dawn. Env writes are cheap: a property is only written when it moved past a
--   small per-property step since its last write (plateaus cost nothing; ~16 properties at most per 2 s).
-- * Night (ClockTime >= NIGHT_ON or < NIGHT_OFF): street lights (tag "StreetLight") turn their PointLights on, and
--   every part tagged "NightGlow" swaps to its NightColor/NightMaterial attributes (windows light up, lamp heads go
--   Neon). Swaps are spread over a few frames. Lighting attribute "IsNight" mirrors the state for clients
--   (e.g. headlights), and NightChanged(isNight) fires for server systems.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local LightingService = {}

LightingService.DAY_SECONDS = 12 * 60
LightingService.NIGHT_SECONDS = 4 * 60
LightingService.CYCLE_SECONDS = LightingService.DAY_SECONDS + LightingService.NIGHT_SECONDS
LightingService.SUNRISE = 6 -- ClockTime where the day segment starts
LightingService.SUNSET = 18 -- ClockTime where the night segment starts
LightingService.NIGHT_ON = 17.75 -- lights on (dusk) ...
LightingService.NIGHT_OFF = 6.25 -- ... lights off (dawn)
LightingService.START_HOUR = 16.2 -- new servers start at golden hour
LightingService.CLOCK_INTERVAL = 1
LightingService.ENV_INTERVAL = 2
LightingService.GLOW_BATCH = 150 -- NightGlow parts swapped per frame

LightingService.TAG_STREET_LIGHT = "StreetLight"
LightingService.TAG_NIGHT_GLOW = "NightGlow"

LightingService.NightChanged = Signal.new() -- (isNight: boolean)

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------------------------------------------

-- ClockTime (0..24) at `t` seconds into the cycle (t = 0 is sunrise).
function LightingService.hourAt(t: number): number
	local cycle = LightingService.CYCLE_SECONDS
	local tt = t % cycle
	local day = LightingService.DAY_SECONDS
	if tt < day then
		return LightingService.SUNRISE + (LightingService.SUNSET - LightingService.SUNRISE) * (tt / day)
	end
	local nightLen = 24 - (LightingService.SUNSET - LightingService.SUNRISE)
	return (LightingService.SUNSET + nightLen * ((tt - day) / LightingService.NIGHT_SECONDS)) % 24
end

-- Cycle time (seconds) at which the clock shows `hour`.
function LightingService.timeForHour(hour: number): number
	local h = hour % 24
	local dayLen = LightingService.SUNSET - LightingService.SUNRISE
	if h >= LightingService.SUNRISE and h < LightingService.SUNSET then
		return (h - LightingService.SUNRISE) / dayLen * LightingService.DAY_SECONDS
	end
	local into = (h - LightingService.SUNSET) % 24
	return LightingService.DAY_SECONDS + into / (24 - dayLen) * LightingService.NIGHT_SECONDS
end

function LightingService.isNightHour(hour: number): boolean
	local h = hour % 24
	return h >= LightingService.NIGHT_ON or h < LightingService.NIGHT_OFF
end

type Key = {
	hour: number,
	ambient: Color3,
	outdoor: Color3,
	brightness: number,
	tint: Color3,
	atmoColor: Color3,
	atmoDecay: Color3,
	bloom: number,
	exposure: number,
	density: number, -- Atmosphere
	haze: number,
	glare: number,
	saturation: number, -- ColorCorrection
	contrast: number,
	bloomSize: number,
	bloomThreshold: number,
	rays: number, -- SunRays intensity
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- The neon night (also the 24 h key): readable navy, not pitch black, with violet haze and glowing signs.
local NIGHT: Key = {
	hour = 0,
	ambient = rgb(66, 70, 132),
	outdoor = rgb(74, 82, 152),
	brightness = 1.35,
	tint = rgb(196, 200, 255),
	atmoColor = rgb(78, 62, 150),
	atmoDecay = rgb(130, 46, 150),
	bloom = 1.45,
	exposure = 0.35,
	density = 0.38,
	haze = 2.5,
	glare = 0,
	saturation = 0.36,
	contrast = 0.16,
	bloomSize = 32,
	bloomThreshold = 1.15,
	rays = 0,
}

-- Look keyframes (sorted by hour; first and last are the same night look so midnight wraps cleanly).
local KEYS: { Key } = {
	NIGHT,
	{ -- pre-dawn
		hour = 5.6,
		ambient = rgb(80, 82, 132),
		outdoor = rgb(110, 104, 152),
		brightness = 1.6,
		tint = rgb(222, 210, 248),
		atmoColor = rgb(122, 108, 172),
		atmoDecay = rgb(104, 70, 120),
		bloom = 1.1,
		exposure = 0.25,
		density = 0.35,
		haze = 2.1,
		glare = 0.1,
		saturation = 0.3,
		contrast = 0.12,
		bloomSize = 30,
		bloomThreshold = 1.3,
		rays = 0.03,
	},
	{ -- sunrise glow
		hour = 6.6,
		ambient = rgb(116, 98, 106),
		outdoor = rgb(180, 142, 134),
		brightness = 2.4,
		tint = rgb(255, 220, 192),
		atmoColor = rgb(255, 192, 160),
		atmoDecay = rgb(180, 110, 104),
		bloom = 0.75,
		exposure = 0.1,
		density = 0.31,
		haze = 1.8,
		glare = 0.55,
		saturation = 0.28,
		contrast = 0.1,
		bloomSize = 28,
		bloomThreshold = 1.5,
		rays = 0.1,
	},
	{ -- bright cartoon day
		hour = 9,
		ambient = rgb(104, 104, 118),
		outdoor = rgb(150, 152, 166),
		brightness = 3,
		tint = rgb(255, 250, 240),
		atmoColor = rgb(200, 224, 255),
		atmoDecay = rgb(110, 134, 170),
		bloom = 0.45,
		exposure = 0,
		density = 0.26,
		haze = 1.1,
		glare = 0.25,
		saturation = 0.24,
		contrast = 0.08,
		bloomSize = 24,
		bloomThreshold = 1.7,
		rays = 0.05,
	},
	{ -- afternoon warming up
		hour = 14.2,
		ambient = rgb(110, 104, 112),
		outdoor = rgb(162, 152, 150),
		brightness = 3,
		tint = rgb(255, 242, 222),
		atmoColor = rgb(232, 218, 236),
		atmoDecay = rgb(146, 128, 156),
		bloom = 0.5,
		exposure = 0,
		density = 0.27,
		haze = 1.3,
		glare = 0.35,
		saturation = 0.26,
		contrast = 0.09,
		bloomSize = 24,
		bloomThreshold = 1.65,
		rays = 0.07,
	},
	{ -- golden hour
		hour = 16.4,
		ambient = rgb(130, 102, 96),
		outdoor = rgb(204, 148, 116),
		brightness = 2.8,
		tint = rgb(255, 214, 168),
		atmoColor = rgb(255, 186, 128),
		atmoDecay = rgb(196, 106, 88),
		bloom = 0.7,
		exposure = 0.05,
		density = 0.3,
		haze = 1.9,
		glare = 0.8,
		saturation = 0.3,
		contrast = 0.12,
		bloomSize = 28,
		bloomThreshold = 1.5,
		rays = 0.14,
	},
	{ -- sunset
		hour = 17.6,
		ambient = rgb(126, 88, 104),
		outdoor = rgb(192, 122, 120),
		brightness = 2.3,
		tint = rgb(255, 192, 170),
		atmoColor = rgb(255, 150, 132),
		atmoDecay = rgb(172, 80, 112),
		bloom = 0.9,
		exposure = 0.12,
		density = 0.32,
		haze = 2.1,
		glare = 0.6,
		saturation = 0.32,
		contrast = 0.13,
		bloomSize = 30,
		bloomThreshold = 1.4,
		rays = 0.12,
	},
	{ -- blue hour: neon switching on
		hour = 18.8,
		ambient = rgb(84, 72, 138),
		outdoor = rgb(106, 86, 158),
		brightness = 1.6,
		tint = rgb(214, 196, 255),
		atmoColor = rgb(112, 76, 162),
		atmoDecay = rgb(154, 60, 150),
		bloom = 1.25,
		exposure = 0.3,
		density = 0.36,
		haze = 2.3,
		glare = 0.1,
		saturation = 0.34,
		contrast = 0.15,
		bloomSize = 31,
		bloomThreshold = 1.2,
		rays = 0.02,
	},
	table.clone(NIGHT),
}
KEYS[#KEYS].hour = 24
LightingService.KEYS = KEYS

-- Interpolated look for an hour (0..24).
function LightingService.lookAt(hour: number): Key
	local h = hour % 24
	local a, b = KEYS[1], KEYS[#KEYS]
	for i = 1, #KEYS - 1 do
		if h >= KEYS[i].hour and h <= KEYS[i + 1].hour then
			a, b = KEYS[i], KEYS[i + 1]
			break
		end
	end
	local span = b.hour - a.hour
	local t = if span > 0 then (h - a.hour) / span else 0
	-- smoothstep so transitions ease in/out
	t = t * t * (3 - 2 * t)
	return {
		hour = h,
		ambient = a.ambient:Lerp(b.ambient, t),
		outdoor = a.outdoor:Lerp(b.outdoor, t),
		brightness = a.brightness + (b.brightness - a.brightness) * t,
		tint = a.tint:Lerp(b.tint, t),
		atmoColor = a.atmoColor:Lerp(b.atmoColor, t),
		atmoDecay = a.atmoDecay:Lerp(b.atmoDecay, t),
		bloom = a.bloom + (b.bloom - a.bloom) * t,
		exposure = a.exposure + (b.exposure - a.exposure) * t,
		density = a.density + (b.density - a.density) * t,
		haze = a.haze + (b.haze - a.haze) * t,
		glare = a.glare + (b.glare - a.glare) * t,
		saturation = a.saturation + (b.saturation - a.saturation) * t,
		contrast = a.contrast + (b.contrast - a.contrast) * t,
		bloomSize = a.bloomSize + (b.bloomSize - a.bloomSize) * t,
		bloomThreshold = a.bloomThreshold + (b.bloomThreshold - a.bloomThreshold) * t,
		rays = a.rays + (b.rays - a.rays) * t,
	}
end

-- Write-skip test: has `value` moved far enough from the last written `last` (nil = never written)? Colors compare
-- per channel. Pure, unit-tested.
function LightingService._changed(last: any, value: any, eps: number): boolean
	if last == nil or typeof(last) ~= typeof(value) then
		return true
	end
	if typeof(value) == "Color3" then
		return math.max(math.abs(last.R - value.R), math.abs(last.G - value.G), math.abs(last.B - value.B)) >= eps
	end
	if typeof(value) == "number" then
		return math.abs(last - value) >= eps
	end
	return last ~= value
end

---------------------------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------------------------

local cycleStart = os.clock() - LightingService.timeForHour(LightingService.START_HOUR)
local night = LightingService.isNightHour(LightingService.START_HOUR)
local glowVersion = 0

local atmosphere: Atmosphere? = nil
local bloom: BloomEffect? = nil
local color: ColorCorrectionEffect? = nil
local sunRays: SunRaysEffect? = nil

local COLOR_EPS = 1.5 / 255
local written: { [string]: any } = {} -- last value written per "Object.Property" (see LightingService._changed)

local function write(inst: Instance?, key: string, prop: string, value: any, eps: number)
	if not inst or not LightingService._changed(written[key], value, eps) then
		return
	end
	written[key] = value
	local target: any = inst
	target[prop] = value
end

local function getOrCreate(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function currentHour(): number
	return LightingService.hourAt(os.clock() - cycleStart)
end

local function applyLook(hour: number)
	local look = LightingService.lookAt(hour)
	write(Lighting, "L.Ambient", "Ambient", look.ambient, COLOR_EPS)
	write(Lighting, "L.OutdoorAmbient", "OutdoorAmbient", look.outdoor, COLOR_EPS)
	write(Lighting, "L.Brightness", "Brightness", look.brightness, 0.02)
	write(Lighting, "L.Exposure", "ExposureCompensation", look.exposure, 0.01)
	write(color, "C.Tint", "TintColor", look.tint, COLOR_EPS)
	write(color, "C.Saturation", "Saturation", look.saturation, 0.005)
	write(color, "C.Contrast", "Contrast", look.contrast, 0.005)
	write(atmosphere, "A.Color", "Color", look.atmoColor, COLOR_EPS)
	write(atmosphere, "A.Decay", "Decay", look.atmoDecay, COLOR_EPS)
	write(atmosphere, "A.Density", "Density", look.density, 0.004)
	write(atmosphere, "A.Haze", "Haze", look.haze, 0.03)
	write(atmosphere, "A.Glare", "Glare", look.glare, 0.02)
	write(bloom, "B.Intensity", "Intensity", look.bloom, 0.01)
	write(bloom, "B.Size", "Size", look.bloomSize, 0.5)
	write(bloom, "B.Threshold", "Threshold", look.bloomThreshold, 0.01)
	write(sunRays, "R.Intensity", "Intensity", look.rays, 0.004)
end

local function materialFrom(name: any, fallback: Enum.Material): Enum.Material
	if typeof(name) ~= "string" then
		return fallback
	end
	local ok, mat = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and typeof(mat) == "EnumItem" then
		return mat
	end
	return fallback
end

-- Applies the day/night look to one tagged part (NightGlow) or lamp (StreetLight).
local function applyGlow(inst: Instance, isNight: boolean)
	if not inst:IsA("BasePart") or not inst.Parent then
		return
	end
	local colorAttr = inst:GetAttribute(if isNight then "NightColor" else "DayColor")
	if typeof(colorAttr) == "Color3" then
		inst.Color = colorAttr
	end
	local matAttr = inst:GetAttribute(if isNight then "NightMaterial" else "DayMaterial")
	if matAttr ~= nil then
		inst.Material = materialFrom(matAttr, inst.Material)
	end
end

local function applyStreetLight(inst: Instance, isNight: boolean)
	if not inst.Parent then
		return
	end
	for _, child in inst:GetChildren() do
		if child:IsA("PointLight") or child:IsA("SpotLight") or child:IsA("SurfaceLight") then
			child.Enabled = isNight
		end
	end
end

-- Applies the night state to every tagged instance. With `spread`, NightGlow swaps are batched over frames.
local function applyNightState(isNight: boolean, spread: boolean)
	glowVersion += 1
	local version = glowVersion
	for _, inst in CollectionService:GetTagged(LightingService.TAG_STREET_LIGHT) do
		applyStreetLight(inst, isNight)
	end
	local glows = CollectionService:GetTagged(LightingService.TAG_NIGHT_GLOW)
	if not spread then
		for _, inst in glows do
			applyGlow(inst, isNight)
		end
		return
	end
	task.spawn(function()
		for i, inst in glows do
			if version ~= glowVersion then
				return -- a newer transition took over
			end
			applyGlow(inst, isNight)
			if i % LightingService.GLOW_BATCH == 0 then
				task.wait()
			end
		end
	end)
end

local function setNight(isNight: boolean, spread: boolean)
	night = isNight
	Lighting:SetAttribute("IsNight", isNight)
	applyNightState(isNight, spread)
	LightingService.NightChanged:Fire(isNight)
end

---------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------

function LightingService.isNight(): boolean
	return night
end

function LightingService.getClockTime(): number
	return currentHour()
end

-- Jump the cycle to an hour (admin/testing). Night state updates immediately.
function LightingService.setClockTime(hour: number)
	cycleStart = os.clock() - LightingService.timeForHour(hour)
	Lighting.ClockTime = currentHour()
	applyLook(Lighting.ClockTime)
	local isNight = LightingService.isNightHour(Lighting.ClockTime)
	if isNight ~= night then
		setNight(isNight, true)
	end
end

function LightingService.init()
	pcall(function()
		(Lighting :: any).Technology = Enum.Technology.Future
	end)
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.25
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1
	Lighting.GeographicLatitude = 23
	Lighting.FogEnd = 100000

	local sky = getOrCreate(Lighting, "Sky", "HotwireSky") :: Sky
	sky.CelestialBodiesShown = true
	sky.StarCount = 3000
	sky.SunAngularSize = 16
	sky.MoonAngularSize = 11

	local atmo = getOrCreate(Lighting, "Atmosphere", "HotwireAtmosphere") :: Atmosphere
	atmo.Density = 0.28
	atmo.Offset = 0.12
	atmo.Glare = 0.25
	atmo.Haze = 1.2
	atmosphere = atmo

	local bl = getOrCreate(Lighting, "BloomEffect", "HotwireBloom") :: BloomEffect
	bl.Intensity = 0.5
	bl.Size = 26
	bl.Threshold = 1.6
	bloom = bl

	local cc = getOrCreate(Lighting, "ColorCorrectionEffect", "HotwireColor") :: ColorCorrectionEffect
	cc.Saturation = 0.24
	cc.Contrast = 0.08
	cc.Brightness = 0.01
	color = cc

	local rays = getOrCreate(Lighting, "SunRaysEffect", "HotwireSunRays") :: SunRaysEffect
	rays.Intensity = 0.05
	rays.Spread = 0.55
	sunRays = rays
	table.clear(written) -- (re)created effects: the next applyLook writes everything

	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local ok = pcall(function()
			local clouds = getOrCreate(terrain, "Clouds", "HotwireClouds") :: Clouds
			clouds.Cover = 0.45
			clouds.Density = 0.65
			clouds.Color = rgb(255, 255, 255)
		end)
		if not ok then
			warn("[LightingService] could not create clouds")
		end
	end

	local hour = currentHour()
	Lighting.ClockTime = hour
	applyLook(hour)
	night = LightingService.isNightHour(hour)
	Lighting:SetAttribute("IsNight", night)
	applyNightState(night, false)

	-- late-tagged instances (e.g. garages built later) pick up the current state
	CollectionService:GetInstanceAddedSignal(LightingService.TAG_NIGHT_GLOW):Connect(function(inst: Instance)
		task.defer(function()
			applyGlow(inst, night)
		end)
	end)
	CollectionService:GetInstanceAddedSignal(LightingService.TAG_STREET_LIGHT):Connect(function(inst: Instance)
		task.defer(function()
			applyStreetLight(inst, night)
		end)
	end)
end

function LightingService.start()
	local envAcc = 0
	while true do
		local dt = task.wait(LightingService.CLOCK_INTERVAL)
		local hour = currentHour()
		Lighting.ClockTime = hour
		envAcc += dt
		if envAcc >= LightingService.ENV_INTERVAL then
			envAcc = 0
			applyLook(hour)
		end
		local isNight = LightingService.isNightHour(hour)
		if isNight ~= night then
			setNight(isNight, true)
		end
	end
end

return LightingService
