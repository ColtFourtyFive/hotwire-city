--!strict
-- WantedService: per-player wanted stars (0..5), heat, decay, Spray Shop clears and BUSTED.
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
-- Pure helpers (tested in tests/spec/police.spec.luau): _penalty, _adjustHeat, _decayDelay, _tickDecay, _sprayCost
--
-- Remotes: Busted(lostCash: number, carLabel: string?) carLabel = the impounded car (failed theft / loot) if any.
-- Player attributes written here: Wanted (0..5), WantedSeen (bool: a cop currently sees you; HUD can flash the
-- stars GTA-style while you are hidden and the decay timer is running), WantedDecayAt (number: server time
-- (Workspace:GetServerTimeNow) when the next star drops if you stay hidden; 0 while seen / not wanted), SprayCost
-- (number: what a Spray Shop charges right now, refreshed ~1 Hz while wanted since it follows income; 0 when clean).
--
-- Spray Shops only work while no cop sees you: a seen car waiting in the booth is sprayed as soon as they lose you.
-- Dying while wanted (e.g. resetting to get home) is a bust, unless it happens inside your own garage.

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

local WantedService = {}

WantedService.Changed = Signal.new() -- (player, stars, old)
WantedService.Busted = Signal.new() -- (player)

local MAX_STARS = PoliceConfig.MAX_STARS
local BUST_GRACE = 8 -- seconds after a bust during which no heat can be added
local NEW_PLAYER_WINDOW = 30 -- brand-new players get halved heat for this long after joining
local DECAY_INTERVAL = 0.25
local RELEASE_DELAY = 1.1 -- seconds between the BUSTED stamp and the teleport to Police HQ
local RELEASE_STUN_EXTRA = 0.3 -- busted players stay stunned a moment past the teleport (no hopping into cars)
local RESPAWN_AT_HQ_WINDOW = 60 -- a died-while-wanted bust sends the next spawn within this long to Police HQ
local SPRAY_COOLDOWN = 1.5
local SPRAY_FAIL_NOTIFY_COOLDOWN = 4
local DECAY_ATTR_EPSILON = 0.5 -- rewrite WantedDecayAt only when it moves by more than this (seconds)
local SPRAY_COST_REFRESH = 1 -- seconds between SprayCost attribute refreshes while wanted

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

local function starString(n: number): string
	return string.rep("★", math.clamp(n, 0, MAX_STARS))
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

-- One decay step. Mutates st.nextDecayAt and returns the new star count.
-- Being seen resets the timer; otherwise one star drops when the timer runs out, then one every DECAY_STEP.
function WantedService._tickDecay(st: { stars: number, nextDecayAt: number }, now: number, seen: boolean): number
	if st.stars <= 0 then
		return 0
	end
	if seen then
		st.nextDecayAt = now + WantedService._decayDelay(st.stars)
		return st.stars
	end
	if now >= st.nextDecayAt then
		local newStars = st.stars - 1
		st.nextDecayAt = now + PoliceConfig.DECAY_STEP
		return newStars
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
	end
	pcall(function()
		player:SetAttribute("Wanted", newStars)
	end)

	if newStars == 0 then
		local peak = st.peak
		st.peak = 0
		st.seen = false
		st.pendingSpray = nil
		st.decayAttr = 0
		st.sprayCostAttr = 0
		st.sprayCostStars = 0
		pcall(function()
			player:SetAttribute("WantedSeen", false)
			player:SetAttribute("WantedDecayAt", 0)
			player:SetAttribute("SprayCost", 0)
		end)
		if old >= 1 and (reason == "decay" or reason == "spray") then
			progress(player, "escape", 1)
			if peak >= 3 then
				progress(player, "escape3", 1)
			end
			if reason == "decay" then
				notify(player, "success", "😎 ESCAPED! You lost the cops.", 4)
				pcall(hooks.fireClient, "Sound", player, "Whoosh")
				local pos = characterPosition(player)
				if pos then
					pcall(hooks.fireNear, "Effect", pos, 300, "Confetti", { position = pos })
				end
			end
			if peak >= 3 then
				pcall(
					hooks.fireAll,
					"EventFeed",
					('😎 <b>%s</b> escaped a <font color="#FFD23F">%s</font> chase!'):format(
						richEscape(player.DisplayName),
						starString(peak)
					)
				)
			end
		end
	elseif old == 0 and not st.hintedWanted and reason ~= "admin" then
		st.hintedWanted = true
		notify(player, "warning", "🚨 Cops are on you! Break line of sight or hit a 🎨 Spray Shop.", 5)
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
	end
	applyStars(player, st, newStars, why)
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

