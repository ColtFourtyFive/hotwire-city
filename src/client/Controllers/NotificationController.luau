--!strict
-- NotificationController (SPEC §7): every transient message the player sees.
--
--  * toast(kind, text, duration?)     right-side stack, slides in, kind color + emoji icon, timer bar, identical toasts
--                                     merge into one with a "×N" counter. `Notify` remote. Desktop: from ~36% height
--                                     down (the PC player list owns the top-right), click to dismiss. Touch: top-right,
--                                     left of the action/driving button column, max 3, sized to fit the text at a
--                                     readable size, and never takes taps (they fall through to the controls).
--  * announce(title, subtitle?, color?, sound?)   huge center banner: scale-pop + wiggle, glossy title, shine sweep
--                                     across a neon ribbon. Queued, ~3s each (shorter while a backlog exists).
--                                     While driving: a compact banner under the top-center HUD instead of over the
--                                     road, and only the newest couple are kept. `Announce` remote.
--  * feed(richText)                   kill-feed lines (newest on top, max 5) fading after 8s, placed beside the HUD
--                                     menu (HUDController.getFeedAnchor; under the chat on PC). `EventFeed`.
--  * cashPopup(amount, worldPos?)     floating "+$1.2K": world position -> pooled BillboardGui (sized with the UI
--                                     scale) that pops, rises and fades; nil -> rises into the HUD cash counter.
--                                     `CashPopup` remote.
--  * offlineEarnings(amount, seconds) "WHILE YOU WERE AWAY" modal with a count-up, god rays and a COLLECT button that
--                                     bursts coins into the cash counter. The HUD holds the (already credited) amount
--                                     back until COLLECT so the counter counts up with the coins. `OfflineEarnings`.
--  * carStolenAlert(thief, carId, mutation, active)  pulsing red screen-edge vignette (4 gradient frames), alarm siren
--                                     loop, "🚨 THIEF IS STEALING YOUR CAR!" banner (under the top-center HUD stack),
--                                     and a live waypoint that follows the car itself (TheftVictimUserId / TheftActive
--                                     model attributes; the thief's name is only a fallback). `CarStolenAlert`.
--  Streamer mode (HUDController.VisibilityChanged): toasts, feed, banners and the alert vignette are hidden.
--  Busted is HUDController's job, not here.
--  Public: isAlertActive(), getAlertBottom(): number? (real px), isOfflineOpen().

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Cars = require(Config:WaitForChild("Cars"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Economy = require(Config:WaitForChild("Economy"))
local Format = require(Shared:WaitForChild("Util"):WaitForChild("Format"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER: safe to require directly.
local SoundController = require(script.Parent:WaitForChild("SoundController"))

local NotificationController = {}

local player = Players.LocalPlayer
local rng = Random.new()

-- Layout (1280x720 design canvas; Kit.screen scales it, with a touch floor so text stays readable on phones). Keep
-- clear of: cash counter + wanted stars (top-center), PC player list (top-right) and chat (top-left), side menu,
-- thumbstick (bottom-left), drive/action buttons (right side on touch).
local TOAST_ANCHOR_DESKTOP = UDim2.new(1, -14, 0.36, 0) -- below the CoreGui player list
local TOAST_TOP_TOUCH = 8 -- touch: the top-right corner is free (no open player list / chat on mobile)
local TOUCH_CONTROLS_WIDTH = 140 -- design px (combat/driving screens) of the right-hand touch button column
local TOAST_WIDTH = 320
local TOAST_WIDTH_TOUCH = 330
local TOAST_HEIGHT = 60
local TOAST_TEXT_TOUCH = 20 -- design px; x Theme.TouchMinScale keeps it >= ~14 real px
local TOAST_MAX_DESKTOP = 4
local TOAST_MAX_TOUCH = 3
local TOAST_DEFAULT_DURATION = 3.5
local FEED_ANCHOR = UDim2.fromOffset(92, 74) -- fallback when the HUD can't say where its menu is
local FEED_WIDTH = 400
local FEED_LINE_HEIGHT = 28
local FEED_LINE_HEIGHT_TOUCH = 30
local FEED_TEXT = 17
local FEED_TEXT_TOUCH = 20
local FEED_MAX = 5
local FEED_LIFETIME = 8
local BANNER_POSITION = UDim2.fromScale(0.5, 0.45) -- below the feed/toast band, above the car
local BANNER_SIZE = Vector2.new(740, 150)
local BANNER_DRIVING_SCALE = 0.6 -- compact banner while driving: the road stays visible
local BANNER_DRIVING_KEEP = 2 -- while driving only the newest announcements are worth showing
local BANNER_TOTAL_SECONDS = 3
local ALERT_BANNER_POSITION = UDim2.new(0.5, 0, 0, 84) -- just under the HUD cash counter (fallback)
local ALERT_BANNER_SIZE = Vector2.new(540, 92) -- fits between the PC chat window and player list at 720p
local ALERT_TOUCH_SCALE = 0.8 -- phones: on top of the screen's touch floor; keeps the 28 px title ~16 real px
local STACK_GAP = 6 -- design px between stacked top-center elements
local HUD_CASH_POSITION = UDim2.new(0.5, 0, 0, 80)
local HUD_CASH_TARGET = UDim2.fromScale(0.5, 0.05)
local WORLD_POPUP_POOL = 8
local WORLD_POPUP_SIZE = Vector2.new(260, 80)
local WORLD_POPUP_SIZE_BIG = Vector2.new(320, 96)
local ALERT_SAFETY_SECONDS = (Economy.THEFT_TIME_LIMIT or 150) + (Economy.DROPPED_CAR_TIMEOUT or 20) + 20
local ALERT_CAR_RESCAN = 0.5 -- seconds between scans for the stolen car model (the waypoint getter runs per frame)
local OFFLINE_AUTO_CLOSE = 30

export type ToastKind = "info" | "success" | "error" | "money" | "warning"
export type KindStyle = { color: Color3, icon: string, sound: string? }

local KIND_STYLES: { [string]: KindStyle } = {
	info = { color = Theme.Colors.Secondary, icon = "💬", sound = "Notify" },
	success = { color = Theme.Colors.Cash, icon = "✅", sound = "Notify" },
	money = { color = Theme.Colors.Gold, icon = "💰", sound = nil }, -- the server plays its own cash sound
	warning = { color = Theme.Colors.Warning, icon = "⚠️", sound = "Notify" },
	error = { color = Theme.Colors.Danger, icon = "⛔", sound = "Click" },
}

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

function NotificationController.kindStyle(kind: any): KindStyle
	return KIND_STYLES[if typeof(kind) == "string" then kind else "info"] or KIND_STYLES.info
end

-- Removes the oldest entries (front of the list) until #list <= max. Returns the removed entries, oldest first.
function NotificationController.trimOldest<T>(list: { T }, max: number): { T }
	local removed: { T } = {}
	while #list > math.max(0, max) do
		table.insert(removed, table.remove(list, 1) :: T)
	end
	return removed
end

-- 1234 -> "+$1.23K", -500 -> "-$500"
function NotificationController.formatCashDelta(amount: number): string
	if amount ~= amount then
		amount = 0
	end
	if amount < 0 then
		return "-" .. Format.cash(-amount)
	end
	return "+" .. Format.cash(amount)
end

-- Escapes text for RichText labels (player names may contain < > &).
function NotificationController.richEscape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

-- "GOLD PHANTOM GT" style label for a car + mutation (falls back to the raw id).
function NotificationController.carLabel(carId: any, mutation: any): string
	local def = if typeof(carId) == "string" then Cars.get(carId) else nil
	local name = if def then def.name elseif typeof(carId) == "string" then carId else "CAR"
	local mut = if typeof(mutation) == "string" and mutation ~= "None" then Rarity.Mutations[mutation :: any] else nil
	local prefix = if mut and mut.label ~= "" then mut.label .. " " else ""
	return string.upper(prefix .. name)
end

-- Rich-text banner line for the stolen-car alert.
function NotificationController.stolenAlertText(thiefName: string, carId: any, mutation: any): string
	local thief = NotificationController.richEscape(string.upper(thiefName))
	local car = NotificationController.richEscape(NotificationController.carLabel(carId, mutation))
	return ('🚨 <font color="#FFD23F">%s</font> IS STEALING YOUR <font color="#FFD23F">%s</font>!'):format(thief, car)
end

-- Seconds a banner stays fully visible given how many banners are waiting behind it.
function NotificationController.bannerHold(queued: number): number
	if queued >= 3 then
		return 1.1
	elseif queued >= 1 then
		return 1.6
	end
	return BANNER_TOTAL_SECONDS - 0.75 -- 0.45 pop in + 0.3 out
end

-- Toast stack anchor. Touch: top-right, shifted left past the right-hand touch button column, which lives on screens
-- at `controlsScale` while the toasts render at `toastScale` (both UIScale values).
function NotificationController.toastAnchor(touch: boolean, controlsScale: number, toastScale: number): UDim2
	if not touch then
		return TOAST_ANCHOR_DESKTOP
	end
	local s = if toastScale > 0 then toastScale else 1
	return UDim2.new(1, -math.ceil((TOUCH_CONTROLS_WIDTH * controlsScale + 8) / s), 0, TOAST_TOP_TOUCH)
end

export type CarInfo = { victimUserId: any, active: any, carId: any, mutation: any }

-- Which car (index) is the local victim's stolen car: TheftActive + TheftVictimUserId == me, preferring the one that
-- matches the alert's car id + mutation. nil when none.
function NotificationController.pickStolenCar(
	cars: { CarInfo },
	myUserId: number,
	carId: string?,
	mutation: string?
): number?
	local fallback: number? = nil
	for i, c in cars do
		if c.active == true and c.victimUserId == myUserId then
			if carId == nil or (c.carId == carId and (c.mutation or "None") == (mutation or "None")) then
				return i
			end
			fallback = fallback or i
		end
	end
	return fallback
end

-------------------------------------------------------------------------------------------------------------------------
-- Small UI utilities
-------------------------------------------------------------------------------------------------------------------------

local function tween(inst: Instance, info: TweenInfo, props: { [string]: any }): Tween
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

-- Fade every visual under (and including) root to fully transparent.
local function fadeOut(root: Instance, seconds: number)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local function fadeOne(d: Instance)
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			tween(d, info, { TextTransparency = 1, BackgroundTransparency = 1 })
		elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
			tween(d, info, { ImageTransparency = 1, BackgroundTransparency = 1 })
		elseif d:IsA("GuiObject") then
			tween(d, info, { BackgroundTransparency = 1 })
		elseif d:IsA("UIStroke") then
			tween(d, info, { Transparency = 1 })
		end
	end
	fadeOne(root)
	for _, d in root:GetDescendants() do
		fadeOne(d)
	end
end

local function sizeConstraint(maxSize: number, minSize: number?): UITextSizeConstraint
	return Kit.new("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = minSize or 10 })
end

local function lazyController(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" then result else nil
end

local lastSoundAt: { [string]: number } = {}
local function playSound(key: string?, minGap: number?)
	if not key then
		return
	end
	local now = os.clock()
	if now - (lastSoundAt[key] or -math.huge) < (minGap or 0.08) then
		return
	end
	lastSoundAt[key] = now
	pcall(SoundController.play, key)
end

-------------------------------------------------------------------------------------------------------------------------
-- Screens (built lazily so other controllers can toast before our start() runs)
-------------------------------------------------------------------------------------------------------------------------

type Screens = {
	main: ScreenGui,
	toastStack: Frame,
	feedStack: Frame,
	hudFx: Frame,
	banners: ScreenGui,
	alert: ScreenGui,
	modal: ScreenGui,
}
local screens: Screens? = nil
local hudHidden = false -- streamer mode (HUDController.VisibilityChanged)

local function isTouch(): boolean
	return Kit.isTouch()
end

local function toastWidth(): number
	return if isTouch() then TOAST_WIDTH_TOUCH else TOAST_WIDTH
end

local function toastMax(): number
	return if isTouch() then TOAST_MAX_TOUCH else TOAST_MAX_DESKTOP
end

-- UIScale value of one of our Kit.screen guis.
local function screenScale(gui: ScreenGui): number
	local scale = gui:FindFirstChildOfClass("UIScale")
	local s = if scale then scale.Scale else 1
	return if s > 0 then s else 1
end

local function layoutToasts(s: Screens)
	local touch = isTouch()
	-- the right-hand touch buttons live on default-scale screens (CombatHUD / DrivingUI); ours has the touch floor
	s.toastStack.Position = NotificationController.toastAnchor(touch, Kit.uiScale(), Kit.uiScale(Theme.TouchMinScale))
	s.toastStack.Size = UDim2.fromOffset(toastWidth() + 20, 4 * 110)
end

local function getScreens(): Screens
	local existing = screens
	if existing and existing.main.Parent then
		return existing
	end

	local main = Kit.screen("HC_Notifications", Theme.Layers.Toasts, { touchMin = Theme.TouchMinScale })
	local toastStack = Kit.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = TOAST_ANCHOR_DESKTOP,
		Size = UDim2.fromOffset(TOAST_WIDTH + 20, 4 * 110),
		Parent = main,
	}, { Kit.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Right) })
	local feedStack = Kit.new("Frame", {
		Name = "EventFeed",
		BackgroundTransparency = 1,
		Position = FEED_ANCHOR,
		Size = UDim2.fromOffset(FEED_WIDTH, (FEED_LINE_HEIGHT_TOUCH + 4) * FEED_MAX),
		Parent = main,
	}, { Kit.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left) })
	local hudFx = Kit.new("Frame", {
		Name = "CashFx",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = main,
	})

	local banners = Kit.screen("HC_Banners", Theme.Layers.Banners, { touchMin = Theme.TouchMinScale })
	local alert = Kit.screen("HC_TheftAlert", Theme.Layers.Banners - 1)
	alert.IgnoreGuiInset = true
	local modal = Kit.screen("HC_Modal", Theme.Layers.Overlay - 1)
	modal.IgnoreGuiInset = true
	for _, gui in { main, banners, alert } do
		gui.Enabled = not hudHidden
	end

	local built: Screens = {
		main = main,
		toastStack = toastStack,
		feedStack = feedStack,
		hudFx = hudFx,
		banners = banners,
		alert = alert,
		modal = modal,
	}
	screens = built
	layoutToasts(built)
	local function relayout()
		if screens == built then
			layoutToasts(built)
		end
	end
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(relayout)
	end)
	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(relayout)
	end
	return built
end

-- Convert an on-screen GuiObject's center into a Scale position inside `container`.
local function scaleCenterOf(obj: GuiObject, container: GuiObject): UDim2
	local size = container.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return UDim2.fromScale(0.5, 0.5)
	end
	local center = obj.AbsolutePosition + obj.AbsoluteSize / 2 - container.AbsolutePosition
	return UDim2.fromScale(center.X / size.X, center.Y / size.Y)
end

-- Optional HUD hook: HUDController.getCashAnchor(): GuiObject? (not in the spec; used when present).
local function hudCashAnchor(): GuiObject?
	local hud = lazyController("HUDController")
	if hud and typeof(hud.getCashAnchor) == "function" then
		local ok, anchor = pcall(hud.getCashAnchor)
		if ok and typeof(anchor) == "Instance" and anchor:IsA("GuiObject") and anchor.Visible then
			return anchor
		end
	end
	return nil
end

local function cashTargetIn(container: GuiObject): UDim2
	local anchor = hudCashAnchor()
	if anchor then
		return scaleCenterOf(anchor, container)
	end
	return HUD_CASH_TARGET
end

-------------------------------------------------------------------------------------------------------------------------
-- Toasts
-------------------------------------------------------------------------------------------------------------------------

type ToastRec = {
	key: string,
	holder: Frame,
	inner: Frame,
	text: TextLabel,
	countLabel: TextLabel,
	timerFill: Frame,
	count: number,
	duration: number,
	token: number,
	closing: boolean,
	width: number,
}

local toasts: { ToastRec } = {}
local toastOrder = 0

-- Touch toasts use a fixed readable text size and grow to fit it (TextScaled would shrink long messages to ~7 px on
-- a phone). Returns the toast height in design px.
local function touchToastHeight(text: string, textWidth: number): number
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, TOAST_TEXT_TOUCH, Enum.Font.FredokaOne, Vector2.new(textWidth, 1e4))
	end)
	local textHeight = if ok and typeof(bounds) == "Vector2" then bounds.Y else TOAST_TEXT_TOUCH * 2
	return math.clamp(math.ceil(textHeight) + 22, TOAST_HEIGHT, TOAST_HEIGHT + 3 * TOAST_TEXT_TOUCH)
