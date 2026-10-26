--!strict
-- RebirthService (SPEC §6): trade everything for a permanent +50% income (and luck) multiplier.
--
-- Rebirth remote / rebirth(player): requires cash >= EconomyMath.rebirthCost(rebirths) and every garage car parked
-- (none out driving / being stolen). Resets cash to STARTING_CASH, the garage to just the single best car (by income)
-- and slotsUnlocked to START_SLOTS. Upgrades, tools, discovered cars, stats, streaks and codes are kept.
-- Robux-bought Exclusive cars are never taken away: they stay parked (or go to data.exclusives, which
-- MonetizationService delivers as soon as a slot frees up). Announce + confetti for the whole server.
-- PlotService reads data.rebirths for the +10s/rebirth lock bonus; GarageService reads it for the income multiplier.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local Net = require(Shared.Net)
local Rarity = require(Shared.Config.Rarity)
local Types = require(Shared.Types)

type SlotRecord = Types.SlotRecord

local RebirthService = {}

-- Lazy system access (no require cycles; tolerant of a missing/broken system) -------------------------------------
local systemCache: { [string]: any } = {}
local function sys(name: string): any
	local cached = systemCache[name]
	if cached then
		return cached
	end
	local parent = script.Parent
	local inst = parent and parent:FindFirstChild(name)
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if ok and typeof(mod) == "table" then
		systemCache[name] = mod
		return mod
	end
	warn(("[RebirthService] could not load %s: %s"):format(name, tostring(mod)))
	return nil
end

-- Test seam: replace a system module seen by sys(). Never used at runtime.
function RebirthService._inject(name: string, mod: any)
	systemCache[name] = mod
end

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
---------------------------------------------------------------------------------------------------------------------

-- Can a player with `cash` and `rebirths` rebirth? Returns (ok, cost).
function RebirthService._canAfford(cash: number, rebirths: number): (boolean, number)
	local cost = EconomyMath.rebirthCost(rebirths)
	return cash >= cost, cost
end

-- Income multiplier from rebirths alone (for previews).
function RebirthService._rebirthMultiplier(rebirths: number): number
	return 1 + math.max(0, rebirths) * Economy.REBIRTH_INCOME_BONUS
end

-- "x2.5", "x3" (rebirth income multiplier label).
function RebirthService._formatMultiplier(rebirths: number): string
	local s = string.format("%.1f", RebirthService._rebirthMultiplier(rebirths))
	s = s:gsub("%.0$", "")
	return "x" .. s
end

local function isExclusive(carId: string): boolean
	local def = Cars.get(carId)
	return def ~= nil and def.rarity == "Exclusive"
end

-- Which cars survive a rebirth, in slot order: the best car by income first (ties -> lowest slot), then every
-- other Exclusive (Robux) car. Unknown car ids are dropped.
function RebirthService._plan(garage: { [string]: SlotRecord }): { SlotRecord }
	local entries: { { slot: number, rec: SlotRecord, income: number } } = {}
	for key, rec in garage do
		local slot = tonumber(key)
		if slot and typeof(rec) == "table" and Cars.get(rec.carId) then
			table.insert(entries, { slot = slot, rec = rec, income = EconomyMath.carIncome(rec.carId, rec.mutation) })
		end
	end
	table.sort(entries, function(a, b)
		return a.slot < b.slot
	end)
	local bestIdx: number? = nil
	for i, e in entries do
		if bestIdx == nil or e.income > entries[bestIdx].income then
			bestIdx = i
		end
	end
	local kept: { SlotRecord } = {}
	if bestIdx then
		local best = entries[bestIdx].rec
		table.insert(kept, { carId = best.carId, mutation = best.mutation, uncollected = 0 })
	end
	for i, e in entries do
		if i ~= bestIdx and isExclusive(e.rec.carId) then
			table.insert(kept, { carId = e.rec.carId, mutation = e.rec.mutation, uncollected = 0 })
		end
	end
	if #kept == 0 then
		table.insert(kept, { carId = Economy.STARTER_CAR, mutation = "None", uncollected = 0 })
	end
	return kept
end

-- Adds an owed exclusive car using MonetizationService's key format ("<carId>" or "<carId>#<n>").
function RebirthService._addPendingExclusive(data: any, carId: string)
	data.exclusives = data.exclusives or {}
	local key = carId
	local n = 1
	while data.exclusives[key] do
		n += 1
		key = carId .. "#" .. n
	end
	data.exclusives[key] = true
end

-- Pure data reset (used directly when GarageService is unavailable, and by tests). Mutates `data`:
-- rebirths+1, cash = STARTING_CASH, slotsUnlocked = START_SLOTS, garage = kept cars in slots 1..capacity; kept
-- exclusives beyond capacity become pending exclusives. Returns the kept list.
function RebirthService._applyReset(data: any, capacity: number?): { SlotRecord }
	local kept = RebirthService._plan(data.garage or {})
	local cap = math.max(1, capacity or Economy.START_SLOTS)
	data.rebirths = (data.rebirths or 0) + 1
	data.cash = Economy.STARTING_CASH
	data.slotsUnlocked = Economy.START_SLOTS
	local garage: { [string]: SlotRecord } = {}
	for i, rec in kept do
		if i <= cap then
			garage[tostring(i)] = rec
		else
			RebirthService._addPendingExclusive(data, rec.carId)
		end
	end
	data.garage = garage
	return kept
