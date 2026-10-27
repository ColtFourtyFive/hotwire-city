--!strict
-- DealershipClient (SPEC §7): makes the showroom feel like a showroom. Purely client-local and cosmetic.
--
--  * Turntables: every "DealerCar" spins slowly around its pad center (client-local CFrame, server never sees it).
--    The server anchors only the Chassis and welds the rest, so moving the chassis moves the whole car (one write
--    per car per frame); falls back to Model:PivotTo if any other part is anchored.
--  * Billboards over each car: rarity pill, mutation, name, price (green if you can afford it), $/s and a live
--    "NEW STOCK IN m:ss" from the car's RestockAt attribute (Workspace:GetServerTimeNow() based).
--  * Empty turntables show "SOLD!" / "STOLEN!" + "NEW CAR IN 0:25".
--  * Rarity-colored pulsing ground glow + light under Epic+ cars, sparkles for Legendary+ (Secret cycles hue). The
--    light and sparkles only run within FX_RANGE of the camera (PERF-13).
--  * StealPrompt.HoldDuration scaled locally by the player's HoldMultiplier attribute (server re-validates).
--  * Prompt audience filter (used by TheftService's dropped-car prompts): any ProximityPrompt under
--    Workspace.Vehicles with attribute OnlyUserId (number) is hidden for everyone else; HideForUserId hides it for
--    that one user. Purely cosmetic: the server re-checks who triggered what.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local Cars = require(Config:WaitForChild("Cars"))
local Rarity = require(Config:WaitForChild("Rarity"))
local EconomyMath = require(Util:WaitForChild("EconomyMath"))
local Format = require(Util:WaitForChild("Format"))
local Trove = require(Util:WaitForChild("Trove"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

local DealershipClient = {}

DealershipClient.SPIN_SPEED = 0.5 -- radians per second
DealershipClient.SPIN_RANGE = 260 -- only spin cars this close to the camera
DealershipClient.FX_RANGE = 160 -- glow PointLight + sparkles are switched off beyond this (mobile GPU budget)
DealershipClient.BILLBOARD_DISTANCE = 120
DealershipClient.TIMER_INTERVAL = 0.25

local player = Players.LocalPlayer

type Tracked = {
	model: Model,
	chassis: BasePart,
	base: CFrame,
	phase: number,
	useChassis: boolean,
	price: number,
	restockAt: number,
	priceLabel: TextLabel?,
	timerLabel: TextLabel?,
	glow: BasePart?,
	glowLight: PointLight?,
	sparkles: ParticleEmitter?,
	fxOn: boolean, -- light + sparkles currently enabled
	glowColor: Color3,
	rainbowGlow: boolean,
	trove: any,
}

type PadBoard = {
	part: BasePart,
	gui: BillboardGui,
	status: TextLabel,
	timer: TextLabel,
	trove: any,
}

local tracked: { [Model]: Tracked } = {}
local padBoards: { [BasePart]: PadBoard } = {}
local fxFolder: Folder? = nil
local timerAccum = 0
local hiddenPrompts: { [ProximityPrompt]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Pure helpers (exposed for tests) ---------------------------------------------------------------------------------

-- "NEW STOCK IN 3:12" style countdown text from a server-time deadline.
function DealershipClient._countdownText(prefix: string, deadline: number, now: number): string
	return prefix .. " " .. Format.clock(math.max(0, math.ceil(deadline - now)))
end

-- Local StealPrompt hold: base * multiplier, clamped to sane bounds.
function DealershipClient._scaledHold(base: number, multiplier: any): number
	local m = if typeof(multiplier) == "number"
			and multiplier == multiplier
			and multiplier > 0
		then math.clamp(multiplier, 0.05, 4)
		else 1
	return math.max(0, base * m)
end

-- Should a prompt carrying audience attributes be visible for `userId`?
function DealershipClient._audienceVisible(onlyUserId: any, hideForUserId: any, userId: number): boolean
	if typeof(onlyUserId) == "number" and onlyUserId ~= userId then
		return false
	end
	if typeof(hideForUserId) == "number" and hideForUserId == userId then
		return false
	end
	return true
end

-- Readable display color for a rarity (Secret's swatch is near-black).
function DealershipClient._displayColor(rarity: string): Color3
	if rarity == "Secret" then
		return Color3.fromRGB(255, 80, 210)
	end
	local tier = Rarity.Tiers[rarity :: any]
	return if tier then tier.color else Theme.Colors.Text
end

-- Helpers ----------------------------------------------------------------------------------------------------------

local function num(v: any, default: number): number
	if typeof(v) == "number" and v == v then
		return v
	end
	return default
end

local function myCash(): number
	return num(player:GetAttribute("Cash"), 0)
end

local function holdMultiplier(): any
	return player:GetAttribute("HoldMultiplier")
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function getFxFolder(): Folder
	local f = fxFolder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "DealerFX_Local"
	nf.Parent = Workspace
	fxFolder = nf
	return nf
end

local function applyHold(prompt: ProximityPrompt)
	local base = prompt:GetAttribute("BaseHold")
	if typeof(base) ~= "number" then
		base = prompt:GetAttribute("BaseHoldDuration")
	end
	if typeof(base) ~= "number" then
		return
	end
	local want = DealershipClient._scaledHold(base, holdMultiplier())
	if math.abs(prompt.HoldDuration - want) > 1e-3 then
		prompt.HoldDuration = want
	end
end

local function scalePrompts(rec: Tracked)
	for _, d in rec.chassis:GetChildren() do
		if d:IsA("ProximityPrompt") and d.Name == "StealPrompt" then
			applyHold(d)
		end
	end
end

-- Billboard ------------------------------------------------------------------------------------------------------------

local function textRow(parent: Instance, name: string, text: string, y: number, h: number, color: Color3, font: Font?)
	local lbl = Kit.label(text, 20, {
		Name = name,
		Position = UDim2.fromScale(0, y),
		Size = UDim2.fromScale(1, h),
		TextScaled = true,
		TextColor3 = color,
	})
	if font then
		lbl.FontFace = font
	end
	lbl.Parent = parent
	return lbl
end

local function updatePrice(rec: Tracked)
	local lbl = rec.priceLabel
	if not lbl then
		return
	end
	local affordable = myCash() >= rec.price
	lbl.Text = (if affordable then "" else "🔒 ") .. Format.cash(rec.price)
	lbl.TextColor3 = if affordable then Theme.Colors.Cash else Theme.Colors.Danger
end

local function buildBillboard(rec: Tracked, def: Cars.CarDef, mutation: string)
	local model = rec.model
	local height = num(model:GetAttribute("Height"), 5)
	local ride = num(model:GetAttribute("RideHeight"), 2)
	local gui = Instance.new("BillboardGui")
	gui.Name = "DealerBillboard"
	gui.Size = UDim2.fromScale(11, 6.6) -- studs: shrinks naturally with distance
	gui.StudsOffsetWorldSpace = Vector3.new(0, height - ride + 4.6, 0)
	gui.MaxDistance = DealershipClient.BILLBOARD_DISTANCE
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Adornee = rec.chassis

	local color = DealershipClient._displayColor(def.rarity)
	-- rarity pill
	local pill = Kit.new("Frame", {
		Name = "RarityPill",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.62, 0.15),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = gui,
	})
	Kit.corner(UDim.new(1, 0)).Parent = pill
	Kit.stroke(Theme.Colors.Stroke, 2).Parent = pill
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190)).Parent = pill
	textRow(pill, "Rarity", string.upper(def.rarity), 0.06, 0.88, Theme.Colors.Text, Theme.Fonts.BodyHeavy)

	local y = 0.17
	local mut = Rarity.getMutation(mutation :: any)
	if mut.label ~= "" then
		local mutLabel =
			textRow(gui, "Mutation", "✨ " .. mut.label .. " ✨", y, 0.13, mut.color or Theme.Colors.Text)
		if mutation == "Rainbow" then
			mutLabel.TextColor3 = Color3.new(1, 1, 1)
			Kit.new("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
					ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 60)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 255, 120)),
					ColorSequenceKeypoint.new(0.75, Color3.fromRGB(60, 170, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 90, 255)),
				}),
				Parent = mutLabel,
			})
		end
		y += 0.14
	else
		y += 0.03
	end
	textRow(gui, "CarName", def.name, y, 0.24, Theme.Colors.Text)
	y += 0.25
	rec.priceLabel = textRow(gui, "Price", Format.cash(rec.price), y, 0.2, Theme.Colors.Cash)
	y += 0.2
	local income = EconomyMath.carIncome(def.id, mutation :: any)
	textRow(gui, "Income", "+" .. Format.cash(income) .. "/s", y, 0.12, Theme.Colors.Gold, Theme.Fonts.BodyHeavy)
	y += 0.12
	rec.timerLabel = textRow(gui, "Restock", "", math.min(y, 0.88), 0.11, Theme.Colors.TextDim, Theme.Fonts.Body)
	updatePrice(rec)
	gui.Parent = rec.chassis
	rec.trove:Add(gui)
