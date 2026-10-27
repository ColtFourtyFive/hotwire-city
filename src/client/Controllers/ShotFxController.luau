--!strict
-- ShotFxController (gta_combat §10.6, §11.6): every visible / audible bullet on this client.
--
--  * Remote shots: ShotFx (players) and PoliceShotFx (police) over UnreliableRemoteEvents:
--    (shooterKey, weaponIndex, origin, endpoints {<= 11}, kinds {0 miss, 1 world, 2 body, 3 metal}).
--  * Local shots: WeaponClient calls ShotFxController.localShot(...) the moment it fires (predicted; the server skips
--    the shooter when it relays).
--  * Pooled tracers (Beam + two Attachments on one local anchored host, 64 max) that streak from the muzzle to the
--    endpoint at ~1,500 studs/s; muzzle flashes (pooled PointLights, 16 max, + VFXLibrary "Flash"); impacts (dust on
--    world surfaces, sparks on metal, a small GREY cloth puff on characters: never red, no blood, no decals on
--    people); near-miss whiz when a remote tracer passes within WHIZ_RADIUS of the local head.
--  * Gun audio through SoundController.playGunshot (shot / tail / mech layers, distance rules, radio ducking).
--    Impact audio: one sound per shot (the first pellet that lands; every pellet still gets its dust / sparks), at
--    most IMPACT_SOUNDS_PER_S per shooter, so a shotgun blast or an SMG burst never floods the positional voice pool.
--  * DistantShot(origin, weaponIndex): a gunshot beyond the ShotFx radius, heard as a low-passed tail
--    (SoundController.playDistantGunshot).
--  * Effect remote names it renders: TaserShot { from, to, hit } (two thin probe wires), TireBurst { position },
--    StripDrop { position }, MeleeHit { position }.
-- Pure helpers (tests): _closestPointOnSegment, _impactStyle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))

local ShotFxController = {}

local player = Players.LocalPlayer

ShotFxController.TRACER_POOL = 64
ShotFxController.FLASH_POOL = 16
ShotFxController.TRACER_SPEED = 1500
ShotFxController.TRACER_LENGTH = 9
ShotFxController.WHIZ_RADIUS = 4
ShotFxController.MAX_DISTANCE = 600 -- FX farther than this from the camera are skipped (audio still plays)
ShotFxController.FLASH_TIME = 0.05
ShotFxController.IMPACT_SOUNDS_PER_S = 8

local TRACER_COLOR = Color3.fromRGB(255, 226, 168)
local FLASH_COLOR = Color3.fromRGB(255, 196, 120)
local CLOTH_GREY = Color3.fromRGB(150, 150, 150)
local DUST = Color3.fromRGB(176, 168, 152)
local WIRE = Color3.fromRGB(200, 200, 205)

-- PURE -----------------------------------------------------------------------------------------------------------------

function ShotFxController._closestPointOnSegment(p: Vector3, a: Vector3, b: Vector3): Vector3
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = if len2 > 1e-6 then math.clamp((p - a):Dot(ab) / len2, 0, 1) else 0
	return a + ab * t
end

