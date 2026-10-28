--!strict
-- Engines (PLAN C3 · audio): other players' and traffic cars, heard in 3D on a hard budget.
--
--  * Registry: every model tagged "Vehicle", "Traffic" (v2 kinematic traffic) or "Police", tracked as it streams in
--    and dropped when it streams out (no Workspace scans). Engine set per car from Audio/EngineClass (the model's
--    EngineClass attribute, police, the catalog class / style, else sedan), re-read when its CarId changes.
--  * Budget: every SCAN seconds the SLOTS nearest running cars within EngineModel.MAX_RANGE (250 studs) hold an
--    engine slot (three pooled loops on one emitter). LOD by distance every frame: idle / on-load / off-load layers
--    up close, crossfading over EngineModel.FAR_FROM..FAR_TO (50..75 studs) into the single dominant layer at its own
--    pitch (EngineModel.remoteLayers), nothing past MAX_RANGE. Layer volumes are smoothed; a layer that reaches
--    silence is stopped (no silent streams) and restarted at a random point of its loop when it is needed again.
--  * Each held car runs its own EngineModel: speed from the "Speed" attribute (v2 traffic), else the chassis velocity
--    (physics cars) or the position change (anchored / kinematic cars); throttle from the "Throttle" attribute, else
--    guessed from acceleration (EngineModel.inferThrottle). Pitch carries a manual Doppler shift from the closing
--    speed (SoundService.DopplerScale is 0: SoundController owns Doppler so the local car never wobbles).
--  * Physics cars that lose speed suddenly crash audibly (Mix.suddenDrop -> LocalCar.impact) when close.
--  * Tyre squeal for WheelAnimator: playLoop("TireScreech", chassis) hands out one of SQUEALS pooled loops that follows
--    that chassis and is levelled by its lateral slip (Mix.squealLevel); stopLoop returns it. A squeal whose chassis
--    vanished is muted but stays reserved (orphan) until its owner's stopLoop, so one Sound never has two owners.
--  * Horns: hornNear(position) names the class horn of the car at `position` and that car's chassis, so the horn can
--    follow the car (Voices.follow).
-- step() runs every frame and allocates nothing; scan() runs at 4 Hz and reuses its buffers.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioShared = Shared:WaitForChild("Audio")
local Sounds = require(Shared:WaitForChild("Config"):WaitForChild("Sounds"))
local Cars = require(Shared:WaitForChild("Config"):WaitForChild("Cars"))
local EngineModel = require(AudioShared:WaitForChild("EngineModel"))
local EngineClass = require(AudioShared:WaitForChild("EngineClass"))
local Mix = require(AudioShared:WaitForChild("Mix"))
local Siren = require(AudioShared:WaitForChild("Siren"))

local Apply = require(script.Parent:WaitForChild("Apply"))
local Groups = require(script.Parent:WaitForChild("Groups"))
local Voices = require(script.Parent:WaitForChild("Voices"))
local LocalCar = require(script.Parent:WaitForChild("LocalCar"))

local Engines = {}

Engines.TAGS = { "Vehicle", "Traffic", "Police" }
Engines.SLOTS = 6
Engines.SQUEALS = 4
Engines.ORPHAN_TIMEOUT = 10 -- s an orphaned squeal stays reserved for its owner's stopLoop
Engines.HORN_RADIUS = 16 -- a horn played within this of a car uses that car's class horn
Engines.IMPACT_RANGE = 220
Engines.DEFAULT_TOP_SPEED = 100

type Def = Apply.Def

export type Car = {
	model: Model,
	chassis: BasePart?,
	seat: VehicleSeat?,
	carId: any,
	kind: any,
	set: string,
	topSpeed: number,
	police: boolean,
	traffic: boolean,
	prevPos: Vector3,
	hasPrev: boolean,
	speed: number,
	prevSpeed: number,
	rawPrev: number,
	thr: number,
	recentMax: number,
	vel: Vector3,
}

type Layer = { sound: Sound, def: Def?, vol: number }
type Slot = {
	att: Attachment,
	idle: Layer,
	on: Layer,
	off: Layer,
	set: string?,
	holder: Car?,
	st: EngineModel.State,
	mix: EngineModel.Mix,
	fade: number,
	leaving: boolean, -- fading out before the slot is freed (no clicks when a car drops out of the budget)
}
type Squeal = { att: Attachment, sound: Sound, chassis: BasePart?, vol: number, orphan: boolean, orphanAt: number }
type Cand = { key: any, dist: number }

