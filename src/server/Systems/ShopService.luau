--!strict
-- ShopService (SPEC §6): the Gear Shop and the FREEDOM ARMS gun stores (gta_combat §5).
--   * ProximityPrompt "Gear Shop" on the counter part MapBuilder tags "GearShopCounter" -> OpenUI("GearShop").
--     (If no counter shows up within COUNTER_TIMEOUT seconds, a fallback counter is placed at
--     MapLayout.gearShopCounter() so the shop is always reachable.)
--   * BuyUpgrade(upgradeId): valid id, level < max, server price (EconomyMath.upgradePrice), spend.
--   * BuyTool(toolId): valid id, not owned, server price, spend, then CombatService.giveTools (lazy).
--   * Gun stores: a "FREEDOM ARMS" prompt on every part tagged "GunStoreCounter" (fallback counters at
--     MapLayout.gunStores()) -> OpenUI("GunShop"). BuyWeapon / BuyAmmo / BuyArmor / BuyMedKit / SetWeaponTint all
--     require the buyer to stand INSIDE a gun-store zone (MapLayout.safeZones kind "gunstore"), check ownership /
--     reserve caps / carry limits, and only then spend. Buying a rifle ends rookie protection.
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
local Weapons = require(Shared.Config.Weapons)

local ShopService = {}

ShopService.COUNTER_TAG = "GearShopCounter"
ShopService.GUN_COUNTER_TAG = "GunStoreCounter"
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
			notify(player, "error", `{def.name} is fully upgraded.`)
		end
		return false, priceOrReason :: string
	end
	local price = priceOrReason :: number
	if not DataService.spendCash(player, price) then
		notify(player, "error", `Not enough cash. {def.name} costs {Format.cash(price)}.`)
		return false, "cash"
	end
	data.upgrades[upgradeId] = level + 1
	DataService.markDirty(player)
	local maxed = level + 1 >= def.maxLevel
	notify(player, "success", `{def.name} upgraded to level {level + 1}{if maxed then " (max)" else ""}.`)
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
		notify(player, "error", `You already own the {def.name}.`)
		return false, "owned"
	end
	local ok, priceOrReason = ShopService._toolQuote(toolId, data.tools)
	if not ok then
		return false, priceOrReason :: string
	end
	local price = priceOrReason :: number
	if price > 0 and not DataService.spendCash(player, price) then
		notify(player, "error", `Not enough cash. The {def.name} costs {Format.cash(price)}.`)
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
	notify(player, "success", `You bought the {def.name}.`)
	Net.fireClient("Sound", player, "Purchase")
	return true, nil
end

---------------------------------------------------------------------------------------------------------------------
-- FREEDOM ARMS (gun stores)
---------------------------------------------------------------------------------------------------------------------

-- Pure (tested): the price of one weapon purchase. (ok, price | reason) reason: "invalid" | "owned" | "police"
function ShopService._weaponQuote(weaponId: any, owned: { [string]: any }?): (boolean, number | string)
	if not Net.isString(weaponId, 16) then
		return false, "invalid"
	end
	local def = Weapons.get(weaponId)
	if not def or def.id == "fists" then
		return false, "invalid"
	end
	if def.policeOnly then
		return false, "police"
	end
	if owned and owned[weaponId] ~= nil then
		return false, "owned"
	end
	return true, def.price
end

-- Pure (tested): rounds and price for an ammo purchase given the free reserve space. full = fill to the cap.
-- Returns (rounds, price); 0 rounds = nothing to buy.
function ShopService._ammoQuote(weaponId: string, space: number, full: boolean): (number, number)
	local def = Weapons.get(weaponId)
	if not def or not Weapons.isGun(def) or not def.ammoPerPurchase or not def.ammoPrice then
		return 0, 0
	end
	space = math.max(0, math.floor(space))
	if space <= 0 then
		return 0, 0
	end
	local per = def.ammoPerPurchase
	local boxes = if full then math.ceil(space / per) else 1
	local rounds = math.min(space, boxes * per)
	return rounds, boxes * def.ammoPrice