-- (vfx preset, color, count, sound key?) for an impact kind. No red for bodies (Moderate, no blood).
function ShotFxController._impactStyle(kind: number): (string?, Color3, number, string?)
	if kind == 2 then
		return "DustPuff", CLOTH_GREY, 3, nil -- small grey cloth puff (the server's HitConfirm drives the tick)
	elseif kind == 3 then
		return "Sparks", Color3.fromRGB(255, 214, 150), 8, "Ricochet1"
	elseif kind == 1 then
		return "DustPuff", DUST, 4, "Impact1"
	end
	return nil, DUST, 0, nil
end

-- Impact-sound budget per shooter (pure, tested): a token bucket of IMPACT_SOUNDS_PER_S tokens refilling at that
-- rate. Returns true (and spends a token) when this impact may play its sound.
export type SoundBudget = { tokens: number, at: number }
function ShotFxController._takeImpactSound(b: SoundBudget, now: number): boolean
	local rate = ShotFxController.IMPACT_SOUNDS_PER_S
	b.tokens = math.min(rate, b.tokens + math.max(0, now - b.at) * rate)
	b.at = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

-- STATE ---------------------------------------------------------------------------------------------------------------

type Tracer = {
	a0: Attachment,
	a1: Attachment,
	beam: Beam,
	from: Vector3,
	dir: Vector3,
	dist: number,
	t: number,
	active: boolean,
	whizzed: boolean,
	remote: boolean,
}
type Flash = { att: Attachment, light: PointLight, untilT: number }

local host: Part? = nil
local tracers: { Tracer } = {}
local flashes: { Flash } = {}
local nextTracer = 1
local nextFlash = 1
local activeCount = 0
local vfx: any = nil
local sound: any = nil
local soundBudgets: { [any]: SoundBudget } = {}
local budgetSweepAt = 0

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return false
	end
	local ok, res = pcall(require, mod :: any)
	return if ok and typeof(res) == "table" then res else false
end

local function getVfx(): any
	if vfx == nil then
		vfx = lazy("VFXLibrary")
	end
	return vfx or nil
end

local function getSound(): any
	if sound == nil then
		sound = lazy("SoundController")
	end
	return sound or nil
end

local function ensureHost(): Part
	local h = host
	if h and h.Parent then
		return h
	end
	local folder = Workspace:FindFirstChild("ClientFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ClientFX"
		folder.Parent = Workspace
	end
	local part = Instance.new("Part")
	part.Name = "ShotFxHost"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new()
	part.Parent = folder
	host = part
	table.clear(tracers)
	table.clear(flashes)
	nextTracer, nextFlash, activeCount = 1, 1, 0
	return part
end

local function newTracer(h: Part): Tracer
	local a0 = Instance.new("Attachment")
	a0.Name = "TracerTail"
	a0.Parent = h
	local a1 = Instance.new("Attachment")
	a1.Name = "TracerHead"
	a1.Parent = h
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(TRACER_COLOR)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.6, 0.55),
		NumberSequenceKeypoint.new(1, 0.25),
	})
	beam.Width0 = 0.04
	beam.Width1 = 0.07
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Segments = 1
	beam.Enabled = false
	beam.Parent = h
	return {
		a0 = a0,
		a1 = a1,
		beam = beam,
		from = Vector3.zero,
		dir = Vector3.zAxis,
		dist = 0,
		t = 0,
		active = false,
		whizzed = false,
		remote = false,
	}
end

local function acquireTracer(): Tracer
	local h = ensureHost()
	if #tracers < ShotFxController.TRACER_POOL then
		local tr = newTracer(h)
		table.insert(tracers, tr)
		return tr
	end
	local tr = tracers[nextTracer]
	nextTracer = nextTracer % #tracers + 1
	if tr.active then
		activeCount -= 1
	end
	return tr
end

local function flashAt(pos: Vector3)
	local h = ensureHost()
	local f: Flash
	if #flashes < ShotFxController.FLASH_POOL then
		local att = Instance.new("Attachment")
		att.Name = "Flash"
		att.Parent = h
		local light = Instance.new("PointLight")
		light.Color = FLASH_COLOR
		light.Range = 9
		light.Brightness = 0
		light.Shadows = false
		light.Parent = att
		f = { att = att, light = light, untilT = 0 }
		table.insert(flashes, f)
	else
		f = flashes[nextFlash]
		nextFlash = nextFlash % #flashes + 1
	end
	f.att.WorldPosition = pos
	f.light.Brightness = 3
	f.untilT = os.clock() + ShotFxController.FLASH_TIME
	local lib = getVfx()
	if lib then
		pcall(lib.burst, "Flash", pos, { scale = 0.22, color = FLASH_COLOR })
	end
end

local function camPos(): Vector3?
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else nil
end

local function startTracer(from: Vector3, to: Vector3, remote: boolean)
	local d = to - from
	local dist = d.Magnitude
	if dist < 2 then
		return
	end
	local tr = acquireTracer()
	tr.from = from
	tr.dir = d / dist
	tr.dist = dist
	tr.t = 0
	tr.whizzed = not remote
	tr.remote = remote
	tr.a0.WorldPosition = from
	tr.a1.WorldPosition = from
	tr.beam.Enabled = true
	if not tr.active then
		tr.active = true
		activeCount += 1
	end
end

