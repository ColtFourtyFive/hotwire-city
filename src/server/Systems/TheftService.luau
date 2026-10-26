--!strict
-- TheftService (SPEC §6): player -> player car theft, the drama engine.
--
-- Flow: a thief holds the StealPrompt on a display car in someone else's garage (GarageService validates the hold
-- and calls beginTheft). We validate everything (_canSteal gives a reason code + friendly text), flip the victim's slot
-- to "BeingStolen" (GarageService removes the display), spawn a drivable "Stolen" car on the slot pad facing the
-- aisle, seat the thief, add heat, alarm the victim and point the thief home. Delivery into the thief's own drop-off
-- is routed by GarageService to complete(car) (atomic transfer). Every failure path (time limit, wreck, bust, thief
-- leaving, dropped car timing out) restores the victim's slot EXACTLY ONCE: a car is never lost or duplicated.
--
-- Dropped cars: when the driver seat empties mid-theft the car sits "dropped" (DROPPED_CAR_TIMEOUT if the thief was
-- knocked out, THEFT_ABANDON_LIMIT if they just hopped out). The victim gets an instant RecoverPrompt (0.3s hold,
-- shown only to them via the OnlyUserId attribute); everybody else gets a Hotwire takeover prompt (VehicleService
-- addStealPrompt, ~1.5s hold, hidden for the victim via HideForUserId) and becomes the new thief.
--
-- Public API: beginTheft, complete, fail, recover, isBeingStolen, getActiveTheft, getTheftForCar, onThiefHit,
-- signals TheftStarted(theft) / TheftEnded(theft, outcome). Pure helpers prefixed with _ are exposed for tests.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local MapConfig = require(Shared.Config.Map)
local MapLayout = require(Shared.Util.MapLayout)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local PoliceConfig = require(Shared.Config.Police)
local Rarity = require(Shared.Config.Rarity)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local G = MapConfig.Garage

local TheftService = {}