end

-- Is the player standing inside a gun-store zone?
function ShopService.inGunStore(player: Player): boolean
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	for _, z in MapLayout.safeZones() do
		if z.kind == "gunstore" and MapLayout.isInBox(z.cframe, z.size, root.Position) then
			return true
		end
	end
	return false
end

local function storeGate(player: Player): (any, any)
	if not ShopService.inGunStore(player) then
		notify(player, "error", "Step up to a FREEDOM ARMS counter.")
		return nil, nil
	end
	return getData(player)
end

local function weaponService(): any
	return sys("WeaponService")
end

function ShopService.buyWeapon(player: Player, weaponId: any): (boolean, string?)
	local data, DataService = storeGate(player)
	if not data then
		return false, "zone"
	end
	local ok, priceOrReason = ShopService._weaponQuote(weaponId, data.weapons)
	if not ok then
		if priceOrReason == "owned" then
			notify(player, "error", "You already own that.")
		end
		return false, priceOrReason :: string
	end
	local def = Weapons.get(weaponId) :: Weapons.WeaponDef
	local price = priceOrReason :: number
	local WeaponService = weaponService()
	if not WeaponService then
		return false, "unavailable"
	end
	if price > 0 and not DataService.spendCash(player, price) then
		notify(player, "error", `Not enough cash. The {def.name} costs {Format.cash(price)}.`)
		return false, "cash"
	end
	local okGive, given = pcall(WeaponService.giveWeapon, player, def.id, Weapons.FREE_MAGS_ON_BUY)
	if not okGive or given ~= true then
		DataService.addCash(player, price, "refund")
		return false, "error"
	end
	if def.class == "Rifle" then
		local Damage = sys("DamageService")
		if Damage and typeof(Damage.endRookie) == "function" then
			pcall(Damage.endRookie, player, "bought a rifle")
		end
	end
	DataService.markDirty(player)
	notify(player, "success", `{def.name} purchased. Two spare magazines included.`)
	Net.fireClient("Sound", player, "Purchase")
	return true, nil
end

function ShopService.buyAmmo(player: Player, weaponId: any, full: any): (boolean, string?)
	local data, DataService = storeGate(player)
	if not data or not Net.isString(weaponId, 16) then
		return false, "zone"
	end
	local WeaponService = weaponService()
	if not WeaponService or not WeaponService.owns(player, weaponId) then
		return false, "owned"
	end
	local space = WeaponService.reserveSpace(player, weaponId)
	local rounds, price = ShopService._ammoQuote(weaponId, space, full == true)
	if rounds <= 0 then
		notify(player, "error", "Ammo is full.")
		return false, "full"
	end
	if not DataService.spendCash(player, price) then
		notify(player, "error", `Not enough cash ({Format.cash(price)}).`)
		return false, "cash"
	end
	WeaponService.addAmmo(player, weaponId, rounds)
	DataService.markDirty(player)
	Net.fireClient("Sound", player, "Purchase")
	return true, nil
end

function ShopService.buyArmor(player: Player, armorId: any): (boolean, string?)
	local data, DataService = storeGate(player)
	if not data or not Net.isString(armorId, 16) then
		return false, "zone"
	end
	local def = Weapons.Armor[armorId]
	if not def then
		return false, "invalid"
	end
	local Damage = sys("DamageService")
	if not Damage then
		return false, "unavailable"
	end
	if (Damage.getArmor(player) or 0) >= 100 then
		notify(player, "error", "Your armor is full.")
		return false, "full"
	end
	if not DataService.spendCash(player, def.price) then
		notify(player, "error", `Not enough cash ({Format.cash(def.price)}).`)
		return false, "cash"
	end
	Damage.addArmor(player, def.amount)
	notify(player, "success", `{def.name} on.`)
	Net.fireClient("Sound", player, "Purchase")
	local WeaponService = weaponService()
	if WeaponService then
		WeaponService.pushState(player)
	end
	return true, nil
