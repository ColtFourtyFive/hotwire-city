--!strict
-- TutorialController (SPEC §2 + §7, RESEARCH "First 60 seconds"): icon-first onboarding for brand-new players
-- (snapshot.tutorialDone == false). Never blocks input: the objective card is a passive GTA-style "mission line" at
-- bottom-center (only its small SKIP button takes touches), guidance is world waypoints + a highlighted target car.
--
--   1 💰 YOUR CAR MAKES MONEY!     waypoint -> own CollectPad, auto-advances after 4s
--   2 🚗 STEAL A CAR!              waypoint + pulsing outline on the street car StreetSpawnService reserved for us
--                                  (TutorialForUserId), else the nearest Parked car on the street side of our garage
--                                  door (re-picked every 2s). If we already hotwired a car and hopped out, it points
--                                  back at that car instead ("GET BACK IN!", the F / Y / tap enter prompt).
--                                  Advances when the local player is driving a non-owned car
--   3 🏠 DRIVE IT HOME!            WaypointController's automatic "home" waypoint guides; advances when the garage
--                                  gains a car (garage count or steals stat rises); back to 2 if you leave the car
--   4 💵 COLLECT YOUR CASH!        waypoint -> CollectPad; advances when Cash jumps while near the pad, or after 20s
--   5 🏎️ BETTER CARS AT THE DEALERSHIP!   waypoint -> Dealership until you arrive (or 90s), then
--                                  Net.fire("TutorialDone") + confetti
-- During steps 1-3 the HUD is in focus mode (menus/HOME hidden); they pop back in at step 4.
-- Returning players who already delivered a car (stats.steals > 0) never replay it: TutorialDone is sent instead.
-- Streamer mode (HUDController.VisibilityChanged) hides the card.
--
-- Public API: isActive(): boolean, getStep(): (number, string?), skip(),
--   StepChanged: Signal(index, id), Finished: Signal(skipped: boolean)
-- Pure helpers (tests): STEPS, DONE, transition(step, ctx), pickNearest(candidates, origin, maxDistance?), keyFor,
--   enterKeyFor, shouldRun(snapshot), alreadyDelivered(snapshot), hintFor(stepDef, inputKind), garageCount(snapshot),
--   stealCount(snapshot), inFrontOfDoor(pos, door, face)

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local MapConfig = require(Config:WaitForChild("Map"))
local Util = Shared:WaitForChild("Util")
local MapLayout = require(Util:WaitForChild("MapLayout"))
local Signal = require(Util:WaitForChild("Signal"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER: safe to require at the top.
local StateController = require(script.Parent:WaitForChild("StateController"))

local TutorialController = {}

TutorialController.StepChanged = Signal.new() -- (index: number, id: string)
TutorialController.Finished = Signal.new() -- (skipped: boolean)

local player = Players.LocalPlayer

export type StepDef = {
	id: string,
	icon: string,
	title: string,
	hint: string,
	hintTouch: string?,
	hintPad: string?,
	color: Color3,
	timed: number?, -- seconds shown as a draining bar
	key: boolean?, -- show the "hold this key" keycap (E / 👆 / X)
}

TutorialController.STEPS = {
	{
		id = "money",
		icon = "💰",
		title = "YOUR CAR MAKES MONEY!",
		hint = "Cash stacks up on your green pad",
		color = Theme.Colors.Cash,
		timed = 4,
	},
	{
		id = "steal",
		icon = "🚗",
		title = "STEAL A CAR!",
		hint = "Run to the glowing car & HOLD",
		hintTouch = "Run to the glowing car!",
		hintPad = "Run to the glowing car & HOLD",
		color = Theme.Colors.Secondary,
		key = true,
	},
	{
		id = "deliver",
		icon = "🏠",
		title = "DRIVE IT HOME!",
		hint = "Follow the arrow into your garage",
		color = Theme.Colors.Primary,
	},
	{
		id = "collect",
		icon = "💵",
		title = "COLLECT YOUR CASH!",
		hint = "Step on the green pad",
		color = Theme.Colors.Cash,
	},
	{
		id = "dealer",
		icon = "🏎️",
		title = "BETTER CARS AT THE DEALERSHIP!",
		hint = "Follow the arrow • rarer cars = way more $/s",
		hintTouch = "Rarer cars = way more $/s",
		color = Theme.Colors.Gold,
	},
} :: { StepDef }

TutorialController.DONE = #TutorialController.STEPS + 1

local STEP_MONEY, STEP_STEAL, STEP_DELIVER, STEP_COLLECT, STEP_DEALER = 1, 2, 3, 4, 5
local DONE = TutorialController.DONE

local MONEY_SECONDS = 4
local COLLECT_TIMEOUT = 20
local DEALER_TIMEOUT = 90 -- the dealership step ends on arrival, or after this long
local DEALER_NEAR = 70 -- flat studs from the Dealership block center that count as "arrived"
local TARGET_MAX_DISTANCE = 220 -- street-side cars farther than this are ignored while a closer one exists
local REENTER_RADIUS = 150 -- our own hotwired-then-abandoned car within this range is the target again
local DOOR_FACE_SLACK = -4 -- same street-side test as StreetSpawnService._inFrontOfDoor
local DELIVER_GRACE = 2.5 -- seconds out of the car (e.g. busted / wrecked) before "steal a car" comes back
local RETARGET_EVERY = 2
local RETARGET_HYSTERESIS = 25 -- a new car must be this many studs closer to replace the current target
local START_DELAY = 1.5
local NEAR_PAD = 16
local TICK = 0.2
local CARD_BOTTOM = 186 -- clears the garage LOCK button (GarageClient) and the driving speedometer
local CARD_BOTTOM_THEFT = 276 -- also clears HUDController's theft timer when one is showing
local TOUCH_CARD_SCALE = 1.25 -- phones run at the 0.55 UI scale floor; keep the objective readable
local FOCUS_MAX_SECONDS = 150 -- HUD focus mode (menus hidden) never lasts longer than this
local WAYPOINT_ID = "tutorial"
local STREET_AHEAD = 70 -- studs in front of the garage door used as a "go to the street" waypoint

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

export type Ctx = {
	elapsed: number, -- seconds since the current step began
	driving: boolean, -- driving a deliverable (non-owned) car right now
	notDrivingFor: number, -- seconds since the player stopped driving (0 while driving)
	delivered: boolean, -- the garage gained a car since the tutorial began
	collected: boolean, -- cash jumped while standing near the collect pad (since this step began)
	nearDealer: boolean?, -- standing (or driving) within DEALER_NEAR of the Dealership
}

-- The whole tutorial state machine. Returns the next step index (DONE when finished). Steps can be skipped ahead
-- when the player is faster than the tutorial (e.g. already driving during step 1).
function TutorialController.transition(step: number, ctx: Ctx): number
	if step >= DONE then
		return DONE
	end
	if step <= STEP_DELIVER and ctx.delivered then
		return STEP_COLLECT
	end
	if step == STEP_MONEY then
		if ctx.driving then
			return STEP_DELIVER
		elseif ctx.elapsed >= MONEY_SECONDS then
			return STEP_STEAL
		end
	elseif step == STEP_STEAL then
		if ctx.driving then
			return STEP_DELIVER
		end
	elseif step == STEP_DELIVER then
		if not ctx.driving and ctx.notDrivingFor >= DELIVER_GRACE then
			return STEP_STEAL
		end
	elseif step == STEP_COLLECT then
		if ctx.collected or ctx.elapsed >= COLLECT_TIMEOUT then
			return STEP_DEALER
		end
	elseif step == STEP_DEALER then
		if ctx.nearDealer == true or ctx.elapsed >= DEALER_TIMEOUT then
			return DONE
		end
	end
	return step
end

export type Candidate = { position: Vector3, kind: string? }

-- Index of the nearest candidate whose kind is "Parked" (within maxDistance when given), or nil.
function TutorialController.pickNearest(candidates: { Candidate }, origin: Vector3, maxDistance: number?): number?
	local best: number? = nil
	local bestDist = maxDistance or math.huge
	for i, c in candidates do
		if c.kind == "Parked" then
			local d = (c.position - origin).Magnitude
			if d <= bestDist then
				best = i
				bestDist = d
			end
		end
	end
	return best
end

function TutorialController.shouldRun(snapshot: any): boolean
	return typeof(snapshot) == "table" and snapshot.tutorialDone == false
end

-- Street-side test (same as StreetSpawnService._inFrontOfDoor): door = door position, face = flat unit vector out of
-- the door. Cars behind/beside the garage walls fail it, so the arrow never points a newbie through a wall.
function TutorialController.inFrontOfDoor(pos: Vector3, door: Vector3, face: Vector3): boolean
	return (pos - door):Dot(face) > DOOR_FACE_SLACK
end

export type InputKind = "touch" | "gamepad" | "keyboard"

function TutorialController.hintFor(step: StepDef, input: InputKind): string
	if input == "touch" and step.hintTouch then
		return step.hintTouch
	elseif input == "gamepad" and step.hintPad then
		return step.hintPad
	end
	return step.hint
end

-- Keycap glyph for the steal prompt's hold input (ProximityPrompt defaults: E / ButtonX / on-screen button).
function TutorialController.keyFor(input: InputKind): string
	if input == "touch" then
		return "👆"
	elseif input == "gamepad" then
		return "X"
	end
	return "E"
end

-- Keycap glyph for VehicleService's "Get in" EnterPrompt (F / ButtonY / on-screen button) on our own hotwired car.
function TutorialController.enterKeyFor(input: InputKind): string
	if input == "touch" then
		return "👆"
	elseif input == "gamepad" then
		return "Y"
	end
	return "F"
end

function TutorialController.garageCount(snapshot: any): number
	if typeof(snapshot) ~= "table" or typeof(snapshot.garage) ~= "table" then
		return 0
	end
	local n = 0
	for _ in snapshot.garage do
		n += 1
	end
	return n
end

function TutorialController.stealCount(snapshot: any): number
	if typeof(snapshot) ~= "table" or typeof(snapshot.stats) ~= "table" then
		return 0
	end
	local v = snapshot.stats.steals
	return if typeof(v) == "number" then v else 0
end

-- A tutorial-pending profile that already delivered a car (stats.steals only rises on delivery): the player left
-- mid-tutorial last session. Don't replay it from step 1 with the menus hidden.
function TutorialController.alreadyDelivered(snapshot: any): boolean
	return TutorialController.shouldRun(snapshot) and TutorialController.stealCount(snapshot) > 0
end

-------------------------------------------------------------------------------------------------------------------------
-- Lazy dependencies
-------------------------------------------------------------------------------------------------------------------------

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" then result else nil
end

local function playSound(key: string)
	local sc = lazy("SoundController")
	if sc and typeof(sc.play) == "function" then
		pcall(sc.play, key)
	end
end

local function setHudFocus(on: boolean)
	local hud = lazy("HUDController")
	if hud and typeof(hud.setFocusMode) == "function" then
		pcall(hud.setFocusMode, on)
	end
end

local function tween(inst: Instance, info: TweenInfo, props: { [string]: any }): Tween
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

-------------------------------------------------------------------------------------------------------------------------
-- World queries
-------------------------------------------------------------------------------------------------------------------------

local function plotIndex(): number?
	local v = player:GetAttribute("PlotIndex")
	if typeof(v) == "number" and v >= 1 then
		return v
	end
	local snap: any = StateController.get()
	return if snap and typeof(snap.plotIndex) == "number" then snap.plotIndex else nil
end

local function rootPart(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function plotModel(): Instance?
	local idx = plotIndex()
	local plots = Workspace:FindFirstChild("Plots")
	if not idx or not plots then
		return nil
	end
	return plots:FindFirstChild("Plot" .. idx)
end

local function findCollectPad(): BasePart?
	local plot = plotModel()
	if not plot then
		return nil
	end
	local pad = plot:FindFirstChild("CollectPad") or plot:FindFirstChild("CollectPad", true)
	return if pad and pad:IsA("BasePart") then pad else nil
end

local function collectPadPosition(): Vector3?
	local pad = findCollectPad()
	if pad then
		return pad.Position
	end
	local idx = plotIndex()
	if not idx then
		return nil
	end
	local ok, cf = pcall(MapLayout.plotToWorld, idx, MapConfig.Garage.COLLECT_CENTER)
	return if ok then cf.Position else nil
end

local function streetPosition(): Vector3?
	local idx = plotIndex()
	if not idx then
		return nil
	end
	local ok, cf = pcall(MapLayout.plotToWorld, idx, Vector3.new(0, 0, MapConfig.Garage.FRONT_Z - STREET_AHEAD))
	return if ok then cf.Position else nil
end

local function dropoffPosition(): Vector3?
	local idx = plotIndex()
	if not idx then
		return nil
	end
	local ok, cf = pcall(MapLayout.plotDropoffZone, idx)
	return if ok then cf.Position else nil
end

-- Our garage door (world) + the flat unit vector pointing out of it, for the street-side test.
local function doorInfo(): (Vector3?, Vector3?)
	local idx = plotIndex()
	if not idx then
		return nil, nil
	end
	local ok, origin = pcall(MapLayout.plotOrigin, idx)
	if not ok then
		return nil, nil
	end
	local look = (origin :: CFrame).LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return nil, nil
	end
	local door = ((origin :: CFrame) * CFrame.new(0, 0, MapConfig.Garage.FRONT_Z)).Position
	return door, flat.Unit
end

local function insideOwnGarage(): boolean
	local idx = plotIndex()
	local root = rootPart()
	if not idx or not root then
		return false
	end
	local ok, cf, size = pcall(MapLayout.plotInteriorZone, idx)
	return ok and MapLayout.isInBox(cf, size, root.Position)
end

local function nearDealer(): boolean
	local root = rootPart()
	if not root then
		return false
	end
	local ok, center = pcall(MapLayout.poiCenter, "Dealership")
	if not ok then
		return false
	end
	local d = root.Position - (center :: Vector3)
	return Vector3.new(d.X, 0, d.Z).Magnitude <= DEALER_NEAR
end

local function nearPad(): boolean
	local root = rootPart()
	local pos = collectPadPosition()
	if not root or not pos then
		return false
	end
	local d = root.Position - pos
	return Vector3.new(d.X, 0, d.Z).Magnitude <= NEAR_PAD
end

-- Driving a car that can be delivered (anything but your own car / a police car).
local function drivingDeliverable(): boolean
	if player:GetAttribute("Driving") ~= true then
		return false
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat then
		return true -- the attribute says so; trust it
	end
	local model: Instance? = seat.Parent
	while model and model ~= Workspace and model:GetAttribute("Kind") == nil do
		model = model.Parent
	end
	local kind = if model then model:GetAttribute("Kind") else nil
	return kind ~= "Owned" and kind ~= "Police"
end

local function inputKind(): InputKind
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(preferred) == "EnumItem" then
		if preferred.Name == "Touch" then
			return "touch"
		elseif preferred.Name == "Gamepad" then
			return "gamepad"
		end
		return "keyboard"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	end
	return "keyboard"
end

-------------------------------------------------------------------------------------------------------------------------
-- Guidance: waypoint (WaypointController, lazy) + fallback marker + target highlight
-------------------------------------------------------------------------------------------------------------------------

local currentWaypointKey: any = nil
local fallbackGui: BillboardGui? = nil
local fallbackAnchor: Attachment? = nil
local highlight: Highlight? = nil
local highlightTween: Tween? = nil

local function clearFallback()
	if fallbackGui then
		fallbackGui:Destroy()
		fallbackGui = nil
	end
	if fallbackAnchor then
		fallbackAnchor:Destroy()
		fallbackAnchor = nil
	end
end

local function showFallback(target: Instance | Vector3, color: Color3, label: string)
	clearFallback()
	local adornee: Instance? = nil
	if typeof(target) == "Vector3" then
		local att = Instance.new("Attachment")
		att.Name = "TutorialMarker"
		att.WorldPosition = target
		att.Parent = Workspace.Terrain
		fallbackAnchor = att
		adornee = att
	elseif typeof(target) == "Instance" then
		adornee = if target:IsA("Model")
			then (target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart"))
			else target
	end
	if not adornee then
		return
	end
	local gui = Kit.new("BillboardGui", {
		Name = "TutorialMarker",
		Adornee = adornee,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(160, 130),
		StudsOffsetWorldSpace = Vector3.new(0, 9, 0),
		ResetOnSpawn = false,
		Parent = player:FindFirstChildOfClass("PlayerGui"),
	}) :: BillboardGui
	local arrow = Kit.label("⬇️", 64, {
		Name = "Arrow",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 30),
		Size = UDim2.fromOffset(90, 80),
		Parent = gui,
	})
	tween(
		arrow,
		TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.new(0.5, 0, 0, 46) }
	)
	Kit.label(label, 24, {
		Name = "Label",
		Size = UDim2.new(1, 0, 0, 30),
		TextColor3 = color,
		TextWrapped = false,
		Parent = gui,
	})
	fallbackGui = gui
end

local function positionOf(target: Instance | Vector3): Vector3?
	if typeof(target) == "Vector3" then
		return target
	elseif typeof(target) == "Instance" then
		if target:IsA("Model") then
			return target:GetPivot().Position
		elseif target:IsA("BasePart") then
			return target.Position
		end
	end
	return nil
end

-- Point the player at target (Instance follows it). nil clears. Re-calls with the same target are ignored.
local function setWaypoint(target: (Instance | Vector3)?, color: Color3?, label: string?)
	local key: any = if target == nil then nil else { target, label }
	if key == nil and currentWaypointKey == nil then
		return
	end
	if
		key ~= nil
		and currentWaypointKey ~= nil
		and currentWaypointKey[1] == key[1]
		and currentWaypointKey[2] == key[2]
	then
		return
	end
	currentWaypointKey = key
	local wp = lazy("WaypointController")
	if target == nil then
		if wp and typeof(wp.clear) == "function" then
			pcall(wp.clear, WAYPOINT_ID)
		end
		clearFallback()
		return
	end
	local c = color or Theme.Colors.Secondary
	local text = label or ""
	if wp then
		if typeof(target) == "Instance" and typeof(wp.track) == "function" then
			if pcall(wp.track, WAYPOINT_ID, target, c, text) then
				clearFallback()
				return
			end
		end
		local pos = positionOf(target)
		if pos and typeof(wp.set) == "function" and pcall(wp.set, WAYPOINT_ID, pos, c, text) then
			clearFallback()
			return
		end
	end
	showFallback(target, c, text)
end

local function clearHighlight()
	if highlightTween then
		highlightTween:Cancel()
		highlightTween = nil
	end
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
end

local function highlightCar(model: Model)
	if highlight and highlight.Parent == model then
		return
	end
	clearHighlight()
	local h = Instance.new("Highlight")
	h.Name = "TutorialHighlight"
	h.Adornee = model
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.FillColor = Theme.Colors.Secondary
	h.OutlineColor = Color3.new(1, 1, 1)
	h.FillTransparency = 0.8
	h.OutlineTransparency = 0
	h.Parent = model -- client-local child; vanishes with the car
	highlight = h
	highlightTween = tween(
		h,
		TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ FillTransparency = 0.4 }
	)
end

-------------------------------------------------------------------------------------------------------------------------
-- Card UI
-------------------------------------------------------------------------------------------------------------------------

type CardUI = {
	gui: ScreenGui,
	holder: Frame, -- positioned + device-scaled wrapper (Kit.pop owns the card's own UIScale)
	card: Frame,
	cardStroke: UIStroke?,
	badge: Frame,
	icon: TextLabel,
	check: TextLabel,
	title: TextLabel,
	hint: TextLabel,
	dots: { Frame },
	timerFill: Frame,
	skip: TextButton,
	key: Frame,
	keyLabel: TextLabel,
	keyHold: TextLabel,
}

local card: CardUI? = nil
local renderToken = 0
local cardBottom = CARD_BOTTOM
local reenterMode = false -- step 2 is pointing back at our own hotwired car ("GET BACK IN!")

local function buildCard(onSkip: () -> ()): CardUI
	local gui = Kit.screen("HC_Tutorial", Theme.Layers.HUD + 2)
	local holder = Kit.new("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -CARD_BOTTOM),
		Size = UDim2.fromOffset(500, 110),
		Parent = gui,
	})
	Kit.new("UIScale", {
		Name = "DeviceScale",
		Scale = if inputKind() == "touch" then TOUCH_CARD_SCALE else 1,
		Parent = holder,
	})
	local frame = Kit.panel({
		Name = "Card",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Background,
		Parent = holder,
	})
	Kit.new("UIScale", { Parent = frame })
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 4
	end

	local badge = Kit.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 56, 0.5, 0),
		Size = UDim2.fromOffset(92, 92),
		BackgroundColor3 = Theme.Colors.Cash,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = frame,
	})
	Kit.corner(UDim.new(1, 0)).Parent = badge
	Kit.stroke(Theme.Colors.Stroke, 4).Parent = badge
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(150, 150, 170)).Parent = badge
	local badgeScale = Kit.new("UIScale", { Parent = badge })
	tween(
		badgeScale,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.08 }
	)
	local icon = Kit.new("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromScale(0.74, 0.74),
		Text = "💰",
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		Rotation = -8,
		ZIndex = 3,
		Parent = badge,
	})
	Kit.new("UIScale", { Parent = icon })
	tween(icon, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Rotation = 8 })
	local check = Kit.label("✅", 64, {
		Name = "Check",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(80, 80),
		Visible = false,
		ZIndex = 4,
		Parent = badge,
	})
	Kit.new("UIScale", { Parent = check })

	local title = Kit.label("", 30, {
		Name = "Title",
		Position = UDim2.fromOffset(114, 12),
		Size = UDim2.new(1, -130, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextScaled = true,
		Parent = frame,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 14, Parent = title })
	Kit.new("UIScale", { Parent = title })
	local hint = Kit.label("", 19, {
		Name = "Hint",
		Position = UDim2.fromOffset(114, 52),
		Size = UDim2.new(1, -130, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.Colors.TextDim,
		TextWrapped = false,
		TextScaled = true,
		Parent = frame,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 19, MinTextSize = 11, Parent = hint })

	local dotRow = Kit.new("Frame", {
		Name = "Dots",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(114, 84),
		Size = UDim2.fromOffset(200, 14),
		Parent = frame,
	})
	Kit.list(Enum.FillDirection.Horizontal, 7, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		dotRow
	local dots: { Frame } = {}
	for i = 1, #TutorialController.STEPS do
		local d = Kit.new("Frame", {
			Name = "Dot" .. i,
			Size = UDim2.fromOffset(28, 10),
			BackgroundColor3 = Theme.Colors.PanelLight,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Parent = dotRow,
		})
		Kit.corner(UDim.new(1, 0)).Parent = d
		Kit.stroke(Theme.Colors.Stroke, 2).Parent = d
		dots[i] = d
	end

	local timerTrack = Kit.new("Frame", {
		Name = "TimerTrack",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -5),
		Size = UDim2.new(1, -40, 0, 5),
		Parent = frame,
	})
	local timerFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.Colors.Cash,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = timerTrack,
	})
	Kit.corner(UDim.new(1, 0)).Parent = timerFill

	-- keycap ("hold E"): chunky key with a darker base so it reads as a physical button
	local key = Kit.new("Frame", {
		Name = "Key",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -20, 0.5, 2),
		Size = UDim2.fromOffset(64, 64),
		BackgroundColor3 = Theme.Colors.Stroke,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
		Parent = frame,
	})
	Kit.corner(UDim.new(0, 14)).Parent = key
	local keyTop = Kit.new("Frame", {
		Name = "Top",
		Size = UDim2.new(1, 0, 1, -7),
		BackgroundColor3 = Color3.fromRGB(245, 246, 255),
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = key,
	})
	-- the "press" pulse lives on the key top: Kit.pop(key) owns the key's own UIScale, and a pop tween on the same
	-- UIScale would cancel this infinite one
	local keyScale = Kit.new("UIScale", { Parent = keyTop })
	tween(keyScale, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true), { Scale = 0.9 })
	Kit.corner(UDim.new(0, 14)).Parent = keyTop
	Kit.stroke(Theme.Colors.Stroke, 3).Parent = keyTop
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(200, 205, 225)).Parent = keyTop
	local keyLabel = Kit.label("E", 34, {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		TextColor3 = Theme.Colors.Primary,
		TextWrapped = false,
		ZIndex = 5,
		Parent = keyTop,
	})
	local keyHold = Kit.label("HOLD", 13, {
		Name = "Hold",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 2),
		Size = UDim2.fromOffset(64, 16),
		TextWrapped = false,
		ZIndex = 5,
		Parent = key,
	})

	local skip = Kit.button("SKIP ⏭", Theme.Colors.PanelLight, {
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 6, 0, -2),
		Size = UDim2.fromOffset(104, 36),
		TextSize = 17,
		ZIndex = 6,
		Parent = frame,
	})
	skip.Activated:Connect(onSkip)

	return {
		gui = gui,
		holder = holder,
		card = frame,
		cardStroke = stroke,
		badge = badge,
		icon = icon,
		check = check,
		title = title,
		hint = hint,
		dots = dots,
		timerFill = timerFill,
		skip = skip,
		key = key,
		keyLabel = keyLabel,
		keyHold = keyHold,
	}
