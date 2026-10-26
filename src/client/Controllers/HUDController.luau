--!strict
-- HUDController (SPEC §7): the always-on heads-up display.
--
--  * Cash pill (top-center): 💵 + count-up cash (Format.cash), "+$X/s" income tab (IncomePerSec attribute), ⚡ multiplier
--    chip, 👑 when VIP. Pop + green flash when cash goes up, red shake when it goes down.
--  * Wanted stars (top-right): 5 ★ that pop/flash as they fill or empty, red/blue police-light pulse while wanted,
--    "🚔 GETTING BUSTED!" bar under them while BustProgress > 0.
--  * Menu column (left): STORE / GEAR / INDEX / DAILY / CONTRACTS / GIFTS / REBIRTH (+ CODES / SETTINGS row top-left)
--    -> MenuController.toggle/open (lazy). Red "!" badges: daily claimable, playtime gift ready, rebirth affordable,
--    gear upgrade affordable, new cars in the index. The grid wraps into a second column on short (phone) screens
--    so it never sits on the touch thumbstick.
--  * 🏠 HOME (bottom-center, above the backpack hotbar): Net.fire("GoHome"). Hidden while driving, inside your own
--    garage, or in tutorial focus mode; greyed with 🚨 while wanted; local cooldown display after a successful trip.
--  * Theft delivery timer (TheftState): "🚨 DELIVER IT HOME! 1:42" + draining bar. Sits bottom-center just above the
--    speedometer (the thief is driving and looking there; EventsClient owns the strip under the cash pill).
--  * BUSTED overlay (Busted remote): flash, police lights, comic "BUSTED!" stamp slam, lost cash, fades after 3s.
--  * Streamer mode: snapshot.settings.hideHud hides all of the above; a tiny 👁️ button (top-left) turns it back on.
--
-- Public API (beyond init/start):
--   getCashAnchor(): GuiObject?           cash pill (NotificationController flies coins / popups into it)
--   getMenuButton(id): GuiButton?         e.g. "Store", "GearShop", "Daily" (TutorialController may point at them)
--   setFocusMode(on: boolean)             tutorial: hide menus + HOME, then pop them back in
--   isHidden(): boolean                   streamer mode active
--   showBusted(lostCash: number)          play the BUSTED overlay (also driven by the Busted remote)
--   getBottomClearance(): number          design px reserved at bottom-center (hotbar + HOME button when shown)
--   VisibilityChanged: Signal(hidden: boolean)
-- Pure helpers (tests): clampStars, starStates, cashTrend, theftView, playtimeClaimable, rebirthReady,
--   gearAffordable, homeState, gridFit, countGarage, menuNameCandidates.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Economy = require(Config:WaitForChild("Economy"))
local PoliceConfig = require(Config:WaitForChild("Police"))
local Util = Shared:WaitForChild("Util")
local EconomyMath = require(Util:WaitForChild("EconomyMath"))
local Format = require(Util:WaitForChild("Format"))
local MapLayout = require(Util:WaitForChild("MapLayout"))
local Signal = require(Util:WaitForChild("Signal"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER: safe to require at the top.
local StateController = require(script.Parent:WaitForChild("StateController"))

local HUDController = {}

-- Fired with (hidden: boolean) when streamer mode toggles.
HUDController.VisibilityChanged = Signal.new()

local player = Players.LocalPlayer

-------------------------------------------------------------------------------------------------------------------------
-- Tuning / layout (1280x720 design canvas; Kit.screen scales it)
-------------------------------------------------------------------------------------------------------------------------

local MAX_STARS = PoliceConfig.MAX_STARS or 5
local THEFT_TOTAL = Economy.THEFT_TIME_LIMIT or 150
local THEFT_URGENT = 20 -- seconds left when the delivery timer turns red and pulses
local THEFT_BOTTOM = 184 -- theft timer bottom offset: clears the driving speedometer (bottom-center, 168 tall)
local HOME_COOLDOWN = 20 -- matches PlotService GoHome cooldown (display only; the server decides)
local HOME_CONFIRM_WINDOW = 2.5 -- seconds after GoHome during which arriving home starts the local cooldown
local MENU_TOP = 72 -- menu column starts below the top-left button row (recomputed per input type in layout())
local MENU_CELL = 62
local MENU_CELL_TOUCH = 76
local TOP_ROW_CELL_TOUCH = 62
local MENU_PAD = 6
local TOP_ROW_CELL = 52
local HOTBAR_REAL_PX = 74 -- default backpack hotbar height in real pixels (+ margin)
local TOUCH_THUMB_REAL_PX = 120 -- keep the left column above the touch thumbstick's resting area (real pixels)
local TICK = 0.1
local BUSTED_HOLD = 3

local PURPLE = Color3.fromRGB(160, 90, 255)
local REBIRTH_COLOR = Color3.fromRGB(120, 70, 255)
local STAR_EMPTY = Color3.fromRGB(58, 62, 104)
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

export type MenuDef = { id: string, icon: string, caption: string, color: Color3, names: { string } }

-- Left column, top to bottom. `names` = MenuController window names to try, in order.
HUDController.MENU = {
	{ id = "Store", icon = "🛒", caption = "STORE", color = Theme.Colors.Gold, names = { "Store" } },
	{
		id = "GearShop",
		icon = "🔧",
		caption = "GEAR",
		color = Theme.Colors.Secondary,
		names = { "GearShop", "Gear" },
	},
	{ id = "Index", icon = "📖", caption = "INDEX", color = PURPLE, names = { "Index", "CarIndex" } },
	{ id = "Daily", icon = "🎁", caption = "DAILY", color = Theme.Colors.Primary, names = { "Daily" } },
	{
		id = "Contracts",
		icon = "🎯",
		caption = "JOBS", -- short caption stays legible on phones; opens the Contracts menu
		color = Theme.Colors.Warning,
		names = { "Contracts" },
	},
	{
		id = "Playtime",
		icon = "⏰",
		caption = "GIFTS",
		color = Theme.Colors.Cash,
		names = { "Playtime", "Gifts", "PlaytimeGifts" },
	},
	{ id = "Rebirth", icon = "♻️", caption = "REBIRTH", color = REBIRTH_COLOR, names = { "Rebirth" } },
} :: { MenuDef }

-- Small top-left row.
HUDController.MENU_TOP_ROW = {
	{ id = "Codes", icon = "🎟️", caption = "CODES", color = Theme.Colors.PanelLight, names = { "Codes" } },
	{
		id = "Settings",
		icon = "⚙️",
		caption = "SETTINGS",
		color = Theme.Colors.PanelLight,
		names = { "Settings" },
	},
} :: { MenuDef }

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

-- Any value -> integer star count in 0..max.
function HUDController.clampStars(v: any, maxStars: number?): number
	local max = maxStars or MAX_STARS
	if typeof(v) ~= "number" or v ~= v then
		return 0
	end
	return math.clamp(math.floor(v + 0.5), 0, max)
end

export type StarState = { filled: boolean, changed: boolean, gained: boolean }

-- Per-star view state. `previous` nil = first render (nothing "changed").
function HUDController.starStates(stars: any, previous: any, maxStars: number?): { StarState }
	local max = maxStars or MAX_STARS
	local now = HUDController.clampStars(stars, max)
	local before = if previous == nil then now else HUDController.clampStars(previous, max)
	local out: { StarState } = {}
	for i = 1, max do
		local filled = i <= now
		local was = i <= before
		out[i] = { filled = filled, changed = filled ~= was, gained = filled and not was }
	end
	return out
end

export type Trend = "up" | "down" | "none"

function HUDController.cashTrend(new: number, old: number?): Trend
	if old == nil or new ~= new or old ~= old then
		return "none"
	end
	if new > old + 0.5 then
		return "up"
	elseif new < old - 0.5 then
		return "down"
	end
	return "none"
end

-- Delivery timer view: (clock text, fraction of time left 0..1, urgent).
function HUDController.theftView(endsAt: number?, now: number, total: number?): (string, number, boolean)
	if typeof(endsAt) ~= "number" or endsAt ~= endsAt then
		return "--:--", 1, false
	end
	local t = if total and total > 0 then total else THEFT_TOTAL
	local left = math.max(0, endsAt - now)
	return Format.clock(math.ceil(left)), math.clamp(left / t, 0, 1), left <= THEFT_URGENT
end

-- True when any playtime gift has been earned (sessionSeconds + extra) and not claimed yet.
function HUDController.playtimeClaimable(playtime: any, extraSeconds: number?): boolean
	if typeof(playtime) ~= "table" then
		return false
	end
	local base = if typeof(playtime.sessionSeconds) == "number" then playtime.sessionSeconds else 0
	local secs = base + math.max(0, extraSeconds or 0)
	local claimed: any = if typeof(playtime.claimed) == "table" then playtime.claimed else {}
	for i, reward in Economy.PLAYTIME_REWARDS do
		if secs >= reward.minutes * 60 and not (claimed[tostring(i)] or claimed[i]) then
			return true
		end
	end
	return false
end

function HUDController.rebirthReady(cash: number, rebirths: number): boolean
	if typeof(cash) ~= "number" or typeof(rebirths) ~= "number" then
		return false
	end
	local ok, cost = pcall(EconomyMath.rebirthCost, rebirths)
	return ok and typeof(cost) == "number" and cash >= cost
end

-- True when the player can afford any next upgrade level or any unowned paid tool.
function HUDController.gearAffordable(snapshot: any, cash: number): boolean
	if typeof(snapshot) ~= "table" or typeof(cash) ~= "number" then
		return false
	end
	local upgrades: any = if typeof(snapshot.upgrades) == "table" then snapshot.upgrades else {}
	for id, def in Economy.Upgrades do
		local level = if typeof(upgrades[id]) == "number" then upgrades[id] else 0
		if level < def.maxLevel then
			local price = EconomyMath.upgradePrice(id, level)
			if price and cash >= price then
				return true
			end
		end
	end
	local tools: any = if typeof(snapshot.tools) == "table" then snapshot.tools else {}
	for id, def in Economy.Tools do
		if def.price > 0 and not tools[id] and cash >= def.price then
			return true
		end
	end
	return false
end

export type HomeCtx = {
	hidden: boolean, -- streamer mode
	focus: boolean, -- tutorial focus mode
	driving: boolean,
	inOwnGarage: boolean,
	hasPlot: boolean,
	wanted: number,
	cooldownLeft: number,
}
export type HomeState = "hidden" | "wanted" | "cooldown" | "ready"

function HUDController.homeState(ctx: HomeCtx): HomeState
	if ctx.hidden or ctx.focus or ctx.driving or ctx.inOwnGarage or not ctx.hasPlot then
		return "hidden"
	end
	if ctx.wanted > 0 then
		return "wanted"
	end
	if ctx.cooldownLeft > 0 then
		return "cooldown"
	end
	return "ready"
end

-- How many columns/rows a vertical-first grid of `count` cells needs to fit `available` height.
function HUDController.gridFit(count: number, available: number, cell: number, pad: number): (number, number)
	if count <= 0 then
		return 0, 0
	end
	local rows = math.max(1, math.floor((available + pad) / (cell + pad)))
	rows = math.min(rows, count)
	return math.ceil(count / rows), rows
end

function HUDController.countGarage(snapshot: any): number
	if typeof(snapshot) ~= "table" or typeof(snapshot.garage) ~= "table" then
		return 0
	end
	local n = 0
	for _ in snapshot.garage do
		n += 1
	end
	return n
end

function HUDController.countDiscovered(snapshot: any): number
	if typeof(snapshot) ~= "table" or typeof(snapshot.discovered) ~= "table" then
		return 0
	end
	local n = 0
	for _, v in snapshot.discovered do
		if v then
			n += 1
		end
	end
	return n
end

-- MenuController window names to try for a HUD button id.
function HUDController.menuNameCandidates(id: string): { string }
	for _, list in { HUDController.MENU, HUDController.MENU_TOP_ROW } do
		for _, def in list do
			if def.id == id then
				return def.names
			end
		end
	end
	return { id }
end

-------------------------------------------------------------------------------------------------------------------------
-- Lazy dependencies (written in parallel; may be missing or fail to load)
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

local function toast(kind: string, text: string)
	local nc = lazy("NotificationController")
	if nc and typeof(nc.toast) == "function" then
		pcall(nc.toast, kind, text)
	end
end

local function tween(inst: Instance, info: TweenInfo, props: { [string]: any }): Tween
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

-------------------------------------------------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------------------------------------------------

type MenuButton = {
	def: MenuDef,
	button: TextButton,
	badge: Frame,
	badgePulse: Tween?,
	badgeOn: boolean,
}

type HudUI = {
	gui: ScreenGui,
	scale: UIScale?,
	root: Frame,
	cashHolder: Frame,
	cashPill: Frame,
	cashStroke: UIStroke?,
	cashIcon: Frame,
	cashAmount: TextLabel,
	cashFlash: Frame,
	incomeTab: Frame,
	incomeLabel: TextLabel,
	multChip: TextLabel,
	vipCrown: TextLabel,
	wanted: Frame,
	wantedStroke: UIStroke?,
	siren: TextLabel,
	stars: { TextLabel },
	bust: Frame,
	bustSet: (number, boolean?) -> (),
	bustLabel: TextLabel,
	menu: Frame,
	grid: UIGridLayout,
	topRow: Frame,
	buttons: { [string]: MenuButton },
	home: TextButton,
	theft: Frame,
	theftTimer: TextLabel,
	theftTitle: TextLabel,
	theftSet: (number, boolean?) -> (),
	toggleGui: ScreenGui,
	toggleButton: TextButton,
	overlay: ScreenGui,
}

local ui: HudUI? = nil
local started = false
local hidden = false
local focusMode = false
local lastCash: number? = nil
local lastStars: number? = nil
local snapshotAt = 0
local indexSeen: number? = nil
local homeState: HomeState = "hidden"
local homeCooldownUntil = 0
local homePendingAt = -math.huge
local lastHomePress = -math.huge
local theftActive = false
local theftEndsAt: number? = nil
local theftLastSecond = -1
local bustShown = false
local inOwnGarage = false
local bustedToken = 0
local shakeToken = 0
local hiddenOverrideUntil = 0 -- after a local 👁️ tap, ignore stale snapshots that still say hideHud=true

-------------------------------------------------------------------------------------------------------------------------
-- Reading state
-------------------------------------------------------------------------------------------------------------------------

local function attrNumber(name: string): number?
	local v = player:GetAttribute(name)
	return if typeof(v) == "number" and v == v then v else nil
end

local function currentCash(): number
	local a = attrNumber("Cash")
	if a then
		return a
	end
	local snap: any = StateController.get()
	return if snap and typeof(snap.cash) == "number" then snap.cash else 0
end

local function currentIncome(): number
	local a = attrNumber("IncomePerSec")
	if a then
		return a
	end
	local snap: any = StateController.get()
	return if snap and typeof(snap.incomePerSec) == "number" then snap.incomePerSec else 0
end

local function currentRebirths(): number
	local a = attrNumber("Rebirths")
	if a then
		return a
	end
	local snap: any = StateController.get()
	return if snap and typeof(snap.rebirths) == "number" then snap.rebirths else 0
end

local function plotIndex(): number?
	local a = attrNumber("PlotIndex")
	if a and a >= 1 then
		return a
	end
	local snap: any = StateController.get()
	return if snap and typeof(snap.plotIndex) == "number" then snap.plotIndex else nil
end

local function rootPart(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function isTouch(): boolean
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(preferred) == "EnumItem" then
		return preferred.Name == "Touch"
	end
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function hotbarVisible(): boolean
	local ok, enabled = pcall(function()
		return StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack)
	end)
	return not ok or enabled == true
end

local function uiScaleValue(): number
	local u = ui
	local s = if u and u.scale then u.scale.Scale else 1
	return if s > 0 then s else 1
end

-------------------------------------------------------------------------------------------------------------------------
-- Building blocks
-------------------------------------------------------------------------------------------------------------------------

local function roundCorners(obj: GuiObject)
	local c = obj:FindFirstChildOfClass("UICorner")
	if c then
		c.CornerRadius = UDim.new(1, 0)
	end
end

local function makeBadge(parent: GuiObject): Frame
	local badge = Kit.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(24, 24),
		BackgroundColor3 = Theme.Colors.Danger,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 5,
		Parent = parent,
	})
	Kit.corner(UDim.new(1, 0)).Parent = badge
	Kit.stroke(Theme.Colors.Stroke, 2.5).Parent = badge
	Kit.gradient(WHITE, Color3.fromRGB(200, 170, 170)).Parent = badge
	Kit.new("UIScale", { Parent = badge })
	Kit.label("!", 18, {
		Name = "Mark",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 6,
		Parent = badge,
	})
	return badge
