--!strict
-- VehicleClient: drives the local player's car.
--   * Detects the local Humanoid sitting in the DriverSeat of a model tagged "Vehicle" and runs a
--     Shared/Vehicle/VehicleController on RunService.PreSimulation (this client is the network owner).
--   * Input: VehicleSeat.ThrottleFloat/SteerFloat (keyboard, gamepad and touch thumbstick via the PlayerModule)
--     + handbrake (Space / ButtonX / DRIFT button), nitro (LeftShift / ButtonR1 / NITRO button),
--     horn (H / ButtonY / HORN button), exit (F / E / ButtonA / EXIT button). Auto-accelerate setting.
--   * Driving HUD ("DrivingUI"): speedometer (MPH), rev bar, nitro bar, car health, drift banner, touch buttons.
--   * Feel: FOV kick with speed + nitro, camera shake on crashes, tire smoke + screech while drifting,
--     nitro flame + glow while boosting. Purely local; no remotes fired from here.
-- Wheels of the driven car are posed by WheelAnimator from getController() data (VehicleClient.positionsWheels=false).

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cars = require(Shared.Config.Cars)
local Rarity = require(Shared.Config.Rarity)
local Sounds = require(Shared.Config.Sounds)
local Tuning = require(Shared.Config.Vehicle)
local EconomyMath = require(Shared.Util.EconomyMath)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local VehicleController = require(Shared.Vehicle.VehicleController)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)

local VMath = VehicleController.math

local player = Players.LocalPlayer

local VehicleClient = {}
VehicleClient.Entered = Signal.new() -- (model: Model, controller)
VehicleClient.Exited = Signal.new() -- (model: Model)
-- false: WheelAnimator poses the driven car's wheels using getController() (exact suspension + steer input).
VehicleClient.positionsWheels = false

-- Tuning local to the client feel
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 50
local ACTION_HANDBRAKE = "HC_Handbrake"
local ACTION_NITRO = "HC_Nitro"
local ACTION_HORN = "HC_Horn"
local ACTION_EXIT = "HC_Exit"
local SHAKE_UNDO_BIND = "HC_DriveShakeUndo"
local SHAKE_APPLY_BIND = "HC_DriveShakeApply"
local NITRO_FOV_EXTRA = 8
local FOV_RESPONSE = 5
local CRASH_DROP = 40 -- studs/s of sudden speed loss = crash
local CRASH_WINDOW_DECAY = 300 -- recent-max speed decays this fast (studs/s per s) => ~0.13 s window for CRASH_DROP
local CRASH_COOLDOWN = 0.5
local HORN_COOLDOWN = 0.35
local REV_SEGMENTS = 16
local HINT_SECONDS = 10
local SETTINGS_REFRESH = 1

type Session = {
	model: Model,
	seat: VehicleSeat,
	humanoid: Humanoid,
	chassis: BasePart,
	controller: any,
	def: Cars.CarDef,
	trove: any,
	input: { throttle: number, steer: number, handbrake: boolean, nitro: boolean },
	autoAccelerate: boolean,
	sfx: boolean,
	settingsTimer: number,
	recentMax: number,
	lastCrash: number,
	shake: number,
	shakeOffset: CFrame,
	baseFov: number,
	startedAt: number,
	driftTime: number,
	wasBoosting: boolean,
	wasDrifting: boolean,
	shownMph: number,
	shownLit: number,
	shownNitro: number,
	shownDriftTenths: number,
	nitroWasFull: boolean,
	lastHealth: number,
	fx: {
		smoke: { ParticleEmitter },
		flame: ParticleEmitter?,
		light: PointLight?,
		glow: BasePart?,
		exhaust: Attachment?,
		screech: Sound?,
		horn: Sound?,
	},
}

local session: Session? = nil
local ui: any = nil -- built in start()
local keys = { handbrake = false, nitro = false }
local touch = { handbrake = false, nitro = false }
local lastHorn = 0
local fovTween: Tween? = nil
local normalFov: number? = nil -- the player's on-foot FOV, restored on exit

----------------------------------------------------------------------------------------------------------------------
-- Lazy access to other controllers (pcall: never let a missing/broken sibling break driving)
----------------------------------------------------------------------------------------------------------------------
local siblingCache: { [string]: any } = {}

local function sibling(name: string): any
	local cached = siblingCache[name]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local ms = script.Parent:FindFirstChild(name)
	if ms and ms:IsA("ModuleScript") then
		local ok, mod = pcall(require, ms)
		if ok and type(mod) == "table" then
			siblingCache[name] = mod
			return mod
		end
	end
	siblingCache[name] = false
	return nil
end

local function getSnapshot(): any
	local sc = sibling("StateController")
	if sc and type(sc.get) == "function" then
		local ok, snap = pcall(sc.get)
		if ok and type(snap) == "table" then
			return snap
		end
	end
	return nil
end

type DriverSettings = { autoAccelerate: boolean, sfx: boolean, nitroSeconds: number, infiniteNitro: boolean }

