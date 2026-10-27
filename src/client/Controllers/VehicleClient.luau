--!strict
-- VehicleClient: drives the local player's car.
--   * Detects the local Humanoid sitting in the DriverSeat of a model tagged "Vehicle" and runs a
--     Shared/Vehicle/VehicleController on RunService.PreSimulation (this client is the network owner).
--   * Input: VehicleSeat.ThrottleFloat/SteerFloat (keyboard, gamepad and touch thumbstick via the PlayerModule)
--     + handbrake (Space / ButtonX / DRIFT button), nitro (LeftShift / ButtonR1 / NITRO button),
--     horn (H / ButtonY / HORN button), exit (F / ButtonA / EXIT button; not E, the hold-to-steal key, so a
--     "Hotwire [E]" prompt on a passing car can't throw the driver out). Auto-accelerate setting.
--   * Driving HUD ("DrivingUI", v2 GTA language): optional small speed readout bottom-right (Settings > Speed
--     readout), a thin car-damage rule, a quiet drift line and the touch circle buttons (HudLayout.buttons). Nitro
--     is the third radar bar segment (HUDController), the car name comes in on the location lines and the radio
--     station at top-centre. A one-off help text lists the controls. The CoreGui backpack hotbar is hidden while
--     driving and restored on exit.
--   * Feel: FOV kick with speed + nitro, camera shake on crashes, screech while drifting. Effects come from the
--     shared VFXLibrary (Config/VFX presets, quality-scaled + budgeted): flipbook tire smoke from the rear wheels and
--     skid-mark Trails that only draw while they slide, nitro = flipbook flame + hot core + shock-diamond jet beam
--     with a flickering light, backfire pops on nitro start and on upshifts (arcade gear points), collision sparks
--     at the contact point on hard hits, surface dust off-road (grass / sand / dirt) and water spray, and speed lines
--     around the camera while boosting. Other players' drift smoke and screech come from WheelAnimator (derived from
--     the replicated chassis velocity); their nitro flames and horn come from the VehicleFx remote: nitro start/stop
--     and horn presses are sent as state changes only (>= FX_MIN_INTERVAL apart, coalesced), the server relays them to
--     nearby clients as VehicleFxState and EffectsController renders them.
--   * Car radio (SoundController plays it): on while driving; R / T keys, D-pad left / right, the RADIO touch
--     button. HUDController.showRadio shows the station + track at top-centre on each change. The first drive
--     tunes a random station. (radioLayout / canvasWidth / textBoost are the v1 pill maths, kept for the specs.)
-- Wheels of the driven car are posed by WheelAnimator from getController() data (VehicleClient.positionsWheels=false).

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cars = require(Shared.Config.Cars)
local Sounds = require(Shared.Config.Sounds)
local Tuning = require(Shared.Config.Vehicle)
local EconomyMath = require(Shared.Util.EconomyMath)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local VehicleController = require(Shared.Vehicle.VehicleController)
local Net = require(Shared.Net)

