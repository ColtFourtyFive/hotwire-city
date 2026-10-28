--!strict
-- City (PLAN C3 · audio): the ambience of wherever the listener (the camera) is.
--
--  * Beds: the district under the listener (Config/WorldLayout.districtAt, WORLD_SPEC §4) picks a bed
--    (Shared/Audio/Ambience.DISTRICT_BEDS: downtown traffic hum + horns, beach waves + gulls, hills wind / birds by day
--    and crickets by night, industrial and port hum + clanks, desert air, suburbs, airport). Each bed has a day and a
--    night loop weighted by the lighting's NightFactor (Workspace attribute published by LightingService; Lighting
--    .ClockTime as a fallback), equal power. Two decks: a district change crossfades over Ambience.CROSSFADE seconds.
--  * Freeway roar: a third loop whose level follows the distance to the nearest freeway centreline
--    (Ambience.buildSegments over the WorldLayout freeway edges, built once on first use).
--  * One-shots: Ambience.ONESHOTS (distant sirens, dog barks, car alarms, planes, gulls, coyotes, clanks, train horns,
--    horns) with per-kind cooldowns and a global gap, played in 3D at a random bearing from the listener (overhead
--    planes and trains in 2D).
--  * Reverb: five rays straight up from the listener (every SCAN): a roof over every ray (a garage, a tunnel, a
--    parking structure) = ParkingLot, over most = Alley (under a freeway deck), else open air. A garage plot
--    (WorldQuery.plotAt) under a roof counts as a garage. Written to SoundService.AmbientReverb only on change.
--  * Ducks: the beds sit lower while the local player drives (the engine takes over) and under a roof.
-- Streaming-safe: nothing here looks for parts; only the camera, attributes and pure world data.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Sounds = require(Shared:WaitForChild("Config"):WaitForChild("Sounds"))
local Ambience = require(Shared:WaitForChild("Audio"):WaitForChild("Ambience"))
local Mix = require(Shared:WaitForChild("Audio"):WaitForChild("Mix"))

local Apply = require(script.Parent:WaitForChild("Apply"))
local Groups = require(script.Parent:WaitForChild("Groups"))
local Voices = require(script.Parent:WaitForChild("Voices"))

local City = {}

City.SCAN = 0.5 -- s between district / reverb / one-shot checks
City.RAYS = 5
City.RAY_UP = 140
City.RAY_SPREAD = 7
City.DRIVING_DUCK = 0.55
City.COVER_DUCK = 0.7

type Def = Apply.Def
type Deck = { day: Sound, night: Sound, dayDef: Def?, nightDef: Def?, bed: string?, fade: number, target: number }

local player = Players.LocalPlayer
local rng = Random.new()
local function rand(): number
	return rng:NextNumber()
end

local decks: { Deck } = {}
local current = 0 -- index of the deck playing the current bed
local freeway: Sound? = nil
local freewayLevel = 0
local freewayTarget = 0
local nightFactor = 0
local covered = 0 -- 0..1 share of up-rays that hit a roof
local reverbName = "NoReverb"
local scheduler: Ambience.Scheduler? = nil
local bed = Ambience.DEFAULT_BED
local district: string? = nil

-- World data (lazy: the layout builds on first require; pcall so a broken world never breaks audio)
local world: any = nil
local worldTried = false
local query: any = nil
local grid: Ambience.SegGrid? = nil
local rayParams: RaycastParams? = nil
local filter: { Instance } = {}

local function def(key: string): Def?
	local d = (Sounds :: any)[key]
	return if typeof(d) == "table" then d :: Def else nil
end

