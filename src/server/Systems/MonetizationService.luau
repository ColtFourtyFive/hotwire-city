--!strict
-- MonetizationService: gamepass ownership cache + the single MarketplaceService.ProcessReceipt.
--
-- Receipt safety (exactly-once grants):
--   1. Player absent or data not loaded            -> NotProcessedYet (Roblox redelivers on a later join).
--   2. PurchaseId already in data.receipts         -> it was granted. If this session hasn't confirmed a save
--      that contains it yet, try saveNow: success -> PurchaseGranted, failure -> NotProcessedYet.
--   3. Otherwise run the product handler (grant), append the PurchaseId to data.receipts IN THE SAME TABLE as
--      the grant, then saveNow. PurchaseGranted only when that save succeeded, else NotProcessedYet.
--   The grant and the receipt id always live in the same profile record, so they are persisted together or
--   lost together:
--     * save fails, server keeps running -> both are in memory; the next autosave/leave save persists both; a
--       redelivery finds the receipt id and does NOT grant again (step 2) -> no double grant.
--     * save fails and the server dies before any later save -> both are lost; Roblox redelivers and we
--       grant again -> the player still gets exactly one grant.
--   So no rollback is needed: rolling back would be strictly worse (a later redelivery could double-grant
--   if the rollback raced a successful autosave).
--   Concurrent deliveries of the same PurchaseId are rejected with NotProcessedYet while one is in flight.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Format = require(Shared.Util.Format)

local DataService = require(script.Parent.DataService)

local MonetizationService = {}

MonetizationService.PassChanged = Signal.new() -- (player, key)

export type ProductHandler = (Player) -> boolean

local owned: { [Player]: { [string]: boolean } } = {}
local overrides: { [Player]: { [string]: boolean } } = {} -- admin/Studio testing (session only)
local handlers: { [string]: ProductHandler } = {}
local inFlight: { [string]: boolean } = {} -- purchaseId -> being processed
local unconfirmed: { [Player]: { [string]: boolean } } = {} -- granted this session, save not confirmed yet
local passesReady: { [Player]: boolean } = {} -- the join-time gamepass lookup finished (or gave up)

local RECEIPT_CAP = 50
local EXCLUSIVE_CHECK_INTERVAL = 5

---------------------------------------------------------------------------------------------------------------
-- Pure receipt helpers (tested)
---------------------------------------------------------------------------------------------------------------

function MonetizationService._hasReceipt(receipts: { string }, purchaseId: string): boolean
	return table.find(receipts, purchaseId) ~= nil
end

-- Appends (if new) and trims to `cap` newest ids. Returns true if it was newly added.
function MonetizationService._recordReceipt(receipts: { string }, purchaseId: string, cap: number?): boolean
	if table.find(receipts, purchaseId) then
		return false
	end
	table.insert(receipts, purchaseId)
	local limit = cap or RECEIPT_CAP
	while #receipts > limit do
		table.remove(receipts, 1)
	end
	return true
end

-- Decision for a delivery given current state (pure). Returns "grant" | "alreadyGranted" | "confirmSave".
function MonetizationService._receiptAction(
	receipts: { string },
	purchaseId: string,
	unconfirmedSet: { [string]: boolean }?
): string
	if MonetizationService._hasReceipt(receipts, purchaseId) then
		if unconfirmedSet and unconfirmedSet[purchaseId] then
			return "confirmSave"
		end
		return "alreadyGranted"
	end
	return "grant"
end

-- One-per-account exclusive (pure): true if `carId` is parked in the garage or still owed in data.exclusives
-- (keys "<carId>" or "<carId>#<n>").
function MonetizationService._ownsExclusive(data: any, carId: string): boolean
	if typeof(data) ~= "table" then
		return false
	end
	if typeof(data.garage) == "table" then
		for _, rec in data.garage do
			if typeof(rec) == "table" and rec.carId == carId then
				return true
			end
		end
	end
	if typeof(data.exclusives) == "table" then
		for key, flag in data.exclusives do
			if flag and typeof(key) == "string" and string.match(key, "^([^#]+)") == carId then
				return true
			end
		end
	end
	return false