end

---------------------------------------------------------------------------------------------------------------------
-- Runtime
---------------------------------------------------------------------------------------------------------------------

local busy: { [Player]: boolean } = {}

local function notify(player: Player, kind: string, text: string, duration: number?)
	Net.fireClient("Notify", player, kind, text, duration)
end

local function richEscape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
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

-- Why the player can't rebirth right now (nil = they can). Does not check cash.
local function blockedReason(player: Player, data: any): string?
	local Garage = sys("GarageService")
	if Garage and typeof(Garage.getSlotState) == "function" then
		for key in data.garage do
			local slot = tonumber(key)
			if slot then
				local ok, state = pcall(Garage.getSlotState, player, slot)
				if ok and state == "BeingStolen" then
					return "Your garage is being robbed! Stop the thief first 🚨"
				elseif ok and state == "Driving" then
					return "Park your car back in your garage first 🅿️"
				end
			end
		end
	end
	return nil
end

-- Extra: (canRebirth, cost, reason?) for UI/admin.
function RebirthService.canRebirth(player: Player): (boolean, number, string?)
	local DataService = sys("DataService")
	local data = DataService and DataService.isLoaded(player) and DataService.get(player)
	if not data then
		return false, 0, "loading"
	end
	local afford, cost = RebirthService._canAfford(data.cash, data.rebirths)
	if not afford then
		return false, cost, "Need " .. Format.cash(cost) .. " to rebirth"
	end
	local reason = blockedReason(player, data)
	return reason == nil, cost, reason
end

local function celebrate(player: Player, rebirths: number)
	local multText = RebirthService._formatMultiplier(rebirths)
	Net.fireAll(
		"Announce",
		`🌟 {player.DisplayName} REBIRTHED! (x{rebirths})`,
		`Now earning {multText} cash forever`,
		Color3.fromRGB(255, 205, 50),
		"CashBig"
	)
	Net.fireAll("EventFeed", `🌟 <b>{richEscape(player.DisplayName)}</b> rebirthed! <b>(x{rebirths})</b>`)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local pos = root.Position + Vector3.new(0, 3, 0)
		Net.fireNear("Effect", pos, 300, "Confetti", { position = pos, rarity = "Legendary" })
		Net.fireNear("Effect", pos, 300, "CashBurst", { position = pos })
	end
end

-- Performs a rebirth. Returns (ok, reason?). Public so AdminService can call it after topping up cash.
function RebirthService.rebirth(player: Player): (boolean, string?)
	if busy[player] then
		return false, "busy"
	end
	local DataService = sys("DataService")
	if not DataService or not DataService.isLoaded(player) then
		return false, "loading"
	end
	local data = DataService.get(player)
	if not data then
		return false, "loading"
	end
	local afford, cost = RebirthService._canAfford(data.cash, data.rebirths)
	if not afford then
		notify(player, "error", `You need {Format.cash(cost)} to rebirth!`)
		return false, "cash"
	end
	local reason = blockedReason(player, data)
	if reason then
		notify(player, "error", reason)
		return false, "blocked"
	end

	busy[player] = true
	local ok, err = pcall(function()
		local Garage = sys("GarageService")
		local kept = RebirthService._plan(data.garage)
		local canUseGarage = Garage
			and typeof(Garage.removeSlot) == "function"
			and typeof(Garage.storeCar) == "function"
		if canUseGarage then
			-- through GarageService so displays/pads/income stay in sync (no yields between steps)
			for key in table.clone(data.garage) do
				local slot = tonumber(key)
				if slot then
					Garage.removeSlot(player, slot)
				end
			end
			for key in table.clone(data.garage) do
				data.garage[key] = nil -- anything removeSlot could not parse
			end
			data.rebirths += 1
			data.cash = Economy.STARTING_CASH
			data.slotsUnlocked = Economy.START_SLOTS
			for _, rec in kept do
				local stored = Garage.storeCar(player, rec.carId, rec.mutation)
				if not stored then
					RebirthService._addPendingExclusive(data, rec.carId)
				end
			end
			if typeof(Garage.refresh) == "function" then
				Garage.refresh(player)
			end
		else
			RebirthService._applyReset(data, Economy.START_SLOTS)
		end
		DataService.markDirty(player)
		player:SetAttribute("Rebirths", data.rebirths)
		local best = kept[1]
		local keptName = carLabel(best.carId, best.mutation)
		local multText = RebirthService._formatMultiplier(data.rebirths)
		notify(player, "success", `🌟 REBIRTH x{data.rebirths}! You kept your {keptName}. Income {multText}!`, 6)
		Net.fireClient("Sound", player, "CashBig")
		celebrate(player, data.rebirths)
	end)
	busy[player] = nil
	if not ok then
		warn("[RebirthService] rebirth failed for " .. player.Name .. ": " .. tostring(err))
		return false, "error"
	end
	if typeof(DataService.saveNow) == "function" then
		task.spawn(DataService.saveNow, player)
	end
	return true, nil
end

function RebirthService.init()
	Net.on("Rebirth", function(player: Player)
		RebirthService.rebirth(player)
	end, 0.5)
end

function RebirthService.start()
	Players.PlayerRemoving:Connect(function(player: Player)
		busy[player] = nil
	end)
end

return RebirthService
