--!strict
-- GarageClient: everything garage-related that differs per viewer.
--   * own laser gate is non-collidable locally (and tinted cyan) so the owner walks/drives through their lock
--   * Drive/Sell prompts only for the owner; Steal only for others when the owner is robbable (>= newbie cars,
--     not locked) and the server wouldn't refuse anyway (victim already being robbed, victim's RobbableAt
--     protection, your own garage full): the billboard says why instead (F7). StealPrompt.HoldDuration scaled
--     locally by the player's HoldMultiplier attribute
--   * billboards above display cars (name in rarity color, rarity + mutation pills, $/s, owner's uncollected $),
--     built only once their garage comes within TAG_NEAR of the camera and disabled while it is far (PERF-12)
--   * pad visuals from server pad attributes (lock + price, next unlock, STOLEN!/OUT states) + "Unlock $X" prompt;
--     +2 Slots pass pads read "MAX SLOTS" while the pass isn't on sale (id 0)
--   * collect pad glow pulse + floating total while the owner has uncollected cash
--   * LOCK button / countdown pill (touch friendly) while inside your garage or while it's locked (stacked above
--     HUDController's HOME button outside); hidden in streamer mode (HUDController.VisibilityChanged); flashes
--     "LOCK NOW!" for a few seconds after the plot's IntruderAt stamp (someone started hotwiring, F3)
-- The server re-checks everything; this module is presentation only.
-- Public: getLockTop() (design px of the pill's top edge while it shows; TutorialController stacks above it).
-- Pure helpers (tests): _freeSlots, _stealBlock, _lockedPadLabel, _tagsNear, _intruderFlash, _lockTop.

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared: any = ReplicatedStorage:WaitForChild("Shared")
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local Format = require(Shared.Util.Format)
local MapLayout = require(Shared.Util.MapLayout)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local Rarity = require(Shared.Config.Rarity)
local Trove = require(Shared.Util.Trove)

local UI: any = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local StateController = require(script.Parent:WaitForChild("StateController"))

local player = Players.LocalPlayer

local GarageClient = {}

local OWN_LASER = Color3.fromRGB(0, 214, 255) -- your own lock reads "friendly" (and lets you through)
local LOCK_BOTTOM = 112 -- design px from the screen bottom to the LOCK pill's bottom edge (at least)
local LOCK_HEIGHT = 58 -- design px
local INTRUDER_FLASH = 6 -- seconds the LOCK pill flashes after the server's IntruderAt stamp (someone hotwiring)
local TAG_NEAR = 150 -- studs (camera -> garage interior center) within which a plot's car billboards exist / show
local PULSE = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BOB = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

type PlotView = {
	model: Model,
	index: number,
	trove: any,
	gate: BasePart?,
	pads: { BasePart },
}

type CollectFx = {
	index: number,
	trove: any,
	light: PointLight,
	billboard: BillboardGui,
	amount: TextLabel,
	tweens: { Tween },
	active: boolean,
	signAmount: TextLabel?,
}

local views: { [number]: PlotView } = {}
local displayTroves: { [Model]: any } = {}
-- PERF-12: a display car's billboard is built only once its garage is near the camera, and disabled while it is far
local pendingTags: { [Model]: BasePart } = {} -- chassis of display cars whose billboard waits for their plot
local tagGuis: { [Model]: BillboardGui } = {}
local tagNear: { [number]: boolean } = {} -- plot index -> its billboards are enabled
local plotCenters: { [number]: Vector3 | false } = {}
local unlockPrompts: { [BasePart]: ProximityPrompt } = {}
local padPulses: { [BasePart]: Tween } = {}
local collectFx: CollectFx? = nil

local lockButton: TextButton? = nil
local lockScreen: ScreenGui? = nil
local lockState = "hidden"
local lockPulseAt = 0 -- os.clock() of the last intruder flash pop
local hudHidden = false -- streamer mode (HUDController)
local freeSlots: number? = nil -- my free garage slots from the snapshot (nil = unknown)

-- helpers ----------------------------------------------------------------------------------------------------------

local function num(v: any, default: number): number
	return if typeof(v) == "number" and v == v then v else default
end

local function myIndex(): number?
	local v = player:GetAttribute("PlotIndex")
	return if typeof(v) == "number" then v else nil
end

local function isMine(view: PlotView): boolean
	return view.model:GetAttribute("OwnerUserId") == player.UserId
end

local function setText(lbl: Instance?, text: string, color: Color3?)
	if lbl and lbl:IsA("TextLabel") then
		lbl.Text = text
		if color then
			lbl.TextColor3 = color
		end
	end
end

-- Sibling controller, required lazily (nil if missing or it fails to load).
local function controller(name: string): any
	local inst = script.Parent:FindFirstChild(name)
	if not inst or not inst:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, inst :: any)
	return if ok then mod else nil
end

-- Pure helpers (tests) -------------------------------------------------------------------------------------------------

-- Free garage slots from the local snapshot, mirroring GarageService.freeSlots (nil = no snapshot yet).
function GarageClient._freeSlots(snapshot: any): number?
	if typeof(snapshot) ~= "table" or typeof(snapshot.garage) ~= "table" then
		return nil
	end
	local unlocked = math.clamp(num(snapshot.slotsUnlocked, Economy.START_SLOTS), 0, Economy.MAX_SLOTS)
	local extra = math.max(0, num(snapshot.maxSlots, Economy.MAX_SLOTS) - Economy.MAX_SLOTS)
	local capacity = math.min(unlocked + extra, MapLayout.maxPhysicalSlots())
	local free = 0
	for slot = 1, capacity do
		if snapshot.garage[tostring(slot)] == nil then
			free += 1
		end
	end
	return free
end

-- Why the server would refuse a steal from a robbable garage (same order as TheftService._canSteal), or nil.
-- robbableAt / now are Workspace:GetServerTimeNow() times; freeSlots nil = unknown (never blocks).
function GarageClient._stealBlock(busy: boolean, robbableAt: number, now: number, slots: number?): string?
	if busy then
		return "🚨 BEING ROBBED"
	elseif robbableAt > now then
		return "🛡️ PROTECTED " .. Format.clock(math.ceil(robbableAt - now))
	elseif slots ~= nil and slots <= 0 then
		return "📦 YOUR GARAGE IS FULL"
	end
	return nil
end

-- Locked pad label: (icon, text, Theme.Colors key). Pass pads advertise the +2 Slots pass only while it is on sale
-- (id ~= 0); otherwise they read MAX SLOTS, never a dead-end offer (DECISIONS #11).
function GarageClient._lockedPadLabel(
	passOnly: boolean,
	passOnSale: boolean,
	mine: boolean,
	nextUnlock: boolean,
	price: number
): (string, string, string)
	if passOnly then
		if passOnSale then
			return "🅿️", "+2 SLOTS PASS", "Gold"
		end
		return "🔒", "MAX SLOTS", "TextDim"
	elseif mine and nextUnlock then
		return "🔓", "UNLOCK " .. Format.cash(price), "Cash"
	elseif mine and price > 0 then
		return "🔒", Format.cash(price), "Warning"
	end
	return "🔒", "LOCKED", "Danger"
end

-- PERF-12: does a garage's car billboards need to exist / show? The camera is within `radius` of the garage interior
-- center (unknown camera or garage -> yes).
function GarageClient._tagsNear(camPos: Vector3?, center: Vector3?, radius: number): boolean
	if not camPos or not center then
		return true
	end
	return (camPos - center).Magnitude <= radius
end

-- Is the LOCK pill flashing for an intruder? intruderAt / now are Workspace:GetServerTimeNow() times.
function GarageClient._intruderFlash(intruderAt: number, now: number): boolean
	return intruderAt > 0 and now >= intruderAt - 1 and now - intruderAt < INTRUDER_FLASH
end

-- Design px from the screen bottom to the LOCK pill's top edge while it shows (nil when hidden).
function GarageClient._lockTop(visible: boolean, bottomOffset: number): number?
	if not visible then
		return nil
	end
	return bottomOffset + LOCK_HEIGHT
end

-- Gate --------------------------------------------------------------------------------------------------------------

local function applyGate(view: PlotView)
	local gate = view.gate
	-- only the owner overrides anything locally; everyone else sees the server's gate untouched
	if not gate or gate.Parent == nil or not isMine(view) then
		return
	end
	if gate.CanCollide then
		gate.CanCollide = false
	end
	if gate.Color ~= OWN_LASER then
		gate.Color = OWN_LASER
	end
	for _, child in gate:GetChildren() do
		if child:IsA("BasePart") then
			child.CanCollide = false
			if child.Color ~= OWN_LASER then
				child.Color = OWN_LASER
			end
		end
	end
end

-- Display car prompts -----------------------------------------------------------------------------------------------

-- Is one of this garage's cars being stolen right now (pad State "BeingStolen")?
local function plotBusy(view: PlotView): boolean
	for _, pad in view.pads do
		if pad:GetAttribute("State") == "BeingStolen" then
			return true
		end
	end
	return false
end

-- Shows (or hides) why a car can't be stolen right now, on its billboard (non-owners only).
local function setStealBlock(chassis: Instance, block: string?)
	local tag = chassis:FindFirstChild("GarageTag")
	local lbl = tag and tag:FindFirstChild("StealBlock")
	if not lbl or not lbl:IsA("TextLabel") then
		return
	end
	local show = block ~= nil
	if lbl.Visible ~= show then
		lbl.Visible = show
	end
	if block and lbl.Text ~= block then
		lbl.Text = block
	end
end

local function updatePrompts(model: Model)
	local chassis = model:FindFirstChild("Chassis")
	if not chassis then
		return
	end
	local mine = model:GetAttribute("OwnerUserId") == player.UserId
	local driving = player:GetAttribute("Driving") == true
	local drive = chassis:FindFirstChild("DrivePrompt")
	local sell = chassis:FindFirstChild("SellPrompt")
	local steal = chassis:FindFirstChild("StealPrompt")
	if drive and drive:IsA("ProximityPrompt") then
		drive.Enabled = mine and not driving
	end
	if sell and sell:IsA("ProximityPrompt") then
		sell.Enabled = mine and not driving
	end
	if steal and steal:IsA("ProximityPrompt") then
		-- no view yet (plots still loading) reads as 0 cars: setupPlot re-runs this once the view exists
		local view = views[num(model:GetAttribute("PlotIndex"), 0)]
		local cars = if view then num(view.model:GetAttribute("CarCount"), 0) else 0
		local locked = view ~= nil and view.model:GetAttribute("Locked") == true
		local robbable = not mine and not driving and not locked and cars >= Economy.NEWBIE_PROTECTION_CARS
		local block: string? = nil
		if robbable and view then
			local robbableAt = num(view.model:GetAttribute("RobbableAt"), 0)
			block = GarageClient._stealBlock(plotBusy(view), robbableAt, Workspace:GetServerTimeNow(), freeSlots)
		end
		steal.Enabled = robbable and block == nil
		setStealBlock(chassis, block)
		local base = num(steal:GetAttribute("BaseHold"), steal.HoldDuration)
		local mult = num(player:GetAttribute("HoldMultiplier"), 1)
		if mult <= 0 then
			mult = 1
		end
		local want = base * mult
		if math.abs(steal.HoldDuration - want) > 1e-3 then
			steal.HoldDuration = want
		end
	end
end

local function updatePlotPrompts(view: PlotView)
	local display = view.model:FindFirstChild("Display")
	if not display then
		return
	end
	for _, m in display:GetChildren() do
		if m:IsA("Model") then
			updatePrompts(m)
		end
	end
end

local function updateAllPrompts()
	for model in displayTroves do
		updatePrompts(model)
	end
end

-- Display car billboards ----------------------------------------------------------------------------------------------

local function pill(parent: Instance, text: string, color: Color3, order: number): Frame
	local f = Kit.new("Frame", {
		Name = "Pill" .. order,
		BackgroundColor3 = color,
		Size = UDim2.fromScale(0.36, 1),
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.corner(UDim.new(0.5, 0)).Parent = f
	Kit.stroke(Theme.Colors.Stroke, 2).Parent = f
	local lbl = Kit.label(text, 14, {
		Name = "Text",
		Size = UDim2.fromScale(0.9, 0.86),
		Position = UDim2.fromScale(0.05, 0.07),
		TextScaled = true,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 22, Parent = lbl })
	lbl.Parent = f
	return f
end

local function plotCenter(index: number): Vector3?
	local c = plotCenters[index]
	if c == nil then
		local ok, cf = pcall(MapLayout.plotInteriorZone, index)
		c = if ok then (cf :: CFrame).Position else false
		plotCenters[index] = c
	end
	return if c then c else nil
end

local function cameraPosition(): Vector3?
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else nil
end

-- Billboards for this plot's cars should exist / show (cached per plot by refreshTags; computed on first use).
local function tagsNearPlot(index: number): boolean
	local near = tagNear[index]
	if near == nil then
		near = GarageClient._tagsNear(cameraPosition(), plotCenter(index), TAG_NEAR)
		tagNear[index] = near
	end
	return near
end

local function buildBillboard(model: Model, chassis: BasePart, trove: any)
	local carId = model:GetAttribute("CarId")
	local def = if typeof(carId) == "string" then Cars.get(carId) else nil
	if not def then
		return
	end
	local tier = Rarity.Tiers[def.rarity]
	local mutId = model:GetAttribute("Mutation")
	local mut = Rarity.getMutation(if typeof(mutId) == "string" then mutId :: any else "None")
	local ride = num(model:GetAttribute("RideHeight"), 2)
	local height = model:GetExtentsSize().Y
	local rarityColor = if tier then tier.color else Theme.Colors.Text
	local dark = rarityColor.R + rarityColor.G + rarityColor.B < 0.5

	local bb = Kit.new("BillboardGui", {
		Name = "GarageTag",
		Adornee = chassis,
		Size = UDim2.fromScale(9, 4.6),
		StudsOffsetWorldSpace = Vector3.new(0, height - ride + 2.6, 0),
		AlwaysOnTop = false,
		MaxDistance = 80,
		LightInfluence = 0,
		ResetOnSpawn = false,
	})
	local nameLbl = Kit.label(def.name, 28, {
		Name = "CarName",
		Size = UDim2.fromScale(1, 0.3),
		Position = UDim2.fromScale(0, 0),
		TextScaled = true,
		TextColor3 = rarityColor,
	})
	if dark then
		local stroke = nameLbl:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = Color3.new(1, 1, 1)
		end
	end
	Kit.new("UITextSizeConstraint", { MaxTextSize = 44, Parent = nameLbl })
	nameLbl.Parent = bb

	local tags = Kit.new("Frame", {
		Name = "Tags",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.2),
		Position = UDim2.fromScale(0, 0.31),
		Parent = bb,
	})
	Kit.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		tags
	pill(tags, string.upper(def.rarity), rarityColor, 1)
	if mut.id ~= "None" then
		local p = pill(tags, mut.label, mut.color or Color3.new(1, 1, 1), 2)
		if mut.id == "Rainbow" then
			Kit.new("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 60)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 235, 110)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(60, 160, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 80, 255)),
				}),
				Parent = p,
			})
		end
	end

	local incomeLbl = Kit.label("", 26, {
		Name = "Income",
		Size = UDim2.fromScale(1, 0.25),
		Position = UDim2.fromScale(0, 0.52),
		TextScaled = true,
		TextColor3 = Theme.Colors.Cash,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 40, Parent = incomeLbl })
	incomeLbl.Parent = bb
	local uncLbl = Kit.label("", 22, {
		Name = "Uncollected",
		Size = UDim2.fromScale(1, 0.22),
		Position = UDim2.fromScale(0, 0.78),
		TextScaled = true,
		TextColor3 = Theme.Colors.Gold,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 34, Parent = uncLbl })
	uncLbl.Parent = bb
	-- non-owners: why the Steal prompt is off (same row as the owner-only uncollected line)
	local blockLbl = Kit.label("", 22, {
		Name = "StealBlock",
		Size = UDim2.fromScale(1, 0.22),
		Position = UDim2.fromScale(0, 0.78),
		TextScaled = true,
		TextColor3 = Theme.Colors.Warning,
		Visible = false,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 30, Parent = blockLbl })
	blockLbl.Parent = bb

	local function refreshIncome()
		incomeLbl.Text = Format.cash(num(model:GetAttribute("Income"), def.income)) .. "/s"
	end
	local function refreshUncollected()
		-- other players never see this line: skip the per-tick text work for their cars (PERF-08)
		if model:GetAttribute("OwnerUserId") ~= player.UserId then
			if uncLbl.Visible then
				uncLbl.Visible = false
			end
			return
		end
		local value = num(model:GetAttribute("Uncollected"), 0)
		uncLbl.Visible = value > 0
		uncLbl.Text = "💰 " .. Format.cash(value)
	end
	refreshIncome()
	refreshUncollected()
	trove:Connect(model:GetAttributeChangedSignal("Income"), refreshIncome)
	trove:Connect(model:GetAttributeChangedSignal("Uncollected"), refreshUncollected)
	trove:Connect(model:GetAttributeChangedSignal("OwnerUserId"), function()
		refreshUncollected()
		updatePrompts(model)
	end)
	bb.Enabled = tagsNearPlot(num(model:GetAttribute("PlotIndex"), 0))
	bb.Parent = chassis
	trove:Add(bb)
	tagGuis[model] = bb
