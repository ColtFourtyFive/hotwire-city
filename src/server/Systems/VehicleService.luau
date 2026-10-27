--!strict
-- VehicleService (docs/SPEC.md §6): owns every drivable car in Hotwire City.
--
--  * spawn(carId | CarDef, mutation, groundCFrame, kind, opts?) builds a car with Shared/Vehicle/CarBuilder, rests its
--    wheels on groundCFrame, parents it to Workspace.Vehicles, tags it "Vehicle" (+ "Police") and sets the model
--    attributes VehicleId / CarId / Mutation / Kind / Rarity / OwnerUserId / Health / DriverUserId.
--    Parked / Dealership / HotDrop cars spawn anchored with their wheels exactly on the ground; everything else is
--    unanchored (dropped from 0.3 studs) and server-owned until driven.
--  * Seats are Disabled (no touch-to-sit, ever). seat(car, player) is the ONLY way in: it authorizes that player for a
--    short window, unanchors, enables the seat, hands network ownership to the driver and calls Sit. It never
--    throws: callers must check its (ok, reason) result. Any other occupant is ejected on sight. Exit (jump or
--    eject) -> the character is put beside the car, seat disabled, server takes ownership back and runs a settling
--    VehicleController (zero input, SETTLE_MAX at most) so the car rests on its suspension; it is anchored, levelled
--    onto flat ground, once it has been at rest for PARK_ANCHOR_AFTER seconds.
--  * addStealPrompt(car, opts) -> ProximityPrompt with server-side hold validation: the server records
--    PromptButtonHoldBegan per (prompt, player) and rejects Triggered unless the button was held for at least
--    base * getHoldMultiplier(player) * HOLD_TOLERANCE seconds (and the hold began recently: no pre-charged holds),
--    plus a distance check. Clients only scale HoldDuration locally for display (player attribute
--    "HoldMultiplier", prompt attribute "BaseHoldDuration").
--  * Zones (0.2s, driven cars): own drop-off -> DeliveryAttempt (on entry, retried every DELIVERY_RETRY s while
--    inside), Chop Shop -> ChopAttempt (after CHOP_DWELL s stopped inside), Spray Shops -> SprayAttempt. Owned cars
--    only count at the drop-off after they have left the garage interior once (car.data.leftGarage); if
--    GarageService does not park it, ReturnedHome fires as a fallback. Zone events only fire for a car whose
--    position passes the watchdog check that tick (else it is rewound), that is not tainted, and that could have
--    got there from where its drive started (minTravelTime).
--  * Abandon rules (1s; sunk below LOST_Y for LOST_AFTER s = lost), crash damage (0.1s, armor-scaled, scaled by the
--    real time between samples), wreck (KAPOW + smoke, destroyed after 2s) and the anti-cheat watchdog (0.5s:
--    speed cap, horizontal + upward teleport, fling spin / vertical speed, flying with no ground below -> server
--    rewinds the car, keeps ownership for WATCHDOG_REVOKE_SECONDS and taints it; logs, never kicks).
--  * Unoccupied Owned / Loot cars get VehicleService-managed prompts so players can get back in:
--      "EnterPrompt" (F / ButtonY, instant, attribute OnlyUserId = owner / claimer, server re-checks) and, on Loot,
--      a "Hotwire" steal prompt for everybody else (attribute HideForUserId = claimer; the server refuses it to the
--      claimer too).
--  * A leaving player's Owned cars are destroyed (they never outlive the session).
--
-- Public API (SPEC): spawn, seat, eject, addStealPrompt, damage, destroy, get, fromModel, getDriving, all, setKind,
--   getHoldMultiplier; signals Spawned, DriverChanged, Destroyed, DeliveryAttempt, ChopAttempt, SprayAttempt,
--   ReturnedHome, Stolen.
-- Extra public helpers: wreck(car), teleport(car, cframe), resetWatchdog(car), getSpeedCap(car),
--   minTravelTime(car, targetPos), isTainted(car), settle(car), allInto(buffer),
--   refreshHoldMultiplier(player), addStealHeat(player, stars, reason) -> applied, isFirstSteal(player),
--   contractProgress(player, stat, amount), announceSteal(player, car, verb), carLabel(car), getFolder();
--   signal Wrecked(car) (fired before the driver is ejected). Drive-start tracking: car.data.driveStartAt /
--   car.data.driveStartPos are set whenever a player starts driving the car.
--   Pure helpers prefixed with _ are exposed for tests/spec/vehicleservice.spec.luau.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local MapConfig = require(Shared.Config.Map)
local Monetization = require(Shared.Config.Monetization)
local Rarity = require(Shared.Config.Rarity)
local VehicleConfig = require(Shared.Config.Vehicle)
local EconomyMath = require(Shared.Util.EconomyMath)
local MapLayout = require(Shared.Util.MapLayout)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)
local CarBuilder = require(Shared.Vehicle.CarBuilder)

type CarDef = Cars.CarDef
type MutationId = Rarity.MutationId
export type VehicleKind = Types.VehicleKind

export type Car = {
	id: number,
	model: Model,
	chassis: BasePart,
	seat: VehicleSeat,
	carId: string,
	mutation: MutationId,
	kind: VehicleKind,
	ownerUserId: number?,
	driver: Player?,
	health: number,
	lastDriverAt: number,
	data: { [string]: any }, -- per-system scratch (data.theft, data.slot, data.leftGarage, ...)
	-- extras (read-only for other systems)
	def: CarDef,
	rarity: Rarity.RarityId,
	maxHealth: number,
	spawnedAt: number,
	destroyed: boolean,
	wrecked: boolean,
}

export type StealPromptOpts = {
	actionText: string,
	holdDuration: number,
	objectText: string?,
	canSteal: (Player) -> (boolean, string?),
	onStolen: (Player) -> ...any, -- return false when nothing was taken (e.g. seat() refused): no Stolen signal
	name: string?, -- default "Hotwire" / "Carjack" (from actionText) or "StealPrompt"
	managed: boolean?, -- VehicleService's own re-created prompts: not added to the car's trove (PERF-14)
	scaleWithHotwire: boolean?, -- default true: required hold = base * getHoldMultiplier(player)
	maxDistance: number?, -- default PROMPT_DISTANCE
	keyCode: Enum.KeyCode?,
	gamepadKeyCode: Enum.KeyCode?,
	onHoldBegan: ((Player) -> ())?, -- e.g. traffic brakes when someone starts a carjack
}

export type SpawnOpts = {
	ownerUserId: number?,
	owner: Player?,
	slot: number?,
	anchored: boolean?, -- overrides the per-kind default
	data: { [string]: any }?,
	health: number?,
	[string]: any,
}

type CarState = {
	trove: Trove.Trove,
	authorized: Player?,
	authorizedUntil: number,
	lastVel: Vector3,
	lastVelAt: number,
	damageGraceUntil: number,
	wdCFrame: CFrame,
	wdAt: number,
	wdRevokedUntil: number,
	wdSpeedStrikes: number,
	wdFlingStrikes: number,
	airSince: number?,
	restSince: number?,
	sunkSince: number?,
	inDropoff: boolean,
	dropoffFiredAt: number,
	inChop: boolean, -- ChopAttempt already fired for this visit
	chopEntered: boolean,
	chopSince: number?,
	inSpray: number?,
	returnFired: boolean,
	shownHealth: number,
	enterPrompt: ProximityPrompt?,
	hotwirePrompt: ProximityPrompt?,
	stealing: boolean,
}

local VehicleService = {}

-- TUNING -------------------------------------------------------------------------------------------------------------

