--!strict
-- SoundController (SPEC §7, PLAN C3 · audio): every sound the client hears. A facade over client/Audio/*:
--
--  * Mix (Audio/Groups + Shared/Audio/Mix): SoundGroups HC_SFX / HC_Vehicles / HC_Ambience / HC_Music / HC_UI under
--    SoundService. Volume = settings toggle (snapshot settings.sfx gates sfx / vehicles / ambience / ui, settings.music
--    the radio) x master slider x channel slider (pause menu SETTINGS rows: setVolume / getVolume) x ducks. Ducks fade:
--    "bigMessage" (WASTED / BUSTED: the death muffle and the stings), "pause" (HUDController's pause state), "gunfire"
--    (a shot within 80 studs: radio -6 dB), "retune" (the radio's static burst).
--  * One-shots (Audio/Voices): play(key, position?) — pooled Sounds, no Instance.new per shot; a global cap of
--    Mix.MAX_VOICES with priorities (UI > local car / guns > impacts / sirens > horns / world > remote cars > ambience).
--    No position = a 2D interface sound; with a position = 3D, channel by key (Mix.channelFor). A horn played at a car
--    becomes that car's class horn (Audio/Engines.hornNear). The `Sound` remote plays through here.
--  * Local car (Audio/LocalCar): per-class engine layers on a simulated rpm / gearbox, ignition / starter / stop,
--    pops on VehicleClient's Backfire signal, turbo hiss, limiter, tyre squeal by lateral slip, off-road rumble,
--    wall scrape, wind (inside only), impacts by crash size (VehicleClient's Crashed signal -> playImpact).
--  * Other cars (Audio/Engines): the 6 nearest running cars within 250 studs get 3D engines (3 layers within 60,
--    one layer beyond), Doppler-shifted; WheelAnimator's TireScreech loops are pooled and levelled by slip.
--  * Police (Audio/Police): siren patterns (SirenMode attribute or a wail / yelp / hi-lo machine), Doppler, the
--    wanted siren bed + dispatch blips (no words), the helicopter rotor when a heli exists.
--  * City (Audio/City): district beds day / night (NightFactor), freeway roar, one-shots, cover reverb.
--  * Radio (Audio/Radio): stations + RADIO OFF, per-car memory, police start off, a live clock shared by all clients,
--    static burst, muffled 3D copy for players outside a car (RadioTune remote -> car attribute RadioStation).
--  * Hotwire crackle while holding a steal prompt (Audio/Hotwire).
--  * Gunfire (gta_combat §11.6): playGunshot (shot / tail / mech layers by distance; tails skip the one-shot cull),
--    playDistantGunshot (the DistantShot remote: a quiet low-passed tail from the shot's direction, up to 1200 studs).
--  * Doppler is manual (SoundService.DopplerScale = 0): remote engines, sirens and the heli shift by closing speed,
--    and the local car never wobbles with the camera.
--  * BACKLOG 5: start() preloads Sound instances for every non-radio Config/Sounds id, and TextLabels for the Theme
--    fonts, with ContentProvider:PreloadAsync (instances, never id strings), then frees them.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Sounds = require(Config:WaitForChild("Sounds"))
local AudioShared = Shared:WaitForChild("Audio")
local Mix = require(AudioShared:WaitForChild("Mix"))
local EngineClass = require(AudioShared:WaitForChild("EngineClass"))
local RadioDial = require(AudioShared:WaitForChild("RadioDial"))

local Audio = script.Parent.Parent:WaitForChild("Audio")
local Apply = require(Audio:WaitForChild("Apply"))
local Groups = require(Audio:WaitForChild("Groups"))
local Voices = require(Audio:WaitForChild("Voices"))
local LocalCar = require(Audio:WaitForChild("LocalCar"))
local Engines = require(Audio:WaitForChild("Engines"))
local Police = require(Audio:WaitForChild("Police"))
local City = require(Audio:WaitForChild("City"))
local Radio = require(Audio:WaitForChild("Radio"))
local Hotwire = require(Audio:WaitForChild("Hotwire"))

-- Earlier in the client ORDER, so a direct require is safe (no cycle).
local StateController = require(script.Parent:WaitForChild("StateController"))

local SoundController = {}

local SCAN_INTERVAL = 0.25
local DEFAULT_TOP_SPEED = 100
local RADIO_PREFIX = "Radio_"
local BIG_MESSAGE_SECONDS = 5
local LISTENER_SMOOTHING = 6
local PRELOAD_DELAY = 3 -- s after start: the loading screen preloads first
SoundController.RADIO_TUNE_DELAY = Radio.TUNE_DELAY
-- VehicleClient checks this before making its own drift screech: the local car's tyres are ours (lateral slip).
SoundController.ownsLocalTyres = true

type SoundDef = Sounds.SoundDef

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests; the v1 engine helpers stay for the client-core specs)
-------------------------------------------------------------------------------------------------------------------------

-- v1 single-loop engine PlaybackSpeed for a car going `speed` with top speed `topSpeed` (clamped, nitro overshoot).
function SoundController.enginePitch(speed: number, topSpeed: number): number
	local top = if topSpeed > 1 then topSpeed else DEFAULT_TOP_SPEED
	local ratio = math.clamp(speed / top, 0, 1.3)
	return 0.7 + 1.1 * ratio
end

SoundController.isEngineEligible = EngineClass.isEngineEligible
SoundController.topSpeedFor = Engines.topSpeedFor

-- Given candidates { {key, dist} }, returns the set of the (≤ maxSlots) closest keys. Sorts candidates in place.
function SoundController.selectNearest(candidates: { { key: any, dist: number } }, maxSlots: number): { [any]: boolean }
	table.sort(candidates, function(a, b)
		return a.dist < b.dist
	end)
	local chosen: { [any]: boolean } = {}
	for i = 1, math.min(maxSlots, #candidates) do
		chosen[candidates[i].key] = true
	end
	return chosen
end

export type RadioStation = RadioDial.Station

SoundController.buildStations = RadioDial.buildStations

-- Station index after stepping `dir` (+1 / -1) from `index` among `count` stations. Wraps; an unset index -> 1.
function SoundController.stepIndex(index: number, dir: number, count: number): number
	if count <= 0 then
		return 0
	end
	if index < 1 or index > count or index % 1 ~= 0 then
		return 1
	end
	return (index - 1 + dir) % count + 1
end

-------------------------------------------------------------------------------------------------------------------------
-- Lookup
-------------------------------------------------------------------------------------------------------------------------

local warnedKeys: { [string]: boolean } = {}

local function lookup(key: string): SoundDef?
	local def = (Sounds :: any)[key]
	if typeof(def) ~= "table" then
		if not warnedKeys[key] then
			warnedKeys[key] = true
			warn("[SoundController] unknown sound key " .. tostring(key))
		end
		return nil
	end
	return def :: SoundDef
end

local PRIORITY_OF: { [string]: number } = {
	ui = Mix.PRIORITY.ui,
	music = Mix.PRIORITY.ui,
	vehicles = Mix.PRIORITY.horn,
	sfx = Mix.PRIORITY.world,
	ambience = Mix.PRIORITY.ambient,
}

local BIG_MESSAGES: { [string]: boolean } = { Wasted = true, Busted = true, WastedImpact = true }

-------------------------------------------------------------------------------------------------------------------------
-- One-shots
-------------------------------------------------------------------------------------------------------------------------

-- Play a Config/Sounds key. position = world sound (3D), nil = UI sound. Returns the playing Sound or nil.
function SoundController.play(key: string, position: Vector3?): Sound?
	if typeof(key) ~= "string" then
		return nil
	end
	local def = lookup(key)
	if not def then
		return nil
	end
	local positional = typeof(position) == "Vector3"
	local channel = Mix.channelFor(key, positional)
	if not Groups.isOn(if channel == "music" then "music" else "sfx") then
		return nil
	end
	if BIG_MESSAGES[key] then
		Groups.duck("bigMessage", true, BIG_MESSAGE_SECONDS)
	end
	if positional then
		local pos = position :: Vector3
		local k, d = key, def
		if key == "Horn" or key == "AirHorn" then
			local classHorn = Engines.hornNear(pos)
			local hd = if classHorn then lookup(classHorn) else nil
			if classHorn and hd then
				k, d = classHorn, hd
			end
		end
		channel = Mix.channelFor(k, true)
		return Voices.playAt(d, pos, Groups.get(channel), PRIORITY_OF[channel] or Mix.PRIORITY.world)
	end
	return Voices.play2D(key, def, Groups.get(channel), PRIORITY_OF[channel] or Mix.PRIORITY.ui)
end

-- A car crash of `drop` studs/s of sudden speed loss at `position` (VehicleClient: light thud / heavy crunch / glass).
function SoundController.playImpact(drop: number, position: Vector3)
	if typeof(drop) ~= "number" or typeof(position) ~= "Vector3" or not Groups.isOn("sfx") then
		return
	end
	LocalCar.impact(drop, position, Mix.PRIORITY.localCar)
end

-- Start a looping sound the caller owns. parent = BasePart/Attachment for 3D, nil for a UI loop.
-- channel "music" puts it on the music channel; default by key. TireScreech (WheelAnimator) comes from a pooled,
-- slip-levelled set and may be nil when the pool is busy.
function SoundController.playLoop(key: string, parent: Instance?, channel: string?): Sound?
	if key == "TireScreech" and parent and parent:IsA("BasePart") then
		return Engines.squealLoop(parent)
	end
	local def = lookup(key)
	if not def then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = "Loop_" .. key
	local ch = if channel == "music" then "music" else Mix.channelFor(key, parent ~= nil)
	Apply.def(s, def, Groups.get(ch))
	s.Looped = true
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 15
	s.RollOffMaxDistance = def.rollOff or 300
	s.Parent = parent or SoundService
	s.TimePosition = Apply.startTime(def)
	s:Play()
	return s
end

function SoundController.stopLoop(sound: Sound?)
	if not sound then
		return
	end
	if Engines.releaseLoop(sound) then
		return
	end
	sound:Stop()
	sound:Destroy()
end

-- Start (on) or release a named duck (Mix.DUCKS); seconds = release automatically.
function SoundController.duck(reason: string, on: boolean, seconds: number?)
	Groups.duck(reason, on, seconds)
end

-------------------------------------------------------------------------------------------------------------------------
-- Gunfire (gta_combat §11.6): shot (close) + tail (distance) + mech (close) layers, distance rules, near-miss whiz,
-- radio ducking, and the death / weapon-wheel muffle on the world channels.
-------------------------------------------------------------------------------------------------------------------------

SoundController.GUN_TAIL_FROM = 120 -- the tail layer plays for listeners beyond this
SoundController.GUN_LOWPASS_FROM = 250 -- ...low-passed beyond this
SoundController.GUN_FAR = 600 -- beyond this only a single quiet distant tail
SoundController.GUN_MECH_RANGE = 30
SoundController.GUN_DUCK_RANGE = 80
SoundController.GUN_DISTANT_MAX = 1200 -- distant tails (DistantShot) are heard up to this far
SoundController.GUN_DISTANT_EMIT = 150 -- ...emitted at most this far away, on the line to the shot (keeps direction)

local roundRobin: { [string]: number } = {}

-- Next variant from a list (round robin per list head).
function SoundController.pickVariant(list: { string }, counter: { [string]: number }?): string?
	local n = #list
	if n == 0 then
		return nil
	end
	local book = counter or roundRobin
	local key = list[1]
	local i = (book[key] or 0) % n + 1
	book[key] = i
	return list[i]
end

-- Which gun layers play for a listener at distance d: (shot, tail, lowpass, mech, distantOnly).
function SoundController.gunLayers(d: number): (boolean, boolean, boolean, boolean, boolean)
	if d > SoundController.GUN_FAR then
		return false, true, true, false, true
	end
	return true,
		d > SoundController.GUN_TAIL_FROM,
		d > SoundController.GUN_LOWPASS_FROM,
		d <= SoundController.GUN_MECH_RANGE,
		false
end

-- Distant-tail volume multiplier for a listener `d` studs away (pure, tested): 0.3 up to GUN_FAR, falling with
-- distance to half that at GUN_DISTANT_MAX, 0 beyond.
function SoundController.distantVolume(d: number): number
	if d > SoundController.GUN_DISTANT_MAX then
		return 0
	end
	return 0.3 * math.clamp(SoundController.GUN_FAR / math.max(d, 1), 0.5, 1)
end

-- Where a distant tail is emitted (pure, tested): the shot itself when close, else GUN_DISTANT_EMIT studs from the
-- listener toward it (the pooled emitters' roll-off would silence the real position; the direction is kept).
function SoundController.distantEmitPoint(listener: Vector3, origin: Vector3): Vector3
	local off = origin - listener
	local d = off.Magnitude
	if d <= SoundController.GUN_DISTANT_EMIT or d < 1e-3 then
		return origin
	end
	return listener + off / d * SoundController.GUN_DISTANT_EMIT
end

local function listenerPosition(): Vector3?
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else nil
end

-- force: skip the distance cull (tails).
local function playLayer(key: string?, position: Vector3, volumeMult: number, lowpass: boolean, force: boolean?)
	if not key then
		return
	end
	local def = lookup(key)
	if not def or not Groups.isOn("sfx") then
		return
	end
	Voices.playAt(def, position, Groups.get("sfx"), Mix.PRIORITY.gunshot, volumeMult, lowpass, force)
end

-- Radio ducking under nearby gunfire (-6 dB, Mix.DUCKS.gunfire). factor is kept for the v1 signature.
function SoundController.duckRadio(seconds: number, _factor: number?)
	Groups.duckNow("gunfire", seconds)
end

-- Only the quiet, low-passed tail of a far-away shot (beyond GUN_FAR, or relayed as DistantShot).
local function playDistantTail(weaponSounds: any, position: Vector3, listener: Vector3?, d: number)
	local mult = SoundController.distantVolume(d)
	if mult <= 0 then
		return
	end
	local at = if listener then SoundController.distantEmitPoint(listener, position) else position
	playLayer(SoundController.pickVariant(weaponSounds.tail or {}), at, mult, true, true)
end

-- One gunshot heard at `position`. weaponSounds = Config/Weapons def.sounds.
function SoundController.playGunshot(weaponSounds: any, position: Vector3)
	if typeof(weaponSounds) ~= "table" or typeof(position) ~= "Vector3" then
		return
	end
	local listener = listenerPosition()
	local d = if listener then (listener - position).Magnitude else 0
	local shot, tail, lowpass, mech, distantOnly = SoundController.gunLayers(d)
	if distantOnly then
		playDistantTail(weaponSounds, position, listener, d)
		return
	end
	if shot then
		playLayer(SoundController.pickVariant(weaponSounds.shot or {}), position, 1, false)
	end
	if tail then
		-- tails carry past the one-shot cull distance
		playLayer(SoundController.pickVariant(weaponSounds.tail or {}), position, 0.8, lowpass, true)
	end
	if mech and weaponSounds.mech and #weaponSounds.mech > 0 then
		local key = SoundController.pickVariant(weaponSounds.mech)
		task.delay(0.35, function()
			playLayer(key, position, 1, false)
		end)
	end
	if d <= SoundController.GUN_DUCK_RANGE then
		SoundController.duckRadio(1.5)
	end
end

-- A gunshot far beyond the ShotFx radius (the DistantShot remote, gta_combat §11.6): only its distant tail, quiet
-- and low-passed, from the shot's direction. Nothing beyond GUN_DISTANT_MAX.
function SoundController.playDistantGunshot(weaponSounds: any, origin: Vector3)
	if typeof(weaponSounds) ~= "table" or typeof(origin) ~= "Vector3" or not Groups.isOn("sfx") then
		return
	end
	local listener = listenerPosition()
	local d = if listener then (listener - origin).Magnitude else SoundController.GUN_FAR
	playDistantTail(weaponSounds, origin, listener, math.max(d, SoundController.GUN_FAR))
end

local WHIZ = { "Whiz1", "Whiz2", "Whiz3" }
function SoundController.playWhiz(position: Vector3)
	playLayer(SoundController.pickVariant(WHIZ), position, 1, false)
end

-- Muffle the world (death / arrest grade, weapon wheel). nil clears that reason's muffle; with several reasons
-- active the strongest (most negative) gains win. The radio and UI one-shots stay crisp. The death grade also ducks
-- music / ambience for the WASTED / BUSTED message.
local muffles: { [string]: { high: number, mid: number } } = {}
function SoundController.setMuffle(highGain: number?, midGain: number?, reason: string?)
	local key = reason or "default"
	muffles[key] = if highGain == nil then nil else { high = highGain, mid = midGain or 0 }
	local high, mid, any = 0, 0, false
	for _, m in muffles do
		any = true
		high = math.min(high, m.high)
		mid = math.min(mid, m.mid)
	end
	Groups.setMuffle(if any then high else nil, mid)
	if key == "death" then
		Groups.duck("bigMessage", highGain ~= nil)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Car radio (Audio/Radio)
-------------------------------------------------------------------------------------------------------------------------

SoundController.RadioChanged = Radio.Changed -- (station: string?, title: string?) title is nil while nothing plays

local controllerCache: { [string]: any } = {}
local function lazy(name: string): any
	local cached = controllerCache[name]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local ms = script.Parent:FindFirstChild(name)
	local mod: any = false
	if ms and ms:IsA("ModuleScript") then
		local ok, res = pcall(require, ms)
		if ok and typeof(res) == "table" then
			mod = res
		end
	end
	controllerCache[name] = mod
	return if mod then mod else nil
end

-- VehicleClient: true while the local player drives. A new car tunes a random station (police: RADIO OFF).
function SoundController.setRadioOn(on: boolean)
	if typeof(on) ~= "boolean" then
		return
	end
	local model: Model? = nil
	if on then
		local vc = lazy("VehicleClient")
		if vc and typeof(vc.getModel) == "function" then
			local ok, m = pcall(vc.getModel)
			model = if ok and typeof(m) == "Instance" and m:IsA("Model") then m else nil
		end
	end
	Radio.setInCar(on, model)
end

-- Next (+1) / previous (-1) dial position (stations, then RADIO OFF).
function SoundController.stepRadio(dir: number)
	Radio.step(dir)
end

-- (station name? (RADIO OFF when off), track title? (nil while silent), playing)
function SoundController.getRadio(): (string?, string?, boolean)
	return Radio.get()
end

function SoundController.radioStations(): { string }
	return Radio.stationNames()
end

-------------------------------------------------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------------------------------------------------

-- setEnabled(enabled, channel?) or setEnabled(channel, enabled). channel = "sfx" | "music" | nil (both).
function SoundController.setEnabled(a: any, b: any)
	local channel: any, value: any
	if typeof(a) == "string" then
		channel, value = a, b
	else
		value, channel = a, b
	end
	if typeof(value) ~= "boolean" then
		return
	end
	if channel == nil or channel == "sfx" then
		Groups.setToggle("sfx", value)
	end
	if channel == nil or channel == "music" then
		Groups.setToggle("music", value)
		Radio.setMusic(value)
	end
end

function SoundController.isEnabled(channel: string): boolean
	return Groups.isOn(channel)
end

-- Slider volume 0..1 of a channel: "master" | "sfx" | "vehicles" | "ambience" | "music" | "ui".
function SoundController.setVolume(channel: string, volume: number)
	if typeof(channel) ~= "string" or typeof(volume) ~= "number" then
		return
	end
	Groups.setVolume(channel, volume)
end

function SoundController.getVolume(channel: string): number
	return Groups.getVolume(channel)
end

local function applySettings(snapshot: any)
	if typeof(snapshot) ~= "table" or typeof(snapshot.settings) ~= "table" then
		return
	end
	local s = snapshot.settings
	if typeof(s.sfx) == "boolean" then
		Groups.setToggle("sfx", s.sfx)
	end
	if typeof(s.music) == "boolean" then
		Groups.setToggle("music", s.music)
		Radio.setMusic(s.music)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Integration with VehicleClient / HUDController (lazy: they load after us)
-------------------------------------------------------------------------------------------------------------------------

local function connectSignal(owner: any, field: string, fn: (...any) -> ()): boolean
	local sig = if typeof(owner) == "table" then owner[field] else nil
	if typeof(sig) == "table" and typeof(sig.Connect) == "function" then
		sig:Connect(fn)
		return true
	end
	return false
end

local function hookControllers()
	local vc = lazy("VehicleClient")
	if vc then
		connectSignal(vc, "Entered", function(model: any, controller: any)
			if typeof(model) == "Instance" and model:IsA("Model") then
				LocalCar.enter(model, controller)
			end
		end)
		connectSignal(vc, "Exited", function()
			LocalCar.exit()
		end)
		-- integration points (VehicleClient, PLAN C3): exhaust pops with the flame VFX, crashes by size
		LocalCar.setBackfireSignal(connectSignal(vc, "Backfire", function(big: any)
			if Groups.isOn("sfx") then
				LocalCar.pop(big == true)
			end
		end))
		-- a car we were already driving when this ran
		if typeof(vc.getModel) == "function" and typeof(vc.getController) == "function" then
			local okM, m = pcall(vc.getModel)
			local okC, c = pcall(vc.getController)
			if okM and okC and typeof(m) == "Instance" and m:IsA("Model") then
				LocalCar.enter(m, c)
			end
		end
	end
	local hud = lazy("HUDController")
	if hud and typeof(hud.hiddenState) == "function" then
		local function readPause()
			local ok, _, _, paused = pcall(hud.hiddenState)
			Groups.duck("pause", ok and paused == true)
		end
		connectSignal(hud, "VisibilityChanged", readPause)
		readPause()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Preload (BACKLOG 5: instances, never id strings)
-------------------------------------------------------------------------------------------------------------------------

-- Every non-radio Config/Sounds id once (radio tracks stream when tuned: 2-3 min each).
function SoundController.preloadIds(defs: { [string]: any }): { string }
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	for key, def in defs do
		if typeof(key) == "string" and string.sub(key, 1, #RADIO_PREFIX) == RADIO_PREFIX then
			continue
		end
		if typeof(def) == "table" and typeof(def.id) == "string" and not seen[def.id] then
			seen[def.id] = true
			table.insert(ids, def.id)
		end
	end
	table.sort(ids)
	return ids
end

local function preload()
	local list: { Instance } = {}
	for _, id in SoundController.preloadIds(Sounds :: any) do
		local s = Instance.new("Sound")
		s.SoundId = id
		table.insert(list, s)
	end
	-- the Theme fonts (the loading screen preloads four; menus use the rest)
	local okTheme, Theme = pcall(function()
		local ui = script.Parent.Parent:FindFirstChild("UI")
		return require((ui :: Instance):FindFirstChild("Theme") :: any)
	end)
	if okTheme and typeof(Theme) == "table" and typeof(Theme.Fonts) == "table" then
		for _, face in Theme.Fonts do
			if typeof(face) == "Font" then
				local label = Instance.new("TextLabel")
				label.FontFace = face
				label.Text = "Aa"
				table.insert(list, label)
			end
		end
	end
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(list)
	end)
	if not ok then
		warn("[SoundController] preload failed: " .. tostring(err))
	end
	for _, inst in list do
		inst:Destroy()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local lisPos = Vector3.zero
local lisVel = Vector3.zero
local hasListener = false
local scanAccum = 0
local scanCount = 0

local function onRender(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam or dt <= 0 then
		return
	end
	local pos = cam.CFrame.Position
	if hasListener then
		local raw = (pos - lisPos) / dt
		if raw.Magnitude > 400 then
			raw = Vector3.zero -- a camera cut / teleport is not motion
		end
		lisVel = lisVel:Lerp(raw, math.min(1, dt * LISTENER_SMOOTHING))
	end
	lisPos = pos
	hasListener = true
	local sfxOn = Groups.isOn("sfx")
	local driving = LocalCar.isActive()

	scanAccum += dt
	if scanAccum >= SCAN_INTERVAL then
		scanAccum = 0
		scanCount += 1
		debug.profilebegin("HC_SoundScan")
		Engines.scan(pos, sfxOn)
		Police.scan(pos, sfxOn)
		if scanCount % 2 == 0 then
			City.scan(pos, sfxOn, LocalCar.getModel())
			Radio.scan(pos, Engines.cars(), LocalCar.getModel())
		end
		debug.profileend()
	end

	debug.profilebegin("HC_SoundStep")
	Groups.step(dt)
	LocalCar.step(dt)
	Engines.step(dt, pos, lisVel)
	Police.step(dt, pos, lisVel, sfxOn, driving)
	City.step(dt, driving)
	Radio.stepOutside(dt)
	debug.profileend()
end

function SoundController.init()
	Groups.apply()
	pcall(function()
		SoundService.DopplerScale = 0 -- manual Doppler (see header)
	end)
end

function SoundController.start()
	Groups.apply()
	Voices.anchor()

	-- remote
	local ok, err = pcall(Net.listen, "Sound", function(key: any, position: any)
		if typeof(key) ~= "string" or #key > 64 then
			return
		end
		SoundController.play(key, if typeof(position) == "Vector3" then position else nil)
	end)
	if not ok then
		warn("[SoundController] Sound remote unavailable: " .. tostring(err))
	end
	Radio.setFire(Net.fire)

	-- settings from the snapshot
	StateController.onReady(applySettings)
	StateController.Changed:Connect(function(snapshot: any)
		applySettings(snapshot)
	end)

	Engines.start()
	Police.start()
	City.start()
	Hotwire.start()
	task.defer(hookControllers)

	RunService.PreRender:Connect(onRender)

	-- preload in the background (yields; never blocks gameplay)
	task.delay(PRELOAD_DELAY, preload)
end

return SoundController
