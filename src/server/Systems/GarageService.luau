--!strict
-- GarageService: the money loop. Garage slots (persisted in data.garage), income ticks, display cars with
-- Drive/Sell/Steal prompts, the Collect pad, slot unlocks, and the delivery / chop / returned-home handlers
-- for VehicleService zone signals.
--
-- Runtime slot states (never persisted): "Parked" (on display, earning), "Driving" (owner took it out),
-- "BeingStolen" (TheftService has it). Only Parked slots accrue income.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local MapConfig = require(Shared.Config.Map)
local MapLayout = require(Shared.Util.MapLayout)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local Rarity = require(Shared.Config.Rarity)
local Types = require(Shared.Types)

type SlotRecord = Types.SlotRecord
type SlotState = Types.SlotState
type SlotSnapshot = Types.SlotSnapshot

local G = MapConfig.Garage

local GarageService = {}

GarageService.SNAPSHOT_EVERY = 3 -- income ticks between snapshot pushes caused only by income
GarageService.COLLECT_DEBOUNCE = 0.75
GarageService.PROMPT_DISTANCE = 12
GarageService.DRIVE_MAX_DISTANCE = 40 -- DriveCar remote: player must be inside their garage or this close to the slot

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
	if ok and mod then
		systemCache[name] = mod
		return mod
	end
	warn(("[GarageService] could not load %s: %s"):format(name, tostring(mod)))
	return nil
end

local carBuilder: any = nil
local function getCarBuilder(): any
	if carBuilder then
		return carBuilder
	end
	local vehicleFolder = Shared:FindFirstChild("Vehicle")
	local mod = vehicleFolder and vehicleFolder:FindFirstChild("CarBuilder")
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod)
	if ok then
		carBuilder = res
		return res
	end
	warn("[GarageService] CarBuilder failed to load: " .. tostring(res))
	return nil
end

-- Test seam: replace (or clear with nil) a system module seen by sys(). Never used at runtime.
function GarageService._inject(name: string, mod: any)
	systemCache[name] = mod
end

-- Call fn(...) safely, returning its first result or `default`.
local function try(fn: any, default: any, ...: any): any
	if typeof(fn) ~= "function" then
		return default
	end
	local ok, res = pcall(fn, ...)
	if ok and res ~= nil then
		return res
	end
	return default
end

-- Pure helpers (exposed for tests) ---------------------------------------------------------------------------------

-- Usable slot count: purchased slots (capped at MAX_SLOTS) + pass slots, capped by the physical pads.
function GarageService._capacity(slotsUnlocked: number, hasSlotsPass: boolean): number
	local bought = math.clamp(slotsUnlocked, 0, Economy.MAX_SLOTS)
	local extra = if hasSlotsPass then Economy.PASS_EXTRA_SLOTS else 0
	return math.min(bought + extra, MapLayout.maxPhysicalSlots())
end

-- The most slots this player could ever have.
function GarageService._maxSlots(hasSlotsPass: boolean): number
	local extra = if hasSlotsPass then Economy.PASS_EXTRA_SLOTS else 0
	return math.min(Economy.MAX_SLOTS + extra, MapLayout.maxPhysicalSlots())
end

-- Lowest empty slot index within capacity (nil when full).
function GarageService._firstFreeSlot(garage: { [string]: SlotRecord }, capacity: number): number?
	for i = 1, capacity do
		if garage[tostring(i)] == nil then
			return i
		end
	end
	return nil
end

export type PadInfo = { locked: boolean, price: number, passOnly: boolean, nextUnlock: boolean }

-- What a pad shows for a player: locked? price to unlock (0 if n/a), pass-only, cheapest next purchase.
function GarageService._padInfo(slot: number, slotsUnlocked: number, hasSlotsPass: boolean): PadInfo
	local cap = GarageService._capacity(slotsUnlocked, hasSlotsPass)
	if slot <= cap then
		return { locked = false, price = 0, passOnly = false, nextUnlock = false }
	end
	local bought = math.clamp(slotsUnlocked, 0, Economy.MAX_SLOTS)
	local purchase = bought + (slot - cap) -- value of slotsUnlocked after buying enough to reach this pad
	if purchase <= Economy.MAX_SLOTS then
		return {
			locked = true,
			price = EconomyMath.slotPrice(purchase) or 0,
			passOnly = false,
			nextUnlock = slot == cap + 1,
		}
	end
	return { locked = true, price = 0, passOnly = not hasSlotsPass, nextUnlock = false }
end

-- Adds income to every Parked slot (missing state = Parked). Returns total $/s of the Parked slots.
function GarageService._accrue(
	garage: { [string]: SlotRecord },
	states: { [number]: SlotState },
	mult: number,
	dt: number
): number
	local total = 0
	for key, rec in garage do
		local slot = tonumber(key)
		if slot and (states[slot] or "Parked") == "Parked" then
			local inc = EconomyMath.carIncome(rec.carId, rec.mutation) * mult
			rec.uncollected = (rec.uncollected or 0) + inc * dt
			total += inc
		end
	end
	return total
end

-- Server-side minimum hold before a StealPrompt trigger is accepted (10% latency slack).
function GarageService._requiredHold(baseHold: number, holdMultiplier: number): number
	return baseHold * holdMultiplier * 0.9
end

function GarageService._baseStealHold(carId: string): number
	local def = Cars.get(carId)
	local tier = def and Rarity.Tiers[def.rarity]
	return (if tier then tier.hotwireTime else 1) * Economy.THEFT_HOLD_MULTIPLIER
end

-- Per-player runtime state ----------------------------------------------------------------------------------------

