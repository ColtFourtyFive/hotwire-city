--!strict
-- DealershipService (SPEC §6): the showroom at MapLayout.poiCenter("Dealership").
--
--  * 8 turntable pads (MapLayout.dealerPads()) each show one rolled car (Rolls.car("dealer", luck) +
--    Rolls.mutation(1)). The whole floor restocks every RESTOCK_INTERVAL; a pad emptied by a sale/theft refills
--    after PAD_RESTOCK seconds (or at the global restock, whichever comes first).
--  * Display cars: CarBuilder.build(..., { forDisplay = true }) in Workspace.Dealership, chassis anchored (every
--    other part is welded to it so clients can spin the whole car by moving the chassis), tag "DealerCar",
--    attributes CarId / Mutation / Price / Rarity / PadIndex / Income / RestockAt (Workspace:GetServerTimeNow()).
--  * Prompts in the chassis: BuyPrompt ("Buy $X", hold 0.5) -> spend first, storeCar, refund on failure;
--    StealPrompt ("Steal", hold = hotwireTime * DEALER_STEAL_HOLD_MULTIPLIER, scaled by the thief's hotwire
--    multiplier) -> display removed, drivable "Loot" car spawned on the pad, thief seated, +dealerSteal heat.
--  * Mythic/Secret stock is announced server-wide (Announce + EventFeed + a temporary Waypoint).
--  * A big countdown sign ("NEW STOCK IN m:ss") stands behind the back row.
--
-- Pure helpers (_price, _stealHold, _padRestockAt, _rollStock, ...) and the harness-compatible builders
-- (buildShowroom, buildDisplay) are exposed for tests / tools.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local EconomyMath = require(Shared.Util.EconomyMath)
local Format = require(Shared.Util.Format)
local MapLayout = require(Shared.Util.MapLayout)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local PoliceConfig = require(Shared.Config.Police)
local Rarity = require(Shared.Config.Rarity)
local Rolls = require(Shared.Util.Rolls)

local DealershipService = {}

DealershipService.RESTOCK_INTERVAL = 240
DealershipService.PAD_RESTOCK = 30
DealershipService.BUY_HOLD = 0.5
DealershipService.PROMPT_DISTANCE = 14
DealershipService.REACH = 24 -- server-side max distance from the pad center for buy/steal
DealershipService.TURNTABLE_DIAMETER = 19
DealershipService.TURNTABLE_HEIGHT = 0.35
DealershipService.RARE_WAYPOINT_SECONDS = 45
DealershipService.SAVE_NOW_PRICE = 50000 -- purchases at least this expensive force a save
DealershipService.SIGN_OFFSET = Vector3.new(0, 0, 41) -- from the showroom center (behind the back row)
DealershipService.SIGN_SIZE = Vector3.new(34, 10, 0.8)
DealershipService.SIGN_BOTTOM = 9 -- studs above the floor

DealershipService._rng = Random.new()

local PINK = Color3.fromRGB(255, 52, 140)
local CYAN = Color3.fromRGB(0, 214, 255)
local NAVY = Color3.fromRGB(28, 31, 58)
local DISC = Color3.fromRGB(34, 36, 58)
local WAYPOINT_ID = "dealer_rare"

-- Injectable dependencies -------------------------------------------------------------------------------------------

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
		warn(("[DealershipService] could not load %s: %s"):format(name, tostring(mod)))
	end
	return nil
end

local carBuilder: any = nil
local function getCarBuilder(): any
	if carBuilder then
		return carBuilder
	end
	local folder = Shared:FindFirstChild("Vehicle")
	local mod = folder and folder:FindFirstChild("CarBuilder")
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	if ok then
		carBuilder = res
		return res
	end
	warn("[DealershipService] CarBuilder failed to load: " .. tostring(res))
	return nil
end

local hooks = {
	clock = os.clock,
	serverNow = function(): number
		return Workspace:GetServerTimeNow()
	end,
	system = loadSystem,
}

function DealershipService._setHooks(overrides: { [string]: any })
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
		warn(("[DealershipService] %s.%s errored: %s"):format(name, fn, tostring(res)))
		return false, nil
	end
	return true, res
end

local function notify(player: Player, kind: string, text: string)
	pcall(Net.fireClient, "Notify", player, kind, text)
end

local function fireClient(name: string, player: Player, ...: any)
	pcall(Net.fireClient, name, player, ...)
end

local function fireAll(name: string, ...: any)
	pcall(Net.fireAll, name, ...)
end

local function fireNear(name: string, pos: Vector3, radius: number, ...: any)
	pcall(Net.fireNear, name, pos, radius, ...)
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