local function readDriverSettings(): DriverSettings
	local out: DriverSettings = { autoAccelerate = false, sfx = true, nitroSeconds = 2.5, infiniteNitro = false }
	local level = 0
	local snap = getSnapshot()
	if snap then
		local settings = snap.settings
		if type(settings) == "table" then
			out.autoAccelerate = settings.autoAccelerate == true
			out.sfx = settings.sfx ~= false
		end
		local upgrades = snap.upgrades
		if type(upgrades) == "table" and type(upgrades.nitro) == "number" then
			level = upgrades.nitro
		end
		local passes = snap.passes
		if type(passes) == "table" then
			out.infiniteNitro = passes.nitro == true
		end
	end
	local ok, seconds = pcall(EconomyMath.upgradeValue, "nitro", level)
	if ok and type(seconds) == "number" then
		out.nitroSeconds = seconds
	end
	return out
end

-- Play a Config.Sounds key through SoundController (if present). Returns true when it was handled.
local function playViaController(key: string, position: Vector3?): boolean
	local sc = sibling("SoundController")
	if sc and type(sc.play) == "function" then
		local ok = pcall(sc.play, key, position)
		return ok
	end
	return false
end

local function makeLocalSound(key: string, parent: Instance): Sound?
	local def = Sounds[key]
	if not def then
		return nil
	end
	local snd = Instance.new("Sound")
	snd.Name = "HC_" .. key
	snd.SoundId = def.id
	snd.Volume = def.volume
	snd.PlaybackSpeed = def.pitch or 1
	snd.Looped = def.looped == true
	snd.RollOffMaxDistance = 250
	snd.Parent = parent
	return snd
end

----------------------------------------------------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------------------------------------------------
local function lerpColor(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, math.clamp(t, 0, 1))
end

local function segmentColor(i: number): Color3
	local t = (i - 1) / (REV_SEGMENTS - 1)
	if t < 0.55 then
		return lerpColor(Theme.Colors.Secondary, Theme.Colors.Primary, t / 0.55)
	end
	return lerpColor(Theme.Colors.Primary, Theme.Colors.Danger, (t - 0.55) / 0.45)
end

local function roundButton(
	icon: string,
	caption: string,
	color: Color3,
	size: number,
	position: UDim2,
	parent: Instance
)
	local btn = Kit.iconButton(icon, caption, color)
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Size = UDim2.fromOffset(size, size)
	btn.Position = position
	local corner = btn:FindFirstChildOfClass("UICorner")
	if corner then
		corner.CornerRadius = UDim.new(1, 0)
	end
	local cap = btn:FindFirstChild("Caption")
	if cap and cap:IsA("TextLabel") then
		cap.TextSize = math.max(13, math.floor(size / 7))
		cap.Position = UDim2.new(0, 0, 1, -(cap.TextSize + 10))
		cap.Size = UDim2.new(1, 0, 0, cap.TextSize + 2)
	end
	local iconLabel = btn:FindFirstChild("Icon")
	if iconLabel and iconLabel:IsA("TextLabel") then
		iconLabel.AnchorPoint = Vector2.new(0.5, 0)
		iconLabel.Position = UDim2.fromScale(0.5, 0.1)
		iconLabel.Size = UDim2.fromScale(0.62, 0.55)
	end
	btn.Parent = parent
	return btn
end

-- Hold-to-use touch button: true while any finger/mouse that began on it is still down.
local function bindHold(btn: GuiButton, field: string)
	local active: InputObject? = nil
	btn.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			active = input;
			(touch :: any)[field] = true
		end
	end)
	local function release(input: InputObject)
		local current = active
		if
			current
			and (
				input == current
				or current.UserInputState == Enum.UserInputState.End
				or current.UserInputState == Enum.UserInputState.Cancel
			)
		then
			active = nil
			(touch :: any)[field] = false
		end
	end
	btn.InputEnded:Connect(release)
	UserInputService.InputEnded:Connect(release) -- finger slid off the button before lifting
end

