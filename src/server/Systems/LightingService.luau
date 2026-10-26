--!strict
-- LightingService: bold cartoon look + day/night cycle (SPEC §6).
--
-- * Lighting: Future technology (also set in default.project.json), Atmosphere, default Sky (no custom ids),
--   Bloom, vibrant ColorCorrection, SunRays, Terrain Clouds.
-- * Cycle: 12 real minutes of day (ClockTime 06:00 -> 18:00) then 4 minutes of night (18:00 -> 06:00). ClockTime is
--   advanced smoothly on the server (10 Hz); ambient/atmosphere/tint/bloom are blended from keyframes (2 Hz).
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
LightingService.START_HOUR = 14 -- new servers start in the afternoon
LightingService.CLOCK_INTERVAL = 0.1
LightingService.ENV_INTERVAL = 0.5
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
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Look keyframes (sorted by hour). Night stays readable: a bright navy "cartoon night", not pitch black.
local KEYS: { Key } = {
	{
		hour = 0,
		ambient = rgb(70, 76, 130),
		outdoor = rgb(78, 88, 150),
		brightness = 1.4,
		tint = rgb(196, 206, 255),
		atmoColor = rgb(60, 70, 130),
		atmoDecay = rgb(40, 40, 90),
		bloom = 1.1,
		exposure = 0.35,
	},
	{
		hour = 5.6,
		ambient = rgb(80, 82, 130),
		outdoor = rgb(110, 104, 150),
		brightness = 1.6,
		tint = rgb(220, 210, 245),
		atmoColor = rgb(120, 110, 170),
		atmoDecay = rgb(90, 70, 110),
		bloom = 0.95,
		exposure = 0.25,
	},
	{
		hour = 6.6,
		ambient = rgb(110, 96, 110),
		outdoor = rgb(170, 140, 140),
		brightness = 2.4,
		tint = rgb(255, 222, 200),
		atmoColor = rgb(255, 196, 170),
		atmoDecay = rgb(170, 110, 110),
		bloom = 0.7,
		exposure = 0.1,
	},
	{
		hour = 9,
		ambient = rgb(104, 104, 118),
		outdoor = rgb(150, 152, 166),
		brightness = 3,
		tint = rgb(255, 252, 246),
		atmoColor = rgb(200, 224, 255),
		atmoDecay = rgb(110, 134, 170),
		bloom = 0.45,
		exposure = 0,
	},
	{
		hour = 15.5,
		ambient = rgb(108, 104, 114),
		outdoor = rgb(156, 150, 158),
		brightness = 3,
		tint = rgb(255, 248, 238),
		atmoColor = rgb(214, 220, 250),
		atmoDecay = rgb(120, 130, 168),
		bloom = 0.5,
		exposure = 0,
	},
	{
		hour = 17.6,
		ambient = rgb(120, 92, 100),
		outdoor = rgb(184, 130, 120),
		brightness = 2.4,
		tint = rgb(255, 206, 170),
		atmoColor = rgb(255, 170, 130),
		atmoDecay = rgb(160, 90, 96),
		bloom = 0.75,
		exposure = 0.1,
	},
	{
		hour = 18.8,
		ambient = rgb(84, 76, 130),
		outdoor = rgb(110, 90, 150),
		brightness = 1.6,
		tint = rgb(220, 200, 250),
		atmoColor = rgb(110, 80, 150),
		atmoDecay = rgb(70, 50, 110),
		bloom = 1.0,
		exposure = 0.3,
	},
	{
		hour = 24,
		ambient = rgb(70, 76, 130),
		outdoor = rgb(78, 88, 150),
		brightness = 1.4,
		tint = rgb(196, 206, 255),
		atmoColor = rgb(60, 70, 130),
		atmoDecay = rgb(40, 40, 90),
		bloom = 1.1,
		exposure = 0.35,
	},
}
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
	}
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
	Lighting.Ambient = look.ambient
	Lighting.OutdoorAmbient = look.outdoor
	Lighting.Brightness = look.brightness
	Lighting.ExposureCompensation = look.exposure
	if color then
		color.TintColor = look.tint
	end
	if atmosphere then
		atmosphere.Color = look.atmoColor
		atmosphere.Decay = look.atmoDecay
	end
	if bloom then
		bloom.Intensity = look.bloom
	end
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
