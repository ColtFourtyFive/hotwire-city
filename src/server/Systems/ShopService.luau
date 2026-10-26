--!strict
-- ShopService (SPEC §6): the Gear Shop.
--   * ProximityPrompt "Gear Shop" on the counter part MapBuilder tags "GearShopCounter" -> OpenUI("GearShop").
--     (If no counter shows up within COUNTER_TIMEOUT seconds, a fallback counter is placed at
--     MapLayout.gearShopCounter() so the shop is always reachable.)
--   * BuyUpgrade(upgradeId): valid id, level < max, server price (EconomyMath.upgradePrice), spend.
--   * BuyTool(toolId): valid id, not owned, server price, spend, then CombatService.giveTools (lazy).
-- The client only ever sends ids; prices/levels/ownership come from server state.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Economy = require(Shared.Config.Economy)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local MapLayout = require(Shared.Util.MapLayout)
local Net = require(Shared.Net)

local ShopService = {}

ShopService.COUNTER_TAG = "GearShopCounter"
ShopService.COUNTER_TIMEOUT = 30
ShopService.PROMPT_DISTANCE = 14

-- Lazy system access -----------------------------------------------------------------------------------------------
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
	warn(("[ShopService] could not load %s: %s"):format(name, tostring(mod)))
	return nil
end

-- Test seam: replace a system module seen by sys(). Never used at runtime.
function ShopService._inject(name: string, mod: any)
	systemCache[name] = mod
end

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
---------------------------------------------------------------------------------------------------------------------

-- (ok, price | reason). reason: "invalid" | "maxed"
function ShopService._upgradeQuote(upgradeId: any, level: any): (boolean, number | string)
	if not Net.isString(upgradeId, 24) then
		return false, "invalid"
	end
	local def = Economy.Upgrades[upgradeId]
	if not def or def.id ~= upgradeId then
		return false, "invalid"
	end
	local lvl = if typeof(level) == "number" and level == level then math.max(0, math.floor(level)) else 0
	local price = EconomyMath.upgradePrice(upgradeId, lvl)
	if not price then
		return false, "maxed"
	end
	return true, price
end

-- (ok, price | reason). reason: "invalid" | "owned"
function ShopService._toolQuote(toolId: any, owned: { [string]: boolean }?): (boolean, number | string)
	if not Net.isString(toolId, 24) then
		return false, "invalid"
	end
	local def = Economy.Tools[toolId]
	if not def or def.id ~= toolId then
		return false, "invalid"
	end
	if owned and owned[toolId] then
		return false, "owned"
	end
	return true, def.price
end

---------------------------------------------------------------------------------------------------------------------
-- Purchases
---------------------------------------------------------------------------------------------------------------------

local function notify(player: Player, kind: string, text: string)
	Net.fireClient("Notify", player, kind, text)
end

local function getData(player: Player): (any, any)
	local DataService = sys("DataService")
	if not DataService or not DataService.isLoaded(player) then
		return nil, nil
	end
	return DataService.get(player), DataService
end

local function hasPass(player: Player, key: string): boolean
	local Monet = sys("MonetizationService")
	if not Monet or typeof(Monet.hasPass) ~= "function" then
		return false
	end
	local ok, owned = pcall(Monet.hasPass, player, key)
	return ok and owned == true
end

function ShopService.buyUpgrade(player: Player, upgradeId: any): (boolean, string?)
	local data, DataService = getData(player)
	if not data then
		return false, "loading"
	end
	if not Net.isString(upgradeId, 24) or not Economy.Upgrades[upgradeId] then
		return false, "invalid"
	end
	data.upgrades = data.upgrades or {}
	local level = data.upgrades[upgradeId] or 0
	local ok, priceOrReason = ShopService._upgradeQuote(upgradeId, level)
	local def = Economy.Upgrades[upgradeId]
	if not ok then
		if priceOrReason == "maxed" then
			notify(player, "error", `{def.name} is already MAXED! ⭐`)
		end
		return false, priceOrReason :: string
	end
	local price = priceOrReason :: number
	if not DataService.spendCash(player, price) then
		notify(player, "error", `Not enough cash! {def.name} costs {Format.cash(price)}`)
		return false, "cash"
	end
	data.upgrades[upgradeId] = level + 1
	DataService.markDirty(player)
	local maxed = level + 1 >= def.maxLevel
	notify(player, "success", `⬆️ {def.name} upgraded to Lv.{level + 1}{if maxed then " (MAX)" else ""}!`)
	Net.fireClient("Sound", player, "Purchase")
	return true, nil
