--!strict
-- EventsClient (SPEC §7): server event presentation.
--   * HotDropState -> big countdown banner ("🔥 HOT DROP LANDING 0:15" -> "🔥 HOT DROP • CLAIM IT! 2:41") with the
--     car's rarity + name + live distance, and a waypoint to the drop (WaypointController.set("hotdrop", ...) when
--     that controller exists, otherwise a local neon Beam from your character to the beacon).
--   * EventState -> pill badges along the top of the screen: "🚦 RUSH HOUR 1:12", "💸 2X CASH 4:01",
--     "🍀 SERVER LUCK x2 12:30", "💰 CASH RAIN @ PLAZA". Pop in / shrink out; the last 10s blink.
-- Reads state from StateController when available (it caches pushes that arrived before we started), else listens
-- to the remotes directly. Timestamps are Workspace:GetServerTimeNow() based. Presentation only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared: any = ReplicatedStorage:WaitForChild("Shared")
local Cars = require(Shared.Config.Cars)
local Format = require(Shared.Util.Format)
local Net = require(Shared.Net)
local Rarity = require(Shared.Config.Rarity)

local UI: any = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)

local player = Players.LocalPlayer

local EventsClient = {}

export type PillDef = { icon: string, text: string, color: Color3, order: number, timer: boolean }

EventsClient.Pills = {
	rushHour = { icon = "🚦", text = "RUSH HOUR", color = Theme.Colors.Warning, order = 1, timer = true },
	doubleCash = { icon = "💸", text = "2X CASH", color = Theme.Colors.Cash, order = 2, timer = true },
	serverLuck = {
		icon = "🍀",
		text = "SERVER LUCK x2",
		color = Color3.fromRGB(60, 205, 120),
		order = 3,
		timer = true,
	},
	cashRain = { icon = "💰", text = "CASH RAIN @ PLAZA", color = Theme.Colors.Gold, order = 4, timer = false },
} :: { [string]: PillDef }

local HOT_DROP_COLOR = Color3.fromRGB(255, 110, 40)
local BLINK_UNDER = 10

---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
---------------------------------------------------------------------------------------------------------------------

-- "🚦 RUSH HOUR 1:12" (timer omitted for pills without one).
function EventsClient.pillText(name: string, secondsLeft: number): string?
	local def = EventsClient.Pills[name]
	if not def then
		return nil
	end
	if def.timer then
		return `{def.icon} {def.text} {Format.clock(math.ceil(math.max(0, secondsLeft)))}`
	end
	return `{def.icon} {def.text}`
end

export type HotDropPhase = "none" | "countdown" | "live"

-- Phase of a sanitized HotDropState at server time `t`.
function EventsClient.hotDropPhase(state: any, t: number): HotDropPhase
	if typeof(state) ~= "table" then
		return "none"
	end
	if state.active == true and typeof(state.position) == "Vector3" then
		if typeof(state.endsAt) == "number" and state.endsAt < t - 2 then
			return "none" -- stale
		end
		return "live"
	end
	if typeof(state.startsAt) == "number" and typeof(state.position) == "Vector3" then
		if state.startsAt < t - 15 then
			return "none" -- the landing never came (server hiccup)
		end
		return "countdown"
	end
	return "none"
end