end

local function teardownDisplay(model: Instance)
	pendingTags[model :: Model] = nil
	tagGuis[model :: Model] = nil
	local t = displayTroves[model :: Model]
	if t then
		displayTroves[model :: Model] = nil
		t:Destroy()
	end
end

-- PERF-12: build the billboards of garages the camera comes near (once) and switch far garages' billboards off.
local function refreshTags()
	local cam = cameraPosition()
	local changed = false
	for index = 1, MapLayout.plotCount() do
		local near = GarageClient._tagsNear(cam, plotCenter(index), TAG_NEAR)
		if tagNear[index] ~= near then
			tagNear[index] = near
			changed = true
		end
	end
	if not changed then
		return
	end
	for model, trove in displayTroves do
		local near = tagsNearPlot(num(model:GetAttribute("PlotIndex"), 0))
		local chassis = pendingTags[model]
		if near and chassis then
			pendingTags[model] = nil
			if chassis.Parent then
				buildBillboard(model, chassis, trove)
				updatePrompts(model) -- the StealBlock line lives on the billboard
			end
		end
		local bb = tagGuis[model]
		if bb and bb.Enabled ~= near then
			bb.Enabled = near
		end
	end
end

local function setupDisplay(inst: Instance)
	if not inst:IsA("Model") or displayTroves[inst] then
		return
	end
	local model = inst
	local trove = Trove.new()
	displayTroves[model] = trove
	trove:Connect(model.AncestryChanged, function()
		if model.Parent == nil then
			teardownDisplay(model)
		end
	end)
	task.spawn(function()
		local chassis = model:WaitForChild("Chassis", 5)
		if not chassis or not chassis:IsA("BasePart") or displayTroves[model] ~= trove then
			return
		end
		if tagsNearPlot(num(model:GetAttribute("PlotIndex"), 0)) then
			buildBillboard(model, chassis, trove)
		else
			pendingTags[model] = chassis -- far garage: refreshTags builds it once the camera comes near
		end
		updatePrompts(model)
		trove:Connect(chassis.ChildAdded, function(child: Instance)
			if child:IsA("ProximityPrompt") then
				updatePrompts(model)
			end
		end)
	end)