local function buildUI()
	local gui = Kit.screen("DrivingUI", Theme.Layers.HUD + 1)
	gui.Enabled = false
	local root = Kit.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})

	-- Speedometer ----------------------------------------------------------------------------------------------
	local speedo = Kit.panel({
		Name = "Speedometer",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(340, 156),
		Parent = root,
	})
	local speedoScale = Kit.new("UIScale", { Parent = speedo })
	-- neon accent strip across the top
	local strip = Kit.new("Frame", {
		Name = "Accent",
		BackgroundColor3 = Theme.Colors.Primary,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(1, -40, 0, 4),
		Parent = speedo,
	})
	Kit.corner(UDim.new(1, 0)).Parent = strip
	Kit.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.Secondary, Theme.Colors.Primary),
		Parent = strip,
	})

	local carName = Kit.label("", 17, {
		Name = "CarName",
		Position = UDim2.fromOffset(0, 12),
		Size = UDim2.new(1, 0, 0, 20),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	carName.Parent = speedo

	local speedLabel = Kit.label("0", 66, {
		Name = "Speed",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0.5, 56, 0, 30),
		Size = UDim2.fromOffset(200, 66),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
	})
	speedLabel.Parent = speedo
	Kit.new("UIScale", { Parent = speedLabel })
	local mphLabel = Kit.label("MPH", 22, {
		Name = "Unit",
		Position = UDim2.new(0.5, 62, 0, 62),
		Size = UDim2.fromOffset(80, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.Colors.Secondary,
		TextWrapped = false,
	})
	mphLabel.Parent = speedo
	local boostBadge = Kit.label("NITRO!", 18, {
		Name = "Boost",
		Position = UDim2.new(0.5, 62, 0, 38),
		Size = UDim2.fromOffset(90, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.Colors.Primary,
		TextWrapped = false,
		Visible = false,
	})
	boostBadge.Parent = speedo

	local rev = Kit.new("Frame", {
		Name = "Rev",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 98),
		Size = UDim2.new(1, -36, 0, 20),
		Parent = speedo,
	})
	Kit.list(Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom).Parent =
		rev
	local segments: { Frame } = {}
	for i = 1, REV_SEGMENTS do
		local h = 0.35 + 0.65 * (i / REV_SEGMENTS)
		local seg = Kit.new("Frame", {
			Name = "Seg" .. i,
			LayoutOrder = i,
			BackgroundColor3 = segmentColor(i),
			BackgroundTransparency = 0.8,
			BorderSizePixel = 0,
			Size = UDim2.new(1 / REV_SEGMENTS, -3, h, 0),
			Parent = rev,
		})
		Kit.corner(UDim.new(0, 3)).Parent = seg
		segments[i] = seg
	end

	-- nitro + health bars
	local bars = Kit.new("Frame", {
		Name = "Bars",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 16, 1, -32),
		Size = UDim2.new(1, -32, 0, 24),
		Parent = speedo,
	})
	local function barIcon(text: string, x: UDim): TextLabel
		local l = Kit.label(text, 18, {
			Position = UDim2.new(x, UDim.new(0, 0)),
			Size = UDim2.fromOffset(24, 24),
			TextWrapped = false,
		})
		l.Parent = bars
		return l
	end
	barIcon("🔥", UDim.new(0, 0))
	local nitroBar, setNitro = Kit.progressBar(Theme.Colors.Secondary, {
		Name = "Nitro",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 28, 0.5, 0),
		Size = UDim2.new(0.5, -40, 0, 14),
		Parent = bars,
	})
	Kit.new("UIScale", { Parent = nitroBar })
	local infinity = Kit.label("∞", 18, {
		Name = "Infinite",
		Size = UDim2.fromScale(1, 1),
		TextWrapped = false,
		Visible = false,
		ZIndex = 3,
	})
	infinity.Parent = nitroBar
	barIcon("🔧", UDim.new(0.5, 4))
	local healthBar, setHealth = Kit.progressBar(Theme.Colors.Cash, {
		Name = "Health",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.5, 32, 0.5, 0),
		Size = UDim2.new(0.5, -32, 0, 14),
		Parent = bars,
	})
	Kit.new("UIScale", { Parent = healthBar })

	-- drift banner (above the speedometer)
	local drift = Kit.label("DRIFT!", 38, {
		Name = "Drift",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -46), -- clears the control hint line
		Size = UDim2.fromOffset(320, 44),
		TextColor3 = Theme.Colors.Primary,
		TextWrapped = false,
		Rotation = -4,
		Visible = false,
	})
	drift.Parent = speedo
	local driftScale = Kit.new("UIScale", { Parent = drift })
	local driftSub = Kit.label("+NITRO", 16, {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.fromOffset(200, 20),
		TextColor3 = Theme.Colors.Secondary,
		TextWrapped = false,
	})
	driftSub.Parent = drift

	-- control hint for keyboard / gamepad (fades after a few seconds)
	local hint = Kit.label("", 14, {
		Name = "Hint",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -6),
		Size = UDim2.fromOffset(520, 18),
		TextColor3 = Theme.Colors.TextDim,
		TextWrapped = false,
		FontFace = Theme.Fonts.Body,
	})
	hint.Parent = speedo

	-- Touch buttons -------------------------------------------------------------------------------------------
	local touchFrame = Kit.new("Frame", {
		Name = "Touch",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = UserInputService.TouchEnabled,
		Parent = root,
	})
	local nitroBtn = roundButton("🔥", "NITRO", Theme.Colors.Secondary, 116, UDim2.new(1, -24, 1, -34), touchFrame)
	nitroBtn.Name = "NitroButton"
	local driftBtn = roundButton("💨", "DRIFT", Theme.Colors.Primary, 100, UDim2.new(1, -156, 1, -28), touchFrame)
	driftBtn.Name = "DriftButton"
	local hornBtn = roundButton("📯", "HORN", Theme.Colors.Warning, 84, UDim2.new(1, -40, 1, -170), touchFrame)
	hornBtn.Name = "HornButton"
	local exitBtn = roundButton("🚪", "EXIT", Theme.Colors.Danger, 84, UDim2.new(1, -40, 1, -270), touchFrame)
	exitBtn.Name = "ExitButton"
	bindHold(nitroBtn, "nitro")
	bindHold(driftBtn, "handbrake")
	hornBtn.Activated:Connect(function()
		VehicleClient.honk()
	end)
	exitBtn.Activated:Connect(function()
		VehicleClient.exit()
	end)

	ui = {
		gui = gui,
		speedo = speedo,
		speedoScale = speedoScale,
		carName = carName,
		speed = speedLabel,
		mph = mphLabel,
		boost = boostBadge,
		segments = segments,
		nitroBar = nitroBar,
		setNitro = setNitro,
		infinity = infinity,
		healthBar = healthBar,
		setHealth = setHealth,
		drift = drift,
		driftScale = driftScale,
		driftSub = driftSub,
		hint = hint,
		touchFrame = touchFrame,
		nitroBtn = nitroBtn,
	}
