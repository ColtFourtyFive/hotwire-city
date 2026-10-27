--!strict
-- SoundController (SPEC §7): every sound the client hears.
--
--  * play(key, position?) — one-shot Config/Sounds sound. No position = UI sound (pooled Sounds in SoundService);
--    with a position = world sound (pooled Attachments on an anchored, invisible part in Workspace.HC_ClientSounds).
--    Small random pitch variation on one-shots so repeated sounds don't fatigue. Returns the Sound (or nil).
--  * playLoop(key, parent?) / stopLoop(sound) — owned looping sounds (e.g. the stolen-car alarm). The caller stops it.
--  * `Sound` remote (soundKey, worldPosition?) -> play.
--  * Engine loop: the ≤ 6 closest "Vehicle"-tagged cars that are actually being driven (a seated driver, or AI-driven
--    Traffic/Police) get a looping engine Sound in their chassis, PlaybackSpeed = 0.7 + 1.1 × speed / topSpeed
--    (topSpeed from Config/Cars by the CarId attribute, Cars.Police for police), smoothed per frame.
--  * Police sirens: the ≤ 3 closest "Police"-tagged cars within 250 studs carry a looping siren (skipped while the
--    server marks the unit Siren=false: leaving or wrecked).
--  * City ambience loop at low volume (ducked while driving).
--  * Settings: snapshot settings.sfx / settings.music drive two SoundGroups (HC_SFX, HC_Music); ambience counts as
--    "music". setEnabled / setVolume let other controllers (e.g. Settings menu previews) override locally.
--  * start(): ContentProvider:PreloadAsync of every Config/Sounds id (pcall, background).

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Sounds = require(Config:WaitForChild("Sounds"))
local Cars = require(Config:WaitForChild("Cars"))

-- Earlier in the client ORDER, so a direct require is safe (no cycle).
local StateController = require(script.Parent:WaitForChild("StateController"))

local SoundController = {}

local player = Players.LocalPlayer
local rng = Random.new()

local UI_POOL_PER_KEY = 4 -- max simultaneous copies of one UI sound
local WORLD_POOL_SIZE = 20 -- max simultaneous positional one-shots
local WORLD_CULL_DISTANCE = 450 -- skip positional one-shots farther than this from the camera
local ENGINE_SLOTS = 6
local ENGINE_RANGE = 220
local SIREN_SLOTS = 3
local SIREN_RANGE = 250
local SCAN_INTERVAL = 0.25
local PITCH_SMOOTHING = 7 -- per second
local AMBIENCE_VOLUME_SCALE = 0.6
local AMBIENCE_DRIVING_DUCK = 0.45
local DEFAULT_TOP_SPEED = 100

-- Kinds whose cars sit still (anchored displays / unclaimed) and never get an engine loop.
local SILENT_KINDS: { [string]: boolean } = { Parked = true, Dealership = true, HotDrop = true }
-- AI-driven kinds that have no seated player but still drive around.
local AI_KINDS: { [string]: boolean } = { Traffic = true, Police = true }

type SoundDef = Sounds.SoundDef

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

-- Engine PlaybackSpeed for a car going `speed` with top speed `topSpeed`. Ratio clamped to [0, 1.3] (nitro overshoot).
function SoundController.enginePitch(speed: number, topSpeed: number): number
	local top = if topSpeed > 1 then topSpeed else DEFAULT_TOP_SPEED
	local ratio = math.clamp(speed / top, 0, 1.3)
	return 0.7 + 1.1 * ratio
end

-- Does a car with this Kind / driver state make engine noise?
function SoundController.isEngineEligible(kind: any, hasDriver: boolean): boolean
	if typeof(kind) ~= "string" then
		return hasDriver
	end
	if SILENT_KINDS[kind] then
		return false
	end
	return hasDriver or AI_KINDS[kind] == true
end

-- Top speed for a car model's attributes.
function SoundController.topSpeedFor(carId: any, kind: any): number
	if kind == "Police" or carId == Cars.Police.id then
		return Cars.Police.topSpeed
	end
	if typeof(carId) == "string" then
		local def = Cars.get(carId)
		if def then
			return def.topSpeed
		end
	end
	return DEFAULT_TOP_SPEED
end

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

-------------------------------------------------------------------------------------------------------------------------
-- Groups, folders, settings
-------------------------------------------------------------------------------------------------------------------------

local sfxGroup: SoundGroup? = nil
local musicGroup: SoundGroup? = nil
local uiFolder: Folder? = nil
local worldAnchor: Part? = nil
local enabled = { sfx = true, music = true }
local volumes = { sfx = 1, music = 1 }