type Display = {
	model: Model,
	chassis: BasePart,
	slot: number,
	holds: { [Player]: number },
	shownUncollected: number,
	shownIncome: number,
}

type PState = {
	states: { [number]: SlotState },
	displays: { [number]: Display },
	outCars: { [number]: any }, -- slot -> VehicleService Car (Owned, out driving)
	mult: number,
	indexBonus: number,
	indexAt: number,
	income: number,
	ticks: number,
	collectAt: number,
	fullNotifyAt: number,
	padsKey: string,
}

local pstates: { [Player]: PState } = {}

local function getData(player: Player): any
	local DataService = sys("DataService")
	if not DataService then
		return nil
	end
	return try(DataService.get, nil, player)
end

local function markDirty(player: Player)
	local DataService = sys("DataService")
	if DataService then
		try(DataService.markDirty, nil, player)
	end
end

local function getPS(player: Player): PState
	local ps = pstates[player]
	if not ps then
		ps = {
			states = {},
			displays = {},
			outCars = {},
			mult = 1,
			indexBonus = 0,
			indexAt = -math.huge,
			income = 0,
			ticks = 0,
			collectAt = 0,
			fullNotifyAt = 0,
			padsKey = "",
		}
		pstates[player] = ps
	end
	return ps
end

local function notify(player: Player, kind: string, text: string)
	Net.fireClient("Notify", player, kind, text)
end

local function progress(player: Player, stat: string, amount: number)
	local Rewards = sys("RewardsService")
	if Rewards then
		try(Rewards.progress, nil, player, stat, amount)
	end
end

local function hasPass(player: Player, key: string): boolean
	local Monet = sys("MonetizationService")
	return Monet ~= nil and try(Monet.hasPass, false, player, key) == true
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

local function plotIndexOf(player: Player): number?
	local PlotService = sys("PlotService")
	return PlotService and try(PlotService.getPlotIndex, nil, player)
end

local function plotModelOf(player: Player): Model?
	local PlotService = sys("PlotService")
	local index = plotIndexOf(player)
	if not PlotService or not index then
		return nil
	end
	return try(PlotService.getPlotModel, nil, index)
end

local function padTop(): number
	local PlotService = sys("PlotService")
	return if PlotService and typeof(PlotService.PAD_TOP) == "number" then PlotService.PAD_TOP else 0.25
end

-- Public: slots / capacity --------------------------------------------------------------------------------------------

function GarageService.maxSlots(player: Player): number
	return GarageService._maxSlots(hasPass(player, "slots"))
end

function GarageService.capacity(player: Player): number
	local data = getData(player)
	if not data then
		return 0
	end
	return GarageService._capacity(data.slotsUnlocked or Economy.START_SLOTS, hasPass(player, "slots"))
end

function GarageService.ownedCount(player: Player): number
	local data = getData(player)
	if not data or not data.garage then
		return 0
	end
	local n = 0
	for _ in data.garage do
		n += 1
	end
	return n
end

function GarageService.freeSlots(player: Player): number
	local data = getData(player)
	if not data or not data.garage then
		return 0
	end
	local cap = GarageService.capacity(player)
	local n = 0
	for i = 1, cap do
		if data.garage[tostring(i)] == nil then
			n += 1
		end
	end
	return n
end

function GarageService.getSlotState(player: Player, slot: number): SlotState?
	local data = getData(player)
	if not data or not data.garage or not data.garage[tostring(slot)] then
		return nil
	end
	local ps = pstates[player]
	return if ps then ps.states[slot] or "Parked" else "Parked"
end

-- Multiplier / income --------------------------------------------------------------------------------------------

local function computeMultiplier(player: Player, data: any, noEvents: boolean?): number
	local ps = getPS(player)
	local now = os.clock()
	if now - ps.indexAt > 5 then
		ps.indexAt = now
		ps.indexBonus = EconomyMath.indexBonus(data.discovered or {})
	end
	local eventMult = 1
	if not noEvents then
		local Events = sys("EventService")
		if Events then
			local m = try(Events.getIncomeMultiplier, 1)
			eventMult = if typeof(m) == "number" and m == m then m else 1
		end
	end
	local friends, inGroup = 0, false
	local Rewards = sys("RewardsService")
	if Rewards then
		local f = try(Rewards.friendsInServer, 0, player)
		friends = if typeof(f) == "number" and f == f then f else 0
		inGroup = try(Rewards.isInGroup, false, player) == true
	end
	return EconomyMath.playerMultiplier({
		rebirths = data.rebirths or 0,
		vip = hasPass(player, "vip"),
		eventMultiplier = eventMult,
		friendsInServer = friends,
		inGroup = inGroup,
		indexBonus = ps.indexBonus,
	})
end

function GarageService.multiplier(player: Player): number
	local data = getData(player)
	if not data then
		return 1
	end
	return computeMultiplier(player, data)
end

-- Current $/s of all Parked slots. noEvents=true excludes event multipliers (offline earnings).
function GarageService.incomePerSec(player: Player, noEvents: boolean?): number
	local data = getData(player)
	if not data or not data.garage then
		return 0
	end
	local mult = computeMultiplier(player, data, noEvents)
	local ps = pstates[player]
	local total = 0
	for key, rec in data.garage do
		local slot = tonumber(key)
		if slot and (if ps then ps.states[slot] or "Parked" else "Parked") == "Parked" then
			total += EconomyMath.carIncome(rec.carId, rec.mutation) * mult
		end
	end
	return total
end