end

-- Cash product amounts (pure): income-scaled with minimums.
function MonetizationService._cashAmount(key: string, incomePerSec: number): number
	local income = if incomePerSec == incomePerSec and incomePerSec ~= math.huge then math.max(0, incomePerSec) else 0
	if key == "cash_small" then
		return math.floor(math.max(5000, income * 600))
	elseif key == "cash_big" then
		return math.floor(math.max(50000, income * 3600))
	end
	return 0
end

---------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------

local function trySystem(name: string): any
	local parent = script.Parent
	local mod = parent and parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod)
	if ok and typeof(result) == "table" then
		return result
	end
	return nil
end

local function callSystem(name: string, fnName: string, ...: any): (boolean, ...any)
	local mod = trySystem(name)
	if not mod then
		return false
	end
	local fn = mod[fnName]
	if typeof(fn) ~= "function" then
		return false
	end
	return pcall(fn, ...)
end

local function notify(player: Player, kind: string, text: string, duration: number?)
	if player.Parent == Players then
		Net.fireClient("Notify", player, kind, text, duration)
	end
end

local function rootPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function celebrate(player: Player, sound: string)
	if player.Parent ~= Players then
		return
	end
	Net.fireClient("Sound", player, sound)
	local pos = rootPosition(player)
	if pos then
		Net.fireClient("Effect", player, "Confetti", { position = pos })
	end
end

local function incomeOf(player: Player): number
	local ok, v = callSystem("GarageService", "incomePerSec", player)
	if ok and typeof(v) == "number" and v == v and v ~= math.huge then
		return math.max(0, v)
	end
	local attr = player:GetAttribute("IncomePerSec")
	if typeof(attr) == "number" and attr == attr and attr ~= math.huge then
		return math.max(0, attr)
	end
	return 0
end

local function applyPassAttributes(player: Player)
	if player.Parent ~= Players then
		return
	end
	local vip = MonetizationService.hasPass(player, "vip")
	if player:GetAttribute("VIP") ~= vip then
		player:SetAttribute("VIP", vip)
	end
end

local function setOwned(player: Player, key: string, value: boolean)
	local map = owned[player]
	if not map then
		map = {}
		owned[player] = map
	end
	local before = MonetizationService.hasPass(player, key)
	map[key] = value
	local after = MonetizationService.hasPass(player, key)
	if before ~= after then
		applyPassAttributes(player)
		MonetizationService.PassChanged:Fire(player, key)
		DataService.markDirty(player)
	end
end

---------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------

function MonetizationService.passIdFor(key: string): number
	local def = Monetization.Passes[key]
	return if def then def.id else 0
end

function MonetizationService.productIdFor(key: string): number
	local def = Monetization.Products[key]
	return if def then def.id else 0
end

-- True if the player owns the pass (false for unknown keys and for passes whose id is 0, unless an admin
-- testing override is set for this session).
function MonetizationService.hasPass(player: Player, key: string): boolean
	if not Monetization.Passes[key] then
		return false
	end
	local o = overrides[player]
	if o and o[key] ~= nil then
		return o[key]
	end
	if MonetizationService.passIdFor(key) == 0 then
		return false
	end
	local map = owned[player]
	return map ~= nil and map[key] == true
end

-- Extra: true once this session's gamepass lookup has finished (or given up), so join-time rewards that depend on
-- a pass (VIP offline earnings) can wait for it instead of reading an empty cache.
function MonetizationService.passesReady(player: Player): boolean
	return passesReady[player] == true
end

-- Extra: { [passKey]: boolean } for every key in Monetization.PassOrder.
function MonetizationService.getPasses(player: Player): { [string]: boolean }
	local out = {}
	for _, key in Monetization.PassOrder do
		out[key] = MonetizationService.hasPass(player, key)
	end
	return out