local function takePenalty(player: Player): number
	local DataService = sys("DataService")
	if not DataService then
		return 0
	end
	local ok, data = pcall(DataService.get, player)
	if not ok or typeof(data) ~= "table" then
		return 0
	end
	local cash = if typeof(data.cash) == "number" then data.cash else 0
	local penalty = WantedService._penalty(cash, getIncome(player))
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
		local ok = pcall(CombatService.stun, player, RELEASE_DELAY + RELEASE_STUN_EXTRA)
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
	local peak = math.max(st.peak, st.stars)

	local carLabel: string? = nil
	local ok, err = pcall(function()
		carLabel = handleCar(player)
	end)
	if not ok then
		warn("[WantedService] bust car handling failed: " .. tostring(err))
	end

	local lost = 0
	local okP, res = pcall(takePenalty, player)
	if okP and typeof(res) == "number" then
		lost = res
	end

	st.graceUntil = hooks.clock() + BUST_GRACE
	applyStars(player, st, 0, "busted")
	st.busting = false

	pcall(hooks.fireClient, "Busted", player, lost, carLabel)
	if died then
		st.respawnAtHQ = hooks.clock()
		notify(player, "warning", "🚔 Bailing out doesn't lose the cops - you got BUSTED!", 4)
	end
	if peak >= 3 then
		pcall(
			hooks.fireAll,
			"EventFeed",
			('🚔 <b>%s</b> got <font color="#FF3B3B">BUSTED</font> at %s!'):format(
				richEscape(player.DisplayName),
				starString(peak)
			)
		)
	end
	WantedService.Busted:Fire(player)

	if died then
		return true -- no body to stun or move; the respawn goes to Police HQ
	end
	local rawStun = stunForRelease(player)
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

-- A wanted player's character died (Humanoid.Died; resets included). Resetting must not be a free escape to the
-- garage, so it counts as a bust. Dying inside your own garage (already a safe house) gains nothing: no bust.
function WantedService._onDied(player: Player, position: Vector3?): boolean
	local st = states[player]
	if not st or st.stars <= 0 or st.busting then
		return false
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
			notify(player, "warning", "🚔 They're watching! Break line of sight and the booth sprays you.", 3)
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
			notify(player, "error", ("🎨 A fresh paint job costs $%d. Get some cash first!"):format(cost), 3)
		end
		return "broke"
	end
	st.lastSprayAt = now
	WantedService.clear(player, "spray")
	pcall(WantedService._repaint, car)
	notify(player, "success", "🎨 Fresh paint! Cops lost you.", 4)
	pcall(hooks.fireClient, "Sound", player, "Purchase")
	local chassis = car.chassis
	if typeof(chassis) == "Instance" and chassis:IsA("BasePart") then
		local pos = chassis.CFrame.Position
		pcall(hooks.fireNear, "Effect", pos, 400, "Confetti", { position = pos })
	end
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

-- WantedDecayAt: server time of the next star loss while hidden (0 while seen / not wanted). Written only when it
-- moves (a star drops, a crime refreshes the timer, seen <-> hidden), not every pass.
local function publishDecayAt(player: Player, st: State, now: number)
	local value = 0
	if st.stars > 0 and not st.seen then
		value = hooks.serverNow() + math.max(0, st.nextDecayAt - now)
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

-- One pass of the decay loop (public for tests via _decayPass).
function WantedService._decayPass()
	local now = hooks.clock()
	for player, st in states do
		if st.stars > 0 and not st.busting then
			local seen = isSeen(player)
			if seen ~= st.seen then
				st.seen = seen
				pcall(function()
					player:SetAttribute("WantedSeen", seen)
				end)
			end
			local newStars = WantedService._tickDecay(st, now, seen)
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
			publishDecayAt(player, st, now)
			if st.stars > 0 then
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
	end)
end

function WantedService._addPlayer(player: Player)
	onPlayerAdded(player)
end

function WantedService._removePlayer(player: Player)
	states[player] = nil
end

-- Humanoid.Died hook per character (one live connection per player; the old one goes with the old character).
local diedConns: { [Player]: RBXScriptConnection } = {}
local function watchCharacter(player: Player, character: Model)
	local old = diedConns[player]
	if old then
		old:Disconnect()
		diedConns[player] = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") or player.Character ~= character then
		return
	end
	diedConns[player] = humanoid.Died:Connect(function()
		local root = character:FindFirstChild("HumanoidRootPart")
		local pos = if root and root:IsA("BasePart") then root.Position else nil
		local ok, err = pcall(WantedService._onDied, player, pos)
		if not ok then
			warn("[WantedService] died-while-wanted bust failed: " .. tostring(err))
		end
	end)
end

local function onRealPlayerAdded(player: Player)
	onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character: Model)
		watchCharacter(player, character)
	end)
	if player.Character then
		task.spawn(watchCharacter, player, player.Character)
	end
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
end

function WantedService.start()
	Players.PlayerAdded:Connect(onRealPlayerAdded)
	for _, p in Players:GetPlayers() do
		onRealPlayerAdded(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
		local conn = diedConns[player]
		if conn then
			conn:Disconnect()
			diedConns[player] = nil
		end
	end)
	while true do
		task.wait(DECAY_INTERVAL)
		local ok, err = pcall(WantedService._decayPass)
		if not ok then
			warn("[WantedService] decay pass failed: " .. tostring(err))
		end
	end
end

return WantedService