-- A readable color for banners / rich text (Secret's swatch is near-black).
local function showColor(rarity: string): Color3
	if rarity == "Secret" then
		return Color3.fromRGB(255, 80, 210)
	end
	local tier = Rarity.Tiers[rarity :: any]
	return if tier then tier.color else Color3.new(1, 1, 1)
end

local function richCar(carId: string, mutation: string): string
	local def = Cars.get(carId)
	local color = showColor(if def then def.rarity else "Common")
	return `<font color="#{hex(color)}"><b>{richEscape(carLabel(carId, mutation))}</b></font>`
end

local function rarityOrder(carId: string): number
	local def = Cars.get(carId)
	local tier = def and Rarity.Tiers[def.rarity]
	return if tier then tier.order else 1
end

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------------------------------------------------

-- Dealer price = catalog price * mutation multiplier (so buy -> sell can never be profitable: sell is 50% of this).
function DealershipService._price(carId: string, mutation: string): number
	local def = Cars.get(carId)
	if not def then
		return 0
	end
	return math.floor(def.price * Rarity.getMutation(mutation :: any).multiplier)
end

-- Base StealPrompt hold before the thief's hotwire multiplier.
function DealershipService._stealHold(carId: string): number
	local def = Cars.get(carId)
	local tier = def and Rarity.Tiers[def.rarity]
	return (if tier then tier.hotwireTime else 1) * Economy.DEALER_STEAL_HOLD_MULTIPLIER
end

-- When a pad emptied at `now` refills: PAD_RESTOCK later, or at the global restock if that comes first.
function DealershipService._padRestockAt(now: number, nextGlobal: number): number
	return math.min(now + DealershipService.PAD_RESTOCK, nextGlobal)
end

-- Next global restock after one at `now`.
function DealershipService._nextGlobal(now: number): number
	return now + DealershipService.RESTOCK_INTERVAL
end

-- Seconds until a deadline as "m:ss" (never negative).
function DealershipService._countdown(deadline: number, now: number): string
	return Format.clock(math.max(0, math.ceil(deadline - now)))
end

export type StockEntry = { carId: string, mutation: Rarity.MutationId }

-- Rolls `count` cars for the floor. Avoids duplicate car ids (vs. each other and `taken`) when it can; with
-- ensureCheap, a full restock always offers at least one Common so new players can buy something.
function DealershipService._rollStock(
	count: number,
	luck: number,
	rng: Random,
	taken: { [string]: boolean }?,
	ensureCheap: boolean?
): { StockEntry }
	local out: { StockEntry } = {}
	local used: { [string]: boolean } = if taken then table.clone(taken) else {}
	for _ = 1, count do
		local def = Rolls.car("dealer", luck, rng)
		for _ = 1, 5 do
			if not used[def.id] then
				break
			end
			def = Rolls.car("dealer", luck, rng)
		end
		used[def.id] = true
		table.insert(out, { carId = def.id, mutation = Rolls.mutation(1, rng) })
	end
	if ensureCheap and count >= 4 then
		local hasCommon = false
		local cheapest, cheapestPrice = 1, math.huge
		for i, e in out do
			local def = Cars.get(e.carId)
			if def and def.rarity == "Common" then
				hasCommon = true
				break
			end
			local p = DealershipService._price(e.carId, e.mutation)
			if p < cheapestPrice then
				cheapest, cheapestPrice = i, p
			end
		end
		if not hasCommon then
			-- replace the cheapest roll so a lucky Mythic is never thrown away
			local def = Rolls.carOfRarity("Common", "dealer", rng)
			out[cheapest] = { carId = def.id, mutation = "None" }
		end
	end
	return out
end

-- "announce" = Announce banner + feed + waypoint; "feed" = event feed line only; "none".
function DealershipService._hype(carId: string, mutation: string): string
	local def = Cars.get(carId)
	if not def then
		return "none"
	end
	if def.rarity == "Mythic" or def.rarity == "Secret" then
		return "announce"
	end
	local order = rarityOrder(carId)
	local mut = Rarity.getMutation(mutation :: any)
	if order >= 5 or (order >= 4 and mut.order >= 4) then
		return "feed"
	end
	return "none"
end

---------------------------------------------------------------------------------------------------------------------
-- Builders (harness-compatible: pure instance construction)
---------------------------------------------------------------------------------------------------------------------

local function part(props: { [string]: any }): BasePart
	local className = props.ClassName or "Part"
	local p = Instance.new(className) :: any
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		if k ~= "ClassName" and k ~= "Parent" then
			p[k] = v
		end
	end
	if props.Parent then
		p.Parent = props.Parent
	end
	return p
end

local function vertical(pos: Vector3): CFrame
	-- Cylinder axis is local X; rotate it to world Y.
	return CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
end

local function signLabel(parent: Instance, name: string, text: string, pos: UDim2, size: UDim2, color: Color3)
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.BackgroundTransparency = 1
	lbl.Position = pos
	lbl.Size = size
	lbl.Text = text
	lbl.TextScaled = true
	lbl.TextColor3 = color
	lbl.FontFace = Font.fromEnum(Enum.Font.FredokaOne)
	lbl.RichText = true
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(10, 11, 22)
	stroke.Thickness = 4
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = lbl
	lbl.Parent = parent
	return lbl
end

-- Builds the countdown sign (board + neon frame + posts) standing on the floor at `base` (facing its LookVector).
function DealershipService.buildSign(parent: Instance, base: CFrame): BasePart
	local size = DealershipService.SIGN_SIZE
	local bottom = DealershipService.SIGN_BOTTOM
	local model = Instance.new("Model")
	model.Name = "RestockSign"
	local center = base * CFrame.new(0, bottom + size.Y / 2, 0)
	local board = part({
		Name = "Board",
		Size = size,
		CFrame = center,
		Color = NAVY,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = true,
		CanQuery = true,
		Parent = model,
	})
	-- neon frame
	local t = 0.5
	local frame = {
		{ Vector3.new(size.X + t * 2, t, size.Z + 0.2), Vector3.new(0, size.Y / 2 + t / 2, 0), PINK },
		{ Vector3.new(size.X + t * 2, t, size.Z + 0.2), Vector3.new(0, -size.Y / 2 - t / 2, 0), PINK },
		{ Vector3.new(t, size.Y, size.Z + 0.2), Vector3.new(size.X / 2 + t / 2, 0, 0), CYAN },
		{ Vector3.new(t, size.Y, size.Z + 0.2), Vector3.new(-size.X / 2 - t / 2, 0, 0), CYAN },
	}
	for i, f in frame do
		part({
			Name = "Frame" .. i,
			Size = f[1],
			CFrame = center * CFrame.new(f[2]),
			Color = f[3],
			Material = Enum.Material.Neon,
			Parent = model,
		})
	end
	-- posts
	for i, x in { -size.X / 2 + 3, size.X / 2 - 3 } do
		part({
			Name = "Post" .. i,
			Size = Vector3.new(1.2, bottom, 1.2),
			CFrame = base * CFrame.new(x, bottom / 2, 0.8),
			Color = Color3.fromRGB(60, 64, 96),
			Material = Enum.Material.Metal,
			CanCollide = true,
			Parent = model,
		})
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Display"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 36
	gui.LightInfluence = 0
	gui.MaxDistance = 400
	gui.Parent = board
	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = NAVY
	bg.BorderSizePixel = 0
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.fromRGB(70, 40, 120), Color3.fromRGB(20, 22, 44))
	grad.Rotation = 90
	grad.Parent = bg
	bg.Parent = gui
	signLabel(bg, "Title", "🚗 HOTWIRE MOTORS", UDim2.fromScale(0.04, 0.03), UDim2.fromScale(0.92, 0.27), PINK)
	signLabel(
		bg,
		"Countdown",
		"NEW STOCK IN 4:00",
		UDim2.fromScale(0.04, 0.31),
		UDim2.fromScale(0.92, 0.4),
		Color3.new(1, 1, 1)
	)
	signLabel(
		bg,
		"Subtitle",
		"BUY IT... OR STEAL IT 😈",
		UDim2.fromScale(0.08, 0.74),
		UDim2.fromScale(0.84, 0.2),
		CYAN
	)
	model.PrimaryPart = board
	model.Parent = parent
	return board
