--!strict
-- Radio (PLAN C3 · audio): the GTA-style car radio.
--
--  * Stations: Config/Sounds Radio_* tracks (Roblox-licensed APM Music already on the platform, audited in
--    docs/v2/evidence/audio_audit.md) grouped by our own parody station names (Shared/Audio/RadioDial.buildStations).
--    The dial has every station plus RADIO OFF.
--  * Only in vehicles: VehicleClient calls setRadioOn(true / false) on getting in / out. A car you have driven
--    remembers its station while you keep coming back to it (RadioDial memory by VehicleId); a new car starts on a
--    random station, police cars start on RADIO OFF.
--  * Live stations: a station plays its playlist on a clock shared by every client (RadioDial.trackAt over the
--    server time), so tuning in lands mid-song, like GTA, and whoever stands next to the car hears the same song.
--  * Tuning: the label retunes at once (Changed fires per press: the HUD shows station + track), a short static burst
--    plays, and the station's track starts TUNE_DELAY after the last press (mashing the buttons streams one track).
--    Two decks crossfade.
--  * Other players hear it: the settled station is sent to the server ("RadioTune"; AudioService validates that the
--    sender drives a live car and sets that car's "RadioStation" attribute). Cars near the listener with a
--    RadioStation get a muffled (low-passed) 3D copy of that station, on the same clock (OUTSIDE_SLOTS nearest within
--    OUTSIDE_RANGE).
-- Music setting off = no stream at all (decks stopped).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Sounds = require(Shared:WaitForChild("Config"):WaitForChild("Sounds"))
local RadioDial = require(Shared:WaitForChild("Audio"):WaitForChild("RadioDial"))
local EngineClass = require(Shared:WaitForChild("Audio"):WaitForChild("EngineClass"))
local Mix = require(Shared:WaitForChild("Audio"):WaitForChild("Mix"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local Cars = require(Shared:WaitForChild("Config"):WaitForChild("Cars"))

local Apply = require(script.Parent:WaitForChild("Apply"))
local Groups = require(script.Parent:WaitForChild("Groups"))
local Voices = require(script.Parent:WaitForChild("Voices"))

local Radio = {}

Radio.TUNE_DELAY = 0.4 -- s after the last press before that station's track starts
Radio.FADE = 0.8 -- s per crossfade half
Radio.LOAD_TIMEOUT = 12 -- s: a track still not loaded is retried
Radio.RESYNC = 1.5 -- s of drift from the station clock that triggers a re-seek once loaded
Radio.OUTSIDE_RANGE = 70
Radio.OUTSIDE_SLOTS = 2
Radio.OUTSIDE_GAIN = 1.8 -- the muffled copy is louder before its low-pass (it is heard through the bodywork)
Radio.REMOTE = "RadioTune"

Radio.Changed = Signal.new() -- (station: string?, title: string?) title nil while nothing plays

type Def = Apply.Def
type Outside = { att: Attachment, sound: Sound, car: any, station: number, key: string?, fade: number, token: number }

local stations = RadioDial.buildStations(Sounds :: any)
local count = #stations
local rng = Random.new()
local function rand(): number
	return rng:NextNumber()
end

local dial = 0 -- 1..count = station, count + 1 = OFF, 0 = never tuned
local inCar = false
local playing = false -- decks live: in a car, music on, a station tuned
local title: string? = nil
local carKey: any = nil
local memory = RadioDial.newMemory()
local decks: { [number]: Sound } = {}
local tweens: { [number]: Tween } = {}
local deck = 1
local token = 0
local tuneToken = 0
local published: string? = nil
local outside: { Outside } = {}
local musicOn = true
local fire: ((string, ...any) -> ())? = nil

-------------------------------------------------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------------------------------------------------

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and typeof(t) == "number" then t else os.time()
end

local function def(key: string?): Def?
	if not key then
		return nil
	end
	local d = (Sounds :: any)[key]
	return if typeof(d) == "table" then d :: Def else nil
end

local function isOff(): boolean
	return RadioDial.isOff(dial, count)
end

local function stationName(): string?
	if isOff() then
		return RadioDial.OFF_LABEL
	end
	local st = stations[dial]
	return if st then st.name else nil
end

local function notify()
	Radio.Changed:Fire(stationName(), if playing then title else nil)
end

-- The clock track of station index i: (Sounds key, seconds in).
function Radio.clockTrack(i: number, t: number): (string?, number)
	local st = stations[i]
	if not st then
		return nil, 0
	end
	local index, offset = RadioDial.trackAt(st.lengths, t, st.salt)
	return st.tracks[index], offset
end

local function publish()
	local name = if inCar and not isOff() then stationName() or "" else ""
	if name == published then
		return
	end
	published = name
	local f = fire
	if f then
		task.spawn(function()
			pcall(f, Radio.REMOTE, name)
		end)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Decks
-------------------------------------------------------------------------------------------------------------------------

local function fadeDeck(i: number, target: number, stopAfter: boolean)
	local sound = decks[i]
	if not sound then
		return
	end
	local previous = tweens[i]
	if previous then
		previous:Cancel()
	end
	local tween = TweenService:Create(
		sound,
		TweenInfo.new(Radio.FADE, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Volume = target }
	)
	tweens[i] = tween
	if stopAfter then
		tween.Completed:Once(function(state: Enum.PlaybackState)
			if state == Enum.PlaybackState.Completed and tweens[i] == tween then
				sound:Stop()
			end
		end)
	end
	tween:Play()
end

local playClock: () -> ()

local function ensureDeck(i: number): Sound
	local existing = decks[i]
	if existing and existing.Parent then
		return existing
	end
	local sound = Voices.loop2D("HC_Radio" .. i)
	sound.Looped = false
	sound.SoundGroup = Groups.get("music")
	-- Ended = played to the end (Stop() fires Stopped instead): the clock moves on to the next track
	sound.Ended:Connect(function()
		if playing and decks[deck] == sound then
			playClock()
		end
	end)
	decks[i] = sound
	return sound
end

-- Start the tuned station's current clock track on the idle deck, crossfading out the other one.
playClock = function()
	local st = stations[dial]
	if not (playing and st) then
		return
	end
	tuneToken += 1 -- supersedes any pending press
	local key, offset = Radio.clockTrack(dial, serverNow())
	local d = def(key)
	if not d then
		return
	end
	local from = deck
	local to = 3 - from
	fadeDeck(from, 0, true)
	local sound = ensureDeck(to)
	local running = tweens[to]
	if running then
		running:Cancel()
		tweens[to] = nil
	end
	deck = to
	token += 1
	local my = token
	local station = dial
	sound:Stop()
	sound.SoundGroup = Groups.get("music")
	sound.SoundId = d.id
	sound.PlaybackSpeed = d.pitch or 1
	sound.Volume = 0
	sound.TimePosition = offset
	sound:Play()
	fadeDeck(to, d.volume, false)
	title = (d :: any).title or key
	notify()
	-- once loaded: re-seek to the clock (the stream may have started at 0); never loaded: try again later
	task.spawn(function()
		local waited = 0
		while my == token and not sound.IsLoaded and waited < Radio.LOAD_TIMEOUT do
			waited += task.wait(0.25)
		end
		if my ~= token or not playing or dial ~= station then
			return
		end
		if not sound.IsLoaded then
			task.delay(8, function()
				if my == token and playing and dial == station then
					playClock()
				end
			end)
			return
		end
		local k, now = Radio.clockTrack(station, serverNow())
		if k == key and math.abs(sound.TimePosition - now) > Radio.RESYNC then
			sound.TimePosition = now
		end
	end)
end

-- Play or silence the decks to match (in a car, music on, a station tuned).
local function refresh()
	local want = inCar and musicOn and count > 0 and dial >= 1 and not isOff()
	if want == playing then
		return
	end
	playing = want
	if want then
		playClock()
	else
		token += 1
		for i in decks do
			fadeDeck(i, 0, true)
		end
		notify()
	end
end

local function staticBurst()
	local d = def("RadioStatic")
	if d then
		Voices.play2D("RadioStatic", d, Groups.get("vehicles"), Mix.PRIORITY.ui)
	end
	Groups.duck("retune", true, 0.35)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------------------------------------------------

-- fireRemote = Net.fire (SoundController passes it; nil in tests).
function Radio.setFire(fn: ((string, ...any) -> ())?)
	fire = fn
end

function Radio.stations(): { RadioDial.Station }
	return stations
end

function Radio.stationNames(): { string }
	local names = {}
	for _, st in stations do
		table.insert(names, st.name)
	end
	return names
end

-- VehicleClient: true while the local player drives `model` (nil = read it from VehicleClient, see SoundController).
function Radio.setInCar(on: boolean, model: Model?)
	if on == inCar and (not on or model == nil) then
		return
	end
	if on then
		local key: any = if model then model:GetAttribute("VehicleId") else nil
		if key == nil then
			key = model
		end
		carKey = key
		local carId = if model then model:GetAttribute("CarId") else nil
		local police = model ~= nil
			and EngineClass.isPolice(
				model:GetAttribute("Kind"),
				if typeof(carId) == "string" then Cars.get(carId) else nil
			)
		if model and not police then
			police = CollectionService:HasTag(model, "Police")
		end
		local start = RadioDial.startFor(memory, carKey, police == true, count, rand)
		if model ~= nil or dial < 1 then
			dial = start
		end
		inCar = true
	else
		RadioDial.remember(memory, carKey, dial)
		inCar = false
	end
	refresh()
	if not playing then
		notify()
	end
	publish()
	if on then
		-- the server may register us as the driver a moment after our seat event: say it again shortly
		task.delay(1.5, function()
			if inCar then
				published = nil
				publish()
			end
		end)
	end
end

-- Next (+1) / previous (-1) position (through RADIO OFF). The label retunes at once; in a car the station's track
-- crossfades in TUNE_DELAY after the last press.
function Radio.step(dir: number)
	if count == 0 then
		return
	end
	dial = RadioDial.step(dial, if typeof(dir) == "number" and dir < 0 then -1 else 1, count)
	title = nil
	RadioDial.remember(memory, carKey, dial)
	if not inCar then
		notify()
		return
	end
	staticBurst()
	local wasPlaying = playing
	if isOff() then
		if playing then
			refresh() -- stops the decks and tells the HUD
		else
			notify()
		end
		publish()
		return
	end
	if not wasPlaying then
		refresh() -- coming back from OFF
		if playing then
			publish()
			return
		end
	end
	-- silence the old station now; the new one starts after the debounce
	token += 1
	for i in decks do
		fadeDeck(i, 0, true)
	end
	notify()
	tuneToken += 1
	local tune = tuneToken
	task.delay(Radio.TUNE_DELAY, function()
		if tune == tuneToken then
			if playing then
				playClock()
			end
			publish() -- others hear the station even when this player's music setting is off
		end
	end)
end

-- (station name? (RADIO OFF when off), track title? (nil while silent), playing)
function Radio.get(): (string?, string?, boolean)
	return stationName(), if playing then title else nil, playing
end

function Radio.setMusic(on: boolean)
	musicOn = on
	refresh()
end

function Radio.isInCar(): boolean
	return inCar
end

-------------------------------------------------------------------------------------------------------------------------
-- Other cars' radios, heard muffled
-------------------------------------------------------------------------------------------------------------------------

local function ensureOutside()
	if #outside > 0 and outside[1].att.Parent then
		return
	end
	table.clear(outside)
	for i = 1, Radio.OUTSIDE_SLOTS do
		local att, s = Voices.loopAt("HC_RadioOut" .. i)
		s.Looped = false
		s.SoundGroup = Groups.get("music")
		s.RollOffMinDistance = 6
		s.RollOffMaxDistance = Radio.OUTSIDE_RANGE
		Apply.lowpass(s, true, -26, -9)
		local slot: Outside = { att = att, sound = s, car = nil, station = 0, key = nil, fade = 0, token = 0 }
		s.Ended:Connect(function()
			slot.key = nil -- the scan restarts it on the next clock track
		end)
		table.insert(outside, slot)
	end
end

local function startOutside(slot: Outside)
	local key, offset = Radio.clockTrack(slot.station, serverNow())
	local d = def(key)
	slot.key = key
	if not d then
		return
	end
	slot.token += 1
	local s = slot.sound
	s:Stop()
	s.SoundId = d.id
	s.Volume = 0
	s.TimePosition = offset
	s:Play()
end

-- 2 Hz: which nearby cars play a station (cars = Engines.cars(); localModel = our own car).
function Radio.scan(listener: Vector3, cars: { [Model]: any }, localModel: Model?)
	ensureOutside()
	local best1: any, d1 = nil, Radio.OUTSIDE_RANGE
	local best2: any, d2 = nil, Radio.OUTSIDE_RANGE
	if musicOn then
		for model, car in cars do
			if model ~= localModel and model.Parent then
				local name = model:GetAttribute("RadioStation")
				local c = car.chassis
				if typeof(name) == "string" and name ~= "" and c and c.Parent then
					local d = (c.Position - listener).Magnitude
					if d < d1 then
						best2, d2 = best1, d1
						best1, d1 = car, d
					elseif d < d2 then
						best2, d2 = car, d
					end
				end
			end
		end
	end
	for i, slot in outside do
		local want = if i == 1 then best1 else best2
		if slot.car ~= want then
			slot.car = want
			slot.key = nil
			slot.fade = 0
			slot.sound:Stop()
		end
		if want then
			local station = RadioDial.find(stations, want.model:GetAttribute("RadioStation")) or 0
			if station ~= slot.station then
				slot.station = station
				slot.key = nil
			end
			if station > 0 and slot.key == nil then
				startOutside(slot)
			end
		end
	end
end

function Radio.stepOutside(dt: number)
	for _, slot in outside do
		local car = slot.car
		local d = def(slot.key)
		if car and d and car.chassis and car.chassis.Parent then
			slot.att.WorldPosition = car.chassis.Position
			slot.fade = Mix.approach(slot.fade, 1, 1.5, dt)
			slot.sound.Volume = d.volume * Radio.OUTSIDE_GAIN * slot.fade
		elseif slot.sound.IsPlaying then
			slot.sound.Volume = 0
			slot.sound:Stop()
		end
	end
end

return Radio