local UI = script.Parent.Parent:WaitForChild("UI")
local HudLayout = require(UI.HudLayout)
local Kit = require(UI.Kit)
local RichText = require(UI.RichText)
local Theme = require(UI.Theme)
local VFXLibrary = require(script.Parent:WaitForChild("VFXLibrary"))

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
local ACTION_RADIO_PREV = "HC_RadioPrev"
local ACTION_RADIO_NEXT = "HC_RadioNext"
local SHAKE_UNDO_BIND = "HC_DriveShakeUndo"
local SHAKE_APPLY_BIND = "HC_DriveShakeApply"
local NITRO_FOV_EXTRA = 8
local FOV_RESPONSE = 5
local CRASH_DROP = 40 -- studs/s of sudden speed loss = crash
local CRASH_WINDOW_DECAY = 300 -- recent-max speed decays this fast (studs/s per s) => ~0.13 s window for CRASH_DROP
local CRASH_COOLDOWN = 0.5
local HORN_COOLDOWN = 0.35
local FX_MIN_INTERVAL = 0.2 -- s between VehicleFx sends (server bucket: 6/s); newer state waits, then goes out
local SETTINGS_REFRESH = 1
-- v1 dashboard maths (textBoost / radioLayout / canvasWidth), kept as pure helpers for the ap4 + vehicle specs.
local PHONE_TEXT_MAX_BOOST = 1.4
local RADIO_SIZE = Vector2.new(216, 60)
local RADIO_GAP = 6
local RADIO_TOUCH_MIN_WIDTH = 100 -- narrowest compact pill (design px before its UIScale) that still reads
local SPEEDO_HALF_WIDTH = 170
local TOUCH_CLUSTER_LEFT = 256
-- Local VFX
local SURFACE_SAMPLE = 0.2 -- s between ground-material rays (dust / spray)
local DUST_MIN_SPEED = 14
local SPRAY_MIN_SPEED = 8
local SPLASH_MIN_SPEED = 25
local BACKFIRE_COOLDOWN = 0.6
local SPARK_PROBE = 4 -- studs past the bumper the crash ray looks for the contact point
local SPEED_LINE_RING = 8
local SPEED_LINE_RADIUS = 7.5
local SPEED_LINE_AHEAD = 28
local SPEED_LINE_FRACTION = 0.9 -- of top speed: speed lines (lighter) without nitro too

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
	fxBoost: boolean, -- nitro state last sent through VehicleFx
	fxHonk: boolean, -- a horn press waiting to be sent
	fxAt: number, -- os.clock() of the last VehicleFx send
	fx: {
		smoke: { VFXLibrary.Stream }, -- rear-left, rear-right
		skids: { VFXLibrary.TrailRig },
		dust: { VFXLibrary.Stream },
		spray: VFXLibrary.Stream?,
		flame: VFXLibrary.Stream?,
		core: VFXLibrary.Stream?,
		jet: VFXLibrary.BeamRig?,
		light: PointLight?,
		exhaust: Attachment?,
		speedHost: BasePart?,
		speedLines: { VFXLibrary.Stream },
		rayParams: RaycastParams?,
		screech: Sound?,
		horn: Sound?,
	},
	fxSlideOn: boolean,
	fxSlideLevel: number,
	fxGear: number,
	fxBackfireAt: number,
	fxSurfaceT: number,
	fxDust: Color3?,
	fxWater: boolean,
	fxDustOn: boolean,
	fxDustColor: Color3?,
	fxSprayOn: boolean,
	fxLinesLevel: number,
	prevVel: Vector3,
}

local session: Session? = nil
local ui: any = nil -- built in start()
local keys = { handbrake = false, nitro = false }
local touch = { handbrake = false, nitro = false }
local lastHorn = 0
local fovTween: Tween? = nil
local normalFov: number? = nil -- the player's on-foot FOV, restored on exit
local hidBackpack = false -- true while WE disabled the CoreGui backpack (only ever restore what we hid)

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
-- TextSize multiplier that lifts small labels to the touchMin effective scale on touch screens (1 elsewhere, and on
-- tablets whose canvas scale is already >= touchMin). Pure, unit-tested.
function VehicleClient.textBoost(isTouch: boolean, uiScale: number, touchMin: number): number
	if not isTouch or uiScale ~= uiScale or uiScale <= 0 then
		return 1
	end
	return math.clamp(touchMin / uiScale, 1, PHONE_TEXT_MAX_BOOST)
end

export type RadioLayout = {
	anchorX: number, -- AnchorPoint (anchorX, 1) / Position UDim2.new(0.5, offsetX, 1, -12)
	offsetX: number,
	width: number, -- pill width in design px before its UIScale (height RADIO_SIZE.Y)
	compact: boolean, -- touch: station name only, no prev / next buttons, no track line
	tap: boolean, -- the pill is a tap-to-cycle button (compact pills right of the speedometer only)
}

-- Radio pill placement on a DrivingUI canvas `canvasWidth` design px wide, pill drawn at `scale` (see RADIO_SIZE).
-- On touch nothing interactive ever lands left of the speedometer (thumbstick zone). Pure, unit-tested.
function VehicleClient.radioLayout(canvasWidth: number, touch: boolean, scale: number): RadioLayout
	local s = if scale == scale and scale > 0 then scale else 1
	local side = SPEEDO_HALF_WIDTH + RADIO_GAP
	if not touch then
		local fits = canvasWidth / 2 + side + RADIO_SIZE.X * s <= canvasWidth - 12
		return {
			anchorX = if fits then 0 else 1,
			offsetX = if fits then side else -side,
			width = RADIO_SIZE.X,
			compact = false,
			tap = false,
		}
	end
	-- room between the speedometer and DRIFT, in pill units
	local slot = (canvasWidth / 2 - side - TOUCH_CLUSTER_LEFT - RADIO_GAP) / s
	if slot >= RADIO_TOUCH_MIN_WIDTH then
		return { anchorX = 0, offsetX = side, width = math.min(RADIO_SIZE.X, slot), compact = true, tap = true }
	end
	return { anchorX = 1, offsetX = -side, width = RADIO_TOUCH_MIN_WIDTH, compact = true, tap = false }
end