end

local function closeToast(rec: ToastRec, fast: boolean?)
	if rec.closing then
		return
	end
	rec.closing = true
	local idx = table.find(toasts, rec)
	if idx then
		table.remove(toasts, idx)
	end
	local slideInfo = TweenInfo.new(if fast then 0.12 else 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(rec.inner, slideInfo, { Position = UDim2.fromOffset(rec.width + 40, 0) })
	task.delay(slideInfo.Time, function()
		if rec.holder.Parent then
			local collapse = tween(rec.holder, Theme.TweenFast, { Size = UDim2.fromOffset(rec.width, 0) })
			collapse.Completed:Once(function()
				rec.holder:Destroy()
			end)
		end
	end)
end

local function armToastTimer(rec: ToastRec)
	rec.token += 1
	local token = rec.token
	rec.timerFill.Size = UDim2.fromScale(1, 1)
	tween(rec.timerFill, TweenInfo.new(rec.duration, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(0, 1) })
	task.delay(rec.duration, function()
		if rec.token == token then
			closeToast(rec)
		end
	end)
end

function NotificationController.toast(kind: string, text: string, duration: number?)
	if typeof(text) ~= "string" or text == "" then
		return
	end
	local style = NotificationController.kindStyle(kind)
	local seconds = if typeof(duration) == "number" and duration > 0
		then math.clamp(duration, 1, 15)
		else (if kind == "error" then TOAST_DEFAULT_DURATION + 1 else TOAST_DEFAULT_DURATION)
	local key = tostring(kind) .. "|" .. text

	-- merge identical toasts
	for _, rec in toasts do
		if rec.key == key and not rec.closing then
			rec.count += 1
			rec.countLabel.Text = "×" .. rec.count
			rec.countLabel.Visible = true
			rec.duration = seconds
			Kit.pop(rec.inner, 1.08)
			armToastTimer(rec)
			playSound(style.sound)
			return
		end
	end

	local s = getScreens()
	toastOrder += 1
	local touch = isTouch()
	local width = toastWidth()
	local height = if touch then touchToastHeight(text, width - 84) else TOAST_HEIGHT

	local holder = Kit.new("Frame", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(width, 0),
		LayoutOrder = toastOrder,
		Parent = s.toastStack,
	})
	local inner = Kit.panel({
		Name = "Inner",
		Size = UDim2.fromOffset(width, height),
		Position = UDim2.fromOffset(width + 40, 0),
		BackgroundColor3 = Theme.Colors.Panel,
		Parent = holder,
	})
	Kit.new("Frame", {
		Name = "Accent",
		BackgroundColor3 = style.color,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 8, 1, -14),
		Position = UDim2.fromOffset(6, 7),
		Parent = inner,
	}, { Kit.corner(UDim.new(1, 0)) })
	local badge = Kit.new("Frame", {
		Name = "Badge",
		BackgroundColor3 = style.color,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 20, 0.5, 0),
		Size = UDim2.fromOffset(42, 42),
		Parent = inner,
	}, {
		Kit.corner(UDim.new(1, 0)),
		Kit.stroke(Theme.Colors.Stroke, 2.5),
		Kit.gradient(WHITE, Color3.fromRGB(190, 190, 190)),
	})
	Kit.new("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		Text = style.icon,
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		TextColor3 = WHITE,
		Parent = badge,
	})
	local label = Kit.label(text, if touch then TOAST_TEXT_TOUCH else 20, {
		Name = "Text",
		Position = UDim2.fromOffset(72, 6),
		Size = UDim2.new(1, -84, 1, -14),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextScaled = not touch,
	})
	if not touch then
		sizeConstraint(20, 11).Parent = label
	end
	label.Parent = inner
	local countLabel = Kit.label("×1", 16, {
		Name = "Count",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 6, 0, -10),
		Size = UDim2.fromOffset(40, 22),
		TextColor3 = style.color,
		Visible = false,
		ZIndex = 3,
	})
	countLabel.Parent = inner
	local timerBg = Kit.new("Frame", {
		Name = "Timer",
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 72, 1, -7),
		Size = UDim2.new(1, -86, 0, 3),
		Parent = inner,
	}, { Kit.corner(UDim.new(1, 0)) })
	local timerFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = style.color,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = timerBg,
	}, { Kit.corner(UDim.new(1, 0)) })
	local rec: ToastRec = {
		key = key,
		holder = holder,
		inner = inner,
		text = label,
		countLabel = countLabel,
		timerFill = timerFill,
		count = 1,
		duration = seconds,
		token = 0,
		closing = false,
		width = width,
	}
	-- click-to-dismiss on desktop only: on touch the toast sits near the action / driving buttons, and a full-size
	-- button would eat the taps meant for them (plain frames and labels let touches through)
	if not touch then
		local hit = Kit.new("TextButton", {
			Name = "Dismiss",
			BackgroundTransparency = 1,
			Text = "",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 5,
			Parent = inner,
		})
		hit.Activated:Connect(function()
			closeToast(rec, true)
		end)
	end

	table.insert(toasts, rec)
	for _, old in NotificationController.trimOldest(toasts, toastMax()) do
		closeToast(old, true)
	end

	tween(holder, Theme.TweenFast, { Size = UDim2.fromOffset(width, height) })
	tween(inner, Theme.TweenPop, { Position = UDim2.fromOffset(0, 0) })
	armToastTimer(rec)
	playSound(style.sound)