end

-- Extra (AdminService / Studio QA): force a pass on/off for this session only (nil clears the override).
function MonetizationService.setPassOverride(player: Player, key: string, value: boolean?)
	if not Monetization.Passes[key] then
		return
	end
	local before = MonetizationService.hasPass(player, key)
	local o = overrides[player]
	if not o then
		o = {}
		overrides[player] = o
	end
	o[key] = value
	local after = MonetizationService.hasPass(player, key)
	if before ~= after then
		applyPassAttributes(player)
		MonetizationService.PassChanged:Fire(player, key)
		DataService.markDirty(player)
	end
end

-- Register (or replace) the grant handler for a developer product key. Handler returns true when granted.
function MonetizationService.registerProduct(key: string, handler: ProductHandler)
	handlers[key] = handler
end

-- Extra: pending exclusive cars owed to a player whose garage was full (keys "<carId>" or "<carId>#<n>").
local function addPendingExclusive(data: any, carId: string)
	local key = carId
	local n = 1
	while data.exclusives[key] do
		n += 1
		key = carId .. "#" .. n
	end
	data.exclusives[key] = true
end

local delivering: { [Player]: boolean } = {}

-- Tries to deliver owed exclusive cars into free slots. Returns number delivered. Never runs twice at once
-- for the same player (prevents a double delivery if storeCar yields).
function MonetizationService.deliverExclusives(player: Player): number
	local data = DataService.get(player)
	if not data or not DataService.isLoaded(player) or delivering[player] then
		return 0
	end
	delivering[player] = true
	local delivered = 0
	local okLoop, loopErr = pcall(function()
		for key in table.clone(data.exclusives) do
			local carId = string.match(key, "^([^#]+)")
			if carId then
				local okFree, free = callSystem("GarageService", "freeSlots", player)
				if not okFree or typeof(free) ~= "number" or free <= 0 then
					break
				end
				local ok, stored = callSystem("GarageService", "storeCar", player, carId, "None")
				if ok and stored == true then
					data.exclusives[key] = nil
					data.discovered[carId] = true
					delivered += 1
					notify(player, "success", "💎 Your exclusive car just rolled into your garage!", 5)
					celebrate(player, "CashBig")
				else
					break
				end
			end
		end
	end)
	if not okLoop then
		warn("[Monetization] deliverExclusives: " .. tostring(loopErr))
	end
	delivering[player] = nil
	if delivered > 0 then
		DataService.markDirty(player)
	end
	return delivered
end

---------------------------------------------------------------------------------------------------------------
-- Built-in product handlers
---------------------------------------------------------------------------------------------------------------

local function grantCash(key: string): ProductHandler
	return function(player: Player): boolean
		local amount = MonetizationService._cashAmount(key, incomeOf(player))
		local newBalance = DataService.addCash(player, amount, "purchase")
		if newBalance == nil then
			return false
		end
		Net.fireClient("CashPopup", player, amount, rootPosition(player))
		notify(player, "money", "+" .. Format.cash(amount) .. " - thanks for supporting Hotwire City!", 4)
		celebrate(player, "CashBig")
		return true
	end
end