function GarageService.slotSnapshots(player: Player): { [string]: SlotSnapshot }
	local out: { [string]: SlotSnapshot } = {}
	local data = getData(player)
	if not data or not data.garage then
		return out
	end
	local ps = pstates[player]
	local mult = if ps then ps.mult else computeMultiplier(player, data)
	for key, rec in data.garage do
		local slot = tonumber(key)
		out[key] = {
			carId = rec.carId,
			mutation = rec.mutation,
			uncollected = math.floor(rec.uncollected or 0),
			state = if ps and slot then ps.states[slot] or "Parked" else "Parked",
			income = EconomyMath.carIncome(rec.carId, rec.mutation) * mult,
		}
	end
	return out
end

-- Display cars ------------------------------------------------------------------------------------------------------

local function removeDisplay(ps: PState, slot: number)
	local d = ps.displays[slot]
	if d then
		ps.displays[slot] = nil
		d.model:Destroy()
	end
end

local function holdMultiplier(player: Player): number
	local data = getData(player)
	local level = if data and data.upgrades then data.upgrades.hotwire or 0 else 0
	local mult = EconomyMath.upgradeValue("hotwire", level)
	if hasPass(player, "hotwire") then
		mult *= Monetization.MASTER_THIEF_MULT
	end
	local attr = player:GetAttribute("HoldMultiplier")
	if typeof(attr) == "number" and attr == attr and attr > 0 then
		mult = math.min(mult, attr)
	end
	return mult
end

local function makePrompt(
	parent: Instance,
	name: string,
	action: string,
	object: string,
	key: Enum.KeyCode,
	pad: Enum.KeyCode,
	hold: number,
	offset: Vector2
): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.Name = name
	pp.ActionText = action
	pp.ObjectText = object
	pp.KeyboardKeyCode = key
	pp.GamepadKeyCode = pad
	pp.HoldDuration = hold
	pp.RequiresLineOfSight = false
	pp.MaxActivationDistance = GarageService.PROMPT_DISTANCE
	pp.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	pp.UIOffset = offset
	pp.Parent = parent
	return pp
end

local driveSlot: (Player, number) -> boolean
local sellSlot: (Player, number) -> boolean

local function buildDisplay(player: Player, ps: PState, slot: number, rec: SlotRecord)
	removeDisplay(ps, slot)
	local PlotService = sys("PlotService")
	local index = plotIndexOf(player)
	if not PlotService or not index then
		return
	end
	local folder = try(PlotService.getDisplayFolder, nil, index)
	local CB = getCarBuilder()
	local def = Cars.get(rec.carId)
	if not folder or not CB or not def then
		return
	end
	local ok, model = pcall(CB.build, rec.carId, rec.mutation, { forDisplay = true })
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn(("[GarageService] CarBuilder.build(%s) failed: %s"):format(rec.carId, tostring(model)))
		return
	end
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not chassis or not chassis:IsA("BasePart") then
		model:Destroy()
		return
	end
	model.Name = "Slot" .. slot
	local ride = model:GetAttribute("RideHeight")
	local height = padTop() + (if typeof(ride) == "number" then ride else 2)
	model:PivotTo(MapLayout.slotWorld(index, slot) * CFrame.new(0, height, 0))
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		elseif d:IsA("VehicleSeat") or d:IsA("Seat") then
			(d :: any).Disabled = true
		end
	end
	chassis.CanCollide = true

	local tier = Rarity.Tiers[def.rarity]
	local income = EconomyMath.carIncome(rec.carId, rec.mutation) * ps.mult
	model:SetAttribute("PlotIndex", index)
	model:SetAttribute("Slot", slot)
	model:SetAttribute("CarId", rec.carId)
	model:SetAttribute("Mutation", rec.mutation)
	model:SetAttribute("Rarity", def.rarity)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("Uncollected", math.floor(rec.uncollected or 0))
	model:SetAttribute("Income", income)
	CollectionService:AddTag(model, "DisplayCar")

	local label = carLabel(rec.carId, rec.mutation)
	local display: Display = {
		model = model,
		chassis = chassis,
		slot = slot,
		holds = {},
		shownUncollected = math.floor(rec.uncollected or 0),
		shownIncome = income,
	}

	local drive =
		makePrompt(chassis, "DrivePrompt", "Drive", label, Enum.KeyCode.E, Enum.KeyCode.ButtonX, 0, Vector2.zero)
	drive.Triggered:Connect(function(p: Player)
		if p == player then
			driveSlot(p, slot)
		end
	end)
	local sellValue = EconomyMath.sellValue(rec.carId, rec.mutation)
	local sell = makePrompt(
		chassis,
		"SellPrompt",
		"Sell " .. Format.cash(sellValue),
		label,
		Enum.KeyCode.F,
		Enum.KeyCode.ButtonY,
		1,
		Vector2.new(0, 84)
	)
	sell.Triggered:Connect(function(p: Player)
		if p == player then
			sellSlot(p, slot)
		end
	end)
	if def.stealable and tier then
		local base = GarageService._baseStealHold(rec.carId)
		local steal =
			makePrompt(chassis, "StealPrompt", "Steal", label, Enum.KeyCode.E, Enum.KeyCode.ButtonX, base, Vector2.zero)
		steal:SetAttribute("BaseHold", base)
		steal.PromptButtonHoldBegan:Connect(function(p: Player)
			display.holds[p] = os.clock()
		end)
		steal.Triggered:Connect(function(thief: Player)
			if thief == player or thief.Parent == nil or player.Parent == nil then
				return
			end
			local began = display.holds[thief]
			display.holds[thief] = nil
			if not began or os.clock() - began < GarageService._requiredHold(base, holdMultiplier(thief)) then
				return
			end
			if ps.states[slot] ~= nil and ps.states[slot] ~= "Parked" then
				return
			end
			local Theft = sys("TheftService")
			if not Theft or typeof(Theft.beginTheft) ~= "function" then
				notify(thief, "error", "Stealing is offline right now.")
				return
			end
			local okTheft, err = pcall(Theft.beginTheft, thief, player, slot)
			if not okTheft then
				warn("[GarageService] beginTheft failed: " .. tostring(err))
			end
		end)
	end

	ps.displays[slot] = display
	model.Parent = folder
