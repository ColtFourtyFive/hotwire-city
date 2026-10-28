--!strict
-- Police (PLAN C3 · audio): sirens, the wanted soundscape and the helicopter.
--
--  * Sirens: the SLOTS nearest sounding units (CollectionService tag "Police") within RANGE studs carry a looping
--    siren tone on a pooled emitter. A unit is silent while Siren == false (v1: leaving / wrecked) or SirenOn == false
--    (v2 traffic). The pattern comes from the unit's SirenMode attribute ("wail" | "yelp" | "hilo", "lights" = silent)
--    when the server sets one, else from a client-side Shared/Audio/Siren machine that switches wail / yelp / hi-lo
--    during a chase (more yelp and hi-lo when the unit is close and fast). PlaybackSpeed = tone x pattern sweep x a
--    manual Doppler factor from the unit's closing speed.
--  * Wanted (player attribute "Wanted", stars): a distant siren bed that steps aside when real units are close
--    (Siren.distantLevel), and dispatch-radio blips (squelch, static, beeps; never words) every few seconds, busier
--    with more stars (Siren.dispatchGap).
--  * Helicopter: models tagged "PoliceHeli" (v2 police) or "Helicopter": the HELIS nearest within HELI_RANGE get a
--    rotor loop that follows the model (PrimaryPart, else its "HeliCFrame" attribute, else its pivot), Doppler-shifted.
--    Nothing plays while no heli exists.
-- step() runs every frame and allocates nothing; scan() runs at 4 Hz.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Sounds = require(Shared:WaitForChild("Config"):WaitForChild("Sounds"))
local Siren = require(Shared:WaitForChild("Audio"):WaitForChild("Siren"))
local Mix = require(Shared:WaitForChild("Audio"):WaitForChild("Mix"))

local Apply = require(script.Parent:WaitForChild("Apply"))
local Groups = require(script.Parent:WaitForChild("Groups"))
local Voices = require(script.Parent:WaitForChild("Voices"))

local Police = {}

Police.SLOTS = 3
Police.RANGE = 320
Police.HELIS = 2
Police.HELI_RANGE = 900
Police.HELI_TAGS = { "PoliceHeli", "Helicopter" }
Police.FADE = 3 -- per second

type Def = Apply.Def
type Unit = { model: Model, st: Siren.State, prevPos: Vector3, hasPrev: boolean, vel: Vector3, chassis: BasePart? }
type Slot = { att: Attachment, sound: Sound, holder: Unit?, fade: number }
type Heli = { model: Model, prevPos: Vector3, hasPrev: boolean }
type HeliSlot = { att: Attachment, sound: Sound, holder: Heli?, fade: number }
type Cand = { key: any, dist: number }

local player = Players.LocalPlayer
local rng = Random.new()
local function rand(): number
	return rng:NextNumber()
end

local units: { [Model]: Unit } = {}
local helis: { [Model]: Heli } = {}
local slots: { Slot } = {}
local heliSlots: { HeliSlot } = {}
local cands: { Cand } = {}
local candPool: { Cand } = {}
local chosen: { [any]: boolean } = {}
local nearestUnit = math.huge
local distant: Sound? = nil
local distantVol = 0
local dispatchAt = 0
local DISPATCH =
	{ "Dispatch_Squelch1", "Dispatch_Squelch2", "Dispatch_Squelch3", "Dispatch_Static1", "Dispatch_Static2" }

local function def(key: string): Def?
	local d = (Sounds :: any)[key]
	return if typeof(d) == "table" then d :: Def else nil
end

local function chassisOf(model: Model): BasePart?
	local primary = model.PrimaryPart
	if primary then
		return primary
	end
	local c = model:FindFirstChild("Chassis")
	return if c and c:IsA("BasePart") then c else nil
end

-------------------------------------------------------------------------------------------------------------------------
-- Tracking
-------------------------------------------------------------------------------------------------------------------------

local function trackUnit(inst: Instance)
	if inst:IsA("Model") and not units[inst] then
		units[inst] = {
			model = inst,
			st = Siren.newState(rand),
			prevPos = Vector3.zero,
			hasPrev = false,
			vel = Vector3.zero,
			chassis = nil,
		}
	end
end

local function untrackUnit(inst: Instance)
	if inst:IsA("Model") then
		units[inst] = nil
	end
end

local function trackHeli(inst: Instance)
	if inst:IsA("Model") and not helis[inst] then
		helis[inst] = { model = inst, prevPos = Vector3.zero, hasPrev = false }
	end
end