local cars: { [Model]: Car } = {}
local slots: { Slot } = {}
local squeals: { Squeal } = {}
local cands: { Cand } = {}
local candPool: { Cand } = {}
local chosen: { [any]: boolean } = {}
local held: { [Car]: boolean } = {}
local rng = Random.new()
local scanNo = 0

-------------------------------------------------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------------------------------------------------

-- Top speed for a car model's attributes (Config/Cars; police = Cars.Police).
function Engines.topSpeedFor(carId: any, kind: any): number
	local police = (Cars :: any).Police
	if police and (kind == "Police" or carId == police.id) then
		return police.topSpeed
	end
	if typeof(carId) == "string" then
		local def = Cars.get(carId)
		if def then
			return def.topSpeed
		end
	end
	return Engines.DEFAULT_TOP_SPEED
end

-- The chassis (cheap; every scan for cars without one yet).
local function resolveChassis(car: Car): BasePart?
	local c = car.chassis
	if c and c.Parent then
		return c
	end
	local model = car.model
	local primary = model.PrimaryPart or model:FindFirstChild("Chassis")
	car.chassis = if primary and primary:IsA("BasePart") then primary else nil
	return car.chassis
end

-- Seat, engine set and flags (only for cars near enough to matter; the recursive seat search runs once per car
-- identity, not every scan: traffic bodies have no DriverSeat).
local function resolve(car: Car)
	local model = car.model
	local carId = model:GetAttribute("CarId")
	local kind = model:GetAttribute("Kind")
	local changed = carId ~= car.carId or kind ~= car.kind
	if changed then
		car.carId = carId
		car.kind = kind
		local def = if typeof(carId) == "string" then Cars.get(carId) else nil
		car.police = EngineClass.isPolice(kind, def) or CollectionService:HasTag(model, "Police")
		car.set = EngineClass.resolve(model:GetAttribute("EngineClass"), if car.police then "Police" else kind, def)
		car.topSpeed = Engines.topSpeedFor(carId, kind)
	end
	local s = car.seat
	-- (a missing seat is looked for again every 20th scan: it may stream in after the model)
	if changed or (s ~= nil and s.Parent == nil) or (s == nil and scanNo % 20 == 0) then
		local seat = model:FindFirstChild("DriverSeat", true)
		car.seat = if seat and seat:IsA("VehicleSeat") then seat else nil
	end
	car.traffic = CollectionService:HasTag(model, "Traffic")
end

local function track(inst: Instance)
	if not inst:IsA("Model") or cars[inst] then
		return
	end
	local car: Car = {
		model = inst,
		chassis = nil,
		seat = nil,
		carId = false,
		kind = false,
		set = EngineClass.DEFAULT,
		topSpeed = Engines.DEFAULT_TOP_SPEED,
		police = false,
		traffic = false,
		prevPos = Vector3.zero,
		hasPrev = false,
		speed = 0,
		prevSpeed = 0,
		rawPrev = 0,
		thr = 0,
		recentMax = 0,
		vel = Vector3.zero,
	}
	cars[inst] = car
	resolveChassis(car)
	resolve(car)
end

local function untrack(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	for _, tag in Engines.TAGS do
		if CollectionService:HasTag(inst, tag) then
			return -- still tagged (e.g. a police car is also a Vehicle)
		end
	end
	cars[inst] = nil
end

-- The tracked cars (read-only; Radio scans it for cars playing a station).
function Engines.cars(): { [Model]: Car }
	return cars
end

local function hasDriver(car: Car): boolean
	local seat = car.seat
	if seat and seat.Occupant ~= nil then
		return true
	end
	local driverId = car.model:GetAttribute("DriverUserId")
	return typeof(driverId) == "number" and driverId > 0
end

-- The class horn for a horn played at `position` (the nearest car within HORN_RADIUS) and that car's chassis (the
-- horn follows it), else nil.
function Engines.hornNear(position: Vector3): (string?, BasePart?)
	local localModel = LocalCar.getModel()
	local best, bestD = nil :: string?, Engines.HORN_RADIUS
	local part: BasePart? = nil
	if localModel then
		local primary = localModel.PrimaryPart
		if primary then
			local d = (primary.Position - position).Magnitude
			if d <= bestD then
				best, bestD, part = EngineClass.hornFor(LocalCar.getEngineSet()), d, primary
			end
		end
	end
	for _, car in cars do
		local c = car.chassis
		if c and c.Parent then
			local d = (c.Position - position).Magnitude
			if d < bestD then
				best, bestD, part = EngineClass.hornFor(car.set), d, c
			end
		end
	end
	return best, part