end

local function makeMenuButton(def: MenuDef, size: number, layoutOrder: number, parent: Instance): MenuButton
	local btn = Kit.iconButton(def.icon, def.caption, def.color)
	btn.Name = def.id
	btn.Size = UDim2.fromOffset(size, size)
	btn.LayoutOrder = layoutOrder
	local icon = btn:FindFirstChild("Icon")
	if icon and icon:IsA("TextLabel") then
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.fromScale(0.5, 0.06)
		icon.Size = UDim2.fromScale(0.68, 0.6)
	end
	local cap = btn:FindFirstChild("Caption")
	if cap and cap:IsA("TextLabel") then
		cap.TextScaled = true
		cap.TextWrapped = false
		cap.Position = UDim2.new(0, 3, 1, -17)
		cap.Size = UDim2.new(1, -6, 0, 15)
		Kit.new("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 7, Parent = cap })
	end
	local badge = makeBadge(btn)
	btn.Parent = parent
	return { def = def, button = btn, badge = badge, badgePulse = nil, badgeOn = false }
end

local function setBadge(mb: MenuButton, on: boolean)
	if mb.badgeOn == on then
		return
	end
	mb.badgeOn = on
	mb.badge.Visible = on
	local scale = mb.badge:FindFirstChildOfClass("UIScale")
	if mb.badgePulse then
		mb.badgePulse:Cancel()
		mb.badgePulse = nil
	end
	if on and scale then
		scale.Scale = 0.2
		local pop = tween(scale, Theme.TweenPop, { Scale = 1 })
		pop.Completed:Once(function()
			if mb.badgeOn and mb.badgePulse == nil and scale.Parent then
				mb.badgePulse =
					tween(scale, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
						Scale = 1.22,
					})
			end
		end)
	end