end

local function controlHint(): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return ""
	end
	if UserInputService.GamepadEnabled and UserInputService:GetLastInputType().Name:find("Gamepad") then
		return "RT/LT drive   X drift   RB nitro   Y horn   A exit"
	end
	return "WASD drive   SPACE drift   SHIFT nitro   H horn   F exit"
end

local function setRev(lit: number, boosting: boolean)
	for i, seg in ui.segments do
		local on = i <= lit
		seg.BackgroundTransparency = if on then 0 else 0.8
		seg.BackgroundColor3 = if boosting and on then Theme.Colors.Secondary else segmentColor(i)
	end
end

local function updateHealthUI(s: Session, animate: boolean)
	if not ui then
		return
	end
	local hp = s.model:GetAttribute("Health")
	local frac = if typeof(hp) == "number" then hp / Tuning.MAX_HEALTH else 1
	frac = math.clamp(frac, 0, 1)
	ui.setHealth(frac, animate)
	local fill = ui.healthBar:FindFirstChild("Fill")
	if fill and fill:IsA("Frame") then
		fill.BackgroundColor3 = if frac > 0.5
			then Theme.Colors.Cash
			elseif frac > 0.25 then Theme.Colors.Warning
			else Theme.Colors.Danger
	end
end

local function showUI(s: Session)
	if not ui then
		return
	end
	local tier = Rarity.Tiers[s.def.rarity]
	ui.carName.Text = s.def.name
	ui.carName.TextColor3 = if tier then tier.color else Theme.Colors.Text
	ui.speed.Text = "0"
	ui.speed.TextColor3 = Theme.Colors.Text
	ui.boost.Visible = false
	ui.drift.Visible = false
	ui.hint.Text = controlHint()
	ui.hint.TextTransparency = 0
	ui.infinity.Visible = s.controller.infiniteNitro == true
	ui.touchFrame.Visible = UserInputService.TouchEnabled
	setRev(0, false)
	ui.setNitro(s.controller.nitro, false)
	updateHealthUI(s, false)
	ui.gui.Enabled = true
	-- slide up + pop
	ui.speedo.Position = UDim2.new(0.5, 0, 1, 190)
	TweenService:Create(ui.speedo, Theme.TweenPop, { Position = UDim2.new(0.5, 0, 1, -12) }):Play()
	Kit.pop(ui.touchFrame.NitroButton, 0.6)
end

local function hideUI()
	if ui then
		ui.gui.Enabled = false
	end
end