end

-- Glow ------------------------------------------------------------------------------------------------------------------

local function buildGlow(rec: Tracked, def: Cars.CarDef)
	local tier = Rarity.Tiers[def.rarity]
	if not tier or tier.order < 4 then
		return
	end
	local ride = num(rec.model:GetAttribute("RideHeight"), 2)
	local ground = rec.base.Position - Vector3.new(0, ride, 0)
	local color = DealershipClient._displayColor(def.rarity)
	local ring = Instance.new("Part")
	ring.Name = "DealerGlow"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.12, 23, 23)
	-- sits around the turntable rim (the turntable covers the middle), slightly below the turntable top
	ring.CFrame = CFrame.new(ground - Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 18
	light.Brightness = 2.5
	light.Shadows = false
	light.Parent = ring
	if tier.order >= 5 then
		local sparkles = Instance.new("ParticleEmitter")
		sparkles.Name = "Sparkles"
		sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkles.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
		sparkles.LightEmission = 1
		sparkles.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		})
		sparkles.Transparency = NumberSequence.new(0.1)
		sparkles.Lifetime = NumberRange.new(1.2, 2.2)
		sparkles.Speed = NumberRange.new(3, 7)
		sparkles.SpreadAngle = Vector2.new(25, 25)
		sparkles.Rate = if tier.order >= 6 then 16 else 8
		sparkles.EmissionDirection = Enum.NormalId.Right -- local +X = world up after the cylinder rotation
		sparkles.Shape = Enum.ParticleEmitterShape.Disc
		sparkles.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		sparkles.Parent = ring
		rec.sparkles = sparkles
	end
	ring.Parent = getFxFolder()
	rec.glow = ring
	rec.glowLight = light
	rec.glowColor = color
	rec.rainbowGlow = def.rarity == "Secret"
	rec.trove:Add(ring)