end

-- Pads + plot attributes (what every client renders) ----------------------------------------------------------------

local function updatePads(player: Player, force: boolean?)
	local model = plotModelOf(player)
	local data = getData(player)
	if not model or not data then
		return
	end
	local ps = getPS(player)
	local slotsPass = hasPass(player, "slots")
	local unlocked = data.slotsUnlocked or Economy.START_SLOTS
	local parts = { tostring(unlocked), tostring(slotsPass) }
	for slot = 1, MapLayout.maxPhysicalSlots() do
		local rec = data.garage[tostring(slot)]
		table.insert(parts, if rec then rec.carId .. ":" .. (ps.states[slot] or "Parked") else "-")
	end
	local key = table.concat(parts, "|")
	if key == ps.padsKey and not force then
		return
	end
	ps.padsKey = key
	for slot = 1, MapLayout.maxPhysicalSlots() do
		local pad = model:FindFirstChild("Pad" .. slot)
		if pad then
			local info = GarageService._padInfo(slot, unlocked, slotsPass)
			local rec = data.garage[tostring(slot)]
			pad:SetAttribute("Locked", info.locked and rec == nil)
			pad:SetAttribute("Price", info.price)
			pad:SetAttribute("PassOnly", info.passOnly)
			pad:SetAttribute("NextUnlock", info.nextUnlock and rec == nil)
			pad:SetAttribute("State", if rec then ps.states[slot] or "Parked" else "Empty")
		end
	end
	model:SetAttribute("CarCount", GarageService.ownedCount(player))
end

local function updatePlotTotals(player: Player, data: any, ps: PState)
	local model = plotModelOf(player)
	if not model then
		return
	end
	local total = 0
	for _, rec in data.garage do
		total += rec.uncollected or 0
	end
	local whole = math.floor(total)
	if model:GetAttribute("Uncollected") ~= whole then
		model:SetAttribute("Uncollected", whole)
	end
	if model:GetAttribute("IncomePerSec") ~= ps.income then
		model:SetAttribute("IncomePerSec", ps.income)
	end
end

-- Rebuild all displays + pads for a player (load, plot assigned, rebirth, admin...).
function GarageService.refresh(player: Player)
	local data = getData(player)
	if not data or not data.garage then
		return
	end
	local ps = getPS(player)
	ps.mult = computeMultiplier(player, data)
	for slot in ps.displays do
		removeDisplay(ps, slot)
	end
	-- drop states for slots that no longer exist
	for slot in ps.states do
		if data.garage[tostring(slot)] == nil then
			ps.states[slot] = nil
		end
	end
	for key, rec in data.garage do
		local slot = tonumber(key)
		if slot and (ps.states[slot] or "Parked") == "Parked" then
			ps.states[slot] = "Parked"
			buildDisplay(player, ps, slot, rec)
		end
	end
	ps.income = GarageService.incomePerSec(player)
	player:SetAttribute("IncomePerSec", ps.income)
	updatePads(player, true)
	updatePlotTotals(player, data, ps)
	markDirty(player)
end

local function refreshIfReady(player: Player)
	if player.Parent == nil then
		return
	end
	local data = getData(player)
	if data and plotIndexOf(player) then
		GarageService.refresh(player)
	elseif data then
		-- no plot (server full?) still earns; keep attributes sane
		getPS(player)
		player:SetAttribute("IncomePerSec", GarageService.incomePerSec(player))
	end
end

-- Slot mutation API ----------------------------------------------------------------------------------------------------

function GarageService.setSlotState(player: Player, slot: number, state: SlotState)
	local data = getData(player)
	local rec = data and data.garage and data.garage[tostring(slot)]
	if not rec then
		return
	end
	local ps = getPS(player)
	ps.states[slot] = state
	if state == "Parked" then
		ps.outCars[slot] = nil
		if not ps.displays[slot] then
			buildDisplay(player, ps, slot, rec)
		end
	else
		removeDisplay(ps, slot)
	end
	ps.income = GarageService.incomePerSec(player)
	player:SetAttribute("IncomePerSec", ps.income)
	updatePads(player)
	markDirty(player)
end

function GarageService.restoreSlot(player: Player, slot: number)
	GarageService.setSlotState(player, slot, "Parked")
end

-- Removes a slot's car entirely (theft transfer, rebirth...). Returns the removed record (caller handles its cash).
function GarageService.removeSlot(player: Player, slot: number): SlotRecord?
	local data = getData(player)
	if not data or not data.garage then
		return nil
	end
	local key = tostring(slot)
	local rec = data.garage[key]
	if not rec then
		return nil
	end
	data.garage[key] = nil
	local ps = getPS(player)
	ps.states[slot] = nil
	ps.outCars[slot] = nil
	removeDisplay(ps, slot)
	ps.income = GarageService.incomePerSec(player)
	player:SetAttribute("IncomePerSec", ps.income)
	updatePads(player)
	updatePlotTotals(player, data, ps)
	markDirty(player)
	return rec
end