local function loadWorld()
	if worldTried then
		return
	end
	worldTried = true
	local config = Shared:FindFirstChild("Config")
	local util = Shared:FindFirstChild("Util")
	local ok, layout = pcall(function()
		return require((config :: Instance):FindFirstChild("WorldLayout") :: any)
	end)
	if ok and typeof(layout) == "table" then
		world = layout
		local okGrid, g = pcall(Ambience.buildSegments, layout.Edges or {}, nil, nil)
		if okGrid then
			grid = g
		end
	end
	local okQ, q = pcall(function()
		return require((util :: Instance):FindFirstChild("WorldQuery") :: any)
	end)
	if okQ and typeof(q) == "table" then
		query = q
	end
end

local function newDeck(i: number): Deck
	return {
		day = Voices.loop2D("HC_Bed" .. i .. "Day"),
		night = Voices.loop2D("HC_Bed" .. i .. "Night"),
		dayDef = nil,
		nightDef = nil,
		bed = nil,
		fade = 0,
		target = 0,
	}
end

local function ensure()
	if #decks > 0 and decks[1].day.Parent then
		return
	end
	table.clear(decks)
	decks[1] = newDeck(1)
	decks[2] = newDeck(2)
	current = 0
	local f = Voices.loop2D("HC_Freeway")
	local fd = def(Ambience.FREEWAY_KEY)
	if fd then
		Apply.def(f, fd, Groups.get("ambience"))
		f.Looped = true
		f.Volume = 0
	end
	freeway = f
end

local function loadDeck(deck: Deck, name: string)
	local keys = Ambience.KEYS[name] or Ambience.KEYS[Ambience.DEFAULT_BED]
	local group = Groups.get("ambience")
	deck.bed = name
	deck.dayDef = def(keys.day)
	deck.nightDef = def(keys.night)
	for _, pair in { { deck.day, deck.dayDef }, { deck.night, deck.nightDef } } do
		local s = pair[1] :: Sound
		local d = pair[2] :: Def?
		s:Stop()
		s.Volume = 0
		if d then
			Apply.def(s, d, group)
			s.Looped = true
			s.TimePosition = rng:NextNumber(0, 8) -- not always the same opening seconds
		end
	end
end

-- Switch to `name` (crossfade from the current deck).
local function setBed(name: string)
	local cur = decks[current]
	if cur and cur.bed == name then
		cur.target = 1
		return
	end
	local nextIndex = if current == 1 then 2 else 1
	local deck = decks[nextIndex]
	if cur then
		cur.target = 0
	end
	if deck.bed ~= name then
		loadDeck(deck, name)
		deck.fade = 0
	end
	deck.target = 1
	current = nextIndex
end

local function readNight(): number
	local nf = Workspace:GetAttribute("NightFactor")
	if typeof(nf) == "number" then
		return math.clamp(nf, 0, 1)
	end
	-- fallback: the engine clock (day 7-18, night 20-5, ramps between)
	local h = Lighting.ClockTime
	if h >= 7 and h <= 17.5 then
		return 0
	elseif h >= 20 or h <= 5 then
		return 1
	elseif h > 17.5 then
		return (h - 17.5) / 2.5
	end
	return (7 - h) / 2
end

local function sampleCover(listener: Vector3, carModel: Model?): number
	local params = rayParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		rayParams = params
	end
	local p = params :: RaycastParams
	table.clear(filter)
	local holder = Workspace:FindFirstChild("HC_ClientSounds")
	if holder then
		table.insert(filter, holder)
	end
	local char = player and player.Character
	if char then
		table.insert(filter, char)
	end
	if carModel then
		table.insert(filter, carModel)
	end
	p.FilterDescendantsInstances = filter
	local up = Vector3.new(0, City.RAY_UP, 0)
	local s = City.RAY_SPREAD
	local hits = 0
	for i = 1, City.RAYS do
		local off = if i == 1
			then Vector3.zero
			elseif i == 2 then Vector3.new(s, 0, 0)
			elseif i == 3 then Vector3.new(-s, 0, 0)
			elseif i == 4 then Vector3.new(0, 0, s)
			else Vector3.new(0, 0, -s)
		if Workspace:Raycast(listener + off + Vector3.new(0, 1.5, 0), up, p) then
			hits += 1
		end
	end
	return hits
