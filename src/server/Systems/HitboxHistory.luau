--!strict
-- HitboxHistory (gta_combat §10.3): lag compensation by position history.
--
-- At SAMPLE_HZ on Heartbeat it records the root CFrame of every player character, every NPC (on-foot officers and
-- pedestrians in Workspace.NPCs) within TRACK_RADIUS of a player, and the chassis of every car in Workspace.Vehicles,
-- keyed by MODEL, stamped with Workspace:GetServerTimeNow() (the same clock the client stamps shots with).
-- Each model keeps a ring buffer of BUFFER seconds. sample(model, t) interpolates position (lerp) and rotation
-- (slerp) between the two samples around t, clamping to the oldest / newest sample outside the buffer.
-- WeaponService rewinds the shooter's head and the victim's hit part with it.
--
-- Cost: ~92 models x 20 Hz = ~1,840 writes/s at a full server (30 players + 8 officers + 14 peds + 40 cars).
-- Pure ring-buffer helpers (_newRing, _push, _sampleRing) are unit-tested.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local HitboxHistory = {}

HitboxHistory.SAMPLE_HZ = 20
HitboxHistory.BUFFER = 1.0
HitboxHistory.TRACK_RADIUS = 400
HitboxHistory.SIZE = 21 -- BUFFER x SAMPLE_HZ + 1

export type Ring = { times: { number }, frames: { CFrame }, head: number, count: number, size: number }

function HitboxHistory._newRing(size: number): Ring
	return { times = table.create(size, 0), frames = table.create(size, CFrame.new()), head = 0, count = 0, size = size }
end

function HitboxHistory._push(ring: Ring, t: number, cf: CFrame)
	ring.head = ring.head % ring.size + 1
	ring.times[ring.head] = t
	ring.frames[ring.head] = cf
	ring.count = math.min(ring.count + 1, ring.size)
end

-- i-th newest sample (1 = newest).
local function at(ring: Ring, i: number): (number, CFrame)
	local idx = (ring.head - i) % ring.size + 1
	return ring.times[idx], ring.frames[idx]
end

-- Interpolated CFrame at time t (nil when the ring is empty).
function HitboxHistory._sampleRing(ring: Ring, t: number): CFrame?
	if ring.count == 0 then
		return nil
	end
	local newestT, newestCF = at(ring, 1)
	if t >= newestT then
		return newestCF
	end
	local prevT, prevCF = newestT, newestCF
	for i = 2, ring.count do
		local ti, cfi = at(ring, i)
		if t >= ti then
			local span = prevT - ti
			local a = if span > 1e-6 then (t - ti) / span else 0
			return cfi:Lerp(prevCF, a)
		end
		prevT, prevCF = ti, cfi
	end
	return prevCF -- older than the buffer: the oldest sample
end

-- RUNTIME ---------------------------------------------------------------------------------------------------------

local rings: { [Instance]: Ring } = setmetatable({}, { __mode = "k" }) :: any
local rootOf: { [Instance]: BasePart } = setmetatable({}, { __mode = "k" }) :: any

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and typeof(t) == "number" then t else os.clock()
end

local function record(model: Instance, root: BasePart, t: number)
	local ring = rings[model]
	if not ring then
		ring = HitboxHistory._newRing(HitboxHistory.SIZE)
		rings[model] = ring
	end
	rootOf[model] = root
	HitboxHistory._push(ring, t, root.CFrame)
end

local function characterRoot(model: Model): BasePart?
	local r = model:FindFirstChild("HumanoidRootPart")
	if r and r:IsA("BasePart") then
		return r
	end
	return nil
end

local function pass()
	local t = serverNow()
	local playerPositions: { Vector3 } = {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		if char and char.Parent then
			local root = characterRoot(char)
			if root then
				record(char, root, t)
				table.insert(playerPositions, root.Position)
			end
		end
	end
	if #playerPositions == 0 then
		return
	end
	local r2 = HitboxHistory.TRACK_RADIUS * HitboxHistory.TRACK_RADIUS
	local function nearPlayer(pos: Vector3): boolean
		for _, pp in playerPositions do
			local d = pos - pp
			if d.X * d.X + d.Z * d.Z <= r2 then
				return true
			end
		end
		return false
	end
	local npcs = Workspace:FindFirstChild("NPCs")
	if npcs then
		for _, m in npcs:GetChildren() do
			if m:IsA("Model") then
				local root = characterRoot(m)
				if root and nearPlayer(root.Position) then
					record(m, root, t)
				end
			end
		end
	end
	local vehicles = Workspace:FindFirstChild("Vehicles")
	if vehicles then
		for _, m in vehicles:GetChildren() do
			if m:IsA("Model") then
				local chassis = m.PrimaryPart
				if chassis and not chassis.Anchored and nearPlayer(chassis.Position) then
					record(m, chassis, t)
				end
			end
		end
	end
	-- forget models that left the world (weak keys handle the rest)
	for model in rings do
		if model.Parent == nil then
			rings[model] = nil
			rootOf[model] = nil
		end
	end
end

-- Rewound root CFrame of `model` at server time t; falls back to the live root when the model has no history.
function HitboxHistory.sample(model: Instance, t: number): CFrame?
	local ring = rings[model]
	if ring then
		local cf = HitboxHistory._sampleRing(ring, t)
		if cf then
			return cf
		end
	end
	if model:IsA("Model") then
		local root = characterRoot(model) or model.PrimaryPart
		if root then
			return root.CFrame
		end
	end
	return nil
end

-- Rewound world position of `part` (a part of `model`): rewound root x the part's CURRENT offset from the root.
function HitboxHistory.samplePart(model: Instance, part: BasePart, t: number): Vector3?
	local rewound = HitboxHistory.sample(model, t)
	if not rewound then
		return nil
	end
	local root = rootOf[model]
	if not root and model:IsA("Model") then
		root = characterRoot(model) or model.PrimaryPart
	end
	if not root then
		return part.Position
	end
	return (rewound * root.CFrame:ToObjectSpace(part.CFrame)).Position
end

function HitboxHistory.isTracked(model: Instance): boolean
	return rings[model] ~= nil
end

function HitboxHistory.init() end

function HitboxHistory.start()
	local acc = 0
	local step = 1 / HitboxHistory.SAMPLE_HZ
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < step then
			return
		end
		acc = math.min(acc - step, step)
		local ok, err = pcall(pass)
		if not ok then
			warn("[HitboxHistory] pass failed: " .. tostring(err))
		end
	end)
end

return HitboxHistory
