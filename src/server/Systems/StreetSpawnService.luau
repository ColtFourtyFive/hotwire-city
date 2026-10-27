--!strict
-- StreetSpawnService (docs/SPEC.md §6): keeps the city stocked with parked, hotwireable cars.
--
--  * Target count = min(MAX_COUNT, BASE_COUNT + PER_PLAYER * players) anchored "Parked" cars on random free
--    MapLayout.parkingSpots() (free = no car within SPOT_CLEAR_RADIUS). New cars prefer spots out of players' faces.
--    Rarity: Rolls.car("street", EventService.getLuck()) + Rolls.mutation(1).
--  * Parked cars rotate: after LIFETIME seconds a car nobody is near is replaced by a fresh roll, so the city keeps
--    changing and rare cars keep showing up for players who roam.
--  * "Hotwire" prompt (hold = rarity hotwireTime, server-validated by VehicleService.addStealPrompt). On steal:
--    the thief is seated (nothing else happens if seat() refuses: the car is left as unowned Loot), kind -> Loot,
--    wanted: a witness sees it with probability rarity.wantedChance and adds max(1, rarity.wantedOnSteal) stars
--    (DECISIONS §1; none on a player's first-ever steal), EventFeed + BigSteal for Legendary+, contract "steal".
--  * Luck events re-roll a share of the parked cars nobody can see (rerollOutOfView), so boosted luck shows up on
--    the street and not only in brand-new spawns.
--  * Newbie guarantee: while a player's tutorial is not done (first join), a Common parked car always sits within
--    NEWBIE_RADIUS of their garage door (tagged with attribute TutorialForUserId for the tutorial arrow).
--
-- Public API: none required by the spec. Extras: getParked(): {Car}, ensureNewbieCar(player): Car?,
--   spawnAt(groundCFrame, carId?, mutation?): Car?, rerollOutOfView(fraction): number (called by EventService when
--   Rush Hour / Server Luck starts). Pure helpers prefixed with _ for tests.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local MapConfig = require(Shared.Config.Map)
local Rarity = require(Shared.Config.Rarity)
local MapLayout = require(Shared.Util.MapLayout)
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldQuery = require(Shared.Util.WorldQuery)
local Net = require(Shared.Net)
local Rolls = require(Shared.Util.Rolls)
local VehicleService = require(script.Parent.VehicleService)

type Car = VehicleService.Car

local StreetSpawnService = {}

StreetSpawnService.BASE_COUNT = 24
StreetSpawnService.PER_PLAYER = 2
StreetSpawnService.MAX_COUNT = 44
StreetSpawnService.SPOT_CLEAR_RADIUS = 12
StreetSpawnService.PLAYER_CLEAR_RADIUS = 6 -- never spawn on top of someone
StreetSpawnService.PREFER_PLAYER_DIST = 60 -- prefer spots at least this far from every player (no pop-in)
StreetSpawnService.TICK = 2
StreetSpawnService.MAX_SPAWNS_PER_TICK = 4
StreetSpawnService.MAX_DESPAWNS_PER_TICK = 2
StreetSpawnService.LIFETIME = { 300, 540 } -- seconds before an untouched parked car may be swapped for a new roll
StreetSpawnService.ROTATE_CLEAR_RADIUS = 160 -- ...but only when no player is this close
StreetSpawnService.EXCESS_CLEAR_RADIUS = 200 -- excess cars (players left) are removed only out of view
StreetSpawnService.NEWBIE_RADIUS = 120
StreetSpawnService.NEWBIE_CHECK_EVERY = 8
StreetSpawnService.NEWBIE_WINDOW = 600 -- keep guaranteeing for this long after joining
StreetSpawnService.NEWBIE_FIRST_DEADLINE = 15
-- along-road offsets (from the door axis) of the curbside newbie spots: clear of the driveway (door 34 wide)
StreetSpawnService.CURBSIDE_OFFSETS = { 32, -32, 48, -48, 64, -64 }

type Entry = { car: Car, prompt: ProximityPrompt?, expiresAt: number, newbieFor: number? }

local entries: { [Car]: Entry } = {}
local rng = Random.new()
local newbieWatching: { [Player]: boolean } = {}

local systemCache: { [string]: any } = {}
local function sys(name: string): any
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local parent = script.Parent
	local inst = parent and parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok and type(mod) == "table" then
			systemCache[name] = mod
			return mod
		end
	end
	return nil
end

local function call(name: string, fn: string, ...: any): (boolean, any)
	local mod = sys(name)
	local f = mod and mod[fn]
	if typeof(f) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(f, ...)
	if not ok then
		warn(("[StreetSpawnService] %s.%s errored: %s"):format(name, fn, tostring(res)))
		return false, nil
	end
	return true, res
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function luck(): number
	local ok, v = call("EventService", "getLuck")
	if ok and typeof(v) == "number" and v == v and v >= 1 then
		return math.min(v, 100)
	end
	return 1
end

local function playerRoots(): { Vector3 }
	local out = {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(out, root.Position)
		end
	end
	return out
end

local function vehiclePositions(): { Vector3 }
	local out = {}
	for _, car in VehicleService.all() do
		if not car.destroyed and car.chassis.Parent then
			table.insert(out, car.chassis.CFrame.Position)
		end
	end
	return out
end

-- PURE HELPERS ---------------------------------------------------------------------------------------------------------

function StreetSpawnService._targetCount(playerCount: number): number
	return math.min(
		StreetSpawnService.MAX_COUNT,
		StreetSpawnService.BASE_COUNT + StreetSpawnService.PER_PLAYER * math.max(0, playerCount)
	)
end

-- A spot is free when no position in `occupied` is within radius (flat distance).
function StreetSpawnService._isSpotFree(spot: Vector3, occupied: { Vector3 }, radius: number): boolean
	for _, p in occupied do
		if flatDist(spot, p) < radius then
			return false
		end
	end
	return true
end

-- Min flat distance from pos to any of points (math.huge when empty).
function StreetSpawnService._minDist(pos: Vector3, points: { Vector3 }): number
	local best = math.huge
	for _, p in points do
		local d = flatDist(pos, p)
		if d < best then
			best = d
		end
	end
	return best
end

-- Garage door position (front opening, curb height) of a plot.
function StreetSpawnService._doorPosition(plotIndex: number): Vector3
	return MapLayout.plotToWorld(plotIndex, Vector3.new(0, 0, MapConfig.Garage.FRONT_Z)).Position
end

-- Unit vector out of a plot's front door (flat).
local function plotFace(plotIndex: number): Vector3
	local look = MapLayout.plotOrigin(plotIndex).LookVector
	return Vector3.new(look.X, 0, look.Z).Unit
end

-- True if pos is on the street side of the garage door (where a newbie can see it when walking out).
function StreetSpawnService._inFrontOfDoor(plotIndex: number, pos: Vector3): boolean
	local door = StreetSpawnService._doorPosition(plotIndex)
	return (pos - door):Dot(plotFace(plotIndex)) > -4
end

-- Candidate ground CFrames for a plot's newbie car, best first: parking spots and curbside spots (on the road the
-- garage faces, beside the driveway) in front of the door within NEWBIE_RADIUS, nearest first; then any other
-- parking spot within NEWBIE_RADIUS.
function StreetSpawnService._newbieSpots(plotIndex: number): { CFrame }
	local door = StreetSpawnService._doorPosition(plotIndex)
	local front: { { cf: CFrame, d: number } } = {}
	local other: { { cf: CFrame, d: number } } = {}
	for _, cf in MapLayout.parkingSpots() do
		local d = flatDist(cf.Position, door)
		if d <= StreetSpawnService.NEWBIE_RADIUS then
			local bucket = if StreetSpawnService._inFrontOfDoor(plotIndex, cf.Position) then front else other
			table.insert(bucket, { cf = cf, d = d })
		end
	end
	-- curbside beside the driveway: the plot's baked curb spot (v2 world) and steps along the curb from it
	local plot = WorldLayout.Plots[plotIndex]
	if plot then
		local base = plot.curbSpot
		for k = 0, 5 do
			-- one car length + gap (24) at a time, away from the driveway
			local p = (base * CFrame.new(0, 0, -24 * k)).Position
			local _, ei, s = WorldQuery.nearestRoadPoint(p, { maxDistance = 40 })
			if ei and WorldQuery.isOnRoad(p) then
				local _, tan = WorldQuery.edgePoint(ei, s)
				local look = if tan:Dot(base.LookVector) >= 0 then tan else -tan
				table.insert(front, { cf = CFrame.lookAt(p, p + look), d = flatDist(p, door) })
			end
		end
	end
	local function byDist(x: { cf: CFrame, d: number }, y: { cf: CFrame, d: number }): boolean
		return x.d < y.d
	end
	table.sort(front, byDist)
	table.sort(other, byDist)
	local out = {}
	for _, e in front do
		table.insert(out, e.cf)
	end
	for _, e in other do
		table.insert(out, e.cf)
	end
	return out
end

-- ROLLING / SPAWNING ---------------------------------------------------------------------------------------------------

local onStolen: (entry: Entry, player: Player) -> boolean

local function canSteal(entry: Entry, player: Player): (boolean, string?)
	local car = entry.car
	if car.destroyed or car.wrecked or car.kind ~= "Parked" or entries[car] ~= entry then
		return false, nil
	end
	if player:GetAttribute("Stunned") == true then
		return false, nil
	end
	if VehicleService.getDriving(player) ~= nil then
		return false, "You're already driving!"
	end
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
		return false, nil
	end
	return true, nil
end

onStolen = function(entry: Entry, player: Player): boolean
	local car = entry.car
	entries[car] = nil
	if entry.prompt then
		entry.prompt:Destroy()
		entry.prompt = nil
	end
	local tier = Rarity.Tiers[car.rarity] or Rarity.Tiers.Common
	car.data.source = "street"
	-- seat first so the managed Loot prompts never flash up between the two calls
	local seated, why = VehicleService.seat(car, player)
	VehicleService.setKind(car, "Loot")
	pcall(car.model.SetAttribute, car.model, "TutorialForUserId", nil)
	if not seated then
		-- nobody got in: leave an unowned Loot car (anyone may hotwire it; abandon rules clean it up), and no
		-- heat, contract credit or announcement for a steal that did not happen
		warn(("[StreetSpawnService] could not seat %s: %s"):format(player.Name, tostring(why)))
		return false
	end
	car.ownerUserId = player.UserId
	pcall(car.model.SetAttribute, car.model, "OwnerUserId", player.UserId)
	local stars = VehicleService._streetStars(tier.wantedOnSteal, tier.wantedChance, rng:NextNumber())
	local heat = VehicleService.addStealHeat(player, stars, "streetSteal")
	VehicleService.contractProgress(player, "steal", 1)
	VehicleService.announceSteal(player, car, "hotwired")
	local pos = car.chassis.CFrame.Position
	pcall(Net.fireNear, "Sound", pos, 120, "EngineStart", pos)
	if heat > 0 then
		pcall(Net.fireClient, "Notify", player, "warning", `🚨 Somebody saw that! +{heat}★`, 2.5)
	end
	return true
end

local function attachPrompt(entry: Entry)
	local car = entry.car
	local tier = Rarity.Tiers[car.rarity] or Rarity.Tiers.Common
	entry.prompt = VehicleService.addStealPrompt(car, {
		actionText = "Hotwire",
		holdDuration = tier.hotwireTime,
		objectText = VehicleService.carLabel(car),
		canSteal = function(player: Player): (boolean, string?)
			return canSteal(entry, player)
		end,
		onStolen = function(player: Player): boolean
			return onStolen(entry, player)
		end,
	})
end

-- Spawns one parked car (rolled unless carId given) at a ground CFrame. Extra public helper (admin / events).
function StreetSpawnService.spawnAt(groundCFrame: CFrame, carId: string?, mutation: string?): Car?
	local def = if carId then Cars.get(carId) else nil
	if not def then
		def = Rolls.car("street", luck(), rng)
	end
	local mut = mutation or Rolls.mutation(1, rng)
	local ok, car = pcall(VehicleService.spawn, (def :: Cars.CarDef).id, mut, groundCFrame, "Parked")
	if not ok or type(car) ~= "table" then
		warn("[StreetSpawnService] spawn failed: " .. tostring(car))
		return nil
	end
	car.data.source = "street"
	local life = StreetSpawnService.LIFETIME
	local entry: Entry = {
		car = car,
		prompt = nil,
		expiresAt = os.clock() + rng:NextNumber(life[1], life[2]),
		newbieFor = nil,
	}
	entries[car] = entry
	attachPrompt(entry)
	return car
end

-- Luck events (Rush Hour, Server Luck) only change NEW rolls: expire about `fraction` of the parked cars no player is
-- near (never a newbie car), so the next manage ticks re-roll them with the boosted luck. Returns how many.
function StreetSpawnService.rerollOutOfView(fraction: number?): number
	local f = if typeof(fraction) == "number" and fraction == fraction then math.clamp(fraction, 0, 1) else 0.5
	if f <= 0 then
		return 0
	end
	local roots = playerRoots()
	local n = 0
	for car, entry in entries do
		if entry.newbieFor ~= nil or car.destroyed or entry.expiresAt <= 0 then
			continue
		end
		local dist = StreetSpawnService._minDist(car.chassis.CFrame.Position, roots)
		if dist >= StreetSpawnService.ROTATE_CLEAR_RADIUS and rng:NextNumber() < f then
			entry.expiresAt = 0
			n += 1
		end
	end
	return n
end

function StreetSpawnService.getParked(): { Car }
	local out = {}
	for car in entries do
		if not car.destroyed then
			table.insert(out, car)
		end
	end
	return out
end

local function pruneDead()
	for car in entries do
		if car.destroyed or car.kind ~= "Parked" then
			entries[car] = nil
		end
	end
end

local function countParked(): number
	local n = 0
	for _ in entries do
		n += 1
	end
	return n
end

-- Picks a random free parking spot (prefers ones away from players). nil when the city is full.
local function pickSpot(occupied: { Vector3 }, roots: { Vector3 }): CFrame?
	local spots = MapLayout.parkingSpots()
	local n = #spots
	if n == 0 then
		return nil
	end
	local fallback: CFrame? = nil
	local start = rng:NextInteger(1, n)
	for i = 0, n - 1 do
		local cf = spots[(start + i - 1) % n + 1]
		local p = cf.Position
		if
			StreetSpawnService._isSpotFree(p, occupied, StreetSpawnService.SPOT_CLEAR_RADIUS)
			and StreetSpawnService._minDist(p, roots) >= StreetSpawnService.PLAYER_CLEAR_RADIUS
		then
			if StreetSpawnService._minDist(p, roots) >= StreetSpawnService.PREFER_PLAYER_DIST then
				return cf
			end
			fallback = fallback or cf
		end
	end
	return fallback
end

local function managePass(now: number)
	pruneDead()
	local players = Players:GetPlayers()
	if #players == 0 then
		return
	end
	local roots = playerRoots()
	local target = StreetSpawnService._targetCount(#players)
	local count = countParked()

	-- rotation + excess (out of view only, never the newbie car)
	local removed = 0
	for car, entry in entries do
		if removed >= StreetSpawnService.MAX_DESPAWNS_PER_TICK then
			break
		end
		if entry.newbieFor then
			continue
		end
		local pos = car.chassis.CFrame.Position
		local dist = StreetSpawnService._minDist(pos, roots)
		local excess = count - removed > target and dist >= StreetSpawnService.EXCESS_CLEAR_RADIUS
		local expired = now >= entry.expiresAt and dist >= StreetSpawnService.ROTATE_CLEAR_RADIUS
		if excess or expired then
			entries[car] = nil
			removed += 1
			VehicleService.destroy(car, if excess then "excess" else "rotate")
		end
	end
	count -= removed

	local need = math.min(StreetSpawnService.MAX_SPAWNS_PER_TICK, target - count)
	if need <= 0 then
		return
	end
	local occupied = vehiclePositions()
	for _ = 1, need do
		local cf = pickSpot(occupied, roots)
		if not cf then
			break
		end
		local car = StreetSpawnService.spawnAt(cf)
		table.insert(occupied, if car then car.chassis.CFrame.Position else cf.Position)
	end
end

-- NEWBIE GUARANTEE -----------------------------------------------------------------------------------------------------

local function plotIndexOf(player: Player): number?
	local attr = player:GetAttribute("PlotIndex")
	if typeof(attr) == "number" and attr >= 1 and attr <= MapLayout.plotCount() and attr % 1 == 0 then
		return attr
	end
	return nil
end

-- Makes sure a Common parked car sits near this player's garage door. Returns the car (existing or new).
function StreetSpawnService.ensureNewbieCar(player: Player): Car?
	local plot = plotIndexOf(player)
	if not plot then
		return nil
	end
	pruneDead()
	local door = StreetSpawnService._doorPosition(plot)
	for car, entry in entries do
		local pos = car.chassis.CFrame.Position
		if
			car.rarity == "Common"
			and flatDist(pos, door) <= StreetSpawnService.NEWBIE_RADIUS
			and StreetSpawnService._inFrontOfDoor(plot, pos)
		then
			if entry.newbieFor == nil then
				entry.newbieFor = player.UserId
				pcall(car.model.SetAttribute, car.model, "TutorialForUserId", player.UserId)
			end
			return car
		end
	end
	local occupied = vehiclePositions()
	local roots = playerRoots()
	for _, cf in StreetSpawnService._newbieSpots(plot) do
		local p = cf.Position
		if
			StreetSpawnService._isSpotFree(p, occupied, StreetSpawnService.SPOT_CLEAR_RADIUS)
			and StreetSpawnService._minDist(p, roots) >= StreetSpawnService.PLAYER_CLEAR_RADIUS
		then
			local def = Rolls.carOfRarity("Common", "street", rng)
			local car = StreetSpawnService.spawnAt(cf, def.id, "None")
			if car then
				local entry = entries[car]
				if entry then
					entry.newbieFor = player.UserId
				end
				pcall(car.model.SetAttribute, car.model, "TutorialForUserId", player.UserId)
				return car
			end
		end
	end
	return nil
end

local function tutorialDone(player: Player): boolean?
	local ok, data = call("DataService", "get", player)
	if not ok or type(data) ~= "table" then
		return nil
	end
	return data.tutorialDone == true
end

local function watchNewbie(player: Player)
	if newbieWatching[player] then
		return
	end
	newbieWatching[player] = true
	local joined = os.clock()
	-- wait for data + plot (bounded so the first car appears within NEWBIE_FIRST_DEADLINE)
	while player.Parent == Players and os.clock() - joined < StreetSpawnService.NEWBIE_FIRST_DEADLINE do
		if tutorialDone(player) ~= nil and plotIndexOf(player) ~= nil then
			break
		end
		task.wait(0.5)
	end
	while player.Parent == Players and os.clock() - joined < StreetSpawnService.NEWBIE_WINDOW do
		local done = tutorialDone(player)
		if done == true then
			break
		end
		if done == false and VehicleService.getDriving(player) == nil then
			local ok, err = pcall(StreetSpawnService.ensureNewbieCar, player)
			if not ok then
				warn("[StreetSpawnService] newbie car failed: " .. tostring(err))
			end
		end
		task.wait(StreetSpawnService.NEWBIE_CHECK_EVERY)
	end
	newbieWatching[player] = nil
	-- release the newbie mark so the car can rotate normally again
	for car, entry in entries do
		if entry.newbieFor == player.UserId then
			entry.newbieFor = nil
			pcall(car.model.SetAttribute, car.model, "TutorialForUserId", nil)
		end
	end
end

-- LIFECYCLE ------------------------------------------------------------------------------------------------------------

function StreetSpawnService.init()
	VehicleService.Destroyed:Connect(function(car: any)
		entries[car] = nil
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		newbieWatching[player] = nil
	end)
end

function StreetSpawnService.start()
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(watchNewbie, player)
	end)
	for _, p in Players:GetPlayers() do
		task.spawn(watchNewbie, p)
	end
	while true do
		local ok, err = pcall(managePass, os.clock())
		if not ok then
			warn("[StreetSpawnService] manage pass failed: " .. tostring(err))
		end
		task.wait(StreetSpawnService.TICK)
	end
end

return StreetSpawnService