local function impact(pos: Vector3, kind: number, normal: Vector3?, withSound: boolean)
	local preset, color, count, key = ShotFxController._impactStyle(kind)
	local cam = camPos()
	if cam and (cam - pos).Magnitude > ShotFxController.MAX_DISTANCE then
		return
	end
	local lib = getVfx()
	if preset and lib then
		pcall(lib.burst, preset, pos, { count = count, scale = 0.35, color = color, direction = normal })
	end
	local snd = getSound()
	if withSound and key and snd then
		pcall(snd.play, key, pos)
	end
end

local function budgetFor(shooterKey: any, now: number): SoundBudget
	local b = soundBudgets[shooterKey]
	if not b then
		b = { tokens = ShotFxController.IMPACT_SOUNDS_PER_S, at = now }
		soundBudgets[shooterKey] = b
	end
	-- forget idle shooters now and then
	if now - budgetSweepAt > 10 then
		budgetSweepAt = now
		for k, other in soundBudgets do
			if now - other.at > 10 and k ~= shooterKey then
				soundBudgets[k] = nil
			end
		end
	end
	return b
end

-- Renders one shot: muzzle flash, tracers to every endpoint, impacts, and the shooter's gun audio.
local function render(
	shooterKey: any,
	weaponId: string?,
	origin: Vector3,
	endpoints: { Vector3 },
	kinds: { number },
	remote: boolean,
	normals: { Vector3 }?
)
	local def = weaponId and Weapons.get(weaponId)
	local snd = getSound()
	if def and snd then
		pcall(snd.playGunshot, def.sounds, origin)
	end
	local cam = camPos()
	local near = cam == nil or (cam - origin).Magnitude <= ShotFxController.MAX_DISTANCE
	if near then
		flashAt(origin)
	end
	local now = os.clock()
	local soundTaken = false
	for i, e in endpoints do
		if typeof(e) == "Vector3" then
			startTracer(origin, e, remote)
			local kind = kinds[i] or 0
			if kind ~= 0 then
				-- one impact sound per shot (the first pellet that lands), within the shooter's budget
				local withSound = false
				if not soundTaken then
					soundTaken = true
					withSound = ShotFxController._takeImpactSound(budgetFor(shooterKey, now), now)
				end
				-- impact lands when the tracer arrives
				local delay = (e - origin).Magnitude / ShotFxController.TRACER_SPEED
				local n = normals and normals[i]
				task.delay(delay, impact, e, kind, n, withSound)
			end
		end
	end
end

-- Predicted local shot (WeaponClient).
function ShotFxController.localShot(
	weaponId: string,
	origin: Vector3,
	endpoints: { Vector3 },
	kinds: { number },
	normals: { Vector3 }?
)
	render("local", weaponId, origin, endpoints, kinds, false, normals)
end

