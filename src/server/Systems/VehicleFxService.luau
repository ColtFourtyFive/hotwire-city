--!strict
-- VehicleFxService (AP4): relays a driver's cosmetic nitro / horn state to nearby players.
--
-- * VehicleFx(boost: boolean, honk: boolean) from VehicleClient: sent on nitro start / stop and on horn presses only.
--   Validated: both args booleans, the sender is the current driver of a live car (VehicleService.getDriving, lazy),
--   Net rate limit RATE/s, horns at most one per HONK_COOLDOWN (the client's own horn cooldown), unchanged boost
--   without a honk is dropped, a boost start sooner than MIN_BOOST_EDGE after the previous one is dropped (toggle
--   spam), and a boost is cut after MAX_BOOST seconds (longer than the biggest legal tank) unless the driver owns the
--   Infinite Nitro pass; a cut boost stays off until the client reports it stopped.
-- * Broadcast: "VehicleFxState"(vehicleId, boost, honk) to every player within RANGE of the car except the sender
--   (its client draws its own car). EffectsController draws the flames on the model whose VehicleId matches and plays
--   the horn there.
-- * Keep-alive: every KEEPALIVE seconds an ongoing boost is re-sent (cars racing into range see it, clients drop flames
--   whose keep-alive stopped). A driver who left the car / switched cars / left the game gets a final boost=false.
-- Purely cosmetic: nothing here touches physics, speed or nitro amounts (VehicleController owns those).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local VehicleFxService = {}

VehicleFxService.RANGE = 300
VehicleFxService.RATE = 6 -- VehicleFx calls per second per player (client sends >= 0.2 s apart)
VehicleFxService.HONK_COOLDOWN = 0.35 -- = VehicleClient's HORN_COOLDOWN: honest mashing passes, faster is spam
VehicleFxService.MIN_BOOST_EDGE = 0.5 -- boost starts closer together than this are dropped
VehicleFxService.MAX_BOOST = 10 -- s of continuous boost (biggest tank: 8 s) before the flames are cut
VehicleFxService.KEEPALIVE = 1.5 -- clients expire flames after 3.5 s without a refresh

type FxState = {
	player: Player,
	vehicleId: number,
	chassis: BasePart,
	boost: boolean,
	boostOnAt: number, -- clock of the last accepted boost start
	capped: boolean, -- boost cut at MAX_BOOST: ignore boost until the client reports false
	lastHonk: number,
	lastSent: number,
}

local states: { [Player]: FxState } = {}

-- Test seams (Lune harness): fake VehicleService.getDriving, the broadcast, the pass check and the clock.
type Hooks = {
	getDriving: ((Player) -> any)?,
	fireNear: ((name: string, except: Player?, position: Vector3, radius: number, ...any) -> ())?,
	infiniteNitro: ((Player) -> boolean)?,
	clock: () -> number,
}
local hooks: Hooks = { getDriving = nil, fireNear = nil, infiniteNitro = nil, clock = os.clock }

function VehicleFxService._setHooks(overrides: { [string]: any }?)
	hooks.getDriving = if overrides then overrides.getDriving else nil
	hooks.fireNear = if overrides then overrides.fireNear else nil
	hooks.infiniteNitro = if overrides then overrides.infiniteNitro else nil
	hooks.clock = if overrides and overrides.clock then overrides.clock else os.clock
	table.clear(states)
end

-- Lazy: VehicleService loads in the same ORDER; requiring at the top would tie our load to its load.
local systems: { [string]: any } = {}
local function sys(name: string): any
	if systems[name] == nil then
		local ms = script.Parent and script.Parent:FindFirstChild(name)
		local ok, mod = false, nil
		if ms and ms:IsA("ModuleScript") then
			ok, mod = pcall(require, ms)
		end
		systems[name] = if ok and type(mod) == "table" then mod else false
	end
	return if systems[name] then systems[name] else nil
end
local function vehicles(): any
	return sys("VehicleService")
end

-- Infinite Nitro pass: a legitimately endless boost (MonetizationService, lazy).
local function hasInfiniteNitro(player: Player): boolean
	if hooks.infiniteNitro then
		return hooks.infiniteNitro(player) == true
	end
	local ms = sys("MonetizationService")
	if not ms or type(ms.hasPass) ~= "function" then
		return false
	end
	local ok, has = pcall(ms.hasPass, player, "nitro")
	return ok and has == true
end

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------------------------------------------

-- Should a request be broadcast? Returns (send, honk, boost): a boost stop always goes out, a boost start only
-- MIN_BOOST_EDGE after the previous start (sinceBoostOn; nil = never started), a honk only past the cooldown.
-- `boost` is the state to adopt (a dropped start keeps the flames off).
function VehicleFxService.decide(
	prevBoost: boolean,
	boost: boolean,
	honk: boolean,
	sinceHonk: number,
	sinceBoostOn: number?
): (boolean, boolean, boolean)
	local honkOut = honk and sinceHonk >= VehicleFxService.HONK_COOLDOWN
	local boostOut = boost
	if boost and not prevBoost and sinceBoostOn ~= nil and sinceBoostOn < VehicleFxService.MIN_BOOST_EDGE then
		boostOut = false
	end
	return boostOut ~= prevBoost or honkOut, honkOut, boostOut
end

---------------------------------------------------------------------------------------------------------------
-- Relay
---------------------------------------------------------------------------------------------------------------

-- Net.fireNear minus `except` (the sender draws its own car's flames and horn).
local function fireNearExcept(name: string, except: Player?, position: Vector3, radius: number, ...: any)
	for _, p in Players:GetPlayers() do
		if p ~= except then
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= radius then
				Net.fireClient(name, p, ...)
			end
		end
	end
end

local function broadcast(st: FxState, boost: boolean, honk: boolean)
	local chassis = st.chassis
	if chassis.Parent == nil then
		return -- despawned: clients drop the flames with the model
	end
	st.lastSent = hooks.clock()
	local fire = hooks.fireNear or fireNearExcept
	pcall(fire, "VehicleFxState", st.player, chassis.Position, VehicleFxService.RANGE, st.vehicleId, boost, honk)
end

-- The live car this player drives, or nil.
local function drivenCar(player: Player): any
	local getDriving = hooks.getDriving
	if not getDriving then
		local vs = vehicles()
		getDriving = if vs and type(vs.getDriving) == "function" then vs.getDriving else nil
	end
	if not getDriving then
		return nil
	end
	local ok, car = pcall(getDriving, player)
	if not ok or type(car) ~= "table" or car.destroyed or car.driver ~= player or typeof(car.id) ~= "number" then
		return nil
	end
	local chassis = car.chassis
	if typeof(chassis) ~= "Instance" or not chassis:IsA("BasePart") or chassis.Parent == nil then
		return nil
	end
	return car
end

-- Close a player's flames (left the car / switched cars / left the game) and forget them.
local function endState(player: Player)
	local st = states[player]
	if not st then
		return
	end
	states[player] = nil
	if st.boost then
		broadcast(st, false, false)
	end
end

local function onVehicleFx(player: Player, boost: any, honk: any)
	if typeof(boost) ~= "boolean" or typeof(honk) ~= "boolean" then
		return
	end
	local car = drivenCar(player)
	if not car then
		return
	end
	local st = states[player]
	if st and st.vehicleId ~= car.id then
		endState(player)
		st = nil
	end
	if not st then
		st = {
			player = player,
			vehicleId = car.id,
			chassis = car.chassis,
			boost = false,
			boostOnAt = -math.huge,
			capped = false,
			lastHonk = -math.huge,
			lastSent = 0,
		}
		states[player] = st
	end
	local state = st :: FxState
	local wanted = boost :: boolean
	if state.capped then
		if wanted then
			wanted = false -- cut at MAX_BOOST: stays off until the client says it stopped
		else
			state.capped = false
		end
	end
	local now = hooks.clock()
	local send, honkOut, boostOut =
		VehicleFxService.decide(state.boost, wanted, honk, now - state.lastHonk, now - state.boostOnAt)
	if not send then
		return
	end
	if honkOut then
		state.lastHonk = now
	end
	if boostOut and not state.boost then
		state.boostOnAt = now
	end
	state.boost = boostOut
	broadcast(state, boostOut, honkOut)
end

-- Keep-alive for ongoing boosts + cleanup of drivers who left their car.
local function sweep()
	local now = hooks.clock()
	for player, st in states do
		local car = drivenCar(player)
		if not car or car.id ~= st.vehicleId or player.Parent == nil then
			endState(player)
		elseif st.boost and now - st.boostOnAt > VehicleFxService.MAX_BOOST and not hasInfiniteNitro(player) then
			st.boost = false
			st.capped = true
			broadcast(st, false, false)
		elseif st.boost and now - st.lastSent >= VehicleFxService.KEEPALIVE then
			broadcast(st, true, false)
		end
	end
end

VehicleFxService._onVehicleFx = onVehicleFx
VehicleFxService._sweep = sweep

---------------------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------------------

function VehicleFxService.init()
	Net.on("VehicleFx", onVehicleFx, VehicleFxService.RATE)
	Players.PlayerRemoving:Connect(function(player: Player)
		endState(player)
	end)
end

function VehicleFxService.start()
	while true do
		task.wait(0.5)
		if next(states) ~= nil then
			local ok, err = pcall(sweep)
			if not ok then
				warn("[VehicleFxService] sweep failed: " .. tostring(err))
			end
		end
	end
end

return VehicleFxService