end

local function wiggle(obj: GuiObject)
	local info = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	task.spawn(function()
		for _, r in { 9, -9, 6, -6, 0 } do
			if not obj.Parent then
				return
			end
			tween(obj, info, { Rotation = r })
			task.wait(0.07)
		end
	end)
end

local function shake(obj: GuiObject, base: UDim2, amplitude: number, duration: number)
	shakeToken += 1
	local token = shakeToken
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < duration do
			if token ~= shakeToken or not obj.Parent then
				return
			end
			local k = 1 - (os.clock() - t0) / duration
			obj.Position = base + UDim2.fromOffset((math.random() * 2 - 1) * amplitude * k, 0)
			task.wait(0.03)
		end
		if token == shakeToken then
			obj.Position = base
		end
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------------------------------------------------

local CASH_HOLDER_POS = UDim2.new(0.5, 0, 0, 4)

local function buildCash(root: Frame)
	local holder = Kit.new("Frame", {
		Name = "CashHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = CASH_HOLDER_POS,
		Size = UDim2.fromOffset(290, 72),
		Parent = root,
	})
	local pill = Kit.panel({
		Name = "CashPill",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 10, 0, 2),
		Size = UDim2.fromOffset(262, 54),
		BackgroundColor3 = Theme.Colors.Background,
		Parent = holder,
	})
	roundCorners(pill)
	Kit.new("UIScale", { Parent = pill })
	local stroke = pill:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = Theme.Colors.CashDark
		stroke.Thickness = 3.5
	end
	-- glossy top highlight
	local gloss = Kit.new("Frame", {
		Name = "Gloss",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(48, 5),
		Size = UDim2.new(1, -78, 0, 6),
		Parent = pill,
	})
	Kit.corner(UDim.new(1, 0)).Parent = gloss
	Kit.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.35, 0.55),
			NumberSequenceKeypoint.new(0.65, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = gloss,
	})

	local flash = Kit.new("Frame", {
		Name = "Flash",
		BackgroundColor3 = Theme.Colors.Cash,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = pill,
	})
	Kit.corner(UDim.new(1, 0)).Parent = flash

	local amount = Kit.label("$0", 38, {
		Name = "Amount",
		Position = UDim2.fromOffset(46, 0),
		Size = UDim2.new(1, -60, 1, 0),
		TextColor3 = Theme.Colors.Cash,
		TextWrapped = false,
		TextScaled = true,
		ZIndex = 4,
		Parent = pill,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 38, MinTextSize = 16, Parent = amount })
	Kit.new("UIScale", { Parent = amount })

	-- money badge overlapping the pill's left edge
	local icon = Kit.new("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(64, 64),
		BackgroundColor3 = Theme.Colors.Cash,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = pill,
	})
	Kit.corner(UDim.new(1, 0)).Parent = icon
	Kit.stroke(Theme.Colors.Stroke, 3.5).Parent = icon
	Kit.gradient(WHITE, Color3.fromRGB(150, 190, 150)).Parent = icon
	Kit.new("UIScale", { Parent = icon })
	Kit.new("TextLabel", {
		Name = "Emoji",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromScale(0.7, 0.7),
		Text = "💵",
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		ZIndex = 6,
		Parent = icon,
	})

	local crown = Kit.label("👑", 26, {
		Name = "VIP",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, -4),
		Size = UDim2.fromOffset(34, 34),
		Rotation = -22,
		Visible = false,
		ZIndex = 7,
		Parent = pill,
	})

	-- "+$X/s" tab hanging under the pill
	local tab = Kit.new("Frame", {
		Name = "Income",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 10, 0, 48),
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Colors.Stroke,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = holder,
	})
	Kit.corner(UDim.new(1, 0)).Parent = tab
	Kit.stroke(Theme.Colors.CashDark, 2.5).Parent = tab
	Kit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		Parent = tab,
	})
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		tab
	local income = Kit.label("+$0/s", 17, {
		Name = "Rate",
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		TextColor3 = Theme.Colors.Cash,
		LayoutOrder = 1,
		ZIndex = 3,
		Parent = tab,
	})
	local mult = Kit.label("⚡x1", 15, {
		Name = "Multiplier",
		Size = UDim2.fromOffset(0, 20),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		TextColor3 = Theme.Colors.Gold,
		LayoutOrder = 2,
		Visible = false,
		ZIndex = 3,
		Parent = tab,
	})

	return holder, pill, stroke, icon, amount, flash, tab, income, mult, crown