end

function ShopService.buyMedKit(player: Player): (boolean, string?)
	local data, DataService = storeGate(player)
	if not data then
		return false, "zone"
	end
	local def = Weapons.MedKit
	local have = tonumber(data.medkits) or 0
	if have >= def.carry then
		notify(player, "error", ("You can carry %d med kits."):format(def.carry))
		return false, "full"
	end
	if not DataService.spendCash(player, def.price) then
		notify(player, "error", `Not enough cash ({Format.cash(def.price)}).`)
		return false, "cash"
	end
	data.medkits = have + 1
	DataService.markDirty(player)
	Net.fireClient("Sound", player, "Purchase")
	local WeaponService = weaponService()
	if WeaponService then
		WeaponService.pushState(player)
	end
	return true, nil
end

function ShopService.setTint(player: Player, weaponId: any, tintId: any): (boolean, string?)
	local data, DataService = storeGate(player)
	if not data or not Net.isString(weaponId, 16) or not Net.isString(tintId, 16) then
		return false, "zone"
	end
	local tint = Weapons.Tints[tintId]
	local WeaponService = weaponService()
	if not tint or not WeaponService or not WeaponService.owns(player, weaponId) or weaponId == "fists" then
		return false, "invalid"
	end
	-- a tint is bought once per account (any weapon can wear it afterwards)
	data.tintsOwned = if typeof(data.tintsOwned) == "table" then data.tintsOwned else {}
	if tint.price > 0 and data.tintsOwned[tintId] ~= true then
		if not DataService.spendCash(player, tint.price) then
			notify(player, "error", `The {tint.name} tint costs {Format.cash(tint.price)}.`)
			return false, "cash"
		end
		data.tintsOwned[tintId] = true
	end
	WeaponService.setTint(player, weaponId, tintId)
	DataService.markDirty(player)
	Net.fireClient("Sound", player, "Purchase")
	return true, nil
end

---------------------------------------------------------------------------------------------------------------------
-- Counter prompts (Gear Shop + FREEDOM ARMS)
---------------------------------------------------------------------------------------------------------------------

type CounterKind = { tag: string, ui: string, action: string, object: string, promptName: string }

local GEAR: CounterKind = {
	tag = ShopService.COUNTER_TAG,
	ui = "GearShop",
	action = "Gear Shop",
	object = "Upgrades & Tools",
	promptName = "GearShopPrompt",
}
local GUNS: CounterKind = {
	tag = ShopService.GUN_COUNTER_TAG,
	ui = "GunShop",
	action = "Browse",
	object = "FREEDOM ARMS",
	promptName = "GunShopPrompt",
}

local prompted: { [BasePart]: ProximityPrompt } = {}
local promptedKind: { [BasePart]: CounterKind } = {}
local fallbacks: { [CounterKind]: { BasePart } } = { [GEAR] = {}, [GUNS] = {} }

local function count(kind: CounterKind): number
	local n = 0
	for part, k in promptedKind do
		if k == kind and not table.find(fallbacks[kind], part) then
			n += 1
		end
	end
	return n
end

local destroyFallback: (BasePart) -> ()

local function addPrompt(part: Instance, kind: CounterKind)
	if not part:IsA("BasePart") or prompted[part] then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = kind.promptName
	prompt.ActionText = kind.action
	prompt.ObjectText = kind.object
	prompt.HoldDuration = 0
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.MaxActivationDistance = ShopService.PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(player: Player)
		if player.Parent ~= Players then
			return
		end
		Net.fireClient("OpenUI", player, kind.ui)
		Net.fireClient("Sound", player, "Click")
	end)
	prompt.Parent = part
	prompted[part] = prompt
	promptedKind[part] = kind
	part.AncestryChanged:Connect(function()
		if not part:IsDescendantOf(game) then
			prompted[part] = nil
			promptedKind[part] = nil
		end
	end)
	local list = fallbacks[kind]
	if #list > 0 and not table.find(list, part) then
		-- a real counter arrived late: drop the fallbacks
		for _, fb in list do
			prompted[fb] = nil
			promptedKind[fb] = nil
			destroyFallback(fb)
		end
		table.clear(list)
	end