end

-- Tracking ----------------------------------------------------------------------------------------------------------------

local function untrack(model: Model)
	local rec = tracked[model]
	if not rec then
		return
	end
	tracked[model] = nil
	rec.trove:Clean()
end

local function track(model: Instance)
	if not model:IsA("Model") or tracked[model] then
		return
	end
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not chassis or not chassis:IsA("BasePart") then
		return
	end
	local carId = model:GetAttribute("CarId")
	local def = if typeof(carId) == "string" then Cars.get(carId) else nil
	if not def then
		return
	end
	local mutation = model:GetAttribute("Mutation")
	local mut = if typeof(mutation) == "string" then mutation else "None"
	local useChassis = chassis.Anchored
	if useChassis then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d ~= chassis and d.Anchored then
				useChassis = false
				break
			end
		end
	end
	local rec: Tracked = {
		model = model,
		chassis = chassis,
		base = model:GetPivot(),
		phase = num(model:GetAttribute("PadIndex"), 1) * 0.78,
		useChassis = useChassis,
		price = num(model:GetAttribute("Price"), def.price),
		restockAt = num(model:GetAttribute("RestockAt"), 0),
		priceLabel = nil,
		timerLabel = nil,
		glow = nil,
		glowLight = nil,
		sparkles = nil,
		fxOn = true,
		glowColor = Theme.Colors.Text,
		rainbowGlow = false,
		trove = Trove.new(),
	}
	tracked[model] = rec
	local ok, err = pcall(buildBillboard, rec, def, mut)
	if not ok then
		warn("[DealershipClient] billboard failed: " .. tostring(err))
	end
	local okGlow, errGlow = pcall(buildGlow, rec, def)
	if not okGlow then
		warn("[DealershipClient] glow failed: " .. tostring(errGlow))
	end
	scalePrompts(rec)
	rec.trove:Connect(chassis.ChildAdded, function(child: Instance)
		if child:IsA("ProximityPrompt") and child.Name == "StealPrompt" then
			applyHold(child)
		end
	end)
	rec.trove:Connect(model:GetAttributeChangedSignal("RestockAt"), function()
		rec.restockAt = num(model:GetAttribute("RestockAt"), rec.restockAt)
	end)
	rec.trove:Connect(model.AncestryChanged, function()
		if not model:IsDescendantOf(Workspace) then
			untrack(model)
		end
	end)