end

-------------------------------------------------------------------------------------------------------------------------
-- Announce banners
-------------------------------------------------------------------------------------------------------------------------

type BannerItem = { title: string, subtitle: string?, color: Color3, sound: string? }
local bannerQueue: { BannerItem } = {}
local bannerWorker: thread? = nil

local function buildBanner(parent: Instance, item: BannerItem): (Frame, UIScale, Frame)
	local color = item.color
	local dark = color:Lerp(BLACK, 0.6)
	local root = Kit.new("Frame", {
		Name = "Banner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = BANNER_POSITION,
		Size = UDim2.fromOffset(BANNER_SIZE.X, BANNER_SIZE.Y),
		Rotation = -4,
		Parent = parent,
	})
	local scale = Kit.new("UIScale", { Scale = 0.25, Parent = root })
	local fade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.14, 0.05),
		NumberSequenceKeypoint.new(0.86, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	local ribbon = Kit.new("Frame", {
		Name = "Ribbon",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 112),
		Parent = root,
	}, {
		Kit.new("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, dark),
				ColorSequenceKeypoint.new(0.5, Theme.Colors.Background),
				ColorSequenceKeypoint.new(1, dark),
			}),
			Transparency = fade,
		}),
	})
	-- neon edge lines
	for _, y in { 0, 1 } do
		Kit.new("Frame", {
			Name = "Edge",
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, y),
			Position = UDim2.fromScale(0.5, y),
			Size = UDim2.new(1, 0, 0, 4),
			Parent = ribbon,
		}, { Kit.new("UIGradient", { Transparency = fade }) })
	end
	local shine = Kit.new("Frame", {
		Name = "Shine",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = ribbon,
	})
	Kit.new("UIGradient", {
		Name = "Sweep",
		Rotation = 20,
		Offset = Vector2.new(-1.2, 0),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.42, 1),
			NumberSequenceKeypoint.new(0.5, 0.45),
			NumberSequenceKeypoint.new(0.58, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = shine,
	})

	local title = Kit.label(item.title, 58, {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, if item.subtitle and item.subtitle ~= "" then -14 else 0),
		Size = UDim2.new(1, -150, 0, 64),
		TextScaled = true,
		TextColor3 = WHITE,
		ZIndex = 3,
	})
	sizeConstraint(58, 22).Parent = title
	Kit.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, color:Lerp(WHITE, 0.55)),
			ColorSequenceKeypoint.new(0.55, color),
			ColorSequenceKeypoint.new(1, color:Lerp(BLACK, 0.15)),
		}),
		Parent = title,
	})
	local titleStroke = title:FindFirstChildOfClass("UIStroke")
	if titleStroke then
		titleStroke.Thickness = 4
	end
	title.Parent = root

	if item.subtitle and item.subtitle ~= "" then
		local sub = Kit.label(item.subtitle, 24, {
			Name = "Subtitle",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 32),
			Size = UDim2.new(1, -170, 0, 28),
			TextScaled = true,
			ZIndex = 3,
		})
		sizeConstraint(24, 12).Parent = sub
		sub.Parent = root
	end

	-- sparkles either side of the title
	for i, x in { 0.07, 0.93 } do
		Kit.new("TextLabel", {
			Name = "Sparkle",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, if i == 1 then 0.3 else 0.7),
			Size = UDim2.fromOffset(46, 46),
			Text = "✨",
			TextScaled = true,
			FontFace = Theme.Fonts.Display,
			ZIndex = 4,
			Parent = root,
		})
	end
	return root, scale, shine