VehicleService.PROMPT_DISTANCE = 12
VehicleService.PROMPT_SLACK = 4 -- server distance check = MaxActivationDistance + this
VehicleService.HOLD_TOLERANCE = 0.85 -- fraction of the required hold the server insists on (latency jitter)
VehicleService.HOLD_MAX_EXTRA = 1.5 -- a hold that began longer ago than the full hold + this is stale (SEC-2)
VehicleService.SEAT_AUTH_WINDOW = 3 -- seconds a seat() authorization stays valid while the Sit replicates
VehicleService.DELIVERY_RETRY = 3 -- re-fire DeliveryAttempt this often while parked in the drop-off
VehicleService.OWNED_FALLBACK_DELAY = 1 -- Owned car still alive this long after DeliveryAttempt -> ReturnedHome
VehicleService.RETURN_DESTROY_DELAY = 3 -- ReturnedHome not handled -> destroy the car ourselves after this
VehicleService.WRECK_DESTROY_AFTER = 2
VehicleService.DAMAGE_GRACE = 1 -- no crash damage this long after seating / rewinds
VehicleService.DAMAGE_WINDOW = 0.2 -- velocity samples further apart than this need a proportionally bigger change
VehicleService.REST_SPEED = 0.75 -- studs/s: below this an empty car counts as "at rest"
VehicleService.SPAWN_DROP = 0.3 -- unanchored cars spawn this far above their rest height and settle onto it
VehicleService.SETTLE_MAX = 15 -- seconds a driverless car runs the server settling controller at most
-- Sunk: the seabed is at WATER_LEVEL - 14 and nothing drivable is below WATER_LEVEL - 6 (same line as TheftService
-- and the police rubber-band), so a car down there for LOST_AFTER seconds is lost. Police are PoliceService's job.
VehicleService.LOST_Y = MapConfig.WATER_LEVEL - 6
VehicleService.LOST_AFTER = 1.5
VehicleService.VOID_Y = MapConfig.WATER_LEVEL - 28 -- fell out of the world: lost at once, police included
VehicleService.CHOP_DWELL = 1.2 -- seconds stopped inside the Chop Shop before ChopAttempt (no drive-through chops)
VehicleService.CHOP_MAX_SPEED = 8 -- studs/s: "stopped" for the chop dwell
-- lag tolerance: displacement allowance accrues for at most this long (a stalled client may jump by its catch-up,
-- but a car held still can no longer bank seconds of allowance for one big hop, F5)
VehicleService.WATCHDOG_MAX_DT = 1
VehicleService.WATCHDOG_BLATANT = 1.5 -- speed above cap * this is a violation on the first strike
-- Fling (SEC-6): spin or vertical speed no driving produces (MAX_YAW_RATE 2.4, upright 6 rad/s; a 160-stud fall
-- for 250 studs/s), on two consecutive samples
VehicleService.WATCHDOG_FLING_SPIN = 40
VehicleService.WATCHDOG_FLING_VERTICAL = 250
-- Flying (F5): no ground (or water) within this many studs under the chassis for WATCHDOG_AIR_SECONDS in a row.
-- The biggest ramp (MegaRamp, 14 high) keeps a car airborne for about a second.
VehicleService.WATCHDOG_AIR_CLEARANCE = 14
VehicleService.WATCHDOG_AIR_SECONDS = 3

local DAMAGE_TICK = 0.1
local ZONE_TICK = 0.2
local WATCHDOG_TICK = 0.5
local LIFE_TICK = 1
local HOLD_MULT_TICK = 5

local VALID_KINDS: { [string]: boolean } = {
	Parked = true,
	Traffic = true,
	Owned = true,
	Stolen = true,
	Loot = true,
	Dealership = true,
	HotDrop = true,
	Police = true,
}
local ANCHORED_KINDS: { [string]: boolean } = { Parked = true, Dealership = true, HotDrop = true }
local SELF_DRIVEN_KINDS: { [string]: boolean } = { Traffic = true, Police = true } -- never rest-anchored here

-- SIGNALS ------------------------------------------------------------------------------------------------------------

VehicleService.Spawned = Signal.new() -- (car)
VehicleService.DriverChanged = Signal.new() -- (car, newDriver: Player?, oldDriver: Player?)
VehicleService.Destroyed = Signal.new() -- (car, reason: string)
VehicleService.DeliveryAttempt = Signal.new() -- (player, car)
VehicleService.ChopAttempt = Signal.new() -- (player, car)
VehicleService.SprayAttempt = Signal.new() -- (player, car)
VehicleService.ReturnedHome = Signal.new() -- (car)
VehicleService.Stolen = Signal.new() -- (player, car, previousKind)
-- (car) extra: fired when health hits 0, BEFORE the driver is ejected (destroyed WRECK_DESTROY_AFTER later)
VehicleService.Wrecked = Signal.new()

-- STATE --------------------------------------------------------------------------------------------------------------

local cars: { [number]: Car } = {}
local byModel: { [Instance]: Car } = {}
local states: { [Car]: CarState } = {}
local drivingByPlayer: { [Player]: Car } = {}
local freeStealUsed: { [Player]: boolean } = {}
local nextId = 0
local vehiclesFolder: Folder? = nil
local ejectParams: RaycastParams? = nil
local groundParams: RaycastParams? = nil
local groundFilter: { Instance } = {}
local settling: { [Car]: any } = {} -- car -> server VehicleController (zero input) while it settles after exit
local settleUntil: { [Car]: number } = {}
local heatRng = Random.new()

local setDriver: (car: Car, player: Player?) -> ()
local refreshManagedPrompts: (car: Car) -> ()
local onOccupantChanged: (car: Car) -> ()

-- HELPERS ------------------------------------------------------------------------------------------------------------

local systemCache: { [string]: any } = {}
-- Lazy system lookup (avoids require cycles; missing / erroring systems return nil).
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

-- pcall a function on another system: returns (ok, result).
local function call(name: string, fn: string, ...: any): (boolean, any)
	local mod = sys(name)
	local f = mod and mod[fn]
	if typeof(f) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(f, ...)
	if not ok then
		warn(("[VehicleService] %s.%s errored: %s"):format(name, fn, tostring(res)))
		return false, nil
	end
	return true, res
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function num(v: any, default: number): number
	if typeof(v) == "number" and v == v then
		return v
	end
	return default
end

local function setAttr(inst: Instance?, name: string, value: any)
	if inst then
		pcall(inst.SetAttribute, inst, name, value)
	end
end

local function characterOf(player: Player): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	if not char then
		return nil, nil, nil
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	return char, humanoid, if root and root:IsA("BasePart") then root else nil
end

local function isAlive(player: Player): boolean
	local _, humanoid, root = characterOf(player)
	return humanoid ~= nil and root ~= nil and humanoid.Health > 0
end

local function withinReach(player: Player, pos: Vector3, maxDistance: number): boolean
	local _, _, root = characterOf(player)
	return root ~= nil and (root.Position - pos).Magnitude <= maxDistance
end

local function notify(player: Player, kind: string, text: string, duration: number?)
	pcall(Net.fireClient, "Notify", player, kind, text, duration)
end

local function richEscape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function anyPlayerNear(pos: Vector3, radius: number): boolean
	for _, p in Players:GetPlayers() do
		local _, _, root = characterOf(p)
		if root and (root.Position - pos).Magnitude <= radius then
			return true
		end
	end
	return false
end

local function safeConnect(trove: Trove.Trove, getSignal: () -> RBXScriptSignal, fn: (...any) -> ())
	-- pcall'd so the builders stay usable in the headless Lune harness (no engine events there)
	local ok, signal = pcall(getSignal)
	if ok and signal ~= nil then
		pcall(function()
			trove:Connect(signal, fn)
		end)
	end
end

local function rarityDef(car: Car): Rarity.RarityDef
	return Rarity.Tiers[car.rarity] or Rarity.Tiers.Common
end

function VehicleService.carLabel(car: Car): string
	local mut = Rarity.getMutation(car.mutation)
	local name = if car.def and car.def.name then car.def.name else car.carId
	return if mut.label ~= "" then `{mut.label} {name}` else name
end

function VehicleService.getFolder(): Folder
	local f = vehiclesFolder
	if f and f.Parent then
		return f
	end
	local existing = Workspace:FindFirstChild("Vehicles")
	if existing and existing:IsA("Folder") then
		vehiclesFolder = existing
		return existing
	end
	local nf = Instance.new("Folder")
	nf.Name = "Vehicles"
	nf.Parent = Workspace
	vehiclesFolder = nf
	return nf
end

local function resolveDef(carIdOrDef: any): CarDef
	if type(carIdOrDef) == "table" then
		assert(type(carIdOrDef.id) == "string", "VehicleService.spawn: CarDef without an id")
		return carIdOrDef :: CarDef
	end
	assert(type(carIdOrDef) == "string", "VehicleService.spawn: carId must be a string or a CarDef")
	local def = Cars.get(carIdOrDef)
	if def then
		return def
	end
	if carIdOrDef == Cars.Police.id or carIdOrDef == "police" then
		return Cars.Police
	end
	error(("VehicleService.spawn: unknown car id %q"):format(carIdOrDef))
end

-- PURE HELPERS (tests) -----------------------------------------------------------------------------------------------

-- May `userId` drive a car of this kind? (seat() enforces it; occupants that fail it are ejected)
function VehicleService._canDrive(kind: string, ownerUserId: number?, theft: any, userId: number): boolean
	if kind == "Police" then
		return false
	end
	if kind == "Owned" then
		return ownerUserId == nil or ownerUserId == 0 or ownerUserId == userId
	end
	if kind == "Stolen" and type(theft) == "table" then
		local function uid(x: any): number?
			if typeof(x) == "Instance" and x:IsA("Player") then
				return (x :: Player).UserId
			elseif type(x) == "number" then
				return x
			end
			return nil
		end
		local thief = uid(theft.thief) or uid(theft.thiefUserId)
		local victim = uid(theft.victim) or uid(theft.victimUserId)
		if thief == nil and victim == nil then
			return true
		end
		return userId == thief or userId == victim
	end
	return true
end

-- Server-side hold check. began = os.clock() of PromptButtonHoldBegan (nil = never began). maxAge (optional): a hold
-- that began longer ago than this is stale (tapped earlier, then triggered with a locally zeroed HoldDuration).
function VehicleService._holdOk(
	began: number?,
	now: number,
	required: number,
	tolerance: number?,
	maxAge: number?
): boolean
	if required <= 0.05 then
		return true
	end
	if began == nil then
		return false
	end
	local held = now - began
	if maxAge ~= nil and held > maxAge then
		return false
	end
	return held >= required * (tolerance or VehicleService.HOLD_TOLERANCE)
