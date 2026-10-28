--!strict
-- FootService (C4a characters): the server half of the on-foot GTA feel. Fall damage + a brief ragdoll on big falls.
--
--   * Detection is server-side (nothing to trust from the client): every Heartbeat the root's replicated vertical
--     velocity is sampled per player; a sample falling faster than the safe-drop speed followed by one that has
--     (nearly) stopped is a landing (FootTuning.landingImpact). Seated / dead / already-ragdolled players, landings
--     in water and the first seconds after a spawn are ignored.
--   * Damage: FootTuning.fallDamage (none under ~4 m, lethal from ~17 m), applied through DamageService.applyDamage as
--     world damage (no source: protection rules for player attacks do not apply, armor absorbs first as for any hit).
--   * Ragdoll: drops of ~7 m+ that do not kill ragdoll the body for 1.4-2.6 s with Shared/Combat/Ragdoll (joints
--     intact, motors disabled), RequiresNeck off meanwhile. The character attribute HC_RagdollUntil (server time)
--     tells the owner's client (FootMovement) to hold the humanoid in Physics, then stand up.
-- API: ragdoll(player, seconds), isRagdolled(player), Landed: Signal(player, impactSpeed, damage).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local FootTuning = require(Shared.Appearance.FootTuning)
local Ragdoll = require(Shared.Combat.Ragdoll)

local FootService = {}

FootService.SPAWN_GRACE = 3 -- seconds after a spawn with no fall damage (spawns drop the body a little)
FootService.SEAT_GRACE = 1 -- seconds after leaving a seat (getting out of a moving car is not a fall)
FootService.ATTR = "HC_RagdollUntil"

FootService.Landed = Signal.new() -- (player, impactSpeed, damage)

type PState = {
	char: Model?,
	spawnedAt: number,
	seatedAt: number,
	prevVy: number,
	ragdollToken: number,
}

local states: { [Player]: PState } = {}

local hooks = {
	clock = os.clock,
	serverTime = function(): number
		return Workspace:GetServerTimeNow()
	end,
	gravity = function(): number
		return Workspace.Gravity
	end,
	damage = function(player: Player, amount: number): boolean
		-- DamageService is earlier in ORDER: required lazily anyway so this module loads alone (tests)
		local ds = script.Parent:FindFirstChild("DamageService")
		if ds then
			local okReq, mod = pcall(require, ds :: any)
			if okReq and typeof(mod) == "table" and typeof(mod.applyDamage) == "function" then
				local res = mod.applyDamage(player, { amount = amount })
				return typeof(res) == "table" and res.killed == true
			end
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum:TakeDamage(amount)
			return hum.Health <= 0
		end
		return false
	end,
	inWater = function(pos: Vector3): boolean
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = false
		local hit = Workspace:Raycast(pos, Vector3.new(0, -9, 0), params)
		return hit ~= nil and hit.Material == Enum.Material.Water
	end,
	delay = function(seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end,
}

function FootService._setHooks(overrides: { [string]: any })
	for k, v in overrides do
		(hooks :: any)[k] = v
	end
end

function FootService._state(player: Player): PState?
	return states[player]
end

local function parts(player: Player): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, if root and root:IsA("BasePart") then root else nil
end

function FootService.isRagdolled(player: Player): boolean
	local char = player.Character
	if not char then
		return false
	end
	local untilT = char:GetAttribute(FootService.ATTR)
	return typeof(untilT) == "number" and untilT > hooks.serverTime()
end

-- Ragdolls a living player for `seconds` (joints intact), then stands them back up.
function FootService.ragdoll(player: Player, seconds: number)
	local st = states[player]
	local char, hum = parts(player)
	if not st or not char or not hum or hum.Health <= 0 then
		return
	end
	st.ragdollToken += 1
	local token = st.ragdollToken
	pcall(function()
		hum.RequiresNeck = false
	end)
	pcall(Ragdoll.enable, char)
	pcall(Ragdoll.setBodyCollision, char, true)
	char:SetAttribute(FootService.ATTR, hooks.serverTime() + seconds)
	hooks.delay(seconds, function()
		if st.ragdollToken ~= token or player.Character ~= char then
			return
		end
		char:SetAttribute(FootService.ATTR, nil)
		if hum.Health > 0 then
			pcall(Ragdoll.restore, char)
			pcall(Ragdoll.setBodyCollision, char, false)
			pcall(function()
				hum.RequiresNeck = true
			end)
		end
	end)
end

-- A hard landing: damage, maybe a ragdoll. Returns the damage dealt.
function FootService._land(player: Player, impactSpeed: number, position: Vector3?): number
	if position and hooks.inWater(position) then
		return 0
	end
	local damage, rag = FootTuning.fallDamage(impactSpeed, hooks.gravity())
	if damage <= 0 then
		return 0
	end
	local killed = hooks.damage(player, damage)
	FootService.Landed:Fire(player, impactSpeed, damage)
	if not killed and rag > 0 then
		FootService.ragdoll(player, rag)
	end
	return damage
end

-- One sample for one player (Heartbeat). Returns the impact speed when this sample is a hard landing, else 0.
function FootService._sample(player: Player, now: number): number
	local st = states[player]
	if not st then
		return 0
	end
	local char, hum, root = parts(player)
	if not char or not hum or not root or hum.Health <= 0 then
		st.prevVy = 0
		return 0
	end
	if st.char ~= char then
		st.char = char
		st.spawnedAt = now
		st.prevVy = 0
	end
	if hum.SeatPart ~= nil then
		st.seatedAt = now
		st.prevVy = 0
		return 0
	end
	local vy = root.AssemblyLinearVelocity.Y
	local prev = st.prevVy
	st.prevVy = vy
	if now - st.spawnedAt < FootService.SPAWN_GRACE or now - st.seatedAt < FootService.SEAT_GRACE then
		return 0
	end
	if FootService.isRagdolled(player) then
		return 0
	end
	local impact = FootTuning.landingImpact(prev, vy, hooks.gravity())
	if impact > 0 then
		FootService._land(player, impact, root.Position)
	end
	return impact
end

local function track(player: Player)
	if not states[player] then
		states[player] = { char = nil, spawnedAt = 0, seatedAt = -math.huge, prevVy = 0, ragdollToken = 0 }
	end
end
FootService._track = track

function FootService.init() end

function FootService.start()
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(p: Player)
		states[p] = nil
	end)
	for _, p in Players:GetPlayers() do
		track(p)
	end
	RunService.Heartbeat:Connect(function()
		local now = hooks.clock()
		for player in states do
			local ok, err = pcall(FootService._sample, player, now)
			if not ok then
				warn("[FootService] " .. tostring(err))
			end
		end
	end)
end

return FootService