end

-- Empty-pad boards ------------------------------------------------------------------------------------------------------

local function refreshPadBoard(board: PadBoard)
	local part = board.part
	local empty = part:GetAttribute("Empty") == true
	board.gui.Enabled = empty
	if not empty then
		return
	end
	local status = part:GetAttribute("Status")
	if status == "sold" then
		board.status.Text = "SOLD! 💸"
		board.status.TextColor3 = Theme.Colors.Cash
	elseif status == "stolen" then
		board.status.Text = "STOLEN! 🚨"
		board.status.TextColor3 = Theme.Colors.Danger
	else
		board.status.Text = "RESTOCKING"
		board.status.TextColor3 = Theme.Colors.Secondary
	end
end

local function trackPad(inst: Instance)
	if not inst:IsA("BasePart") or padBoards[inst] or not string.match(inst.Name, "^Turntable%d+$") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "PadBoard"
	gui.Size = UDim2.fromScale(10, 3.2)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	gui.MaxDistance = DealershipClient.BILLBOARD_DISTANCE
	gui.LightInfluence = 0
	gui.Enabled = false
	gui.Adornee = inst
	local status = textRow(gui, "Status", "SOLD!", 0, 0.62, Theme.Colors.Cash)
	local timer = textRow(gui, "Timer", "", 0.64, 0.34, Theme.Colors.Text, Theme.Fonts.BodyHeavy)
	gui.Parent = inst
	local board: PadBoard = { part = inst, gui = gui, status = status, timer = timer, trove = Trove.new() }
	board.trove:Add(gui)
	padBoards[inst] = board
	board.trove:Connect(inst.AttributeChanged, function()
		refreshPadBoard(board)
	end)
	board.trove:Connect(inst.AncestryChanged, function()
		if not inst:IsDescendantOf(Workspace) then
			padBoards[inst] = nil
			board.trove:Clean()
		end
	end)
	refreshPadBoard(board)
end

-- Prompt audience filter ------------------------------------------------------------------------------------------------

local function applyAudience(prompt: ProximityPrompt)
	local only = prompt:GetAttribute("OnlyUserId")
	local hide = prompt:GetAttribute("HideForUserId")
	if only == nil and hide == nil then
		return
	end
	local visible = DealershipClient._audienceVisible(only, hide, player.UserId)
	if not visible then
		hiddenPrompts[prompt] = true
		if prompt.Enabled then
			prompt.Enabled = false
		end
	elseif hiddenPrompts[prompt] then
		hiddenPrompts[prompt] = nil
		prompt.Enabled = true
	end
end

local function watchPrompt(inst: Instance)
	if not inst:IsA("ProximityPrompt") then
		return
	end
	applyAudience(inst)
	-- connection dies with the prompt (destroyed instances disconnect their signals)
	inst.AttributeChanged:Connect(function(attr: string)
		if attr == "OnlyUserId" or attr == "HideForUserId" then
			applyAudience(inst)
		end
	end)