end

local function isDriving(): boolean
	return player:GetAttribute("Driving") == true
end

-- Real px (inset-relative) where the top-center HUD stack ends: cash pill + wanted status (HUDController), the theft
-- alert banner, the event pills / hot drop banner (EventsClient). Each part is optional.
local function topStackBottom(includeAlert: boolean, includeEvents: boolean): number
	local bottom = 0
	local hud = lazyController("HUDController")
	if hud and typeof(hud.getTopStackBottom) == "function" then
		local ok, v = pcall(hud.getTopStackBottom)
		if ok and typeof(v) == "number" then
			bottom = math.max(bottom, v)
		end
	end
	if includeAlert then
		local a = NotificationController.getAlertBottom()
		if a then
			bottom = math.max(bottom, a)
		end
	end
	if includeEvents then
		local ev = lazyController("EventsClient")
		if ev and typeof(ev.getBottom) == "function" then
			local ok, v = pcall(ev.getBottom)
			if ok and typeof(v) == "number" then
				bottom = math.max(bottom, v)
			end
		end
	end
	return bottom
end

local function showBanner(item: BannerItem)
	local s = getScreens()
	local root, scale, shine = buildBanner(s.banners, item)
	playSound(item.sound or "Whoosh", 0.2)

	-- driving: a compact banner tucked under the top-center HUD, so it never sits over the road ahead
	local targetScale = 1
	if isDriving() then
		targetScale = BANNER_DRIVING_SCALE
		local top = topStackBottom(true, true) / screenScale(s.banners) + STACK_GAP
		root.Position = UDim2.new(0.5, 0, 0, math.ceil(top + BANNER_SIZE.Y * targetScale / 2))
		scale.Scale = 0.25 * targetScale
	end

	local popInfo = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	tween(scale, popInfo, { Scale = targetScale })
	tween(root, popInfo, { Rotation = 0 })
	for _, sparkle in root:GetChildren() do
		if sparkle.Name == "Sparkle" and sparkle:IsA("TextLabel") then
			sparkle.Rotation = -30
			tween(sparkle, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
				Rotation = 30,
			})
		end
	end
	task.wait(0.35)
	local sweep = shine:FindFirstChild("Sweep")
	if sweep and sweep:IsA("UIGradient") then
		tween(sweep, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
			Offset = Vector2.new(1.2, 0),
		})
	end
	task.wait(NotificationController.bannerHold(#bannerQueue))
	tween(scale, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 1.12 * targetScale })
	fadeOut(root, 0.3)
	task.wait(0.32)
	root:Destroy()
end

local function runBanners()
	while #bannerQueue > 0 do
		if isDriving() then
			-- mid-getaway a backlog of banners is noise: keep only the newest few
			while #bannerQueue > BANNER_DRIVING_KEEP do
				table.remove(bannerQueue, 1)
			end
		end
		local item = table.remove(bannerQueue, 1) :: BannerItem
		local ok, err = pcall(showBanner, item)
		if not ok then
			warn("[NotificationController] banner failed: " .. tostring(err))
		end
	end
	bannerWorker = nil
end

function NotificationController.announce(title: string, subtitle: string?, color: Color3?, sound: string?)
	if typeof(title) ~= "string" or title == "" then
		return
	end
	local last = bannerQueue[#bannerQueue]
	if last and last.title == title and last.subtitle == subtitle then
		return -- exact duplicate already waiting
	end
	table.insert(bannerQueue, {
		title = title,
		subtitle = if typeof(subtitle) == "string" then subtitle else nil,
		color = if typeof(color) == "Color3" then color else Theme.Colors.Gold,
		sound = if typeof(sound) == "string" then sound else nil,
	})
	-- don't let a flood of announcements stall for minutes
	while #bannerQueue > 6 do
		table.remove(bannerQueue, 1)
	end
	if not bannerWorker then
		bannerWorker = task.spawn(runBanners)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Event feed
-------------------------------------------------------------------------------------------------------------------------

type FeedRec = { holder: Frame, inner: Frame, closing: boolean }
local feedLines: { FeedRec } = {}
local feedOrder = 0

local function closeFeed(rec: FeedRec, seconds: number)
	if rec.closing then
		return
	end
	rec.closing = true
	local idx = table.find(feedLines, rec)
	if idx then
		table.remove(feedLines, idx)
	end
	fadeOut(rec.inner, seconds)
	task.delay(seconds, function()
		rec.holder:Destroy()
	end)
end

-- Beside the HUD menu (desktop: right of the column, under the chat window; touch: under the strip).
local function positionFeed(s: Screens)
	local hud = lazyController("HUDController")
	if hud and typeof(hud.getFeedAnchor) == "function" then
		local ok, anchor = pcall(hud.getFeedAnchor)
		if ok and typeof(anchor) == "Vector2" then
			local y = anchor.Y
			if isTouch() then
				-- phones: the theft alarm banner sits under the menu strip too; keep the feed below it
				local alertBottom = NotificationController.getAlertBottom()
				if alertBottom then
					y = math.max(y, alertBottom + STACK_GAP * screenScale(s.main))
				end
			end
			local scale = screenScale(s.main)
			s.feedStack.Position = UDim2.fromOffset(math.floor(anchor.X / scale), math.floor(y / scale))
			return
		end
	end
	s.feedStack.Position = FEED_ANCHOR
end

function NotificationController.feed(richText: string)
	if typeof(richText) ~= "string" or richText == "" then
		return
	end
	if hudHidden then
		return -- streamer mode: feed lines name other players
	end
	local s = getScreens()
	positionFeed(s)
	local touch = isTouch()
	local lineHeight = if touch then FEED_LINE_HEIGHT_TOUCH else FEED_LINE_HEIGHT
	feedOrder -= 1 -- newest on top
	local holder = Kit.new("Frame", {
		Name = "FeedLine",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(FEED_WIDTH, lineHeight),
		LayoutOrder = feedOrder,
		Parent = s.feedStack,
	})
	local inner = Kit.new("Frame", {
		Name = "Inner",
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(-FEED_WIDTH - 20, 0),
		Parent = holder,
	}, {
		Kit.corner(Theme.CornerSmall),
		Kit.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(0.65, 0.35),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})
	Kit.new("Frame", {
		Name = "Tick",
		BackgroundColor3 = Theme.Colors.Primary,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 4, 1, -8),
		Position = UDim2.fromOffset(4, 4),
		Parent = inner,
	}, { Kit.corner(UDim.new(1, 0)) })
	local label = Kit.label(richText, if touch then FEED_TEXT_TOUCH else FEED_TEXT, {
		Name = "Text",
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -18, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	label.Parent = inner

	local rec: FeedRec = { holder = holder, inner = inner, closing = false }
	table.insert(feedLines, rec)
	for _, old in NotificationController.trimOldest(feedLines, FEED_MAX) do
		closeFeed(old, 0.15)
	end
	tween(inner, Theme.TweenPop, { Position = UDim2.fromOffset(0, 0) })
	task.delay(FEED_LIFETIME, function()
		closeFeed(rec, 0.6)
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Cash popups
-------------------------------------------------------------------------------------------------------------------------

type WorldPopup = {
	attachment: Attachment,
	gui: BillboardGui,
	label: TextLabel,
	token: number,
	startedAt: number,
	fades: { Tween },
}
local worldPopups: { WorldPopup } = {}
local fxAnchor: Part? = nil

local function getFxAnchor(): Part
	local anchor = fxAnchor
	if anchor and anchor.Parent then
		return anchor
	end
	local folder = Workspace:FindFirstChild("HC_ClientFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "HC_ClientFX"
		folder.Parent = Workspace
	end
	local part = Instance.new("Part")
	part.Name = "PopupAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new()
	part.Parent = folder
	fxAnchor = part
	return part
end

local function acquireWorldPopup(): WorldPopup
	local anchor = getFxAnchor()
	local now = os.clock()
	local pick: WorldPopup? = nil
	for _, p in worldPopups do
		if p.attachment.Parent == anchor and not p.gui.Enabled then
			pick = p
			break
		end
	end
	if not pick and #worldPopups < WORLD_POPUP_POOL then
		local att = Instance.new("Attachment")
		att.Name = "CashPopup"
		att.Parent = anchor
		local gui = Kit.new("BillboardGui", {
			Name = "CashPopup",
			Size = UDim2.fromOffset(WORLD_POPUP_SIZE.X, WORLD_POPUP_SIZE.Y),
			AlwaysOnTop = true,
			LightInfluence = 0,
			MaxDistance = 260,
			ResetOnSpawn = false,
			Enabled = false,
			Parent = att,
		})
		local label = Kit.label("", 44, {
			Name = "Amount",
			Size = UDim2.fromScale(1, 1),
			TextScaled = true,
			TextColor3 = Theme.Colors.Cash,
		})
		sizeConstraint(48, 14).Parent = label
		Kit.new("UIScale", { Parent = label })
		label.Parent = gui
		pick = { attachment = att, gui = gui, label = label, token = 0, startedAt = 0, fades = {} }
		table.insert(worldPopups, pick :: WorldPopup)
	end
	if not pick then
		pick = worldPopups[1]
		for _, p in worldPopups do
			if p.startedAt < (pick :: WorldPopup).startedAt then
				pick = p
			end
		end
	end
	local p = pick :: WorldPopup
	if p.attachment.Parent ~= anchor then
		p.attachment.Parent = anchor
	end
	p.startedAt = now
	return p
end

local function worldCashPopup(amount: number, position: Vector3)
	local p = acquireWorldPopup()
	p.token += 1
	local token = p.token
	for _, t in p.fades do
		t:Cancel() -- a recycled popup may still be fading out
	end
	table.clear(p.fades)
	local big = math.abs(amount) >= 10000
	p.attachment.WorldPosition = position
	p.label.Text = NotificationController.formatCashDelta(amount)
	p.label.TextColor3 = if amount < 0 then Theme.Colors.Danger elseif big then Theme.Colors.Gold else Theme.Colors.Cash
	p.label.TextTransparency = 0
	local stroke = p.label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0
	end
	local jitter = Vector3.new(rng:NextNumber(-1.5, 1.5), 0, rng:NextNumber(-1.5, 1.5))
	p.gui.StudsOffsetWorldSpace = Vector3.new(0, 3, 0) + jitter
	-- billboards are raw pixels: follow the screen UI scale (with the touch floor) so a phone isn't half covered
	local uiScale = Kit.uiScale(Theme.TouchMinScale)
	local size = if big then WORLD_POPUP_SIZE_BIG else WORLD_POPUP_SIZE
	p.gui.Size = UDim2.fromOffset(math.floor(size.X * uiScale), math.floor(size.Y * uiScale))
	local constraint = p.label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint.MaxTextSize = math.max(constraint.MinTextSize, math.floor(48 * uiScale))
	end
	p.gui.Enabled = true
	Kit.pop(p.label, 1.7)
	tween(p.gui, TweenInfo.new(1.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = Vector3.new(0, 10, 0) + jitter,
	})
	task.delay(0.8, function()
		if p.token ~= token then
			return
		end
		local info = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		table.insert(p.fades, tween(p.label, info, { TextTransparency = 1 }))
		if stroke then
			table.insert(p.fades, tween(stroke, info, { Transparency = 1 }))
		end
		task.delay(0.47, function()
			if p.token == token then
				p.gui.Enabled = false
			end
		end)
	end)
end

local function hudCashPopup(amount: number)
	local s = getScreens()
	local start = HUD_CASH_POSITION
	local anchor = hudCashAnchor()
	if anchor then
		local c = scaleCenterOf(anchor, s.hudFx)
		start = UDim2.new(c.X.Scale, 0, c.Y.Scale, 52)
	end
	local jitterX = rng:NextInteger(-50, 50)
	local label = Kit.label(NotificationController.formatCashDelta(amount), 30, {
		Name = "CashPopup",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = start + UDim2.fromOffset(jitterX, 0),
		Size = UDim2.fromOffset(240, 40),
		TextColor3 = if amount < 0 then Theme.Colors.Danger else Theme.Colors.Cash,
		ZIndex = 5,
	})
	label.Parent = s.hudFx
	Kit.pop(label, 1.6)
	tween(label, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = start + UDim2.fromOffset(jitterX, -46),
	})
	task.delay(0.7, function()
		fadeOut(label, 0.4)
		task.delay(0.42, function()
			label:Destroy()
		end)
	end)
end

function NotificationController.cashPopup(amount: number, worldPosition: Vector3?)
	if typeof(amount) ~= "number" or amount ~= amount or amount == 0 then
		return
	end
	if typeof(worldPosition) == "Vector3" then
		worldCashPopup(amount, worldPosition)
	else
		hudCashPopup(amount)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Offline earnings modal
-------------------------------------------------------------------------------------------------------------------------

type OfflineModal = { root: Frame, card: Frame, amountLabel: TextLabel, total: number, collecting: boolean }
local offline: OfflineModal? = nil

local function coinBurst(fromObj: GuiObject, container: Frame)
	local origin = scaleCenterOf(fromObj, container)
	local target = cashTargetIn(container)
	local icons = { "💵", "💰", "🪙", "💵" }
	for i = 1, 16 do
		local coin = Kit.new("TextLabel", {
			Name = "Coin",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = origin,
			Size = UDim2.fromOffset(38, 38),
			Text = icons[(i % #icons) + 1],
			TextScaled = true,
			FontFace = Theme.Fonts.Display,
			Rotation = rng:NextNumber(-40, 40),
			ZIndex = 20,
			Parent = container,
		})
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(70, 170)
		local burst = origin + UDim2.fromOffset(math.cos(angle) * radius, math.sin(angle) * radius - 40)
		tween(coin, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = burst })
		task.delay(0.3 + i * 0.035, function()
			local fly = tween(coin, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = target,
				Size = UDim2.fromOffset(20, 20),
				Rotation = rng:NextNumber(-180, 180),
			})
			fly.Completed:Once(function()
				coin:Destroy()
				if i % 4 == 0 then
					playSound("Coin", 0.05)
				end
			end)
		end)
	end
end

-- The server credits offline earnings before the modal shows; the HUD counter holds that amount back until COLLECT.
local function hudCash(method: string, amount: number?)
	local hud = lazyController("HUDController")
	local fn = hud and hud[method]
	if typeof(fn) == "function" then
		pcall(fn, amount)
	end
end

local function closeOffline(withBurst: boolean)
	local m = offline
	if not m or m.collecting then
		return
	end
	m.collecting = true
	local root = m.root
	if withBurst then
		local button = m.card:FindFirstChild("Collect", true)
		if button and button:IsA("GuiObject") then
			coinBurst(button, root)
		end
		playSound("CashBig")
		playSound("CountingMoney")
		-- count the HUD up as the first coins land in it
		task.delay(0.6, hudCash, "releaseCash")
	else
		hudCash("releaseCash")
	end
	local cardScale = m.card:FindFirstChildOfClass("UIScale")
	if cardScale then
		tween(cardScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0.6 })
	end
	fadeOut(m.card, 0.25)
	local dim = root:FindFirstChild("Dim")
	if dim and dim:IsA("Frame") then
		tween(dim, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
	end
	task.delay(1.8, function()
		root:Destroy()
		if offline == m then
			offline = nil
		end
	end)
end

local function amountText(n: number): string
	return NotificationController.formatCashDelta(n)
end

-- True while the "WHILE YOU WERE AWAY" modal is up (before COLLECT / auto-close).
function NotificationController.isOfflineOpen(): boolean
	local m = offline
	return m ~= nil and not m.collecting
end

function NotificationController.offlineEarnings(amount: number, seconds: number?)
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	local away = if typeof(seconds) == "number" and seconds == seconds then seconds else 0

	local existing = offline
	if existing and not existing.collecting then
		existing.total += amount
		hudCash("holdCash", amount)
		Kit.tweenNumber(existing.amountLabel, existing.total, amountText, 1)
		Kit.pop(existing.amountLabel, 1.15)
		return
	end
	hudCash("holdCash", amount)

	local s = getScreens()
	local root = Kit.new("Frame", {
		Name = "OfflineEarnings",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = s.modal,
	})
	local dim = Kit.new("Frame", {
		Name = "Dim",
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = true, -- swallow taps behind the modal
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})
	tween(dim, TweenInfo.new(0.3), { BackgroundTransparency = 0.35 })

	local card = Kit.panel({
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(520, 350),
		Parent = root,
	})
	local cardScale = Kit.new("UIScale", { Scale = 0.5, Parent = card })
	tween(cardScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })

	-- header
	local header = Kit.new("Frame", {
		Name = "Header",
		BackgroundColor3 = Theme.Colors.Primary,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 62),
		Parent = card,
	}, { Kit.corner(), Kit.gradient(WHITE, Color3.fromRGB(170, 170, 170)) })
	Kit.new("Frame", {
		BackgroundColor3 = Theme.Colors.Primary,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -14),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = header,
	}, { Kit.gradient(Color3.fromRGB(190, 190, 190), Color3.fromRGB(170, 170, 170)) })
	local headerLabel = Kit.label("💤 WHILE YOU WERE AWAY", 32, {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -30, 0, 40),
		TextScaled = true,
		ZIndex = 2,
	})
	sizeConstraint(32, 14).Parent = headerLabel
	headerLabel.Parent = header

	local subText = if away >= 60
		then ("Your garage kept printing cash for <b>%s</b>!"):format(Format.duration(away))
		else "Your garage kept printing cash!"
	local sub = Kit.label(subText, 20, {
		Name = "Subtitle",
		Position = UDim2.fromOffset(20, 74),
		Size = UDim2.new(1, -40, 0, 26),
		TextColor3 = Theme.Colors.TextDim,
		TextScaled = true,
	})
	sizeConstraint(20, 11).Parent = sub
	sub.Parent = card

	-- god rays behind the amount
	local rays = Kit.new("Frame", {
		Name = "Rays",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 162),
		Size = UDim2.fromOffset(250, 250),
		Parent = card,
	})
	for i = 0, 7 do
		Kit.new("Frame", {
			Name = "Ray",
			BackgroundColor3 = Theme.Colors.Gold,
			BackgroundTransparency = 0.8,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, 26, 1, 0),
			Rotation = i * 22.5,
			Parent = rays,
		}, {
			Kit.new("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.5, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		})
	end
	tween(rays, TweenInfo.new(9, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 })

	local amountLabel = Kit.label(amountText(0), 68, {
		Name = "Amount",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 162),
		Size = UDim2.new(1, -40, 0, 80),
		TextColor3 = Theme.Colors.Cash,
		TextScaled = true,
		ZIndex = 3,
	})
	sizeConstraint(68, 24).Parent = amountLabel
	local amountStroke = amountLabel:FindFirstChildOfClass("UIStroke")
	if amountStroke then
		amountStroke.Thickness = 5
	end
	amountLabel.Parent = card
	amountLabel:SetAttribute("Value", 0)
	Kit.tweenNumber(amountLabel, amount, amountText, 1.3)

	-- collect button (wrapper carries the breathing pulse; Kit.juice owns the button's own UIScale)
	local wrap = Kit.new("Frame", {
		Name = "CollectWrap",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -22),
		Size = UDim2.fromOffset(270, 68),
		Parent = card,
	})
	local pulse = Kit.new("UIScale", { Parent = wrap })
	tween(pulse, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.06 })
	local button = Kit.button("💰 COLLECT", Theme.Colors.Cash, {
		Name = "Collect",
		Size = UDim2.fromScale(1, 1),
		TextSize = 32,
	})
	button.Parent = wrap

	local modal: OfflineModal =
		{ root = root, card = card, amountLabel = amountLabel, total = amount, collecting = false }
	offline = modal
	button.Activated:Connect(function()
		closeOffline(true)
	end)
	task.delay(OFFLINE_AUTO_CLOSE, function()
		if offline == modal then
			closeOffline(false)
		end
	end)
	playSound("Purchase", 0.2)