-- Design-canvas width of DrivingUI: its ScreenGui's AbsoluteSize (inside the device safe-area insets, e.g. notches,
-- like the touch buttons laid out in it), the camera viewport only until the gui has a size. Pure, unit-tested.
function VehicleClient.canvasWidth(guiWidth: number, viewportWidth: number, scale: number): number
	local real = if guiWidth >= 1 then guiWidth else viewportWidth
	return real / (if scale == scale and scale > 0 then scale else 1)
end

-- v2 driving UI (gta_ui_language §5.13, §7): no dashboard panel. The radar bars carry nitro (HUDController reads
-- getController().nitro into the third segment), the radio is HUDController's station name at top-centre, the car's
-- name comes in on the location lines. DrivingUI keeps only an optional small speed readout bottom-right (Settings >
-- Speed readout: player attribute HC_ShowSpeedo), a thin car-damage rule under it, a quiet "DRIFT 2.4s" line, and on
-- touch screens the GTA-style circle buttons (NITRO / DRIFT / HORN / EXIT / RADIO) from HudLayout.buttons.

local SPEED_TEXT = 34 -- Kanit numerals (design px)
local UNIT_TEXT = 14
local CONTROLS_HELP_ID = "drive_controls"

local function hud(): any
	return sibling("HUDController")
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
	local gui = Kit.screen("DrivingUI", Theme.Layers.HUD + 1, { touchMin = Theme.TouchMinScale })
	gui.Enabled = false
	local root = Kit.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})

	-- Speed readout --------------------------------------------------------------------------------------------
	local speedo = Kit.new("Frame", {
		Name = "Speedometer",
		BackgroundTransparency = 1,
		Parent = root,
	})
	local speedLabel = Kit.numeric("0", SPEED_TEXT, {
		Name = "Speed",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -40, 1, -6),
		Size = UDim2.new(1, -40, 1, -6),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Parent = speedo,
	})
	local unit = Kit.text("MPH", "condensed", UNIT_TEXT, {
		Name = "Unit",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -10),
		Size = UDim2.fromOffset(36, 16),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.Colors.TextDim,
		Parent = speedo,
	})
	-- thin car-damage rule under the numbers; only shown once the car has taken damage
	local healthTrack = Kit.new("Frame", {
		Name = "Health",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.new(1, -40, 0, 3),
		BackgroundColor3 = Theme.Colors.HealthTrack,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Visible = false,
		Parent = speedo,
	})
	local healthFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.Colors.Health,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = healthTrack,
	})

	-- Drift line (quiet: condensed white with the time in yellow, no banner) ------------------------------------
	local drift = Kit.text("", "condensed", 18, {
		Name = "Drift",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextStrokeColor3 = Theme.Colors.Black,
		TextStrokeTransparency = 0.5,
		Visible = false,
		Parent = root,
	})

	-- Touch buttons (HudLayout.buttons, bottom-right arc; nothing in the thumbstick zone) ------------------------
	local touchFrame = Kit.new("Frame", {
		Name = "Touch",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = Kit.isTouch(),
		Parent = root,
	})
	local nitroBtn = Kit.circleButton("Nitro", 96, "hud.nitro", { Name = "NitroButton", Parent = touchFrame })
	local driftBtn = Kit.circleButton("Drift", 84, "hud.drift", { Name = "DriftButton", Parent = touchFrame })
	local hornBtn = Kit.circleButton("Horn", 60, "hud.horn", { Name = "HornButton", Parent = touchFrame })
	local exitBtn = Kit.circleButton("Exit", 60, "hud.exit", { Name = "ExitButton", Parent = touchFrame })
	local radioBtn = Kit.circleButton("Radio", 48, "hud.signal", { Name = "RadioButton", Parent = touchFrame })
	bindHold(nitroBtn, "nitro")
	bindHold(driftBtn, "handbrake")
	hornBtn.Activated:Connect(function()
		VehicleClient.honk()
	end)
	exitBtn.Activated:Connect(function()
		VehicleClient.exit()
	end)
	radioBtn.Activated:Connect(function()
		VehicleClient.radioStep(1)
	end)

	ui = {
		gui = gui,
		speedo = speedo,
		speed = speedLabel,
		unit = unit,
		healthTrack = healthTrack,
		healthFill = healthFill,
		drift = drift,
		touchFrame = touchFrame,
		nitroBtn = nitroBtn,
		driftBtn = driftBtn,
		hornBtn = hornBtn,
		exitBtn = exitBtn,
		radioBtn = radioBtn,
	}
end

local function place(obj: GuiObject, r: { x: number, y: number, w: number, h: number }?)
	if r then
		obj.Position = UDim2.fromOffset(r.x, r.y)
		obj.Size = UDim2.fromOffset(r.w, r.h)
		obj.AnchorPoint = Vector2.zero
	end
end