end

-- Pads ---------------------------------------------------------------------------------------------------------------

local function stopPadPulse(pad: BasePart)
	local t = padPulses[pad]
	if t then
		padPulses[pad] = nil
		t:Cancel()
	end
end

local function clearUnlockPrompt(pad: BasePart)
	local pp = unlockPrompts[pad]
	if pp then
		unlockPrompts[pad] = nil
		pp:Destroy()
	end
end

-- kind: "slot" -> UnlockSlot remote, "pass" -> +2 Slots gamepass purchase prompt
local function ensureUnlockPrompt(pad: BasePart, action: string, object: string, kind: string)
	local pp = unlockPrompts[pad]
	if not pp then
		local newPrompt = Kit.new("ProximityPrompt", {
			Name = "UnlockPrompt",
			KeyboardKeyCode = Enum.KeyCode.E,
			GamepadKeyCode = Enum.KeyCode.ButtonX,
			HoldDuration = 0.4,
			RequiresLineOfSight = false,
			MaxActivationDistance = 14,
			Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton,
		}) :: ProximityPrompt
		newPrompt.Triggered:Connect(function()
			if newPrompt:GetAttribute("Kind") == "pass" then
				local passId = Monetization.Passes.slots.id
				if passId ~= 0 then
					MarketplaceService:PromptGamePassPurchase(player, passId)
				end
			else
				Net.fire("UnlockSlot")
			end
		end)
		newPrompt.Parent = pad
		unlockPrompts[pad] = newPrompt
		pp = newPrompt
	end
	local prompt = pp :: ProximityPrompt
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt:SetAttribute("Kind", kind)
end