end

function ShopService.buyTool(player: Player, toolId: any): (boolean, string?)
	local data, DataService = getData(player)
	if not data then
		return false, "loading"
	end
	if not Net.isString(toolId, 24) or not Economy.Tools[toolId] then
		return false, "invalid"
	end
	data.tools = data.tools or {}
	local def = Economy.Tools[toolId]
	local owned = data.tools[toolId] == true or (toolId == "taser" and hasPass(player, "taser"))
	if owned then
		notify(player, "error", `You already own the {def.name}!`)
		return false, "owned"
	end
	local ok, priceOrReason = ShopService._toolQuote(toolId, data.tools)
	if not ok then
		return false, priceOrReason :: string
	end
	local price = priceOrReason :: number
	if price > 0 and not DataService.spendCash(player, price) then
		notify(player, "error", `Not enough cash! The {def.name} costs {Format.cash(price)}`)
		return false, "cash"
	end
	data.tools[toolId] = true
	DataService.markDirty(player)
	local Combat = sys("CombatService")
	if Combat and typeof(Combat.giveTools) == "function" then
		local okGive, err = pcall(Combat.giveTools, player)
		if not okGive then
			warn("[ShopService] CombatService.giveTools failed: " .. tostring(err))
		end
	end
	notify(player, "success", `🛠️ You got the {def.name}! Check your backpack.`)
	Net.fireClient("Sound", player, "Purchase")
	return true, nil
end

---------------------------------------------------------------------------------------------------------------------
-- Counter prompt
---------------------------------------------------------------------------------------------------------------------

local prompted: { [BasePart]: ProximityPrompt } = {}
local fallbackCounter: BasePart? = nil

local function addPrompt(part: Instance)
	if not part:IsA("BasePart") or prompted[part] then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GearShopPrompt"
	prompt.ActionText = "Gear Shop"
	prompt.ObjectText = "🛠️ Upgrades & Tools"
	prompt.HoldDuration = 0
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.MaxActivationDistance = ShopService.PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(player: Player)
		if player.Parent ~= Players then
			return
		end
		Net.fireClient("OpenUI", player, "GearShop")
		Net.fireClient("Sound", player, "Click")
	end)
	prompt.Parent = part
	prompted[part] = prompt
	part.AncestryChanged:Connect(function()
		if not part:IsDescendantOf(game) then
			prompted[part] = nil
		end
	end)
	if fallbackCounter and part ~= fallbackCounter then
		-- the real counter arrived late: drop the fallback
		local fb = fallbackCounter
		fallbackCounter = nil
		prompted[fb] = nil
		fb:Destroy()
	end
end

local function makeFallbackCounter()
	local cf = MapLayout.gearShopCounter()
	local part = Instance.new("Part")
	part.Name = "GearShopCounterFallback"
	part.Size = Vector3.new(10, 4, 3)
	part.CFrame = cf * CFrame.new(0, 2, 0)
	part.Anchored = true
	part.CanCollide = true
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromRGB(255, 52, 140)
	local folder = Workspace:FindFirstChild("Effects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Effects"
		folder.Parent = Workspace
	end
	part.Parent = folder
	fallbackCounter = part
	addPrompt(part)
end

function ShopService.init()
	Net.on("BuyUpgrade", function(player: Player, upgradeId: any)
		if not Net.isString(upgradeId, 24) then
			return
		end
		ShopService.buyUpgrade(player, upgradeId)
	end, 3)
	Net.on("BuyTool", function(player: Player, toolId: any)
		if not Net.isString(toolId, 24) then
			return
		end
		ShopService.buyTool(player, toolId)
	end, 3)
end

function ShopService.start()
	CollectionService:GetInstanceAddedSignal(ShopService.COUNTER_TAG):Connect(addPrompt)
	for _, part in CollectionService:GetTagged(ShopService.COUNTER_TAG) do
		addPrompt(part)
	end
	-- MapBuilder tags the counter in init(); wait briefly in case the map is still building.
	local deadline = os.clock() + ShopService.COUNTER_TIMEOUT
	while next(prompted) == nil and os.clock() < deadline do
		task.wait(1)
		for _, part in CollectionService:GetTagged(ShopService.COUNTER_TAG) do
			addPrompt(part)
		end
	end
	if next(prompted) == nil then
		warn("[ShopService] no part tagged GearShopCounter; placing a fallback counter")
		makeFallbackCounter()
	end
end

return ShopService