end

-------------------------------------------------------------------------------------------------------------------------
-- Slots
-------------------------------------------------------------------------------------------------------------------------

local function newLayer(att: Attachment, name: string): Layer
	local s = Instance.new("Sound")
	s.Name = name
	s.Looped = true
	s.Volume = 0
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 12
	s.RollOffMaxDistance = EngineModel.MAX_RANGE
	s.Parent = att
	Voices.registerLoop(s)
	return { sound = s, def = nil, vol = 0 }
end

local function ensureSlots()
	if #slots > 0 and slots[1].att.Parent then
		return
	end
	table.clear(slots)
	for i = 1, Engines.SLOTS do
		local att = Voices.emitter("HC_Engine" .. i)
		local p = EngineModel.profileFor(EngineClass.DEFAULT)
		table.insert(slots, {
			att = att,
			idle = newLayer(att, "Idle"),
			on = newLayer(att, "On"),
			off = newLayer(att, "Off"),
			set = nil,
			holder = nil,
			st = EngineModel.newState(p),
			mix = EngineModel.newMix(),
			fade = 0,
			leaving = false,
		})
	end
end

local function point(layer: Layer, key: string)
	local d = (Sounds :: any)[key]
	layer.def = if typeof(d) == "table" then d :: Def else nil
	if layer.def then
		Apply.def(layer.sound, layer.def :: Def, Groups.get("vehicles"))
		layer.sound.Looped = true
		layer.sound.RollOffMaxDistance = EngineModel.MAX_RANGE
	end
	layer.sound.Volume = 0
	layer.vol = 0
end

local function stopLayer(layer: Layer)
	layer.vol = 0
	layer.sound.Volume = 0
	if layer.sound.IsPlaying then
		layer.sound:Stop()
	end
end

local function release(slot: Slot)
	slot.holder = nil
	stopLayer(slot.idle)
	stopLayer(slot.on)
	stopLayer(slot.off)
end

local function assign(slot: Slot, car: Car)
	if slot.set ~= car.set then
		local keys = EngineClass.keysFor(car.set)
		point(slot.idle, keys.idle)
		point(slot.on, keys.on)
		point(slot.off, keys.off)
		slot.set = car.set
	end
	EngineModel.reset(slot.st, EngineModel.profileFor(car.set))
	slot.holder = car
	slot.fade = 0
	slot.leaving = false
	car.hasPrev = false
	car.recentMax = 0 -- a stale peak from an earlier hold would read as a crash
	-- layers start in stepSlot when their level rises above silence
	stopLayer(slot.idle)
	stopLayer(slot.on)
	stopLayer(slot.off)
end

local function byDist(a: Cand, b: Cand): boolean
	return a.dist < b.dist
end

-- Re-pick the SLOTS nearest running cars (4 Hz). localModel = the car the local player drives (LocalCar has it).
function Engines.scan(listener: Vector3, enabled: boolean)
	ensureSlots()
	if not enabled then
		for _, slot in slots do
			if slot.holder then
				release(slot)
			end
		end
		-- engines are off, but Radio still needs the chassis of cars that stream in meanwhile (muffled radios)
		for model, car in cars do
			if model.Parent == nil then
				cars[model] = nil
			else
				resolveChassis(car)
			end
		end
		return
	end
	local localModel = LocalCar.getModel()
	scanNo += 1
	table.clear(cands)
	local n = 0
	for model, car in cars do
		if model.Parent == nil then
			cars[model] = nil
			continue
		end
		if model == localModel then
			continue
		end
		local c = resolveChassis(car)
		local dist = if c then (c.Position - listener).Magnitude else math.huge
		if dist <= EngineModel.MAX_RANGE then
			resolve(car)
			if car.traffic or EngineClass.isEngineEligible(car.kind, hasDriver(car)) then
				n += 1
				local entry = candPool[n]
				if not entry then
					entry = { key = car, dist = dist }
					candPool[n] = entry
				end
				entry.key = car
				entry.dist = dist
				cands[n] = entry
			end
		end
	end
	table.sort(cands, byDist)
	table.clear(chosen)
	for i = 1, math.min(Engines.SLOTS, n) do
		chosen[cands[i].key] = true
	end
	-- keep current holders that are still chosen
	table.clear(held)
	for _, slot in slots do
		local car = slot.holder
		if car then
			if not (car.chassis and car.chassis.Parent) then
				release(slot)
			elseif chosen[car] then
				held[car] = true
				slot.leaving = false
			else
				slot.leaving = true -- stepSlot fades it out, then frees it
			end
		end
	end
	for car in chosen do
		if not held[car] then
			for _, slot in slots do
				if slot.holder == nil then
					assign(slot, car :: Car)
					break
				end
			end
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Per frame
-------------------------------------------------------------------------------------------------------------------------