-- Color used for a hot drop car (Secret's near-black catalog color is swapped for a readable purple).
function EventsClient.rarityColor(carId: string?): Color3
	local def = if carId then Cars.get(carId) else nil
	if not def then
		return HOT_DROP_COLOR
	end
	if def.rarity == "Secret" then
		return Color3.fromRGB(190, 120, 255)
	end
	local tier = Rarity.Tiers[def.rarity]
	return if tier then tier.color else HOT_DROP_COLOR
end

function EventsClient.waypointLabel(carId: string?): string
	local def = if carId then Cars.get(carId) else nil
	return if def then "HOT DROP: " .. string.upper(def.name) else "HOT DROP"
end

function EventsClient.carText(carId: string?, mutation: string?): string
	local def = if carId then Cars.get(carId) else nil
	if not def then
		return "MYSTERY CAR"
	end
	local mut = Rarity.getMutation((mutation or "None") :: any)
	local name = if mut.label ~= "" then mut.label .. " " .. def.name else def.name
	return string.upper(def.rarity) .. " • " .. name
end

---------------------------------------------------------------------------------------------------------------------
-- Lazy controllers
---------------------------------------------------------------------------------------------------------------------

local lazyCache: { [string]: any } = {}
local function lazyController(name: string): any
	local cached = lazyCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil -- not built (yet); look again next time
	end
	local ok, result = pcall(require, mod :: any)
	lazyCache[name] = if ok and typeof(result) == "table" then result else false
	return if ok and typeof(result) == "table" then result else nil
end

local function playSound(key: string)
	local sc = lazyController("SoundController")
	if sc and typeof(sc.play) == "function" then
		pcall(sc.play, key)
	end
end

local function hudHidden(): boolean
	local sc = lazyController("StateController")
	if sc and typeof(sc.getSetting) == "function" then
		local ok, v = pcall(sc.getSetting, "hideHud")
		return ok and v == true
	end
	return false
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

---------------------------------------------------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------------------------------------------------

type Pill = { frame: Frame, label: TextLabel, scale: UIScale, endsAt: number, closing: boolean, blink: boolean }

local gui: ScreenGui? = nil
local pillRow: Frame? = nil
local pills: { [string]: Pill } = {}

local banner: Frame? = nil
local bannerScale: UIScale? = nil
local bannerTitle: TextLabel? = nil
local bannerTimer: TextLabel? = nil
local bannerInfo: TextLabel? = nil
local bannerDist: TextLabel? = nil
local bannerStroke: UIStroke? = nil
local bannerShown = false

local eventState: { [string]: number } = {}
local hotDrop: any = { active = false }
local lastPhase: HotDropPhase = "none"
local lastSecond = -1

local function buildUI()
	local screen = Kit.screen("EventsHUD", Theme.Layers.HUD + 1)
	gui = screen
	local top = Kit.new("Frame", {
		Name = "Top",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 78),
		Size = UDim2.fromOffset(900, 240),
		Parent = screen,
	})
	Kit.list(Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center).Parent = top

	local row = Kit.new("Frame", {
		Name = "Pills",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(900, 40),
		LayoutOrder = 1,
		Parent = top,
	})
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		row
	pillRow = row

	-- Hot drop banner -------------------------------------------------------------------------------------------
	local b = Kit.panel({
		Name = "HotDropBanner",
		Size = UDim2.fromOffset(400, 118),
		LayoutOrder = 2,
		Visible = false,
		Parent = top,
	})
	b.BackgroundColor3 = Theme.Colors.Background
	local stroke = b:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = HOT_DROP_COLOR
		stroke.Thickness = 4
		bannerStroke = stroke
	end
	local scale = Kit.new("UIScale", { Scale = 0, Parent = b })
	bannerScale = scale

	-- hot stripe across the top
	local stripe = Kit.new("Frame", {
		Name = "Stripe",
		BackgroundColor3 = HOT_DROP_COLOR,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 40),
		Parent = b,
	})
	Kit.corner().Parent = stripe
	Kit.new("Frame", {
		BackgroundColor3 = HOT_DROP_COLOR,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -12),
		Size = UDim2.new(1, 0, 0, 12),
		Parent = stripe,
	})
	Kit.gradient(Color3.fromRGB(255, 230, 120), Color3.fromRGB(255, 70, 70), 0).Parent = stripe

	bannerTitle = Kit.label("🔥 HOT DROP INCOMING", 24, {
		Name = "Title",
		Size = UDim2.new(1, -20, 0, 34),
		Position = UDim2.fromOffset(10, 3),
		ZIndex = 2,
		Parent = b,
	})
	bannerTimer = Kit.label("0:20", 38, {
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(120, 44),
		Position = UDim2.new(1, -14, 0, 44),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Theme.Colors.Warning,
		Parent = b,
	})
	Kit.new("UIScale", { Parent = bannerTimer })
	bannerInfo = Kit.label("LEGENDARY • ???", 18, {
		Name = "Info",
		Size = UDim2.new(1, -150, 0, 26),
		Position = UDim2.fromOffset(16, 46),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = b,
	})
	bannerDist = Kit.label("📍 --", 16, {
		Name = "Distance",
		Size = UDim2.new(1, -150, 0, 22),
		Position = UDim2.fromOffset(16, 76),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.Colors.TextDim,
		Parent = b,
	})
	banner = b
end