end

-- Longest a legit hold can take from HoldBegan to Triggered: the client shows at most the unscaled base duration
-- (HoldMultiplier <= 1, possibly a stale copy), plus latency jitter.
function VehicleService._holdMaxAge(required: number, base: number): number
	return math.max(required, base) * 1.25 + VehicleService.HOLD_MAX_EXTRA
end

-- Hotwire hold multiplier from the upgrade level and the Master Thief pass.
function VehicleService._holdMultiplier(hotwireLevel: number, masterThief: boolean): number
	local level = math.floor(math.max(0, num(hotwireLevel, 0)))
	local mult = EconomyMath.upgradeValue("hotwire", level)
	if masterThief then
		mult *= Monetization.MASTER_THIEF_MULT
	end
	return mult
end

-- Watchdog speed cap (studs/s, horizontal).
function VehicleService._speedCap(topSpeed: number, speedMultiplier: number?): number
	return topSpeed
		* VehicleConfig.SPEED_CAP_MULT
		* VehicleConfig.NITRO_SPEED_MULT
		* VehicleConfig.SPEED_CAP_GRACE
		* math.max(1, num(speedMultiplier, 1))
end

-- nil = fine, "teleport" = moved farther than physically possible, "speed" = over the cap.
-- displacement is horizontal; rise (optional) is the upward displacement over the same dt, held to the same bound
-- (a ramp turns at most the car's speed into climb).
function VehicleService._watchdogVerdict(
	hSpeed: number,
	displacement: number,
	dt: number,
	cap: number,
	rise: number?
): string?
	local up = rise or 0
	if hSpeed ~= hSpeed or displacement ~= displacement or up ~= up then
		return "teleport"
	end
	local allowance = cap * math.max(dt, 0) + VehicleConfig.WATCHDOG_TELEPORT_SLACK
	if displacement > allowance or up > allowance then
		return "teleport"
	end
	if hSpeed > cap then
		return "speed"
	end
	return nil
end

-- One fling sample: spin (rad/s) or vertical speed (studs/s) beyond anything driving produces.
function VehicleService._flingSample(angularSpeed: number, verticalSpeed: number): boolean
	if angularSpeed ~= angularSpeed or verticalSpeed ~= verticalSpeed then
		return true
	end
	return angularSpeed > VehicleService.WATCHDOG_FLING_SPIN
		or math.abs(verticalSpeed) > VehicleService.WATCHDOG_FLING_VERTICAL
end

-- Crash damage from two horizontal velocity samples (before armor). elapsed = real seconds between the samples
-- (default one DAMAGE_TICK): after a hitch / replication gap the change must be proportionally bigger, so hard
-- braking or a nitro launch spread over a long gap never reads as an impact.
function VehicleService._crashDamage(prevVel: Vector3, vel: Vector3, elapsed: number?): number
	local dv = (flat(vel) - flat(prevVel)).Magnitude
	local gap = num(elapsed, DAMAGE_TICK)
	local threshold = VehicleConfig.CRASH_DAMAGE_THRESHOLD * math.max(1, gap / VehicleService.DAMAGE_WINDOW)
	if dv ~= dv or dv <= threshold then
		return 0
	end
	return (dv - threshold) * VehicleConfig.CRASH_DAMAGE_SCALE
end

-- Fastest any car of this top speed can cover `distance` studs (watchdog speed band incl. nitro, no lag grace).
function VehicleService._minTravelTime(distance: number, topSpeed: number, speedMultiplier: number?): number
	if distance ~= distance then
		return math.huge
	end
	local maxSpeed = num(topSpeed, 100)
		* VehicleConfig.SPEED_CAP_MULT
		* VehicleConfig.NITRO_SPEED_MULT
		* math.max(1, num(speedMultiplier, 1))
	if maxSpeed <= 0 then
		return 0
	end
	return math.max(0, distance) / maxSpeed
end

-- Stars for a street hotwire (DECISIONS §1): a witness sees it with probability wantedChance, and then it is worth
-- at least one star. roll in [0, 1). The free first steal is applied later by addStealHeat.
function VehicleService._streetStars(wantedOnSteal: number, wantedChance: number?, roll: number): number
	local chance = num(wantedChance, 1)
	if roll >= chance then
		return 0
	end
	return math.max(1, math.floor(num(wantedOnSteal, 0)))
end

local chopCF, chopSize = MapLayout.chopZone()
local sprayZones = MapLayout.sprayZones()
local dropoffCache: { [number]: { cf: CFrame, size: Vector3 } } = {}

-- Which zones contain pos: (in own drop-off, in chop shop, spray booth index or nil).
function VehicleService._zoneFlags(pos: Vector3, plotIndex: number?): (boolean, boolean, number?)
	local inDrop = false
	if plotIndex and plotIndex >= 1 and plotIndex <= MapLayout.plotCount() and plotIndex % 1 == 0 then
		local z = dropoffCache[plotIndex]
		if not z then
			local cf, size = MapLayout.plotDropoffZone(plotIndex)
			z = { cf = cf, size = size }
			dropoffCache[plotIndex] = z
		end
		inDrop = MapLayout.isInBox(z.cf, z.size, pos)
	end
	local inChop = MapLayout.isInBox(chopCF, chopSize, pos)
	local spray: number? = nil
	for i, z in sprayZones do
		if MapLayout.isInBox(z.cframe, z.size, pos) then
			spray = i
			break
		end
	end
	return inDrop, inChop, spray
end

-- Stars a street/traffic steal adds: none for the very first steal of a brand-new player.
function VehicleService._stealHeat(stars: number, firstSteal: boolean): number
	if firstSteal then
		return 0
	end
	return math.max(0, math.floor(stars))
end

-- PLAYER MULTIPLIERS ---------------------------------------------------------------------------------------------------

local function dataOf(player: Player): any
	local ok, data = call("DataService", "get", player)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

-- Hold-time multiplier for hotwiring (upgrade * Master Thief pass). Server-authoritative; clients get a copy in the
-- player attribute "HoldMultiplier" for display only.
function VehicleService.getHoldMultiplier(player: Player): number
	local level = 0
	local data = dataOf(player)
	if data and type(data.upgrades) == "table" then
		level = num(data.upgrades.hotwire, 0)
	end
	local _, pass = call("MonetizationService", "hasPass", player, "hotwire")
	return VehicleService._holdMultiplier(level, pass == true)
end

function VehicleService.refreshHoldMultiplier(player: Player)
	if player.Parent ~= Players then
		return
	end
	local mult = VehicleService.getHoldMultiplier(player)
	if player:GetAttribute("HoldMultiplier") ~= mult then
		setAttr(player, "HoldMultiplier", mult)
	end
end

local function armorMultiplier(player: Player): number
	local data = dataOf(player)
	local level = if data and type(data.upgrades) == "table" then num(data.upgrades.armor, 0) else 0
	return EconomyMath.upgradeValue("armor", math.floor(math.max(0, level)))
end

-- True when the player's next steal is their first ever (no wanted level for the tutorial steal).
function VehicleService.isFirstSteal(player: Player): boolean
	if freeStealUsed[player] then
		return false
	end
	local data = dataOf(player)
	local steals = if data and type(data.stats) == "table" then num(data.stats.steals, 0) else 0
	return steals <= 0
end

-- Adds steal heat via WantedService (lazy), honoring the free first steal. Returns the stars actually added.
function VehicleService.addStealHeat(player: Player, stars: number, reason: string): number
	local first = VehicleService.isFirstSteal(player)
	local heat = VehicleService._stealHeat(stars, first)
	if first then
		freeStealUsed[player] = true
	end
	if heat > 0 then
		call("WantedService", "addHeat", player, heat, reason)
	end
	return heat
end

function VehicleService.contractProgress(player: Player, stat: string, amount: number)
	call("RewardsService", "progress", player, stat, amount)
end

-- EventFeed + BigSteal effect for Legendary+ steals ("hotwired", "carjacked", ...).
function VehicleService.announceSteal(player: Player, car: Car, verb: string)
	local tier = rarityDef(car)
	if tier.order < 5 then
		return
	end
	local label = VehicleService.carLabel(car)
	local hex = tier.color:ToHex()
	pcall(
		Net.fireAll,
		"EventFeed",
		`🚨 <b>{richEscape(player.DisplayName)}</b> {verb} a <font color="#{hex}"><b>{string.upper(tier.id)} {richEscape(
			label
		)}</b></font>!`
	)
	local pos = car.chassis.CFrame.Position
	pcall(Net.fireNear, "Effect", pos, 300, "BigSteal", { position = pos, text = `{string.upper(tier.id)} STEAL!` })
end

-- REGISTRY -----------------------------------------------------------------------------------------------------------

function VehicleService.get(id: number): Car?
	return cars[id]
end

-- Car for a model (or any descendant of one, e.g. a Touched hit part).
function VehicleService.fromModel(model: Instance?): Car?
	if typeof(model) ~= "Instance" then
		return nil
	end
	local node: Instance? = model
	while node and node ~= Workspace do
		local car = byModel[node]
		if car then
			return if car.destroyed then nil else car
		end
		node = node.Parent
	end
	return nil
end

function VehicleService.getDriving(player: Player): Car?
	local car = drivingByPlayer[player]
	if car and not car.destroyed then
		return car
	end
	return nil
end

function VehicleService.all(): { Car }
	local out = {}
	for _, car in cars do
		table.insert(out, car)
	end
	return out
end

-- Non-allocating all(): clears and refills a caller-owned buffer (hot loops, PERF-09). Returns the buffer.
function VehicleService.allInto(out: { Car }): { Car }
	table.clear(out)
	for _, car in cars do
		table.insert(out, car)
	end
	return out
end

function VehicleService.isTainted(car: Car): boolean
	return type(car) == "table" and type(car.data) == "table" and car.data.tainted == true
end

-- Shortest legal time to reach targetPos from where the current drive started (car.data.driveStartPos); 0 when the
-- car has never been driven.
function VehicleService.minTravelTime(car: Car, targetPos: Vector3): number
	if type(car) ~= "table" or type(car.data) ~= "table" or typeof(targetPos) ~= "Vector3" then
		return 0
	end
	local start = car.data.driveStartPos
	if typeof(start) ~= "Vector3" then
		return 0
	end
	local top = if car.def then num(car.def.topSpeed, 100) else 100
	return VehicleService._minTravelTime(flat(targetPos - start).Magnitude, top, car.model:GetAttribute("SpeedMultiplier"))
end

-- SPAWN --------------------------------------------------------------------------------------------------------------

local function newState(car: Car): CarState
	local now = os.clock()
	return {
		trove = Trove.new(),
		authorized = nil,
		authorizedUntil = 0,
		lastVel = Vector3.zero,
		lastVelAt = now,
		damageGraceUntil = now + VehicleService.DAMAGE_GRACE,
		wdCFrame = car.chassis.CFrame,
		wdAt = now,
		wdRevokedUntil = 0,
		wdSpeedStrikes = 0,
		wdFlingStrikes = 0,
		airSince = nil,
		restSince = nil,
		sunkSince = nil,
		inDropoff = false,
		dropoffFiredAt = -math.huge,
		inChop = false,
		chopEntered = false,
		chopSince = nil,
		inSpray = nil,
		returnFired = false,
		shownHealth = math.ceil(car.health),
		enterPrompt = nil,
		hotwirePrompt = nil,
		stealing = false,
	}
end

function VehicleService.spawn(
	carIdOrDef: any,
	mutation: any,
	groundCFrame: CFrame,
	kind: VehicleKind,
	opts: SpawnOpts?
): Car
	local def = resolveDef(carIdOrDef)
	assert(typeof(groundCFrame) == "CFrame", "VehicleService.spawn: groundCFrame must be a CFrame")
	assert(VALID_KINDS[kind :: string] == true, "VehicleService.spawn: bad kind " .. tostring(kind))
	local mut: MutationId = if type(mutation) == "string" and Rarity.Mutations[mutation :: MutationId]
		then mutation :: MutationId
		else "None"
	local o: SpawnOpts = opts or {}

	local model = CarBuilder.buildDef(def, mut)
	local chassis = model.PrimaryPart
	local seat = model:FindFirstChild("DriverSeat")
	if not chassis or not seat or not seat:IsA("VehicleSeat") then
		model:Destroy()
		error("VehicleService.spawn: CarBuilder model is missing Chassis / DriverSeat")
	end
	-- anchored kinds never drop, so they sit exactly at rest height (F10); physics cars settle the last few tenths
	local anchored = if o.anchored ~= nil then o.anchored == true else ANCHORED_KINDS[kind :: string] == true
	local ride = num(model:GetAttribute("RideHeight"), 2)
	model:PivotTo(groundCFrame * CFrame.new(0, ride + (if anchored then 0 else VehicleService.SPAWN_DROP), 0))

	nextId += 1
	local now = os.clock()
	local ownerUserId: number? = nil
	if typeof(o.ownerUserId) == "number" then
		ownerUserId = o.ownerUserId
	elseif typeof(o.owner) == "Instance" and (o.owner :: Instance):IsA("Player") then
		ownerUserId = (o.owner :: Player).UserId
	end
	local data: { [string]: any } = if type(o.data) == "table" then o.data else {}
	if o.slot ~= nil and data.slot == nil then
		data.slot = o.slot
	end
	local maxHealth = math.max(1, num(o.health, VehicleConfig.MAX_HEALTH))

	local car: Car = {
		id = nextId,
		model = model,
		chassis = chassis,
		seat = seat,
		carId = def.id,
		mutation = mut,
		kind = kind,
		ownerUserId = ownerUserId,
		driver = nil,
		health = maxHealth,
		lastDriverAt = now,
		data = data,
		def = def,
		rarity = def.rarity,
		maxHealth = maxHealth,
		spawnedAt = now,
		destroyed = false,
		wrecked = false,
	}

	model:SetAttribute("VehicleId", car.id)
	model:SetAttribute("CarId", def.id)
	model:SetAttribute("Mutation", mut)
	model:SetAttribute("Kind", kind)
	model:SetAttribute("Rarity", def.rarity)
	model:SetAttribute("OwnerUserId", ownerUserId or 0)
	model:SetAttribute("Health", math.ceil(maxHealth))
	model:SetAttribute("MaxHealth", maxHealth)
	model:SetAttribute("DriverUserId", 0)
	if o.slot ~= nil then
		model:SetAttribute("Slot", o.slot)
	end

	seat.Disabled = true
	chassis.Anchored = anchored
	model.Parent = VehicleService.getFolder()
	CollectionService:AddTag(model, "Vehicle")
	if kind == "Police" then
		CollectionService:AddTag(model, "Police")
	end
	if not anchored then
		pcall(chassis.SetNetworkOwner, chassis, nil)
	end

	local st = newState(car)
	cars[car.id] = car
	byModel[model] = car
	states[car] = st
	safeConnect(st.trove, function()
		return seat:GetPropertyChangedSignal("Occupant")
	end, function()
		onOccupantChanged(car)
	end)
	refreshManagedPrompts(car)
	VehicleService.Spawned:Fire(car)
	return car
end

-- KIND ---------------------------------------------------------------------------------------------------------------

-- Changes a car's kind (attribute + Police tag + managed prompts). Returns the previous kind.
function VehicleService.setKind(car: Car, kind: VehicleKind): VehicleKind
	assert(VALID_KINDS[kind :: string] == true, "VehicleService.setKind: bad kind " .. tostring(kind))
	local old = car.kind
	car.kind = kind
	setAttr(car.model, "Kind", kind)
	if kind == "Police" then
		pcall(CollectionService.AddTag, CollectionService, car.model, "Police")
	elseif old == "Police" then
		pcall(CollectionService.RemoveTag, CollectionService, car.model, "Police")
	end
	local driver = car.driver
	if kind == "Loot" and driver then
		car.ownerUserId = driver.UserId
		setAttr(car.model, "OwnerUserId", driver.UserId)
	end
	refreshManagedPrompts(car)
	return old
end

-- SEATING ------------------------------------------------------------------------------------------------------------

-- Moves an ejected character next to the car: driver side, other side, front, back, or the roof as a last resort.
local function nudgeOut(car: Car, character: Instance?)
	if not character or not character:IsA("Model") or not character.Parent then
		return
	end
	local chassis = car.chassis
	if not chassis.Parent then
		return
	end
	local params = ejectParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		ejectParams = params
	end
	params.FilterDescendantsInstances = { car.model, character }
	local cf = chassis.CFrame
	local width = num(car.model:GetAttribute("Width"), 7)
	local length = num(car.model:GetAttribute("Length"), 12)
	local height = num(car.model:GetAttribute("Height"), 5)
	local look = flat(cf.LookVector)
	look = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)
	local right = look:Cross(Vector3.yAxis)
	local origin = cf.Position + Vector3.new(0, 1, 0)
	local candidates = {
		origin - right * (width / 2 + 2.5),
		origin + right * (width / 2 + 2.5),
		origin + look * (length / 2 + 3),
		origin - look * (length / 2 + 3),
	}
	local target = cf.Position + Vector3.new(0, height + 2, 0)
	for _, c in candidates do
		local ok, hit = pcall(Workspace.Raycast, Workspace, origin, c - origin, params)
		if ok and hit == nil then
			target = c + Vector3.new(0, 1.5, 0)
			break
		end
	end
	pcall(function()
		(character :: Model):PivotTo(CFrame.lookAt(target, target + look))
	end)