end

local function effectsFolder(): Instance
	local folder = Workspace:FindFirstChild("Effects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Effects"
		folder.Parent = Workspace
	end
	return folder :: Instance
end

-- Fallback store counter (only when the map tagged none; job 0006: it was a bare black block by the road). A model that
-- reads as a shop counter from the street: walnut counter with a dark stone top and a glass display front, a plaster
-- back wall with a steel rack, a plain lit sign (no neon) and a cloth awning. The prompt sits on the "Counter" part.
-- `cf` is the counter's front-centre 3 studs above the sidewalk, LookVector toward the street (MapLayout spots).
ShopService.FALLBACK_SIGN = { guns = "FREEDOM ARMS", gear = "AUTO PARTS AND TOOLS" }

-- (name, size, offset from the ground point, colour, material, transparency, canCollide) of every fallback piece
-- (pure, tested). Local axes: +Z is behind the counter (away from the street), +Y up.
function ShopService._counterPieces(): { { any } }
	local function rgb(r: number, g: number, b: number): Color3
		return Color3.fromRGB(r, g, b)
	end
	local M = Enum.Material
	return {
		{ "Counter", Vector3.new(10, 3.4, 2.4), Vector3.new(0, 1.7, 0), rgb(92, 68, 50), M.Wood, 0, true },
		{ "Top", Vector3.new(10.4, 0.25, 2.8), Vector3.new(0, 3.525, 0), rgb(40, 40, 42), M.Slate, 0, false },
		{
			"Display",
			Vector3.new(9.4, 1.6, 0.15),
			Vector3.new(0, 2.35, -1.22),
			rgb(176, 196, 206),
			M.Glass,
			0.55,
			false,
		},
		{ "Kick", Vector3.new(10, 0.5, 0.1), Vector3.new(0, 0.25, -1.24), rgb(30, 30, 32), M.Metal, 0, false },
		{ "Wall", Vector3.new(14, 9, 0.6), Vector3.new(0, 4.5, 4.4), rgb(190, 182, 166), M.Plaster, 0, true },
		{ "Rack", Vector3.new(9, 3, 0.2), Vector3.new(0, 5.4, 3.98), rgb(62, 64, 68), M.DiamondPlate, 0, false },
		{ "Sign", Vector3.new(8, 1.5, 0.3), Vector3.new(0, 7.9, 3.95), rgb(26, 26, 28), M.SmoothPlastic, 0, false },
		{ "Awning", Vector3.new(14, 0.25, 4.2), Vector3.new(0, 9.1, 2.3), rgb(112, 30, 30), M.Fabric, 0, false },
	}
end

local function makeCounter(name: string, cf: CFrame, signText: string): Part
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("HC_FallbackCounter", true)
	local ground = cf * CFrame.new(0, -3, 0)
	local counter: Part? = nil
	local sign: Part? = nil
	for _, piece in ShopService._counterPieces() do
		local part = Instance.new("Part")
		part.Name = piece[1]
		part.Size = piece[2]
		part.CFrame = ground * CFrame.new(piece[3])
		part.Color = piece[4]
		part.Material = piece[5]
		part.Transparency = piece[6]
		part.CanCollide = piece[7]
		part.Anchored = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		if piece[1] == "Counter" then
			counter = part
		elseif piece[1] == "Sign" then
			sign = part
		end
	end
	if sign then
		-- printed sign, lit by the world (LightInfluence 1): it never glows like the v1 neon boards
		local gui = Instance.new("SurfaceGui")
		gui.Name = "SignGui"
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 1
		local text = Instance.new("TextLabel")
		text.BackgroundTransparency = 1
		text.Size = UDim2.fromScale(0.92, 0.8)
		text.Position = UDim2.fromScale(0.04, 0.1)
		text.Text = signText
		text.TextScaled = true
		text.TextColor3 = Color3.fromRGB(236, 232, 224)
		text.FontFace = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.SemiBold)
		text.Parent = gui
		gui.Parent = sign
	end
	local main = counter :: Part
	model.PrimaryPart = main
	model.Parent = effectsFolder()
	return main