local function makePill(name: string, def: PillDef, endsAt: number): Pill
	local frame = Kit.new("Frame", {
		Name = name,
		BackgroundColor3 = def.color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 38),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = def.order,
	})
	Kit.corner(UDim.new(1, 0)).Parent = frame
	Kit.stroke().Parent = frame
	Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(165, 165, 175)).Parent = frame
	Kit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
		Parent = frame,
	})
	local label = Kit.label("", 20, {
		Name = "Text",
		Size = UDim2.fromOffset(0, 38),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		Parent = frame,
	})
	local scale = Kit.new("UIScale", { Scale = 0, Parent = frame })
	frame.Parent = pillRow
	TweenService:Create(scale, Theme.TweenPop, { Scale = 1 }):Play()
	return { frame = frame, label = label, scale = scale, endsAt = endsAt, closing = false, blink = false }
end

local function closePill(name: string)
	local pill = pills[name]
	if not pill or pill.closing then
		return
	end
	pill.closing = true
	pills[name] = nil
	local t = TweenService:Create(pill.scale, Theme.TweenFast, { Scale = 0 })
	t.Completed:Once(function()
		pill.frame:Destroy()
	end)
	t:Play()
end

local function updatePills(t: number)
	for name, endsAt in eventState do
		local def = EventsClient.Pills[name]
		if def and endsAt > t then
			local pill = pills[name]
			if not pill then
				pill = makePill(name, def, endsAt)
				pills[name] = pill
				playSound("Whoosh")
			elseif pill.endsAt ~= endsAt then
				pill.endsAt = endsAt
				Kit.pop(pill.frame, 1.15) -- extended (e.g. stacked Server Luck)
			end
		end
	end
	for name, pill in pills do
		local endsAt = eventState[name]
		if not endsAt or endsAt <= t then
			closePill(name)
			continue
		end
		local left = endsAt - t
		pill.label.Text = EventsClient.pillText(name, left) or ""
		local blink = left <= BLINK_UNDER and math.floor(left * 2) % 2 == 0
		if blink ~= pill.blink then
			pill.blink = blink
			pill.label.TextColor3 = if blink then Theme.Colors.Danger else Theme.Colors.Text
		end
	end
end

local function showBanner(show: boolean)
	local b, scale = banner, bannerScale
	if not b or not scale or show == bannerShown then
		return
	end
	bannerShown = show
	if show then
		b.Visible = true
		scale.Scale = 0.4
		TweenService:Create(scale, Theme.TweenPop, { Scale = 1 }):Play()
	else
		local tw = TweenService:Create(scale, Theme.TweenFast, { Scale = 0 })
		tw.Completed:Once(function()
			if not bannerShown then
				b.Visible = false
			end
		end)
		tw:Play()
	end
end

local function updateBanner(t: number)
	local phase = EventsClient.hotDropPhase(hotDrop, t)
	if phase == "none" then
		showBanner(false)
		return
	end
	local title, timer, info, dist = bannerTitle, bannerTimer, bannerInfo, bannerDist
	if not title or not timer or not info or not dist then
		return
	end
	showBanner(true)
	local left = if phase == "countdown" then (hotDrop.startsAt or t) - t else (hotDrop.endsAt or t) - t
	local secs = math.max(0, math.ceil(left))
	title.Text = if phase == "countdown" then "🔥 HOT DROP LANDING IN" else "🔥 HOT DROP • CLAIM IT!"
	timer.Text = Format.clock(secs)
	local color = EventsClient.rarityColor(hotDrop.carId)
	info.Text = EventsClient.carText(hotDrop.carId, hotDrop.mutation)
	info.TextColor3 = color
	if bannerStroke then
		bannerStroke.Color = color
	end
	if secs ~= lastSecond then
		lastSecond = secs
		if phase == "countdown" and secs <= 5 and secs > 0 then
			Kit.pop(timer, 1.45)
			playSound("Click")
		end
		timer.TextColor3 = if phase == "live" and secs <= 30 then Theme.Colors.Danger else Theme.Colors.Warning
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and typeof(hotDrop.position) == "Vector3" then
		local d = (root.Position - hotDrop.position).Magnitude
		dist.Text = if d < 30 then "📍 YOU'RE HERE! Hold to claim" else `📍 {Format.commas(d)} studs away`
	else
		dist.Text = "📍 Follow the beacon!"
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Waypoint (WaypointController if present, else a local Beam)
---------------------------------------------------------------------------------------------------------------------

local beamParts: { Instance } = {}
local beamTarget: Vector3? = nil
local beamColor: Color3 = HOT_DROP_COLOR

local function clearBeam()
	for _, inst in beamParts do
		inst:Destroy()
	end
	table.clear(beamParts)