-- Lay DrivingUI out from the shared HudLayout on its own (same-scale) canvas.
local function layoutDriving()
	if not ui then
		return
	end
	local canvas = Kit.canvasSize(ui.gui)
	local isTouch = Kit.isTouch()
	local L = HudLayout.compute(canvas.X, canvas.Y, isTouch)
	place(ui.speedo, L.speed)
	place(ui.drift, L.driftText)
	local b = L.buttons
	place(ui.nitroBtn, b.nitro)
	place(ui.driftBtn, b.drift)
	place(ui.hornBtn, b.horn)
	place(ui.exitBtn, b.exit)
	place(ui.radioBtn, b.radio)
	ui.touchFrame.Visible = isTouch
end

-- Radio: the station name shows top-centre (HUDController.showRadio) on every change while driving.
local function updateRadioUI(station: any, title: any)
	if not session then
		return
	end
	local h = hud()
	if not (h and typeof(h.showRadio) == "function") then
		return
	end
	local sc = sibling("SoundController")
	local musicOff = sc ~= nil and type(sc.isEnabled) == "function" and sc.isEnabled("music") == false
	local track = if musicOff then "Music off" elseif typeof(title) == "string" then title else nil
	pcall(h.showRadio, if typeof(station) == "string" then station else nil, track)
end

local function radioCall(method: string, ...: any): ...any
	local sc = sibling("SoundController")
	local fn = if sc then sc[method] else nil
	if type(fn) ~= "function" then
		return nil
	end
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		return nil
	end
	return table.unpack(results, 2, results.n)
end

-- One GTA help text with the driving controls for the current input (first drive of the session only).
local controlsShown = false
local function controlsHelp(): string?
	local input = Kit.inputKind()
	if input == "touch" then
		return "Hold <b>NITRO</b> for a boost and <b>DRIFT</b> to slide. Tap <b>RADIO</b> to change station."
	elseif input == "gamepad" then
		return `Hold {RichText.key("RB")} for nitro, {RichText.key("X")} to drift. {RichText.key("Y")} horn, `
			.. `{RichText.key("A")} to get out. {RichText.key("D-Pad")} changes the radio.`
	end
	return `Hold {RichText.key("Shift")} for nitro and {RichText.key("Space")} to drift. {RichText.key("H")} horn, `
		.. `{RichText.key("F")} to get out. {RichText.key("R")} {RichText.key("T")} change the radio.`
end

local function showControlsHelp()
	if controlsShown then
		return
	end
	local h = hud()
	local text = controlsHelp()
	if text and h and typeof(h.help) == "function" then
		controlsShown = true
		pcall(h.help, text, { id = CONTROLS_HELP_ID, duration = 9 })
	end
end

local function speedoWanted(): boolean
	return player:GetAttribute("HC_ShowSpeedo") ~= false
end

local function updateHealthUI(s: Session, _animate: boolean)
	if not ui then
		return
	end
	local hp = s.model:GetAttribute("Health")
	local frac = math.clamp(if typeof(hp) == "number" then hp / Tuning.MAX_HEALTH else 1, 0, 1)
	ui.healthTrack.Visible = frac < 0.999 and speedoWanted()
	ui.healthFill.Size = UDim2.fromScale(frac, 1)
	ui.healthFill.BackgroundColor3 = if frac > 0.5
		then Theme.Colors.Health
		elseif frac > 0.25 then Theme.Colors.Yellow
		else Theme.Colors.Red
end

-- The CoreGui backpack hotbar stays on top of every ScreenGui while seated, right over the speed readout. Hide it
-- for the drive; restore it only if we were the ones who hid it (another system may keep it off on purpose).
local function hideBackpack()
	local okGet, enabled = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack)
	if okGet and enabled == true then
		local okSet = pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false)
		hidBackpack = okSet
	end
end

local function restoreBackpack()
	if hidBackpack then
		hidBackpack = false
		pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, true)
	end
end

local function showUI(s: Session)
	hideBackpack()
	if not ui then
		return
	end
	ui.speed.Text = "0"
	ui.speed.TextColor3 = Theme.Colors.Text
	ui.speedo.Visible = speedoWanted()
	ui.drift.Visible = false
	ui.gui.Enabled = true
	layoutDriving() -- after Enabled: measured on the live DrivingUI canvas
	updateHealthUI(s, false)
	-- GTA: the vehicle name fades in bottom-right with the location lines, the station name at top-centre
	local h = hud()
	if h and typeof(h.showLocation) == "function" then
		pcall(h.showLocation, s.def.name, nil, nil)
	end
	updateRadioUI(radioCall("getRadio"))
	showControlsHelp()
end