type PoolEntry = { sound: Sound, startedAt: number }
type WorldEntry = { attachment: Attachment, sound: Sound, startedAt: number }

local uiPools: { [string]: { PoolEntry } } = {}
local worldPool: { WorldEntry } = {}

local function ensureGroups()
	if sfxGroup and sfxGroup.Parent and musicGroup and musicGroup.Parent then
		return
	end
	local sfx = SoundService:FindFirstChild("HC_SFX")
	if not (sfx and sfx:IsA("SoundGroup")) then
		sfx = Instance.new("SoundGroup")
		sfx.Name = "HC_SFX"
		sfx.Parent = SoundService
	end
	local music = SoundService:FindFirstChild("HC_Music")
	if not (music and music:IsA("SoundGroup")) then
		music = Instance.new("SoundGroup")
		music.Name = "HC_Music"
		music.Parent = SoundService
	end
	sfxGroup = sfx :: SoundGroup
	musicGroup = music :: SoundGroup
	local folder = SoundService:FindFirstChild("HC_UISounds")
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = "HC_UISounds"
		folder.Parent = SoundService
		table.clear(uiPools) -- any pooled Sounds died with the old folder
	end
	uiFolder = folder :: Folder
end

local function ensureWorldAnchor(): Part
	local anchor = worldAnchor
	if anchor and anchor.Parent then
		return anchor
	end
	local folder = Workspace:FindFirstChild("HC_ClientSounds")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "HC_ClientSounds"
		folder.Parent = Workspace
	end
	local part = Instance.new("Part")
	part.Name = "SoundAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new()
	part.Parent = folder
	worldAnchor = part
	table.clear(worldPool) -- pooled emitters died with the old anchor
	return part
end

local function applyGroupVolumes()
	ensureGroups()
	local sfx = sfxGroup :: SoundGroup
	local music = musicGroup :: SoundGroup
	sfx.Volume = if enabled.sfx then volumes.sfx else 0
	music.Volume = if enabled.music then volumes.music else 0
end

-- Configure a Sound instance for a def (shared by all pools).
local function configure(sound: Sound, def: SoundDef, group: SoundGroup?)
	sound.SoundId = def.id -- same-value assignment is a no-op, so pooled sounds don't reload
	sound.Volume = def.volume
	sound.PlaybackSpeed = def.pitch or 1
	sound.SoundGroup = group
end

-------------------------------------------------------------------------------------------------------------------------
-- One-shots
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

local function variedPitch(def: SoundDef): number
	return (def.pitch or 1) * rng:NextNumber(0.95, 1.05)
end

local function playUI(key: string, def: SoundDef): Sound
	ensureGroups()
	local pool = uiPools[key]
	if not pool then
		pool = {}
		uiPools[key] = pool
	end
	local pick: PoolEntry? = nil
	for _, entry in pool do
		if entry.sound.Parent and not entry.sound.IsPlaying then
			pick = entry
			break
		end
	end
	if not pick then
		if #pool < UI_POOL_PER_KEY then
			local s = Instance.new("Sound")
			s.Name = key
			s.Parent = uiFolder
			pick = { sound = s, startedAt = 0 }
			table.insert(pool, pick :: PoolEntry)
		else
			-- steal the oldest
			local oldest = pool[1]
			for _, entry in pool do
				if entry.startedAt < oldest.startedAt then
					oldest = entry
				end
			end
			pick = oldest
		end
	end
	local entry = pick :: PoolEntry
	if not entry.sound.Parent then
		entry.sound.Parent = uiFolder
	end
	configure(entry.sound, def, sfxGroup)
	entry.sound.Looped = false
	entry.sound.PlaybackSpeed = variedPitch(def)
	entry.sound.TimePosition = 0
	entry.sound:Play()
	entry.startedAt = os.clock()
	return entry.sound
end

