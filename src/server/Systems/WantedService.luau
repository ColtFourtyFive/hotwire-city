--!strict
-- WantedService: per-player wanted stars (0..5), heat, the GTA V evade model, Spray Shop clears and BUSTED.
--
-- Public API (docs/SPEC.md §6):
--   addHeat(player, stars, reason)      raise wanted level (ignored during post-bust grace; halved for brand-new players)
--   getStars(player): number
--   clear(player, reason): boolean      drop to 0 stars ("decay"/"spray" count as an escape for contracts); returns
--                                       true only when there were stars to clear (paid products check this)
--   bust(player, reason?): boolean      BUSTED: theft fails / loot impounded, cash penalty, release at Police HQ
--   Changed: Signal(player, stars, old)
--   Busted: Signal(player)
-- Extra helpers: set(player, stars, reason), isInGrace(player), getPeak(player),
--   consumeRespawnAtHQ(player): boolean  true once after a wanted player died (reset) and was busted for it;
--                                       PlotService spawns that character at Police HQ instead of the garage
-- Combat v2 (gta_combat §7, §9.4, §9.5): raiseTo(player, stars, reason, pos?) (crime floors; a witnessed crime also
--   pins the last known position), clearOnWasted(player) (a WASTED death clears the stars and fails a theft like a
--   bust, without the bail), surrender(player) (<= 2 stars with police within 40 studs: busted at half the bail),
--   getSearchArea(player): (Vector3?, number?).
-- Pure helpers (tested in tests/spec/police.spec.luau): _penalty, _adjustHeat, _decayDelay, _tickEvade, _sprayCost
--
-- Evade (replaces v1's star-by-star decay): while police can see you the timer is full (DECAY_DELAY[stars]) and
-- your last known position (LKP) follows you. Out of sight it counts down 1x inside the search circle around the LKP
-- (radius SEARCH_RADIUS[stars]) and EVADE_OUTSIDE_MULT x outside it; any sighting resets it. At zero every star
-- clears at once ("You evaded the police.").
--
-- Remotes: Busted(lostCash: number, carLabel: string?) carLabel = the impounded car (failed theft / loot) if any.
-- Player attributes written here: Wanted (0..5), WantedSeen (bool: police currently see you; the HUD flashes the
-- stars while you are hidden), WantedDecayAt (number: server time when you evade if nothing changes; 0 while seen /
-- not wanted), LastKnownPos (Vector3), SearchRadius (number; 0 when clean), SprayCost (number: what a Spray Shop
-- charges right now, refreshed ~1 Hz while wanted since it follows income; 0 when clean).
--
-- Spray Shops only work while no cop sees you: a seen car waiting in the booth is sprayed as soon as they lose you.
-- Dying while wanted with no recent damage (e.g. resetting to get home) is a bust, unless it happens inside your own
-- garage; DamageService owns the death classification (gta_combat §7.1) and calls bust / clearOnWasted.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local MapLayout = require(Shared.Util.MapLayout)
local PoliceConfig = require(Shared.Config.Police)
local Economy = require(Shared.Config.Economy)
local VehicleConfig = require(Shared.Config.Vehicle)
local Cars = require(Shared.Config.Cars)
local Rarity = require(Shared.Config.Rarity)
local PoliceAim = require(Shared.Combat.PoliceAim)

local WantedService = {}

WantedService.Changed = Signal.new() -- (player, stars, old)
WantedService.Busted = Signal.new() -- (player)

local MAX_STARS = PoliceConfig.MAX_STARS
local BUST_GRACE = 8 -- seconds after a bust during which no heat can be added
local NEW_PLAYER_WINDOW = 30 -- brand-new players get halved heat for this long after joining
local DECAY_INTERVAL = 0.25
-- Seconds between BUSTED and the teleport to Police HQ: the arrest shot holds while the shard is up (gta_ui_language
-- §5.9: grade at 1.0 s, shard at 1.2 s, black at ~4.4 s); the player stays frozen (stunned) and protected until then.
local RELEASE_DELAY = 5.0
WantedService.RELEASE_DELAY = RELEASE_DELAY
local RELEASE_STUN_EXTRA = 0.3 -- busted players stay stunned a moment past the teleport (no hopping into cars)
local RESPAWN_AT_HQ_WINDOW = 60 -- a died-while-wanted bust sends the next spawn within this long to Police HQ
local SPRAY_COOLDOWN = 1.5
local SPRAY_FAIL_NOTIFY_COOLDOWN = 4
local DECAY_ATTR_EPSILON = 0.5 -- rewrite WantedDecayAt only when it moves by more than this (seconds)
local SPRAY_COST_REFRESH = 1 -- seconds between SprayCost attribute refreshes while wanted
local LKP_EPSILON = 5 -- republish LastKnownPos only when it moved more than this
local SURRENDER_RANGE = 40
local SURRENDER_MAX_STARS = 2

type State = {
	stars: number,
	peak: number, -- highest stars reached in the current chase (reset when stars hit 0)
	nextDecayAt: number,
	graceUntil: number,
	joinedAt: number,
	seen: boolean,
	hintedWanted: boolean,
	lastSprayAt: number,
	lastSprayFailNotify: number,
	lastSprayWatchNotify: number,
	pendingSpray: any?, -- car waiting in a Spray Shop for the cops to lose sight of it
	decayAttr: number, -- last WantedDecayAt written
	sprayCostAttr: number, -- last SprayCost written
	sprayCostStars: number, -- stars that SprayCost was computed for
	sprayCostAt: number, -- next SprayCost refresh (clock)
	respawnAtHQ: number?, -- clock time of a died-while-wanted bust (consumed by PlotService on respawn)
	busting: boolean,
	evadeLeft: number, -- seconds of evade timer left (v2: all stars clear at 0)
	lkp: Vector3?, -- last known position
	lkpShown: Vector3?,
	lastPassAt: number,
}

local states: { [Player]: State } = {}

-- Injectable dependencies so the logic can be unit-tested headlessly in Lune.
local systemCache: { [string]: any } = {}
local function loadSystem(name: string): any
	local cached = systemCache[name]
	if cached ~= nil then
		return cached
	end
	local inst = script.Parent and script.Parent:FindFirstChild(name)
	if inst and inst:IsA("ModuleScript") then
		local ok, mod = pcall(require, inst :: any)
		if ok then
			systemCache[name] = mod
			return mod
		end
		warn(("[WantedService] could not load %s: %s"):format(name, tostring(mod)))
	end
	return nil
end

local hooks = {
	isTest = false,
	clock = os.clock,
	system = loadSystem,
	fireClient = function(name: string, player: Player, ...: any)
		Net.fireClient(name, player, ...)
	end,
	fireAll = function(name: string, ...: any)
		Net.fireAll(name, ...)
	end,
	fireNear = function(name: string, position: Vector3, radius: number, ...: any)
		Net.fireNear(name, position, radius, ...)
	end,
	-- shared clock for client countdowns (WantedDecayAt)
	serverNow = function(): number
		local ok, t = pcall(function()
			return Workspace:GetServerTimeNow()
		end)
		return if ok and typeof(t) == "number" then t else os.clock()
	end,
}

-- Tests only: override clock / system loader / remote firing.
function WantedService._setHooks(overrides: { [string]: any })
	for k, v in overrides do
		(hooks :: any)[k] = v
	end
	table.clear(systemCache)
end

local function sys(name: string): any
	return hooks.system(name)
end

local function notify(player: Player, kind: string, text: string, duration: number?)
	pcall(hooks.fireClient, "Notify", player, kind, text, duration)
end

local function richEscape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- PURE HELPERS ------------------------------------------------------------------------------------------

-- Busted cash penalty: min(cash * 10%, income * 600s), never negative, whole dollars.
function WantedService._penalty(cash: number, incomePerSec: number): number
	cash = math.max(0, cash)
	incomePerSec = math.max(0, incomePerSec)
	local p = math.min(cash * Economy.BUSTED_CASH_PENALTY, incomePerSec * Economy.BUSTED_MAX_PENALTY_SECONDS)
	return math.max(0, math.floor(p))
end

-- Heat after the brand-new-player discount (halved, rounded down).
function WantedService._adjustHeat(amount: number, brandNew: boolean): number
	if amount <= 0 then
		return 0
	end
	if brandNew then
		return math.floor(amount / 2)
	end
	return math.floor(amount)
end

-- Seconds of not being seen before the next star drops, for the current star count.
function WantedService._decayDelay(stars: number): number
	local list = PoliceConfig.DECAY_DELAY
	return list[math.clamp(stars, 1, #list)] or 20
end

-- One evade step (gta_combat §9.4). Mutates st.evadeLeft and returns the new star count: unchanged, or 0 when the
-- timer ran out (every star clears at once). Seen resets the timer; outside the search area it runs 2x.
function WantedService._tickEvade(
	st: { stars: number, evadeLeft: number },
	dt: number,
	seen: boolean,
	inside: boolean
): number
	if st.stars <= 0 then
		return 0
	end
	st.evadeLeft = PoliceAim.evadeStep(st.evadeLeft, WantedService._decayDelay(st.stars), dt, seen, inside)
	if st.evadeLeft <= 0 then
		return 0
	end
	return st.stars
end

-- Spray Shop price (docs/integration/DECISIONS.md): stars * max(SPRAY_COST_PER_STAR, income/s * SPRAY_INCOME_SECONDS),
-- whole dollars, so a fresh paint job stays a real cost at every stage of the game.
function WantedService._sprayCost(stars: number, incomePerSec: number): number
	if stars ~= stars or stars <= 0 then
		return 0
	end
	local income = if incomePerSec == incomePerSec and incomePerSec > 0 then incomePerSec else 0
	local perStar = math.max(Economy.SPRAY_COST_PER_STAR, income * Economy.SPRAY_INCOME_SECONDS)
	return math.floor(math.floor(stars) * perStar)
end

-- "GOLD Phantom GT" style label for a car record (nil when the record has no known car id).
function WantedService._carLabel(car: any): string?
	if typeof(car) ~= "table" or typeof(car.carId) ~= "string" then
		return nil
	end
	local def = Cars.get(car.carId)
	local name = if def then def.name else car.carId
	local mut = Rarity.getMutation(if typeof(car.mutation) == "string" then car.mutation :: any else "None")
	if mut.label ~= "" then
		return mut.label .. " " .. name
	end
	return name
end

-- STATE -------------------------------------------------------------------------------------------------

local function newState(): State
	return {
		stars = 0,
		peak = 0,
		nextDecayAt = 0,
		graceUntil = 0,
		joinedAt = hooks.clock(),
		seen = false,
		hintedWanted = false,
		lastSprayAt = -math.huge,
		lastSprayFailNotify = -math.huge,
		lastSprayWatchNotify = -math.huge,
		pendingSpray = nil,
		decayAttr = 0,
		sprayCostAttr = 0,
		sprayCostStars = 0,
		sprayCostAt = -math.huge,
		respawnAtHQ = nil,
		busting = false,
		evadeLeft = 0,
		lkp = nil,
		lkpShown = nil,
		lastPassAt = hooks.clock(),
	}
end

local function getState(player: Player): State
	local st = states[player]
	if not st then
		st = newState()
		states[player] = st
	end
	return st
end

local function isBrandNew(player: Player, st: State): boolean
	if hooks.clock() - st.joinedAt > NEW_PLAYER_WINDOW then
		return false
	end
	local DataService = sys("DataService")
	if not DataService then
		return false
	end
	if typeof(DataService.getSessionInfo) == "function" then
		local okInfo, info = pcall(DataService.getSessionInfo, player)
		if okInfo and typeof(info) == "table" and typeof(info.isNew) == "boolean" then
			return info.isNew -- first-ever session
		end
	end
	if typeof(DataService.get) ~= "function" then
		return false
	end
	local ok, data = pcall(DataService.get, player)
	if not ok or typeof(data) ~= "table" then
		return false
	end
	return data.tutorialDone == false
end

local function progress(player: Player, stat: string, amount: number)
	local RewardsService = sys("RewardsService")
	if RewardsService and typeof(RewardsService.progress) == "function" then
		local ok, err = pcall(RewardsService.progress, player, stat, amount)
		if not ok then
			warn("[WantedService] RewardsService.progress failed: " .. tostring(err))
		end
	end
end

local function characterPosition(player: Player): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.CFrame.Position
	end
	return nil
end

-- Writes stars + attribute + fires Changed. Handles escape bookkeeping when dropping to 0.
local function applyStars(player: Player, st: State, newStars: number, reason: string)
	newStars = math.clamp(math.floor(newStars), 0, MAX_STARS)
	local old = st.stars
	if newStars == old then
		return
	end
	st.stars = newStars
	if newStars > st.peak then
		st.peak = newStars
	end
	if newStars > 0 and newStars > old then
		st.nextDecayAt = hooks.clock() + WantedService._decayDelay(newStars)
		st.evadeLeft = WantedService._decayDelay(newStars)
		if old == 0 then
			st.lkp = characterPosition(player)
		end
	end
	pcall(function()
		player:SetAttribute("Wanted", newStars)
		player:SetAttribute("SearchRadius", if newStars > 0 then PoliceAim.searchRadius(newStars) else 0)
	end)

	if newStars == 0 then
		local peak = st.peak
		st.peak = 0
		st.seen = false
		st.pendingSpray = nil
		st.decayAttr = 0
		st.sprayCostAttr = 0
		st.sprayCostStars = 0
		st.evadeLeft = 0
		st.lkp = nil
		st.lkpShown = nil
		pcall(function()
			player:SetAttribute("WantedSeen", false)
			player:SetAttribute("WantedDecayAt", 0)
			player:SetAttribute("SprayCost", 0)
			player:SetAttribute("LastKnownPos", nil)
		end)
		if old >= 1 and (reason == "decay" or reason == "spray") then
			progress(player, "escape", 1)
			if peak >= 3 then
				progress(player, "escape3", 1)
			end
			if reason == "decay" then
				notify(player, "success", "You evaded the police.", 4)
			end
			if peak >= 3 then
				pcall(
					hooks.fireAll,
					"EventFeed",
					("<b>%s</b> evaded a %d-star chase"):format(richEscape(player.DisplayName), peak)
				)
			end
		end
	elseif old == 0 and not st.hintedWanted and reason ~= "admin" then
		st.hintedWanted = true
		notify(player, "warning", "Police are after you. Break line of sight and get out of the search area.", 5)
	end

	WantedService.Changed:Fire(player, newStars, old)
end

-- PUBLIC API --------------------------------------------------------------------------------------------

function WantedService.getStars(player: Player): number
	local st = states[player]
	return if st then st.stars else 0
end

function WantedService.getPeak(player: Player): number
	local st = states[player]
	return if st then st.peak else 0
end

function WantedService.isInGrace(player: Player): boolean
	local st = states[player]
	return st ~= nil and hooks.clock() < st.graceUntil
end

-- Adds wanted stars for a crime. Any crime (even at max stars) refreshes the decay timer.
function WantedService.addHeat(player: Player, stars: number, reason: string?)
	if typeof(stars) ~= "number" or stars ~= stars then
		return
	end
	if player.Parent ~= Players and not hooks.isTest then
		return
	end
	local st = getState(player)
	local why = reason or "crime"
	local amount: number
	if why == "admin" then
		amount = math.floor(stars)
	else
		if hooks.clock() < st.graceUntil or st.busting then
			return
		end
		amount = WantedService._adjustHeat(stars, isBrandNew(player, st))
	end
	if amount <= 0 then
		return
	end
	local newStars = math.min(MAX_STARS, st.stars + amount)
	if st.stars > 0 then
		-- crime refreshes the timer even when the star count can't go higher
		st.nextDecayAt = math.max(st.nextDecayAt, hooks.clock() + WantedService._decayDelay(newStars))
		st.evadeLeft = WantedService._decayDelay(newStars)
		st.lkp = characterPosition(player) or st.lkp
	end
	applyStars(player, st, newStars, why)
end

-- Crime floors (CrimeRules.starsAfter decides `stars`): raises to `stars` when higher, never lowers. Any crime
-- refreshes the evade timer and pins the last known position to where it happened. Returns the star count.
function WantedService.raiseTo(player: Player, stars: number, reason: string?, pos: Vector3?): number
	if typeof(stars) ~= "number" or stars ~= stars then
		return WantedService.getStars(player)
	end
	if player.Parent ~= Players and not hooks.isTest then
		return 0
	end
	local st = getState(player)
	if hooks.clock() < st.graceUntil or st.busting then
		return st.stars
	end
	local target = math.clamp(math.floor(stars), 0, MAX_STARS)
	if st.stars > 0 or target > 0 then
		st.lkp = pos or characterPosition(player) or st.lkp
	end
	if target > st.stars then
		applyStars(player, st, target, reason or "crime")
	elseif st.stars > 0 then
		st.evadeLeft = WantedService._decayDelay(st.stars)
		st.nextDecayAt = hooks.clock() + WantedService._decayDelay(st.stars)
	end
	return st.stars
end

-- (center, radius) of the search area while wanted, nil when clean / unknown.
function WantedService.getSearchArea(player: Player): (Vector3?, number?)
	local st = states[player]
	if not st or st.stars <= 0 or not st.lkp then
		return nil, nil
	end
	return st.lkp, PoliceAim.searchRadius(st.stars)
end

-- Sets an exact star count (admin tools / products). 0 behaves like clear().
function WantedService.set(player: Player, stars: number, reason: string?)
	if typeof(stars) ~= "number" or stars ~= stars then
		return
	end
	local st = getState(player)
	stars = math.clamp(math.floor(stars), 0, MAX_STARS)
	if stars == 0 then
		WantedService.clear(player, reason or "admin")
		return
	end
	if stars > st.stars then
		st.nextDecayAt = hooks.clock() + WantedService._decayDelay(stars)
	end
	applyStars(player, st, stars, reason or "admin")
end

-- Returns true when stars were actually cleared (false: the player was not wanted, nothing changed).
function WantedService.clear(player: Player, reason: string?): boolean
	local st = states[player]
	if not st or st.stars == 0 then
		return false
	end
	applyStars(player, st, 0, reason or "clear")
	return true
end

local function getIncome(player: Player): number
	local GarageService = sys("GarageService")
	if GarageService and typeof(GarageService.incomePerSec) == "function" then
		local ok, v = pcall(GarageService.incomePerSec, player)
		if ok and typeof(v) == "number" and v == v then
			return v
		end
	end
	local attr = player:GetAttribute("IncomePerSec")
	return if typeof(attr) == "number" then attr else 0
end

local function takePenalty(player: Player, mult: number?): number
	local DataService = sys("DataService")
	if not DataService then
		return 0
	end
	local ok, data = pcall(DataService.get, player)
	if not ok or typeof(data) ~= "table" then
		return 0
	end
	local cash = if typeof(data.cash) == "number" then data.cash else 0
	local penalty = math.floor(WantedService._penalty(cash, getIncome(player)) * (mult or 1))
	if penalty > 0 then
		local paid = false
		if typeof(DataService.spendCash) == "function" then
			local ok2, res = pcall(DataService.spendCash, player, penalty)
			paid = ok2 and res == true
		end
		if not paid and typeof(DataService.addCash) == "function" then
			local ok3, res3 = pcall(DataService.addCash, player, -penalty, "busted")
			paid = ok3 and res3 ~= nil -- addCash returns the new balance, nil when not loaded
		end
		if not paid then
			penalty = 0
		end
	end
	if typeof(data.stats) == "table" then
		data.stats.busted = (tonumber(data.stats.busted) or 0) + 1
	end
	if typeof(DataService.markDirty) == "function" then
		pcall(DataService.markDirty, player)
	end
	return penalty
end

-- Ejects the busted player and deals with the car they were driving. Returns the impounded car's label (a failed
-- theft or a destroyed Loot car) for the Busted overlay, nil when nothing was taken.
local function handleCar(player: Player): string?
	local VehicleService = sys("VehicleService")
	if not VehicleService or typeof(VehicleService.getDriving) ~= "function" then
		return nil
	end
	local ok, car = pcall(VehicleService.getDriving, player)
	if not ok or not car then
		return nil
	end
	local label = WantedService._carLabel(car)
	if car.kind == "Stolen" then
		-- end the theft BEFORE the eject: ejecting first makes TheftService treat it as a dropped car
		-- ("Grab it back!" / "Get back in!") a moment before it fails (DECISIONS.md: fail, then eject)
		local TheftService = sys("TheftService")
		if TheftService and typeof(TheftService.fail) == "function" then
			local okF, err = pcall(TheftService.fail, car, "busted")
			if not okF then
				warn("[WantedService] TheftService.fail errored: " .. tostring(err))
			end
		end
		pcall(VehicleService.eject, car) -- usually a no-op by now (fail sends the car home)
		return label
	end
	pcall(VehicleService.eject, car)
	if car.kind == "Loot" then
		local okD, err = pcall(VehicleService.destroy, car, "busted")
		if not okD then
			warn("[WantedService] VehicleService.destroy errored: " .. tostring(err))
		end
		return label
	end
	return nil
end

-- Busted players are stunned until just after the teleport (no prompts / no hopping into another car).
local function stunForRelease(player: Player): boolean
	local CombatService = sys("CombatService")
	if CombatService and typeof(CombatService.stun) == "function" then
		-- forced: an arrest right after a taser stun must still freeze the suspect (stun immunity is for fights)
		local ok = pcall(CombatService.stun, player, RELEASE_DELAY + RELEASE_STUN_EXTRA, true)
		if ok then
			return false
		end
	end
	-- fallback: raw attribute (the clients freeze on it); the caller clears it after the release
	pcall(function()
		player:SetAttribute("Stunned", true)
	end)
	return true
end

local function releaseCharacter(player: Player)
	if player.Parent ~= Players then
		return
	end
	local char = player.Character
	if not char or not char.Parent then
		return
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local seatPart = humanoid.SeatPart
		if seatPart then
			local weld = seatPart:FindFirstChild("SeatWeld")
			if weld then
				weld:Destroy()
			end
		end
		humanoid.Sit = false
	end
	local jitter = Vector3.new(math.random(-40, 40) / 10, 0, math.random(-40, 40) / 10)
	local cf = MapLayout.bustedReleaseCFrame() + jitter
	char:PivotTo(cf)
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

-- BUSTED. Returns true if the bust happened. reason "died": the wanted player died (reset); the character is
-- already gone, so instead of the stun + teleport the next spawn goes to Police HQ (consumeRespawnAtHQ).
function WantedService.bust(player: Player, reason: string?): boolean
	local st = states[player]
	if not st or st.stars <= 0 or st.busting then
		return false
	end
	if hooks.clock() < st.graceUntil then
		return false
	end
	st.busting = true
	local died = reason == "died"
	local surrendered = reason == "surrender"
	local peak = math.max(st.peak, st.stars)

	local carLabel: string? = nil
	local ok, err = pcall(function()
		carLabel = handleCar(player)
	end)
	if not ok then
		warn("[WantedService] bust car handling failed: " .. tostring(err))
	end

	local lost = 0
	local okP, res = pcall(takePenalty, player, if surrendered then Economy.SURRENDER_PENALTY_MULT else 1)
	if okP and typeof(res) == "number" then
		lost = res
	end

	-- armor is confiscated (WeaponService takes half the reserve ammo on the Busted signal)
	local DamageService = sys("DamageService")
	if DamageService and typeof(DamageService.setArmor) == "function" then
		pcall(DamageService.setArmor, player, 0)
	end

	st.graceUntil = hooks.clock() + BUST_GRACE
	applyStars(player, st, 0, "busted")
	st.busting = false

	pcall(hooks.fireClient, "Busted", player, lost, carLabel)
	if died then
		st.respawnAtHQ = hooks.clock()
		notify(player, "warning", "Resetting doesn't lose the police. Busted.", 4)
	end
	if peak >= 3 then
		pcall(
			hooks.fireAll,
			"EventFeed",
			('<b>%s</b> was <font color="#5DB6E5">busted</font> at %d stars'):format(
				richEscape(player.DisplayName),
				peak
			)
		)
	end
	WantedService.Busted:Fire(player)

	if died then
		return true -- no body to stun or move; the respawn goes to Police HQ
	end
	local rawStun = stunForRelease(player)
	-- the cuffed suspect can't be shot while the arrest plays, and the release at Police HQ starts spawn protection
	if DamageService and typeof(DamageService.grantProtection) == "function" then
		pcall(DamageService.grantProtection, player, RELEASE_DELAY + RELEASE_STUN_EXTRA)
	end
	task.delay(RELEASE_DELAY, function()
		local okR, errR = pcall(releaseCharacter, player)
		if not okR then
			warn("[WantedService] release failed: " .. tostring(errR))
		end
		if rawStun then
			task.delay(RELEASE_STUN_EXTRA, function()
				pcall(function()
					player:SetAttribute("Stunned", false)
				end)
			end)
		end
	end)
	return true
end

-- True once after a died-while-wanted bust (within RESPAWN_AT_HQ_WINDOW): spawn this character at Police HQ.
function WantedService.consumeRespawnAtHQ(player: Player): boolean
	local st = states[player]
	local at = st and st.respawnAtHQ
	if not st or at == nil then
		return false
	end
	st.respawnAtHQ = nil
	return hooks.clock() - at <= RESPAWN_AT_HQ_WINDOW
end

-- WASTED while wanted (gta_combat §7.2): stars cleared, a stolen car's theft fails like a bust, no bail (the hospital
-- bill is DamageService's). Returns true when there were stars to clear.
function WantedService.clearOnWasted(player: Player): boolean
	local st = states[player]
	if not st or st.stars <= 0 or st.busting then
		return false
	end
	local VehicleService = sys("VehicleService")
	if VehicleService and typeof(VehicleService.getDriving) == "function" then
		local okD, car = pcall(VehicleService.getDriving, player)
		if okD and typeof(car) == "table" and car.kind == "Stolen" then
			local TheftService = sys("TheftService")
			if TheftService and typeof(TheftService.fail) == "function" then
				pcall(TheftService.fail, car, "wasted")
			end
		end
	end
	applyStars(player, st, 0, "wasted")
	return true
end

-- Surrender (hold H / pad D-down / mobile SURRENDER): at <= 2 stars with police within 40 studs, give yourself up:
-- busted at half the bail. Returns true when it happened.
function WantedService.surrender(player: Player): boolean
	local st = states[player]
	if not st or st.stars <= 0 or st.stars > SURRENDER_MAX_STARS or st.busting then
		return false
	end
	local pos = characterPosition(player)
	if not pos then
		return false
	end
	local PoliceService = sys("PoliceService")
	local near = false
	if PoliceService and typeof(PoliceService.copsNear) == "function" then
		local ok, res = pcall(PoliceService.copsNear, pos, SURRENDER_RANGE)
		near = ok and res == true
	end
	if not near then
		notify(player, "error", "There's nobody here to surrender to.", 2)
		return false
	end
	pcall(function()
		player:SetAttribute("Surrendering", true)
	end)
	local busted = WantedService.bust(player, "surrender")
	task.delay(RELEASE_DELAY + 0.5, function()
		pcall(function()
			player:SetAttribute("Surrendering", false)
		end)
	end)
	return busted
end

-- A wanted player's character died (Humanoid.Died; resets included). Resetting must not be a free escape to the
-- garage, so it counts as a bust. Dying inside your own garage (already a safe house) gains nothing: no bust.
-- With DamageService present it decides (gta_combat §7.1): a death with recent damage is WASTED, not BUSTED.
function WantedService._onDied(player: Player, position: Vector3?): boolean
	local st = states[player]
	if not st or st.stars <= 0 or st.busting then
		return false
	end
	local DamageService = sys("DamageService")
	if DamageService and typeof(DamageService.classifyDeath) == "function" then
		local okK, kind = pcall(DamageService.classifyDeath, player, position)
		if okK and kind == "wasted" then
			WantedService.clearOnWasted(player)
			return false
		end
	end
	if position then
		local plot = player:GetAttribute("PlotIndex")
		if typeof(plot) == "number" and MapLayout.plotAt(position) == plot then
			return false
		end
	end
	return WantedService.bust(player, "died")
end

-- SPRAY SHOP --------------------------------------------------------------------------------------------

local sprayRng = Random.new()

local function brightColor(): Color3
	return Color3.fromHSV(sprayRng:NextNumber(), sprayRng:NextNumber(0.6, 0.95), sprayRng:NextNumber(0.9, 1))
end

local carBuilderModule: any = nil -- false once known to be unavailable
local function getCarBuilder(): any
	if carBuilderModule == nil then
		carBuilderModule = false
		local folder = Shared:FindFirstChild("Vehicle")
		local m = folder and folder:FindFirstChild("CarBuilder")
		if m then
			local ok, mod = pcall(require, m :: any)
			if ok and typeof(mod) == "table" then
				carBuilderModule = mod
			end
		end
	end
	return carBuilderModule or nil
end

-- Repaints Paint="primary" parts with one bright random color, repairs health and tires. CarBuilder.repaint keeps a
-- mutation's look (a Gold / Diamond / Galaxy car stays gold / diamond / galaxy; only its base paint changes).
function WantedService._repaint(car: any): Color3
	local color = brightColor()
	local model = car.model
	if typeof(model) == "Instance" then
		local CarBuilder = getCarBuilder()
		local repainted = false
		if model:IsA("Model") and CarBuilder and typeof(CarBuilder.repaint) == "function" then
			repainted = pcall(CarBuilder.repaint, model, color)
		end
		if not repainted then
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") and d:GetAttribute("Paint") == "primary" then
					d.Color = color
				end
			end
		end
		model:SetAttribute("Health", VehicleConfig.MAX_HEALTH)
		if model:GetAttribute("TiresPopped") ~= nil then
			model:SetAttribute("TiresPopped", nil)
		end
		local chassis = car.chassis
		if typeof(chassis) == "Instance" and chassis:GetAttribute("TiresPopped") ~= nil then
			chassis:SetAttribute("TiresPopped", nil)
		end
	end
	car.health = VehicleConfig.MAX_HEALTH
	return color
end

local function isSeen(player: Player): boolean
	local PoliceService = sys("PoliceService")
	if PoliceService and typeof(PoliceService.isSeen) == "function" then
		local ok, res = pcall(PoliceService.isSeen, player)
		return ok and res == true
	end
	return false
end

-- Result of a spray attempt: "sprayed" | "seen" (cops watching; kept pending while the car waits in the booth)
-- | "broke" | "skip" (not wanted / cooldown / bad call).
local function onSprayAttempt(player: Player, car: any, seenKnown: boolean?): string
	-- SprayAttempt comes from VehicleService (server code), so only sanity-check the shape
	if player == nil or typeof(car) ~= "table" then
		return "skip"
	end
	local st = states[player]
	if not st or st.stars <= 0 or st.busting then
		return "skip"
	end
	local now = hooks.clock()
	if now - st.lastSprayAt < SPRAY_COOLDOWN then
		return "skip"
	end
	local seen = if seenKnown ~= nil then seenKnown else isSeen(player)
	if seen then
		-- no paint job with a cruiser on your bumper: lose them first (the booth sprays you once they do)
		st.pendingSpray = car
		if now - st.lastSprayWatchNotify > SPRAY_FAIL_NOTIFY_COOLDOWN then
			st.lastSprayWatchNotify = now
			notify(player, "warning", "The police can see you. Break line of sight and the booth will respray.", 3)
		end
		return "seen"
	end
	st.pendingSpray = nil
	local cost = WantedService._sprayCost(st.stars, getIncome(player))
	local DataService = sys("DataService")
	local paid = false
	if DataService and typeof(DataService.spendCash) == "function" then
		local ok, res = pcall(DataService.spendCash, player, cost)
		paid = ok and res == true
	end
	if not paid then
		if now - st.lastSprayFailNotify > SPRAY_FAIL_NOTIFY_COOLDOWN then
			st.lastSprayFailNotify = now
			notify(player, "error", ("A respray costs $%d."):format(cost), 3)
		end
		return "broke"
	end
	st.lastSprayAt = now
	WantedService.clear(player, "spray")
	pcall(WantedService._repaint, car)
	notify(player, "success", "New paint. The police lost track of the car.", 4)
	pcall(hooks.fireClient, "Sound", player, "Purchase")
	return "sprayed"
end

local sprayZoneCache: { { cframe: CFrame, size: Vector3 } }? = nil
local function inSprayZone(pos: Vector3): boolean
	local zones = sprayZoneCache
	if not zones then
		zones = MapLayout.sprayZones()
		sprayZoneCache = zones
	end
	for _, z in zones do
		if MapLayout.isInBox(z.cframe, z.size, pos) then
			return true
		end
	end
	return false
end

-- A car refused because cops were watching keeps waiting in the booth: spray it the moment nobody sees it.
-- Dropped when the player leaves the booth, leaves the car, or the car is flagged by VehicleService's watchdog.
local function retryPendingSpray(player: Player, st: State, seen: boolean)
	local car = st.pendingSpray
	if car == nil or seen then
		return
	end
	local VehicleService = sys("VehicleService")
	local okD: boolean, driving: any = false, nil
	if VehicleService and typeof(VehicleService.getDriving) == "function" then
		okD, driving = pcall(VehicleService.getDriving, player)
	end
	local chassis = car.chassis
	local valid = okD
		and driving == car
		and not car.destroyed
		and not car.wrecked
		and typeof(chassis) == "Instance"
		and chassis:IsA("BasePart")
		and inSprayZone(chassis.CFrame.Position)
	if valid and VehicleService and typeof(VehicleService.isTainted) == "function" then
		local okT, tainted = pcall(VehicleService.isTainted, car)
		valid = okT and tainted ~= true
	end
	if not valid then
		st.pendingSpray = nil
		return
	end
	if onSprayAttempt(player, car, false) ~= "seen" then
		st.pendingSpray = nil
	end
end

-- LIFECYCLE ---------------------------------------------------------------------------------------------

-- WantedDecayAt: server time at which the evade timer completes if nothing changes (0 while seen / not wanted).
-- Written only when it moves (a crime refreshes the timer, seen <-> hidden, crossing the search circle).
local function publishDecayAt(player: Player, st: State, inside: boolean)
	local value = 0
	if st.stars > 0 and not st.seen then
		local rate = if inside then 1 else PoliceConfig.EVADE_OUTSIDE_MULT
		value = hooks.serverNow() + math.max(0, st.evadeLeft) / rate
	end
	local changed = if value == 0 or st.decayAttr == 0
		then value ~= st.decayAttr
		else math.abs(value - st.decayAttr) > DECAY_ATTR_EPSILON
	if changed then
		st.decayAttr = value
		pcall(function()
			player:SetAttribute("WantedDecayAt", value)
		end)
	end
end

-- LastKnownPos: the search circle's centre (minimap search area); written when it moves more than LKP_EPSILON.
local function publishLkp(player: Player, st: State)
	local lkp = st.lkp
	if lkp and (st.lkpShown == nil or (lkp - (st.lkpShown :: Vector3)).Magnitude > LKP_EPSILON) then
		st.lkpShown = lkp
		pcall(function()
			player:SetAttribute("LastKnownPos", lkp)
		end)
	end
end

-- SprayCost: the current Spray Shop price for the HUD / spray waypoint (it follows income, so it is refreshed about
-- once a second while wanted, and immediately when the star count changes). Written only when the value changes.
local function publishSprayCost(player: Player, st: State, now: number)
	if st.stars == st.sprayCostStars and now < st.sprayCostAt then
		return
	end
	st.sprayCostAt = now + SPRAY_COST_REFRESH
	st.sprayCostStars = st.stars
	local cost = WantedService._sprayCost(st.stars, getIncome(player))
	if cost ~= st.sprayCostAttr then
		st.sprayCostAttr = cost
		pcall(function()
			player:SetAttribute("SprayCost", cost)
		end)
	end
end

-- One pass of the evade loop (public for tests via _decayPass).
function WantedService._decayPass()
	local now = hooks.clock()
	for player, st in states do
		local dt = math.clamp(now - st.lastPassAt, 0, 1)
		st.lastPassAt = now
		if st.stars > 0 and not st.busting then
			local seen = isSeen(player)
			if seen ~= st.seen then
				st.seen = seen
				pcall(function()
					player:SetAttribute("WantedSeen", seen)
				end)
			end
			local pos = characterPosition(player)
			if seen and pos then
				st.lkp = pos
			end
			local inside = true
			local lkp = st.lkp
			if pos and lkp then
				local dx, dz = pos.X - lkp.X, pos.Z - lkp.Z
				inside = math.sqrt(dx * dx + dz * dz) <= PoliceAim.searchRadius(st.stars)
			end
			local newStars = WantedService._tickEvade(st, dt, seen, inside)
			if newStars ~= st.stars then
				applyStars(player, st, newStars, "decay")
			end
			if st.pendingSpray ~= nil and st.stars > 0 then
				local ok, err = pcall(retryPendingSpray, player, st, seen)
				if not ok then
					st.pendingSpray = nil
					warn("[WantedService] pending spray failed: " .. tostring(err))
				end
			end
			publishDecayAt(player, st, inside)
			if st.stars > 0 then
				publishLkp(player, st)
				publishSprayCost(player, st, now)
			end
		end
	end
end

local function onPlayerAdded(player: Player)
	local st = getState(player)
	pcall(function()
		player:SetAttribute("Wanted", st.stars)
		player:SetAttribute("WantedSeen", false)
		player:SetAttribute("WantedDecayAt", 0)
		player:SetAttribute("SprayCost", 0)
		player:SetAttribute("SearchRadius", 0)
		player:SetAttribute("Surrendering", false)
	end)
end

function WantedService._addPlayer(player: Player)
	onPlayerAdded(player)
end

function WantedService._removePlayer(player: Player)
	states[player] = nil
end

function WantedService.init()
	local VehicleService = sys("VehicleService")
	if VehicleService and VehicleService.SprayAttempt then
		VehicleService.SprayAttempt:Connect(function(player: Player, car: any)
			local ok, err = pcall(onSprayAttempt, player, car)
			if not ok then
				warn("[WantedService] spray failed: " .. tostring(err))
			end
		end)
	else
		warn("[WantedService] VehicleService.SprayAttempt unavailable; Spray Shops won't clear wanted levels")
	end
	local okNet, errNet = pcall(Net.on, "Surrender", function(player: Player)
		WantedService.surrender(player)
	end, 1)
	if not okNet and not hooks.isTest then
		warn("[WantedService] Surrender remote unavailable: " .. tostring(errNet))
	end
end

-- Deaths: DamageService's Humanoid.Died handler classifies (gta_combat §7.1) and calls bust(player, "died") or
-- clearOnWasted(player); WantedService no longer hooks Died itself (one owner, no ordering races).
function WantedService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	while true do
		task.wait(DECAY_INTERVAL)
		local ok, err = pcall(WantedService._decayPass)
		if not ok then
			warn("[WantedService] evade pass failed: " .. tostring(err))
		end
	end
end

return WantedService