end

-------------------------------------------------------------------------------------------------------------------------
-- Car stolen alert
-------------------------------------------------------------------------------------------------------------------------

type AlertRec = { thief: string, carId: string, mutation: string, token: number }
type AlertUI = {
	root: Frame,
	edges: { Frame },
	holder: Frame, -- positioned + device-scaled wrapper (Kit.pop owns the banner's own UIScale)
	holderScale: UIScale,
	banner: Frame,
	title: TextLabel,
	tweens: { Tween },
}

local alerts: { AlertRec } = {}
local alertUI: AlertUI? = nil
local alertSiren: Sound? = nil
local alertToken = 0
local alertLastCar: Model? = nil
local ALERT_WAYPOINT_ID = "stolen_car"

local function findPlayerByName(name: string): Player?
	for _, p in Players:GetPlayers() do
		if p.Name == name then
			return p
		end
	end
	for _, p in Players:GetPlayers() do
		if p.DisplayName == name then
			return p
		end
	end
	return nil
end

-- The stolen car itself (TheftService marks it TheftActive + TheftVictimUserId), cached between rescans because the
-- waypoint getter runs every frame. Following the car also covers dropped cars and hijacks by a second thief.
local alertCar: Model? = nil
local alertCarScanAt = -math.huge

local function resetAlertCar()
	alertLastCar = nil
	alertCar = nil
	alertCarScanAt = -math.huge
end

local function isOurStolenCar(model: Model?): boolean
	return model ~= nil
		and model.Parent ~= nil
		and model:GetAttribute("TheftActive") == true
		and model:GetAttribute("TheftVictimUserId") == player.UserId
end

local function findStolenCar(rec: AlertRec): Model?
	local cached = alertCar
	if isOurStolenCar(cached) then
		return cached
	end
	local now = os.clock()
	if now - alertCarScanAt < ALERT_CAR_RESCAN then
		return nil
	end
	alertCarScanAt = now
	local models: { Model } = {}
	local infos: { CarInfo } = {}
	for _, inst in CollectionService:GetTagged("Vehicle") do
		if inst:IsA("Model") and inst:GetAttribute("TheftActive") == true then
			table.insert(models, inst)
			table.insert(infos, {
				victimUserId = inst:GetAttribute("TheftVictimUserId"),
				active = true,
				carId = inst:GetAttribute("CarId"),
				mutation = inst:GetAttribute("Mutation"),
			})
		end
	end
	local idx = NotificationController.pickStolenCar(
		infos,
		player.UserId,
		if rec.carId ~= "" then rec.carId else nil,
		rec.mutation
	)
	alertCar = if idx then models[idx] else nil
	return alertCar
end

-- Position of the stolen car for the live waypoint; falls back to the thief found by (display) name.
local function thiefPosition(): Vector3?
	local rec = alerts[#alerts]
	if not rec then
		return nil
	end
	local car = findStolenCar(rec)
	if car then
		return car:GetPivot().Position
	end
	local thief = findPlayerByName(rec.thief)
	local char = thief and thief.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if seat then
		local model = seat:FindFirstAncestorOfClass("Model")
		if model and model ~= char then
			alertLastCar = model
			return model:GetPivot().Position
		end
		return seat.Position
	end
	local lastCar = alertLastCar
	if lastCar and lastCar.Parent then
		return lastCar:GetPivot().Position
	end
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function buildAlertUI(): AlertUI
	local s = getScreens()
	local root = Kit.new("Frame", {
		Name = "TheftAlert",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = s.alert,
	})
	local red = Theme.Colors.Danger
	local edgeFade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.45, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	-- top, bottom, left, right: gradient starts opaque at the screen edge and fades inward
	local specs = {
		{
			name = "Top",
			size = UDim2.fromScale(1, 0.17),
			pos = UDim2.fromScale(0, 0),
			anchor = Vector2.new(0, 0),
			rot = 90,
		},
		{
			name = "Bottom",
			size = UDim2.fromScale(1, 0.17),
			pos = UDim2.fromScale(0, 1),
			anchor = Vector2.new(0, 1),
			rot = 270,
		},
		{
			name = "Left",
			size = UDim2.fromScale(0.11, 1),
			pos = UDim2.fromScale(0, 0),
			anchor = Vector2.new(0, 0),
			rot = 0,
		},
		{
			name = "Right",
			size = UDim2.fromScale(0.11, 1),
			pos = UDim2.fromScale(1, 0),
			anchor = Vector2.new(1, 0),
			rot = 180,
		},
	}
	local edges: { Frame } = {}
	for _, spec in specs do
		local edge = Kit.new("Frame", {
			Name = "Edge" .. spec.name,
			BackgroundColor3 = red,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			AnchorPoint = spec.anchor,
			Position = spec.pos,
			Size = spec.size,
			Parent = root,
		}, { Kit.new("UIGradient", { Rotation = spec.rot, Transparency = edgeFade }) })
		table.insert(edges, edge)
	end

	-- the banner lives in the inset-aware banners gui so it sits below the topbar + cash counter on every device;
	-- the vignette gui ignores the inset so the red glow reaches the very top of the screen
	local holder = Kit.new("Frame", {
		Name = "AlertBanner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = ALERT_BANNER_POSITION,
		Size = UDim2.fromOffset(ALERT_BANNER_SIZE.X, ALERT_BANNER_SIZE.Y),
		Parent = s.banners,
	})
	local holderScale = Kit.new("UIScale", { Name = "DeviceScale", Parent = holder })
	local banner = Kit.panel({
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0), -- the pop / sway pivot at the top-center, like the holder
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = red,
		Parent = holder,
	})
	Kit.new("UIScale", { Scale = 0.3, Parent = banner })
	local title = Kit.label("", 28, {
		Name = "Title",
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -28, 0, 44),
		TextScaled = true,
	})
	sizeConstraint(28, 12).Parent = title
	title.Parent = banner
	local sub = Kit.label("Chase them down and BONK 🏏 them to get it back!", 20, {
		Name = "Subtitle",
		Position = UDim2.new(0, 14, 1, -36),
		Size = UDim2.new(1, -28, 0, 26),
		TextColor3 = Color3.fromRGB(255, 230, 230),
		TextScaled = true,
	})
	sizeConstraint(20, 12).Parent = sub
	sub.Parent = banner
	return {
		root = root,
		edges = edges,
		holder = holder,
		holderScale = holderScale,
		banner = banner,
		title = title,
		tweens = {},
	}