end

local function playOneShot(key: string, dist: number, listener: Vector3)
	local d = def(key)
	if not d then
		return
	end
	local group = Groups.get("ambience")
	if dist <= 0 then
		Voices.play2D(key, d, group, Mix.PRIORITY.ambient)
		return
	end
	local a = rng:NextNumber(0, 2 * math.pi)
	local at = listener + Vector3.new(math.cos(a) * dist, 12, math.sin(a) * dist)
	Voices.playAt(d, at, group, Mix.PRIORITY.ambient, 1, false, true, dist * 2.4)
end

-- Load the world data off the render path (the layout may be building on first require).
function City.start()
	ensure()
	task.spawn(loadWorld)
end

-- 2 Hz: district, night factor, freeway distance, reverb, one-shots.
function City.scan(listener: Vector3, enabled: boolean, carModel: Model?)
	ensure()
	if not enabled then
		for _, deck in decks do
			deck.target = 0
		end
		freewayTarget = 0
		return
	end
	-- district -> bed
	if world and typeof(world.districtAt) == "function" then
		local ok, id = pcall(world.districtAt, listener.X, listener.Z)
		if ok then
			district = id
		end
	end
	bed = Ambience.bedFor(district)
	setBed(bed)
	nightFactor = readNight()
	-- freeway roar
	local g = grid
	if g then
		local d = Ambience.nearestDistance(g, listener.X, listener.Z, Ambience.FREEWAY_FAR)
		freewayTarget = Ambience.freewayLevel(d)
	end
	-- cover reverb
	local hits = sampleCover(listener, carModel)
	covered = hits / City.RAYS
	local inGarage = false
	if hits >= 3 and query and typeof(query.plotAt) == "function" then
		local ok, plot = pcall(query.plotAt, listener)
		inGarage = ok and plot ~= nil
	end
	local name = Mix.reverbFor(hits, City.RAYS, false, inGarage)
	if name ~= reverbName then
		reverbName = name
		local ok, enum = pcall(function()
			return (Enum.ReverbType :: any)[name]
		end)
		if ok and enum then
			SoundService.AmbientReverb = enum
		end
	end
	-- one-shots
	local now = os.clock()
	local s = scheduler
	if not s then
		s = Ambience.newScheduler(now, rand)
		scheduler = s
	end
	local key, dist = Ambience.pickOneShot(s :: Ambience.Scheduler, now, bed, Ambience.isNight(nightFactor), rand)
	if key then
		playOneShot(key, dist, listener)
	end
end

local function drive(s: Sound, d: Def?, level: number)
	local v = if d then d.volume * level else 0
	if v > 0.003 then
		if not s.IsPlaying then
			s:Play()
		end
		s.Volume = v
	elseif s.IsPlaying then
		s.Volume = 0
		s:Stop()
	end
end

function City.step(dt: number, driving: boolean)
	if #decks == 0 then
		return
	end
	local dayW, nightW = Ambience.dayNight(nightFactor)
	local duck = (if driving then City.DRIVING_DUCK else 1) * (1 - (1 - City.COVER_DUCK) * covered)
	local rate = 1 / Ambience.CROSSFADE
	for _, deck in decks do
		deck.fade = Mix.approach(deck.fade, deck.target, rate, dt)
		-- equal-power crossfade between decks
		local w = math.sin(deck.fade * math.pi / 2) * duck
		drive(deck.day, deck.dayDef, w * dayW)
		drive(deck.night, deck.nightDef, w * nightW)
	end
	freewayLevel = Mix.approach(freewayLevel, freewayTarget, 0.6, dt)
	local f = freeway
	if f then
		drive(f, def(Ambience.FREEWAY_KEY), freewayLevel * (if driving then 0.7 else 1))
	end
end

-- (district id, bed, night factor, reverb preset): debug.
function City.state(): (string?, string, number, string)
	return district, bed, nightFactor, reverbName
end

return City