----------------------------------------------------------------------------------------------------------------------
-- Local FX
----------------------------------------------------------------------------------------------------------------------
local function buildFx(s: Session)
	local chassis = s.chassis
	local trove = s.trove
	local radius = s.controller.wheelRadius or 1.2
	local wheels = s.controller.wheels or {}

	for i = 3, 4 do
		local w = wheels[i]
		local base = if w then w.attachment.Position else Vector3.new(if i == 3 then -2.5 else 2.5, -1, 4)
		local att = trove:Add(Instance.new("Attachment"))
		att.Name = "HC_Smoke" .. i
		att.Position = base - Vector3.new(0, radius * 0.85, 0)
		att.Parent = chassis
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "TireSmoke"
		pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
		pe.Color = ColorSequence.new(Color3.fromRGB(240, 240, 245), Color3.fromRGB(185, 185, 200))
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 6) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		pe.Lifetime = NumberRange.new(0.7, 1.3)
		pe.Rate = 45
		pe.Speed = NumberRange.new(2, 6)
		pe.SpreadAngle = Vector2.new(35, 35)
		pe.Acceleration = Vector3.new(0, 4, 0)
		pe.Drag = 2
		pe.Rotation = NumberRange.new(0, 360)
		pe.RotSpeed = NumberRange.new(-60, 60)
		pe.LightInfluence = 0.6
		pe.EmissionDirection = Enum.NormalId.Back
		pe.Enabled = false
		pe.Parent = att
		table.insert(s.fx.smoke, pe)
	end

	local length = s.model:GetAttribute("Length")
	local halfLength = math.max(chassis.Size.Z / 2, (if typeof(length) == "number" then length / 2 - 0.3 else 0))
	local exhaust = trove:Add(Instance.new("Attachment"))
	exhaust.Name = "HC_Exhaust"
	exhaust.Position = Vector3.new(0, 0, halfLength + 0.3)
	exhaust.Parent = chassis
	s.fx.exhaust = exhaust

	local flame = Instance.new("ParticleEmitter")
	flame.Name = "NitroFlame"
	flame.Texture = "rbxasset://textures/particles/fire_main.dds"
	flame.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.25, Theme.Colors.Secondary),
		ColorSequenceKeypoint.new(0.7, Theme.Colors.Primary),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 40, 255)),
	})
	flame.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.8), NumberSequenceKeypoint.new(1, 0.2) })
	flame.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	flame.Lifetime = NumberRange.new(0.12, 0.26)
	flame.Rate = 140
	flame.Speed = NumberRange.new(28, 40)
	flame.SpreadAngle = Vector2.new(8, 8)
	flame.LightEmission = 1
	flame.LightInfluence = 0
	flame.EmissionDirection = Enum.NormalId.Back
	flame.ZOffset = 1
	flame.Enabled = false
	flame.Parent = exhaust
	s.fx.flame = flame

	local light = Instance.new("PointLight")
	light.Name = "NitroLight"
	light.Color = Theme.Colors.Secondary
	light.Range = 14
	light.Brightness = 3
	light.Enabled = false
	light.Parent = exhaust
	s.fx.light = light

	local glow = trove:Add(Instance.new("Part"))
	glow.Name = "HC_NitroGlow"
	glow.Shape = Enum.PartType.Ball
	glow.Size = Vector3.new(1.6, 1.6, 1.6)
	glow.Material = Enum.Material.Neon
	glow.Color = Theme.Colors.Secondary
	glow.Anchored = true
	glow.CanCollide = false
	glow.CanQuery = false
	glow.CanTouch = false
	glow.CastShadow = false
	glow.Transparency = 1
	glow.Parent = Workspace.CurrentCamera or Workspace
	s.fx.glow = glow

	local screech = makeLocalSound("TireScreech", chassis)
	if screech then
		trove:Add(screech)
		screech.Volume = 0
		s.fx.screech = screech
	end
end