-- Puts a car into the first free slot. Returns (true, slotIndex) or (false, reason) with reason "full" / "nodata" /
-- "badcar". Does NOT mark the car discovered (callers decide; see GarageService.discover).
function GarageService.storeCar(player: Player, carId: string, mutation: Types.MutationId?): (boolean, number | string)
	local data = getData(player)
	if not data or not data.garage then
		return false, "nodata"
	end
	if typeof(carId) ~= "string" or not Cars.get(carId) then
		return false, "badcar"
	end
	local mut: Types.MutationId = if mutation and Rarity.Mutations[mutation] then mutation else "None"
	local slot = GarageService._firstFreeSlot(data.garage, GarageService.capacity(player))
	if not slot then
		return false, "full"
	end
	local rec: SlotRecord = { carId = carId, mutation = mut, uncollected = 0 }
	data.garage[tostring(slot)] = rec
	local ps = getPS(player)
	ps.states[slot] = "Parked"
	buildDisplay(player, ps, slot, rec)
	ps.income = GarageService.incomePerSec(player)
	player:SetAttribute("IncomePerSec", ps.income)
	updatePads(player)
	markDirty(player)
	return true, slot
end

-- Marks a car as discovered for the Index. Returns true when it is new.
function GarageService.discover(player: Player, carId: string): boolean
	local data = getData(player)
	if not data or not Cars.get(carId) then
		return false
	end
	data.discovered = data.discovered or {}
	if data.discovered[carId] then
		return false
	end
	data.discovered[carId] = true
	local ps = pstates[player]
	if ps then
		ps.indexAt = -math.huge -- recompute index bonus next tick
	end
	return true
end

-- Collect ----------------------------------------------------------------------------------------------------------------

function GarageService.collect(player: Player): number
	local data = getData(player)
	local DataService = sys("DataService")
	if not data or not data.garage or not DataService then
		return 0
	end
	local total = 0
	for _, rec in data.garage do
		total += rec.uncollected or 0
		rec.uncollected = 0
	end
	local amount = math.floor(total)
	local ps = getPS(player)
	for _, d in ps.displays do
		d.shownUncollected = 0
		d.model:SetAttribute("Uncollected", 0)
	end
	updatePlotTotals(player, data, ps)
	if amount <= 0 then
		return 0
	end
	try(DataService.addCash, nil, player, amount, "collect")
	local model = plotModelOf(player)
	local pad = model and model:FindFirstChild("CollectPad")
	local pos = if pad and pad:IsA("BasePart") then pad.CFrame.Position + Vector3.new(0, 3, 0) else nil
	Net.fireClient("CashPopup", player, amount, pos)
	local big = amount >= math.max(250, ps.income * 30)
	Net.fireClient("Sound", player, if big then "CashBig" else "Cash", pos)
	if pos then
		Net.fireNear("Effect", pos, 150, "CashBurst", { position = pos, amount = amount })
	end
	progress(player, "collectCash", amount)
	markDirty(player)
	return amount
end

local function onCollectTouched(index: number, hit: BasePart)
	local node: Instance? = hit.Parent
	local player: Player? = nil
	for _ = 1, 3 do
		if not node then
			break
		end
		player = Players:GetPlayerFromCharacter(node)
		if player then
			break
		end
		node = node.Parent
	end
	if not player or plotIndexOf(player) ~= index then
		return
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	local ps = getPS(player)
	local now = os.clock()
	if now - ps.collectAt < GarageService.COLLECT_DEBOUNCE then
		return
	end
	ps.collectAt = now
	GarageService.collect(player)
end

-- Sell / drive / unlock --------------------------------------------------------------------------------------------------

sellSlot = function(player: Player, slot: number): boolean
	local data = getData(player)
	local DataService = sys("DataService")
	local rec = data and data.garage and data.garage[tostring(slot)]
	if not rec or not DataService then
		return false
	end
	if GarageService.getSlotState(player, slot) ~= "Parked" then
		notify(player, "error", "That car isn't parked right now.")
		return false
	end
	local def = Cars.get(rec.carId)
	if def and def.rarity == "Exclusive" then
		notify(player, "error", "Exclusive cars can't be sold.")
		return false
	end
	if GarageService.ownedCount(player) <= 1 then
		notify(player, "error", "You can't sell your last car!")
		return false
	end
	local removed = GarageService.removeSlot(player, slot)
	if not removed then
		return false
	end
	local value = EconomyMath.sellValue(removed.carId, removed.mutation) + math.floor(removed.uncollected or 0)
	try(DataService.addCash, nil, player, value, "sell")
	local model = plotModelOf(player)
	local pad = model and model:FindFirstChild("Pad" .. slot)
	local pos = if pad and pad:IsA("BasePart") then pad.CFrame.Position + Vector3.new(0, 4, 0) else nil
	Net.fireClient("CashPopup", player, value, pos)
	Net.fireClient("Sound", player, "CashDrop", pos)
	notify(player, "money", `Sold {carLabel(removed.carId, removed.mutation)} for {Format.cash(value)}`)
	return true
end