local function renderPad(view: PlotView, pad: BasePart)
	if pad.Parent == nil then
		return
	end
	local slot = num(pad:GetAttribute("Slot"), 0)
	local locked = pad:GetAttribute("Locked") == true
	local price = num(pad:GetAttribute("Price"), 0)
	local passOnly = pad:GetAttribute("PassOnly") == true
	local nextUnlock = pad:GetAttribute("NextUnlock") == true
	local state = pad:GetAttribute("State")
	local mine = isMine(view)
	local owned = num(view.model:GetAttribute("OwnerUserId"), 0) ~= 0

	local statusText, statusColor = "", Theme.Colors.TextDim
	local icon, priceText, priceColor = "🔒", "LOCKED", Theme.Colors.Danger
	if locked then
		local passOnSale = Monetization.Passes.slots.id ~= 0
		local padIcon, padText, colorKey = GarageClient._lockedPadLabel(passOnly, passOnSale, mine, nextUnlock, price)
		icon, priceText = padIcon, padText
		priceColor = (Theme.Colors :: any)[colorKey] or Theme.Colors.Danger
		statusText, statusColor = icon .. " " .. priceText, priceColor
	elseif state == "BeingStolen" then
		statusText, statusColor = "🚨 STOLEN!", Theme.Colors.Danger
	elseif state == "Driving" then
		statusText, statusColor = "🚗 OUT", Theme.Colors.Secondary
	elseif state == "Empty" and owned then
		statusText, statusColor = "EMPTY", Theme.Colors.TextDim
	elseif state == "Parked" then
		statusText, statusColor = "PARKED", Theme.Colors.Cash
	end

	local gui = pad:FindFirstChild("PadGui")
	local root = gui and gui:FindFirstChild("Root")
	if root then
		local number = root:FindFirstChild("Number")
		local lock = root:FindFirstChild("Lock")
		if number and number:IsA("GuiObject") then
			number.Visible = not locked
		end
		if lock and lock:IsA("Frame") then
			lock.Visible = locked
			setText(lock:FindFirstChild("Icon"), icon)
			setText(lock:FindFirstChild("Price"), priceText, priceColor)
			local stroke = lock:FindFirstChildOfClass("UIStroke")
			local highlight = locked and mine and nextUnlock
			lock.BackgroundColor3 = if highlight then Color3.fromRGB(14, 60, 30) else Color3.fromRGB(70, 18, 30)
			if stroke then
				stroke.Color = if highlight then Theme.Colors.Cash else Theme.Colors.Danger
				if highlight and not padPulses[pad] then
					stroke.Transparency = 0
					local t = TweenService:Create(stroke, PULSE, { Transparency = 0.7 })
					padPulses[pad] = t
					t:Play()
				elseif not highlight then
					stopPadPulse(pad)
					stroke.Transparency = 0
				end
			end
		end
	end
	local sign = pad:FindFirstChild("Sign")
	local sgui = sign and sign:FindFirstChild("SignGui")
	local sroot = sgui and sgui:FindFirstChild("Root")
	if sroot then
		setText(sroot:FindFirstChild("Status"), statusText, statusColor)
	end

	if mine and locked and nextUnlock then
		ensureUnlockPrompt(pad, "Unlock " .. Format.cash(price), "Garage slot " .. slot, "slot")
	elseif mine and locked and passOnly and Monetization.Passes.slots.id ~= 0 then
		ensureUnlockPrompt(pad, "Get +2 Slots", "Garage slot " .. slot, "pass")
	else
		clearUnlockPrompt(pad)
	end