local function registerBuiltIns()
	MonetizationService.registerProduct("cash_small", grantCash("cash_small"))
	MonetizationService.registerProduct("cash_big", grantCash("cash_big"))

	MonetizationService.registerProduct("lock_10", function(player: Player): boolean
		local okIdx, index = callSystem("PlotService", "getPlotIndex", player)
		if not okIdx or typeof(index) ~= "number" then
			return false
		end
		local ok, res = callSystem("PlotService", "lockFor", index, Monetization.LOCKDOWN_DURATION)
		if not ok or res == false then
			return false
		end
		notify(player, "success", "🔒 LOCKDOWN! Your garage is sealed for 10 minutes.", 4)
		celebrate(player, "Purchase")
		return true
	end)

	MonetizationService.registerProduct("clear_wanted", function(player: Player): boolean
		-- never charge for nothing: with 0 stars the receipt stays NotProcessedYet (the Store disables the button)
		local okStars, stars = callSystem("WantedService", "getStars", player)
		if not okStars or typeof(stars) ~= "number" or stars <= 0 then
			notify(player, "info", "😇 You're not wanted right now - nothing to clear!", 4)
			return false
		end
		local ok = callSystem("WantedService", "clear", player, "purchase")
		if not ok then
			return false
		end
		notify(player, "success", "🚔 The cops lost your trail. You're clean!", 4)
		celebrate(player, "Purchase")
		return true
	end)

	MonetizationService.registerProduct("server_luck", function(player: Player): boolean
		local ok, res = callSystem("EventService", "activateServerLuck", player)
		if not ok or res == false then
			return false
		end
		celebrate(player, "Purchase")
		return true
	end)

	MonetizationService.registerProduct("diamond_dragster", function(player: Player): boolean
		local data = DataService.get(player)
		if not data then
			return false
		end
		-- one per account: refuse (never charge) while one is parked or still owed
		if MonetizationService._ownsExclusive(data, "diamond_dragster") then
			notify(player, "info", "💎 You already own the Diamond Dragster!", 4)
			return false
		end
		local ok, stored = callSystem("GarageService", "storeCar", player, "diamond_dragster", "None")
		if ok and stored == true then
			data.discovered.diamond_dragster = true
			notify(player, "success", "💎 The DIAMOND DRAGSTER is parked in your garage!", 5)
		else
			addPendingExclusive(data, "diamond_dragster")
			data.discovered.diamond_dragster = true
			notify(
				player,
				"warning",
				"💎 Diamond Dragster unlocked! Your garage is full - free a slot and it rolls in automatically.",
				7
			)
		end
		DataService.markDirty(player)
		celebrate(player, "CashBig")
		return true
	end)
end

---------------------------------------------------------------------------------------------------------------
-- ProcessReceipt
---------------------------------------------------------------------------------------------------------------

local function keyForProductId(productId: number): string?
	if productId == 0 then
		return nil
	end
	for key, def in Monetization.Products do
		if def.id == productId then
			return key
		end
	end
	return nil
end

local function keyForPassId(passId: number): string?
	if passId == 0 then
		return nil
	end
	for key, def in Monetization.Passes do
		if def.id == passId then
			return key
		end
	end
	return nil
end