end

-- Frame loop ------------------------------------------------------------------------------------------------------------

local function step(dt: number)
	local cam = Workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	local t = os.clock()
	local range = DealershipClient.SPIN_RANGE
	local fxRange = DealershipClient.FX_RANGE
	for model, rec in tracked do
		local dist = (rec.base.Position - camPos).Magnitude
		local fxOn = dist <= fxRange
		if fxOn ~= rec.fxOn then
			rec.fxOn = fxOn
			local light = rec.glowLight
			if light then
				light.Enabled = fxOn
			end
			local sparkles = rec.sparkles
			if sparkles then
				sparkles.Enabled = fxOn
			end
		end
		if dist <= range then
			local cf = rec.base * CFrame.Angles(0, t * DealershipClient.SPIN_SPEED + rec.phase, 0)
			if rec.useChassis then
				rec.chassis.CFrame = cf
			else
				model:PivotTo(cf)
			end
			local glow = rec.glow
			if glow then
				local pulse = (math.sin(t * 3 + rec.phase) + 1) * 0.5
				glow.Transparency = 0.1 + pulse * 0.35
				local light = rec.glowLight
				if light then
					light.Brightness = 1.8 + pulse * 1.6
				end
				if rec.rainbowGlow then
					local c = Color3.fromHSV((t * 0.25) % 1, 0.8, 1)
					glow.Color = c
					if light then
						light.Color = c
					end
				end
			end
		end
	end

	timerAccum += dt
	if timerAccum < DealershipClient.TIMER_INTERVAL then
		return
	end
	timerAccum = 0
	local now = serverNow()
	for _, rec in tracked do
		local lbl = rec.timerLabel
		if lbl and rec.restockAt > 0 then
			lbl.Text = DealershipClient._countdownText("NEW STOCK IN", rec.restockAt, now)
		end
	end
	for _, board in padBoards do
		if board.gui.Enabled then
			local at = num(board.part:GetAttribute("RestockAt"), 0)
			board.timer.Text = if at > 0 then DealershipClient._countdownText("NEW CAR IN", at, now) else ""
		end
	end
end

-- Lifecycle --------------------------------------------------------------------------------------------------------------

function DealershipClient.init() end

function DealershipClient.start()
	CollectionService:GetInstanceAddedSignal("DealerCar"):Connect(function(inst: Instance)
		task.defer(function()
			if inst.Parent then
				track(inst)
			end
		end)
	end)
	CollectionService:GetInstanceRemovedSignal("DealerCar"):Connect(function(inst: Instance)
		if inst:IsA("Model") then
			untrack(inst)
		end
	end)
	for _, inst in CollectionService:GetTagged("DealerCar") do
		track(inst)
	end

	player:GetAttributeChangedSignal("Cash"):Connect(function()
		for _, rec in tracked do
			updatePrice(rec)
		end
	end)
	player:GetAttributeChangedSignal("HoldMultiplier"):Connect(function()
		for _, rec in tracked do
			scalePrompts(rec)
		end
	end)

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		applyAudience(prompt)
		local model = prompt:FindFirstAncestorWhichIsA("Model")
		if model and tracked[model] and prompt.Name == "StealPrompt" then
			applyHold(prompt)
		end
	end)

	RunService.PreRender:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[DealershipClient] step failed: " .. tostring(err))
		end
	end)

	task.spawn(function()
		local dealership = Workspace:WaitForChild("Dealership", 60)
		if dealership then
			dealership.ChildAdded:Connect(trackPad)
			for _, child in dealership:GetChildren() do
				trackPad(child)
			end
		end
	end)
	task.spawn(function()
		local vehicles = Workspace:WaitForChild("Vehicles", 60)
		if vehicles then
			vehicles.DescendantAdded:Connect(watchPrompt)
			for _, d in vehicles:GetDescendants() do
				watchPrompt(d)
			end
		end
	end)
end

return DealershipClient