end

local function renderPads(view: PlotView)
	for _, pad in view.pads do
		renderPad(view, pad)
	end
end

-- Collect pad FX (own plot) ------------------------------------------------------------------------------------------------

local function stopCollectFx(fx: CollectFx)
	for _, t in fx.tweens do
		t:Cancel()
	end
	table.clear(fx.tweens)
	fx.active = false
	fx.light.Brightness = 0
	fx.billboard.Enabled = false
end

local function destroyCollectFx()
	local fx = collectFx
	if fx then
		collectFx = nil
		stopCollectFx(fx)
		fx.trove:Destroy()
	end
end

local function updateCollectFx()
	local fx = collectFx
	if not fx then
		return
	end
	local view = views[fx.index]
	if not view then
		return
	end
	local total = num(view.model:GetAttribute("Uncollected"), 0)
	fx.amount.Text = "💰 " .. Format.cash(total)
	if fx.signAmount then
		fx.signAmount.Text = if total > 0 then Format.cash(total) .. " waiting!" else "Step on the pad!"
	end
	if total > 0 and not fx.active then
		fx.active = true
		fx.billboard.Enabled = true
		fx.light.Brightness = 0.4
		local t1 = TweenService:Create(fx.light, PULSE, { Brightness = 3.2 })
		local t2 = TweenService:Create(fx.billboard, BOB, { StudsOffsetWorldSpace = Vector3.new(0, 6.2, 0) })
		fx.tweens = { t1, t2 }
		t1:Play()
		t2:Play()
	elseif total <= 0 and fx.active then
		stopCollectFx(fx)
	end