end

local function renderDots(c: CardUI, current: number)
	for i, d in c.dots do
		local color = if i < current
			then Theme.Colors.Cash
			elseif i == current then Theme.Colors.Primary
			else Theme.Colors.PanelLight
		d.BackgroundColor3 = color
		d.Size = if i == current then UDim2.fromOffset(40, 12) else UDim2.fromOffset(28, 10)
	end
end

local function renderStep(index: number, forward: boolean)
	local c = card
	local def = TutorialController.STEPS[index]
	if not c or not def then
		return
	end
	renderToken += 1
	local token = renderToken
	local function apply()
		if token ~= renderToken or not c.gui.Parent then
			return
		end
		local input = inputKind()
		local reenter = index == STEP_STEAL and reenterMode
		c.icon.Text = def.icon
		c.title.Text = if reenter then "GET BACK IN!" else def.title
		c.hint.Text = if reenter then "Hop back in your glowing car" else TutorialController.hintFor(def, input)
		local showKey = def.key == true
		c.key.Visible = showKey
		c.keyLabel.Text = if reenter then TutorialController.enterKeyFor(input) else TutorialController.keyFor(input)
		c.keyHold.Visible = not reenter -- the enter prompt is a tap/press, not a hold
		local textWidth = if showKey then UDim.new(1, -210) else UDim.new(1, -130)
		c.title.Size = UDim2.new(textWidth, UDim.new(0, 38))
		c.hint.Size = UDim2.new(textWidth, UDim.new(0, 26))
		if showKey then
			Kit.pop(c.key, 1.4)
		end
		c.badge.BackgroundColor3 = def.color
		if c.cardStroke then
			c.cardStroke.Color = def.color
		end
		renderDots(c, index)
		Kit.pop(c.title, 1.25)
		Kit.pop(c.icon, 1.5)
		c.timerFill.BackgroundColor3 = def.color
		if def.timed then
			c.timerFill.Size = UDim2.fromScale(1, 1)
			tween(c.timerFill, TweenInfo.new(def.timed, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) })
		else
			c.timerFill.Size = UDim2.fromScale(0, 1)
		end
	end
	if forward and index > 1 then
		-- check-mark payoff for the step just finished, then swap in the next objective
		c.check.Visible = true
		Kit.pop(c.check, 2)
		Kit.pop(c.card, 1.06)
		playSound("Pickup")
		task.delay(0.55, function()
			if token ~= renderToken then
				return
			end
			c.check.Visible = false
			apply()
			playSound("Whoosh")
		end)
	else
		apply()
	end