local function untrackHeli(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	for _, tag in Police.HELI_TAGS do
		if CollectionService:HasTag(inst, tag) then
			return
		end
	end
	helis[inst] = nil
end

local function heliPosition(model: Model): Vector3
	local primary = model.PrimaryPart
	if primary then
		return primary.Position
	end
	local cf = model:GetAttribute("HeliCFrame")
	if typeof(cf) == "CFrame" then
		return cf.Position
	end
	return model:GetPivot().Position
end

-------------------------------------------------------------------------------------------------------------------------
-- Slots
-------------------------------------------------------------------------------------------------------------------------

local function ensureSlots()
	if #slots > 0 and slots[1].att.Parent then
		return
	end
	table.clear(slots)
	table.clear(heliSlots)
	local tone = def("Siren_Tone")
	for i = 1, Police.SLOTS do
		local att, s = Voices.loopAt("HC_Siren" .. i)
		if tone then
			Apply.def(s, tone, Groups.get("vehicles"))
			s.Looped = true
		end
		s.Volume = 0
		s.RollOffMinDistance = 25
		s.RollOffMaxDistance = Police.RANGE + 60
		table.insert(slots, { att = att, sound = s, holder = nil, fade = 0 })
	end
	local rotor = def("Heli_Rotor")
	for i = 1, Police.HELIS do
		local att, s = Voices.loopAt("HC_Heli" .. i)
		if rotor then
			Apply.def(s, rotor, Groups.get("vehicles"))
			s.Looped = true
		end
		s.Volume = 0
		s.RollOffMinDistance = 60
		s.RollOffMaxDistance = Police.HELI_RANGE
		table.insert(heliSlots, { att = att, sound = s, holder = nil, fade = 0 })
	end
	local bed = Voices.loop2D("HC_SirenDistant")
	local d = def("Siren_Distant")
	if d then
		Apply.def(bed, d, Groups.get("vehicles"))
		bed.Looped = true
		bed.Volume = 0
	end
	distant = bed
end

local function byDist(a: Cand, b: Cand): boolean
	return a.dist < b.dist
end

local function pickNearest(n: number, count: number)
	table.sort(cands, byDist)
	table.clear(chosen)
	for i = 1, math.min(count, n) do
		chosen[cands[i].key] = true
	end
end

local function addCand(n: number, key: any, dist: number): number
	n += 1
	local entry = candPool[n]
	if not entry then
		entry = { key = key, dist = dist }
		candPool[n] = entry
	end
	entry.key = key
	entry.dist = dist
	cands[n] = entry
	return n
end

-- Reassign a slot list to the chosen set (keep current holders).
local function distribute(list: { any }, start: (any, any) -> ())
	for _, slot in list do
		local h = slot.holder
		if h and not chosen[h] then
			slot.holder = nil
		end
	end
	for key in chosen do
		local has = false
		for _, slot in list do
			if slot.holder == key then
				has = true
				break
			end
		end
		if not has then
			for _, slot in list do
				if slot.holder == nil and slot.fade <= 0.001 then
					start(slot, key)
					break
				end
			end
		end
	end
end

local function startSiren(slot: any, unit: any)
	slot.holder = unit
	slot.fade = 0
	local u = unit :: Unit
	u.hasPrev = false
	local s = slot.sound :: Sound
	if not s.IsPlaying then
		local tone = def("Siren_Tone")
		s.TimePosition = if tone then Apply.startTime(tone) else 0
		s:Play()
	end
end

local function startHeli(slot: any, heli: any)
	local h: Heli = heli
	slot.holder = h
	slot.fade = 0
	h.hasPrev = false
	local s = slot.sound :: Sound
	if not s.IsPlaying then
		s:Play()
	end
end

function Police.scan(listener: Vector3, enabled: boolean)
	ensureSlots()
	-- sirens
	table.clear(cands)
	local n = 0
	nearestUnit = math.huge
	if enabled then
		for model, unit in units do
			if model.Parent == nil then
				units[model] = nil
				continue
			end
			if not Siren.isOn(model:GetAttribute("Siren"), model:GetAttribute("SirenOn")) then
				continue
			end
			local c = unit.chassis
			if not (c and c.Parent) then
				c = chassisOf(model)
				unit.chassis = c
			end
			if c then
				local dist = (c.Position - listener).Magnitude
				if dist < nearestUnit then
					nearestUnit = dist
				end
				if dist <= Police.RANGE then
					n = addCand(n, unit, dist)
				end
			end
		end
	end
	pickNearest(n, Police.SLOTS)
	distribute(slots, startSiren)

	-- helicopters
	table.clear(cands)
	n = 0
	if enabled then
		for model, heli in helis do
			if model.Parent == nil then
				helis[model] = nil
				continue
			end
			local dist = (heliPosition(model) - listener).Magnitude
			if dist <= Police.HELI_RANGE then
				n = addCand(n, heli, dist)
			end
		end
	end
	pickNearest(n, Police.HELIS)
	distribute(heliSlots, startHeli)
end

-------------------------------------------------------------------------------------------------------------------------
-- Per frame
-------------------------------------------------------------------------------------------------------------------------

local function stepSiren(slot: Slot, dt: number, listener: Vector3, lisVel: Vector3)
	local unit = slot.holder
	local target = 0
	local pos: Vector3? = nil
	if unit then
		local c = unit.chassis
		local model = unit.model
		if c and c.Parent and model.Parent then
			local p = c.Position
			pos = p
			local vel = if c.Anchored
				then (if unit.hasPrev and dt > 0 then (p - unit.prevPos) / dt else Vector3.zero)
				else c.AssemblyLinearVelocity
			unit.vel = vel
			unit.prevPos = p
			unit.hasPrev = true
			local known, attrPattern = Siren.fromAttr(model:GetAttribute("SirenMode"))
			local pattern: string?
			if known then
				unit.st.t += dt
				pattern = attrPattern
			else
				pattern = Siren.step(unit.st, dt, Siren.intensity((p - listener).Magnitude, vel.Magnitude), rand)
			end
			if pattern and Siren.isOn(model:GetAttribute("Siren"), model:GetAttribute("SirenOn")) then
				target = 1
				local tone = def("Siren_Tone")
				local doppler = Siren.doppler(Siren.closingSpeed(p, vel, listener, lisVel))
				slot.sound.PlaybackSpeed = (if tone then tone.pitch or 1 else 1)
					* Siren.pitchAt(pattern, unit.st.t)
					* doppler
			end
		else
			slot.holder = nil
		end
	end
	slot.fade = Mix.approach(slot.fade, target, Police.FADE, dt)
	local tone = def("Siren_Tone")
	slot.sound.Volume = (if tone then tone.volume else 0.5) * slot.fade
	if pos then
		slot.att.WorldPosition = pos
	end
	if slot.fade <= 0.001 and slot.sound.IsPlaying and not slot.holder then
		slot.sound:Stop()
	end
end

local function stepHeli(slot: HeliSlot, dt: number, listener: Vector3, lisVel: Vector3)
	local heli = slot.holder
	local target = 0
	if heli then
		local model = heli.model
		if model.Parent then
			local p = heliPosition(model)
			local vel = if heli.hasPrev and dt > 0 then (p - heli.prevPos) / dt else Vector3.zero
			heli.prevPos = p
			heli.hasPrev = true
			slot.att.WorldPosition = p
			target = 1
			local rotor = def("Heli_Rotor")
			slot.sound.PlaybackSpeed = (if rotor then rotor.pitch or 1 else 1)
				* Siren.doppler(Siren.closingSpeed(p, vel, listener, lisVel))
		else
			slot.holder = nil
		end
	end
	slot.fade = Mix.approach(slot.fade, target, 0.8, dt)
	local rotor = def("Heli_Rotor")
	slot.sound.Volume = (if rotor then rotor.volume else 0.7) * slot.fade
	if slot.fade <= 0.001 and slot.sound.IsPlaying and not slot.holder then
		slot.sound:Stop()
	end
end

local function stars(): number
	local w = if player then player:GetAttribute("Wanted") else nil
	return if typeof(w) == "number" then w else 0
end

local function stepWanted(dt: number, enabled: boolean, driving: boolean)
	local s = distant
	if not s then
		return
	end
	local level = if enabled then Siren.distantLevel(stars(), nearestUnit) else 0
	distantVol = Mix.approach(distantVol, level, 0.5, dt)
	local d = def("Siren_Distant")
	local v = (if d then d.volume else 1) * distantVol
	if v > 0.003 then
		if not s.IsPlaying then
			s:Play()
		end
		s.Volume = v
	elseif s.IsPlaying then
		s.Volume = 0
		s:Stop()
	end
	-- dispatch radio blips
	local st = stars()
	local now = os.clock()
	if not enabled or st <= 0 then
		dispatchAt = now + 2
		return
	end
	if now >= dispatchAt then
		dispatchAt = now + Siren.dispatchGap(st, rand)
		local key = DISPATCH[rng:NextInteger(1, #DISPATCH)]
		local dd = def(key)
		if dd then
			Voices.play2D(key, dd, Groups.get("vehicles"), Mix.PRIORITY.siren, if driving then 1 else 0.6)
		end
	end
end

function Police.step(dt: number, listener: Vector3, lisVel: Vector3, enabled: boolean, driving: boolean)
	for _, slot in slots do
		stepSiren(slot, dt, listener, lisVel)
	end
	for _, slot in heliSlots do
		stepHeli(slot, dt, listener, lisVel)
	end
	stepWanted(dt, enabled, driving)
end

function Police.start()
	ensureSlots()
	CollectionService:GetInstanceAddedSignal("Police"):Connect(trackUnit)
	CollectionService:GetInstanceRemovedSignal("Police"):Connect(untrackUnit)
	for _, inst in CollectionService:GetTagged("Police") do
		trackUnit(inst)
	end
	for _, tag in Police.HELI_TAGS do
		CollectionService:GetInstanceAddedSignal(tag):Connect(trackHeli)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrackHeli)
		for _, inst in CollectionService:GetTagged(tag) do
			trackHeli(inst)
		end
	end
end

-- (sounding units within range, helis tracked, wanted stars): debug.
function Police.stats(): (number, number, number)
	local h = 0
	for _ in helis do
		h += 1
	end
	local s = 0
	for _, slot in slots do
		if slot.holder then
			s += 1
		end
	end
	return s, h, stars()
end

return Police
