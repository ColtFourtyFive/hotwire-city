--!strict
-- LocalCar (PLAN C3 · audio): what the local driver hears from their own car.
--
--  * Engine: the car's engine set (Audio/EngineClass from the catalog: EngineClass attribute > police > class > style >
--    sedan) with idle / on-load / off-load layers. Shared/Audio/EngineModel turns the arcade chassis' speed + throttle
--    into rpm with fake gears (pitch drop + a short volume dip on upshifts), revs freely at a standstill with the
--    handbrake on or in the air, bounces off the limiter, crackles on lift-off. Ignition click, starter, then the
--    engine fades in; the engine-off clunk when you get out.
--  * Pops: upshift / nitro pops are played on VehicleClient's Backfire signal (the exhaust-flame VFX), so sound and
--    flame land together; limiter and lift-off crackles come from the engine model; turbo cars hiss on upshifts.
--  * Foley: tyre squeal from lateral slip (Mix.squealLevel, the drift VFX's input), off-road rumble on the materials
--    that throw dust (Mix.RUMBLE ~ Config/VFX.SurfaceDust), a scrape loop while a side grinds along a wall, wind noise
--    at speed (2D: heard inside the car only), impacts scaled by the crash's speed loss (light thud / heavy crunch /
--    glass) from VehicleClient's Crashed signal.
-- Every loop lives on a pooled emitter that follows the chassis (Voices.loopAt), never inside the car model. step()
-- runs every frame from SoundController and allocates nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioShared = Shared:WaitForChild("Audio")
local Sounds = require(Shared:WaitForChild("Config"):WaitForChild("Sounds"))
local Cars = require(Shared:WaitForChild("Config"):WaitForChild("Cars"))
local EngineModel = require(AudioShared:WaitForChild("EngineModel"))
local EngineClass = require(AudioShared:WaitForChild("EngineClass"))
local Mix = require(AudioShared:WaitForChild("Mix"))

local Apply = require(script.Parent:WaitForChild("Apply"))
local Groups = require(script.Parent:WaitForChild("Groups"))
local Voices = require(script.Parent:WaitForChild("Voices"))

local LocalCar = {}

LocalCar.IGNITION_DELAY = 0.35 -- s from the key click to the starter
LocalCar.ENGINE_FADE_AT = 0.7 -- s after getting in when the engine layers start fading in
LocalCar.ENGINE_FADE = 0.5 -- s of that fade
LocalCar.SURFACE_EVERY = 0.2 -- s between ground-material rays
LocalCar.SCRAPE_EVERY = 0.1 -- s between side rays
LocalCar.POP_GAP = 0.09 -- s between two crackle pops
LocalCar.LOOP_RESPONSE = 9 -- per second, loop volume smoothing

type Def = Apply.Def
type Layer = { sound: Sound, def: Def?, vol: number, pitch: number }

local player = Players.LocalPlayer
local rng = Random.new()

local active = false
local model: Model? = nil
local chassis: BasePart? = nil
local controller: any = nil
local carDef: any = nil
local engineSet = EngineClass.DEFAULT
local profile: EngineModel.Profile = EngineModel.profileFor(EngineClass.DEFAULT)
local state: EngineModel.State = EngineModel.newState(profile)
local mix: EngineModel.Mix = EngineModel.newMix()
local enteredAt = 0
local lastPop = 0
local lastDoor = -math.huge
local surfaceT = 0
local scrapeT = 0
local surfaceName: string? = nil
local touchingWall = false
local hasBackfireSignal = false

local emitter: Attachment? = nil
local idle: Layer? = nil
local on: Layer? = nil
local off: Layer? = nil
local squeal: Layer? = nil
local rumble: Layer? = nil
local scrape: Layer? = nil
local wind: Layer? = nil
local rayParams: RaycastParams? = nil
local filter: { Instance } = {}

local function def(key: string): Def?
	local d = (Sounds :: any)[key]
	return if typeof(d) == "table" then d :: Def else nil
end

local function newLayer(sound: Sound): Layer
	return { sound = sound, def = nil, vol = 0, pitch = 1 }
end

