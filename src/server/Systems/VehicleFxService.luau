--!strict
-- VehicleFxService (AP4): relays a driver's cosmetic nitro / horn state to nearby players.
--
-- * VehicleFx(boost: boolean, honk: boolean) from VehicleClient: sent on nitro start / stop and on horn presses only.
--   Validated: both args booleans, the sender is the current driver of a live car (VehicleService.getDriving, lazy),
--   Net rate limit RATE/s, horns at most one per HONK_COOLDOWN, unchanged boost without a honk is dropped.
-- * Broadcast: Net.fireNear("VehicleFxState", carPosition, RANGE, vehicleId, boost, honk). EffectsController draws the
--   flames on the model whose VehicleId matches and plays the horn there (the sender's own client skips its own car).
-- * Keep-alive: every KEEPALIVE seconds an ongoing boost is re-sent (cars racing into range see it, clients drop flames
--   whose keep-alive stopped). A driver who left the car / switched cars / left the game gets a final boost=false.
-- Purely cosmetic: nothing here touches physics, speed or nitro amounts (VehicleController owns those).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local VehicleFxService = {}

VehicleFxService.RANGE = 300
VehicleFxService.RATE = 6 -- VehicleFx calls per second per player (client sends >= 0.2 s apart)
VehicleFxService.HONK_COOLDOWN = 0.3
VehicleFxService.KEEPALIVE = 1.5 -- clients expire flames after 3.5 s without a refresh

type FxState = {
	vehicleId: number,
	chassis: BasePart,
	boost: boolean,
	lastHonk: number,
	lastSent: number,
}

local states: { [Player]: FxState } = {}

-- Test seams (Lune harness): fake VehicleService.getDriving, Net.fireNear and the clock.
type Hooks = {
	getDriving: ((Player) -> any)?,
	fireNear: ((name: string, position: Vector3, radius: number, ...any) -> ())?,
	clock: () -> number,
}
local hooks: Hooks = { getDriving = nil, fireNear = nil, clock = os.clock }

function VehicleFxService._setHooks(overrides: { [string]: any }?)
	hooks.getDriving = if overrides then overrides.getDriving else nil
	hooks.fireNear = if overrides then overrides.fireNear else nil
	hooks.clock = if overrides and overrides.clock then overrides.clock else os.clock
	table.clear(states)
end

-- Lazy: VehicleService loads in the same ORDER; requiring at the top would tie our load to its load.
local vehicleService: any = nil
local function vehicles(): any
	if vehicleService == nil then
		local ms = script.Parent and script.Parent:FindFirstChild("VehicleService")
		local ok, mod = false, nil
		if ms and ms:IsA("ModuleScript") then
			ok, mod = pcall(require, ms)
		end
		vehicleService = if ok and type(mod) == "table" then mod else false
	end
	return if vehicleService then vehicleService else nil
end

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------------------------------------------

-- Should a request be broadcast? Returns (send, honk): a boost change always goes out; a honk only past the cooldown.
function VehicleFxService.decide(
	prevBoost: boolean,
	boost: boolean,
	honk: boolean,
	sinceHonk: number
): (boolean, boolean)
	local honkOut = honk and sinceHonk >= VehicleFxService.HONK_COOLDOWN
	return boost ~= prevBoost or honkOut, honkOut
end

---------------------------------------------------------------------------------------------------------------
-- Relay
---------------------------------------------------------------------------------------------------------------

local function broadcast(st: FxState, boost: boolean, honk: boolean)
	local chassis = st.chassis
	if chassis.Parent == nil then
		return -- despawned: clients drop the flames with the model
	end
	st.lastSent = hooks.clock()
	local fire = hooks.fireNear or Net.fireNear
	pcall(fire, "VehicleFxState", chassis.Position, VehicleFxService.RANGE, st.vehicleId, boost, honk)
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
		st = { vehicleId = car.id, chassis = car.chassis, boost = false, lastHonk = -math.huge, lastSent = 0 }
		states[player] = st
	end
	local state = st :: FxState
	local now = hooks.clock()
	local send, honkOut = VehicleFxService.decide(state.boost, boost, honk, now - state.lastHonk)
	if not send then
		return
	end
	if honkOut then
		state.lastHonk = now
	end
	state.boost = boost
	broadcast(state, boost, honkOut)
end

-- Keep-alive for ongoing boosts + cleanup of drivers who left their car.
local function sweep()
	local now = hooks.clock()
	for player, st in states do
		local car = drivenCar(player)
		if not car or car.id ~= st.vehicleId or player.Parent == nil then
			endState(player)
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