TheftService.TICK = 0.5
TheftService.TAKEOVER_HOLD = 1.5 -- seconds to hotwire a dropped stolen car (before the player's hotwire multiplier)
TheftService.RECOVER_HOLD = 0.3
TheftService.SEAT_GRACE = 2 -- seconds after seating before an empty seat counts as "dropped" (seat replication lag)
TheftService.KNOCKOUT_WINDOW = 3 -- a hit this recent when the seat empties = knocked out (longer drop timer)
TheftService.REVENGE_WINDOW = 300 -- bonk the player who robbed you within this many seconds for a revenge bonus
TheftService.MIN_BONUS = 100 -- recovery / revenge bonus floor (new players have tiny incomes)
TheftService.TAKEOVER_MIN_TIME = 60 -- a hijacker gets at least this many seconds to deliver
TheftService.WAYPOINT_EVERY = 1 -- seconds between "get back in" waypoint updates while a car sits dropped
TheftService.PROMPT_DISTANCE = 14
TheftService.MAX_INSIDE_SLOT_DISTANCE = 26 -- thief root must be this close to the slot pad (prompt range + slack)
TheftService.LOST_Y = MapConfig.WATER_LEVEL - 6 -- car sank / fell off the map below this

TheftService.TheftStarted = Signal.new() -- (theft)
TheftService.TheftEnded = Signal.new() -- (theft, outcome: "delivered" | "recovered" | <fail reason>)

local THIEF_COLOR = Color3.fromRGB(70, 235, 110)
local WAYPOINT_THEFT = "theft" -- thief: drop-off (or the dropped car)
local WAYPOINT_VICTIM = "stolen_car" -- victim's live arrow (owned client-side by NotificationController); cleared here

export type Theft = {
	id: number,
	car: any, -- VehicleService Car
	victim: Player,
	victimUserId: number,
	victimName: string,
	thief: Player,
	thiefUserId: number,
	slot: number,
	carId: string,
	mutation: string,
	label: string,
	startedAt: number, -- hooks.clock() time
	endsAt: number, -- hooks.clock() deadline (THEFT_TIME_LIMIT)
	graceUntil: number,
	dropped: boolean,
	droppedUntil: number,
	lastHitAt: number,
	lastHitBy: Player?,
	revengePaid: boolean,
	finished: boolean,
	warned30: boolean,
	warned10: boolean,
	lastWaypointAt: number,
	lastWaypointPos: Vector3?,
	lastFullNotifyAt: number,
	trove: any, -- Trove for drop prompts
	recoverPrompt: Instance?,
	takeoverPrompt: Instance?,
}

-- Injectable dependencies (tests run headlessly in Lune) ------------------------------------------------------------

local systemCache: { [string]: any } = {}
local function loadSystem(name: string): any
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local parent = script.Parent
	local inst = parent and parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok and mod then
			systemCache[name] = mod
			return mod
		end
		warn(("[TheftService] could not load %s: %s"):format(name, tostring(mod)))
	end
	return nil
end

local function defaultRootOf(player: any): (BasePart?, Humanoid?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	return if root and root:IsA("BasePart") then root else nil, hum
end

local hooks = {
	isTest = false,
	clock = os.clock,
	serverNow = function(): number
		return Workspace:GetServerTimeNow()
	end,
	system = loadSystem,
	isOnline = function(player: any): boolean
		return player.Parent == Players
	end,
	rootOf = defaultRootOf,
	fireClient = function(name: string, player: Player, ...: any)
		Net.fireClient(name, player, ...)
	end,
	fireAll = function(name: string, ...: any)
		Net.fireAll(name, ...)
	end,
	fireNear = function(name: string, position: Vector3, radius: number, ...: any)
		Net.fireNear(name, position, radius, ...)
	end,
	spawnTask = function(fn: (...any) -> (), ...: any)
		task.spawn(fn, ...)
	end,
}

-- Tests only: override clock / system loader / remote firing / player helpers.
function TheftService._setHooks(overrides: { [string]: any })
	for k, v in overrides do
		(hooks :: any)[k] = v
	end
	table.clear(systemCache)
end

local function sys(name: string): any
	return hooks.system(name)
end

local function call(name: string, fn: string, ...: any): (boolean, any)
	local mod = sys(name)
	local f = mod and mod[fn]
	if typeof(f) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(f, ...)
	if not ok then
		warn(("[TheftService] %s.%s errored: %s"):format(name, fn, tostring(res)))
		return false, nil
	end
	return true, res
end

local function fireClient(name: string, player: Player, ...: any)
	local ok, err = pcall(hooks.fireClient, name, player, ...)
	if not ok then
		warn(("[TheftService] fireClient %s failed: %s"):format(name, tostring(err)))
	end
end

local function fireAll(name: string, ...: any)
	local ok, err = pcall(hooks.fireAll, name, ...)
	if not ok then
		warn(("[TheftService] fireAll %s failed: %s"):format(name, tostring(err)))
	end
end

local function fireNear(name: string, position: Vector3, radius: number, ...: any)
	pcall(hooks.fireNear, name, position, radius, ...)
end

local function notify(player: Player, kind: string, text: string, duration: number?)
	fireClient("Notify", player, kind, text, duration)
end

local function isPlayer(v: any): boolean
	if typeof(v) == "Instance" then
		return v:IsA("Player")
	end
	return hooks.isTest and type(v) == "table" and type(v.UserId) == "number"
end

local function online(player: any): boolean
	return isPlayer(player) and hooks.isOnline(player)
end

local function richEscape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function hex(c: Color3): string
	return string.format(
		"%02X%02X%02X",
		math.clamp(math.floor(c.R * 255 + 0.5), 0, 255),
		math.clamp(math.floor(c.G * 255 + 0.5), 0, 255),
		math.clamp(math.floor(c.B * 255 + 0.5), 0, 255)
	)
end

local function carLabel(carId: string, mutation: string): string
	local def = Cars.get(carId)
	local name = if def then def.name else carId
	local mut = Rarity.getMutation(mutation :: any)
	if mut.label ~= "" then
		return mut.label .. " " .. name
	end
	return name
end

-- "<font color=#hex><b>GOLD Viper Strike</b></font>" for the event feed.
local function richCar(carId: string, mutation: string): string
	local def = Cars.get(carId)
	local tier = def and Rarity.Tiers[def.rarity]
	local color = if tier then tier.color else Color3.new(1, 1, 1)
	if def and def.rarity == "Secret" then
		color = Color3.fromRGB(255, 80, 210) -- Secret's swatch is near-black; use a readable hot pink in text
	end
	return `<font color="#{hex(color)}"><b>{richEscape(carLabel(carId, mutation))}</b></font>`
end

local function rarityOrder(carId: string): number
	local def = Cars.get(carId)
	local tier = def and Rarity.Tiers[def.rarity]
	return if tier then tier.order else 1
end

local function nameOf(player: any): string
	local ok, n = pcall(function()
		return player.DisplayName
	end)
	return if ok and typeof(n) == "string" then n else "Someone"
end

local function getData(player: Player): any
	local _, data = call("DataService", "get", player)
	return data
end

local function plotIndexOf(player: Player): number?
	local _, idx = call("PlotService", "getPlotIndex", player)
	return if typeof(idx) == "number" then idx else nil
end

local function incomeOf(player: Player): number
	local _, inc = call("GarageService", "incomePerSec", player)
	return if typeof(inc) == "number" and inc == inc then inc else 0
end

local function progress(player: Player, stat: string, amount: number)
	call("RewardsService", "progress", player, stat, amount)
end

local function toServerTime(clockTime: number): number
	return hooks.serverNow() + (clockTime - hooks.clock())
end

local function padTop(): number
	local PlotService = sys("PlotService")
	return if PlotService and typeof(PlotService.PAD_TOP) == "number" then PlotService.PAD_TOP else 0.25
end

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------------------------------------------------

export type StealState = {
	isSelf: boolean,
	victimOnline: boolean,
	victimLoaded: boolean,
	thiefLoaded: boolean,
	thiefAlive: boolean,
	thiefStunned: boolean,
	thiefDriving: boolean,
	thiefBusy: boolean, -- already running a theft
	hasCar: boolean, -- the slot holds a car
	slotParked: boolean, -- ...and it is on display
	stealable: boolean,
	locked: boolean, -- victim's laser gate is up
	inside: boolean, -- thief is inside the victim's garage
	victimCars: number,
	victimBusy: boolean, -- victim already has a car being stolen
	cooldownLeft: number, -- seconds of victim protection left
	thiefHasPlot: boolean,
	thiefFreeSlots: number,
}

-- Seconds left on a cooldown deadline, rounded UP so "try again in 1s" never shows 0.
function TheftService._cooldownLeft(cooldownUntil: number?, now: number): number
	if not cooldownUntil or cooldownUntil <= now then
		return 0
	end
	return math.ceil(cooldownUntil - now)
end

-- Validates a theft attempt. Returns (ok, reasonCode, friendlyMessage). The first failing rule wins, ordered so
-- the most useful message is shown (e.g. a locked gate beats "too new").
function TheftService._canSteal(s: StealState): (boolean, string, string)
	if s.isSelf then
		return false, "self", "That's your own car!"
	elseif not s.victimOnline then
		return false, "offline", "They left the game."
	elseif not s.victimLoaded or not s.thiefLoaded then
		return false, "loading", "Still loading. Try again in a sec!"
	elseif not s.thiefAlive then
		return false, "dead", "You can't steal right now."
	elseif s.thiefStunned then
		return false, "stunned", "💫 You're seeing stars!"
	elseif s.thiefDriving then
		return false, "driving", "Hop out of your car first!"
	elseif s.thiefBusy then
		return false, "busy", "Finish your current heist first!"
	elseif not s.hasCar or not s.slotParked then
		return false, "gone", "That car isn't there anymore."
	elseif not s.stealable then
		return false, "unstealable", "💎 That car can't be stolen!"
	elseif s.locked then
		return false, "locked", "🔒 Garage locked!"
	elseif not s.inside then
		return false, "outside", "Get inside their garage first!"
	elseif s.victimCars < Economy.NEWBIE_PROTECTION_CARS then
		return false, "newbie", "🛡️ Too new to rob (protected)"
	elseif s.victimBusy then
		return false, "victimBusy", "🚨 They're already being robbed!"
	elseif s.cooldownLeft > 0 then
		return false, "cooldown", `⏳ They were just robbed — try again in {s.cooldownLeft}s`
	elseif not s.thiefHasPlot then
		return false, "noPlot", "You need a garage first!"
	elseif s.thiefFreeSlots <= 0 then
		return false, "full", "📦 Your garage is full! Sell a car first."
	end
	return true, "ok", ""
end

-- How long a car sits "dropped" before it is towed home. Knocked-out thieves leave a longer window (fair chase for
-- the victim and for hijackers); a thief who simply hopped out gets the shorter abandon limit.
function TheftService._dropTimeout(knockedOut: boolean): number
	return if knockedOut then Economy.DROPPED_CAR_TIMEOUT else Economy.THEFT_ABANDON_LIMIT
end

-- Bonus cash = seconds of income, never below MIN_BONUS. Whole dollars.
function TheftService._bonus(incomePerSec: number, seconds: number): number
	local inc = if incomePerSec == incomePerSec and incomePerSec > 0 then incomePerSec else 0
	return math.max(TheftService.MIN_BONUS, math.floor(inc * seconds))
end

-- Deadline after a hijack: never shorter than TAKEOVER_MIN_TIME from now.
function TheftService._takeoverDeadline(endsAt: number, now: number): number
	return math.max(endsAt, now + TheftService.TAKEOVER_MIN_TIME)
end

-- Friendly lines for each fail reason: (victimText, thiefText).
function TheftService._failText(reason: string, carName: string, victimName: string): (string, string)
	if reason == "timeout" then
		return `⏱️ The thief ran out of time. Your {carName} is back home!`,
			"⏱️ Too slow! The car went back home."
	elseif reason == "busted" then
		return `🚔 The cops busted the thief! Your {carName} is back home.`,
			`🚔 Busted! The {carName} went back home.`
	elseif reason == "wrecked" then
		return `💥 Your {carName} got wrecked... and towed home. Phew!`, "💥 Wrecked! The car got towed home."
	elseif reason == "thief_left" then
		return `🏃 The thief left the game. Your {carName} is back home!`, ""
	elseif reason == "dropped" then
		return `🚚 Your {carName} was towed back home.`, `🚚 Too late! The {carName} got towed home.`
	elseif reason == "lost" then
		return `🌊 Your {carName} took a swim... and got towed home.`, "🌊 Splash! The car got towed home."
	elseif reason == "victim_left" then
		return "", `😶 {victimName} left. The {carName} vanished!`
	end
	return `🏠 Your {carName} is back home.`, `The {carName} went back home.`
end

---------------------------------------------------------------------------------------------------------------------
-- Runtime state
---------------------------------------------------------------------------------------------------------------------

local byCar: { [any]: Theft } = {}
local byThief: { [any]: Theft } = {}
local byVictim: { [any]: { [number]: Theft } } = {}
local cooldownUntil: { [number]: number } = {} -- victim userId -> clock deadline
local recentRobbers: { [number]: { [number]: number } } = {} -- victimUserId -> thiefUserId -> expires
local nextId = 0

local function victimThefts(victim: any): { [number]: Theft }
	local map = byVictim[victim]
	if not map then
		map = {}
		byVictim[victim] = map
	end
	return map
end

local function unregister(theft: Theft)
	if byCar[theft.car] == theft then
		byCar[theft.car] = nil
	end
	if byThief[theft.thief] == theft then
		byThief[theft.thief] = nil
	end
	local map = byVictim[theft.victim]
	if map and map[theft.slot] == theft then
		map[theft.slot] = nil
		if next(map) == nil then
			byVictim[theft.victim] = nil
		end
	end
end

local function setCooldown(victimUserId: number, now: number)
	local untilT = now + Economy.THEFT_VICTIM_COOLDOWN
	cooldownUntil[victimUserId] = math.max(cooldownUntil[victimUserId] or 0, untilT)
end

local function carModel(car: any): Model?
	local m = car and car.model
	if typeof(m) == "Instance" and m:IsA("Model") then
		return m
	end
	return nil
end

local function carPosition(car: any): Vector3?
	local chassis = car and car.chassis
	if typeof(chassis) == "Instance" and chassis:IsA("BasePart") then
		return chassis.Position
	end
	local model = carModel(car)
	if model and model.Parent then
		return model:GetPivot().Position
	end
	return nil
end

local function carAlive(car: any): boolean
	if hooks.isTest and car and car._alive ~= nil then
		return car._alive == true
	end
	local model = carModel(car)
	return model ~= nil and model.Parent ~= nil
end

local function driverOf(car: any): Player?
	local d = car and car.driver
	if d ~= nil and isPlayer(d) then
		return d
	end
	local seat = car and car.seat
	if typeof(seat) == "Instance" and seat:IsA("VehicleSeat") then
		local occ = seat.Occupant
		if occ and occ.Parent then
			return Players:GetPlayerFromCharacter(occ.Parent)
		end
	end
	return nil
end

local function isDriving(player: Player): boolean
	if player:GetAttribute("Driving") == true then
		return true
	end
	local ok, car = call("VehicleService", "getDriving", player)
	if ok and car ~= nil then
		return true
	end
	local _, hum = hooks.rootOf(player)
	return hum ~= nil and (hum :: any).SeatPart ~= nil
end

local function isAlive(player: Player): boolean
	local root, hum = hooks.rootOf(player)
	return root ~= nil and hum ~= nil and hum.Health > 0
end

local function setModelAttr(car: any, key: string, value: any)
	local model = carModel(car)
	if model then
		pcall(model.SetAttribute, model, key, value)
	end
end

local function destroyCar(car: any, reason: string)
	if hooks.isTest and type(car) == "table" then
		car._alive = false
	end
	local VS = sys("VehicleService")
	if VS then
		if typeof(VS.eject) == "function" then
			pcall(VS.eject, car)
		end
		if typeof(VS.destroy) == "function" then
			local ok, err = pcall(VS.destroy, car, reason)
			if ok then
				return
			end
			warn("[TheftService] VehicleService.destroy failed: " .. tostring(err))
		end
	end
	local model = carModel(car)
	if model then
		model:Destroy()
	end
end

-- Client UI ----------------------------------------------------------------------------------------------------------

local function dropoffPosition(plotIndex: number?): Vector3?
	if not plotIndex then
		return nil
	end
	local ok, cf = pcall(MapLayout.plotToWorld, plotIndex, G.DROPOFF_CENTER)
	return if ok then cf.Position + Vector3.new(0, 3, 0) else nil
end

local function sendThiefState(theft: Theft)
	if not online(theft.thief) then
		return
	end
	local plot = plotIndexOf(theft.thief)
	fireClient("TheftState", theft.thief, {
		active = true,
		endsAt = toServerTime(theft.endsAt),
		carId = theft.carId,
		mutation = theft.mutation,
		targetPlot = plot,
		victimName = theft.victimName,
		dropped = theft.dropped,
		droppedEndsAt = if theft.dropped then toServerTime(theft.droppedUntil) else nil,
	})
	if theft.dropped then
		local pos = carPosition(theft.car)
		if pos then
			fireClient("Waypoint", theft.thief, WAYPOINT_THEFT, pos + Vector3.new(0, 4, 0), THIEF_COLOR, "GET BACK IN!")
		end
	else
		local pos = dropoffPosition(plot)
		if pos then
			fireClient("Waypoint", theft.thief, WAYPOINT_THEFT, pos, THIEF_COLOR, "DROP OFF")
		end
	end
end

local function clearThiefUI(player: Player)
	if online(player) then
		fireClient("TheftState", player, { active = false })
		fireClient("Waypoint", player, WAYPOINT_THEFT, nil)
	end
end

local function clearVictimUI(theft: Theft, thiefName: string)
	if online(theft.victim) then
		fireClient("CarStolenAlert", theft.victim, thiefName, theft.carId, theft.mutation, false)
		fireClient("Waypoint", theft.victim, WAYPOINT_VICTIM, nil)
	end
end

local function updateWaypoints(theft: Theft, now: number, force: boolean?)
	if not theft.dropped then
		return
	end
	if not force and now - theft.lastWaypointAt < TheftService.WAYPOINT_EVERY then
		return
	end
	local pos = carPosition(theft.car)
	if not pos then
		return
	end
	local last = theft.lastWaypointPos
	if not force and last and (last - pos).Magnitude < 4 then
		return
	end
	theft.lastWaypointAt = now
	theft.lastWaypointPos = pos
	local marker = pos + Vector3.new(0, 4, 0)
	-- The victim's arrow is tracked live client-side (NotificationController follows the thief / dropped car under
	-- the "stolen_car" id on CarStolenAlert), so only the thief's "get back in" arrow comes from here.
	if theft.dropped and online(theft.thief) then
		fireClient("Waypoint", theft.thief, WAYPOINT_THEFT, marker, THIEF_COLOR, "GET BACK IN!")
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Ending a theft (the ONLY places a theft finishes)
---------------------------------------------------------------------------------------------------------------------

local clearDropped: (Theft) -> ()

-- Returns the victim's car to its slot exactly once. Safe if the victim left (their data still holds the record).
local function restoreVictimSlot(theft: Theft): boolean
	if not online(theft.victim) then
		return false -- leaving: the record never left data.garage, it is saved with them
	end
	local data = getData(theft.victim)
	local rec = data and data.garage and data.garage[tostring(theft.slot)]
	if not rec or rec.carId ~= theft.carId then
		return false
	end
	-- restoreSlot is idempotent in GarageService (Parked + display only if missing); finish() guarantees we get
	-- here at most once per theft.
	local ok = call("GarageService", "restoreSlot", theft.victim, theft.slot)
	return ok
end

-- Marks a theft finished + unregisters + clears every bit of UI. Does not touch garages or the car.
local function finish(theft: Theft, outcome: string): boolean
	if theft.finished then
		return false
	end
	theft.finished = true
	clearDropped(theft)
	unregister(theft)
	clearThiefUI(theft.thief)
	clearVictimUI(theft, nameOf(theft.thief))
	setCooldown(theft.victimUserId, hooks.clock())
	setModelAttr(theft.car, "TheftActive", false)
	TheftService.TheftEnded:Fire(theft, outcome)
	return true
end

-- Ends a theft without a transfer: car back home (unless the victim left), car destroyed, both sides told why.
local function failTheft(theft: Theft, reason: string, skipDestroy: boolean?): boolean
	if not finish(theft, reason) then
		return false
	end
	-- destroy first so the rebuilt display never overlaps the drivable car
	if not skipDestroy and carAlive(theft.car) then
		destroyCar(theft.car, "theft_" .. reason)
	end
	local restored = false
	if reason ~= "victim_left" then
		restored = restoreVictimSlot(theft)
	end
	local carName = theft.label
	local victimText, thiefText = TheftService._failText(reason, carName, theft.victimName)
	if victimText ~= "" and online(theft.victim) then
		notify(theft.victim, if restored then "success" else "info", victimText)
		if restored then
			fireClient("Sound", theft.victim, "Pickup")
		end
	end
	if thiefText ~= "" and online(theft.thief) then
		notify(theft.thief, "warning", thiefText)
	end
	return true
end

---------------------------------------------------------------------------------------------------------------------
-- Dropped cars: Recover (victim) + Hotwire takeover (everyone else)
---------------------------------------------------------------------------------------------------------------------

local takeover: (Theft, Player) -> boolean

local function canTakeover(theft: Theft, player: Player): (boolean, string?)
	if theft.finished or not theft.dropped then
		return false, nil
	end
	if player == theft.victim then
		return false, "That's YOUR car! Hit Recover!"
	end
	if not isAlive(player) then
		return false, nil
	end
	if player:GetAttribute("Stunned") == true then
		return false, "💫 You're seeing stars!"
	end
	local other = byThief[player]
	if other and other ~= theft then
		return false, "Finish your current heist first!"
	end
	if isDriving(player) then
		return false, "Hop out of your car first!"
	end
	if not getData(player) then
		return false, "Still loading. Try again in a sec!"
	end
	if not plotIndexOf(player) then
		return false, "You need a garage first!"
	end
	if player ~= theft.thief then
		local _, free = call("GarageService", "freeSlots", player)
		if typeof(free) ~= "number" or free <= 0 then
			return false, "📦 Your garage is full! Sell a car first."
		end
	end
	return true, nil
end

-- Fallback hold validation for prompts we create ourselves (VehicleService does this for addStealPrompt).
local function holdMultiplier(player: Player): number
	local data = getData(player)
	local level = if data and data.upgrades then data.upgrades.hotwire or 0 else 0
	local mult = EconomyMath.upgradeValue("hotwire", level)
	local _, pass = call("MonetizationService", "hasPass", player, "hotwire")
	if pass == true then
		mult *= Monetization.MASTER_THIEF_MULT
	end
	local attr = player:GetAttribute("HoldMultiplier")
	if typeof(attr) == "number" and attr == attr and attr > 0 then
		mult = math.min(mult, attr)
	end
	return mult
end

local function makePrompt(name: string, action: string, object: string, hold: number): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.Name = name
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = hold
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.GamepadKeyCode = Enum.KeyCode.ButtonX
	pp.RequiresLineOfSight = false
	pp.MaxActivationDistance = TheftService.PROMPT_DISTANCE
	pp.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	return pp
end

local function withinReach(player: Player, car: any, maxDistance: number): boolean
	local root = hooks.rootOf(player)
	local pos = carPosition(car)
	return root ~= nil and pos ~= nil and (root.Position - pos).Magnitude <= maxDistance
end

local function addDropPrompts(theft: Theft)
	local car = theft.car
	local chassis = car and car.chassis
	if typeof(chassis) ~= "Instance" or not chassis:IsA("BasePart") then
		return
	end
	local trove = theft.trove
	local label = theft.label

	-- Recover: victim only (OnlyUserId lets every client hide it locally; the server re-checks).
	if not theft.recoverPrompt then
		local holds: { [Player]: number } = {}
		local pp = makePrompt("RecoverPrompt", "Recover!", "Your " .. label, TheftService.RECOVER_HOLD)
		pp.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
		pp:SetAttribute("OnlyUserId", theft.victimUserId)
		trove:Connect(pp.PromptButtonHoldBegan, function(p: Player)
			holds[p] = hooks.clock()
		end)
		trove:Connect(pp.Triggered, function(p: Player)
			local began = holds[p]
			holds[p] = nil
			if p ~= theft.victim or theft.finished or not theft.dropped then
				return
			end
			if not began or hooks.clock() - began < TheftService.RECOVER_HOLD * 0.5 then
				return
			end
			if not withinReach(p, car, TheftService.PROMPT_DISTANCE + 8) then
				return
			end
			TheftService.recover(car, p)
		end)
		pp.Parent = chassis
		trove:Add(pp)
		theft.recoverPrompt = pp
	end

	-- Takeover: anyone but the victim (incl. the original thief getting back in).
	if not theft.takeoverPrompt then
		local VS = sys("VehicleService")
		local object = `{theft.victimName}'s {label}`
		local created: Instance? = nil
		if VS and typeof(VS.addStealPrompt) == "function" then
			local before: { [Instance]: boolean } = {}
			for _, d in chassis:GetDescendants() do
				if d:IsA("ProximityPrompt") then
					before[d] = true
				end
			end
			local ok, ret = pcall(VS.addStealPrompt, car, {
				actionText = "Hotwire",
				objectText = object,
				holdDuration = TheftService.TAKEOVER_HOLD,
				canSteal = function(p: Player): (boolean, string?)
					return canTakeover(theft, p)
				end,
				onStolen = function(p: Player)
					takeover(theft, p)
				end,
			})
			if ok then
				if typeof(ret) == "Instance" and ret:IsA("ProximityPrompt") then
					created = ret
				else
					for _, d in chassis:GetDescendants() do
						if d:IsA("ProximityPrompt") and not before[d] and d ~= theft.recoverPrompt then
							created = d
							break
						end
					end
				end
			else
				warn("[TheftService] addStealPrompt failed: " .. tostring(ret))
			end
		end
		if not created then
			-- Fallback: our own prompt with server-side hold validation.
			local holds: { [Player]: number } = {}
			local pp = makePrompt("StealPrompt", "Hotwire", object, TheftService.TAKEOVER_HOLD)
			pp:SetAttribute("BaseHoldDuration", TheftService.TAKEOVER_HOLD)
			trove:Connect(pp.PromptButtonHoldBegan, function(p: Player)
				holds[p] = hooks.clock()
			end)
			trove:Connect(pp.Triggered, function(p: Player)
				local began = holds[p]
				holds[p] = nil
				local required = TheftService.TAKEOVER_HOLD * holdMultiplier(p) * 0.9
				if not began or hooks.clock() - began < required then
					return
				end
				if not withinReach(p, car, TheftService.PROMPT_DISTANCE + 8) then
					return
				end
				local ok, why = canTakeover(theft, p)
				if not ok then
					if why then
						notify(p, "error", why)
					end
					return
				end
				takeover(theft, p)
			end)
			pp.Parent = chassis
			created = pp
		end
		if created then
			pcall(created.SetAttribute, created, "HideForUserId", theft.victimUserId)
			trove:Add(created)
			theft.takeoverPrompt = created
		end
	end
end

clearDropped = function(theft: Theft)
	theft.recoverPrompt = nil
	theft.takeoverPrompt = nil
	if theft.trove then
		theft.trove:Clean()
	end
	if theft.dropped then
		theft.dropped = false
		setModelAttr(theft.car, "Dropped", false)
	end
end

local function markDropped(theft: Theft, now: number)
	if theft.finished or theft.dropped then
		return
	end
	local thief = theft.thief
	local knocked = not online(thief)
		or not isAlive(thief)
		or thief:GetAttribute("Stunned") == true
		or now - theft.lastHitAt <= TheftService.KNOCKOUT_WINDOW
	local timeout = TheftService._dropTimeout(knocked)
	theft.dropped = true
	theft.droppedUntil = now + timeout
	setModelAttr(theft.car, "Dropped", true)
	setModelAttr(theft.car, "DroppedEndsAt", toServerTime(theft.droppedUntil))
	local ok, err = pcall(addDropPrompts, theft)
	if not ok then
		warn("[TheftService] drop prompts failed: " .. tostring(err))
	end

	if online(theft.victim) then
		notify(
			theft.victim,
			"warning",
			`💥 Your {theft.label} was dropped! Grab it back in {math.floor(timeout)}s!`,
			4
		)
		fireClient("Sound", theft.victim, "Notify")
	end
	if online(thief) then
		notify(thief, "warning", `Get back in! The car gets towed in {math.floor(timeout)}s!`, 4)
		sendThiefState(theft)
	end
	local hitter = theft.lastHitBy
	if knocked and hitter and now - theft.lastHitAt <= TheftService.KNOCKOUT_WINDOW and online(hitter) then
		fireAll(
			"EventFeed",
			`🔨 <b>{richEscape(nameOf(hitter))}</b> knocked <b>{richEscape(nameOf(thief))}</b> out of {richEscape(
				theft.victimName
			)}'s {richCar(theft.carId, theft.mutation)}!`
		)
	end
	updateWaypoints(theft, now, true)
end

local function resume(theft: Theft, now: number)
	if not theft.dropped then
		return
	end
	clearDropped(theft)
	theft.graceUntil = now + TheftService.SEAT_GRACE
	sendThiefState(theft)
end

takeover = function(theft: Theft, player: Player): boolean
	local ok, why = canTakeover(theft, player)
	if not ok then
		if why then
			notify(player, "error", why)
		end
		return false
	end
	local now = hooks.clock()
	local old = theft.thief
	if player ~= old then
		if byThief[old] == theft then
			byThief[old] = nil
		end
		clearThiefUI(old)
		if online(old) then
			notify(old, "error", `😱 {nameOf(player)} hijacked your stolen car!`)
		end
		theft.thief = player
		theft.thiefUserId = player.UserId
		byThief[player] = theft
		theft.endsAt = TheftService._takeoverDeadline(theft.endsAt, now)
		theft.warned30 = false
		theft.warned10 = false
		theft.revengePaid = false
		local data = theft.car and theft.car.data
		if type(data) == "table" and type(data.theft) == "table" then
			data.theft.thief = player
		end
		setModelAttr(theft.car, "TheftThiefUserId", player.UserId)
		call("WantedService", "addHeat", player, PoliceConfig.Heat.playerTheft, "theft")
		if online(theft.victim) then
			fireClient("CarStolenAlert", theft.victim, nameOf(player), theft.carId, theft.mutation, true)
		end
		fireAll(
			"EventFeed",
			`😈 <b>{richEscape(nameOf(player))}</b> hijacked {richEscape(theft.victimName)}'s {richCar(
				theft.carId,
				theft.mutation
			)} from <b>{richEscape(nameOf(old))}</b>!`
		)
	end
	-- If VehicleService converted the car on steal, put it back: it is still a player-theft.
	if theft.car and theft.car.kind ~= "Stolen" then
		theft.car.kind = "Stolen"
		setModelAttr(theft.car, "Kind", "Stolen")
	end
	clearDropped(theft)
	theft.graceUntil = now + TheftService.SEAT_GRACE
	if driverOf(theft.car) ~= player then
		local seatOk, err = call("VehicleService", "seat", theft.car, player)
		if not seatOk and err ~= nil then
			warn("[TheftService] seat on takeover failed: " .. tostring(err))
		end
	end
	notify(player, "success", "🏁 GO GO GO! Get it to your garage!")
	sendThiefState(theft)
	updateWaypoints(theft, now, true)
	return true
end

---------------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------------

function TheftService.isBeingStolen(victim: Player, slot: number): boolean
	local map = byVictim[victim]
	local theft = map and map[slot]
	return theft ~= nil and not theft.finished
end

function TheftService.getActiveTheft(thief: Player): Theft?
	local theft = byThief[thief]
	if theft and not theft.finished then
		return theft
	end
	return nil
end

-- Extra: the theft record for a car (or nil).
function TheftService.getTheftForCar(car: any): Theft?
	local theft = byCar[car]
	if theft and not theft.finished then
		return theft
	end
	return nil
end

-- Extra: every active theft (read-only use).
function TheftService.getActiveThefts(): { Theft }
	local out = {}
	for _, theft in byCar do
		if not theft.finished then
			table.insert(out, theft)
		end
	end
	return out
end

-- Extra: seconds of robbery protection left for a victim (0 = robbable as far as cooldown goes).
function TheftService.cooldownLeft(victim: Player): number
	return TheftService._cooldownLeft(cooldownUntil[victim.UserId], hooks.clock())
end

-- Gathers everything _canSteal needs from live server state.
local function gatherState(thief: Player, victim: Player, slot: number): StealState
	local now = hooks.clock()
	local vData = getData(victim)
	local tData = getData(thief)
	local rec = vData and vData.garage and vData.garage[tostring(slot)]
	local def = rec and Cars.get(rec.carId)
	local _, state = call("GarageService", "getSlotState", victim, slot)
	local victimPlot = plotIndexOf(victim)
	local _, locked = call("PlotService", "isLocked", victimPlot or -1)

	local inside = false
	local root, hum = hooks.rootOf(thief)
	if victimPlot and root then
		local okIn, isIn = call("PlotService", "isInside", thief, victimPlot)
		inside = if okIn then isIn == true else MapLayout.plotAt(root.Position) == victimPlot
		if inside then
			local okSlot, slotCf = pcall(MapLayout.slotWorld, victimPlot, slot)
			if okSlot and (slotCf.Position - root.Position).Magnitude > TheftService.MAX_INSIDE_SLOT_DISTANCE then
				inside = false
			end
		end
	end

	local _, owned = call("GarageService", "ownedCount", victim)
	local _, free = call("GarageService", "freeSlots", thief)
	local busyMap = byVictim[victim]
	local victimBusy = false
	if busyMap then
		for _, th in busyMap do
			if not th.finished then
				victimBusy = true
				break
			end
		end
	end

	return {
		isSelf = thief == victim,
		victimOnline = online(victim),
		victimLoaded = vData ~= nil,
		thiefLoaded = tData ~= nil,
		thiefAlive = root ~= nil and hum ~= nil and hum.Health > 0,
		thiefStunned = thief:GetAttribute("Stunned") == true,
		thiefDriving = isDriving(thief),
		thiefBusy = TheftService.getActiveTheft(thief) ~= nil,
		hasCar = rec ~= nil and def ~= nil,
		slotParked = rec ~= nil
			and (state == nil or state == "Parked")
			and not TheftService.isBeingStolen(victim, slot),
		stealable = def ~= nil and def.stealable and def.rarity ~= "Exclusive",
		locked = locked == true,
		inside = inside,
		victimCars = if typeof(owned) == "number" then owned else 0,
		victimBusy = victimBusy,
		cooldownLeft = TheftService._cooldownLeft(cooldownUntil[victim.UserId], now),
		thiefHasPlot = plotIndexOf(thief) ~= nil,
		thiefFreeSlots = if typeof(free) == "number" then free else 0,
	}
end

-- Called by GarageService when the StealPrompt hold on a display car completes. Returns true if the theft started.
function TheftService.beginTheft(thief: Player, victim: Player, slot: number): boolean
	if not isPlayer(thief) or not isPlayer(victim) or not Net.isInt(slot, 1, MapLayout.maxPhysicalSlots()) then
		return false
	end
	if not online(thief) then
		return false
	end
	local state = gatherState(thief, victim, slot)
	local ok, code, message = TheftService._canSteal(state)
	if not ok then
		if code ~= "dead" and message ~= "" then
			notify(thief, "error", message)
		end
		return false
	end

	local VS = sys("VehicleService")
	local GS = sys("GarageService")
	local victimPlot = plotIndexOf(victim)
	if not VS or typeof(VS.spawn) ~= "function" or not GS or not victimPlot then
		notify(thief, "error", "Stealing is offline right now.")
		return false
	end
	local rec = getData(victim).garage[tostring(slot)]
	local carId: string = rec.carId
	local mutation: string = rec.mutation or "None"

	-- Claim the slot first (removes the display), then spawn the drivable car exactly where it stood.
	call("GarageService", "setSlotState", victim, slot, "BeingStolen")
	local ground = MapLayout.slotWorld(victimPlot, slot) * CFrame.new(0, padTop(), 0)
	local okSpawn, car = pcall(VS.spawn, carId, mutation, ground, "Stolen", {
		ownerUserId = victim.UserId,
		victim = victim,
		thief = thief,
		slot = slot,
	})
	if not okSpawn or type(car) ~= "table" or car.model == nil then
		warn("[TheftService] VehicleService.spawn failed: " .. tostring(car))
		call("GarageService", "restoreSlot", victim, slot)
		notify(thief, "error", "The car wouldn't start! Try again.")
		return false
	end

	local now = hooks.clock()
	nextId += 1
	local label = carLabel(carId, mutation)
	local theft: Theft = {
		id = nextId,
		car = car,
		victim = victim,
		victimUserId = victim.UserId,
		victimName = nameOf(victim),
		thief = thief,
		thiefUserId = thief.UserId,
		slot = slot,
		carId = carId,
		mutation = mutation,
		label = label,
		startedAt = now,
		endsAt = now + Economy.THEFT_TIME_LIMIT,
		graceUntil = now + TheftService.SEAT_GRACE,
		dropped = false,
		droppedUntil = 0,
		lastHitAt = -math.huge,
		lastHitBy = nil,
		revengePaid = false,
		finished = false,
		warned30 = false,
		warned10 = false,
		lastWaypointAt = -math.huge,
		lastWaypointPos = nil,
		lastFullNotifyAt = -math.huge,
		trove = Trove.new(),
		recoverPrompt = nil,
		takeoverPrompt = nil,
	}
	car.data = if type(car.data) == "table" then car.data else {}
	-- SPEC shape { victim, slot, carId, mutation, startedAt, thief } (+ id / userIds for convenience)
	car.data.theft = {
		id = theft.id,
		victim = victim,
		victimUserId = victim.UserId,
		slot = slot,
		carId = carId,
		mutation = mutation,
		startedAt = now,
		thief = thief,
	}
	if car.kind ~= "Stolen" then
		car.kind = "Stolen"
	end
	setModelAttr(car, "Kind", "Stolen")
	setModelAttr(car, "TheftActive", true)
	setModelAttr(car, "TheftVictimUserId", victim.UserId)
	setModelAttr(car, "TheftThiefUserId", thief.UserId)
	setModelAttr(car, "TheftEndsAt", toServerTime(theft.endsAt))
	setModelAttr(car, "Dropped", false)

	byCar[car] = theft
	byThief[thief] = theft
	victimThefts(victim)[slot] = theft
	setCooldown(victim.UserId, now)

	local seatOk = call("VehicleService", "seat", car, thief)
	if not seatOk then
		-- could not put the thief in: hand everything back
		failTheft(theft, "error")
		notify(thief, "error", "The car wouldn't start! Try again.")
		return false
	end

	call("WantedService", "addHeat", thief, PoliceConfig.Heat.playerTheft, "theft")
	progress(thief, "steal", 1)

	-- Victim: alarm + live arrow to their car. Thief: timer + arrow home.
	fireClient("CarStolenAlert", victim, nameOf(thief), carId, mutation, true)
	sendThiefState(theft)
	updateWaypoints(theft, now, true)
	notify(thief, "success", `🏁 GO GO GO! Drive the {label} to your garage!`)
	local pos = carPosition(car)
	if pos then
		fireNear("Sound", pos, 140, "GlassBreak", pos)
	end
	fireAll(
		"EventFeed",
		`🚨 <b>{richEscape(nameOf(thief))}</b> is stealing <b>{richEscape(theft.victimName)}</b>'s {richCar(
			carId,
			mutation
		)}!`
	)
	TheftService.TheftStarted:Fire(theft)
	return true
end

-- Delivery into the current thief's own drop-off (GarageService routes VehicleService.DeliveryAttempt here).
-- Atomic transfer: victim slot -> record -> thief's garage. Returns true when the car changed hands.
function TheftService.complete(car: any): boolean
	local theft = byCar[car]
	if not theft or theft.finished then
		return false
	end
	local thief, victim = theft.thief, theft.victim
	if not online(thief) then
		return false
	end
	local driver = driverOf(car)
	if driver ~= nil and driver ~= thief then
		return false -- only the active thief can cash this in
	end
	if not online(victim) then
		failTheft(theft, "victim_left")
		return false
	end
	local GS = sys("GarageService")
	local DS = sys("DataService")
	local tData = getData(thief)
	local vData = getData(victim)
	if not GS or not DS or not tData or not vData or not tData.garage or not vData.garage then
		return false
	end
	local now = hooks.clock()
	local _, free = call("GarageService", "freeSlots", thief)
	if typeof(free) ~= "number" or free <= 0 then
		if now - theft.lastFullNotifyAt > 3 then
			theft.lastFullNotifyAt = now
			notify(thief, "error", "📦 Garage full! Sell a car to park this one. Hurry!")
		end
		return false
	end

	local key = tostring(theft.slot)
	local rec = vData.garage[key]
	if not rec or rec.carId ~= theft.carId or (rec.mutation or "None") ~= theft.mutation then
		-- The victim's slot changed under us (rebirth / admin). Nothing to transfer: end without touching garages.
		finish(theft, "invalid")
		if carAlive(car) then
			destroyCar(car, "theft_invalid")
		end
		notify(thief, "warning", "The car's papers vanished... no deal this time.")
		return false
	end

	-- Point of no return: everything below is synchronous (no yields), so nobody can interleave.
	theft.finished = true
	local ok, removed = call("GarageService", "removeSlot", victim, theft.slot)
	if not ok or type(removed) ~= "table" then
		-- nothing was removed: put the theft back the way it was and let the normal paths handle it
		theft.finished = false
		return false
	end
	local okStore, stored, slotOrReason = pcall(GS.storeCar, thief, removed.carId, removed.mutation)
	if not okStore or stored ~= true then
		-- roll back: the victim gets their exact record back
		local okBack, backOk, backSlot = pcall(GS.storeCar, victim, removed.carId, removed.mutation)
		if okBack and backOk == true and typeof(backSlot) == "number" then
			local back = vData.garage[tostring(backSlot)]
			if back then
				back.uncollected = removed.uncollected or 0
			end
		else
			vData.garage[key] = removed
			call("GarageService", "refresh", victim)
		end
		theft.finished = false
		finish(theft, "error")
		if carAlive(car) then
			destroyCar(car, "theft_error")
		end
		notify(thief, "error", "Couldn't park that car. It went back home.")
		notify(victim, "success", `🏠 Your {theft.label} is back home.`)
		return false
	end

	-- Bookkeeping ----------------------------------------------------------------------------------------------------
	theft.finished = false -- let finish() run its single-shot cleanup
	finish(theft, "delivered")
	local payout = math.floor(removed.uncollected or 0)
	if payout > 0 then
		call("DataService", "addCash", victim, payout, "uncollected")
		fireClient("CashPopup", victim, payout, nil)
	end
	tData.stats = tData.stats or {}
	vData.stats = vData.stats or {}
	tData.stats.playerSteals = (tData.stats.playerSteals or 0) + 1
	vData.stats.timesRobbed = (vData.stats.timesRobbed or 0) + 1
	local _, isNew = call("GarageService", "discover", thief, removed.carId)
	progress(thief, "playerSteal", 1)
	local order = rarityOrder(removed.carId)
	if order >= 3 then
		progress(thief, "deliverRare", 1)
	end
	if order >= 4 then
		progress(thief, "deliverEpic", 1)
	end
	local robbers = recentRobbers[theft.victimUserId]
	if not robbers then
		robbers = {}
		recentRobbers[theft.victimUserId] = robbers
	end
	robbers[thief.UserId] = now + TheftService.REVENGE_WINDOW
	call("DataService", "markDirty", thief)
	call("DataService", "markDirty", victim)
	if typeof(DS.saveNow) == "function" then
		hooks.spawnTask(function()
			pcall(DS.saveNow, thief)
		end)
		hooks.spawnTask(function()
			pcall(DS.saveNow, victim)
		end)
	end

	-- Juice -----------------------------------------------------------------------------------------------------------
	local thiefPlot = plotIndexOf(thief)
	local fxPos = carPosition(car)
	if thiefPlot and typeof(slotOrReason) == "number" then
		local okSlot, cf = pcall(MapLayout.slotWorld, thiefPlot, slotOrReason)
		if okSlot then
			fxPos = cf.Position + Vector3.new(0, 4, 0)
		end
	end
	destroyCar(car, "delivered")
	if fxPos then
		fireNear("Effect", fxPos, 300, "BigSteal", { position = fxPos, text = "ROBBED!", sound = "CashBig" })
	end
	fireClient("Sound", thief, "CashBig", fxPos)
	local income = EconomyMath.carIncome(removed.carId, removed.mutation)
	local _, mult = call("GarageService", "multiplier", thief)
	if typeof(mult) == "number" and mult == mult then
		income *= mult
	end
	notify(
		thief,
		"money",
		`💰 {if isNew == true then "NEW! " else ""}You stole {theft.victimName}'s {theft.label}! +{Format.cash(income)}/s`
	)
	local keptText = if payout > 0 then ` You kept its {Format.cash(payout)} uncollected.` else ""
	notify(victim, "error", `😭 {nameOf(thief)} stole your {theft.label}!{keptText} Get revenge!`, 5)
	fireClient("Sound", victim, "GlassBreak")
	fireAll(
		"EventFeed",
		`💰 <b>{richEscape(nameOf(thief))}</b> stole <b>{richEscape(theft.victimName)}</b>'s {richCar(
			removed.carId,
			removed.mutation
		)}!`
	)
	if order >= 5 then
		local def = Cars.get(removed.carId)
		local tier = def and Rarity.Tiers[def.rarity]
		fireAll(
			"Announce",
			"HEIST!",
			`{nameOf(thief)} stole {theft.victimName}'s {theft.label}!`,
			if tier and def and def.rarity ~= "Secret" then tier.color else Color3.fromRGB(255, 80, 210),
			"CashBig"
		)
	end
	return true
end

-- Ends a theft and sends the car home (time limit, wreck, bust, thief left, dropped timeout...). Idempotent.
-- `car` may be a VehicleService Car or a Theft record.
function TheftService.fail(car: any, reason: string?): boolean
	local theft = byCar[car]
	if not theft and type(car) == "table" and type(car.car) == "table" then
		theft = byCar[car.car]
	end
	if not theft or theft.finished then
		return false
	end
	return failTheft(theft, if typeof(reason) == "string" then reason else "failed")
end

-- The victim took their car back (instant Recover prompt, or drove it into their own drop-off). Pays the recovery
-- bonus. Returns true on success.
function TheftService.recover(car: any, player: Player?): boolean
	local theft = byCar[car]
	if not theft or theft.finished then
		return false
	end
	if player ~= nil and player ~= theft.victim then
		return false
	end
	local victim = theft.victim
	if not online(victim) then
		return false
	end
	local pos = carPosition(car)
	if not finish(theft, "recovered") then
		return false
	end
	if carAlive(car) then
		destroyCar(car, "recovered")
	end
	local restored = restoreVictimSlot(theft)
	if not restored then
		notify(victim, "info", `🏠 Your {theft.label} is back home.`)
		return true
	end
	local bonus = TheftService._bonus(incomeOf(victim), Economy.RECOVERY_BONUS_SECONDS)
	call("DataService", "addCash", victim, bonus, "recovery")
	fireClient("CashPopup", victim, bonus, pos)
	fireClient("Sound", victim, "CashBig", pos)
	notify(victim, "money", `🛡️ RECOVERED! Your {theft.label} is home. +{Format.cash(bonus)} bonus!`)
	if pos then
		fireNear("Effect", pos, 200, "Confetti", { position = pos })
	end
	if online(theft.thief) then
		notify(theft.thief, "error", `❌ {theft.victimName} took their car back!`)
	end
	fireAll(
		"EventFeed",
		`🛡️ <b>{richEscape(theft.victimName)}</b> got their {richCar(theft.carId, theft.mutation)} back from <b>{richEscape(
			nameOf(theft.thief)
		)}</b>!`
	)
	return true
end

local function payRevenge(attacker: Player, thief: Player)
	local amount = TheftService._bonus(incomeOf(attacker), Economy.REVENGE_BONUS_SECONDS)
	call("DataService", "addCash", attacker, amount, "revenge")
	local root = hooks.rootOf(attacker)
	fireClient("CashPopup", attacker, amount, if root then root.Position + Vector3.new(0, 4, 0) else nil)
	fireClient("Sound", attacker, "CashBig")
	notify(attacker, "money", `⚔️ REVENGE! +{Format.cash(amount)}`)
	fireAll(
		"EventFeed",
		`⚔️ <b>{richEscape(nameOf(attacker))}</b> got REVENGE on <b>{richEscape(nameOf(thief))}</b>!`
	)
end

-- CombatService: `attacker` landed a hit (bat/zapper) on `target`. Revenge bonus when the attacker is the victim of
-- target's active theft (once per theft) or target robbed them within REVENGE_WINDOW (once per robbery).
function TheftService.onThiefHit(attacker: Player, target: Player)
	if not isPlayer(attacker) or not isPlayer(target) or attacker == target then
		return
	end
	local now = hooks.clock()
	local theft = byThief[target]
	if theft and not theft.finished then
		theft.lastHitAt = now
		theft.lastHitBy = attacker
		if attacker == theft.victim and not theft.revengePaid then
			theft.revengePaid = true
			payRevenge(attacker, target)
		end
		return
	end
	local robbers = recentRobbers[attacker.UserId]
	local expires = robbers and robbers[target.UserId]
	if robbers and expires then
		robbers[target.UserId] = nil
		if expires > now then
			payRevenge(attacker, target)
		end
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Signals + heartbeat
---------------------------------------------------------------------------------------------------------------------

local function onDriverChanged(car: any, newDriver: Player?, _oldDriver: Player?)
	local theft = byCar[car]
	if not theft or theft.finished then
		return
	end
	local now = hooks.clock()
	if newDriver == nil then
		markDropped(theft, now)
	elseif newDriver == theft.thief or newDriver == theft.victim then
		resume(theft, now)
	end
end

local function onDestroyed(car: any, reason: any)
	local theft = byCar[car]
	if not theft or theft.finished then
		return
	end
	local why = if reason == "busted" then "busted" else "wrecked"
	failTheft(theft, why, true)
end

-- One heartbeat pass over every active theft. Exposed for tests.
function TheftService._tick(now: number?)
	local t = now or hooks.clock()
	local list = {}
	for _, theft in byCar do
		table.insert(list, theft)
	end
	for _, theft in list do
		if theft.finished then
			continue
		end
		local car = theft.car
		if not carAlive(car) then
			failTheft(theft, "wrecked", true)
			continue
		end
		if not online(theft.victim) then
			failTheft(theft, "victim_left")
			continue
		end
		if not online(theft.thief) then
			failTheft(theft, "thief_left")
			continue
		end
		if t >= theft.endsAt then
			failTheft(theft, "timeout")
			continue
		end
		if theft.dropped and t >= theft.droppedUntil then
			failTheft(theft, "dropped")
			continue
		end
		local pos = carPosition(car)
		if pos and pos.Y < TheftService.LOST_Y then
			failTheft(theft, "lost")
			continue
		end
		if car.kind ~= "Stolen" then
			-- a steal-prompt path may have converted it; a player theft stays a player theft until it ends
			car.kind = "Stolen"
			setModelAttr(car, "Kind", "Stolen")
		end
		if not theft.dropped and t >= theft.graceUntil and driverOf(car) == nil then
			markDropped(theft, t) -- missed signal / seating failed
		end
		local left = theft.endsAt - t
		if not theft.warned30 and left <= 30 then
			theft.warned30 = true
			notify(theft.thief, "warning", "⏱️ 30 seconds left to deliver!")
		elseif theft.warned30 and not theft.warned10 and left <= 10 then
			theft.warned10 = true
			notify(theft.thief, "warning", "⏱️ 10 SECONDS!")
		end
		updateWaypoints(theft, t)
	end
end

local function onPlayerRemoving(player: Player)
	-- as thief: the car goes home
	local mine = byThief[player]
	if mine and not mine.finished then
		failTheft(mine, "thief_left")
	end
	-- as victim: the record never left their data; the car just vanishes
	local map = byVictim[player]
	if map then
		local list = {}
		for _, theft in map do
			table.insert(list, theft)
		end
		for _, theft in list do
			failTheft(theft, "victim_left")
		end
	end
	byVictim[player] = nil
end

-- Exposed for tests (same code path as Players.PlayerRemoving).
TheftService._onPlayerRemoving = onPlayerRemoving
TheftService._onDriverChanged = onDriverChanged
TheftService._onDestroyed = onDestroyed
TheftService._takeover = function(theft: Theft, player: Player): boolean
	return takeover(theft, player)
end
TheftService._canTakeover = canTakeover

-- Tests only: wipe all runtime state.
function TheftService._reset()
	table.clear(byCar)
	table.clear(byThief)
	table.clear(byVictim)
	table.clear(cooldownUntil)
	table.clear(recentRobbers)
end

function TheftService.init()
	local VS = sys("VehicleService")
	if VS then
		if VS.DriverChanged then
			VS.DriverChanged:Connect(onDriverChanged)
		end
		if VS.Destroyed then
			VS.Destroyed:Connect(onDestroyed)
		end
	else
		warn("[TheftService] VehicleService missing: thefts disabled")
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function TheftService.start()
	while true do
		task.wait(TheftService.TICK)
		local ok, err = pcall(TheftService._tick)
		if not ok then
			warn("[TheftService] tick failed: " .. tostring(err))
		end
		-- prune expired revenge entries
		local now = hooks.clock()
		for victimId, robbers in recentRobbers do
			for thiefId, expires in robbers do
				if expires <= now then
					robbers[thiefId] = nil
				end
			end
			if next(robbers) == nil then
				recentRobbers[victimId] = nil
			end
		end
	end
end

return TheftService