end

-- Builds the 8 turntables (+ neon rims) and the countdown sign into `parent`. `floorYs[i]` overrides the floor
-- height under pad i (runtime raycasts the map; tools/tests pass nothing). Returns (turntables, signBoard).
function DealershipService.buildShowroom(parent: Instance, floorYs: { number }?): ({ BasePart }, BasePart)
	local pads = MapLayout.dealerPads()
	local tables: { BasePart } = {}
	local h = DealershipService.TURNTABLE_HEIGHT
	local d = DealershipService.TURNTABLE_DIAMETER
	for i, padCf in pads do
		local y = if floorYs and floorYs[i] then floorYs[i] else padCf.Position.Y
		local pos = Vector3.new(padCf.Position.X, y, padCf.Position.Z)
		local disc = part({
			Name = "Turntable" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(h, d, d),
			CFrame = vertical(pos + Vector3.new(0, h / 2, 0)),
			Color = DISC,
			Material = Enum.Material.SmoothPlastic,
			Reflectance = 0.15,
			CanCollide = true,
			CanQuery = true,
			Parent = parent,
		})
		disc:SetAttribute("PadIndex", i)
		disc:SetAttribute("Empty", true)
		disc:SetAttribute("Status", "")
		disc:SetAttribute("RestockAt", 0)
		disc:SetAttribute("TopY", y + h)
		part({
			Name = "Rim" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(h * 0.6, d + 1.4, d + 1.4),
			CFrame = vertical(pos + Vector3.new(0, h * 0.3, 0)),
			Color = if i % 2 == 0 then CYAN else PINK,
			Material = Enum.Material.Neon,
			Parent = disc,
		})
		table.insert(tables, disc)
	end
	local c = MapLayout.poiCenter("Dealership")
	local floor = if floorYs and floorYs[1] then floorYs[1] else c.Y
	local signPos = Vector3.new(c.X, floor, c.Z) + DealershipService.SIGN_OFFSET
	local board = DealershipService.buildSign(parent, CFrame.lookAt(signPos, signPos + Vector3.new(0, 0, -1)))
	return tables, board