end

local function setupCollectFx(view: PlotView)
	destroyCollectFx()
	local pad = view.model:FindFirstChild("CollectPad")
	if not pad or not pad:IsA("BasePart") then
		return
	end
	local trove = Trove.new()
	local light = trove:Add(Kit.new("PointLight", {
		Name = "LocalGlow",
		Color = Theme.Colors.Cash,
		Range = 18,
		Brightness = 0,
		Shadows = false,
		Parent = pad,
	}))
	local bb = trove:Add(Kit.new("BillboardGui", {
		Name = "CollectTag",
		Adornee = pad,
		Size = UDim2.fromScale(10, 3.6),
		StudsOffsetWorldSpace = Vector3.new(0, 5, 0),
		AlwaysOnTop = false,
		MaxDistance = 120,
		LightInfluence = 0,
		ResetOnSpawn = false,
		Enabled = false,
		Parent = pad,
	}))
	local amount = Kit.label("💰 $0", 40, {
		Name = "Amount",
		Size = UDim2.fromScale(1, 0.58),
		TextScaled = true,
		TextColor3 = Theme.Colors.Gold,
	})
	amount.Parent = bb
	local hint = Kit.label("STEP HERE TO COLLECT", 20, {
		Name = "Hint",
		Size = UDim2.fromScale(1, 0.36),
		Position = UDim2.fromScale(0, 0.62),
		TextScaled = true,
		TextColor3 = Theme.Colors.Cash,
	})
	hint.Parent = bb
	local sign = view.model:FindFirstChild("CollectSign")
	local signAmount = sign and sign:FindFirstChild("Amount", true)
	collectFx = {
		index = view.index,
		trove = trove,
		light = light,
		billboard = bb,
		amount = amount,
		tweens = {},
		active = false,
		signAmount = if signAmount and signAmount:IsA("TextLabel") then signAmount else nil,
	}
	updateCollectFx()