Engines.LAYER_RESPONSE = 6 -- per second: layer volume smoothing (LOD crossfades, dominant-layer swaps far away)

-- Drive one layer toward `target` (share of its def volume) at `pitch`: started when it rises above silence (at a
-- random point of its loop: identical loops never phase), stopped when it reaches silence.
local function setLayer(layer: Layer, target: number, pitch: number, dt: number)
	local d = layer.def
	if not d then
		return
	end
	layer.vol = Mix.approach(layer.vol, target, Engines.LAYER_RESPONSE, dt)
	local s = layer.sound
	if layer.vol > 0.002 then
		if not s.IsPlaying then
			s.TimePosition = Apply.startTime(d) + rng:NextNumber(0, 1)
			s:Play()
		end
		s.Volume = d.volume * layer.vol
		s.PlaybackSpeed = (d.pitch or 1) * pitch
	elseif s.IsPlaying then
		layer.vol = 0
		s.Volume = 0
		s:Stop()
	end
end

local function stepSlot(slot: Slot, car: Car, dt: number, listener: Vector3, lisVel: Vector3)
	local c = car.chassis :: BasePart
	local model = car.model
	local pos = c.Position
	local vel: Vector3
	if c.Anchored then
		vel = if car.hasPrev and dt > 0 then (pos - car.prevPos) / dt else Vector3.zero
	else
		vel = c.AssemblyLinearVelocity
	end
	car.vel = vel
	local attrSpeed = model:GetAttribute("Speed")
	local raw = if typeof(attrSpeed) == "number" then attrSpeed else vel.Magnitude
	car.speed += (raw - car.speed) * math.min(1, dt * 8)

	-- crash (physics cars only: kinematic poses jump at 10 Hz)
	if not c.Anchored then
		local crashed, drop, peak = Mix.suddenDrop(car.recentMax, raw, dt)
		car.recentMax = peak
		if crashed and (pos - listener).Magnitude <= Engines.IMPACT_RANGE then
			LocalCar.impact(drop, pos, Mix.PRIORITY.world)
		end
	end

	local attrThr = model:GetAttribute("Throttle")
	local thr = if typeof(attrThr) == "number" then attrThr else EngineModel.inferThrottle(car.prevSpeed, car.speed, dt)
	car.thr += (thr - car.thr) * math.min(1, dt * 4)
	car.prevSpeed = car.speed

	local p = EngineModel.profileFor(car.set)
	EngineModel.step(slot.st, p, dt, car.speed / math.max(car.topSpeed, 1), car.thr, true, false)
	local m = EngineModel.mix(slot.st, p, slot.mix)
	local dist = (pos - listener).Magnitude
	local doppler = Siren.doppler(Siren.closingSpeed(pos, vel, listener, lisVel))
	if slot.leaving then
		slot.fade = math.max(0, slot.fade - dt * 4)
	else
		slot.fade = math.min(1, slot.fade + dt * 2)
	end
	-- three layers close, crossfading into the dominant one far away; silence past MAX_RANGE
	local g = if EngineModel.lod(dist) > 0 then m.gain * slot.fade else 0
	local idle, on, off = EngineModel.remoteLayers(m, EngineModel.farBlend(dist))
	setLayer(slot.idle, idle * g, m.idlePitch * doppler, dt)
	setLayer(slot.on, on * g, m.onPitch * doppler, dt)
	setLayer(slot.off, off * g, m.offPitch * doppler, dt)
	if
		slot.leaving
		and slot.fade <= 0
		and not (slot.idle.sound.IsPlaying or slot.on.sound.IsPlaying or slot.off.sound.IsPlaying)
	then
		release(slot) -- faded all the way out: free the slot without a click
		return
	end
	slot.att.WorldPosition = pos
	car.prevPos = pos
	car.hasPrev = true