end

-- A fallback counter part goes away with its whole model.
function destroyFallback(part: BasePart)
	local model = part.Parent
	if model and model:IsA("Model") and model:GetAttribute("HC_FallbackCounter") == true then
		model:Destroy()
	else
		part:Destroy()
	end
end

local function makeFallbacks(kind: CounterKind)
	if kind == GEAR then
		local part = makeCounter(
			"GearShopCounterFallback",
			MapLayout.gearShopCounter() * CFrame.new(0, 3, 0),
			ShopService.FALLBACK_SIGN.gear
		)
		table.insert(fallbacks[GEAR], part)
		addPrompt(part, GEAR)
	else
		for _, store in MapLayout.gunStores() do
			local part = makeCounter(store.name .. "CounterFallback", store.cframe, ShopService.FALLBACK_SIGN.guns)
			table.insert(fallbacks[GUNS], part)
			addPrompt(part, GUNS)
		end
	end
end

local function on(name: string, rate: number, fn: (Player, ...any) -> ())
	Net.on(name, fn, rate)
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
	on("BuyWeapon", 3, function(player: Player, weaponId: any)
		if Net.isString(weaponId, 16) then
			ShopService.buyWeapon(player, weaponId)
		end
	end)
	on("BuyAmmo", 6, function(player: Player, weaponId: any, full: any)
		if Net.isString(weaponId, 16) and (full == nil or typeof(full) == "boolean") then
			ShopService.buyAmmo(player, weaponId, full)
		end
	end)
	on("BuyArmor", 3, function(player: Player, armorId: any)
		if Net.isString(armorId, 16) then
			ShopService.buyArmor(player, armorId)
		end
	end)
	on("BuyMedKit", 3, function(player: Player)
		ShopService.buyMedKit(player)
	end)
	on("SetWeaponTint", 3, function(player: Player, weaponId: any, tintId: any)
		if Net.isString(weaponId, 16) and Net.isString(tintId, 16) then
			ShopService.setTint(player, weaponId, tintId)
		end
	end)
end

function ShopService.start()
	for _, kind in { GEAR, GUNS } do
		CollectionService:GetInstanceAddedSignal(kind.tag):Connect(function(part: Instance)
			addPrompt(part, kind)
		end)
		for _, part in CollectionService:GetTagged(kind.tag) do
			addPrompt(part, kind)
		end
	end
	-- MapBuilder tags the counters in init(); wait briefly in case the map is still building.
	local deadline = os.clock() + ShopService.COUNTER_TIMEOUT
	while (count(GEAR) == 0 or count(GUNS) == 0) and os.clock() < deadline do
		task.wait(1)
		for _, kind in { GEAR, GUNS } do
			for _, part in CollectionService:GetTagged(kind.tag) do
				addPrompt(part, kind)
			end
		end
	end
	if count(GEAR) == 0 then
		warn("[ShopService] no part tagged GearShopCounter; placing a fallback counter")
		makeFallbacks(GEAR)
	end
	if count(GUNS) == 0 then
		warn("[ShopService] no part tagged GunStoreCounter; placing fallback FREEDOM ARMS counters (MapLayout)")
		makeFallbacks(GUNS)
	end
end

return ShopService
