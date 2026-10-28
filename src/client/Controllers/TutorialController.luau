--!strict
-- TutorialController (SPEC §2 + §7; v2: gta_ui_language §2.6/§5.5): first-session onboarding for brand-new players
-- (snapshot.tutorialDone == false), told the way GTA teaches: a top-left HELP TEXT box (HUDController.help, with key
-- caps for the current input) plus a bottom-centre OBJECTIVE line with coloured keywords (HUDController.objective),
-- world guidance through WaypointController and a pulsing blue outline on the target car. Nothing blocks input and
-- nothing sits in the middle of the screen; finishing plays the "job complete" shard. Skip lives in the pause menu
-- (SETTINGS > Skip tutorial -> TutorialController.skip()).
--
--   1 money    "Your cars earn cash..."          waypoint -> own cash pad (green), auto-advances after 4s
--   2 steal    "Steal a car."                    waypoint + blue outline on the street car StreetSpawnService
--              reserved for us (TutorialForUserId), else the nearest Parked car on the street side of our garage door
--              (re-picked every 2s). If we already hotwired a car and hopped out, it points back at that car instead
--              ("Get back in the car.", F / Y / tap). Advances when the local player drives a non-owned car
--   3 deliver  "Take the car to your garage."    WaypointController's automatic yellow "home" route guides; advances
--              when the garage gains a car (garage count or steals stat rises); back to 2 if you leave the car
--   4 collect  "Collect your cash..."            waypoint -> cash pad; advances when Cash jumps near the pad, or 20s
--   5 dealer   "Go to the dealership."           yellow waypoint until you arrive (or 90s), then
--              Net.fire("TutorialDone") + "job complete" shard
-- During steps 1-3 the HUD is in focus mode (phone/menu hints hidden); they come back at step 4.
-- Returning players who already delivered a car (stats.steals > 0) never replay it: TutorialDone is sent instead.
--
-- Step 1 starts only once the ReplicatedFirst loading overlay ("HC_Loading") is gone (bounded wait).
-- Public API: isActive(): boolean, getStep(): (number, string?), skip(), loadingScreenUp(): boolean,
--   StepChanged: Signal(index, id), Finished: Signal(skipped: boolean)
-- Pure helpers (tests): STEPS, DONE, transition(step, ctx), pickNearest(candidates, origin, maxDistance?), keyFor,
--   enterKeyFor, shouldRun(snapshot), alreadyDelivered(snapshot), hintFor(stepDef, inputKind), helpText(stepDef, input,
--   reenter?), objectiveText(stepDef, reenter?), garageCount(snapshot), stealCount(snapshot), inFrontOfDoor(pos, door,
--   face), cardBottomAbove(bottom, lockTop?) (v1 layout helper, kept for the leftovers spec)

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
local RichText = require(UI:WaitForChild("RichText"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER: safe to require at the top.
local StateController = require(script.Parent:WaitForChild("StateController"))

local TutorialController = {}

TutorialController.StepChanged = Signal.new() -- (index: number, id: string)
TutorialController.Finished = Signal.new() -- (skipped: boolean)

local player = Players.LocalPlayer
local C = Theme.Colors

export type StepDef = {
	id: string,
	icon: string, -- UIAssets glyph ("hud.cash", ...) for anything that wants a pictogram (pause menu, phone)
	title: string, -- objective line (RichText tags)
	hint: string, -- help text; "{key}" becomes the key cap for the current input
	hintTouch: string?,
	hintPad: string?,
	color: Color3, -- waypoint / blip colour (GTA: blue = target, yellow = destination, green = pickup)
	timed: number?, -- seconds before the step moves on by itself
	key: boolean?, -- the help text carries the "hold this key" cap (E / X / TAP)
}

TutorialController.STEPS = {
	{
		id = "money",
		icon = "hud.cash",
		title = "Your cars earn <g>cash</g> while you play.",
		hint = "Cars stored in your garage earn cash every second. It stacks up on the <g>cash pad</g>.",
		color = C.Green,
		timed = 4,
	},
	{
		id = "steal",
		icon = "hud.car",
		title = "Steal a <blue>car</blue>.",
		hint = "Walk up to the <blue>car</blue> and hold {key} to hotwire it.",
		hintTouch = "Walk up to the <blue>car</blue> and hold the on-screen prompt to hotwire it.",
		hintPad = "Walk up to the <blue>car</blue> and hold {key} to hotwire it.",
		color = C.Blue,
		key = true,
	},
	{
		id = "deliver",
		icon = "hud.pin",
		title = "Take the car to your <y>garage</y>.",
		hint = "Follow the <y>yellow route</y> on the radar and drive into your garage to store the car.",
		color = C.Yellow,
	},
	{
		id = "collect",
		icon = "hud.cash",
		title = "Collect your cash from the <g>cash pad</g>.",
		hint = "Step on the <g>cash pad</g> in your garage to collect what your cars earned.",
		color = C.Green,
	},
	{
		id = "dealer",
		icon = "hud.car",
		title = "Go to the <y>dealership</y>.",
		hint = "Rarer cars earn more cash. Buy them at the <y>dealership</y> or find them on the street. "
			.. RichText.key("P")
			.. " opens the pause menu, "
			.. RichText.key("M")
			.. " the map.",
		hintTouch = "Rarer cars earn more cash. Buy them at the <y>dealership</y>.",
		-- the Start button belongs to Roblox's own menu: the pause menu is on Back / View (MenuController)
		hintPad = "Rarer cars earn more cash. Buy them at the <y>dealership</y>. "
			.. RichText.key("Back")
			.. " opens the pause menu: jobs, garage and the map.",
		color = C.Yellow,
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
-- ReplicatedFirst's loading overlay (src/first/LoadingScreen.client.luau, DisplayOrder 1000) keeps this ScreenGui in
-- PlayerGui until it has faded out; step 1 waits for it (bounded like its HARD_TIMEOUT) so the first help text and
-- waypoint aren't spent behind it on a fresh server.
local LOADING_GUI = "HC_Loading"
TutorialController.LOADING_GUI = LOADING_GUI
local LOADING_WAIT = 25
local NEAR_PAD = 16
local TICK = 0.2
local FOCUS_MAX_SECONDS = 150 -- HUD focus mode never lasts longer than this
local WAYPOINT_ID = "tutorial"
local HELP_ID = "tutorial"
local STREET_AHEAD = 70 -- studs in front of the garage door used as a "go to the street" waypoint
local OBJECTIVE_REPEAT = 25 -- the objective line fades like GTA's; it comes back this often while a step is open
-- GTA help text (gta_ui_language §2.6 / §5.5): the top-left box shows a hint for ~8 s and fades; it comes back only
-- for a NEW hint (next step, another input device, "get back in the car"), never on a timer (job 0006: the hotwire
-- hint stayed on screen for the whole session).
TutorialController.HELP_SECONDS = 8

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

-- Should the help box show `nextText` given what it last showed (pure)? Only a different hint re-shows; nil clears.
function TutorialController.helpAction(lastShown: string?, nextText: string?): string
	if nextText == nil or nextText == "" then
		return if lastShown ~= nil then "clear" else "none"
	end
	return if nextText ~= lastShown then "show" else "none"
end

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

-- Key name for the steal prompt's hold input (ProximityPrompt defaults: E / ButtonX / the on-screen button).
function TutorialController.keyFor(input: InputKind): string
	if input == "touch" then
		return "TAP"
	elseif input == "gamepad" then
		return "X"
	end
	return "E"
end

-- Key name for VehicleService's "Get in" EnterPrompt (F / ButtonY / on-screen button) on our own hotwired car.
function TutorialController.enterKeyFor(input: InputKind): string
	if input == "touch" then
		return "TAP"
	elseif input == "gamepad" then
		return "Y"
	end
	return "F"
end

local REENTER_TITLE = "Get back in the <blue>car</blue>."
local REENTER_HINT = "Press {key} next to the <blue>car</blue> to get back in."
local REENTER_HINT_TOUCH = "Tap the prompt next to the <blue>car</blue> to get back in."

-- Objective line for a step (rich text tags; HUDController formats them).
function TutorialController.objectiveText(step: StepDef, reenter: boolean?): string
	if reenter and step.id == "steal" then
		return REENTER_TITLE
	end
	return step.title
end

-- Help text for a step on this input, with "{key}" replaced by a RichText key cap (touch gets the button name).
function TutorialController.helpText(step: StepDef, input: InputKind, reenter: boolean?): string
	local raw: string
	local keyName: string
	if reenter and step.id == "steal" then
		raw = if input == "touch" then REENTER_HINT_TOUCH else REENTER_HINT
		keyName = TutorialController.enterKeyFor(input)
	else
		raw = TutorialController.hintFor(step, input)
		keyName = TutorialController.keyFor(input)
	end
	local cap = if input == "touch" then RichText.bold(keyName) else RichText.key(keyName)
	return (string.gsub(raw, "{key}", function()
		return cap
	end))
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

-- v1 layout helper (the bottom-centre card is gone; the leftovers spec still pins its maths): a bottom offset that
-- also clears GarageClient's LOCK pill whose top edge is `lockTop` (nil = pill hidden).
function TutorialController.cardBottomAbove(bottom: number, lockTop: number?): number
	if typeof(lockTop) == "number" and lockTop == lockTop then
		return math.max(bottom, math.ceil(lockTop) + 8)
	end
	return bottom
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
-- Guidance: waypoint (WaypointController, lazy) + fallback chevron marker + target outline
-------------------------------------------------------------------------------------------------------------------------

local currentWaypointKey: any = nil
local fallbackGui: BillboardGui? = nil
local fallbackAnchor: Attachment? = nil
local highlight: Highlight? = nil

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

-- Only used when WaypointController is missing: a GTA-style chevron over the target with a small condensed label.
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
		Size = UDim2.fromOffset(120, 84),
		StudsOffsetWorldSpace = Vector3.new(0, 8, 0),
		ResetOnSpawn = false,
		Parent = player:FindFirstChildOfClass("PlayerGui"),
	}) :: BillboardGui
	local chevron = Kit.image("hud.chevron", {
		Name = "Chevron",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 26),
		Size = UDim2.fromOffset(40, 40),
		ImageColor3 = color,
		Parent = gui,
	})
	tween(
		chevron,
		TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.new(0.5, 0, 0, 36) }
	)
	Kit.text(label, "condensed", 18, {
		Name = "Label",
		Size = UDim2.new(1, 0, 0, 22),
		TextColor3 = C.Text,
		TextStrokeColor3 = C.Black,
		TextStrokeTransparency = 0.4,
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
	local c = color or C.Yellow
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
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
end

-- GTA marks the vehicle you are meant to take with the blue chevron and blip; §9 allows only a subtle, static tint
-- on top (accessibility): blue fill at 0.85, a faint outline, hidden behind walls like the car itself. No pulse.
local function highlightCar(model: Model)
	if highlight and highlight.Parent == model then
		return
	end
	clearHighlight()
	local h = Instance.new("Highlight")
	h.Name = "TutorialHighlight"
	h.Adornee = model
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.FillColor = C.Blue
	h.OutlineColor = C.Text
	h.FillTransparency = 0.85
	h.OutlineTransparency = 0.6
	h.Parent = model -- client-local child; vanishes with the car
	highlight = h
end

-------------------------------------------------------------------------------------------------------------------------
-- Help text + objective (HUDController)
-------------------------------------------------------------------------------------------------------------------------

local function hud(): any
	return lazy("HUDController")
end

local lastHelp: string? = nil

local function showHelp(text: string?)
	local h = hud()
	if not h then
		return
	end
	local action = TutorialController.helpAction(lastHelp, text)
	if action == "show" then
		lastHelp = text
		if typeof(h.help) == "function" then
			pcall(h.help, text, { id = HELP_ID, duration = TutorialController.HELP_SECONDS })
		end
	elseif action == "clear" then
		lastHelp = nil
		if typeof(h.clearHelp) == "function" then
			pcall(h.clearHelp, HELP_ID)
		end
	end
end

local function showObjective(text: string?)
	local h = hud()
	if h and typeof(h.objective) == "function" then
		pcall(h.objective, text)
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
local reenterMode = false -- step 2 is pointing back at our own hotwired car ("Get back in the car.")
local renderedInput: InputKind? = nil
local renderedReenter = false
local lastObjectiveAt = 0

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
	reenterMode = on -- tick() re-renders the objective + help text
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
		setWaypoint(own, C.Blue, "CAR")
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
			setWaypoint(door + face * 6, C.Blue, "EXIT")
		else
			setWaypoint(best, C.Blue, "CAR")
		end
	else
		targetCar = nil
		clearHighlight()
		local street = streetPosition()
		if street then
			setWaypoint(street, C.Blue, "STREET")
		end
	end
end

local function render(index: number)
	local def = TutorialController.STEPS[index]
	if not def then
		return
	end
	local input = inputKind()
	local reenter = index == STEP_STEAL and reenterMode
	renderedInput = input
	renderedReenter = reenter
	lastObjectiveAt = os.clock()
	showObjective(TutorialController.objectiveText(def, reenter))
	showHelp(TutorialController.helpText(def, input, reenter))
end

local function enterStep(index: number)
	if index == STEP_MONEY then
		setHudFocus(not focusReleased)
		local pad = findCollectPad()
		setWaypoint(pad or collectPadPosition(), C.Green, "CASH PAD")
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
			setWaypoint(dropoffPosition(), C.Yellow, "GARAGE")
		end
	elseif index == STEP_COLLECT then
		clearHighlight()
		setHudFocus(false)
		local pad = findCollectPad()
		setWaypoint(pad or collectPadPosition(), C.Green, "CASH PAD")
	elseif index == STEP_DEALER then
		setHudFocus(false)
		local ok, pos = pcall(MapLayout.poiCenter, "Dealership")
		setWaypoint(if ok then pos else nil, C.Yellow, "DEALERSHIP")
	end
end

local function teardown()
	active = false
	disconnectAll()
	setWaypoint(nil)
	clearHighlight()
	clearFallback()
	setHudFocus(false)
	showHelp(nil)
	showObjective(nil)
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
	if skipped or not notifyServer then
		return
	end
	-- GTA payoff: the yellow "job complete" shard, then one help line pointing at what to do next
	local h = hud()
	if h and typeof(h.shard) == "function" then
		pcall(h.shard, "job", nil, "You are a car thief now.")
	end
	task.delay(4, function()
		local hh = hud()
		if hh and typeof(hh.help) == "function" then
			local input = inputKind()
			local phone = if input == "touch"
				then "Tap the <b>phone</b> button"
				else "Press " .. RichText.keyFor(input, "B", "D-Pad Up")
			pcall(
				hh.help,
				"Steal rarer cars, stack cash and <y>Prestige</y>. "
					.. phone
					.. " for jobs, contracts and daily rewards.",
				{ id = "tutorial_done", duration = 10 }
			)
		end
	end)
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
	if index > prev and prev >= 1 then
		playSound("Pickup") -- soft "objective done" tick before the next line
	end
	render(index)
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
	-- the input device changed (pad picked up, touch) or the objective faded long ago: re-issue the lines
	if inputKind() ~= renderedInput or (stepIndex == STEP_STEAL and reenterMode ~= renderedReenter) then
		render(stepIndex)
	elseif now - lastObjectiveAt >= OBJECTIVE_REPEAT then
		lastObjectiveAt = now
		local h = hud()
		if h and typeof(h.repeatObjective) == "function" then
			pcall(h.repeatObjective)
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
				finish(false, false) -- finished elsewhere (server / another session / Settings > Skip)
			end
		end)
	)

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

-- True while the ReplicatedFirst loading overlay still covers the screen (its ScreenGui is gone once faded).
function TutorialController.loadingScreenUp(): boolean
	local pg = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	return pg ~= nil and pg:FindFirstChild(LOADING_GUI) ~= nil
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
		local loadingDeadline = os.clock() + LOADING_WAIT
		while TutorialController.loadingScreenUp() and os.clock() < loadingDeadline do
			task.wait(0.25)
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
