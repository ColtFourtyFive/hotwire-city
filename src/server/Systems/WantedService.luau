--!strict
-- WantedService: per-player wanted stars (0..5), heat, decay, Spray Shop clears and BUSTED.
--
-- Public API (docs/SPEC.md §6):
--   addHeat(player, stars, reason)      raise wanted level (ignored during post-bust grace; halved for brand-new players)
--   getStars(player): number
--   clear(player, reason)               drop to 0 stars ("decay"/"spray" count as an escape for contracts)
--   bust(player): boolean               BUSTED: cash penalty, car handling, release at Police HQ
--   Changed: Signal(player, stars, old)
--   Busted: Signal(player)
-- Extra helpers: set(player, stars, reason), isInGrace(player), getPeak(player)
-- Pure helpers (tested in tests/spec/police.spec.luau): _penalty, _adjustHeat, _decayDelay, _tickDecay
--
-- Player attributes written here: Wanted (0..5), WantedSeen (bool: a cop currently sees you; HUD can flash the
-- stars GTA-style while you are hidden and the decay timer is running).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local MapLayout = require(Shared.Util.MapLayout)
local PoliceConfig = require(Shared.Config.Police)
local Economy = require(Shared.Config.Economy)
local VehicleConfig = require(Shared.Config.Vehicle)

local WantedService = {}

WantedService.Changed = Signal.new() -- (player, stars, old)
WantedService.Busted = Signal.new() -- (player)

local MAX_STARS = PoliceConfig.MAX_STARS
local BUST_GRACE = 8 -- seconds after a bust during which no heat can be added
local NEW_PLAYER_WINDOW = 30 -- brand-new players get halved heat for this long after joining
local DECAY_INTERVAL = 0.25
local RELEASE_DELAY = 1.1 -- seconds between the BUSTED stamp and the teleport to Police HQ
local SPRAY_COOLDOWN = 1.5
local SPRAY_FAIL_NOTIFY_COOLDOWN = 4

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
		pcall(function()
			player:SetAttribute("WantedSeen", false)
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

function WantedService.clear(player: Player, reason: string?)
	local st = states[player]
	if not st or st.stars == 0 then
		return
	end
	applyStars(player, st, 0, reason or "clear")
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

-- Ejects the busted player and deals with the car they were driving.
local function handleCar(player: Player)
	local VehicleService = sys("VehicleService")
	if not VehicleService or typeof(VehicleService.getDriving) ~= "function" then
		return
	end
	local ok, car = pcall(VehicleService.getDriving, player)
	if not ok or not car then
		return
	end
	pcall(VehicleService.eject, car)
	if car.kind == "Stolen" then
		local TheftService = sys("TheftService")
		if TheftService and typeof(TheftService.fail) == "function" then
			local okF, err = pcall(TheftService.fail, car, "busted")
			if not okF then
				warn("[WantedService] TheftService.fail errored: " .. tostring(err))
			end
		end
	elseif car.kind == "Loot" then
		local okD, err = pcall(VehicleService.destroy, car, "busted")
		if not okD then
			warn("[WantedService] VehicleService.destroy errored: " .. tostring(err))
		end
	end
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

-- BUSTED. Returns true if the bust happened.
function WantedService.bust(player: Player): boolean
	local st = states[player]
	if not st or st.stars <= 0 or st.busting then
		return false
	end
	if hooks.clock() < st.graceUntil then
		return false
	end
	st.busting = true
	local peak = math.max(st.peak, st.stars)

	local ok, err = pcall(function()
		handleCar(player)
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

	pcall(hooks.fireClient, "Busted", player, lost)
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

	task.delay(RELEASE_DELAY, function()
		local okR, errR = pcall(releaseCharacter, player)
		if not okR then
			warn("[WantedService] release failed: " .. tostring(errR))
		end
	end)
	return true
end

-- SPRAY SHOP --------------------------------------------------------------------------------------------

local sprayRng = Random.new()

local function brightColor(): Color3
	return Color3.fromHSV(sprayRng:NextNumber(), sprayRng:NextNumber(0.6, 0.95), sprayRng:NextNumber(0.9, 1))
end

-- Repaints Paint="primary" parts with one bright random color, repairs health and tires.
function WantedService._repaint(car: any): Color3
	local color = brightColor()
	local model = car.model
	if typeof(model) == "Instance" then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d:GetAttribute("Paint") == "primary" then
				d.Color = color
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

local function onSprayAttempt(player: Player, car: any)
	-- SprayAttempt comes from VehicleService (server code), so only sanity-check the shape
	if player == nil or typeof(car) ~= "table" then
		return
	end
	local st = states[player]
	if not st or st.stars <= 0 or st.busting then
		return
	end
	local now = hooks.clock()
	if now - st.lastSprayAt < SPRAY_COOLDOWN then
		return
	end
	local cost = Economy.SPRAY_COST_PER_STAR * st.stars
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
		return
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
end

-- LIFECYCLE ---------------------------------------------------------------------------------------------

local function isSeen(player: Player): boolean
	local PoliceService = sys("PoliceService")
	if PoliceService and typeof(PoliceService.isSeen) == "function" then
		local ok, res = pcall(PoliceService.isSeen, player)
		return ok and res == true
	end
	return false
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
		end
	end
end

local function onPlayerAdded(player: Player)
	local st = getState(player)
	pcall(function()
		player:SetAttribute("Wanted", st.stars)
		player:SetAttribute("WantedSeen", false)
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
end

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
			warn("[WantedService] decay pass failed: " .. tostring(err))
		end
	end
end

return WantedService