local function hideUI()
	restoreBackpack()
	if ui then
		ui.gui.Enabled = false
	end
	local h = hud()
	if h and typeof(h.showRadio) == "function" then
		pcall(h.showRadio, nil)
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

	-- rear wheels: tire smoke + dust streams, skid-mark trails at the contact patch
	for i = 3, 4 do
		local w = wheels[i]
		local base = if w then w.attachment.Position else Vector3.new(if i == 3 then -2.5 else 2.5, -1, 4)
		local att = trove:Add(Instance.new("Attachment"))
		att.Name = "HC_Smoke" .. i
		att.Position = base - Vector3.new(0, radius * 0.85, 0)
		att.Parent = chassis
		local smoke = VFXLibrary.stream("TireSmoke", att)
		if smoke then
			table.insert(s.fx.smoke, smoke)
		end
		local dust = VFXLibrary.stream("Dust", att)
		if dust then
			table.insert(s.fx.dust, dust)
		end
		local skid = VFXLibrary.trail("SkidMark", chassis, base - Vector3.new(0, radius - 0.08, 0))
		if skid then
			trove:Add(skid.trail)
			trove:Add(skid.a0)
			trove:Add(skid.a1)
			table.insert(s.fx.skids, skid)
		end
	end
	local sprayAtt = trove:Add(Instance.new("Attachment"))
	sprayAtt.Name = "HC_Spray"
	sprayAtt.Position = Vector3.new(0, -radius * 0.6, 0)
	sprayAtt.Parent = chassis
	s.fx.spray = VFXLibrary.stream("WaterSpray", sprayAtt)

	local length = s.model:GetAttribute("Length")
	local halfLength = math.max(chassis.Size.Z / 2, (if typeof(length) == "number" then length / 2 - 0.3 else 0))
	local exhaust = trove:Add(Instance.new("Attachment"))
	exhaust.Name = "HC_Exhaust"
	exhaust.Position = Vector3.new(0, 0, halfLength + 0.3)
	exhaust.Parent = chassis
	s.fx.exhaust = exhaust
	s.fx.flame = VFXLibrary.stream("NitroFlame", exhaust)
	s.fx.core = VFXLibrary.stream("NitroCore", exhaust)
	local jet = VFXLibrary.beam("NitroJet", chassis, exhaust.Position, Vector3.new(0, 0, 1))
	if jet then
		trove:Add(jet.beam)
		trove:Add(jet.a0)
		trove:Add(jet.a1)
		s.fx.jet = jet
	end

	local light = Instance.new("PointLight")
	light.Name = "NitroLight"
	light.Color = Theme.Colors.Secondary
	light.Range = 14
	light.Brightness = 3
	light.Enabled = false
	light.Parent = exhaust
	s.fx.light = light

	-- speed lines: a ring of emitters on a camera-following host (moved only while they show)
	if VFXLibrary.tier().extras then
		local host = trove:Add(Instance.new("Part"))
		host.Name = "HC_SpeedLines"
		host.Anchored = true
		host.CanCollide = false
		host.CanQuery = false
		host.CanTouch = false
		host.CastShadow = false
		host.Transparency = 1
		host.Size = Vector3.new(0.2, 0.2, 0.2)
		host.Parent = Workspace.CurrentCamera or Workspace
		for k = 1, SPEED_LINE_RING do
			local a = (k - 0.5) * 2 * math.pi / SPEED_LINE_RING
			local att = Instance.new("Attachment")
			att.Name = "Line" .. k
			att.Position =
				Vector3.new(math.cos(a) * SPEED_LINE_RADIUS, math.sin(a) * SPEED_LINE_RADIUS * 0.62, -SPEED_LINE_AHEAD)
			att.Parent = host
			local line = VFXLibrary.stream("SpeedLines", att)
			if line then
				table.insert(s.fx.speedLines, line)
			end
		end
		s.fx.speedHost = host
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = false
	local exclude: { Instance } = { s.model }
	if player.Character then
		table.insert(exclude, player.Character)
	end
	params.FilterDescendantsInstances = exclude
	s.fx.rayParams = params

	local screech = makeLocalSound("TireScreech", chassis)
	if screech then
		trove:Add(screech)
		screech.Volume = 0
		s.fx.screech = screech
	end
end

-- All local streams off and forgotten (the trove destroys the instances).
local function releaseFx(s: Session)
	local fx = s.fx
	for _, st in fx.smoke do
		VFXLibrary.releaseStream(st)
	end
	for _, st in fx.dust do
		VFXLibrary.releaseStream(st)
	end
	for _, st in fx.speedLines do
		VFXLibrary.releaseStream(st)
	end
	VFXLibrary.releaseStream(fx.spray)
	VFXLibrary.releaseStream(fx.flame)
	VFXLibrary.releaseStream(fx.core)
end