end

local function buildWanted(root: Frame)
	local panel = Kit.panel({
		Name = "Wanted",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 4),
		Size = UDim2.fromOffset(276, 54),
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.25,
		Parent = root,
	})
	roundCorners(panel)
	Kit.new("UIScale", { Parent = panel })
	local stroke = panel:FindFirstChildOfClass("UIStroke")
	local siren = Kit.label("🚨", 30, {
		Name = "Siren",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		TextTransparency = 0.6,
		Parent = panel,
	})
	Kit.new("UIScale", { Parent = siren })
	local row = Kit.new("Frame", {
		Name = "Stars",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(50, 0),
		Size = UDim2.new(1, -58, 1, 0),
		Parent = panel,
	})
	Kit.list(Enum.FillDirection.Horizontal, 0, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		row
	local stars: { TextLabel } = {}
	for i = 1, MAX_STARS do
		local s = Kit.label("★", 40, {
			Name = "Star" .. i,
			Size = UDim2.fromOffset(42, 46),
			TextColor3 = STAR_EMPTY,
			TextWrapped = false,
			LayoutOrder = i,
			Parent = row,
		})
		local sStroke = s:FindFirstChildOfClass("UIStroke")
		if sStroke then
			sStroke.Thickness = 3
		end
		Kit.new("UIScale", { Parent = s })
		stars[i] = s
	end

	-- bust bar
	local bust = Kit.new("Frame", {
		Name = "Bust",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 62),
		Size = UDim2.fromOffset(276, 26),
		Visible = false,
		Parent = root,
	})
	Kit.new("UIScale", { Parent = bust })
	local bar, setBar = Kit.progressBar(Theme.Colors.Danger, {
		Name = "Bar",
		Size = UDim2.fromScale(1, 1),
		Parent = bust,
	})
	bar.BackgroundColor3 = Theme.Colors.Police
	local bustLabel = Kit.label("🚔 GETTING BUSTED!", 17, {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		TextWrapped = false,
		ZIndex = 3,
		Parent = bust,
	})
	return panel, stroke, siren, stars, bust, setBar, bustLabel
end

local function buildMenus(root: Frame, buttons: { [string]: MenuButton }, onPress: (MenuButton) -> ())
	local menu = Kit.new("Frame", {
		Name = "Menu",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, MENU_TOP),
		Size = UDim2.fromOffset(MENU_CELL, 400),
		Parent = root,
	})
	local grid = Kit.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(MENU_CELL, MENU_CELL),
		CellPadding = UDim2.fromOffset(MENU_PAD, MENU_PAD),
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		Parent = menu,
	})
	for i, def in HUDController.MENU do
		local mb = makeMenuButton(def, MENU_CELL, i, menu)
		buttons[def.id] = mb
		mb.button.Activated:Connect(function()
			onPress(mb)
		end)
	end

	local topRow = Kit.new("Frame", {
		Name = "TopRow",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.fromOffset(TOP_ROW_CELL * 3, TOP_ROW_CELL),
		Parent = root,
	})
	Kit.list(Enum.FillDirection.Horizontal, MENU_PAD, Enum.HorizontalAlignment.Left).Parent = topRow
	for i, def in HUDController.MENU_TOP_ROW do
		local mb = makeMenuButton(def, TOP_ROW_CELL, i, topRow)
		buttons[def.id] = mb
		mb.button.Activated:Connect(function()
			onPress(mb)
		end)
	end
	return menu, grid, topRow
end

local function buildTheft(root: Frame)
	local panel = Kit.panel({
		Name = "TheftTimer",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -THEFT_BOTTOM),
		Size = UDim2.fromOffset(350, 76),
		BackgroundColor3 = Theme.Colors.Background,
		Visible = false,
		Parent = root,
	})
	Kit.new("UIScale", { Parent = panel })
	local stroke = panel:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = Theme.Colors.Primary
		stroke.Thickness = 3.5
	end
	local title = Kit.label("🚨 DELIVER IT HOME!", 22, {
		Name = "Title",
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(1, -110, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextScaled = true,
		Parent = panel,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 12, Parent = title })
	local timer = Kit.label("2:30", 32, {
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 2),
		Size = UDim2.fromOffset(92, 38),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		TextColor3 = Theme.Colors.Warning,
		Parent = panel,
	})
	Kit.new("UIScale", { Parent = timer })
	local _, setBar = Kit.progressBar(Theme.Colors.Primary, {
		Name = "Bar",
		Position = UDim2.fromOffset(14, 46),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = panel,
	})
	return panel, title, timer, setBar
end