end

-- Builds one anchored display car standing on `topCf` (turntable top, facing the street). Chassis anchored, the
-- rest welded to it; collidable chassis so players can't walk through. No prompts (see attachPrompts).
function DealershipService.buildDisplay(carId: string, mutation: string, topCf: CFrame): Model?
	local CB = getCarBuilder()
	if not CB or not Cars.get(carId) then
		return nil
	end
	local ok, model = pcall(CB.build, carId, mutation, { forDisplay = true })
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn(("[DealershipService] CarBuilder.build(%s) failed: %s"):format(carId, tostring(model)))
		return nil
	end
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not chassis or not chassis:IsA("BasePart") then
		model:Destroy()
		return nil
	end
	model.PrimaryPart = chassis
	local ride = model:GetAttribute("RideHeight")
	model:PivotTo(topCf * CFrame.new(0, if typeof(ride) == "number" then ride else 2, 0))
	chassis.Anchored = true
	chassis.CanCollide = true
	for _, desc in model:GetDescendants() do
		if desc:IsA("VehicleSeat") or desc:IsA("Seat") then
			(desc :: any).Disabled = true
		end
	end
	local def = Cars.get(carId) :: Cars.CarDef
	model.Name = "Dealer_" .. carId
	model:SetAttribute("CarId", carId)
	model:SetAttribute("Mutation", mutation)
	model:SetAttribute("Rarity", def.rarity)
	model:SetAttribute("Price", DealershipService._price(carId, mutation))
	model:SetAttribute("Income", EconomyMath.carIncome(carId, mutation :: any))
	return model
end

---------------------------------------------------------------------------------------------------------------------
-- Runtime state
---------------------------------------------------------------------------------------------------------------------

type Pad = {
	index: number,
	cframe: CFrame, -- turntable top, facing the street (-Z)
	turntable: BasePart?,
	model: Model?,
	carId: string?,
	mutation: string?,
	price: number,
	restockAt: number, -- clock time an EMPTY pad refills
	buyHolds: { [Player]: number },
	stealHolds: { [Player]: number },
	waypointUntil: number, -- > 0 while a rare-stock waypoint is live
}

local folder: Folder? = nil
local pads: { Pad } = {}
local nextGlobal = 0
local signBoard: BasePart? = nil
local signText = ""
local signLuck = ""

local function toServer(clockTime: number): number
	return hooks.serverNow() + (clockTime - hooks.clock())
end

local function getLuck(): number
	local ok, luck = call("EventService", "getLuck")
	if ok and typeof(luck) == "number" and luck == luck then
		return math.clamp(luck, 1, 100)
	end
	return 1
end