driveSlot = function(player: Player, slot: number): boolean
	local data = getData(player)
	local rec = data and data.garage and data.garage[tostring(slot)]
	local index = plotIndexOf(player)
	local VS = sys("VehicleService")
	if not rec or not index or not VS then
		return false
	end
	local ps = getPS(player)
	if (ps.states[slot] or "Parked") ~= "Parked" then
		return false
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not root or not root:IsA("BasePart") then
		return false
	end
	if hum.SeatPart or player:GetAttribute("Driving") == true or try(VS.getDriving, nil, player) ~= nil then
		notify(player, "error", "You're already driving!")
		return false
	end
	if player:GetAttribute("Stunned") == true then
		return false
	end
	local near = (root.Position - MapLayout.slotWorld(index, slot).Position).Magnitude
		<= GarageService.DRIVE_MAX_DISTANCE
	if MapLayout.plotAt(root.Position) ~= index and not near then
		notify(player, "error", "Go to your garage to take a car out.")
		return false
	end
	ps.states[slot] = "Driving"
	removeDisplay(ps, slot)
	local ground = MapLayout.plotToWorld(index, G.DRIVE_OUT_SPAWN + Vector3.new(0, padTop() - 0.2, 0))
	local ok, car = pcall(VS.spawn, rec.carId, rec.mutation, ground, "Owned", {
		ownerUserId = player.UserId,
		owner = player,
		slot = slot,
	})
	if not ok or type(car) ~= "table" or not car.model then
		warn("[GarageService] VehicleService.spawn failed: " .. tostring(car))
		ps.states[slot] = "Parked"
		buildDisplay(player, ps, slot, rec)
		notify(player, "error", "Couldn't start that car. Try again!")
		return false
	end
	car.ownerUserId = player.UserId
	car.data = car.data or {}
	car.data.slot = slot
	car.data.leftGarage = false
	pcall(function()
		car.model:SetAttribute("OwnerUserId", player.UserId)
		car.model:SetAttribute("Slot", slot)
	end)
	ps.outCars[slot] = car
	local seatOk, err = pcall(VS.seat, car, player)
	if not seatOk then
		warn("[GarageService] VehicleService.seat failed: " .. tostring(err))
	end
	ps.income = GarageService.incomePerSec(player)
	player:SetAttribute("IncomePerSec", ps.income)
	updatePads(player)
	markDirty(player)
	return true
end

-- UnlockSlot remote handler: buys the next garage slot (server-side price). Public so menus/admin can reuse it.
local function unlockSlot(player: Player)
	local data = getData(player)
	local DataService = sys("DataService")
	if not data or not DataService then
		return
	end
	local unlocked = data.slotsUnlocked or Economy.START_SLOTS
	if unlocked >= Economy.MAX_SLOTS then
		if hasPass(player, "slots") then
			notify(player, "info", "Every garage slot is unlocked!")
		else
			notify(player, "info", "All cash slots unlocked! The +2 Slots pass adds two more.")
		end
		return
	end
	local price = EconomyMath.slotPrice(unlocked + 1) or 0
	if price > 0 and try(DataService.spendCash, false, player, price) ~= true then
		notify(player, "error", `Need {Format.cash(price)} to unlock the next slot.`)
		return
	end
	data.slotsUnlocked = unlocked + 1
	updatePads(player, true)
	local cap = GarageService.capacity(player)
	local model = plotModelOf(player)
	local pad = model and model:FindFirstChild("Pad" .. cap)
	local pos = if pad and pad:IsA("BasePart") then pad.CFrame.Position + Vector3.new(0, 2, 0) else nil
	Net.fireClient("Sound", player, "Purchase", pos)
	if pos then
		Net.fireNear("Effect", pos, 150, "Confetti", { position = pos })
	end
	notify(player, "success", `🅿️ Slot {cap} unlocked!`)
	markDirty(player)
end

-- Vehicle signal handlers ----------------------------------------------------------------------------------------------

local function sameUser(a: any, player: Player): boolean
	if typeof(a) == "Instance" then
		return a == player
	end
	return a == player.UserId
end

local function destroyCar(car: any, reason: string)
	local VS = sys("VehicleService")
	if not VS then
		return
	end
	if typeof(VS.eject) == "function" then
		pcall(VS.eject, car)
	end
	if typeof(VS.destroy) == "function" then
		local ok, err = pcall(VS.destroy, car, reason)
		if not ok then
			warn("[GarageService] VehicleService.destroy failed: " .. tostring(err))
		end
	end
end

local function carPosition(car: any): Vector3?
	local chassis = car.chassis
	if typeof(chassis) == "Instance" and chassis:IsA("BasePart") then
		return chassis.CFrame.Position
	end
	local model = car.model
	if typeof(model) == "Instance" and model:IsA("Model") then
		return model:GetPivot().Position
	end
	return nil
end