end

local function destroySeatWelds(seat: VehicleSeat)
	for _, child in seat:GetChildren() do
		if child.Name == "SeatWeld" and (child:IsA("JointInstance") or child:IsA("WeldConstraint")) then
			child:Destroy()
		end
	end
end

-- Raycast straight down from the chassis, ignoring every car and `extra` (e.g. the driver). Water counts as ground.
-- Returns (ok, hit); ok = false when the ray could not be cast (callers treat that as "no evidence").
local function groundBelow(car: Car, depth: number, extra: Instance?): (boolean, any)
	local params = groundParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = false
		params.RespectCanCollide = true
		groundParams = params
	end
	groundFilter[1] = VehicleService.getFolder()
	groundFilter[2] = extra :: any
	params.FilterDescendantsInstances = groundFilter
	return pcall(Workspace.Raycast, Workspace, car.chassis.CFrame.Position, Vector3.new(0, -depth, 0), params)
end

-- SETTLING (SPEC §8: the server keeps a controller for cars settling after exit) ---------------------------------------
-- A driverless physics car would otherwise drop onto CarBuilder's two centreline bump stops and tip over. A server
-- VehicleController (isServer: impulses, no replicated VectorForces) holds it on its suspension and brakes it to a
-- stop, until it is rest-anchored, gets a driver, is destroyed, or SETTLE_MAX runs out.