local function rootOf(player: Player): (BasePart?, Humanoid?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	return if root and root:IsA("BasePart") then root else nil, hum
end

local function holdMultiplier(player: Player): number
	local _, data = call("DataService", "get", player)
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

local function isDriving(player: Player, hum: Humanoid?): boolean
	if player:GetAttribute("Driving") == true or (hum ~= nil and hum.SeatPart ~= nil) then
		return true
	end
	local ok, car = call("VehicleService", "getDriving", player)
	return ok and car ~= nil
end

local function setTurntable(pad: Pad, empty: boolean, status: string)
	local tt = pad.turntable
	if not tt then
		return
	end
	tt:SetAttribute("Empty", empty)
	tt:SetAttribute("Status", status)
	tt:SetAttribute("RestockAt", if empty then toServer(pad.restockAt) else toServer(nextGlobal))
	tt:SetAttribute("CarId", pad.carId or "")
end

local function clearWaypoint(pad: Pad)
	if pad.waypointUntil > 0 then
		pad.waypointUntil = 0
		fireAll("Waypoint", WAYPOINT_ID .. pad.index, nil)
	end
end

-- Removes the display car. status "sold"/"stolen" empties the pad for PAD_RESTOCK; nil = being replaced.
local function clearPad(pad: Pad, status: string?, now: number)
	local model = pad.model
	pad.model = nil
	table.clear(pad.buyHolds)
	table.clear(pad.stealHolds)
	if model then
		model:Destroy()
	end
	clearWaypoint(pad)
	if status then
		pad.carId = nil
		pad.mutation = nil
		pad.price = 0
		pad.restockAt = DealershipService._padRestockAt(now, nextGlobal)
		setTurntable(pad, true, status)
	end
end

local function makePrompt(
	name: string,
	action: string,
	object: string,
	hold: number,
	key: Enum.KeyCode,
	pad: Enum.KeyCode,
	offset: Vector2
): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.Name = name
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = hold
	pp.KeyboardKeyCode = key
	pp.GamepadKeyCode = pad
	pp.RequiresLineOfSight = false
	pp.MaxActivationDistance = DealershipService.PROMPT_DISTANCE
	pp.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	pp.UIOffset = offset
	return pp
end

local function nearPad(player: Player, pad: Pad): (boolean, Humanoid?)
	local root, hum = rootOf(player)
	if not root or not hum or hum.Health <= 0 then
		return false, nil
	end
	return (root.Position - pad.cframe.Position).Magnitude <= DealershipService.REACH, hum
end

-- Buy -----------------------------------------------------------------------------------------------------------------

local function onBuy(player: Player, pad: Pad, model: Model)
	local began = pad.buyHolds[player]
	pad.buyHolds[player] = nil
	local carId, mutation = pad.carId, pad.mutation
	if pad.model ~= model or not carId or not mutation then
		return
	end
	if not began or hooks.clock() - began < DealershipService.BUY_HOLD * 0.8 then
		return
	end
	local near = nearPad(player, pad)
	if not near then
		return
	end
	local DS = sys("DataService")
	local GS = sys("GarageService")
	if not DS or not GS or typeof(GS.storeCar) ~= "function" then
		notify(player, "error", "The Dealership is closed right now.")
		return
	end
	local _, data = call("DataService", "get", player)
	if not data then
		notify(player, "error", "Still loading. Try again in a sec!")
		return
	end
	local _, free = call("GarageService", "freeSlots", player)
	if typeof(free) ~= "number" or free <= 0 then
		notify(player, "error", "📦 Your garage is full! Sell a car first.")
		fireClient("Sound", player, "Click")
		return
	end
	local price = pad.price
	local _, paid = call("DataService", "spendCash", player, price)
	if paid ~= true then
		local cash = if typeof(data.cash) == "number" then data.cash else 0
		notify(player, "error", `💸 You need {Format.cash(math.max(0, price - cash))} more!`)
		fireClient("Sound", player, "Click")
		return
	end
	local okStore, stored, slotOrReason = pcall(GS.storeCar, player, carId, mutation)
	if not okStore or stored ~= true then
		call("DataService", "addCash", player, price, "refund")
		warn(("[DealershipService] storeCar failed for %s: %s"):format(player.Name, tostring(slotOrReason)))
		notify(player, "error", "Couldn't park it, so you got a refund.")
		return
	end

	local pos = pad.cframe.Position + Vector3.new(0, 4, 0)
	clearPad(pad, "sold", hooks.clock())
	local _, isNew = call("GarageService", "discover", player, carId)
	call("RewardsService", "progress", player, "dealerBuy", 1)
	call("DataService", "markDirty", player)
	if price >= DealershipService.SAVE_NOW_PRICE and typeof(DS.saveNow) == "function" then
		task.spawn(pcall, DS.saveNow, player)
	end
	local label = carLabel(carId, mutation)
	local _, mult = call("GarageService", "multiplier", player)
	local income = EconomyMath.carIncome(carId, mutation :: any) * (if typeof(mult) == "number" then mult else 1)
	notify(
		player,
		"success",
		`🚗 {if isNew == true then "NEW! " else ""}{label} is parked in your garage! +{Format.cash(income)}/s`
	)
	fireClient("Sound", player, "Purchase", pos)
	fireNear("Effect", pos, 150, "Confetti", { position = pos })
	if rarityOrder(carId) >= 4 then
		fireAll("EventFeed", `🛒 <b>{richEscape(player.DisplayName)}</b> bought a {richCar(carId, mutation)}!`)
	end
end

-- Steal ---------------------------------------------------------------------------------------------------------------

local function onSteal(player: Player, pad: Pad, model: Model)
	local began = pad.stealHolds[player]
	pad.stealHolds[player] = nil
	local carId, mutation = pad.carId, pad.mutation
	if pad.model ~= model or not carId or not mutation then
		return
	end
	local required = DealershipService._stealHold(carId) * holdMultiplier(player) * 0.9
	if not began or hooks.clock() - began < required then
		return
	end
	local near, hum = nearPad(player, pad)
	if not near then
		return
	end
	if player:GetAttribute("Stunned") == true then
		return
	end
	if isDriving(player, hum) then
		notify(player, "error", "Hop out of your car first!")
		return
	end
	local _, active = call("TheftService", "getActiveTheft", player)
	if active ~= nil then
		notify(player, "error", "Finish your current heist first!")
		return
	end
	local _, data = call("DataService", "get", player)
	if not data then
		notify(player, "error", "Still loading. Try again in a sec!")
		return
	end
	local VS = sys("VehicleService")
	if not VS or typeof(VS.spawn) ~= "function" then
		notify(player, "error", "Stealing is offline right now.")
		return
	end

	local ground = pad.cframe
	clearPad(pad, "stolen", hooks.clock())
	local okSpawn, car = pcall(VS.spawn, carId, mutation, ground, "Loot", { source = "dealer", thief = player })
	if not okSpawn or type(car) ~= "table" or car.model == nil then
		warn("[DealershipService] VehicleService.spawn failed: " .. tostring(car))
		notify(player, "error", "The car wouldn't start! Try another one.")
		return
	end
	car.data = if type(car.data) == "table" then car.data else {}
	car.data.source = "dealer"
	car.data.dealerPad = pad.index
	car.data.stolenBy = player.UserId
	local seatOk = call("VehicleService", "seat", car, player)
	if not seatOk then
		warn("[DealershipService] VehicleService.seat failed for " .. player.Name)
	end
	call("WantedService", "addHeat", player, PoliceConfig.Heat.dealerSteal, "dealerSteal")
	call("RewardsService", "progress", player, "steal", 1)

	local label = carLabel(carId, mutation)
	local pos = ground.Position + Vector3.new(0, 3, 0)
	notify(player, "warning", `🚨 GRAND THEFT AUTO! Lose the cops and drive the {label} home!`)
	local _, free = call("GarageService", "freeSlots", player)
	if typeof(free) == "number" and free <= 0 then
		notify(player, "info", "📦 Your garage is full: sell a car first, or chop this one at the Chop Shop!")
	end
	fireNear("Sound", pos, 180, "GlassBreak", pos)
	fireClient("Sound", player, "PeelOut", pos)
	if rarityOrder(carId) >= 5 then
		fireNear("Effect", pos, 250, "BigSteal", { position = pos, text = "HEIST!" })
	end
	fireAll(
		"EventFeed",
		`🚨 <b>{richEscape(player.DisplayName)}</b> robbed the Dealership: {richCar(carId, mutation)}!`
	)
end

-- Stock -----------------------------------------------------------------------------------------------------------

local function attachPrompts(pad: Pad, model: Model, chassis: BasePart)
	local carId = pad.carId :: string
	local mutation = pad.mutation :: string
	local label = carLabel(carId, mutation)
	local buy = makePrompt(
		"BuyPrompt",
		"Buy " .. Format.cash(pad.price),
		label,
		DealershipService.BUY_HOLD,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonX,
		Vector2.zero
	)
	buy.PromptButtonHoldBegan:Connect(function(p: Player)
		pad.buyHolds[p] = hooks.clock()
	end)
	buy.Triggered:Connect(function(p: Player)
		local ok, err = pcall(onBuy, p, pad, model)
		if not ok then
			warn("[DealershipService] buy failed: " .. tostring(err))
		end
	end)
	buy.Parent = chassis

	local base = DealershipService._stealHold(carId)
	local steal = makePrompt(
		"StealPrompt",
		"Steal",
		`🚨 Wanted +{PoliceConfig.Heat.dealerSteal}★`,
		base,
		Enum.KeyCode.F,
		Enum.KeyCode.ButtonY,
		Vector2.new(0, 84)
	)
	steal:SetAttribute("BaseHold", base)
	steal:SetAttribute("BaseHoldDuration", base)
	steal.PromptButtonHoldBegan:Connect(function(p: Player)
		pad.stealHolds[p] = hooks.clock()
	end)
	steal.Triggered:Connect(function(p: Player)
		local ok, err = pcall(onSteal, p, pad, model)
		if not ok then
			warn("[DealershipService] steal failed: " .. tostring(err))
		end
	end)
	steal.Parent = chassis
end

local function hypeStock(pad: Pad, now: number)
	local carId, mutation = pad.carId, pad.mutation
	if not carId or not mutation then
		return
	end
	local hype = DealershipService._hype(carId, mutation)
	if hype == "none" then
		return
	end
	local def = Cars.get(carId) :: Cars.CarDef
	local label = carLabel(carId, mutation)
	local article = if string.find("AEIOU", string.upper(string.sub(label, 1, 1)), 1, true) then "An" else "A"
	if hype == "announce" then
		local rarityWord = string.upper(def.rarity)
		local mutWord = Rarity.getMutation(mutation :: any).label
		local name = if mutWord ~= "" then `{mutWord} {def.name}` else def.name
		local color = showColor(def.rarity)
		fireAll(
			"Announce",
			`💎 {rarityWord} AT THE DEALERSHIP!`,
			`A {rarityWord} {name} just hit the Dealership!`,
			color,
			"AirHorn"
		)
		fireAll(
			"EventFeed",
			`💎 A <b>{rarityWord}</b> {richCar(carId, mutation)} just hit the Dealership! Buy it... or steal it!`
		)
		pad.waypointUntil = now + DealershipService.RARE_WAYPOINT_SECONDS
		fireAll(
			"Waypoint",
			WAYPOINT_ID .. pad.index,
			pad.cframe.Position + Vector3.new(0, 6, 0),
			color,
			rarityWord .. " CAR"
		)
	else
		fireAll("EventFeed", `✨ {article} {richCar(carId, mutation)} just rolled into the Dealership!`)
	end
end

local function placeCar(pad: Pad, entry: StockEntry, announce: boolean)
	local parent = folder
	if not parent then
		return
	end
	local model = DealershipService.buildDisplay(entry.carId, entry.mutation, pad.cframe)
	if not model then
		pad.carId = nil
		pad.mutation = nil
		pad.restockAt = DealershipService._padRestockAt(hooks.clock(), nextGlobal)
		setTurntable(pad, true, "")
		return
	end
	local chassis = model.PrimaryPart :: BasePart
	pad.carId = entry.carId
	pad.mutation = entry.mutation
	pad.price = DealershipService._price(entry.carId, entry.mutation)
	pad.model = model
	model:SetAttribute("PadIndex", pad.index)
	model:SetAttribute("RestockAt", toServer(nextGlobal))
	model:SetAttribute("StealHold", DealershipService._stealHold(entry.carId))
	CollectionService:AddTag(model, "DealerCar")
	attachPrompts(pad, model, chassis)
	model.Parent = parent
	-- Anything not welded to the chassis (shouldn't happen) is anchored so it can never fall through the floor.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= chassis then
			local okRoot, root = pcall(function()
				return d.AssemblyRootPart
			end)
			if okRoot and root ~= chassis then
				d.Anchored = true
			end
		end
	end
	setTurntable(pad, false, "")
	if announce then
		hypeStock(pad, hooks.clock())
	end
end

local function currentIds(except: Pad?): { [string]: boolean }
	local ids: { [string]: boolean } = {}
	for _, pad in pads do
		if pad ~= except and pad.carId then
			ids[pad.carId] = true
		end
	end
	return ids
end

local function restockAll(announce: boolean)
	local now = hooks.clock()
	nextGlobal = DealershipService._nextGlobal(now)
	local stock = DealershipService._rollStock(#pads, getLuck(), DealershipService._rng, nil, true)
	for i, pad in pads do
		clearPad(pad, nil, now)
		pad.carId = nil
		local entry = stock[i]
		if entry then
			placeCar(pad, entry, announce)
		end
	end
	if announce then
		fireAll("EventFeed", "🚗 <b>NEW STOCK</b> at the Dealership!")
	end
end

local function restockPad(pad: Pad, announce: boolean)
	local stock = DealershipService._rollStock(1, getLuck(), DealershipService._rng, currentIds(pad), false)
	local entry = stock[1]
	if entry then
		placeCar(pad, entry, announce)
	end
end

-- Sign -------------------------------------------------------------------------------------------------------------

local function updateSign(now: number)
	local board = signBoard
	if not board then
		return
	end
	local text = "NEW STOCK IN " .. DealershipService._countdown(nextGlobal, now)
	local luck = getLuck()
	local luckText = if luck > 1.01 then `🍀 LUCK x{math.floor(luck * 10 + 0.5) / 10}: RARE CARS BOOSTED!` else ""
	if text == signText and luckText == signLuck then
		return
	end
	local display = board:FindFirstChild("Display")
	local bg = display and display:FindFirstChild("Background")
	if not bg then
		return
	end
	if text ~= signText then
		signText = text
		local lbl = bg:FindFirstChild("Countdown")
		if lbl and lbl:IsA("TextLabel") then
			lbl.Text = text
		end
	end
	if luckText ~= signLuck then
		signLuck = luckText
		local sub = bg:FindFirstChild("Subtitle")
		if sub and sub:IsA("TextLabel") then
			sub.Text = if luckText ~= "" then luckText else "BUY IT... OR STEAL IT 😈"
			sub.TextColor3 = if luckText ~= "" then Color3.fromRGB(110, 255, 120) else CYAN
		end
	end
	board:SetAttribute("RestockAt", toServer(nextGlobal))
end

-- Floor height under a pad: the top of whatever Workspace.Map has there (MapBuilder ran first), else curb height.
local function floorAt(padCf: CFrame, params: RaycastParams?): number
	local base = padCf.Position.Y
	if not params then
		return base
	end
	local origin = padCf.Position + Vector3.new(0, 6, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -14, 0), params)
	if hit then
		return math.clamp(hit.Position.Y, base - 0.5, base + 3)
	end
	return base
end

---------------------------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------------------------

-- Extra: read-only view of the floor for other systems (tutorial arrows, admin).
function DealershipService.getStock(): { { padIndex: number, carId: string?, mutation: string?, price: number } }
	local out = {}
	for _, pad in pads do
		table.insert(out, { padIndex = pad.index, carId = pad.carId, mutation = pad.mutation, price = pad.price })
	end
	return out
end

-- Extra: seconds until the next full restock.
function DealershipService.secondsToRestock(): number
	return math.max(0, nextGlobal - hooks.clock())
end

-- Extra (admin / events): reroll the whole floor now.
function DealershipService.forceRestock(announce: boolean?)
	if folder then
		restockAll(announce ~= false)
	end
end

function DealershipService.init()
	local existing = Workspace:FindFirstChild("Dealership")
	local f: Folder
	if existing and existing:IsA("Folder") then
		f = existing
	else
		f = Instance.new("Folder")
		f.Name = "Dealership"
		f.Parent = Workspace
	end
	folder = f

	local params: RaycastParams? = nil
	local map = Workspace:FindFirstChild("Map")
	if map then
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Include
		rp.FilterDescendantsInstances = { map }
		params = rp
	end
	local floorYs: { number } = {}
	local padCfs = MapLayout.dealerPads()
	for i, cf in padCfs do
		floorYs[i] = floorAt(cf, params)
	end
	local tables, board = DealershipService.buildShowroom(f, floorYs)
	signBoard = board
	table.clear(pads)
	for i, cf in padCfs do
		local top = floorYs[i] + DealershipService.TURNTABLE_HEIGHT
		local pos = Vector3.new(cf.Position.X, top, cf.Position.Z)
		table.insert(pads, {
			index = i,
			cframe = CFrame.lookAt(pos, pos + cf.LookVector),
			turntable = tables[i],
			model = nil,
			carId = nil,
			mutation = nil,
			price = 0,
			restockAt = 0,
			buyHolds = {},
			stealHolds = {},
			waypointUntil = 0,
		})
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		for _, pad in pads do
			pad.buyHolds[player] = nil
			pad.stealHolds[player] = nil
		end
	end)
end

function DealershipService.start()
	if not folder then
		return
	end
	local okFirst, errFirst = pcall(restockAll, false)
	if not okFirst then
		warn("[DealershipService] initial stock failed: " .. tostring(errFirst))
	end
	while true do
		task.wait(0.25)
		local ok, err = pcall(function()
			local now = hooks.clock()
			if now >= nextGlobal then
				restockAll(true)
			else
				for _, pad in pads do
					if not pad.model and now >= pad.restockAt then
						restockPad(pad, true)
					elseif pad.waypointUntil > 0 and now >= pad.waypointUntil then
						clearWaypoint(pad)
					end
				end
			end
			updateSign(now)
		end)
		if not ok then
			warn("[DealershipService] tick failed: " .. tostring(err))
		end
	end
end

return DealershipService