end

local function stopAlertTweens(ui: AlertUI)
	for _, t in ui.tweens do
		t:Cancel()
	end
	table.clear(ui.tweens)
end

-- Design px (HC_Banners) of the alert banner's top: right under the HUD's cash pill / wanted stars.
local alertBannerTop = ALERT_BANNER_POSITION.Y.Offset

local alertBannerScale = 1

local function placeAlertBanner(ui: AlertUI)
	local s = getScreens()
	local bottom = topStackBottom(false, false)
	local touch = isTouch()
	if touch then
		-- phones: the banner is wider than the gap between the menu strip and the toasts; go below the strip
		local hud = lazyController("HUDController")
		if hud and typeof(hud.getMenuBottom) == "function" then
			local ok, v = pcall(hud.getMenuBottom)
			if ok and typeof(v) == "number" then
				bottom = math.max(bottom, v)
			end
		end
	end
	local top = if bottom > 0
		then math.ceil(bottom / screenScale(s.banners)) + STACK_GAP
		else ALERT_BANNER_POSITION.Y.Offset
	local scale = if touch then ALERT_TOUCH_SCALE else 1
	if top ~= alertBannerTop or ui.holder.Position.Y.Offset ~= top then
		alertBannerTop = top
		ui.holder.Position = UDim2.new(0.5, 0, 0, top)
	end
	if scale ~= alertBannerScale or ui.holderScale.Scale ~= scale then
		alertBannerScale = scale
		ui.holderScale.Scale = scale
	end