local controllerModule: any = nil -- false once loading failed
local function getControllerModule(): any
	if controllerModule == nil then
		local ok, mod = pcall(function(): any
			return require(Shared.Vehicle.VehicleController) :: any
		end)
		if ok and type(mod) == "table" and typeof(mod.new) == "function" then
			controllerModule = mod
		else
			controllerModule = false
			warn("[VehicleService] VehicleController unavailable, cars won't settle: " .. tostring(mod))
		end
	end
	return if controllerModule then controllerModule else nil
end

local SETTLE_BRAKE = 0.35 -- throttle fraction used as a brake while a driverless car still rolls
local settleInput = { throttle = 0, steer = 0, handbrake = false, nitro = false }

local function stopSettling(car: Car)
	local ctrl = settling[car]
	if ctrl == nil then
		return
	end
	settling[car] = nil
	settleUntil[car] = nil
	pcall(function()
		ctrl:destroy()
	end)
end

-- Starts (or extends) the settling controller of a driverless physics car. Returns true while one runs.
-- Also called by TrafficService for rammed / knocked traffic.
function VehicleService.settle(car: Car): boolean
	if type(car) ~= "table" or car.destroyed or car.wrecked or car.driver ~= nil or states[car] == nil then
		return false
	end
	if SELF_DRIVEN_KINDS[car.kind :: string] then
		return false
	end
	local chassis = car.chassis
	if chassis.Anchored or chassis.Parent == nil then
		return false
	end
	if settling[car] ~= nil then
		settleUntil[car] = os.clock() + VehicleService.SETTLE_MAX
		return true
	end
	local VC = getControllerModule()
	if not VC then
		return false
	end
	local ok, ctrl = pcall(VC.new, car.model, car.def, { isServer = true })
	if not ok or type(ctrl) ~= "table" then
		warn("[VehicleService] settling controller failed: " .. tostring(ctrl))
		return false
	end
	settling[car] = ctrl
	settleUntil[car] = os.clock() + VehicleService.SETTLE_MAX
	return true
end

local settleErrorAt = -math.huge
local function settleStep(dt: number)
	local now = os.clock()
	for car, ctrl in settling do -- stopSettling only clears existing keys (safe while iterating)
		local chassis = car.chassis
		if
			car.destroyed
			or car.wrecked
			or car.driver ~= nil
			or chassis.Parent == nil
			or chassis.Anchored
			or now > (settleUntil[car] or 0)
		then
			stopSettling(car)
			continue
		end
		local vF = num(ctrl.forwardSpeed, 0)
		settleInput.throttle = if vF > 3 then -SETTLE_BRAKE elseif vF < -3 then SETTLE_BRAKE else 0
		local ok, err = pcall(function()
			ctrl:setInput(settleInput)
			ctrl:step(dt)
		end)
		if not ok then
			stopSettling(car)
			if now - settleErrorAt > 10 then
				settleErrorAt = now
				warn("[VehicleService] settling step failed: " .. tostring(err))
			end
		end
	end
end

-- Before rest-anchoring: put a tipped (or hovering) car level on flat ground at exactly its rest height, so parked
-- and abandoned cars never freeze at an angle. Slopes / ramps are left alone.
local function restPose(car: Car)
	local chassis = car.chassis
	local cf = chassis.CFrame
	local ride = num(car.model:GetAttribute("RideHeight"), 2)
	local ok, hit = groundBelow(car, ride + 3, nil)
	if not ok or hit == nil or hit.Normal.Y < 0.98 then
		return
	end
	local look = flat(cf.LookVector)
	if look.Magnitude < 0.1 then
		return
	end
	local target = hit.Position + Vector3.new(0, ride, 0)
	local dy = math.abs(cf.Position.Y - target.Y)
	if dy > 3 or (cf.UpVector.Y >= 0.98 and dy < 0.05) then
		return
	end
	pcall(function()
		car.model:PivotTo(CFrame.lookAt(target, target + look.Unit))
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
	end)
end

-- Removes whoever sits in the seat (server-authoritative) without touching driver bookkeeping.
local function kickOccupant(car: Car, nudge: boolean)
	local seat = car.seat
	local humanoid = seat.Occupant
	destroySeatWelds(seat)
	seat.Disabled = true
	if humanoid then
		pcall(function()
			humanoid.Sit = false
		end)
		if nudge then
			nudgeOut(car, humanoid.Parent)
		end
	end
end

setDriver = function(car: Car, player: Player?)
	local st = states[car]
	local old = car.driver
	if old == player then
		if player and st then
			st.authorized = nil
		end
		return
	end
	local now = os.clock()
	car.driver = player
	car.lastDriverAt = now
	if old and drivingByPlayer[old] == car then
		drivingByPlayer[old] = nil
		setAttr(old, "Driving", false)
	end
	local chassis = car.chassis
	if player then
		local prev = drivingByPlayer[player]
		if prev and prev ~= car and prev.driver == player then
			-- one car per player: drop the old one silently (the seat weld already moved)
			kickOccupant(prev, false)
			setDriver(prev, nil)
		end
		drivingByPlayer[player] = car
		setAttr(player, "Driving", true)
		setAttr(car.model, "DriverUserId", player.UserId)
		if car.kind == "Loot" and car.ownerUserId ~= player.UserId then
			-- whoever drives loot claims it (instant "Get in" for them after hopping out)
			car.ownerUserId = player.UserId
			setAttr(car.model, "OwnerUserId", player.UserId)
		end
		if st then
			st.authorized = nil
			st.restSince = nil
			st.lastVel = flat(chassis.AssemblyLinearVelocity)
			st.damageGraceUntil = now + VehicleService.DAMAGE_GRACE
			st.wdCFrame = chassis.CFrame
			st.wdAt = now
			st.wdRevokedUntil = 0
			st.wdSpeedStrikes = 0
			st.inDropoff = false
			st.inChop = false
			st.inSpray = nil
		end
		if not car.destroyed then
			chassis.Anchored = false
			pcall(chassis.SetNetworkOwner, chassis, player)
		end
	else
		setAttr(car.model, "DriverUserId", 0)
		car.seat.Disabled = true
		if st then
			st.restSince = nil
			st.inDropoff = false
			st.inChop = false
			st.inSpray = nil
		end
		if not car.destroyed and chassis.Parent and not chassis.Anchored then
			pcall(chassis.SetNetworkOwner, chassis, nil)
		end
	end
	refreshManagedPrompts(car)
	VehicleService.DriverChanged:Fire(car, player, old)
end

onOccupantChanged = function(car: Car)
	if car.destroyed then
		return
	end
	local seat = car.seat
	local humanoid = seat.Occupant
	if humanoid == nil then
		seat.Disabled = true
		if car.driver then
			setDriver(car, nil)
		end
		return
	end
	local player = Players:GetPlayerFromCharacter(humanoid.Parent)
	local st = states[car]
	local authorized = player ~= nil
		and (car.driver == player or (st ~= nil and st.authorized == player and os.clock() <= st.authorizedUntil + 1))
		and VehicleService._canDrive(car.kind, car.ownerUserId, car.data.theft, (player :: Player).UserId)
	if authorized and player then
		setDriver(car, player)
	else
		warn(
			("[VehicleService] ejecting unauthorized occupant %s from car %d (%s)"):format(
				if player then player.Name else humanoid:GetFullName(),
				car.id,
				car.kind
			)
		)
		kickOccupant(car, true)
		if car.driver then
			setDriver(car, nil)
		end
	end
end