end

local function syncOwnership()
	local idx = myIndex()
	local mineView = if idx then views[idx] else nil
	if mineView and isMine(mineView) then
		if not collectFx or collectFx.index ~= mineView.index then
			setupCollectFx(mineView)
		end
	elseif collectFx then
		destroyCollectFx()
	end
	for _, view in views do
		applyGate(view)
		renderPads(view)
	end
	updateAllPrompts()
end

-- Plots ------------------------------------------------------------------------------------------------------------------

local function setupPlot(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local model = inst
	local index = model:GetAttribute("PlotIndex")
	if typeof(index) ~= "number" or views[index] then
		return
	end
	local trove = Trove.new()
	local view: PlotView = { model = model, index = index, trove = trove, gate = nil, pads = {} }
	views[index] = view

	local gate = model:WaitForChild("Gate", 10)
	if gate and gate:IsA("BasePart") then
		view.gate = gate
		trove:Connect(gate:GetPropertyChangedSignal("CanCollide"), function()
			applyGate(view)
		end)
	end
	for slot = 1, MapLayout.maxPhysicalSlots() do
		local pad = model:WaitForChild("Pad" .. slot, 10)
		if pad and pad:IsA("BasePart") then
			table.insert(view.pads, pad)
			trove:Connect(pad.AttributeChanged, function(attr: string)
				renderPad(view, pad)
				if attr == "State" then
					updatePlotPrompts(view) -- a car of this garage started / stopped being stolen
				end
			end)
		end
	end
	trove:Connect(model.AttributeChanged, function(attr: string)
		if attr == "OwnerUserId" then
			syncOwnership()
		elseif attr == "Locked" then
			applyGate(view)
			updatePlotPrompts(view)
		elseif attr == "CarCount" or attr == "RobbableAt" then
			updatePlotPrompts(view)
		elseif attr == "Uncollected" then
			if collectFx and collectFx.index == index then
				updateCollectFx()
			end
		end
	end)
	applyGate(view)
	renderPads(view)
	-- display cars set up before this view existed read 0 cars and hid their Steal prompt: re-evaluate them now
	updatePlotPrompts(view)
	if index == myIndex() and isMine(view) then
		setupCollectFx(view)
	end
end

-- Lock button UI ---------------------------------------------------------------------------------------------------------

local function buildLockUI()
	local screen = Kit.screen("GarageHUD", Theme.Layers.HUD + 1)
	local btn = Kit.button("🔒 LOCK GARAGE", Theme.Colors.Danger, {
		Name = "LockButton",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -LOCK_BOTTOM),
		Size = UDim2.fromOffset(250, 58),
		Visible = false,
	})
	btn.Parent = screen
	btn.Activated:Connect(function()
		if lockState == "ready" then
			Net.fire("LockGarage")
			Kit.pop(btn, 1.15)
		else
			-- locked / recharging: the pill shows the countdown; acknowledge the tap instead of ignoring it
			Kit.pop(btn, 0.9)
			local sound = controller("SoundController")
			if sound and typeof(sound.play) == "function" then
				pcall(sound.play, "Click")
			end
		end
	end)
	lockButton = btn
	lockScreen = screen
end

-- Design px HUDController keeps clear at bottom-center (hotbar + HOME), or 0. Both screens use Kit.uiScale().
local function hudBottomClearance(): number
	local hud = controller("HUDController")
	if hud and typeof(hud.getBottomClearance) == "function" then
		local ok, v = pcall(hud.getBottomClearance)
		if ok and typeof(v) == "number" and v == v then
			return v
		end
	end
	return 0
end