local function onDelivery(player: Player, car: any)
	if type(car) ~= "table" or car.data == nil or car.data.delivered then
		return
	end
	local data = getData(player)
	if not data or not data.garage then
		return
	end
	local kind = car.kind
	local pos = carPosition(car)
	if kind == "Owned" then
		if car.ownerUserId ~= player.UserId or not car.data.leftGarage then
			return -- still on the way out of the garage
		end
		local slot = car.data.slot
		local rec = slot and data.garage[tostring(slot)]
		car.data.delivered = true
		destroyCar(car, "parked")
		local ps = getPS(player)
		if slot then
			ps.outCars[slot] = nil
		end
		if rec and rec.carId == car.carId then
			GarageService.restoreSlot(player, slot)
			Net.fireClient("Sound", player, "CarDoor", pos)
		else
			-- the slot vanished meanwhile (rebirth...): try to keep the car anyway
			local ok = GarageService.storeCar(player, car.carId, car.mutation)
			if not ok then
				notify(player, "warning", "No free slot for that car!")
			end
		end
		return
	elseif kind == "Stolen" then
		local theft = car.data.theft
		local Theft = sys("TheftService")
		if not Theft then
			return
		end
		if theft and sameUser(theft.victim, player) then
			-- the victim drove their own car home
			car.data.delivered = true
			local fn = if typeof(Theft.recover) == "function" then Theft.recover else Theft.fail
			local ok, err = pcall(fn, car, if fn == Theft.fail then "recovered" else player)
			if not ok then
				car.data.delivered = false
				warn("[GarageService] theft recovery failed: " .. tostring(err))
			end
			return
		end
		if typeof(Theft.complete) ~= "function" then
			return
		end
		local model = car.model
		local ok, res = pcall(Theft.complete, car)
		if not ok then
			warn("[GarageService] TheftService.complete failed: " .. tostring(res))
			return
		end
		local done = res == true or (res == nil and typeof(model) == "Instance" and model.Parent == nil)
		if done then
			car.data.delivered = true
			local stats = data.stats
			if stats then
				stats.steals = (stats.steals or 0) + 1
			end
			markDirty(player)
		end
		return
	elseif kind ~= "Loot" then
		return
	end

	-- Loot (street / traffic / dealership / hot drop) ------------------------------------------------------------------
	local def = Cars.get(car.carId)
	if not def then
		return
	end
	local ps = getPS(player)
	local okStore, slotOrReason = GarageService.storeCar(player, car.carId, car.mutation)
	if not okStore then
		if slotOrReason == "full" then
			local now = os.clock()
			if now > ps.fullNotifyAt then
				ps.fullNotifyAt = now + 4
				notify(player, "error", "Garage full! Sell a car or chop it at the Chop Shop")
			end
		end
		return
	end
	car.data.delivered = true
	destroyCar(car, "delivered")
	local isNew = GarageService.discover(player, car.carId)
	local stats = data.stats
	if stats then
		stats.steals = (stats.steals or 0) + 1
	end
	local tier = Rarity.Tiers[def.rarity]
	local order = if tier then tier.order else 1
	if order >= 3 then
		progress(player, "deliverRare", 1)
	end
	if order >= 4 then
		progress(player, "deliverEpic", 1)
	end
	local index = plotIndexOf(player)
	local slotPos = if index and typeof(slotOrReason) == "number"
		then MapLayout.slotWorld(index, slotOrReason :: number).Position + Vector3.new(0, 4, 0)
		else pos
	local fxPos = slotPos or pos
	if fxPos then
		Net.fireNear("Effect", fxPos, 250, "Confetti", { position = fxPos, rarity = def.rarity })
	end
	Net.fireClient("Sound", player, "CashBig", fxPos)
	local income = EconomyMath.carIncome(car.carId, car.mutation) * ps.mult
	local label = carLabel(car.carId, car.mutation)
	notify(player, "success", `{if isNew then "NEW! " else ""}{label} parked! +{Format.cash(income)}/s`)
	if order >= 4 then
		local hex = if tier then tier.color:ToHex() else "FFFFFF"
		Net.fireAll(
			"EventFeed",
			`🚗 <b>{richEscape(player.DisplayName)}</b> delivered a <font color="#{hex}"><b>{richEscape(label)}</b></font>!`
		)
	end
	markDirty(player)
end

local function onChop(player: Player, car: any)
	if type(car) ~= "table" or car.kind ~= "Loot" or car.data == nil or car.data.chopped then
		return
	end
	if car.driver ~= nil and car.driver ~= player then
		return
	end
	local DataService = sys("DataService")
	if not DataService or not Cars.get(car.carId) then
		return
	end
	car.data.chopped = true
	local pos = carPosition(car)
	local value = EconomyMath.chopValue(car.carId, car.mutation)
	destroyCar(car, "chopped")
	try(DataService.addCash, nil, player, value, "chop")
	Net.fireClient("CashPopup", player, value, pos)
	Net.fireClient("Sound", player, "CashDrop", pos)
	if pos then
		Net.fireNear("Effect", pos, 150, "CashBurst", { position = pos, amount = value })
	end
	notify(player, "money", `🔧 Chopped {carLabel(car.carId, car.mutation)} for {Format.cash(value)}`)
	progress(player, "chop", 1)
	markDirty(player)
end

local function ownerOf(car: any): Player?
	local uid = car.ownerUserId
	if typeof(uid) ~= "number" then
		return nil
	end
	return Players:GetPlayerByUserId(uid)
end

local function onReturnedHome(car: any)
	if type(car) ~= "table" or car.kind ~= "Owned" or car.data == nil then
		return
	end
	local player = ownerOf(car)
	local slot = car.data.slot
	local model = car.model
	if typeof(model) == "Instance" and model.Parent ~= nil and not car.data.delivered then
		car.data.delivered = true
		destroyCar(car, "returned")
	end
	if not player or typeof(slot) ~= "number" then
		return
	end
	local ps = pstates[player]
	if ps then
		ps.outCars[slot] = nil
	end
	if GarageService.getSlotState(player, slot) == "Driving" then
		GarageService.restoreSlot(player, slot)
		notify(player, "info", `🚚 Your {carLabel(car.carId, car.mutation)} was towed back home.`)
	end
end

local function onVehicleDestroyed(car: any, _reason: any)
	if type(car) ~= "table" or car.kind ~= "Owned" or car.data == nil then
		return
	end
	local player = ownerOf(car)
	local slot = car.data.slot
	if not player or typeof(slot) ~= "number" then
		return
	end
	local ps = pstates[player]
	if ps and ps.outCars[slot] == car then
		ps.outCars[slot] = nil
	end
	if GarageService.getSlotState(player, slot) == "Driving" then
		GarageService.restoreSlot(player, slot)
	end
end

-- Lifecycle ------------------------------------------------------------------------------------------------------------

local function cleanup(player: Player)
	local ps = pstates[player]
	pstates[player] = nil
	if not ps then
		return
	end
	for slot in ps.displays do
		removeDisplay(ps, slot)
	end
end