-- Puts `player` in the driver seat (the only way into a car). Returns (true) or (false, reason).
function VehicleService.seat(car: Car, player: Player): (boolean, string?)
	if type(car) ~= "table" or car.destroyed or car.wrecked then
		return false, "gone"
	end
	local st = states[car]
	if not st or not car.model.Parent or not car.chassis.Parent then
		return false, "gone"
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return false, "player"
	end
	if not VehicleService._canDrive(car.kind, car.ownerUserId, car.data.theft, player.UserId) then
		return false, "not allowed"
	end
	local char, humanoid, root = characterOf(player)
	if not char or not humanoid or not root or humanoid.Health <= 0 then
		return false, "no character"
	end
	local seat = car.seat
	if seat.Occupant == humanoid then
		setDriver(car, player)
		return true
	end
	if car.driver ~= nil and car.driver ~= player then
		return false, "occupied"
	end
	if seat.Occupant ~= nil then
		kickOccupant(car, true) -- stale / unauthorized occupant
	end
	local other = drivingByPlayer[player]
	if other and other ~= car then
		VehicleService.eject(other)
	end
	local current = humanoid.SeatPart
	if current and current ~= seat then
		for _, child in current:GetChildren() do
			if child.Name == "SeatWeld" then
				child:Destroy()
			end
		end
		pcall(function()
			humanoid.Sit = false
		end)
	end

	local now = os.clock()
	st.authorized = player
	st.authorizedUntil = now + VehicleService.SEAT_AUTH_WINDOW
	st.restSince = nil
	refreshManagedPrompts(car)
	local chassis = car.chassis
	chassis.Anchored = false
	seat.Disabled = false
	pcall(chassis.SetNetworkOwner, chassis, player)
	local okSit, err = pcall(seat.Sit, seat, humanoid)
	if not okSit then
		warn("[VehicleService] seat:Sit failed: " .. tostring(err))
		st.authorized = nil
		seat.Disabled = true
		pcall(chassis.SetNetworkOwner, chassis, nil)
		refreshManagedPrompts(car)
		return false, "sit failed"
	end
	if seat.Occupant == humanoid then
		setDriver(car, player)
	end
	task.delay(VehicleService.SEAT_AUTH_WINDOW + 0.5, function()
		if car.destroyed then
			return
		end
		if st.authorized == player then
			st.authorized = nil
		end
		if car.driver == nil and seat.Occupant == nil then
			seat.Disabled = true
			if chassis.Parent and not chassis.Anchored then
				pcall(chassis.SetNetworkOwner, chassis, nil)
			end
			refreshManagedPrompts(car)
		end
	end)
	return true
end

-- Server-authoritative exit: destroys the SeatWeld and nudges the character out beside the car.
function VehicleService.eject(car: Car)
	if type(car) ~= "table" or not car.seat then
		return
	end
	kickOccupant(car, true)
	if car.driver then
		setDriver(car, nil)
	end
end

-- Moves a car on purpose (server teleports) without tripping the watchdog or crash damage.
function VehicleService.teleport(car: Car, cframe: CFrame)
	if type(car) ~= "table" or car.destroyed then
		return
	end
	car.model:PivotTo(cframe)
	VehicleService.resetWatchdog(car)
end

function VehicleService.resetWatchdog(car: Car)
	local st = states[car]
	if not st then
		return
	end
	local now = os.clock()
	st.wdCFrame = car.chassis.CFrame
	st.wdAt = now
	st.wdSpeedStrikes = 0
	st.lastVel = flat(car.chassis.AssemblyLinearVelocity)
	st.damageGraceUntil = math.max(st.damageGraceUntil, now + VehicleService.DAMAGE_GRACE)
end

function VehicleService.getSpeedCap(car: Car): number
	return VehicleService._speedCap(num(car.def.topSpeed, 100), car.model:GetAttribute("SpeedMultiplier"))
end

-- STEAL PROMPTS ------------------------------------------------------------------------------------------------------