end

local function stepSqueals(dt: number)
	for _, sq in squeals do
		local c = sq.chassis
		if sq.orphan then
			if os.clock() - sq.orphanAt > Engines.ORPHAN_TIMEOUT then
				sq.orphan = false -- its owner never called stopLoop (it went away with the car): reuse it
				sq.chassis = nil
			end
		elseif c then
			if c.Parent == nil then
				-- the car is gone but WheelAnimator still holds this Sound until its stopLoop: mute it and keep the
				-- slot reserved, so it is never handed to a second owner (releaseLoop frees it)
				sq.orphan = true
				sq.orphanAt = os.clock()
				sq.vol = 0
				sq.sound.Volume = 0
				sq.sound:Stop()
			else
				local vel = c.AssemblyLinearVelocity
				local lateral = vel:Dot(c.CFrame.RightVector)
				local target = Mix.squealLevel(lateral, true, true)
				sq.vol = Mix.approach(sq.vol, target, 8, dt)
				local d = Sounds.TireScreech
				sq.sound.Volume = (if d then d.volume else 0.3) * sq.vol
				sq.att.WorldPosition = c.Position
			end
		end
	end
end

function Engines.step(dt: number, listener: Vector3, lisVel: Vector3)
	for _, slot in slots do
		local car = slot.holder
		if car then
			local c = car.chassis
			if c and c.Parent and car.model.Parent then
				stepSlot(slot, car, dt, listener, lisVel)
			else
				release(slot)
			end
		end
	end
	stepSqueals(dt)
end

-------------------------------------------------------------------------------------------------------------------------
-- Tyre squeal loops for WheelAnimator (SoundController.playLoop("TireScreech", chassis) / stopLoop)
-------------------------------------------------------------------------------------------------------------------------

function Engines.squealLoop(chassis: Instance?): Sound?
	if not (chassis and chassis:IsA("BasePart")) then
		return nil
	end
	if chassis == (LocalCar.getModel() and (LocalCar.getModel() :: Model).PrimaryPart) then
		return nil -- our own car squeals through LocalCar (lateral slip, not just drifts)
	end
	local free: Squeal? = nil
	for _, sq in squeals do
		if sq.chassis == nil and not sq.orphan and sq.att.Parent then
			free = sq
			break
		end
	end
	if not free and #squeals < Engines.SQUEALS then
		local att, s = Voices.loopAt("HC_Squeal" .. (#squeals + 1))
		local d = Sounds.TireScreech
		if d then
			Apply.def(s, d, Groups.get("vehicles"))
			s.Looped = true
		end
		s.RollOffMaxDistance = 220
		free = { att = att, sound = s, chassis = nil, vol = 0, orphan = false, orphanAt = 0 }
		table.insert(squeals, free :: Squeal)
	end
	if not free then
		return nil
	end
	local sq = free :: Squeal
	sq.chassis = chassis
	sq.orphan = false
	sq.vol = 0
	sq.sound.Volume = 0
	sq.att.WorldPosition = chassis.Position
	local d = Sounds.TireScreech
	sq.sound.TimePosition = (if d then Apply.startTime(d :: any) else 0) + rng:NextNumber(0, 1)
	sq.sound:Play()
	return sq.sound
end

-- true when `sound` was one of ours (returned to the pool).
function Engines.releaseLoop(sound: Sound): boolean
	for _, sq in squeals do
		if sq.sound == sound then
			sq.chassis = nil
			sq.orphan = false
			sq.vol = 0
			sound.Volume = 0
			sound:Stop()
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function Engines.start()
	ensureSlots()
	for _, tag in Engines.TAGS do
		CollectionService:GetInstanceAddedSignal(tag):Connect(track)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
		for _, inst in CollectionService:GetTagged(tag) do
			track(inst)
		end
	end
end

-- (cars tracked, slots holding a car): debug / tests.
function Engines.stats(): (number, number)
	local n, h = 0, 0
	for _ in cars do
		n += 1
	end
	for _, slot in slots do
		if slot.holder then
			h += 1
		end
	end
	return n, h
end

return Engines