local function buildToggle(): (ScreenGui, TextButton)
	local gui = Kit.screen("HC_HudToggle", Theme.Layers.HUD)
	local btn = Kit.button("👁️", Theme.Colors.PanelLight, {
		Name = "ShowHud",
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.fromOffset(44, 44),
		TextSize = 22,
		BackgroundTransparency = 0.35,
		Visible = false,
		Parent = gui,
	})
	return gui, btn
end

-------------------------------------------------------------------------------------------------------------------------
-- Layout (menu grid wraps on short screens; HOME clears the hotbar)
-------------------------------------------------------------------------------------------------------------------------

local function canvasHeight(): number
	local u = ui
	if not u then
		return 720
	end
	local h = u.gui.AbsoluteSize.Y
	if h < 1 then
		return 720
	end
	return h / uiScaleValue()
end

local homeHeight = 54

function HUDController.getBottomClearance(): number
	local s = uiScaleValue()
	local base = if hotbarVisible() then math.ceil(HOTBAR_REAL_PX / s) + 6 else 14
	if homeState ~= "hidden" then
		base += homeHeight + 10
	end
	return base
end

local function layout()
	local u = ui
	if not u then
		return
	end
	local s = uiScaleValue()
	local touch = isTouch()
	-- touch: bigger targets (phones run at the 0.55 UI scale floor) + keep clear of the thumbstick
	local cell = if touch then MENU_CELL_TOUCH else MENU_CELL
	local topCell = if touch then TOP_ROW_CELL_TOUCH else TOP_ROW_CELL
	local menuTop = 6 + topCell + 14
	for _, def in HUDController.MENU_TOP_ROW do
		local mb = u.buttons[def.id]
		if mb then
			mb.button.Size = UDim2.fromOffset(topCell, topCell)
		end
	end
	u.topRow.Size = UDim2.fromOffset(topCell * 3, topCell)
	u.grid.CellSize = UDim2.fromOffset(cell, cell)
	u.menu.Position = UDim2.fromOffset(12, menuTop)
	local reserve = if touch then math.ceil(TOUCH_THUMB_REAL_PX / s) else 16
	local available = canvasHeight() - menuTop - reserve
	local cols, rows = HUDController.gridFit(#HUDController.MENU, available, cell, MENU_PAD)
	u.menu.Size = UDim2.fromOffset(
		math.max(1, cols) * (cell + MENU_PAD) - MENU_PAD,
		math.max(1, rows) * (cell + MENU_PAD) - MENU_PAD
	)
	homeHeight = if touch then 64 else 54
	u.home.Size = UDim2.fromOffset(if touch then 204 else 170, homeHeight)
	u.home.TextSize = if touch then 28 else 24
	local homeBottom = if hotbarVisible() then math.ceil(HOTBAR_REAL_PX / s) + 6 else 14
	u.home.Position = UDim2.new(0.5, 0, 1, -homeBottom)
end

-------------------------------------------------------------------------------------------------------------------------
-- Cash
-------------------------------------------------------------------------------------------------------------------------

local function flashCash(color: Color3)
	local u = ui
	if not u then
		return
	end
	u.cashFlash.BackgroundColor3 = color
	u.cashFlash.BackgroundTransparency = 0.35
	tween(u.cashFlash, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	if u.cashStroke then
		u.cashStroke.Color = color
		tween(u.cashStroke, TweenInfo.new(0.6), { Color = Theme.Colors.CashDark })
	end
end

local function refreshCash(animate: boolean)
	local u = ui
	if not u then
		return
	end
	local cash = currentCash()
	local trend = HUDController.cashTrend(cash, lastCash)
	lastCash = cash
	if animate and trend ~= "none" then
		Kit.tweenNumber(u.cashAmount, cash, Format.cash, 0.5)
	else
		u.cashAmount:SetAttribute("Value", cash)
		u.cashAmount:SetAttribute("TweenToken", (u.cashAmount:GetAttribute("TweenToken") or 0) + 1)
		u.cashAmount.Text = Format.cash(cash)
	end
	if not animate or hidden then
		return
	end
	if trend == "up" then
		Kit.pop(u.cashPill, 1.1)
		Kit.pop(u.cashIcon, 1.35)
		wiggle(u.cashIcon)
		flashCash(Theme.Colors.Cash)
		u.cashAmount.TextColor3 = WHITE
		tween(u.cashAmount, TweenInfo.new(0.5), { TextColor3 = Theme.Colors.Cash })
	elseif trend == "down" then
		flashCash(Theme.Colors.Danger)
		u.cashAmount.TextColor3 = Theme.Colors.Danger
		tween(u.cashAmount, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextColor3 = Theme.Colors.Cash,
		})
		shake(u.cashHolder, CASH_HOLDER_POS, 7, 0.32)
	end
end

local function refreshIncome()
	local u = ui
	if not u then
		return
	end
	u.incomeLabel.Text = "+" .. Format.cash(currentIncome()) .. "/s"
	local snap: any = StateController.get()
	local mult = if snap and typeof(snap.multiplier) == "number" then snap.multiplier else 1
	if mult > 1.01 then
		u.multChip.Visible = true
		local rounded = math.floor(mult * 10 + 0.5) / 10
		u.multChip.Text = "⚡x" .. (if rounded % 1 == 0 then tostring(math.floor(rounded)) else tostring(rounded))
	else
		u.multChip.Visible = false
	end
	local passVip = snap ~= nil and typeof(snap.passes) == "table" and snap.passes.vip == true
	u.vipCrown.Visible = player:GetAttribute("VIP") == true or passVip
end

-------------------------------------------------------------------------------------------------------------------------
-- Wanted
-------------------------------------------------------------------------------------------------------------------------

local function refreshStars(animate: boolean)
	local u = ui
	if not u then
		return
	end
	local stars = HUDController.clampStars(player:GetAttribute("Wanted"))
	local states = HUDController.starStates(stars, lastStars)
	local prev = lastStars or stars
	lastStars = stars
	for i, st in states do
		local label = u.stars[i]
		local scale = label:FindFirstChildOfClass("UIScale")
		if st.filled then
			if animate and st.gained then
				label.TextColor3 = WHITE
				tween(label, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					TextColor3 = Theme.Colors.Gold,
				})
				if scale then
					scale.Scale = 1.9
					tween(scale, Theme.TweenPop, { Scale = 1 })
				end
			else
				label.TextColor3 = Theme.Colors.Gold
			end
			label.TextTransparency = 0
		else
			if animate and st.changed then
				tween(label, TweenInfo.new(0.35), { TextColor3 = STAR_EMPTY })
				if scale then
					scale.Scale = 0.6
					tween(scale, Theme.TweenPop, { Scale = 1 })
				end
			else
				label.TextColor3 = STAR_EMPTY
			end
			label.TextTransparency = if stars == 0 then 0.35 else 0
		end
	end
	u.wanted.BackgroundTransparency = if stars > 0 then 0.05 else 0.35
	u.siren.TextTransparency = if stars > 0 then 0 else 0.6
	if not u.siren.Visible then
		u.siren.Visible = true
	end
	if stars == 0 then
		u.siren.Rotation = 0
		if u.wantedStroke then
			u.wantedStroke.Color = Theme.Colors.Stroke
		end
	end
	if animate and stars ~= prev and not hidden then
		Kit.pop(u.wanted, if stars > prev then 1.15 else 1.06)
		playSound(if stars > prev then "Whoosh" else "ClickBright")
	end