local function processWhileLocked(player: Player, productId: number, purchaseId: string): Enum.ProductPurchaseDecision
	local data = DataService.get(player)
	if not data or not DataService.isLoaded(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local pending = unconfirmed[player]
	if not pending then
		pending = {}
		unconfirmed[player] = pending
	end

	local action = MonetizationService._receiptAction(data.receipts, purchaseId, pending)
	if action == "alreadyGranted" then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	elseif action == "confirmSave" then
		if DataService.saveNow(player) then
			pending[purchaseId] = nil
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local key = keyForProductId(productId)
	local handler = key and handlers[key]
	if not handler then
		warn(("[Monetization] no handler for product %d"):format(productId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local okGrant, granted = pcall(handler, player)
	if not okGrant then
		warn(("[Monetization] handler %s errored: %s"):format(tostring(key), tostring(granted)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if granted ~= true then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- the grant above mutated `data`; record the id in the same table so both persist atomically
	MonetizationService._recordReceipt(data.receipts, purchaseId, RECEIPT_CAP)
	pending[purchaseId] = true
	DataService.markDirty(player)

	if DataService.saveNow(player) then
		pending[purchaseId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	warn(("[Monetization] save after purchase %s failed; will confirm on redelivery"):format(purchaseId))
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function processReceipt(receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	local userId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local purchaseId = tostring(receiptInfo.PurchaseId)
	if typeof(userId) ~= "number" or typeof(productId) ~= "number" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not DataService.waitFor(player, 15) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if inFlight[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	inFlight[purchaseId] = true
	local ok, decision = pcall(processWhileLocked, player, productId, purchaseId)
	inFlight[purchaseId] = nil
	if not ok then
		warn("[Monetization] ProcessReceipt error: " .. tostring(decision))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return decision
end

MonetizationService._processReceipt = processReceipt
MonetizationService._processWhileLocked = processWhileLocked

---------------------------------------------------------------------------------------------------------------
-- Gamepasses
---------------------------------------------------------------------------------------------------------------

local function lookupPasses(player: Player)
	for _, key in Monetization.PassOrder do
		local id = MonetizationService.passIdFor(key)
		if id ~= 0 then
			local result: boolean? = nil
			for attempt = 1, 3 do
				local ok, has = pcall(function()
					return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
				end)
				if ok then
					result = has == true
					break
				end
				if player.Parent ~= Players then
					return
				end
				task.wait(attempt)
			end
			if player.Parent ~= Players then
				return
			end
			if result ~= nil then
				setOwned(player, key, result)
			end
		end
	end
	applyPassAttributes(player)
end

local function refreshPasses(player: Player)
	local ok, err = pcall(lookupPasses, player)
	if not ok then
		warn("[Monetization] pass lookup failed: " .. tostring(err))
	end
	-- always released (even on errors) so nothing waits on it forever
	passesReady[player] = true
end

local function onPlayerAdded(player: Player)
	if owned[player] then
		return
	end
	owned[player] = {}
	unconfirmed[player] = {}
	applyPassAttributes(player)
	task.spawn(refreshPasses, player)
	-- deliver exclusives owed from a previous session once data is in
	task.spawn(function()
		if DataService.waitFor(player, 60) then
			task.wait(3)
			if player.Parent == Players then
				MonetizationService.deliverExclusives(player)
			end
		end
	end)
end

local function onPlayerRemoving(player: Player)
	-- deferred: give in-flight receipts a moment, then drop caches
	task.delay(30, function()
		if player.Parent ~= Players then
			owned[player] = nil
			overrides[player] = nil
			unconfirmed[player] = nil
			delivering[player] = nil
		end
	end)
end

function MonetizationService.init()
	registerBuiltIns()
end

-- Live servers with unset (0) ids: say so once, so a release without the Creator Dashboard ids is noticed.
local function warnUnsetIds()
	if RunService:IsStudio() then
		return
	end
	local missing: { string } = {}
	for key, def in Monetization.Passes do
		if def.id == 0 then
			table.insert(missing, "pass:" .. key)
		end
	end
	for key, def in Monetization.Products do
		if def.id == 0 then
			table.insert(missing, "product:" .. key)
		end
	end
	if #missing > 0 then
		table.sort(missing)
		warn("[Monetization] id 0 (hidden, not purchasable): " .. table.concat(missing, ", "))
	end
end

function MonetizationService.start()
	MarketplaceService.ProcessReceipt = processReceipt
	warnUnsetIds()

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, wasPurchased: boolean)
			if not wasPurchased or typeof(passId) ~= "number" then
				return
			end
			local key = keyForPassId(passId)
			if not key or player.Parent ~= Players then
				return
			end
			setOwned(player, key, true)
			local def = Monetization.Passes[key]
			notify(player, "success", ("%s %s unlocked - thank you!"):format(def.icon, def.name), 5)
			celebrate(player, "Purchase")
		end
	)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- owed exclusive cars roll in as soon as a slot frees up
	while true do
		task.wait(EXCLUSIVE_CHECK_INTERVAL)
		for _, player in Players:GetPlayers() do
			local data = DataService.get(player)
			if data and DataService.isLoaded(player) and next(data.exclusives) ~= nil then
				task.spawn(MonetizationService.deliverExclusives, player)
			end
		end
	end
end

return MonetizationService