local function tickPlayer(player: Player, ps: PState, dt: number)
	local data = getData(player)
	if not data or not data.garage then
		return
	end
	ps.mult = computeMultiplier(player, data)
	local income = GarageService._accrue(data.garage, ps.states, ps.mult, dt)
	if income ~= ps.income or player:GetAttribute("IncomePerSec") ~= income then
		ps.income = income
		player:SetAttribute("IncomePerSec", income)
	end
	for slot, d in ps.displays do
		local rec = data.garage[tostring(slot)]
		if rec then
			local whole = math.floor(rec.uncollected or 0)
			if whole ~= d.shownUncollected then
				d.shownUncollected = whole
				d.model:SetAttribute("Uncollected", whole)
			end
			local inc = EconomyMath.carIncome(rec.carId, rec.mutation) * ps.mult
			if math.abs(inc - d.shownIncome) > 1e-6 then
				d.shownIncome = inc
				d.model:SetAttribute("Income", inc)
			end
		end
	end
	updatePlotTotals(player, data, ps)
	ps.ticks += 1
	if ps.ticks % GarageService.SNAPSHOT_EVERY == 0 then
		markDirty(player)
	end
end

-- Owned cars out driving: flag when they've left the garage (so the drop-off only parks cars coming back) and
-- recover slots whose car vanished without a signal.
local function watchOutCars()
	for player, ps in pstates do
		local index = plotIndexOf(player)
		for slot, car in ps.outCars do
			local model = car.model
			if typeof(model) ~= "Instance" or model.Parent == nil then
				ps.outCars[slot] = nil
				if GarageService.getSlotState(player, slot) == "Driving" then
					GarageService.restoreSlot(player, slot)
				end
			elseif not car.data.leftGarage and index then
				local pos = carPosition(car)
				if pos and MapLayout.plotAt(pos) ~= index then
					car.data.leftGarage = true
				end
			end
		end
	end
end

function GarageService.init()
	Net.on("UnlockSlot", function(player: Player)
		unlockSlot(player)
	end, 2)
	Net.on("SellCar", function(player: Player, slot: any)
		if not Net.isInt(slot, 1, MapLayout.maxPhysicalSlots()) then
			return
		end
		sellSlot(player, slot)
	end, 3)
	Net.on("DriveCar", function(player: Player, slot: any)
		if not Net.isInt(slot, 1, MapLayout.maxPhysicalSlots()) then
			return
		end
		driveSlot(player, slot)
	end, 2)

	local PlotService = sys("PlotService")
	if PlotService then
		for index = 1, MapLayout.plotCount() do
			local model = try(PlotService.getPlotModel, nil, index)
			local pad = model and model:FindFirstChild("CollectPad")
			if pad and pad:IsA("BasePart") then
				pad.Touched:Connect(function(hit: BasePart)
					onCollectTouched(index, hit)
				end)
			end
		end
		PlotService.PlotAssigned:Connect(function(player: Player)
			refreshIfReady(player)
		end)
		PlotService.PlotReleased:Connect(function(player: Player)
			local ps = pstates[player]
			if ps then
				for slot in ps.displays do
					removeDisplay(ps, slot)
				end
			end
		end)
	else
		warn("[GarageService] PlotService missing")
	end

	local DataService = sys("DataService")
	if DataService and DataService.Loaded then
		DataService.Loaded:Connect(function(player: Player)
			refreshIfReady(player)
		end)
	end

	local VS = sys("VehicleService")
	if VS then
		if VS.DeliveryAttempt then
			VS.DeliveryAttempt:Connect(onDelivery)
		end
		if VS.ChopAttempt then
			VS.ChopAttempt:Connect(onChop)
		end
		if VS.ReturnedHome then
			VS.ReturnedHome:Connect(onReturnedHome)
		end
		if VS.Destroyed then
			VS.Destroyed:Connect(onVehicleDestroyed)
		end
	else
		warn("[GarageService] VehicleService missing: deliveries disabled")
	end

	local Monet = sys("MonetizationService")
	if Monet and Monet.PassChanged then
		Monet.PassChanged:Connect(function(player: Player, key: string)
			if key == "slots" then
				updatePads(player, true)
				markDirty(player)
			elseif key == "vip" then
				local ps = pstates[player]
				if ps then
					ps.mult = GarageService.multiplier(player)
				end
			end
		end)
	end

	Players.PlayerRemoving:Connect(cleanup)
end

function GarageService.start()
	for _, p in Players:GetPlayers() do
		task.spawn(refreshIfReady, p)
	end
	task.spawn(function()
		while true do
			task.wait(0.25)
			local ok, err = pcall(watchOutCars)
			if not ok then
				warn("[GarageService] watchOutCars: " .. tostring(err))
			end
		end
	end)
	local last = os.clock()
	while true do
		task.wait(Economy.INCOME_TICK)
		local now = os.clock()
		local dt = math.clamp(now - last, 0, Economy.INCOME_TICK * 5)
		last = now
		for _, player in Players:GetPlayers() do
			local data = getData(player)
			if data and data.garage then
				local ps = getPS(player)
				local ok, err = pcall(tickPlayer, player, ps, dt)
				if not ok then
					warn("[GarageService] tick failed for " .. player.Name .. ": " .. tostring(err))
				end
			end
		end
	end
end

-- Exposed for other systems/tests that want to drive the same code paths as the prompts/remotes/signals.
GarageService.unlockNextSlot = unlockSlot
GarageService._onDelivery = onDelivery
GarageService._onChop = onChop
GarageService._onReturnedHome = onReturnedHome
GarageService.sell = function(player: Player, slot: number): boolean
	return sellSlot(player, slot)
end
GarageService.drive = function(player: Player, slot: number): boolean
	return driveSlot(player, slot)
end

return GarageService
