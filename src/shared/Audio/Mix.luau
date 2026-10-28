--!strict
-- Mix (PLAN C3 · audio): the mixer's rules, pure.
--
-- Channels (one SoundGroup each, flat under SoundService so UI/UISound's lookup keeps working):
--   master (virtual: multiplies everything), sfx (HC_SFX: guns, impacts, foley), vehicles (HC_Vehicles: engines,
--   sirens, horns, tyres), ambience (HC_Ambience: district beds, city one-shots), music (HC_Music: car radio), ui (HC_UI).
-- Settings: the snapshot toggles stay booleans (Types.Settings): "sfx" gates sfx / vehicles / ambience / ui,
-- "music" gates music. Per-channel volume sliders (pause menu SETTINGS) are 0..100 % in 10 % steps.
-- Ducks: named reasons with per-channel gains (big WASTED / BUSTED messages, the pause menu, nearby gunfire, a radio
-- retune); several active reasons multiply, each scaled by its own 0..1 fade.
-- Voices: a global cap on simultaneous one-shots with priorities (a low-priority sound is refused when the budget is
-- full; a higher one may steal the oldest lower one).
-- Reverb: the AmbientReverb preset for where the listener is (open, under cover, tunnel, garage).

local Mix = {}

Mix.CHANNELS = { "master", "sfx", "vehicles", "ambience", "music", "ui" }
Mix.GROUPS = {
	sfx = "HC_SFX",
	vehicles = "HC_Vehicles",
	ambience = "HC_Ambience",
	music = "HC_Music",
	ui = "HC_UI",
}
-- which settings toggle gates a channel
Mix.TOGGLE = { sfx = "sfx", vehicles = "sfx", ambience = "sfx", ui = "sfx", music = "music" }
-- base level of each group (headroom for the mix: music under the world, ambience under the cars)
Mix.BASE = { sfx = 1, vehicles = 0.9, ambience = 0.75, music = 0.85, ui = 0.9 }

Mix.STEPS = 11 -- 0 %, 10 %, ... 100 %
Mix.MAX_VOICES = 40

export type Volumes = { [string]: number }
export type Toggles = { sfx: boolean, music: boolean }

function Mix.defaultVolumes(): Volumes
	return { master = 1, sfx = 1, vehicles = 1, ambience = 1, music = 1, ui = 1 }
end

-- Slider step (1..STEPS) -> volume 0..1, and back.
function Mix.stepToVolume(step: number): number
	return math.clamp((math.floor(step + 0.5) - 1) / (Mix.STEPS - 1), 0, 1)
end

function Mix.volumeToStep(volume: number): number
	return math.clamp(math.floor(math.clamp(volume, 0, 1) * (Mix.STEPS - 1) + 0.5) + 1, 1, Mix.STEPS)
end

-- The option labels for a slider row ("0%" .. "100%").
function Mix.stepLabels(): { string }
	local out = {}
	for i = 1, Mix.STEPS do
		table.insert(out, ("%d%%"):format(math.floor(Mix.stepToVolume(i) * 100 + 0.5)))
	end
	return out
end

-- Which channel a Config/Sounds key plays on (SoundController.play). 2D sounds are interface sounds unless they belong
-- to the car radio; positional ones go by prefix: cars and police -> vehicles, Amb_ -> ambience, the rest -> sfx.
Mix.VEHICLE_PREFIXES = {
	"Eng_",
	"Engine",
	"Horn",
	"AirHorn",
	"Siren",
	"Tire",
	"PeelOut",
	"Pop_",
	"Turbo",
	"Car",
	"Door",
	"Hotwire",
	"Surface",
	"Scrape",
	"Wind",
	"Heli",
	"Dispatch",
	"PoliceRadio",
	"Ignition",
}

function Mix.channelFor(key: string, positional: boolean): string
	if string.sub(key, 1, 6) == "Radio_" or key == "RadioStatic" then
		return "music"
	end
	if string.sub(key, 1, 4) == "Amb_" or key == "CityAmbience" or key == "Traffic" then
		return "ambience"
	end
	if not positional then
		return "ui"
	end
	for _, prefix in Mix.VEHICLE_PREFIXES do
		if string.sub(key, 1, #prefix) == prefix then
			return "vehicles"
		end
	end
	return "sfx"
end

-- Ducks: reason -> per-channel gain at full depth.
Mix.DUCKS = {
	bigMessage = { music = 0.2, ambience = 0.3, vehicles = 0.45, sfx = 0.7 }, -- WASTED / BUSTED shard
	pause = { music = 0.35, ambience = 0.35, vehicles = 0.35, sfx = 0.5 }, -- pause menu open
	gunfire = { music = 0.5 }, -- gunfire within 80 studs: radio -6 dB (gta_combat §11.6)
	retune = { music = 0.6 }, -- the radio's static burst
	cutscene = { ambience = 0.5, vehicles = 0.5 },
}

-- Combined duck gain for a channel. active: reason -> fade 0..1 (missing / 0 = off).
function Mix.duckGain(active: { [string]: number }, channel: string): number
	local g = 1
	for reason, fade in active do
		local d = Mix.DUCKS[reason]
		local depth = if d then d[channel] else nil
		if depth and fade > 0 then
			g *= 1 - (1 - depth) * math.clamp(fade, 0, 1)
		end
	end
	return g
end

-- Final SoundGroup.Volume of a channel.
function Mix.groupVolume(channel: string, volumes: Volumes, toggles: Toggles, ducks: { [string]: number }): number
	local toggle = Mix.TOGGLE[channel]
	if toggle == "sfx" and not toggles.sfx then
		return 0
	end
	if toggle == "music" and not toggles.music then
		return 0
	end
	local master = volumes.master or 1
	local own = volumes[channel] or 1
	return (Mix.BASE[channel] or 1) * master * own * Mix.duckGain(ducks, channel)
end

-- Move a fade toward its target at `rate` per second.
function Mix.approach(current: number, target: number, rate: number, dt: number): number
	if current < target then
		return math.min(target, current + rate * dt)
	end
	return math.max(target, current - rate * dt)
end

-- Voice budget. priority: higher wins. Returns true when a new voice of `priority` may play given `active` voices
-- and the lowest priority currently playing (when full, it may steal only a strictly lower one).
Mix.PRIORITY = {
	ui = 6,
	localCar = 5,
	gunshot = 5,
	impact = 4,
	siren = 4,
	horn = 3,
	world = 3,
	remoteCar = 2,
	ambient = 1,
}

function Mix.admit(active: number, cap: number, priority: number, lowestActive: number?): (boolean, boolean)
	if active < cap then
		return true, false
	end
	if lowestActive ~= nil and priority > lowestActive then
		return true, true -- admit by stealing the oldest lowest-priority voice
	end
	return false, false
end

-- Reverb for the listener: hits = how many of the upward cover rays hit something (0..rays), plus flags.
function Mix.reverbFor(hits: number, rays: number, inTunnel: boolean, inGarage: boolean): string
	if inGarage then
		return "ParkingLot"
	end
	if inTunnel then
		return "Hallway"
	end
	local covered = if rays > 0 then hits / rays else 0
	if covered >= 0.99 then
		return "ParkingLot"
	elseif covered >= 0.5 then
		return "Alley"
	end
	return "NoReverb"
end

-- Impact layers for a crash of `impulse` (studs/s of sudden speed loss): light thud / heavy crunch / glass.
function Mix.impactLayers(impulse: number): (boolean, boolean, boolean, number)
	if impulse < 18 then
		return false, false, false, 0
	end
	local light = impulse < 55
	local heavy = impulse >= 40
	local glass = impulse >= 85
	local gain = math.clamp(0.35 + impulse / 120, 0.35, 1.25)
	return light, heavy, glass, gain
end

-- Tyre squeal level from lateral slip (studs/s sideways) and whether the tyres touch the ground.
function Mix.squealLevel(lateralSpeed: number, grounded: boolean, drifting: boolean): number
	if not grounded then
		return 0
	end
	local slip = math.abs(lateralSpeed)
	local threshold = if drifting then 4 else 9
	if slip < threshold then
		return 0
	end
	return math.clamp((slip - threshold) / 24, 0.15, 1.2)
end

-- Wind noise inside the car: silent below ~45 % of top speed, full at top speed.
function Mix.windLevel(speed: number, topSpeed: number): number
	local f = speed / math.max(topSpeed, 1)
	return math.clamp((f - 0.45) / 0.55, 0, 1.2)
end

-------------------------------------------------------------------------------------------------------------------------
-- Settings sliders (pause menu SETTINGS rows, added by MenuController from this list)
-------------------------------------------------------------------------------------------------------------------------

export type Slider = { channel: string, label: string, desc: string }

Mix.SLIDERS = {
	{ channel = "master", label = "Master volume", desc = "Everything you hear." },
	{ channel = "sfx", label = "Effects volume", desc = "Guns, impacts and footsteps." },
	{ channel = "vehicles", label = "Vehicle volume", desc = "Engines, tyres, horns and sirens." },
	{ channel = "ambience", label = "City volume", desc = "Traffic, the sea, the wind and the city at night." },
	{ channel = "music", label = "Radio volume", desc = "The car radio." },
	{ channel = "ui", label = "Interface volume", desc = "Menus, the phone and messages." },
} :: { Slider }

-- ListMenu option rows wrap around (100 % -> 0 % on one more Right press). A volume slider clamps at its ends instead:
-- the new index the list reports, corrected.
function Mix.sliderStep(prev: number, nextIndex: number, steps: number): number
	if steps <= 1 then
		return 1
	end
	if prev >= steps and nextIndex == 1 then
		return steps
	end
	if prev <= 1 and nextIndex == steps then
		return 1
	end
	return math.clamp(math.floor(nextIndex + 0.5), 1, steps)
end

-------------------------------------------------------------------------------------------------------------------------
-- Car foley levels
-------------------------------------------------------------------------------------------------------------------------

-- Off-road surfaces (raycast Material.Name) and how hard they rumble: the same materials that throw dust in the VFX
-- (Config/VFX.SurfaceDust), so you hear gravel exactly where you see dust.
Mix.RUMBLE = {
	Grass = 0.8,
	LeafyGrass = 0.8,
	Ground = 1,
	Mud = 0.9,
	Sand = 1.1,
	Sandstone = 0.9,
	Snow = 0.6,
	Salt = 0.8,
	Limestone = 0.9,
	Pebble = 1.1,
	Rock = 0.7,
	Slate = 0.7,
	Basalt = 0.7,
	CrackedLava = 0.7,
} :: { [string]: number }

-- Surface rumble level for the material under the car at `speed` (studs/s): 0 on paved roads and when stopped.
function Mix.rumbleLevel(materialName: string?, speed: number): number
	local k = if materialName then Mix.RUMBLE[materialName] else nil
	if not k or speed < 4 then
		return 0
	end
	return k * math.clamp((speed - 4) / 50, 0.15, 1)
end

-- Scrape loop level while the car's side is against a wall: speed along the wall (studs/s) above a crawl.
function Mix.scrapeLevel(touching: boolean, speed: number): number
	if not touching or speed < 6 then
		return 0
	end
	return math.clamp((speed - 6) / 40, 0.25, 1.1)
end

-- Crash detection for cars we only see move (other players, traffic): a sudden speed loss against a decaying recent
-- maximum (the same rule VehicleClient uses for its own car). Returns (crashed, drop, newRecentMax).
Mix.CRASH_DROP = 40
Mix.CRASH_DECAY = 300

function Mix.suddenDrop(recentMax: number, speed: number, dt: number): (boolean, number, number)
	local peak = math.max(speed, recentMax - Mix.CRASH_DECAY * dt)
	local drop = peak - speed
	if drop > Mix.CRASH_DROP then
		return true, drop, speed
	end
	return false, drop, peak
end

return Mix