-- Build the loop Sounds once (they are re-pointed at each car's set on entry).
local function ensureLoops()
	if emitter and emitter.Parent then
		return
	end
	local att = Voices.emitter("HC_LocalCar")
	emitter = att
	local function make(name: string, minDist: number): Layer
		local s = att:FindFirstChild(name)
		if not (s and s:IsA("Sound")) then
			local made = Instance.new("Sound")
			made.Name = name
			made.Looped = true
			made.Volume = 0
			made.RollOffMode = Enum.RollOffMode.InverseTapered
			made.RollOffMinDistance = minDist
			made.RollOffMaxDistance = 260
			made.Parent = att
			s = made
		end
		return newLayer(s :: Sound)
	end
	idle = make("EngIdle", 30)
	on = make("EngOn", 30)
	off = make("EngOff", 30)
	squeal = make("Squeal", 25)
	rumble = make("Rumble", 25)
	scrape = make("Scrape", 25)
	wind = newLayer(Voices.loop2D("HC_Wind"))
	local vehicles = Groups.get("vehicles")
	for _, pair in { { squeal, "TireScreech" }, { rumble, "SurfaceGravel" }, { scrape, "ScrapeLoop" } } do
		local layer = pair[1] :: Layer
		local d = def(pair[2] :: string)
		if d then
			Apply.def(layer.sound, d, vehicles)
			layer.sound.Looped = true
			layer.sound.Volume = 0
			layer.def = d
		end
	end
	local w = wind :: Layer
	local wd = def("WindInterior")
	if wd then
		Apply.def(w.sound, wd, vehicles)
		w.sound.Looped = true
		w.sound.Volume = 0
		w.def = wd
	end
end

local function pointLayer(layer: Layer?, key: string)
	if not layer then
		return
	end
	local d = def(key)
	layer.def = d
	if d then
		Apply.def(layer.sound, d, Groups.get("vehicles"))
		layer.sound.Looped = true
	end
	layer.sound.Volume = 0
	layer.vol = 0
end

local function stopLayer(layer: Layer?)
	if layer then
		layer.vol = 0
		layer.sound.Volume = 0
		if layer.sound.IsPlaying then
			layer.sound:Stop()
		end
	end
end

-- Drive one loop toward `target` (0..~1.3 of its def volume) at `pitch`; starts / stops the Sound at the ends.
local function drive(layer: Layer?, target: number, pitch: number, dt: number)
	if not layer then
		return
	end
	local d = layer.def
	if not d then
		return
	end
	layer.vol = Mix.approach(layer.vol, target, LocalCar.LOOP_RESPONSE, dt)
	local v = d.volume * layer.vol
	local s = layer.sound
	if v > 0.003 then
		if not s.IsPlaying then
			s.TimePosition = Apply.startTime(d) + rng:NextNumber(0, 0.5)
			s:Play()
		end
		s.Volume = v
		local p = (d.pitch or 1) * pitch
		if math.abs(p - layer.pitch) > 0.002 then
			layer.pitch = p
			s.PlaybackSpeed = p
		end
	elseif s.IsPlaying then
		s.Volume = 0
		s:Stop()
	end
end

local function oneShot(key: string, position: Vector3?, volumeMult: number?, priority: number?)
	local d = def(key)
	if not d then
		return
	end
	if position then
		Voices.playAt(d, position, Groups.get("vehicles"), priority or Mix.PRIORITY.localCar, volumeMult)
	else
		Voices.play2D(key, d, Groups.get("vehicles"), priority or Mix.PRIORITY.localCar, volumeMult)
	end
end

local POPS = { "Pop_Backfire1", "Pop_Backfire2" }
local LIGHT = { "Impact_Light1", "Impact_Light2", "Impact_Light3" }
local HEAVY = { "Impact_Heavy1", "Impact_Heavy2", "Impact_Heavy3" }
local GLASS = { "Impact_Glass1", "Impact_Glass2" }

local function pick(list: { string }): string
	return list[rng:NextInteger(1, #list)]
end

local function exhaustPosition(): Vector3?
	local c = chassis
	if not c or c.Parent == nil then
		return nil
	end
	return c.CFrame * Vector3.new(0, -0.4, c.Size.Z * 0.5)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------------------------------------------------

function LocalCar.isActive(): boolean
	return active
end

function LocalCar.getModel(): Model?
	return if active then model else nil
end

function LocalCar.getEngineSet(): string
	return engineSet
end

LocalCar.DOOR_GAP = 1.2

-- A car door at `position`, at most once per DOOR_GAP: getting in plays one, and the garage's drive-out sends its own
-- (the `Sound` remote) at almost the same moment.
function LocalCar.door(position: Vector3)
	local now = os.clock()
	if now - lastDoor < LocalCar.DOOR_GAP then
		return
	end
	lastDoor = now
	oneShot("CarDoor", position)
end

-- VehicleClient exposes a Backfire signal (integration point): upshift / nitro pops follow the exhaust flame.
function LocalCar.setBackfireSignal(present: boolean)
	hasBackfireSignal = present
end

-- An exhaust pop (VehicleClient.Backfire: big = nitro start).
function LocalCar.pop(big: boolean?)
	if not active or not profile then
		return
	end
	local now = os.clock()
	if now - lastPop < LocalCar.POP_GAP then
		return
	end
	lastPop = now
	local at = exhaustPosition()
	if at then
		oneShot(pick(POPS), at, if big then 1.4 else 1)
	end
end

-- A crash of `drop` studs/s of sudden speed loss at `position` (VehicleClient.Crashed, or a remote car's).
function LocalCar.impact(drop: number, position: Vector3, priority: number?)
	local light, heavy, glass, gain = Mix.impactLayers(drop)
	local pr = priority or Mix.PRIORITY.impact
	local group = Groups.get("sfx")
	if light then
		local d = def(pick(LIGHT))
		if d then
			Voices.playAt(d, position, group, pr, gain)
		end
	end
	if heavy then
		local d = def(pick(HEAVY))
		if d then
			Voices.playAt(d, position, group, pr, gain)
		end
	end
	if glass then
		local d = def(pick(GLASS))
		if d then
			Voices.playAt(d, position, group, pr, gain * 0.9)
		end
	end
end

function LocalCar.enter(m: Model, ctrl: any)
	ensureLoops()
	model = m
	controller = ctrl
	local primary = m.PrimaryPart or m:FindFirstChild("Chassis")
	chassis = if primary and primary:IsA("BasePart") then primary else nil
	local carId = m:GetAttribute("CarId")
	carDef = if typeof(ctrl) == "table" and typeof(ctrl.def) == "table" then ctrl.def else nil
	if not carDef and typeof(carId) == "string" then
		carDef = Cars.get(carId)
	end
	engineSet = EngineClass.resolve(m:GetAttribute("EngineClass"), m:GetAttribute("Kind"), carDef)
	profile = EngineModel.profileFor(engineSet)
	EngineModel.reset(state, profile)
	local keys = EngineClass.keysFor(engineSet)
	pointLayer(idle, keys.idle)
	pointLayer(on, keys.on)
	pointLayer(off, keys.off)
	enteredAt = os.clock()
	surfaceName = nil
	touchingWall = false
	active = true
	local params = rayParams or RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	table.clear(filter)
	table.insert(filter, m)
	if player and player.Character then
		table.insert(filter, player.Character)
	end
	params.FilterDescendantsInstances = filter
	rayParams = params
	-- door, key click, then the starter
	if chassis then
		LocalCar.door(chassis.Position)
	end
	oneShot("Ignition", nil, 1, Mix.PRIORITY.ui)
	task.delay(LocalCar.IGNITION_DELAY, function()
		if active and model == m and chassis then
			oneShot("EngineStart", chassis.Position)
		end
	end)
end

function LocalCar.exit()
	if not active then
		return
	end
	active = false
	local c = chassis
	if c and c.Parent then
		oneShot("EngineStop", c.Position)
		local at = c.Position
		task.delay(0.45, function()
			oneShot("DoorSlam", at)
		end)
	end
	for _, layer in { idle, on, off, squeal, rumble, scrape, wind } do
		stopLayer(layer)
	end
	model, chassis, controller, carDef = nil, nil, nil, nil
end

-------------------------------------------------------------------------------------------------------------------------
-- Per frame
-------------------------------------------------------------------------------------------------------------------------

local DOWN = Vector3.new(0, -9, 0)

local function sampleSurface(c: BasePart)
	local params = rayParams
	if not params then
		return
	end
	local hit = Workspace:Raycast(c.Position, DOWN, params)
	surfaceName = if hit then hit.Material.Name else nil
end

-- A side of the car against something solid and upright (a wall, a barrier, another car).
local function sampleWalls(c: BasePart)
	local params = rayParams
	if not params then
		return
	end
	local cf = c.CFrame
	local reach = c.Size.X * 0.5 + 0.9
	local right = cf.RightVector
	touchingWall = false
	for side = -1, 1, 2 do
		local hit = Workspace:Raycast(cf.Position, right * (reach * side), params)
		if hit and math.abs(hit.Normal.Y) < 0.5 then
			touchingWall = true
			return
		end
	end
end

function LocalCar.step(dt: number)
	if not active then
		return
	end
	local c = chassis
	local ctrl = controller
	if not c or c.Parent == nil or typeof(ctrl) ~= "table" then
		LocalCar.exit()
		return
	end
	local speed = math.abs(tonumber(ctrl.speed) or 0)
	local forward = tonumber(ctrl.forwardSpeed) or 0
	local lateral = tonumber(ctrl.lateralSpeed) or 0
	local input = ctrl.input
	local throttleIn = if typeof(input) == "table" then tonumber(input.throttle) or 0 else 0
	local handbrake = typeof(input) == "table" and input.handbrake == true
	local grounded = (tonumber(ctrl.grounded) or 0) >= 2
	local top = if carDef and typeof(carDef.topSpeed) == "number" then carDef.topSpeed else 100
	local frac = speed / math.max(top, 1)

	-- throttle the engine sees: braking while rolling forward = off load; reversing = throttle
	local thr = throttleIn
	if thr < 0 then
		thr = if forward < -1 or speed < 2 then -thr else 0
	end
	if ctrl.boosting == true then
		thr = 1
	end
	local held = handbrake or (player ~= nil and player:GetAttribute("Stunned") == true)
	EngineModel.step(state, profile, dt, frac, thr, grounded, held)
	EngineModel.mix(state, profile, mix)

	-- engine fade-in after the starter
	local since = os.clock() - enteredAt
	local fade = math.clamp((since - LocalCar.ENGINE_FADE_AT) / LocalCar.ENGINE_FADE, 0, 1)
	local g = mix.gain * fade
	drive(idle, mix.idle * g, mix.idlePitch, dt)
	drive(on, mix.on * g, mix.onPitch, dt)
	drive(off, mix.off * g, mix.offPitch, dt)

	-- events from the engine model
	if state.blowoff then
		local at = exhaustPosition()
		if at then
			oneShot("Turbo_Blowoff", at)
		end
	end
	if state.pop and (state.shifted ~= 1 or not hasBackfireSignal) then
		LocalCar.pop(false)
	end

	-- follow the car
	local att = emitter
	if att then
		att.WorldPosition = c.Position
	end

	-- foley
	surfaceT += dt
	if surfaceT >= LocalCar.SURFACE_EVERY then
		surfaceT = 0
		sampleSurface(c)
	end
	scrapeT += dt
	if scrapeT >= LocalCar.SCRAPE_EVERY then
		scrapeT = 0
		sampleWalls(c)
	end
	local slip = Mix.squealLevel(lateral, grounded, ctrl.drifting == true)
	drive(squeal, slip, 0.92 + 0.12 * math.clamp(math.abs(lateral) / 40, 0, 1), dt)
	drive(rumble, if grounded then Mix.rumbleLevel(surfaceName, speed) else 0, 0.85 + 0.3 * math.clamp(frac, 0, 1), dt)
	drive(scrape, Mix.scrapeLevel(touchingWall, speed), 0.9 + 0.2 * math.clamp(speed / 80, 0, 1), dt)
	drive(wind, Mix.windLevel(speed, top), 0.9 + 0.25 * math.clamp(frac, 0, 1.2), dt)
end

return LocalCar