end

local function refreshBust()
	local u = ui
	if not u then
		return
	end
	local p = attrNumber("BustProgress") or 0
	local show = p > 0.001
	if show ~= bustShown then
		bustShown = show
		u.bust.Visible = show
		if show then
			Kit.pop(u.bust, 1.3)
			playSound("Notify")
		end
	end
	if show then
		u.bustSet(p, true)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Menus + badges
-------------------------------------------------------------------------------------------------------------------------

local function openMenu(mb: MenuButton)
	Kit.pop(mb.button, 1.12)
	playSound("Click")
	if mb.def.id == "Index" then
		indexSeen = HUDController.countDiscovered(StateController.get())
	end
	local menu = lazy("MenuController")
	if not menu then
		toast("info", mb.def.icon .. " Coming soon!")
		return
	end
	local names = mb.def.names
	-- Prefer a name MenuController says it knows, when it can tell us.
	if typeof(menu.has) == "function" then
		for _, n in names do
			local ok, known = pcall(menu.has, n)
			if ok and known then
				names = { n }
				break
			end
		end
	end
	local fn = if typeof(menu.toggle) == "function" then menu.toggle else menu.open
	if typeof(fn) ~= "function" then
		return
	end
	for _, n in names do
		local ok, result = pcall(fn, n)
		if ok and result ~= false then
			return
		end
	end
end

local function refreshBadges()
	local u = ui
	if not u then
		return
	end
	local snap: any = StateController.get()
	if not snap then
		return
	end
	local cash = currentCash()
	local b = u.buttons
	if b.Daily then
		setBadge(b.Daily, typeof(snap.daily) == "table" and snap.daily.canClaim == true)
	end
	if b.Playtime then
		setBadge(b.Playtime, HUDController.playtimeClaimable(snap.playtime, os.clock() - snapshotAt))
	end
	if b.Rebirth then
		setBadge(b.Rebirth, HUDController.rebirthReady(cash, currentRebirths()))
	end
	if b.GearShop then
		setBadge(b.GearShop, HUDController.gearAffordable(snap, cash))
	end
	if b.Index then
		local count = HUDController.countDiscovered(snap)
		if indexSeen == nil then
			indexSeen = count
		end
		setBadge(b.Index, count > (indexSeen :: number))
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- HOME button
-------------------------------------------------------------------------------------------------------------------------

local function refreshHome()
	local u = ui
	if not u then
		return
	end
	local root = rootPart()
	local idx = plotIndex()
	inOwnGarage = root ~= nil and idx ~= nil and MapLayout.plotAt(root.Position) == idx
	local now = os.clock()
	if inOwnGarage and now - homePendingAt < HOME_CONFIRM_WINDOW then
		homeCooldownUntil = now + HOME_COOLDOWN
		homePendingAt = -math.huge
	end
	local state = HUDController.homeState({
		hidden = hidden,
		focus = focusMode,
		driving = player:GetAttribute("Driving") == true,
		inOwnGarage = inOwnGarage,
		hasPlot = idx ~= nil,
		wanted = HUDController.clampStars(player:GetAttribute("Wanted")),
		cooldownLeft = math.max(0, homeCooldownUntil - now),
	})
	local btn = u.home
	if state ~= homeState then
		local wasHidden = homeState == "hidden"
		homeState = state
		btn.Visible = state ~= "hidden"
		if wasHidden and state ~= "hidden" then
			Kit.pop(btn, 0.4)
		end
	end
	if state == "ready" then
		btn.Text = "🏠 HOME"
		btn.BackgroundColor3 = Theme.Colors.Secondary
	elseif state == "wanted" then
		btn.Text = "🚨 HOME"
		btn.BackgroundColor3 = Theme.Colors.Disabled
	elseif state == "cooldown" then
		btn.Text = "🏠 " .. Format.clock(math.ceil(homeCooldownUntil - now))
		btn.BackgroundColor3 = Theme.Colors.Disabled
	end
end

local function pressHome()
	local u = ui
	if not u then
		return
	end
	local now = os.clock()
	if now - lastHomePress < 0.8 then
		return
	end
	lastHomePress = now
	if homeState == "ready" then
		Kit.pop(u.home, 1.15)
		playSound("Whoosh")
		homePendingAt = now
		Net.fire("GoHome")
	elseif homeState == "wanted" then
		wiggle(u.home)
		playSound("Click")
		toast("warning", "🚨 Lose the cops first!")
	elseif homeState == "cooldown" then
		wiggle(u.home)
		playSound("Click")
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Theft timer
-------------------------------------------------------------------------------------------------------------------------

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and typeof(t) == "number" then t else os.time()
end

local function applyTheft(state: any)
	local u = ui
	if not u then
		return
	end
	local active = typeof(state) == "table" and state.active == true
	theftEndsAt = if active and typeof(state.endsAt) == "number" then state.endsAt else nil
	if active ~= theftActive then
		theftActive = active
		theftLastSecond = -1
		if active then
			u.theft.Visible = not hidden
			u.theft.Position = UDim2.new(0.5, 0, 1, -THEFT_BOTTOM + 60)
			tween(u.theft, Theme.TweenPop, { Position = UDim2.new(0.5, 0, 1, -THEFT_BOTTOM) })
			Kit.pop(u.theft, 0.6)
		else
			u.theft.Visible = false
		end
	end
end

local function refreshTheft()
	local u = ui
	if not u or not theftActive then
		return
	end
	u.theft.Visible = not hidden
	local text, fraction, urgent = HUDController.theftView(theftEndsAt, serverNow(), THEFT_TOTAL)
	u.theftTimer.Text = text
	u.theftSet(fraction, false)
	u.theftTimer.TextColor3 = if urgent then Theme.Colors.Danger else Theme.Colors.Warning
	local secs = if theftEndsAt then math.ceil(math.max(0, theftEndsAt - serverNow())) else -1
	if urgent and secs ~= theftLastSecond and secs >= 0 then
		Kit.pop(u.theftTimer, 1.3)
		if secs <= 10 then
			playSound("Click")
		end
	end
	theftLastSecond = secs
end

-------------------------------------------------------------------------------------------------------------------------
-- Visibility (streamer mode + tutorial focus)
-------------------------------------------------------------------------------------------------------------------------