end

local function buildBeam()
	clearBeam()
	local target = beamTarget
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not target or not root or not root:IsA("BasePart") then
		return
	end
	local cam = Workspace.CurrentCamera
	local anchor = Instance.new("Part")
	anchor.Name = "HotDropWaypoint"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(target + Vector3.new(0, 6, 0))
	anchor.Parent = cam or Workspace
	local a1 = Instance.new("Attachment")
	a1.Parent = anchor
	local a0 = Instance.new("Attachment")
	a0.Name = "HotDropBeamFrom"
	a0.Position = Vector3.new(0, -2, 0)
	a0.Parent = root
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(beamColor)
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Width0 = 1.2
	beam.Width1 = 3
	beam.Segments = 1
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.15, 0.35),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	beam.Parent = anchor
	table.insert(beamParts, anchor)
	table.insert(beamParts, a0)
end

-- WaypointController auto-clears "hotdrop" whenever HotDropState is not active (i.e. during the countdown), which
-- can race our countdown waypoint depending on handler order: re-assert it while a drop is pending/live.
local function ensureWaypoint(t: number)
	if EventsClient.hotDropPhase(hotDrop, t) == "none" then
		return
	end
	local wc = lazyController("WaypointController")
	if wc and typeof(wc.has) == "function" and typeof(wc.set) == "function" then
		local ok, has = pcall(wc.has, "hotdrop")
		if ok and not has then
			pcall(
				wc.set,
				"hotdrop",
				hotDrop.position,
				EventsClient.rarityColor(hotDrop.carId),
				EventsClient.waypointLabel(hotDrop.carId)
			)
		end
	end
end

local function setWaypoint(position: Vector3?, color: Color3)
	local wc = lazyController("WaypointController")
	if wc and typeof(wc.set) == "function" then
		clearBeam()
		beamTarget = nil
		if position then
			pcall(wc.set, "hotdrop", position, color, EventsClient.waypointLabel(hotDrop.carId))
		elseif typeof(wc.clear) == "function" then
			pcall(wc.clear, "hotdrop")
		else
			pcall(wc.set, "hotdrop", nil)
		end
		return
	end
	if position == beamTarget and color == beamColor then
		return
	end
	beamTarget = position
	beamColor = color
	buildBeam()
end

---------------------------------------------------------------------------------------------------------------------
-- State handling
---------------------------------------------------------------------------------------------------------------------

local function onHotDrop(state: any)
	hotDrop = if typeof(state) == "table" then state else { active = false }
	local t = serverNow()
	local phase = EventsClient.hotDropPhase(hotDrop, t)
	if phase == "none" then
		setWaypoint(nil, HOT_DROP_COLOR)
	else
		setWaypoint(hotDrop.position, EventsClient.rarityColor(hotDrop.carId))
	end
	if phase ~= lastPhase then
		if phase == "live" and banner then
			Kit.pop(banner, 1.12)
		end
		lastPhase = phase
		lastSecond = -1
	end
	updateBanner(t)
end

local function onEventState(state: any)
	local clean: { [string]: number } = {}
	if typeof(state) == "table" then
		for k, v in state do
			if typeof(k) == "string" and typeof(v) == "number" and v == v then
				clean[k] = v
			end
		end
	end
	eventState = clean
	updatePills(serverNow())
end

function EventsClient.init() end

function EventsClient.start()
	buildUI()

	local sc = lazyController("StateController")
	if sc and sc.HotDropChanged and sc.EventStateChanged then
		sc.HotDropChanged:Connect(onHotDrop)
		sc.EventStateChanged:Connect(onEventState)
		if typeof(sc.getHotDrop) == "function" then
			onHotDrop(sc.getHotDrop())
		end
		if typeof(sc.getEventState) == "function" then
			onEventState(sc.getEventState())
		end
	else
		Net.listen("HotDropState", onHotDrop)
		Net.listen("EventState", onEventState)
	end

	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		if beamTarget then
			buildBeam()
		end
	end)

	while true do
		task.wait(0.25)
		local t = serverNow()
		local screen = gui
		if screen then
			screen.Enabled = not hudHidden()
		end
		updatePills(t)
		updateBanner(t)
		ensureWaypoint(t)
		if lastPhase ~= "none" and EventsClient.hotDropPhase(hotDrop, t) == "none" then
			lastPhase = "none"
			setWaypoint(nil, HOT_DROP_COLOR)
		end
	end
end

return EventsClient