-- Exhaust pop: flame burst out of the tailpipe + a light blink.
local function backfire(s: Session, big: boolean)
	local exhaust = s.fx.exhaust
	if not exhaust or not exhaust.Parent then
		return
	end
	s.fxBackfireAt = os.clock()
	local cf = exhaust.WorldCFrame
	VFXLibrary.burst(
		"Backfire",
		cf.Position,
		{ direction = -s.chassis.CFrame.LookVector, count = if big then 3 else 2 }
	)
	local light = s.fx.light
	if light and not light.Enabled then
		light.Color = Color3.fromRGB(255, 160, 60)
		light.Brightness = if big then 5 else 3.5
		light.Enabled = true
		task.delay(0.08, function()
			if session == s and not (s.controller.boosting == true) and light.Parent then
				light.Enabled = false
				light.Color = Theme.Colors.Secondary
			end
		end)
	end
end

-- Ground material under the car (every SURFACE_SAMPLE s): dust color for dirt / grass / sand, water flag.
local function sampleSurface(s: Session)
	local params = s.fx.rayParams
	if not params then
		return
	end
	local origin = s.chassis.Position
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(s.controller.rayLength or 6) - 3, 0), params)
	if not hit then
		s.fxDust = nil
		s.fxWater = false
		return
	end
	local name = hit.Material.Name
	s.fxWater = name == "Water"
	s.fxDust = VFXLibrary.dustColor(name)
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
		-- not E: it is the steal prompts' hold key, and "Hotwire [E]" stays on screen next to parked cars
		Enum.KeyCode.F,
		Enum.KeyCode.ButtonA -- gamepad "jump" = leave the seat (Jumping is disabled while driving)
	)
	ContextActionService:BindActionAtPriority(
		ACTION_RADIO_PREV,
		pressHandler(function()
			VehicleClient.radioStep(-1)
		end),
		false,
		ACTION_PRIORITY,
		Enum.KeyCode.R,
		Enum.KeyCode.DPadLeft
	)
	ContextActionService:BindActionAtPriority(
		ACTION_RADIO_NEXT,
		pressHandler(function()
			VehicleClient.radioStep(1)
		end),
		false,
		ACTION_PRIORITY,
		Enum.KeyCode.T,
		Enum.KeyCode.DPadRight
	)
end

local function unbindActions()
	for _, name in { ACTION_HANDBRAKE, ACTION_NITRO, ACTION_HORN, ACTION_EXIT, ACTION_RADIO_PREV, ACTION_RADIO_NEXT } do
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

-- Sparks where we hit: a ray along the pre-impact velocity finds the contact point (else the leading bumper).
local function crashSparks(s: Session, drop: number)
	local vel = s.prevVel
	local flat = Vector3.new(vel.X, 0, vel.Z)
	if flat.Magnitude < 5 then
		return
	end
	local dir = flat.Unit
	local cf = s.chassis.CFrame
	local half = math.max(s.chassis.Size.Z, s.chassis.Size.X) / 2
	local params = s.fx.rayParams
	local hit = if params then Workspace:Raycast(cf.Position, dir * (half + SPARK_PROBE), params) else nil
	local at = if hit then hit.Position else cf.Position + dir * half
	local normal = if hit then hit.Normal else -dir
	local k = math.clamp(drop / 70, 0.6, 1.6)
	VFXLibrary.burst("Sparks", at, { count = math.floor(18 * k + 0.5), direction = normal + Vector3.new(0, 0.6, 0) })
	VFXLibrary.burst("Flash", at, { scale = 0.45 * k, color = Color3.fromRGB(255, 210, 140) })
	if drop > 90 then
		VFXLibrary.burst("Debris", at, { count = 5, scale = 0.6, direction = normal + Vector3.new(0, 1, 0) })
	end
end

local function onCrash(s: Session, drop: number)
	s.lastCrash = os.clock()
	pcall(crashSparks, s, drop)
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
		Kit.pop(ui.speed, 1.08)
	end
end