----------------------------------------------------------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------------------------------------------------------
local function holdHandler(field: string)
	return function(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin then
			(keys :: any)[field] = true
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			(keys :: any)[field] = false
		end
		return Enum.ContextActionResult.Sink
	end
end

local function pressHandler(fn: () -> ())
	return function(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin then
			fn()
		end
		return Enum.ContextActionResult.Sink
	end
end

local function bindActions()
	-- High priority + Sink: Space must not reach the default Jump (which would pop us out of the seat).
	ContextActionService:BindActionAtPriority(
		ACTION_HANDBRAKE,
		holdHandler("handbrake"),
		false,
		ACTION_PRIORITY,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonX
	)
	ContextActionService:BindActionAtPriority(
		ACTION_NITRO,
		holdHandler("nitro"),
		false,
		ACTION_PRIORITY,
		Enum.KeyCode.LeftShift,
		Enum.KeyCode.ButtonR1
	)
	ContextActionService:BindActionAtPriority(
		ACTION_HORN,
		pressHandler(function()
			VehicleClient.honk()
		end),
		false,
		ACTION_PRIORITY,
		Enum.KeyCode.H,
		Enum.KeyCode.ButtonY
	)
	ContextActionService:BindActionAtPriority(
		ACTION_EXIT,
		pressHandler(function()
			VehicleClient.exit()
		end),
		false,
		ACTION_PRIORITY,
		Enum.KeyCode.F,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonA -- gamepad "jump" = leave the seat (Jumping is disabled while driving)
	)
end

local function unbindActions()
	for _, name in { ACTION_HANDBRAKE, ACTION_NITRO, ACTION_HORN, ACTION_EXIT } do
		pcall(function()
			ContextActionService:UnbindAction(name)
		end)
	end
	keys.handbrake = false
	keys.nitro = false
	touch.handbrake = false
	touch.nitro = false
end

----------------------------------------------------------------------------------------------------------------------
-- Per-frame
----------------------------------------------------------------------------------------------------------------------
local exitVehicle: () -> ()

local function onCrash(s: Session, drop: number)
	s.lastCrash = os.clock()
	s.shake = math.max(s.shake, Tuning.CAMERA_SHAKE_ON_CRASH * math.clamp(drop / 70, 0.5, 1.6))
	if s.sfx and not playViaController("Crash", s.chassis.Position) then
		local snd = makeLocalSound("Crash", s.chassis)
		if snd then
			snd:Play()
			snd.Ended:Once(function()
				snd:Destroy()
			end)
		end
	end
	if ui then
		Kit.pop(ui.speedo, 1.08)
	end
end

local function simStep(s: Session, dt: number)
	if session ~= s then
		return
	end
	if s.seat.Parent == nil or s.model.Parent == nil or s.humanoid.SeatPart ~= s.seat then
		exitVehicle()
		return
	end

	s.settingsTimer += dt
	if s.settingsTimer >= SETTINGS_REFRESH then
		s.settingsTimer = 0
		local settings = readDriverSettings()
		s.autoAccelerate = settings.autoAccelerate
		s.sfx = settings.sfx
		s.controller:setNitroTank(settings.nitroSeconds, settings.infiniteNitro)
	end

	local throttle = s.seat.ThrottleFloat
	local steer = s.seat.SteerFloat
	if s.autoAccelerate and throttle >= -0.1 then
		throttle = 1
	end
	if player:GetAttribute("Stunned") == true then
		throttle, steer = 0, 0
	end
	local input = s.input
	input.throttle = throttle
	input.steer = steer
	input.handbrake = keys.handbrake or touch.handbrake
	input.nitro = keys.nitro or touch.nitro
	local controller = s.controller
	controller:setInput(input)
	controller:step(dt)

	-- crash detection: sudden loss of speed against a decaying recent maximum
	local speed = controller.speed
	s.recentMax = math.max(speed, s.recentMax - CRASH_WINDOW_DECAY * dt)
	local drop = s.recentMax - speed
	if drop > CRASH_DROP and os.clock() - s.lastCrash > CRASH_COOLDOWN then
		onCrash(s, drop)
		s.recentMax = speed
	end
end

local function renderStep(s: Session, dt: number)
	if session ~= s or not ui then
		return
	end
	local c = s.controller
	local def = s.def
	local boosting = c.boosting == true
	local drifting = c.drifting == true

	-- speedometer
	local mph = math.floor(VMath.mph(c.speed) + 0.5)
	if mph ~= s.shownMph then
		s.shownMph = mph
		ui.speed.Text = tostring(mph)
	end
	local lit = math.ceil(math.clamp(c.speed / math.max(def.topSpeed, 1), 0, 1) * REV_SEGMENTS - 0.01)
	if lit ~= s.shownLit or boosting ~= s.wasBoosting then
		s.shownLit = lit
		setRev(lit, boosting)
	end
	if boosting ~= s.wasBoosting then
		ui.boost.Visible = boosting
		ui.speed.TextColor3 = if boosting then Theme.Colors.Secondary else Theme.Colors.Text
		if boosting then
			Kit.pop(ui.speed, 1.25)
			if s.fx.flame then
				s.fx.flame:Emit(25)
			end
			if s.sfx then
				playViaController("Whoosh", s.chassis.Position)
			end
		end
	end

	-- nitro bar
	if math.abs(c.nitro - s.shownNitro) > 0.004 then
		s.shownNitro = c.nitro
		ui.setNitro(c.nitro, false)
	end
	local full = c.nitro >= 0.999
	if full and not s.nitroWasFull and not c.infiniteNitro then
		Kit.pop(ui.nitroBar, 1.25)
		Kit.pop(ui.nitroBtn, 1.15)
	end
	s.nitroWasFull = full
	ui.infinity.Visible = c.infiniteNitro == true

	-- drift banner
	if drifting then
		s.driftTime += dt
		if not s.wasDrifting then
			ui.drift.Visible = true
			ui.driftScale.Scale = 0.6
			TweenService:Create(ui.driftScale, Theme.TweenPop, { Scale = 1 }):Play()
		end
		local tenths = math.floor(s.driftTime * 10)
		if tenths ~= s.shownDriftTenths then
			s.shownDriftTenths = tenths
			ui.drift.Text = string.format("DRIFT! %.1fs", tenths / 10)
			ui.drift.TextColor3 = Color3.fromHSV((os.clock() * 0.8) % 1, 0.65, 1)
		end
	elseif s.wasDrifting then
		ui.drift.Visible = false
		s.driftTime = 0
		s.shownDriftTenths = -1
	end

	-- control hint fades out
	local age = os.clock() - s.startedAt
	if age > HINT_SECONDS and ui.hint.TextTransparency < 1 then
		ui.hint.TextTransparency = math.min(1, (age - HINT_SECONDS) / 1.5)
	end

	-- camera FOV kick
	local cam = Workspace.CurrentCamera
	if cam then
		local frac = math.clamp(c.speed / math.max(def.topSpeed, 1), 0, 1)
		local target = Tuning.FOV_BASE + Tuning.FOV_MAX_BONUS * frac * frac + (if boosting then NITRO_FOV_EXTRA else 0)
		cam.FieldOfView += (target - cam.FieldOfView) * math.min(1, FOV_RESPONSE * dt)
	end

	-- FX
	local fx = s.fx
	for i, pe in fx.smoke do
		local on = drifting and c.wheelGrounded[i + 2] == true
		if pe.Enabled ~= on then
			pe.Enabled = on
		end
	end
	if fx.flame and fx.flame.Enabled ~= boosting then
		fx.flame.Enabled = boosting
	end
	if fx.light and fx.light.Enabled ~= boosting then
		fx.light.Enabled = boosting
	end
	if fx.glow and fx.exhaust then
		if boosting then
			local flicker = 0.85 + math.random() * 0.35
			fx.glow.Size = Vector3.new(1.6, 1.6, 1.6) * flicker
			fx.glow.CFrame = fx.exhaust.WorldCFrame
			fx.glow.Transparency = 0.15
		elseif fx.glow.Transparency < 1 then
			fx.glow.Transparency = 1
		end
	end
	local screech = fx.screech
	if screech then
		local base = (Sounds.TireScreech.volume or 0.35) * (if s.sfx then 1 else 0)
		local targetVol = if drifting then base * math.clamp(math.abs(c.lateralSpeed) / 30, 0.5, 1.3) else 0
		screech.Volume += (targetVol - screech.Volume) * math.min(1, 10 * dt)
		if screech.Volume > 0.02 and not screech.IsPlaying then
			screech:Play()
		elseif screech.Volume <= 0.02 and screech.IsPlaying and not drifting then
			screech:Stop()
		end
	end

	s.wasBoosting = boosting
	s.wasDrifting = drifting
end

-- Camera shake: remove last frame's offset before the camera scripts run, re-apply after them (no drift).
local function shakeUndo(s: Session)
	local cam = Workspace.CurrentCamera
	if cam and s.shakeOffset ~= CFrame.identity then
		cam.CFrame = cam.CFrame * s.shakeOffset:Inverse()
		s.shakeOffset = CFrame.identity
	end
end

local function shakeApply(s: Session, dt: number)
	local cam = Workspace.CurrentCamera
	if not cam or s.shake <= 0.001 then
		return
	end
	local a = s.shake
	local offset = CFrame.Angles((math.random() - 0.5) * 0.07 * a, (math.random() - 0.5) * 0.07 * a, 0)
	cam.CFrame = cam.CFrame * offset
	s.shakeOffset = offset
	s.shake = math.max(0, s.shake - dt * 2.2)
end

----------------------------------------------------------------------------------------------------------------------
-- Enter / exit
----------------------------------------------------------------------------------------------------------------------
local function resolveDef(model: Model): Cars.CarDef
	local carId = model:GetAttribute("CarId")
	if model:GetAttribute("Kind") == "Police" or carId == Cars.Police.id then
		return Cars.Police
	end
	local def = if typeof(carId) == "string" then Cars.get(carId) else nil
	return def or Cars.List[1]
end

local function carModelFromSeat(seat: Instance): Model?
	if not seat:IsA("VehicleSeat") or seat.Name ~= "DriverSeat" then
		return nil
	end
	local node = seat.Parent
	while node and node ~= Workspace do
		if
			node:IsA("Model") and (CollectionService:HasTag(node, "Vehicle") or node:GetAttribute("VehicleId") ~= nil)
		then
			return node
		end
		node = node.Parent
	end
	return nil
end

exitVehicle = function()
	local s = session
	if not s then
		return
	end
	session = nil
	pcall(function()
		s.controller:destroy()
	end)
	unbindActions()
	pcall(function()
		RunService:UnbindFromRenderStep(SHAKE_UNDO_BIND)
		RunService:UnbindFromRenderStep(SHAKE_APPLY_BIND)
	end)
	shakeUndo(s)
	s.trove:Destroy()
	if s.humanoid.Parent then
		s.humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	end
	local cam = Workspace.CurrentCamera
	if cam then
		local tween = TweenService:Create(cam, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FieldOfView = s.baseFov,
		})
		fovTween = tween
		tween.Completed:Once(function()
			if fovTween == tween then
				fovTween = nil
			end
		end)
		tween:Play()
	end
	hideUI()
	VehicleClient.Exited:Fire(s.model)
end

local function enter(seat: VehicleSeat, model: Model, humanoid: Humanoid)
	if session then
		if session.seat == seat then
			return
		end
		exitVehicle()
	end
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not (chassis and chassis:IsA("BasePart")) then
		return
	end
	local def = resolveDef(model)
	local settings = readDriverSettings()
	local ok, controller = pcall(VehicleController.new, model, def, {
		isServer = false,
		nitroSeconds = settings.nitroSeconds,
		infiniteNitro = settings.infiniteNitro,
	})
	if not ok then
		warn("[VehicleClient] could not start controller: " .. tostring(controller))
		return
	end
	local cam = Workspace.CurrentCamera
	if fovTween then
		-- re-entered while the exit tween was still restoring: keep the FOV captured before the last drive
		fovTween:Cancel()
		fovTween = nil
	elseif cam then
		normalFov = math.clamp(cam.FieldOfView, 40, 100)
	end
	local s: Session = {
		model = model,
		seat = seat,
		humanoid = humanoid,
		chassis = chassis,
		controller = controller,
		def = def,
		trove = Trove.new(),
		input = { throttle = 0, steer = 0, handbrake = false, nitro = false },
		autoAccelerate = settings.autoAccelerate,
		sfx = settings.sfx,
		settingsTimer = 0,
		recentMax = 0,
		lastCrash = 0,
		shake = 0,
		shakeOffset = CFrame.identity,
		baseFov = normalFov or Tuning.FOV_BASE,
		startedAt = os.clock(),
		driftTime = 0,
		wasBoosting = false,
		wasDrifting = false,
		shownMph = -1,
		shownLit = -1,
		shownNitro = -1,
		shownDriftTenths = -1,
		nitroWasFull = true,
		lastHealth = (function(): number
			local hp = model:GetAttribute("Health")
			return if typeof(hp) == "number" then hp else Tuning.MAX_HEALTH
		end)(),
		fx = { smoke = {} },
	}
	session = s

	-- Space is our handbrake: with Jumping disabled the default jump can't throw us out of the seat.
	-- Exit is explicit (F / E / ButtonA / EXIT button) and re-enables jumping first.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	bindActions()
	local okFx, fxErr = pcall(buildFx, s)
	if not okFx then
		warn("[VehicleClient] fx: " .. tostring(fxErr))
	end
	showUI(s)

	local trove = s.trove
	trove:Connect(RunService.PreSimulation, function(dt: number)
		simStep(s, dt)
	end)
	trove:Connect(RunService.PreRender, function(dt: number)
		renderStep(s, dt)
	end)
	RunService:BindToRenderStep(SHAKE_UNDO_BIND, Enum.RenderPriority.Camera.Value - 1, function()
		shakeUndo(s)
	end)
	RunService:BindToRenderStep(SHAKE_APPLY_BIND, Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		shakeApply(s, dt)
	end)
	trove:Connect(model:GetAttributeChangedSignal("Health"), function()
		if session ~= s then
			return
		end
		local hp = model:GetAttribute("Health")
		local now = if typeof(hp) == "number" then hp else Tuning.MAX_HEALTH
		updateHealthUI(s, true)
		if now < s.lastHealth and ui then
			Kit.pop(ui.healthBar, 1.25)
		end
		s.lastHealth = now
	end)
	trove:Connect(model.AncestryChanged, function()
		if session == s and not model:IsDescendantOf(game) then
			exitVehicle()
		end
	end)

	VehicleClient.Entered:Fire(model, controller)
end

local function onSeated(humanoid: Humanoid, active: boolean, seatPart: BasePart?)
	if active and seatPart then
		local model = carModelFromSeat(seatPart)
		if model and seatPart:IsA("VehicleSeat") then
			enter(seatPart, model, humanoid)
			return
		end
	end
	if session and session.humanoid == humanoid then
		exitVehicle()
	end
end

local characterTrove = Trove.new()

local function hookCharacter(character: Model)
	characterTrove:Clean()
	local humanoid = character:WaitForChild("Humanoid", 15)
	if not (humanoid and humanoid:IsA("Humanoid")) or character.Parent == nil then
		return
	end
	characterTrove:Connect(humanoid.Seated, function(active: boolean, seatPart: BasePart?)
		onSeated(humanoid, active, seatPart)
	end)
	-- backup for Seated (fires on any SeatPart change; enter() ignores the seat we're already driving)
	characterTrove:Connect(humanoid:GetPropertyChangedSignal("SeatPart"), function()
		local seat = humanoid.SeatPart
		onSeated(humanoid, seat ~= nil, seat)
	end)
	characterTrove:Connect(humanoid.Died, function()
		if session and session.humanoid == humanoid then
			exitVehicle()
		end
	end)
	local seat = humanoid.SeatPart
	if seat then
		onSeated(humanoid, true, seat)
	end
end

----------------------------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------------------------
function VehicleClient.isDriving(): boolean
	return session ~= nil
end

function VehicleClient.getModel(): Model?
	return if session then session.model else nil
end

function VehicleClient.getController(): any
	return if session then session.controller else nil
end

-- Ask to leave the car (same as F / EXIT button).
function VehicleClient.exit()
	local s = session
	if not s then
		return
	end
	local humanoid = s.humanoid
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	humanoid.Jump = true
end

function VehicleClient.honk()
	local s = session
	if not s or os.clock() - lastHorn < HORN_COOLDOWN then
		return
	end
	lastHorn = os.clock()
	if ui then
		Kit.pop(ui.touchFrame.HornButton, 1.2)
	end
	if not s.sfx then
		return
	end
	if playViaController("Horn", s.chassis.Position) then
		return
	end
	local horn = s.fx.horn
	if not horn then
		horn = makeLocalSound("Horn", s.chassis)
		if horn then
			s.trove:Add(horn)
			s.fx.horn = horn
		end
	end
	if horn then
		horn:Play()
	end
end

function VehicleClient.init() end

function VehicleClient.start()
	buildUI()
	player.CharacterAdded:Connect(function(character: Model)
		hookCharacter(character)
	end)
	player.CharacterRemoving:Connect(function()
		exitVehicle()
	end)
	if player.Character then
		task.spawn(hookCharacter, player.Character)
	end
end

return VehicleClient