local function playWorld(def: SoundDef, position: Vector3): Sound?
	local cam = Workspace.CurrentCamera
	if cam and (cam.CFrame.Position - position).Magnitude > WORLD_CULL_DISTANCE then
		return nil
	end
	ensureGroups()
	local anchor = ensureWorldAnchor()
	local pick: WorldEntry? = nil
	for _, entry in worldPool do
		if entry.attachment.Parent == anchor and not entry.sound.IsPlaying then
			pick = entry
			break
		end
	end
	if not pick then
		if #worldPool < WORLD_POOL_SIZE then
			local att = Instance.new("Attachment")
			att.Name = "SoundEmitter"
			att.Parent = anchor
			local s = Instance.new("Sound")
			s.RollOffMode = Enum.RollOffMode.InverseTapered
			s.RollOffMinDistance = 12
			s.RollOffMaxDistance = 320
			s.Parent = att
			pick = { attachment = att, sound = s, startedAt = 0 }
			table.insert(worldPool, pick :: WorldEntry)
		else
			local oldest = worldPool[1]
			for _, entry in worldPool do
				if entry.startedAt < oldest.startedAt then
					oldest = entry
				end
			end
			pick = oldest
		end
	end
	local entry = pick :: WorldEntry
	if entry.attachment.Parent ~= anchor then
		entry.attachment.Parent = anchor
	end
	entry.attachment.WorldPosition = position
	configure(entry.sound, def, sfxGroup)
	entry.sound.Looped = false
	entry.sound.PlaybackSpeed = variedPitch(def)
	entry.sound.TimePosition = 0
	entry.sound:Play()
	entry.startedAt = os.clock()
	return entry.sound
end

-- Play a Config/Sounds key. position = world sound (3D), nil = UI sound. Returns the playing Sound or nil.
function SoundController.play(key: string, position: Vector3?): Sound?
	if typeof(key) ~= "string" then
		return nil
	end
	local def = lookup(key)
	if not def or not enabled.sfx then
		return nil
	end
	if typeof(position) == "Vector3" then
		return playWorld(def, position)
	end
	return playUI(key, def)
end

-- Start a looping sound the caller owns. parent = BasePart/Attachment for 3D, nil for a UI loop.
-- channel "music" puts it in the music group (ambience-like); default "sfx".
function SoundController.playLoop(key: string, parent: Instance?, channel: string?): Sound?
	local def = lookup(key)
	if not def then
		return nil
	end
	ensureGroups()
	local s = Instance.new("Sound")
	s.Name = "Loop_" .. key
	configure(s, def, if channel == "music" then musicGroup else sfxGroup)
	s.Looped = true
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 15
	s.RollOffMaxDistance = 300
	s.Parent = parent or uiFolder
	s:Play()
	return s
end

function SoundController.stopLoop(sound: Sound?)
	if sound then
		sound:Stop()
		sound:Destroy()
	end
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
		enabled.sfx = value
	end
	if channel == nil or channel == "music" then
		enabled.music = value
	end
	applyGroupVolumes()
end

function SoundController.isEnabled(channel: string): boolean
	return if channel == "music" then enabled.music else enabled.sfx
end

-- Master volume (0..1) of a channel.
function SoundController.setVolume(channel: string, volume: number)
	local v = math.clamp(volume, 0, 1)
	if channel == "music" then
		volumes.music = v
	else
		volumes.sfx = v
	end
	applyGroupVolumes()
end

local function applySettings(snapshot: any)
	if typeof(snapshot) ~= "table" or typeof(snapshot.settings) ~= "table" then
		return
	end
	local s = snapshot.settings
	if typeof(s.sfx) == "boolean" then
		enabled.sfx = s.sfx
	end
	if typeof(s.music) == "boolean" then
		enabled.music = s.music
	end
	applyGroupVolumes()
end

-------------------------------------------------------------------------------------------------------------------------
-- Car tracking: engines + sirens
-------------------------------------------------------------------------------------------------------------------------

type CarInfo = { model: Model, chassis: BasePart?, seat: VehicleSeat?, topSpeed: number, carId: any }
type LoopSlot = { key: string, sound: Sound, holder: Model?, pitch: number, baseVolume: number }

local cars: { [Model]: CarInfo } = {}
local policeModels: { [Model]: boolean } = {}
local engineSlots: { LoopSlot } = {}
local sirenSlots: { LoopSlot } = {}
local candidates: { { key: any, dist: number } } = {}
local scanAccum = 0
local ambience: Sound? = nil

local function resolveParts(info: CarInfo)
	local model = info.model
	if not (info.chassis and info.chassis.Parent) then
		local primary = model.PrimaryPart
		local chassis = primary or model:FindFirstChild("Chassis")
		info.chassis = if chassis and chassis:IsA("BasePart") then chassis else nil
	end
	if not (info.seat and info.seat.Parent) then
		local seat = model:FindFirstChild("DriverSeat", true)
		info.seat = if seat and seat:IsA("VehicleSeat") then seat else nil
	end
	local carId = model:GetAttribute("CarId")
	if carId ~= info.carId then
		info.carId = carId
		info.topSpeed = SoundController.topSpeedFor(carId, model:GetAttribute("Kind"))
	end