local function applyFocus(animate: boolean)
	local u = ui
	if not u then
		return
	end
	local show = not focusMode
	if show then
		if not u.menu.Visible or not u.topRow.Visible then
			u.menu.Visible = true
			u.topRow.Visible = true
			if animate then
				local i = 0
				for _, list in { HUDController.MENU_TOP_ROW, HUDController.MENU } do
					for _, def in list do
						local mb = u.buttons[def.id]
						if mb then
							i += 1
							local delay = i * 0.06
							local scale = mb.button:FindFirstChildOfClass("UIScale")
							if scale then
								scale.Scale = 0
								task.delay(delay, function()
									if scale.Parent then
										tween(scale, Theme.TweenPop, { Scale = 1 })
									end
								end)
							end
						end
					end
				end
				task.delay(0.2, playSound, "Pickup")
			end
		end
	else
		u.menu.Visible = false
		u.topRow.Visible = false
	end
end

local function setHidden(value: boolean)
	if value == hidden and ui then
		return
	end
	hidden = value
	local u = ui
	if u then
		u.gui.Enabled = not hidden
		u.toggleButton.Visible = hidden
		if hidden then
			Kit.pop(u.toggleButton, 0.5)
		else
			refreshCash(false)
			refreshStars(false)
		end
	end
	HUDController.VisibilityChanged:Fire(hidden)
end

local function readHidden(snap: any): boolean
	return typeof(snap) == "table" and typeof(snap.settings) == "table" and snap.settings.hideHud == true
end

-------------------------------------------------------------------------------------------------------------------------
-- BUSTED overlay
-------------------------------------------------------------------------------------------------------------------------