end

-- Real px (inset-relative) of the alert banner's bottom while the alarm is up (EventsClient stacks below it).
function NotificationController.getAlertBottom(): number?
	local ui = alertUI
	local s = screens
	if not ui or not s or #alerts == 0 or hudHidden then
		return nil
	end
	return (alertBannerTop + ALERT_BANNER_SIZE.Y * alertBannerScale) * screenScale(s.banners)
end

local function showAlertUI()
	local ui = alertUI
	if not ui or not ui.root.Parent then
		ui = buildAlertUI()
		alertUI = ui
	end
	local current = ui :: AlertUI
	local rec = alerts[#alerts]
	if rec then
		current.title.Text = NotificationController.stolenAlertText(rec.thief, rec.carId, rec.mutation)
	end
	placeAlertBanner(current)
	if #current.tweens > 0 then
		Kit.pop(current.banner, 1.12) -- already showing: just punch the banner
		return
	end
	-- follow the HUD stack (the wanted stars can appear / disappear while the alarm is up)
	task.spawn(function()
		while alertUI == current do
			task.wait(0.3)
			if alertUI == current then
				placeAlertBanner(current)
				positionFeed(getScreens())
			end
		end
	end)
	current.root.Visible = true
	local pulseInfo = TweenInfo.new(0.42, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	for _, edge in current.edges do
		edge.BackgroundTransparency = 0.05
		table.insert(current.tweens, tween(edge, pulseInfo, { BackgroundTransparency = 0.7 }))
	end
	local scale = current.banner:FindFirstChildOfClass("UIScale")
	if scale then
		scale.Scale = 0.3
		tween(scale, Theme.TweenPop, { Scale = 1 })
	end
	-- slow sway + red flash in sync with the vignette (a constant jitter would be grating over a 150s theft)
	current.banner.Rotation = -1.5
	table.insert(
		current.tweens,
		tween(
			current.banner,
			TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Rotation = 1.5 }
		)
	)
	current.banner.BackgroundColor3 = Theme.Colors.Danger
	table.insert(
		current.tweens,
		tween(current.banner, pulseInfo, { BackgroundColor3 = Theme.Colors.Danger:Lerp(BLACK, 0.35) })
	)
end

local function hideAlertUI()
	local ui = alertUI
	if not ui then
		return
	end
	alertUI = nil
	stopAlertTweens(ui)
	positionFeed(getScreens())
	ui.banner.Rotation = 0
	fadeOut(ui.root, 0.4)
	fadeOut(ui.holder, 0.4)
	task.delay(0.45, function()
		ui.root:Destroy()
		ui.holder:Destroy()
	end)
end

local function setAlertWaypoint(on: boolean)
	local wp = lazyController("WaypointController")
	if not wp then
		return
	end
	if on and typeof(wp.track) == "function" then
		pcall(wp.track, ALERT_WAYPOINT_ID, thiefPosition, Theme.Colors.Danger, "YOUR CAR")
	elseif not on and typeof(wp.clear) == "function" then
		pcall(wp.clear, ALERT_WAYPOINT_ID)
	end
end

local function refreshAlert()
	if #alerts > 0 then
		showAlertUI()
		if not alertSiren then
			local ok, snd = pcall(SoundController.playLoop, "Siren")
			if ok and snd then
				snd.Volume *= 0.7
				alertSiren = snd
				-- full blast first, then settle so the alarm stays audible without drowning the game
				task.delay(5, function()
					if alertSiren == snd and snd.Parent then
						tween(snd, TweenInfo.new(1.5), { Volume = snd.Volume * 0.45 })
					end
				end)
			end
		end
		setAlertWaypoint(true)
	else
		hideAlertUI()
		if alertSiren then
			pcall(SoundController.stopLoop, alertSiren)
			alertSiren = nil
		end
		resetAlertCar()
		setAlertWaypoint(false)
	end
end

function NotificationController.carStolenAlert(thiefName: string, carId: string, mutation: string, active: boolean)
	local thief = if typeof(thiefName) == "string" and thiefName ~= "" then thiefName else "SOMEONE"
	local car = if typeof(carId) == "string" then carId else ""
	local mut = if typeof(mutation) == "string" then mutation else "None"

	if active == true then
		-- replace an alert for the same car (e.g. another thief took over the theft)
		for i = #alerts, 1, -1 do
			if alerts[i].carId == car and alerts[i].mutation == mut then
				table.remove(alerts, i)
			end
		end
		alertToken += 1
		local rec: AlertRec = { thief = thief, carId = car, mutation = mut, token = alertToken }
		table.insert(alerts, rec)
		resetAlertCar()
		task.delay(ALERT_SAFETY_SECONDS, function()
			local idx = table.find(alerts, rec)
			if idx then
				table.remove(alerts, idx)
				refreshAlert()
			end
		end)
		refreshAlert()
	else
		local removedAny = false
		for i = #alerts, 1, -1 do
			if alerts[i].carId == car and alerts[i].mutation == mut then
				table.remove(alerts, i)
				removedAny = true
			end
		end
		if not removedAny then
			table.clear(alerts) -- unknown payload: never leave an alarm stuck on
		end
		refreshAlert()
	end
end

-- True while at least one "your car is being stolen" alarm is active.
function NotificationController.isAlertActive(): boolean
	return #alerts > 0
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local function safeListen(name: string, handler: (...any) -> ())
	local ok, err = pcall(Net.listen, name, handler)
	if not ok then
		warn(("[NotificationController] could not listen to %s: %s"):format(name, tostring(err)))
	end
end

function NotificationController.init() end

function NotificationController.start()
	getScreens()

	-- streamer mode: hide everything that can carry other players' names (toasts, feed, banners) and the alarm
	-- vignette; the offline modal stays (it is an interaction, not an overlay)
	local hud = lazyController("HUDController")
	if hud and hud.VisibilityChanged and typeof(hud.isHidden) == "function" then
		local function applyHidden(value: boolean)
			hudHidden = value == true
			local s = screens
			if s then
				for _, gui in { s.main, s.banners, s.alert } do
					gui.Enabled = not hudHidden
				end
			end
		end
		hud.VisibilityChanged:Connect(applyHidden)
		local ok, value = pcall(hud.isHidden)
		applyHidden(ok and value == true)
	end

	safeListen("Notify", function(kind: any, text: any, duration: any)
		if typeof(text) ~= "string" then
			return
		end
		NotificationController.toast(
			if typeof(kind) == "string" then kind else "info",
			text,
			if typeof(duration) == "number" then duration else nil
		)
	end)
	safeListen("Announce", function(title: any, subtitle: any, color: any, sound: any)
		if typeof(title) ~= "string" then
			return
		end
		NotificationController.announce(
			title,
			if typeof(subtitle) == "string" then subtitle else nil,
			if typeof(color) == "Color3" then color else nil,
			if typeof(sound) == "string" then sound else nil
		)
	end)
	safeListen("EventFeed", function(richText: any)
		if typeof(richText) == "string" then
			NotificationController.feed(richText)
		end
	end)
	safeListen("CashPopup", function(amount: any, worldPosition: any)
		if typeof(amount) == "number" then
			NotificationController.cashPopup(amount, if typeof(worldPosition) == "Vector3" then worldPosition else nil)
		end
	end)
	safeListen("OfflineEarnings", function(amount: any, seconds: any)
		if typeof(amount) == "number" then
			NotificationController.offlineEarnings(amount, if typeof(seconds) == "number" then seconds else 0)
		end
	end)
	safeListen("CarStolenAlert", function(thiefName: any, carId: any, mutation: any, active: any)
		NotificationController.carStolenAlert(thiefName, carId, mutation, active == true)
	end)

	-- respawn safety: the screens survive respawn (ResetOnSpawn=false); nothing else to rebuild
	if player then
		player.CharacterAdded:Connect(function()
			resetAlertCar()
		end)
	end
end

return NotificationController