end

local function trackCar(inst: Instance)
	if not inst:IsA("Model") or cars[inst] then
		return
	end
	local info: CarInfo = { model = inst, chassis = nil, seat = nil, topSpeed = DEFAULT_TOP_SPEED, carId = false }
	cars[inst] = info
	resolveParts(info)
end

local function untrackCar(inst: Instance)
	if inst:IsA("Model") then
		cars[inst] = nil
	end
end

local function trackPolice(inst: Instance)
	if inst:IsA("Model") then
		policeModels[inst] = true
	end
end

local function untrackPolice(inst: Instance)
	if inst:IsA("Model") then
		policeModels[inst] = nil
	end
end

local function hasDriver(info: CarInfo): boolean
	local seat = info.seat
	if seat and seat.Occupant ~= nil then
		return true
	end
	local driverId = info.model:GetAttribute("DriverUserId")
	return typeof(driverId) == "number" and driverId > 0
end

local function newLoopSound(key: string, def: SoundDef): Sound
	ensureGroups()
	local s = Instance.new("Sound")
	s.Name = "HC_" .. key
	configure(s, def, sfxGroup)
	s.Looped = true
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = if key == "EngineLoop" then 10 else 25
	s.RollOffMaxDistance = if key == "EngineLoop" then ENGINE_RANGE else SIREN_RANGE + 40
	return s
end

local function makeSlot(key: string): LoopSlot?
	local def = lookup(key)
	if not def then
		return nil
	end
	return { key = key, sound = newLoopSound(key, def), holder = nil, pitch = 0.7, baseVolume = def.volume }
end

-- Loop Sounds live inside car chassis, so they are destroyed together with a despawned car (Parent becomes locked).
-- Re-parenting such a Sound throws: replace it with a fresh one instead.
local function parentSlotSound(slot: LoopSlot, parent: Instance?): boolean
	local ok = pcall(function()
		slot.sound.Parent = parent
	end)
	if ok then
		return true
	end
	local def = lookup(slot.key)
	if not def then
		return false
	end
	slot.sound = newLoopSound(slot.key, def)
	return pcall(function()
		slot.sound.Parent = parent
	end)
end

local function releaseSlot(slot: LoopSlot)
	slot.holder = nil
	if slot.sound.IsPlaying then
		slot.sound:Stop()
	end
	parentSlotSound(slot, nil)
end

local function assignSlot(slot: LoopSlot, model: Model, chassis: BasePart)
	if not parentSlotSound(slot, chassis) then
		slot.holder = nil
		return
	end
	slot.holder = model
	slot.pitch = 0.7
	slot.sound.PlaybackSpeed = slot.pitch
	slot.sound.TimePosition = rng:NextNumber(0, 1) -- de-sync identical loops
	slot.sound:Play()
end

-- Reassign a pool of loop slots to the chosen set of models, keeping current holders where possible.
local function distribute(slots: { LoopSlot }, chosen: { [any]: boolean }, chassisOf: (Model) -> BasePart?)
	local held: { [Model]: boolean } = {}
	for _, slot in slots do
		local holder = slot.holder
		if holder then
			local chassis = chassisOf(holder)
			if chosen[holder] and chassis and slot.sound.Parent == chassis then
				held[holder] = true
			else
				releaseSlot(slot)
			end
		end
	end
	for model in chosen do
		if not held[model] then
			local chassis = chassisOf(model)
			if chassis then
				for _, slot in slots do
					if slot.holder == nil then
						assignSlot(slot, model, chassis)
						break
					end
				end
			end
		end
	end
end

local function chassisOfCar(model: Model): BasePart?
	local info = cars[model]
	if info then
		local chassis = info.chassis
		if chassis and chassis.Parent then
			return chassis
		end
	end
	local primary = model.PrimaryPart
	if primary then
		return primary
	end
	local c = model:FindFirstChild("Chassis")
	return if c and c:IsA("BasePart") then c else nil
end

local function releaseAll(slots: { LoopSlot })
	for _, slot in slots do
		if slot.holder then
			releaseSlot(slot)
		end
	end
end