-- One ProximityPrompt in the chassis with server-side hold + distance validation. canSteal runs at trigger time;
-- onStolen does the conversion (setKind / seat / heat are the caller's job). Fires Stolen(player, car, prevKind)
-- after onStolen succeeds. The prompt is destroyed with the car.
function VehicleService.addStealPrompt(car: Car, opts: StealPromptOpts): ProximityPrompt
	assert(type(car) == "table" and car.chassis, "VehicleService.addStealPrompt: bad car")
	assert(type(opts) == "table" and typeof(opts.onStolen) == "function", "VehicleService.addStealPrompt: bad opts")
	local st = states[car]
	local base = math.max(0, num(opts.holdDuration, 1))
	local scale = opts.scaleWithHotwire ~= false
	local action = if type(opts.actionText) == "string" then opts.actionText else "Steal"
	local maxDistance = num(opts.maxDistance, VehicleService.PROMPT_DISTANCE)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = opts.name
		or (
			if not scale
				then "ActionPrompt"
				elseif action == "Carjack" or action == "Hotwire" then action
				else "StealPrompt"
		)
	prompt.ActionText = action
	prompt.ObjectText = opts.objectText or VehicleService.carLabel(car)
	prompt.HoldDuration = base
	prompt.MaxActivationDistance = maxDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = opts.keyCode or Enum.KeyCode.E
	prompt.GamepadKeyCode = opts.gamepadKeyCode or Enum.KeyCode.ButtonX
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt:SetAttribute("BaseHoldDuration", base)
	prompt:SetAttribute("ScalesWithHotwire", scale)

	local holds: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	local function required(player: Player): number
		local b = num(prompt:GetAttribute("BaseHoldDuration"), base)
		return if scale then b * VehicleService.getHoldMultiplier(player) else b
	end

	pcall(function()
		prompt.PromptButtonHoldBegan:Connect(function(player: Player)
			holds[player] = os.clock()
			if opts.onHoldBegan then
				pcall(opts.onHoldBegan, player)
			end
		end)
		prompt.PromptButtonHoldEnded:Connect(function(player: Player)
			-- an interrupted hold must start over (a completed one is kept for the Triggered that follows)
			local began = holds[player]
			if began and os.clock() - began < required(player) * VehicleService.HOLD_TOLERANCE then
				holds[player] = nil
			end
		end)
		prompt.Triggered:Connect(function(player: Player)
			local began = holds[player]
			holds[player] = nil
			if car.destroyed or car.wrecked or not prompt.Enabled or prompt.Parent == nil then
				return
			end
			if typeof(player) ~= "Instance" or player.Parent ~= Players or not isAlive(player) then
				return
			end
			if not VehicleService._holdOk(began, os.clock(), required(player)) then
				return -- hold too short (spoofed / lagged trigger)
			end
			if
				not withinReach(
					player,
					car.chassis.CFrame.Position,
					prompt.MaxActivationDistance + VehicleService.PROMPT_SLACK
				)
			then
				return
			end
			if st and st.stealing then
				return
			end
			local okC, can, why = pcall(opts.canSteal, player)
			if not okC then
				warn("[VehicleService] canSteal errored: " .. tostring(can))
				return
			end
			if not can then
				if type(why) == "string" and why ~= "" then
					notify(player, "error", why)
				end
				return
			end
			local previousKind = car.kind
			if st then
				st.stealing = true
			end
			local okS, err = pcall(opts.onStolen, player)
			if st then
				st.stealing = false
			end
			if not okS then
				warn("[VehicleService] onStolen errored: " .. tostring(err))
				return
			end
			VehicleService.Stolen:Fire(player, car, previousKind)
		end)
	end)

	prompt.Parent = car.chassis
	if st then
		st.trove:Add(prompt)
	end
	return prompt
end

-- MANAGED PROMPTS (get back into unoccupied Owned / Loot cars) -----------------------------------------------------

local function playerByUserId(userId: number?): Player?
	if not userId or userId == 0 then
		return nil
	end
	local ok, p = pcall(Players.GetPlayerByUserId, Players, userId)
	return if ok then p else nil
end

local function ownerName(userId: number?): string?
	local p = playerByUserId(userId)
	return if p then p.DisplayName else nil
end

local function onEnterTriggered(car: Car, player: Player)
	if car.destroyed or car.wrecked or car.driver ~= nil then
		return
	end
	if typeof(player) ~= "Instance" or player.Parent ~= Players or not isAlive(player) then
		return
	end
	if
		not withinReach(
			player,
			car.chassis.CFrame.Position,
			VehicleService.PROMPT_DISTANCE + VehicleService.PROMPT_SLACK
		)
	then
		return
	end
	if player:GetAttribute("Stunned") == true or VehicleService.getDriving(player) ~= nil then
		return
	end
	local allowed = (car.kind == "Owned" or car.kind == "Loot")
		and (car.ownerUserId == nil or car.ownerUserId == 0 or car.ownerUserId == player.UserId)
	if not allowed then
		local name = ownerName(car.ownerUserId)
		notify(player, "info", if name then `🔒 That's {name}'s ride!` else "🔒 You can't drive that one.", 2)
		return
	end
	VehicleService.seat(car, player)
end

local function canHotwireLoot(car: Car, player: Player): (boolean, string?)
	if car.destroyed or car.wrecked or car.kind ~= "Loot" or car.driver ~= nil then
		return false, nil
	end
	if player:GetAttribute("Stunned") == true then
		return false, nil
	end
	if VehicleService.getDriving(player) ~= nil then
		return false, "You're already driving!"
	end
	return true, nil
end

local function hotwireLoot(car: Car, player: Player)
	local prevClaimer = car.ownerUserId
	local tier = rarityDef(car)
	VehicleService.seat(car, player)
	car.ownerUserId = player.UserId
	setAttr(car.model, "OwnerUserId", player.UserId)
	refreshManagedPrompts(car)
	local verb = "hotwired"
	if prevClaimer and prevClaimer ~= 0 and prevClaimer ~= player.UserId then
		local victim = playerByUserId(prevClaimer)
		if victim then
			notify(victim, "warning", `😱 {player.DisplayName} hotwired your {VehicleService.carLabel(car)}!`)
		end
		verb = "snatched"
	end
	VehicleService.addStealHeat(player, tier.wantedOnSteal, "lootSteal")
	VehicleService.contractProgress(player, "steal", 1)
	VehicleService.announceSteal(player, car, verb)
end

local function createEnterPrompt(car: Car, st: CarState): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.Name = "EnterPrompt"
	pp.ActionText = "Drive"
	pp.ObjectText = VehicleService.carLabel(car)
	pp.HoldDuration = 0
	pp.KeyboardKeyCode = Enum.KeyCode.F
	pp.GamepadKeyCode = Enum.KeyCode.ButtonY
	pp.RequiresLineOfSight = false
	pp.MaxActivationDistance = VehicleService.PROMPT_DISTANCE
	pp.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	pcall(function()
		pp.Triggered:Connect(function(player: Player)
			onEnterTriggered(car, player)
		end)
	end)
	pp.Parent = car.chassis
	st.trove:Add(pp)
	return pp
end

refreshManagedPrompts = function(car: Car)
	local st = states[car]
	if not st then
		return
	end
	local idle = not car.destroyed and not car.wrecked and car.driver == nil and st.authorized == nil
	local claimer: number? = if car.kind == "Loot"
			and car.ownerUserId
			and car.ownerUserId ~= 0
		then car.ownerUserId
		else nil
	local wantEnter = idle and (car.kind == "Owned" or claimer ~= nil)
	local wantHotwire = idle and car.kind == "Loot"

	if wantEnter then
		local pp = st.enterPrompt
		if not pp or not pp.Parent then
			pp = createEnterPrompt(car, st)
			st.enterPrompt = pp
		end
		local prompt = pp :: ProximityPrompt
		local uid = if car.kind == "Owned" then car.ownerUserId else claimer
		setAttr(prompt, "OnlyUserId", uid or 0)
		prompt.ActionText = if car.kind == "Owned" then "Drive" else "Get in"
		local name = ownerName(uid)
		prompt.ObjectText = if name then `{name}'s {VehicleService.carLabel(car)}` else VehicleService.carLabel(car)
		prompt.Enabled = true
	elseif st.enterPrompt then
		st.enterPrompt:Destroy()
		st.enterPrompt = nil
	end

	if wantHotwire then
		local pp = st.hotwirePrompt
		if not pp or not pp.Parent then
			pp = VehicleService.addStealPrompt(car, {
				actionText = "Hotwire",
				holdDuration = rarityDef(car).hotwireTime,
				objectText = VehicleService.carLabel(car),
				canSteal = function(player: Player): (boolean, string?)
					return canHotwireLoot(car, player)
				end,
				onStolen = function(player: Player)
					hotwireLoot(car, player)
				end,
			})
			st.hotwirePrompt = pp
		end
		setAttr(pp, "HideForUserId", claimer or 0)
	elseif st.hotwirePrompt then
		st.hotwirePrompt:Destroy()
		st.hotwirePrompt = nil
	end
end

-- DAMAGE / WRECK / DESTROY ----------------------------------------------------------------------------------------------

function VehicleService.damage(car: Car, amount: number, sourcePlayer: Player?)
	if type(car) ~= "table" or car.destroyed or car.wrecked then
		return
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	local mult = 1
	local driver = car.driver
	if driver then
		mult = armorMultiplier(driver)
	end
	car.health = math.max(0, car.health - math.min(amount, 1e6) * mult)
	local st = states[car]
	local shown = math.ceil(car.health)
	if st then
		st.shownHealth = shown
	end
	setAttr(car.model, "Health", shown)
	if sourcePlayer then
		car.data.lastDamagedBy = sourcePlayer
	end
	if car.health <= 0 then
		VehicleService.wreck(car)
	end
end

-- Health 0: cartoon KAPOW + smoke, everyone out, destroyed WRECK_DESTROY_AFTER later (reason "wrecked").
function VehicleService.wreck(car: Car)
	if type(car) ~= "table" or car.destroyed or car.wrecked then
		return
	end
	car.wrecked = true
	car.health = 0
	local model, chassis = car.model, car.chassis
	setAttr(model, "Health", 0)
	setAttr(model, "Wrecked", true)
	local driver = car.driver
	for _, d in model:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			d.Enabled = false
		end
	end
	refreshManagedPrompts(car)
	VehicleService.eject(car)
	if driver then
		notify(driver, "error", "💥 WRECKED! That ride is toast.", 3)
	end
	local pos = chassis.CFrame.Position
	pcall(Net.fireNear, "Effect", pos, 500, "CarWreck", { position = pos, color = car.def.color })
	pcall(function()
		-- charred paint + a lazy smoke plume everyone can see, and a little cartoon hop
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				local paint = d:GetAttribute("Paint")
				if paint == "primary" or paint == "accent" then
					d.Color = d.Color:Lerp(Color3.fromRGB(30, 30, 34), 0.55)
				end
			end
		end
		local smoke = Instance.new("Smoke")
		smoke.Name = "WreckSmoke"
		smoke.Color = Color3.fromRGB(215, 215, 222)
		smoke.Opacity = 0.35
		smoke.RiseVelocity = 7
		smoke.Size = 5
		smoke.Parent = chassis
		if not chassis.Anchored then
			local mass = chassis.AssemblyMass
			chassis:ApplyImpulse(Vector3.new(0, mass * 38, 0))
			chassis:ApplyAngularImpulse(Vector3.new(0, 0, mass * (if math.random() < 0.5 then -6 else 6)))
		end
	end)
	VehicleService.Wrecked:Fire(car)
	task.delay(VehicleService.WRECK_DESTROY_AFTER, function()
		VehicleService.destroy(car, "wrecked")
	end)
end

function VehicleService.destroy(car: Car, reason: string?)
	if type(car) ~= "table" or car.destroyed then
		return
	end
	car.destroyed = true
	local why = if type(reason) == "string" then reason else "destroyed"
	local st = states[car]
	if car.seat and (car.seat.Occupant ~= nil or car.driver ~= nil) then
		kickOccupant(car, true)
	end
	if cars[car.id] == car then
		cars[car.id] = nil
	end
	if byModel[car.model] == car then
		byModel[car.model] = nil
	end
	VehicleService.Destroyed:Fire(car, why)
	if car.driver then
		setDriver(car, nil)
	end
	states[car] = nil
	if st then
		st.enterPrompt = nil
		st.hotwirePrompt = nil
		st.trove:Clean()
	end
	pcall(function()
		car.model:Destroy()
	end)
end

-- PASSES -------------------------------------------------------------------------------------------------------------

local function returnHome(car: Car, st: CarState)
	if st.returnFired or car.destroyed then
		return
	end
	st.returnFired = true
	VehicleService.ReturnedHome:Fire(car)
	task.delay(VehicleService.RETURN_DESTROY_DELAY, function()
		if not car.destroyed and car.kind == "Owned" then
			VehicleService.destroy(car, "returned")
		end
	end)
end

local function fireDelivery(player: Player, car: Car, st: CarState, now: number)
	st.dropoffFiredAt = now
	VehicleService.DeliveryAttempt:Fire(player, car)
	if car.kind == "Owned" then
		-- GarageService parks Owned cars on DeliveryAttempt; if nobody did, send it home the other way.
		task.delay(VehicleService.OWNED_FALLBACK_DELAY, function()
			if not car.destroyed and car.kind == "Owned" and not st.returnFired then
				returnHome(car, st)
			end
		end)
	end
end

-- Snapshot of drivingByPlayer into reusable arrays: signal handlers fired from a pass may seat / eject players,
-- and adding keys to a table while traversing it is undefined.
local scratchPlayers: { Player } = {}
local scratchCars: { Car } = {}
local function snapshotDriving(): number
	local n = 0
	for p, c in drivingByPlayer do
		n += 1
		scratchPlayers[n] = p
		scratchCars[n] = c
	end
	for i = n + 1, #scratchPlayers do
		scratchPlayers[i] = nil
		scratchCars[i] = nil
	end
	return n
end

local function damagePass(now: number)
	for i = 1, snapshotDriving() do
		local car = scratchCars[i]
		if drivingByPlayer[scratchPlayers[i]] ~= car then
			continue
		end
		local st = states[car]
		if not st or car.destroyed or car.wrecked then
			continue
		end
		local chassis = car.chassis
		if chassis.Anchored then
			continue
		end
		local vel = flat(chassis.AssemblyLinearVelocity)
		local dmg = VehicleService._crashDamage(st.lastVel, vel)
		st.lastVel = vel
		if dmg > 0 and now >= st.damageGraceUntil then
			VehicleService.damage(car, dmg, nil)
		end
	end
end

local function zonePass(now: number)
	for i = 1, snapshotDriving() do
		local player, car = scratchPlayers[i], scratchCars[i]
		if drivingByPlayer[player] ~= car then
			continue
		end
		local st = states[car]
		if not st or car.destroyed or car.wrecked then
			continue
		end
		local pos = car.chassis.CFrame.Position
		local attr = player:GetAttribute("PlotIndex")
		local plot: number? = if typeof(attr) == "number" then attr else nil
		if car.kind == "Owned" and car.data.leftGarage ~= true then
			if plot == nil or MapLayout.plotAt(pos) ~= plot then
				car.data.leftGarage = true
			end
		end
		local inDrop, inChop, spray = VehicleService._zoneFlags(pos, plot)
		if inDrop then
			local eligible = car.kind ~= "Owned" or car.data.leftGarage == true
			if eligible and (not st.inDropoff or now - st.dropoffFiredAt >= VehicleService.DELIVERY_RETRY) then
				fireDelivery(player, car, st, now)
			end
		end
		st.inDropoff = inDrop
		if car.destroyed or car.driver ~= player then
			continue -- delivered / parked by a handler
		end
		if inChop and not st.inChop then
			VehicleService.ChopAttempt:Fire(player, car)
		end
		st.inChop = inChop
		if spray ~= nil and st.inSpray ~= spray then
			VehicleService.SprayAttempt:Fire(player, car)
		end
		st.inSpray = spray
	end
end

local function violate(
	car: Car,
	player: Player,
	st: CarState,
	verdict: string,
	hSpeed: number,
	disp: number,
	cap: number
)
	local now = os.clock()
	local revoke = VehicleConfig.WATCHDOG_REVOKE_SECONDS
	st.wdRevokedUntil = now + revoke
	st.wdSpeedStrikes = 0
	st.damageGraceUntil = now + revoke + VehicleService.DAMAGE_GRACE
	warn(
		("[VehicleService] watchdog %s: %s in car %d speed %.0f disp %.0f cap %.0f -> rewind"):format(
			verdict,
			player.Name,
			car.id,
			hSpeed,
			disp,
			cap
		)
	)
	local chassis = car.chassis
	pcall(chassis.SetNetworkOwner, chassis, nil)
	pcall(function()
		car.model:PivotTo(st.wdCFrame)
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
	end)
	task.delay(revoke, function()
		if car.destroyed or car.driver ~= player then
			return
		end
		if not chassis.Anchored then
			pcall(chassis.SetNetworkOwner, chassis, player)
		end
		st.wdCFrame = chassis.CFrame
		st.wdAt = os.clock()
		st.lastVel = flat(chassis.AssemblyLinearVelocity)
	end)
end

local function watchdogPass(now: number)
	for i = 1, snapshotDriving() do
		local player, car = scratchPlayers[i], scratchCars[i]
		if drivingByPlayer[player] ~= car then
			continue
		end
		local st = states[car]
		if not st or car.destroyed or car.wrecked or now < st.wdRevokedUntil then
			continue
		end
		local chassis = car.chassis
		local cf = chassis.CFrame
		if chassis.Anchored then
			st.wdCFrame = cf
			st.wdAt = now
			continue
		end
		local disp = flat(cf.Position - st.wdCFrame.Position).Magnitude
		local hSpeed = flat(chassis.AssemblyLinearVelocity).Magnitude
		local cap = VehicleService.getSpeedCap(car)
		local dt = math.min(now - st.wdAt, VehicleService.WATCHDOG_MAX_DT)
		local verdict = VehicleService._watchdogVerdict(hSpeed, disp, dt, cap)
		if verdict == "speed" then
			st.wdSpeedStrikes += 1
			if st.wdSpeedStrikes < 2 and hSpeed < cap * VehicleService.WATCHDOG_BLATANT then
				verdict = nil -- one fling sample is not evidence
			end
		elseif verdict == nil then
			st.wdSpeedStrikes = 0
		end
		if verdict then
			violate(car, player, st, verdict, hSpeed, disp, cap)
		elseif disp > 0.01 or now - st.wdAt > VehicleService.WATCHDOG_MAX_DT then
			-- a frozen position (replication stall) keeps accruing allowance instead of resetting it
			st.wdCFrame = cf
			st.wdAt = now
		end
	end
end

local function lifePass(now: number)
	for _, car in VehicleService.all() do -- snapshot: handlers may spawn / destroy cars
		local st = states[car]
		if not st or car.destroyed then
			continue
		end
		local model, chassis = car.model, car.chassis
		if model.Parent == nil or chassis.Parent == nil then
			VehicleService.destroy(car, "lost")
			continue
		end
		if car.wrecked then
			continue
		end
		-- other systems may write car.health directly (spray repair): keep the attribute in sync
		local shown = math.ceil(car.health)
		if shown ~= st.shownHealth then
			st.shownHealth = shown
			setAttr(model, "Health", shown)
		end
		if car.health <= 0 then
			VehicleService.wreck(car)
			continue
		end
		local pos = chassis.CFrame.Position
		if pos.Y < VehicleService.LOST_Y then
			if car.kind == "Owned" then
				VehicleService.eject(car)
				returnHome(car, st)
			elseif car.kind ~= "Stolen" then -- TheftService fails sunk thefts itself
				VehicleService.destroy(car, "lost")
			end
			continue
		end

		local driver = car.driver
		if driver then
			car.lastDriverAt = now
			local _, humanoid = characterOf(driver)
			if driver.Parent ~= Players or not humanoid or humanoid.Health <= 0 then
				VehicleService.eject(car)
			elseif car.seat.Occupant ~= humanoid then
				setDriver(car, nil) -- missed Occupant signal
			end
			continue
		end
		if car.seat.Occupant ~= nil and st.authorized == nil then
			onOccupantChanged(car) -- nobody should be sitting here
		end

		if not SELF_DRIVEN_KINDS[car.kind :: string] and not chassis.Anchored and st.authorized == nil then
			if chassis.AssemblyLinearVelocity.Magnitude < VehicleService.REST_SPEED then
				local since = st.restSince or now
				st.restSince = since
				if now - since >= VehicleConfig.PARK_ANCHOR_AFTER then
					chassis.Anchored = true
					st.restSince = nil
				end
			else
				st.restSince = nil
			end
		end

		local idle = now - car.lastDriverAt
		if car.kind == "Owned" then
			if idle >= VehicleConfig.OWNED_RETURN_AFTER and st.authorized == nil then
				returnHome(car, st)
			end
		elseif car.kind == "Loot" then
			if
				idle >= VehicleConfig.ABANDON_DESPAWN
				and st.authorized == nil
				and not anyPlayerNear(pos, VehicleConfig.NEAR_PLAYER_RADIUS)
			then
				VehicleService.destroy(car, "abandoned")
			end
		end
	end
end

local function holdPass()
	for _, player in Players:GetPlayers() do
		VehicleService.refreshHoldMultiplier(player)
	end
end

-- LIFECYCLE ----------------------------------------------------------------------------------------------------------

local passErrors: { [string]: number } = {}
local function runPass(name: string, fn: (number) -> (), now: number)
	local ok, err = pcall(fn, now)
	if not ok then
		local last = passErrors[name] or -math.huge
		if now - last > 10 then
			passErrors[name] = now
			warn(("[VehicleService] %s pass failed: %s"):format(name, tostring(err)))
		end
	end
end

local function onPlayerRemoving(player: Player)
	local car = drivingByPlayer[player]
	if car then
		setDriver(car, nil)
	end
	drivingByPlayer[player] = nil
	freeStealUsed[player] = nil
	for _, st in states do
		if st.authorized == player then
			st.authorized = nil
		end
	end
end

function VehicleService.init()
	VehicleService.getFolder()
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	local DataService = sys("DataService")
	if DataService and DataService.Loaded then
		DataService.Loaded:Connect(function(player: Player)
			VehicleService.refreshHoldMultiplier(player)
		end)
	end
	local Monet = sys("MonetizationService")
	if Monet and Monet.PassChanged then
		Monet.PassChanged:Connect(function(player: Player, key: string)
			if key == "hotwire" then
				VehicleService.refreshHoldMultiplier(player)
			end
		end)
	end
end

function VehicleService.start()
	local function onPlayerAdded(player: Player)
		VehicleService.refreshHoldMultiplier(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end

	local accDamage, accZone, accWatch, accLife, accHold = 0, 0, 0, 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		accDamage += dt
		accZone += dt
		accWatch += dt
		accLife += dt
		accHold += dt
		if accDamage >= DAMAGE_TICK then
			accDamage = 0
			runPass("damage", damagePass, now)
		end
		if accZone >= ZONE_TICK then
			accZone = 0
			runPass("zone", zonePass, now)
		end
		if accWatch >= WATCHDOG_TICK then
			accWatch = 0
			runPass("watchdog", watchdogPass, now)
		end
		if accLife >= LIFE_TICK then
			accLife = 0
			runPass("life", lifePass, now)
		end
		if accHold >= HOLD_MULT_TICK then
			accHold = 0
			runPass("hold", function()
				holdPass()
			end, now)
		end
	end)
end

return VehicleService