function HUDController.showBusted(lostCash: number)
	local u = ui
	if not u then
		return
	end
	bustedToken += 1
	local token = bustedToken
	local old = u.overlay:FindFirstChild("Busted")
	if old then
		old:Destroy()
	end
	local lost = if typeof(lostCash) == "number" and lostCash == lostCash then math.max(0, lostCash) else 0

	local root = Kit.new("Frame", {
		Name = "Busted",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = u.overlay,
	}) :: Frame
	local dim = Kit.new("Frame", {
		Name = "Dim",
		BackgroundColor3 = BLACK,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})
	-- police lights from both screen edges
	local function edge(color: Color3, left: boolean): Frame
		local f = Kit.new("Frame", {
			Name = if left then "RedLight" else "BlueLight",
			BackgroundColor3 = color,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(if left then 0 else 0.55, 0),
			Size = UDim2.fromScale(0.45, 1),
			Parent = root,
		})
		Kit.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, if left then 0.25 else 1),
				NumberSequenceKeypoint.new(1, if left then 1 else 0.25),
			}),
			Parent = f,
		})
		return f
	end
	local red = edge(Theme.Colors.Danger, true)
	local blue = edge(Theme.Colors.Police, false)
	red.BackgroundTransparency = 1
	blue.BackgroundTransparency = 1

	local stamp = Kit.new("CanvasGroup", {
		Name = "Stamp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(600, 300),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Rotation = -8,
		Parent = root,
	}) :: CanvasGroup
	local stampScale = Kit.new("UIScale", { Scale = 3, Parent = stamp })
	local plate = Kit.new("Frame", {
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(540, 170),
		BackgroundColor3 = Color3.fromRGB(255, 244, 228),
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Parent = stamp,
	})
	Kit.corner(UDim.new(0, 22)).Parent = plate
	Kit.stroke(Theme.Colors.Danger, 9).Parent = plate
	Kit.new("Frame", {
		Name = "InnerLine",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -26, 1, -26),
		BackgroundTransparency = 1,
		Parent = plate,
	}, {
		Kit.corner(UDim.new(0, 14)),
		Kit.stroke(Theme.Colors.Danger, 3),
	})
	local title = Kit.label("BUSTED!", 118, {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -30, 1, -20),
		TextColor3 = Theme.Colors.Danger,
		TextWrapped = false,
		TextScaled = true,
		Parent = plate,
	})
	local tStroke = title:FindFirstChildOfClass("UIStroke")
	if tStroke then
		tStroke.Thickness = 6
	end
	for _, spec in { { x = 0, r = -18 }, { x = 1, r = 18 } } do
		Kit.label("🚨", 54, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(spec.x, 0, 0, 4),
			Size = UDim2.fromOffset(70, 70),
			Rotation = spec.r,
			ZIndex = 3,
			Parent = plate,
		})
	end

	local lostLabel = Kit.label(if lost > 0 then "-" .. Format.cash(lost) else "NO CASH LOST", 44, {
		Name = "Lost",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.42, 96),
		Size = UDim2.fromOffset(520, 52),
		TextColor3 = if lost > 0 then Theme.Colors.Danger else Theme.Colors.Cash,
		TextWrapped = false,
		Visible = false,
		Parent = root,
	})
	Kit.new("UIScale", { Parent = lostLabel })
	local sub = Kit.label("🚔 Car impounded • released at Police HQ", 22, {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.42, 150),
		Size = UDim2.fromOffset(620, 30),
		TextColor3 = Theme.Colors.TextDim,
		TextWrapped = false,
		Visible = false,
		Parent = root,
	})
	local flash = Kit.new("Frame", {
		Name = "Flash",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Parent = root,
	})

	-- 1) anticipation: dim + sirens  2) slam  3) flash + shake  4) details  5) fade out
	tween(dim, TweenInfo.new(0.25), { BackgroundTransparency = 0.45 })
	task.spawn(function()
		local i = 0
		while token == bustedToken and root.Parent and i < 16 do
			i += 1
			local redOn = i % 2 == 1
			red.BackgroundTransparency = if redOn then 0.15 else 0.75
			blue.BackgroundTransparency = if redOn then 0.75 else 0.15
			task.wait(0.17)
		end
		if root.Parent then
			tween(red, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
			tween(blue, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
		end
	end)
	tween(stamp, TweenInfo.new(0.12), { GroupTransparency = 0 })
	local slam = tween(stampScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 1 })
	slam.Completed:Once(function()
		if token ~= bustedToken or not root.Parent then
			return
		end
		playSound("MetalHit")
		flash.BackgroundTransparency = 0.25
		tween(
			flash,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		stampScale.Scale = 0.9
		tween(stampScale, Theme.TweenPop, { Scale = 1 })
		local base = stamp.Position
		task.spawn(function()
			for k = 1, 8 do
				if not stamp.Parent then
					return
				end
				local amp = 14 * (1 - k / 9)
				stamp.Position = base + UDim2.fromOffset((math.random() * 2 - 1) * amp, (math.random() * 2 - 1) * amp)
				task.wait(0.025)
			end
			if stamp.Parent then
				stamp.Position = base
			end
		end)
		task.delay(0.3, function()
			if token ~= bustedToken or not root.Parent then
				return
			end
			lostLabel.Visible = true
			sub.Visible = true
			Kit.pop(lostLabel, 1.6)
			if lost > 0 then
				playSound("CashDrop")
			end
		end)
	end)

	task.delay(BUSTED_HOLD, function()
		if token ~= bustedToken or not root.Parent then
			return
		end
		local out = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(stamp, out, { GroupTransparency = 1 })
		tween(stampScale, out, { Scale = 1.25 })
		tween(dim, out, { BackgroundTransparency = 1 })
		for _, lbl in { lostLabel, sub } do
			tween(lbl, out, { TextTransparency = 1 })
			local s = lbl:FindFirstChildOfClass("UIStroke")
			if s then
				tween(s, out, { Transparency = 1 })
			end
		end
		task.delay(0.5, function()
			if root.Parent then
				root:Destroy()
			end
		end)
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

function HUDController.getCashAnchor(): GuiObject?
	local u = ui
	if not u or hidden or not u.gui.Enabled then
		return nil
	end
	return u.cashPill
end

function HUDController.getMenuButton(id: string): GuiButton?
	local u = ui
	if not u then
		return nil
	end
	local mb = u.buttons[id]
	return if mb then mb.button else nil
end

function HUDController.isHidden(): boolean
	return hidden
end

function HUDController.setFocusMode(on: boolean)
	local value = on == true
	if value == focusMode then
		return
	end
	focusMode = value
	applyFocus(true)
	refreshHome()
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local function build()
	local gui = Kit.screen("HC_HUD", Theme.Layers.HUD)
	local scale = gui:FindFirstChildOfClass("UIScale")
	local root = Kit.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local cashHolder, cashPill, cashStroke, cashIcon, cashAmount, cashFlash, incomeTab, incomeLabel, multChip, crown =
		buildCash(root)
	local wanted, wantedStroke, siren, stars, bust, bustSet, bustLabel = buildWanted(root)
	local buttons: { [string]: MenuButton } = {}
	local menu, grid, topRow = buildMenus(root, buttons, openMenu)
	local home = Kit.button("🏠 HOME", Theme.Colors.Secondary, {
		Name = "Home",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(170, 54),
		TextSize = 24,
		Visible = false,
		Parent = root,
	})
	home.Activated:Connect(pressHome)
	local theft, theftTitle, theftTimer, theftSet = buildTheft(root)
	local toggleGui, toggleButton = buildToggle()
	toggleButton.Activated:Connect(function()
		playSound("Click")
		hiddenOverrideUntil = os.clock() + 2
		setHidden(false)
		Net.fire("SetSetting", "hideHud", false)
	end)
	local overlay = Kit.screen("HC_Busted", Theme.Layers.Overlay)
	overlay.IgnoreGuiInset = true

	ui = {
		gui = gui,
		scale = scale,
		root = root,
		cashHolder = cashHolder,
		cashPill = cashPill,
		cashStroke = cashStroke,
		cashIcon = cashIcon,
		cashAmount = cashAmount,
		cashFlash = cashFlash,
		incomeTab = incomeTab,
		incomeLabel = incomeLabel,
		multChip = multChip,
		vipCrown = crown,
		wanted = wanted,
		wantedStroke = wantedStroke,
		siren = siren,
		stars = stars,
		bust = bust,
		bustSet = bustSet,
		bustLabel = bustLabel,
		menu = menu,
		grid = grid,
		topRow = topRow,
		buttons = buttons,
		home = home,
		theft = theft,
		theftTimer = theftTimer,
		theftTitle = theftTitle,
		theftSet = theftSet,
		toggleGui = toggleGui,
		toggleButton = toggleButton,
		overlay = overlay,
	}

	layout()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	if scale then
		scale:GetPropertyChangedSignal("Scale"):Connect(layout)
	end
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(function()
			layout()
		end)
	end)
end

-- Per-frame cosmetics (Heartbeat): police lights, siren wiggle, bust label flash. Property writes only, no allocs.
local function animateTick(now: number)
	local u = ui
	if not u or hidden then
		return
	end
	local stars = lastStars or 0
	if stars > 0 then
		local phase = math.floor(now * 5) % 2 == 0
		if u.wantedStroke then
			u.wantedStroke.Color = if phase then Theme.Colors.Danger else Theme.Colors.Police
		end
		u.siren.Rotation = math.sin(now * 14) * 12
	end
	if bustShown then
		local on = math.floor(now * 6) % 2 == 0
		u.bustLabel.TextColor3 = if on then WHITE else Theme.Colors.Warning
	end
end

function HUDController.init() end

function HUDController.start()
	if started then
		return
	end
	started = true
	build()

	-- attribute-driven pieces (cheap, server-set)
	player:GetAttributeChangedSignal("Cash"):Connect(function()
		refreshCash(true)
		refreshBadges()
	end)
	player:GetAttributeChangedSignal("IncomePerSec"):Connect(refreshIncome)
	player:GetAttributeChangedSignal("VIP"):Connect(refreshIncome)
	player:GetAttributeChangedSignal("Wanted"):Connect(function()
		refreshStars(true)
		refreshHome()
	end)
	player:GetAttributeChangedSignal("BustProgress"):Connect(refreshBust)
	player:GetAttributeChangedSignal("Driving"):Connect(refreshHome)
	player:GetAttributeChangedSignal("Rebirths"):Connect(refreshBadges)

	-- snapshot-driven pieces
	local function onSnapshot(snap: any, previous: any)
		snapshotAt = os.clock()
		local wantHidden = readHidden(snap)
		if (wantHidden ~= hidden or previous == nil) and not (wantHidden and os.clock() < hiddenOverrideUntil) then
			setHidden(wantHidden)
		end
		if attrNumber("Cash") == nil then
			refreshCash(previous ~= nil)
		end
		refreshIncome()
		refreshBadges()
	end
	StateController.Changed:Connect(onSnapshot)
	local snap = StateController.get()
	if snap then
		onSnapshot(snap, nil)
	end

	StateController.TheftChanged:Connect(function(state: any)
		applyTheft(state)
	end)
	applyTheft(StateController.getTheft())

	-- first paint
	refreshCash(false)
	refreshIncome()
	refreshStars(false)
	refreshBust()
	refreshHome()
	applyFocus(false)

	task.spawn(function()
		local ok, err = pcall(Net.listen, "Busted", function(lost: any)
			HUDController.showBusted(if typeof(lost) == "number" then lost else 0)
		end)
		if not ok then
			warn("[HUDController] could not listen to Busted: " .. tostring(err))
		end
	end)

	RunService.Heartbeat:Connect(function()
		if (lastStars or 0) > 0 or bustShown then
			animateTick(os.clock())
		end
	end)

	-- main tick: timers, HOME state, badges (1 Hz), wiggles (every 4s)
	local lastBadge = 0
	local lastWiggle = 0
	while true do
		local now = os.clock()
		local ok, err = pcall(function()
			refreshHome()
			refreshTheft()
			if now - lastBadge >= 1 then
				lastBadge = now
				refreshBadges()
				refreshIncome()
			end
			if now - lastWiggle >= 4 then
				lastWiggle = now
				local u = ui
				if u and not hidden and not focusMode then
					for _, mb in u.buttons do
						if mb.badgeOn then
							wiggle(mb.button)
						end
					end
				end
			end
		end)
		if not ok then
			warn("[HUDController] tick error: " .. tostring(err))
		end
		task.wait(TICK)
	end
end

return HUDController