local function scan()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local listener = cam.CFrame.Position

	if not enabled.sfx then
		releaseAll(engineSlots)
		releaseAll(sirenSlots)
		return
	end

	-- engines
	table.clear(candidates)
	for model, info in cars do
		if model.Parent == nil then
			cars[model] = nil
			continue
		end
		resolveParts(info)
		local chassis = info.chassis
		if chassis and SoundController.isEngineEligible(model:GetAttribute("Kind"), hasDriver(info)) then
			local dist = (chassis.Position - listener).Magnitude
			if dist <= ENGINE_RANGE then
				table.insert(candidates, { key = model, dist = dist })
			end
		end
	end
	distribute(engineSlots, SoundController.selectNearest(candidates, ENGINE_SLOTS), chassisOfCar)

	-- sirens
	table.clear(candidates)
	for model in policeModels do
		if model.Parent == nil then
			policeModels[model] = nil
			continue
		end
		-- PoliceService sets Siren=false on units that are leaving or wrecked (nil = on: older/unreplicated units)
		if model:GetAttribute("Siren") == false then
			continue
		end
		local chassis = chassisOfCar(model)
		if chassis then
			local dist = (chassis.Position - listener).Magnitude
			if dist <= SIREN_RANGE then
				table.insert(candidates, { key = model, dist = dist })
			end
		end
	end
	distribute(sirenSlots, SoundController.selectNearest(candidates, SIREN_SLOTS), chassisOfCar)

	-- ambience: duck while the local player drives (the engine takes over)
	local amb = ambience
	if amb then
		local def = lookup("CityAmbience")
		local base = (if def then def.volume else 0.25) * AMBIENCE_VOLUME_SCALE
		amb.Volume = if player and player:GetAttribute("Driving") == true then base * AMBIENCE_DRIVING_DUCK else base
	end
end

local function updateEngines(dt: number)
	local alpha = math.min(1, dt * PITCH_SMOOTHING)
	for _, slot in engineSlots do
		local holder = slot.holder
		if holder then
			local info = cars[holder]
			local chassis = if info then info.chassis else nil
			if info and chassis and chassis.Parent then
				local speed = chassis.AssemblyLinearVelocity.Magnitude
				local target = SoundController.enginePitch(speed, info.topSpeed)
				slot.pitch += (target - slot.pitch) * alpha
				slot.sound.PlaybackSpeed = slot.pitch
				local frac = math.clamp((slot.pitch - 0.7) / 1.1, 0, 1)
				slot.sound.Volume = slot.baseVolume * (0.55 + 0.45 * frac)
			end
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function SoundController.init()
	ensureGroups()
	applyGroupVolumes()
end

function SoundController.start()
	ensureGroups()
	ensureWorldAnchor()

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

	-- settings from the snapshot
	StateController.onReady(applySettings)
	StateController.Changed:Connect(function(snapshot: any)
		applySettings(snapshot)
	end)

	-- loop pools
	for _ = 1, ENGINE_SLOTS do
		local slot = makeSlot("EngineLoop")
		if slot then
			table.insert(engineSlots, slot)
		end
	end
	for i = 1, SIREN_SLOTS do
		local slot = makeSlot(if i == 2 then "SirenAlt" else "Siren")
		if slot then
			table.insert(sirenSlots, slot)
		end
	end

	-- car tracking
	CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(trackCar)
	CollectionService:GetInstanceRemovedSignal("Vehicle"):Connect(untrackCar)
	for _, inst in CollectionService:GetTagged("Vehicle") do
		trackCar(inst)
	end
	CollectionService:GetInstanceAddedSignal("Police"):Connect(trackPolice)
	CollectionService:GetInstanceRemovedSignal("Police"):Connect(untrackPolice)
	for _, inst in CollectionService:GetTagged("Police") do
		trackPolice(inst)
	end

	-- ambience (music channel)
	ambience = SoundController.playLoop("CityAmbience", nil, "music")
	local amb = ambience
	if amb then
		amb.Volume *= AMBIENCE_VOLUME_SCALE
	end

	RunService.PreRender:Connect(function(dt: number)
		scanAccum += dt
		if scanAccum >= SCAN_INTERVAL then
			scanAccum = 0
			debug.profilebegin("HC_SoundScan")
			scan()
			debug.profileend()
		end
		updateEngines(dt)
	end)

	-- preload everything in the background (yields; never blocks gameplay)
	task.spawn(function()
		local ids: { string } = {}
		local seen: { [string]: boolean } = {}
		for _, def in Sounds :: any do
			if typeof(def) == "table" and typeof(def.id) == "string" and not seen[def.id] then
				seen[def.id] = true
				table.insert(ids, def.id)
			end
		end
		local preloadOk, preloadErr = pcall(function()
			ContentProvider:PreloadAsync(ids :: any)
		end)
		if not preloadOk then
			warn("[SoundController] preload failed: " .. tostring(preloadErr))
		end
	end)
end

return SoundController