end

local function cardIn()
	local c = card
	if not c then
		return
	end
	c.holder.Position = UDim2.new(0.5, 0, 1, -CARD_BOTTOM + 160)
	tween(c.holder, Theme.TweenPop, { Position = UDim2.new(0.5, 0, 1, -CARD_BOTTOM) })
	Kit.pop(c.card, 0.6)
end

local function confetti(parent: GuiObject)
	local icons = { "🎉", "💵", "🚗", "⭐", "💰", "🏎️" }
	local rng = Random.new()
	for i = 1, 18 do
		local lbl = Kit.new("TextLabel", {
			Name = "Confetti",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(40, 40),
			Text = icons[(i % #icons) + 1],
			TextScaled = true,
			FontFace = Theme.Fonts.Display,
			Rotation = rng:NextNumber(-30, 30),
			ZIndex = 10,
			Parent = parent,
		})
		local angle = rng:NextNumber(math.pi * 1.05, math.pi * 1.95) -- mostly upward
		local dist = rng:NextNumber(140, 300)
		local target = UDim2.new(0.5, math.cos(angle) * dist, 0.5, math.sin(angle) * dist)
		tween(lbl, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = target,
			Rotation = rng:NextNumber(-200, 200),
		})
		task.delay(0.55, function()
			if lbl.Parent then
				tween(lbl, TweenInfo.new(0.35), { TextTransparency = 1 })
			end
		end)
		task.delay(1, function()
			lbl:Destroy()
		end)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Runtime
-------------------------------------------------------------------------------------------------------------------------

local active = false
local finished = false
local stepIndex = 0
local stepStartedAt = 0
local baseGarage = 0
local baseSteals = 0
local collected = false
local notDrivingSince: number? = nil
local targetCar: Model? = nil
local lastRetarget = -math.huge
local lastCash: number? = nil
local connections: { any } = {} -- RBXScriptConnections + Shared/Util/Signal connections
local startedAt = 0
local focusReleased = false

local function disconnectAll()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
end

local function validParked(model: Model?): boolean
	return model ~= nil and model.Parent ~= nil and model:GetAttribute("Kind") == "Parked"
end

-- Our own hotwired car with nobody in it (VehicleService: Kind Loot, OwnerUserId = the claimer, DriverUserId 0).
local function isOwnIdleLoot(model: Model?): boolean
	if model == nil or model.Parent == nil or model:GetAttribute("Kind") ~= "Loot" then
		return false
	end
	if model:GetAttribute("OwnerUserId") ~= player.UserId then
		return false
	end
	local driver = model:GetAttribute("DriverUserId")
	return driver == nil or driver == 0
end

local function validTarget(model: Model?): boolean
	return if reenterMode then isOwnIdleLoot(model) else validParked(model)
end

-- The car we hotwired and hopped out of, if it is still close.
local function ownLootCar(origin: Vector3): Model?
	local best: Model? = nil
	local bestDist = REENTER_RADIUS
	for _, inst in CollectionService:GetTagged("Vehicle") do
		if inst:IsA("Model") and isOwnIdleLoot(inst) then
			local d = (inst:GetPivot().Position - origin).Magnitude
			if d <= bestDist then
				best = inst
				bestDist = d
			end
		end
	end
	return best
end

local function setReenter(on: boolean)
	if on == reenterMode then
		return
	end
	reenterMode = on
	if stepIndex == STEP_STEAL and card then
		renderStep(STEP_STEAL, false)
	end
end

-- Step 2 target, in order: our own abandoned hotwired car; the newbie car StreetSpawnService tagged for us
-- (TutorialForUserId); the nearest Parked car on the street side of our garage door (sticky unless another is clearly
-- closer); any Parked car. While we are still inside the garage the arrow points at the door (the highlight stays on
-- the car) so it never leads through a wall.
local function retarget()
	lastRetarget = os.clock()
	local root = rootPart()
	if not root then
		return
	end
	local origin = root.Position
	local own = ownLootCar(origin)
	if own then
		setReenter(true)
		targetCar = own
		highlightCar(own)
		setWaypoint(own, Theme.Colors.Secondary, "GET IN")
		return
	end
	setReenter(false)

	local door, face = doorInfo()
	local reserved: Model? = nil
	local models: { Model } = {}
	local candidates: { Candidate } = {}
	local frontModels: { Model } = {}
	local frontCandidates: { Candidate } = {}
	for _, inst in CollectionService:GetTagged("Vehicle") do
		if inst:IsA("Model") and inst.Parent and inst:GetAttribute("Kind") == "Parked" then
			local pos = inst:GetPivot().Position
			local cand: Candidate = { position = pos, kind = "Parked" }
			table.insert(models, inst)
			table.insert(candidates, cand)
			if inst:GetAttribute("TutorialForUserId") == player.UserId then
				reserved = inst
			end
			if door and face and TutorialController.inFrontOfDoor(pos, door, face) then
				table.insert(frontModels, inst)
				table.insert(frontCandidates, cand)
			end
		end
	end

	local best: Model? = reserved
	if not best then
		local idx = TutorialController.pickNearest(frontCandidates, origin, TARGET_MAX_DISTANCE)
		if idx then
			best = frontModels[idx]
		else
			idx = TutorialController.pickNearest(candidates, origin)
			best = if idx then models[idx] else nil
		end
		local current = targetCar
		if best and validParked(current) and current ~= best then
			local dCur = ((current :: Model):GetPivot().Position - origin).Magnitude
			local dBest = (best:GetPivot().Position - origin).Magnitude
			local currentFront = door ~= nil
				and face ~= nil
				and TutorialController.inFrontOfDoor((current :: Model):GetPivot().Position, door, face)
			local bestFront = table.find(frontModels, best) ~= nil
			if dCur - dBest < RETARGET_HYSTERESIS and (currentFront or not bestFront) then
				best = current
			end
		end
	end

	if best then
		targetCar = best
		highlightCar(best)
		if door and face and insideOwnGarage() then
			setWaypoint(door + face * 6, Theme.Colors.Secondary, "GO OUT")
		else
			setWaypoint(best, Theme.Colors.Secondary, "STEAL!")
		end
	else
		targetCar = nil
		clearHighlight()
		local street = streetPosition()
		if street then
			setWaypoint(street, Theme.Colors.Secondary, "STREET")
		end
	end
end

local function enterStep(index: number)
	if index == STEP_MONEY then
		setHudFocus(not focusReleased)
		local pad = findCollectPad()
		setWaypoint(pad or collectPadPosition(), Theme.Colors.Cash, "CASH PAD")
	elseif index == STEP_STEAL then
		setHudFocus(not focusReleased)
		targetCar = nil
		reenterMode = false
		retarget()
	elseif index == STEP_DELIVER then
		clearHighlight()
		targetCar = nil
		-- WaypointController's automatic "home" waypoint takes over; only point home ourselves without it.
		if lazy("WaypointController") then
			setWaypoint(nil)
		else
			setWaypoint(dropoffPosition(), Theme.Colors.Primary, "HOME")
		end
	elseif index == STEP_COLLECT then
		clearHighlight()
		setHudFocus(false)
		local pad = findCollectPad()
		setWaypoint(pad or collectPadPosition(), Theme.Colors.Cash, "COLLECT $")
	elseif index == STEP_DEALER then
		setHudFocus(false)
		local ok, pos = pcall(MapLayout.poiCenter, "Dealership")
		setWaypoint(if ok then pos else nil, Theme.Colors.Gold, "DEALERSHIP")
	end
end

local function teardown()
	active = false
	disconnectAll()
	setWaypoint(nil)
	clearHighlight()
	clearFallback()
	setHudFocus(false)
end

local function finish(skipped: boolean, notifyServer: boolean)
	if finished then
		return
	end
	finished = true
	teardown()
	if notifyServer then
		pcall(Net.fire, "TutorialDone")
	end
	TutorialController.Finished:Fire(skipped)
	local c = card
	card = nil
	if not c then
		return
	end
	local function slideOut(delay: number)
		task.delay(delay, function()
			if not c.gui.Parent then
				return
			end
			local t = tween(
				c.holder,
				TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, 0, 1, -CARD_BOTTOM + 200) }
			)
			t.Completed:Once(function()
				c.gui:Destroy()
			end)
		end)
	end
	if skipped or not notifyServer then
		slideOut(0)
		return
	end
	-- celebration
	c.skip.Visible = false
	c.key.Visible = false
	c.icon.Text = "🎉"
	c.title.Text = "YOU'RE A CAR THIEF NOW!"
	c.hint.Text = "Steal rarer cars • stack cash • rebirth"
	c.badge.BackgroundColor3 = Theme.Colors.Gold
	if c.cardStroke then
		c.cardStroke.Color = Theme.Colors.Gold
	end
	renderDots(c, #TutorialController.STEPS + 1)
	c.timerFill.Size = UDim2.fromScale(0, 1)
	Kit.pop(c.card, 1.15)
	Kit.pop(c.icon, 1.8)
	confetti(c.card)
	playSound("CashBig")
	slideOut(3)
end

local function goTo(index: number)
	local prev = stepIndex
	stepIndex = index
	stepStartedAt = os.clock()
	collected = false
	if index >= DONE then
		finish(false, true)
		return
	end
	enterStep(index)
	renderStep(index, index > prev)
	TutorialController.StepChanged:Fire(index, TutorialController.STEPS[index].id)
end

local function tick()
	local now = os.clock()
	local driving = drivingDeliverable()
	if driving then
		notDrivingSince = nil
	elseif notDrivingSince == nil then
		notDrivingSince = now
	end
	local snap = StateController.get()
	local delivered = TutorialController.garageCount(snap) > baseGarage
		or TutorialController.stealCount(snap) > baseSteals
	local nextIndex = TutorialController.transition(stepIndex, {
		elapsed = now - stepStartedAt,
		driving = driving,
		notDrivingFor = if notDrivingSince then now - notDrivingSince else 0,
		delivered = delivered,
		collected = collected,
		nearDealer = stepIndex == STEP_DEALER and nearDealer(),
	})
	if nextIndex ~= stepIndex then
		goTo(nextIndex)
		return
	end
	local since = now - lastRetarget
	if stepIndex == STEP_STEAL and (since >= RETARGET_EVERY or (since >= 0.5 and not validTarget(targetCar))) then
		retarget()
	end
	local c = card
	if c then
		local theft = StateController.getTheft()
		local bottom = if theft and theft.active then CARD_BOTTOM_THEFT else CARD_BOTTOM
		if bottom ~= cardBottom then
			cardBottom = bottom
			tween(c.holder, Theme.TweenMedium, { Position = UDim2.new(0.5, 0, 1, -bottom) })
		end
	end
	if not focusReleased and stepIndex <= STEP_DELIVER and now - startedAt > FOCUS_MAX_SECONDS then
		focusReleased = true
		setHudFocus(false) -- never keep the menus away for long, even if the player wanders off
	end
end

local function begin()
	if active or finished then
		return
	end
	active = true
	startedAt = os.clock()
	focusReleased = false
	cardBottom = CARD_BOTTOM
	local snap = StateController.get()
	baseGarage = TutorialController.garageCount(snap)
	baseSteals = TutorialController.stealCount(snap)
	lastCash = nil
	local v = player:GetAttribute("Cash")
	if typeof(v) == "number" then
		lastCash = v
	end

	table.insert(
		connections,
		player:GetAttributeChangedSignal("Cash"):Connect(function()
			local cash = player:GetAttribute("Cash")
			if typeof(cash) ~= "number" then
				return
			end
			local before = lastCash
			lastCash = cash
			if stepIndex == STEP_COLLECT and before ~= nil and cash > before and nearPad() then
				collected = true
			end
		end)
	)
	table.insert(
		connections,
		StateController.Changed:Connect(function(s: any)
			if active and typeof(s) == "table" and s.tutorialDone == true then
				finish(false, false) -- finished elsewhere (server / another session)
			end
		end)
	)

	card = buildCard(function()
		playSound("Click")
		finish(true, true)
	end)
	-- streamer mode hides the card with the rest of the HUD
	local hud = lazy("HUDController")
	if hud and hud.VisibilityChanged and typeof(hud.isHidden) == "function" then
		local function applyHidden(hidden: boolean)
			local c = card
			if c then
				c.gui.Enabled = not hidden
			end
		end
		table.insert(connections, hud.VisibilityChanged:Connect(applyHidden))
		local ok, hidden = pcall(hud.isHidden)
		applyHidden(ok and hidden == true)
	end
	cardIn()
	stepIndex = 0
	goTo(STEP_MONEY)

	task.spawn(function()
		while active do
			local ok, err = pcall(tick)
			if not ok then
				warn("[TutorialController] tick error: " .. tostring(err))
			end
			task.wait(TICK)
		end
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

function TutorialController.isActive(): boolean
	return active
end

function TutorialController.getStep(): (number, string?)
	local def = TutorialController.STEPS[stepIndex]
	return stepIndex, if def then def.id else nil
end

function TutorialController.skip()
	if active then
		finish(true, true)
	end
end

function TutorialController.init() end

function TutorialController.start()
	StateController.onReady(function(snap: any)
		if TutorialController.alreadyDelivered(snap) then
			-- left mid-tutorial last session after delivering a car: persist "done" instead of replaying step 1
			pcall(Net.fire, "TutorialDone")
			return
		end
		if not TutorialController.shouldRun(snap) then
			return
		end
		task.wait(START_DELAY)
		-- wait (bounded) for our plot + character so the first waypoint has somewhere to point
		local deadline = os.clock() + 20
		while (plotIndex() == nil or rootPart() == nil) and os.clock() < deadline do
			task.wait(0.25)
		end
		local latest = StateController.get()
		if latest and not TutorialController.shouldRun(latest) then
			return
		end
		begin()
	end)
end

return TutorialController