-- VehicleFx: tell the server when our nitro starts / stops and when we honk, so nearby players see the flames and
-- hear the horn. State changes only, >= FX_MIN_INTERVAL apart; a change inside the window goes out when it opens.
local function syncFx(s: Session, boosting: boolean)
	if boosting == s.fxBoost and not s.fxHonk then
		return
	end
	local now = os.clock()
	if now - s.fxAt < FX_MIN_INTERVAL then
		return
	end
	local honk = s.fxHonk
	s.fxBoost = boosting
	s.fxHonk = false
	s.fxAt = now
	pcall(Net.fire, "VehicleFx", boosting, honk)
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
	syncFx(s, controller.boosting == true)

	-- crash detection: sudden loss of speed against a decaying recent maximum
	local speed = controller.speed
	s.recentMax = math.max(speed, s.recentMax - CRASH_WINDOW_DECAY * dt)
	-- velocity at the recent peak = the pre-impact velocity while a crash's speed drop is under way (spark ray)
	if speed >= s.recentMax - 1 then
		s.prevVel = s.chassis.AssemblyLinearVelocity
	end
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
	if boosting ~= s.wasBoosting then
		ui.speed.TextColor3 = if boosting then Theme.Colors.Yellow else Theme.Colors.Text
		if boosting then
			Kit.pop(ui.speed, 1.1)
			backfire(s, true)
			if s.sfx then
				playViaController("Whoosh", s.chassis.Position)
			end
		end
	end

	-- nitro lives in the radar's third bar segment (HUDController); the touch button pops when it is full again
	local full = c.nitro >= 0.999
	if full and not s.nitroWasFull and not c.infiniteNitro then
		Kit.pop(ui.nitroBtn, 1.1)
	end
	s.nitroWasFull = full

	-- drift line
	if drifting then
		s.driftTime += dt
		if not s.wasDrifting then
			ui.drift.Visible = true
		end
		local tenths = math.floor(s.driftTime * 10)
		if tenths ~= s.shownDriftTenths then
			s.shownDriftTenths = tenths
			ui.drift.Text = `DRIFT  <font color="#F0C850">{string.format("%.1f", tenths / 10)}s</font>`
		end
	elseif s.wasDrifting then
		ui.drift.Visible = false
		s.driftTime = 0
		s.shownDriftTenths = -1
	end

	-- camera FOV kick
	local cam = Workspace.CurrentCamera
	if cam then
		local frac = math.clamp(c.speed / math.max(def.topSpeed, 1), 0, 1)
		local target = Tuning.FOV_BASE + Tuning.FOV_MAX_BONUS * frac * frac + (if boosting then NITRO_FOV_EXTRA else 0)
		cam.FieldOfView += (target - cam.FieldOfView) * math.min(1, FOV_RESPONSE * dt)
	end

	-- FX (VFXLibrary streams: state changes only, intensity in 0.1 steps)
	local fx = s.fx
	local frac = math.clamp(c.speed / math.max(def.topSpeed, 1), 0, 1.5)
	local slideLevel = if drifting then math.clamp(math.floor(math.abs(c.lateralSpeed) / 6) / 10 + 0.5, 0.5, 1.3) else 0
	if drifting ~= s.fxSlideOn or slideLevel ~= s.fxSlideLevel then
		s.fxSlideOn = drifting
		s.fxSlideLevel = slideLevel
		for _, st in fx.smoke do
			VFXLibrary.setStream(st, drifting, slideLevel)
		end
	end
	for i, skid in fx.skids do
		-- marks only where that rear tyre is on the ground and sliding
		local want = drifting and c.wheelGrounded[i + 2] == true
		if skid.trail.Enabled ~= want then
			skid.trail.Enabled = want
		end
	end
	-- surface dust / water spray
	s.fxSurfaceT += dt
	if s.fxSurfaceT >= SURFACE_SAMPLE then
		s.fxSurfaceT = 0
		sampleSurface(s)
	end
	local grounded = (c.grounded or 0) >= 2
	local dustColor = s.fxDust
	local dustOn = dustColor ~= nil and grounded and c.speed > DUST_MIN_SPEED
	if dustOn and dustColor ~= s.fxDustColor then
		s.fxDustColor = dustColor
		for _, st in fx.dust do
			st.emitter.Color = ColorSequence.new(dustColor :: Color3)
		end
	end
	if dustOn ~= s.fxDustOn then
		s.fxDustOn = dustOn
		for _, st in fx.dust do
			VFXLibrary.setStream(st, dustOn, math.clamp(frac, 0.4, 1.2))
		end
	end
	local sprayOn = s.fxWater and c.speed > SPRAY_MIN_SPEED
	if sprayOn ~= s.fxSprayOn and fx.spray then
		s.fxSprayOn = sprayOn
		if sprayOn and c.speed > SPLASH_MIN_SPEED then
			-- hitting the water fast: one big crown splash on entry
			VFXLibrary.burst("WaterSplash", s.chassis.Position, { scale = 1.5, count = 3 })
		end
		VFXLibrary.setStream(fx.spray, sprayOn, math.clamp(frac + 0.3, 0.5, 1.3))
	end
	-- nitro: flame + core streams, jet beam + light flicker
	if boosting ~= s.wasBoosting then
		if fx.flame then
			VFXLibrary.setStream(fx.flame, boosting)
		end
		if fx.core then
			VFXLibrary.setStream(fx.core, boosting)
		end
		if fx.jet then
			fx.jet.beam.Enabled = boosting
		end
		if fx.light then
			fx.light.Color = Theme.Colors.Secondary
			fx.light.Enabled = boosting
		end
	end
	if boosting then
		local flicker = 0.82 + math.random() * 0.36
		if fx.light then
			fx.light.Brightness = 3 * flicker
		end
		local jet = fx.jet
		if jet then
			jet.beam.Width0 = 2 * flicker
			jet.a1.Position = jet.a0.Position + Vector3.new(0, 0, 4.5 * (0.75 + math.random() * 0.4))
		end
	end
	-- backfire pops on upshifts under throttle (not while boosting: the flame covers it)
	local gear, up = VFXLibrary.nextGear(s.fxGear, frac)
	s.fxGear = gear
	if
		up
		and not boosting
		and s.input.throttle > 0.5
		and grounded
		and os.clock() - s.fxBackfireAt > BACKFIRE_COOLDOWN
	then
		backfire(s, false)
	end
	-- speed lines around the camera while boosting (lighter near top speed); followSpeedLines moves their host
	if fx.speedHost then
		local level = if boosting then 1 elseif frac >= SPEED_LINE_FRACTION then 0.5 else 0
		if level ~= s.fxLinesLevel then
			s.fxLinesLevel = level
			for _, st in fx.speedLines do
				VFXLibrary.setStream(st, level > 0, level)
			end
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