local function onRemoteShot(shooterKey: any, weaponIndex: any, origin: any, endpoints: any, kinds: any)
	if typeof(origin) ~= "Vector3" or typeof(endpoints) ~= "table" then
		return
	end
	local def = if typeof(weaponIndex) == "number" then Weapons.List[weaponIndex] else nil
	local list: { Vector3 } = {}
	local kindList: { number } = {}
	for i = 1, math.min(#endpoints, Weapons.MAX_PELLETS) do
		local e = endpoints[i]
		if typeof(e) == "Vector3" and (e - origin).Magnitude <= 1000 then
			table.insert(list, e)
			local k = if typeof(kinds) == "table" then kinds[i] else 0
			table.insert(kindList, if typeof(k) == "number" then k else 0)
		end
	end
	local key = if typeof(shooterKey) == "number" then shooterKey else "remote"
	render(key, if def then def.id else nil, origin, list, kindList, true, nil)
end

-- A gunshot beyond the ShotFx radius: only its distant tail.
local function onDistantShot(origin: any, weaponIndex: any)
	if typeof(origin) ~= "Vector3" or not Net.isFiniteVector(origin) or typeof(weaponIndex) ~= "number" then
		return
	end
	local def = Weapons.List[weaponIndex]
	local snd = getSound()
	if def and snd and typeof(snd.playDistantGunshot) == "function" then
		pcall(snd.playDistantGunshot, def.sounds, origin)
	end
end

-- EFFECT REMOTE (gadgets / melee) -------------------------------------------------------------------------------------

local function wire(from: Vector3, to: Vector3, life: number)
	local h = ensureHost()
	local a0 = Instance.new("Attachment")
	a0.WorldPosition = from
	a0.Parent = h
	local a1 = Instance.new("Attachment")
	a1.WorldPosition = to
	a1.Parent = h
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(WIRE)
	beam.Width0 = 0.02
	beam.Width1 = 0.02
	beam.CurveSize0 = 0.4
	beam.FaceCamera = true
	beam.LightInfluence = 1
	beam.Transparency = NumberSequence.new(0.2)
	beam.Parent = h
	task.delay(life, function()
		beam:Destroy()
		a0:Destroy()
		a1:Destroy()
	end)
end

local function onEffect(name: any, data: any)
	if typeof(name) ~= "string" or typeof(data) ~= "table" then
		return
	end
	local lib = getVfx()
	local snd = getSound()
	if name == "TaserShot" then
		local from, to = data.from, data.to
		if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" or (to - from).Magnitude > 120 then
			return
		end
		local side = (to - from):Cross(Vector3.yAxis)
		side = if side.Magnitude > 0.01 then side.Unit * 0.15 else Vector3.xAxis * 0.15
		wire(from, to + side, if data.hit then 1.4 else 0.6)
		wire(from, to - side + Vector3.new(0, -0.6, 0), if data.hit then 1.4 else 0.6)
		if snd then
			pcall(snd.play, "Gun_Empty", from)
		end
		if data.hit and lib then
			pcall(lib.burst, "Sparks", to, { count = 6, scale = 0.25, color = Color3.fromRGB(190, 220, 255) })
		end
	elseif name == "TireBurst" then
		local pos = data.position
		if typeof(pos) == "Vector3" then
			if lib then
				pcall(lib.burst, "DustPuff", pos, { count = 6, scale = 0.6, color = Color3.fromRGB(120, 120, 124) })
				pcall(lib.burst, "Debris", pos, { count = 5, scale = 0.4, color = Color3.fromRGB(26, 26, 28) })
			end
			if snd then
				pcall(snd.play, "Impact2", pos)
			end
		end
	elseif name == "StripDrop" then
		local pos = data.position
		if typeof(pos) == "Vector3" and lib then
			pcall(lib.burst, "DustPuff", pos, { count = 4, scale = 0.5 })
		end
		if typeof(pos) == "Vector3" and snd then
			pcall(snd.play, "Melee_Metal", pos)
		end
	elseif name == "MeleeHit" then
		local pos = data.position
		if typeof(pos) == "Vector3" and lib then
			pcall(lib.burst, "DustPuff", pos, { count = 3, scale = 0.3, color = CLOTH_GREY })
		end
	end
end

-- FRAME -------------------------------------------------------------------------------------------------------------------

local function headPosition(): Vector3?
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head.Position else nil
end

local function step(dt: number)
	local now = os.clock()
	for _, f in flashes do
		if f.light.Brightness > 0 and now >= f.untilT then
			f.light.Brightness = 0
		end
	end
	if activeCount <= 0 then
		return
	end
	local head = headPosition()
	for _, tr in tracers do
		if tr.active then
			tr.t += dt
			local headDist = math.min(tr.dist, tr.t * ShotFxController.TRACER_SPEED)
			local tailDist = math.max(0, headDist - ShotFxController.TRACER_LENGTH)
			local hp = tr.from + tr.dir * headDist
			tr.a1.WorldPosition = hp
			tr.a0.WorldPosition = tr.from + tr.dir * tailDist
			if not tr.whizzed and head then
				local closest = ShotFxController._closestPointOnSegment(head, tr.from, hp)
				if (closest - head).Magnitude <= ShotFxController.WHIZ_RADIUS and (closest - tr.from).Magnitude > 6 then
					tr.whizzed = true
					local snd = getSound()
					if snd then
						pcall(snd.playWhiz, closest)
					end
				end
			end
			if tailDist >= tr.dist then
				tr.active = false
				tr.beam.Enabled = false
				activeCount -= 1
			end
		end
	end
end

function ShotFxController.init() end

function ShotFxController.start()
	ensureHost()
	local ok, err = pcall(function()
		Net.listenUnreliable("ShotFx", onRemoteShot)
		Net.listenUnreliable("PoliceShotFx", onRemoteShot)
		Net.listenUnreliable("DistantShot", onDistantShot)
	end)
	if not ok then
		warn("[ShotFxController] shot remotes unavailable: " .. tostring(err))
	end
	pcall(Net.listen, "Effect", onEffect)
	RunService.PreRender:Connect(step)
end

return ShotFxController