local function updateLockUI()
	local btn = lockButton
	if not btn then
		return
	end
	local screen = lockScreen
	if screen and screen.Enabled == hudHidden then
		screen.Enabled = not hudHidden -- streamer mode hides the pill too
	end
	local idx = myIndex()
	local view = if idx then views[idx] else nil
	if not view or not isMine(view) then
		btn.Visible = false
		lockState = "hidden"
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local inside = root ~= nil and root:IsA("BasePart") and MapLayout.plotAt(root.Position) == idx
	local locked = view.model:GetAttribute("Locked") == true
	local now = Workspace:GetServerTimeNow()
	local endsAt = num(view.model:GetAttribute("LockEndsAt"), 0)
	local readyAt = num(view.model:GetAttribute("LockReadyAt"), 0)
	local driving = player:GetAttribute("Driving") == true
	btn.Visible = not driving and (inside or locked)
	if btn.Visible then
		-- outside your garage HOME sits at bottom-center: stack the pill above it rather than over it
		local bottom = math.max(LOCK_BOTTOM, math.ceil(hudBottomClearance()) + 8)
		if btn.Position.Y.Offset ~= -bottom then
			btn.Position = UDim2.new(0.5, 0, 1, -bottom)
		end
	end
	if locked then
		lockState = "locked"
		btn.Text = "🔒 LOCKED " .. Format.clock(endsAt - now)
		btn.BackgroundColor3 = Theme.Colors.Secondary
	elseif readyAt > now then
		lockState = "cooldown"
		btn.Text = "⏳ LOCK IN " .. math.ceil(readyAt - now) .. "s"
		btn.BackgroundColor3 = Theme.Colors.Disabled
	else
		lockState = "ready"
		-- someone is hotwiring one of your cars (GarageService stamps IntruderAt): flash the pill (F3)
		local intruder = GarageClient._intruderFlash(num(view.model:GetAttribute("IntruderAt"), 0), now)
		btn.Text = if intruder then "🚨 LOCK NOW!" else "🔒 LOCK GARAGE"
		btn.BackgroundColor3 = Theme.Colors.Danger
		local clock = os.clock()
		if intruder and btn.Visible and not hudHidden and clock - lockPulseAt >= 0.6 then
			lockPulseAt = clock
			Kit.pop(btn, 1.15)
		end
	end
end

-- Design px (Kit.uiScale, like HUDController's) from the screen bottom to the LOCK pill's top edge while it shows,
-- else nil. TutorialController keeps its card above it.
function GarageClient.getLockTop(): number?
	local btn = lockButton
	local screen = lockScreen
	if not btn or not screen then
		return nil
	end
	return GarageClient._lockTop(btn.Visible and screen.Enabled, -btn.Position.Y.Offset)
end

-- Lifecycle ----------------------------------------------------------------------------------------------------------------

function GarageClient.init() end

function GarageClient.start()
	buildLockUI()

	CollectionService:GetInstanceAddedSignal("DisplayCar"):Connect(setupDisplay)
	CollectionService:GetInstanceRemovedSignal("DisplayCar"):Connect(teardownDisplay)
	for _, inst in CollectionService:GetTagged("DisplayCar") do
		setupDisplay(inst)
	end

	player:GetAttributeChangedSignal("PlotIndex"):Connect(syncOwnership)
	player:GetAttributeChangedSignal("Driving"):Connect(updateAllPrompts)
	player:GetAttributeChangedSignal("HoldMultiplier"):Connect(updateAllPrompts)

	-- my free slots gate every Steal prompt (a full garage can't take a stolen car)
	local function refreshFreeSlots()
		local free = GarageClient._freeSlots(StateController.get())
		if free ~= freeSlots then
			freeSlots = free
			updateAllPrompts()
		end
	end
	StateController.Changed:Connect(refreshFreeSlots)
	refreshFreeSlots()

	task.spawn(function()
		local hud = controller("HUDController")
		if not hud then
			return
		end
		if typeof(hud.isHidden) == "function" then
			local ok, hidden = pcall(hud.isHidden)
			hudHidden = ok and hidden == true
		end
		if hud.VisibilityChanged then
			hud.VisibilityChanged:Connect(function(hidden: boolean)
				hudHidden = hidden == true
				pcall(updateLockUI)
			end)
		end
	end)

	task.spawn(function()
		local folder = Workspace:WaitForChild("Plots", 60)
		if not folder then
			warn("[GarageClient] Workspace.Plots never appeared")
			return
		end
		folder.ChildAdded:Connect(function(child)
			task.spawn(setupPlot, child)
		end)
		for _, child in folder:GetChildren() do
			task.spawn(setupPlot, child)
		end
	end)

	local lastProtected = 0
	local lastTags = 0
	while true do
		task.wait(0.2)
		local ok, err = pcall(updateLockUI)
		if not ok then
			warn("[GarageClient] lock UI: " .. tostring(err))
		end
		local clock = os.clock()
		if clock - lastTags >= 0.5 then
			lastTags = clock
			local okT, errT = pcall(refreshTags)
			if not okT then
				warn("[GarageClient] billboards: " .. tostring(errT))
			end
		end
		-- tick "PROTECTED m:ss" and re-enable Steal once a victim's RobbableAt passes
		local now = Workspace:GetServerTimeNow()
		if now - lastProtected >= 1 then
			lastProtected = now
			for _, view in views do
				local at = num(view.model:GetAttribute("RobbableAt"), 0)
				if at > 0 and at > now - 2 then
					local okP, errP = pcall(updatePlotPrompts, view)
					if not okP then
						warn("[GarageClient] prompts: " .. tostring(errP))
					end
				end
			end
		end
	end
end

return GarageClient