-- The speed-line host rides the final camera (after the camera scripts + shake), only while lines show.
local function followSpeedLines(s: Session)
	local host = s.fx.speedHost
	local cam = Workspace.CurrentCamera
	if host and cam and s.fxLinesLevel > 0 then
		host.CFrame = cam.CFrame
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
	releaseFx(s)
	s.trove:Destroy()
	radioCall("setRadioOn", false)
	if s.fxBoost then
		-- best effort (the server may already see us out of the seat; its own sweep clears the flames then)
		pcall(Net.fire, "VehicleFx", false, false)
	end
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
		fxBoost = false,
		fxHonk = false,
		fxAt = 0,
		fx = { smoke = {}, skids = {}, dust = {}, speedLines = {} },
		fxSlideOn = false,
		fxSlideLevel = 0,
		fxGear = 0,
		fxBackfireAt = 0,
		fxSurfaceT = 0,
		fxDust = nil,
		fxWater = false,
		fxDustOn = false,
		fxDustColor = nil,
		fxSprayOn = false,
		fxLinesLevel = 0,
		prevVel = Vector3.zero,
	}
	session = s

	-- Space is our handbrake: with Jumping disabled the default jump can't throw us out of the seat.
	-- Exit is explicit (F / ButtonA / EXIT button) and re-enables jumping first.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	bindActions()
	local okFx, fxErr = pcall(buildFx, s)
	if not okFx then
		warn("[VehicleClient] fx: " .. tostring(fxErr))
	end
	radioCall("setRadioOn", true)
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
		followSpeedLines(s)
	end)
	trove:Connect(model:GetAttributeChangedSignal("Health"), function()
		if session ~= s then
			return
		end
		local hp = model:GetAttribute("Health")
		local now = if typeof(hp) == "number" then hp else Tuning.MAX_HEALTH
		updateHealthUI(s, true)
		if now < s.lastHealth and ui then
			Kit.pop(ui.speed, 1.06)
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
	s.fxHonk = true -- nearby players hear it even when our own sfx are off
	if ui then
		Kit.pop(ui.hornBtn, 1.1)
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

-- Previous (-1) / next (+1) radio station while driving (RADIO touch button, R / T, D-pad).
function VehicleClient.radioStep(dir: number)
	if not session then
		return
	end
	radioCall("stepRadio", dir)
	playViaController("Click")
	if ui then
		Kit.pop(ui.radioBtn, 1.1)
	end
end

function VehicleClient.init() end

function VehicleClient.start()
	buildUI()
	local sc = sibling("SoundController")
	local radioChanged = if sc then sc.RadioChanged else nil
	if type(radioChanged) == "table" and type(radioChanged.Connect) == "function" then
		radioChanged:Connect(function(station: any, title: any)
			updateRadioUI(station, title)
		end)
	end
	-- re-place the readout + touch buttons when the DrivingUI canvas (safe-area insets, UI scale) changes
	local function relayout()
		if session then
			layoutDriving()
		end
	end
	if ui then
		ui.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	end
	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(relayout)
	end
	-- Settings > Speed readout (MenuController sets the local attribute)
	player:GetAttributeChangedSignal("HC_ShowSpeedo"):Connect(function()
		local s = session
		if ui and s then
			ui.speedo.Visible = speedoWanted()
			updateHealthUI(s, false)
		end
	end)
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
