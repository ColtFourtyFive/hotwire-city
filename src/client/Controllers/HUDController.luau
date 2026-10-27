--!strict
-- HUDController (SPEC §7): the always-on heads-up display.
--
--  * Cash pill (top-center): 💵 + count-up cash (Format.cash), "+$X/s" income tab (IncomePerSec attribute), ⚡ multiplier
--    chip, 👑 when VIP. Pop + green flash when cash goes up, red shake when it goes down. While the offline-earnings
--    modal is open the grant is held back (holdCash) and counts up when COLLECT is pressed (releaseCash).
--  * Wanted stars (top-center, right under the cash pill: the PC player list covers the top-right): 5 ★ that
--    pop/flash as they fill or empty, red/blue police-light pulse while a cop sees you (WantedSeen); while hidden the
--    stars blink and an "escape" bar fills toward the next star loss (WantedDecayAt). "🚔 GETTING BUSTED!" bar under
--    them while BustProgress > 0. The whole status stack only shows while wanted / being busted.
--  * Menu column (left): STORE / GEAR / INDEX / DAILY / CONTRACTS / GIFTS / REBIRTH (+ CODES / SETTINGS row)
--    -> MenuController.toggle/open (lazy). Red "!" badges: daily claimable, playtime gift ready, rebirth affordable,
--    gear upgrade affordable, new cars in the index. Desktop: starts below the default chat window (top-left) and
--    wraps into more columns on short screens. Touch: a strip above the dynamic thumbstick zone (top third of the
--    screen), hidden while driving (the thumb steers there).
--  * 🏠 HOME (bottom-center, above the backpack hotbar): Net.fire("GoHome"). Hidden while driving, inside your own
--    garage, or in tutorial focus mode; greyed with 🚨 while wanted; local cooldown display after a successful trip.
--  * Theft delivery timer (TheftState): "🚨 DELIVER IT HOME! 1:42" + draining bar; "🚨 GET BACK IN! 0:12" (red)
--    while the thief is knocked out of the car and it is about to be towed home (dropped / droppedEndsAt). Sits
--    bottom-center just above the driving speedometer (measured, so it follows DrivingUI's real size).
--  * BUSTED overlay (Busted remote): flash, police lights, comic "BUSTED!" stamp slam, lost cash, "🚗 <car>
--    IMPOUNDED" when a car was taken, fades after 3s.
--  * Streamer mode: snapshot.settings.hideHud hides all of the above; a tiny 👁️ button (top-left) turns it back on.
--  * Chat: a gold [👑 VIP] prefix on messages from VIP pass holders (TextChatService.OnIncomingMessage).
--  * Reset Character is switched off while wanted (StarterGui ResetButtonCallback): the server counts dying while
--    wanted as a bust, so the button must not look like an escape.
--
-- Public API (beyond init/start):
--   getCashAnchor(): GuiObject?           cash pill (NotificationController flies coins / popups into it)
--   getMenuButton(id): GuiButton?         e.g. "Store", "GearShop", "Daily" (TutorialController may point at them)
--   setFocusMode(on: boolean)             tutorial: hide menus + HOME, then pop them back in
--   isHidden(): boolean                   streamer mode active
--   showBusted(lostCash: number, carLabel: string?)   play the BUSTED overlay (also driven by the Busted remote)
--   getBottomClearance(): number          design px reserved at bottom-center (hotbar + HOME, the driving
--                                         speedometer, the theft timer — whichever reaches highest)
--   getTopStackBottom(): number           real px (inset-relative) where the top-center HUD stack ends
--   getFeedAnchor(): Vector2?             real px top-left for NotificationController's event feed (beside the menu)
--   getMenuBottom(): number               real px bottom of the top-left buttons (wide overlays go below on phones)
--   holdCash(amount) / releaseCash()      offline modal: show cash without `amount` until COLLECT, then count up
--   setMinimapReserve(touchLeft, desktopBottom)   MinimapController: design px the radar takes (touch: top-left
--                                         width, the buttons move right; desktop: bottom-left height, the column wraps)
--   VisibilityChanged: Signal(hidden: boolean)
-- Pure helpers (tests): clampStars, starStates, cashTrend, theftView, theftMode, playtimeClaimable, rebirthReady,
--   gearAffordable, homeState, gridFit, touchMenuGrid, countGarage, menuNameCandidates, vipChatPrefix, resetAllowed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
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
local DROPPED_TOTAL = Economy.DROPPED_CAR_TIMEOUT or 20
local THEFT_URGENT = 20 -- seconds left when the delivery timer turns red and pulses
local THEFT_BOTTOM = 184 -- theft timer bottom offset: clears the driving speedometer (bottom-center, 168 tall)
local THEFT_SPEEDO_GAP = 16 -- design px kept between the (measured) speedometer top and the theft timer
local THEFT_WIDTH, THEFT_HEIGHT = 350, 76
local THEFT_TOUCH_SCALE = 1.3 -- phones sit at the 0.55 UI scale floor: keeps the timer title >= ~14 real px
local HOME_COOLDOWN = 20 -- matches PlotService GoHome cooldown (display only; the server decides)
local HOME_CONFIRM_WINDOW = 2.5 -- seconds after GoHome during which arriving home starts the local cooldown
local MENU_TOP = 72 -- menu column starts below the top-left button row (recomputed per input type in layout())
local MENU_CELL = 62
local MENU_CELL_TOUCH = 76
local TOP_ROW_CELL_TOUCH = 62
local MENU_PAD = 6
local TOP_ROW_CELL = 52
local HOTBAR_REAL_PX = 74 -- default backpack hotbar height in real pixels (+ margin)
local CHAT_FALLBACK_BOTTOM = 250 -- desktop: design px the default chat window covers when we can't measure it
local TOP_CENTER_HALF = 168 -- design px either side of center kept free for the cash pill + status stack (touch)
local STATUS_TOP = 80 -- the wanted / busted status stack hangs right under the cash pill's income tab (ends at 76)
local STATUS_WIDTH = 262
local STATUS_PANEL_HEIGHT = 50
local STATUS_BUST_HEIGHT = 28
local STATUS_TOUCH_SCALE = 1.2
local STATUS_LINGER = 1.6 -- seconds the stars stay up after the last one empties (so the "escaped" animation reads)
local TICK = 0.1
local BUSTED_HOLD = 3
local HOLD_CASH_MAX_SECONDS = 40 -- safety: a held-back offline grant is always released after this
local VIP_CHAT_TAG = '<font color="#FFCD32">[👑 VIP]</font>'

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

-- Which deadline the theft timer shows for a (sanitized) TheftState: (dropped, endsAt, total).
-- While the thief is knocked out of the car the real deadline is the tow-home timer (droppedEndsAt), not endsAt.
function HUDController.theftMode(state: any): (boolean, number?, number)
	if typeof(state) ~= "table" or state.active ~= true then
		return false, nil, THEFT_TOTAL
	end
	local dropAt = state.droppedEndsAt
	if state.dropped == true and typeof(dropAt) == "number" and dropAt == dropAt then
		return true, dropAt, DROPPED_TOTAL
	end
	local endsAt = state.endsAt
	return false, if typeof(endsAt) == "number" and endsAt == endsAt then endsAt else nil, THEFT_TOTAL
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

-- Reset Character stays available only while not wanted (dying while wanted is a bust, chase-events-dealer F3).
function HUDController.resetAllowed(wanted: any): boolean
	return HUDController.clampStars(wanted) == 0
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
	local passes: any = if typeof(snapshot.passes) == "table" then snapshot.passes else {}
	for id, def in Economy.Tools do
		-- same ownership rule as MenuController.toolRows: the Zapper Pass owns the taser without writing tools.taser
		local owned = tools[id] or (id == "taser" and passes.taser == true)
		if def.price > 0 and not owned and cash >= def.price then
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

-- Touch menu strip: as few rows as fit `availableWidth` (left of the top-center HUD), trying each cell size in
-- `cells` (largest first) until the rows fit `availableHeight` (above the thumbstick zone). Falls back to the
-- smallest cell even when it overflows. Returns (cols, rows, cell).
function HUDController.touchMenuGrid(
	count: number,
	availableWidth: number,
	availableHeight: number,
	cells: { number },
	pad: number
): (number, number, number)
	if count <= 0 or #cells == 0 then
		return 0, 0, cells[1] or 0
	end
	local cols, rows, cell = 1, count, cells[#cells]
	for i, c in cells do
		cols = math.clamp(math.floor((availableWidth + pad) / (c + pad)), 1, count)
		rows = math.ceil(count / cols)
		cell = c
		if rows * (c + pad) - pad <= availableHeight or i == #cells then
			break
		end
	end
	return cols, rows, cell
end

-- Chat prefix for a message sender (nil = leave the message alone).
function HUDController.vipChatPrefix(isVip: boolean, prefix: string?): string?
	if not isVip then
		return nil
	end
	local p = prefix or ""
	return if p == "" then VIP_CHAT_TAG else VIP_CHAT_TAG .. " " .. p
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
	status: Frame, -- top-center holder (device scale) for the wanted panel + bust bar
	statusScale: UIScale,
	wanted: Frame,
	wantedStroke: UIStroke?,
	siren: TextLabel,
	stars: { TextLabel },
	escape: Frame,
	escapeSet: (number, boolean?) -> (),
	bust: Frame,
	bustSet: (number, boolean?) -> (),
	bustLabel: TextLabel,
	menu: Frame,
	grid: UIGridLayout,
	topRow: Frame,
	buttons: { [string]: MenuButton },
	home: TextButton,
	theftHolder: Frame, -- positioned + device-scaled wrapper (Kit.pop owns the panel's own UIScale)
	theftScale: UIScale,
	theft: Frame,
	theftStroke: UIStroke?,
	theftTimer: TextLabel,
	theftTitle: TextLabel,
	theftFill: Frame?,
	theftSet: (number, boolean?) -> (),
	toggleGui: ScreenGui,
	toggleButton: TextButton,
	overlay: ScreenGui,
}

-- Menu geometry from the last layout() (design px), for the feed anchor.
type MenuLayout = { x: number, top: number, width: number, height: number, strip: boolean }

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
local theftTotal = THEFT_TOTAL
local theftDropped = false
local theftBottom = THEFT_BOTTOM
local theftSlideUntil = 0
local theftLastSecond = -1
local bustShown = false
local statusShown = false
local statusLingerUntil = 0
local wantedSeen = true
local blinkApplied = false
local decayAt = 0
local decayStart = 0
local cashHold = 0 -- offline grant held back from the display until COLLECT
local cashHoldUntil = 0
local menuLayout: MenuLayout = { x = 12, top = MENU_TOP, width = MENU_CELL, height = 400, strip = false }
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

-- What the cash counter shows: real cash minus an offline grant held back until the modal's COLLECT.
local function displayCash(): number
	local cash = currentCash()
	if cashHold > 0 and os.clock() < cashHoldUntil then
		return math.max(0, cash - cashHold)
	end
	cashHold = 0
	return cash
end

local function isTouch(): boolean
	return Kit.isTouch()
end

local function isDriving(): boolean
	return player:GetAttribute("Driving") == true
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

-- Top-center status stack under the cash pill (the PC player list owns the top-right corner): wanted panel + bust bar
-- in a device-scaled holder. Hidden while not wanted.
local function buildWanted(root: Frame)
	local holder = Kit.new("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 10, 0, STATUS_TOP), -- lined up with the cash pill (offset +10 in its holder)
		Size = UDim2.fromOffset(STATUS_WIDTH, STATUS_PANEL_HEIGHT + 6 + STATUS_BUST_HEIGHT),
		Visible = false,
		Parent = root,
	})
	local holderScale = Kit.new("UIScale", { Name = "DeviceScale", Parent = holder })
	local panel = Kit.panel({
		Name = "Wanted",
		AnchorPoint = Vector2.new(0.5, 0), -- pops grow from the top-center
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 0, 0, STATUS_PANEL_HEIGHT),
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.05,
		Parent = holder,
	})
	roundCorners(panel)
	Kit.new("UIScale", { Parent = panel })
	local stroke = panel:FindFirstChildOfClass("UIStroke")
	local siren = Kit.label("🚨", 28, {
		Name = "Siren",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.fromOffset(38, 38),
		TextTransparency = 0.6,
		Parent = panel,
	})
	Kit.new("UIScale", { Parent = siren })
	local row = Kit.new("Frame", {
		Name = "Stars",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(44, -2),
		Size = UDim2.new(1, -50, 1, 0),
		Parent = panel,
	})
	Kit.list(Enum.FillDirection.Horizontal, 0, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		row
	local stars: { TextLabel } = {}
	for i = 1, MAX_STARS do
		local s = Kit.label("★", 38, {
			Name = "Star" .. i,
			Size = UDim2.fromOffset(41, 44),
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
	-- escape progress while no cop sees you: fills toward the next star loss (WantedDecayAt)
	local escape, escapeSet = Kit.progressBar(Theme.Colors.Secondary, {
		Name = "Escape",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 22, 1, -4),
		Size = UDim2.new(1, -66, 0, 6),
		Visible = false,
		ZIndex = 2,
		Parent = panel,
	})

	-- bust bar
	local bust = Kit.new("Frame", {
		Name = "Bust",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, STATUS_PANEL_HEIGHT + 6),
		Size = UDim2.new(1, 0, 0, STATUS_BUST_HEIGHT),
		Visible = false,
		Parent = holder,
	})
	Kit.new("UIScale", { Parent = bust })
	local bar, setBar = Kit.progressBar(Theme.Colors.Danger, {
		Name = "Bar",
		Size = UDim2.fromScale(1, 1),
		Parent = bust,
	})
	bar.BackgroundColor3 = Theme.Colors.Police
	local bustLabel = Kit.label("🚔 GETTING BUSTED!", 20, {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		TextWrapped = false,
		ZIndex = 3,
		Parent = bust,
	})
	return holder, holderScale, panel, stroke, siren, stars, escape, escapeSet, bust, setBar, bustLabel
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
	local holder = Kit.new("Frame", {
		Name = "TheftHolder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -THEFT_BOTTOM),
		Size = UDim2.fromOffset(THEFT_WIDTH, THEFT_HEIGHT),
		Visible = false,
		Parent = root,
	})
	local holderScale = Kit.new("UIScale", { Name = "DeviceScale", Parent = holder })
	local panel = Kit.panel({
		Name = "TheftTimer",
		AnchorPoint = Vector2.new(0.5, 1), -- pops grow from the bottom-center, like the holder
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Background,
		Parent = holder,
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
	local bar, setBar = Kit.progressBar(Theme.Colors.Primary, {
		Name = "Bar",
		Position = UDim2.fromOffset(14, 46),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = panel,
	})
	local fill = bar:FindFirstChild("Fill")
	return holder, holderScale, panel, stroke, title, timer, if fill and fill:IsA("Frame") then fill else nil, setBar
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

local function canvasSize(): Vector2
	local u = ui
	if not u then
		return Vector2.new(1280, 720)
	end
	local abs = u.gui.AbsoluteSize
	if abs.X < 1 or abs.Y < 1 then
		return Vector2.new(1280, 720)
	end
	local s = uiScaleValue()
	return Vector2.new(abs.X / s, abs.Y / s)
end

-- Desktop: design px down to which the default chat window (CoreGui, top-left, open by default) reaches, 0 when
-- there is none. Measured when TextChatService exposes it; AbsolutePosition is treated as inset-relative, which errs
-- toward starting our column a little lower, never under the chat.
local function chatBottom(s: number): number
	local ok, bottom = pcall(function(): number
		if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			return CHAT_FALLBACK_BOTTOM -- legacy chat: same corner, nothing to measure
		end
		local cfg = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
		if not cfg or not cfg.Enabled then
			return 0
		end
		local size = cfg.AbsoluteSize
		if size.Y < 1 then
			return CHAT_FALLBACK_BOTTOM
		end
		local real = cfg.AbsolutePosition.Y + size.Y
		local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if bar and bar.Enabled and bar.AbsoluteSize.Y >= 1 then
			real = math.max(real, bar.AbsolutePosition.Y + bar.AbsoluteSize.Y)
		end
		return math.ceil(real / s) + 8
	end)
	return if ok and typeof(bottom) == "number" then bottom else CHAT_FALLBACK_BOTTOM
end

-- Design px (HUD canvas) from the screen bottom up to the top of DrivingUI's speedometer while it is shown, else 0.
-- Measured, so the HUD stays clear whatever scale VehicleClient gives its screen.
local function drivingClearance(): number
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local dg = pg and pg:FindFirstChild("DrivingUI")
	if not (dg and dg:IsA("ScreenGui") and dg.Enabled) then
		return 0
	end
	local speedo = dg:FindFirstChild("Speedometer", true)
	if not (speedo and speedo:IsA("GuiObject") and speedo.Visible) then
		return 0
	end
	local real = dg.AbsoluteSize.Y - speedo.AbsolutePosition.Y
	return if real > 0 then math.ceil(real / uiScaleValue()) else 0
end

local homeHeight = 54

-- Design px at bottom-center taken by the hotbar + HOME (when shown) and the driving speedometer (when driving).
local function bottomReserve(): number
	local s = uiScaleValue()
	local base = if hotbarVisible() then math.ceil(HOTBAR_REAL_PX / s) + 6 else 14
	if homeState ~= "hidden" then
		base += homeHeight + 10
	end
	local speedo = drivingClearance()
	if speedo > 0 then
		base = math.max(base, speedo + 6)
	end
	return base
end

function HUDController.getBottomClearance(): number
	local base = bottomReserve()
	local u = ui
	if u and theftActive and u.theftHolder.Visible then
		base = math.max(base, theftBottom + math.ceil(THEFT_HEIGHT * u.theftScale.Scale) + 6)
	end
	return base
end

-- Real px (inset-relative, like every Kit.screen) where the top-center stack (cash pill, then the wanted / busted
-- status when shown) ends. EventsClient and the theft alert banner stack below it.
function HUDController.getTopStackBottom(): number
	local u = ui
	if not u or hidden then
		return 0
	end
	local s = uiScaleValue()
	local bottom = (CASH_HOLDER_POS.Y.Offset + 72) * s
	if statusShown then
		local scale = u.statusScale.Scale
		local h = STATUS_PANEL_HEIGHT + (if bustShown then 6 + STATUS_BUST_HEIGHT else 0)
		bottom = (STATUS_TOP + h * scale) * s
	end
	return bottom
end

-- Real px top-left for NotificationController's event feed: beside the menu column on desktop, under the strip on
-- touch. nil while hidden.
function HUDController.getFeedAnchor(): Vector2?
	local u = ui
	if not u or hidden then
		return nil
	end
	local s = uiScaleValue()
	local m = menuLayout
	if m.strip then
		local below = if u.menu.Visible then m.top + m.height + 8 else m.top
		return Vector2.new(m.x * s, below * s)
	end
	return Vector2.new((m.x + m.width + 12) * s, m.top * s)
end

-- Real px bottom of the top-left buttons (the touch menu strip when shown, else the CODES / SETTINGS row); wide
-- top-center overlays (the theft alarm banner on phones) go below it. 0 while hidden.
function HUDController.getMenuBottom(): number
	local u = ui
	if not u or hidden then
		return 0
	end
	local s = uiScaleValue()
	local m = menuLayout
	if u.menu.Visible then
		return (m.top + m.height) * s
	end
	return if u.topRow.Visible then (m.top - 14) * s else 0
end

local applyFocus: (boolean, boolean?) -> ()

-- Design px the minimap (MinimapController) claims: touch = width at the top-left (the CODES / SETTINGS row and the
-- menu strip start right of it), desktop = height at the bottom-left (the menu column wraps above it).
local minimapTouchLeft = 0
local minimapDesktopBottom = 0

local function layout()
	local u = ui
	if not u then
		return
	end
	local s = uiScaleValue()
	local touch = isTouch()
	local canvas = canvasSize()
	local topCell = if touch then TOP_ROW_CELL_TOUCH else TOP_ROW_CELL
	-- desktop: the default chat window owns the top-left corner, so our left column starts below it
	local top = if touch then 6 else math.max(6, chatBottom(s))
	for _, def in HUDController.MENU_TOP_ROW do
		local mb = u.buttons[def.id]
		if mb then
			mb.button.Size = UDim2.fromOffset(topCell, topCell)
		end
	end
	u.topRow.Size = UDim2.fromOffset(topCell * 3, topCell)
	-- touch: the minimap owns the top-left corner, so the buttons start right of it (MinimapController reserve)
	local left = 12 + (if touch then minimapTouchLeft else 0)
	u.topRow.Position = UDim2.fromOffset(left, top)
	u.toggleButton.Position = UDim2.fromOffset(12, top)
	local menuTop = top + topCell + 14
	local count = #HUDController.MENU
	local cols, rows, cell
	if touch then
		-- a strip above the dynamic thumbstick zone (left 40% of the screen from a third of its height down) and left
		-- of the top-center cash pill + status stack; bigger cells when they fit (phones sit at the 0.55 scale floor)
		cols, rows, cell = HUDController.touchMenuGrid(
			count,
			canvas.X / 2 - TOP_CENTER_HALF - left,
			canvas.Y / 3 - menuTop,
			{ MENU_CELL_TOUCH, TOP_ROW_CELL_TOUCH },
			MENU_PAD
		)
	else
		cell = MENU_CELL
		-- desktop: the minimap owns the bottom-left corner; the column wraps above it
		local availH = canvas.Y - menuTop - (if minimapDesktopBottom > 0 then minimapDesktopBottom else 16)
		cols, rows = HUDController.gridFit(count, availH, cell, MENU_PAD)
		if minimapDesktopBottom > 0 and cols > 4 then
			-- squeezed between the chat window and the radar: stay <= 4 wide, smaller cells when that fits
			local c2, r2, cell2 = HUDController.touchMenuGrid(
				count,
				4 * (MENU_CELL + MENU_PAD) - MENU_PAD,
				availH,
				{ MENU_CELL, TOP_ROW_CELL },
				MENU_PAD
			)
			if r2 * (cell2 + MENU_PAD) - MENU_PAD <= availH then
				cols, rows, cell = c2, r2, cell2
			end
		end
	end
	local width = math.max(1, cols) * (cell + MENU_PAD) - MENU_PAD
	local height = math.max(1, rows) * (cell + MENU_PAD) - MENU_PAD
	u.grid.CellSize = UDim2.fromOffset(cell, cell)
	u.menu.Position = UDim2.fromOffset(left, menuTop)
	u.menu.Size = UDim2.fromOffset(width, height)
	menuLayout = { x = left, top = menuTop, width = width, height = height, strip = touch }
	u.statusScale.Scale = if touch then STATUS_TOUCH_SCALE else 1
	u.theftScale.Scale = if touch then THEFT_TOUCH_SCALE else 1
	homeHeight = if touch then 64 else 54
	u.home.Size = UDim2.fromOffset(if touch then 204 else 170, homeHeight)
	u.home.TextSize = if touch then 28 else 24
	local homeBottom = if hotbarVisible() then math.ceil(HOTBAR_REAL_PX / s) + 6 else 14
	u.home.Position = UDim2.new(0.5, 0, 1, -homeBottom)
	applyFocus(false, true)
end

-- MinimapController: reserve the HUD corner the radar sits in (design px; 0 releases it) and re-run the layout.
function HUDController.setMinimapReserve(touchLeft: number, desktopBottom: number)
	local l = if typeof(touchLeft) == "number" and touchLeft == touchLeft then math.max(0, touchLeft) else 0
	local b = if typeof(desktopBottom) == "number" and desktopBottom == desktopBottom
		then math.max(0, desktopBottom)
		else 0
	if l == minimapTouchLeft and b == minimapDesktopBottom then
		return
	end
	minimapTouchLeft, minimapDesktopBottom = l, b
	layout()
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
	local cash = displayCash()
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
	blinkApplied = false -- the per-star transparency was just rewritten
	if stars == 0 then
		u.siren.Rotation = 0
		u.escape.Visible = false
		if u.wantedStroke then
			u.wantedStroke.Color = Theme.Colors.Stroke
		end
		if prev > 0 then
			statusLingerUntil = os.clock() + STATUS_LINGER
		end
	end
	if animate and stars ~= prev and not hidden then
		Kit.pop(u.wanted, if stars > prev then 1.15 else 1.06)
		playSound(if stars > prev then "Whoosh" else "ClickBright")
	end
end

-- The status stack (stars + bust bar) only takes room under the cash pill while it means something.
local function updateStatus()
	local u = ui
	if not u then
		return
	end
	local show = (lastStars or 0) > 0 or bustShown or os.clock() < statusLingerUntil
	if show ~= statusShown then
		statusShown = show
		u.status.Visible = show
		if show then
			Kit.pop(u.wanted, 0.5)
		end
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
		updateStatus()
	end
	if show then
		u.bustSet(p, true)
	end
end

-- WantedSeen (a cop sees you) / WantedDecayAt (server time of the next star loss while hidden).
local function refreshSeen()
	local seen = player:GetAttribute("WantedSeen")
	wantedSeen = seen ~= false -- nil (not replicated yet) counts as seen
	local at = attrNumber("WantedDecayAt") or 0
	if at ~= decayAt then
		decayAt = at
		decayStart = Workspace:GetServerTimeNow()
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

-- Delivery look vs "knocked out of the car, it gets towed home in 0:12" look.
local function styleTheft(u: HudUI, dropped: boolean)
	u.theftTitle.Text = if dropped then "🚨 GET BACK IN!" else "🚨 DELIVER IT HOME!"
	if u.theftStroke then
		u.theftStroke.Color = if dropped then Theme.Colors.Danger else Theme.Colors.Primary
	end
	if u.theftFill then
		u.theftFill.BackgroundColor3 = if dropped then Theme.Colors.Danger else Theme.Colors.Primary
	end
end

-- Bottom offset that keeps the timer above the speedometer / HOME (whichever is taller right now).
local function wantedTheftBottom(): number
	return math.max(THEFT_BOTTOM, bottomReserve() + THEFT_SPEEDO_GAP - 6)
end

local function applyTheft(state: any)
	local u = ui
	if not u then
		return
	end
	local active = typeof(state) == "table" and state.active == true
	local dropped, endsAt = HUDController.theftMode(state)
	theftEndsAt = endsAt
	if dropped ~= theftDropped then
		theftDropped = dropped
		theftLastSecond = -1
		-- the tow timer is 12-20s: measure it from now so the bar starts full
		theftTotal = if dropped then math.max(1, (endsAt or 0) - serverNow()) else THEFT_TOTAL
		styleTheft(u, dropped)
		if active and theftActive then
			Kit.pop(u.theft, if dropped then 1.25 else 1.1)
			playSound(if dropped then "Notify" else "ClickBright")
		end
	end
	if active ~= theftActive then
		theftActive = active
		theftLastSecond = -1
		if active then
			theftBottom = wantedTheftBottom()
			u.theftHolder.Visible = not hidden
			u.theftHolder.Position = UDim2.new(0.5, 0, 1, -theftBottom + 60)
			tween(u.theftHolder, Theme.TweenPop, { Position = UDim2.new(0.5, 0, 1, -theftBottom) })
			theftSlideUntil = os.clock() + 0.4 -- TweenPop is 0.35s
			Kit.pop(u.theft, 0.6)
		else
			u.theftHolder.Visible = false
		end
	end
end

local function refreshTheft()
	local u = ui
	if not u or not theftActive then
		return
	end
	u.theftHolder.Visible = not hidden
	local want = wantedTheftBottom()
	if math.abs(want - theftBottom) >= 2 and os.clock() >= theftSlideUntil then
		theftBottom = want
		tween(u.theftHolder, Theme.TweenMedium, { Position = UDim2.new(0.5, 0, 1, -theftBottom) })
	end
	local text, fraction, urgent = HUDController.theftView(theftEndsAt, serverNow(), theftTotal)
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

-- Menu / top row visibility: hidden in tutorial focus mode; on touch the menu strip also hides while driving (the
-- thumb steers over that corner). quiet = no pop-in sound (e.g. hopping out of a car).
function applyFocus(animate: boolean, quiet: boolean?)
	local u = ui
	if not u then
		return
	end
	local showTop = not focusMode
	local showMenu = showTop and not (menuLayout.strip and isDriving())
	local popList: { { MenuDef } } = {}
	if showTop and not u.topRow.Visible then
		u.topRow.Visible = true
		table.insert(popList, HUDController.MENU_TOP_ROW)
	elseif not showTop then
		u.topRow.Visible = false
	end
	if showMenu and not u.menu.Visible then
		u.menu.Visible = true
		table.insert(popList, HUDController.MENU)
	elseif not showMenu then
		u.menu.Visible = false
	end
	if animate and #popList > 0 then
		local i = 0
		for _, list in popList do
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
		if not quiet then
			task.delay(0.2, playSound, "Pickup")
		end
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

function HUDController.showBusted(lostCash: number, carLabel: string?)
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
	local car = if typeof(carLabel) == "string" and carLabel ~= "" then string.upper(carLabel) else nil

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
	-- the car is often the biggest loss: say which one was taken
	local impounded = Kit.label(if car then "🚗 " .. car .. " IMPOUNDED" else "", 30, {
		Name = "Impounded",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.42, 150),
		Size = UDim2.fromOffset(640, 36),
		TextColor3 = Theme.Colors.Warning,
		TextWrapped = false,
		TextScaled = true,
		Visible = false,
		Parent = root,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 18, Parent = impounded })
	Kit.new("UIScale", { Parent = impounded })
	local sub = Kit.label("🚔 Released at Police HQ", 22, {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.42, if car then 192 else 150),
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
			if car then
				task.delay(0.25, function()
					if token ~= bustedToken or not root.Parent then
						return
					end
					impounded.Visible = true
					Kit.pop(impounded, 1.5)
					playSound("MetalHit")
				end)
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
		for _, lbl in { lostLabel, impounded, sub } do
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

-- Offline earnings modal: the server has already credited `amount`; keep showing the pre-grant cash behind the modal so
-- COLLECT (releaseCash) gets the count-up. Released automatically after HOLD_CASH_MAX_SECONDS whatever happens.
function HUDController.holdCash(amount: number)
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	cashHold += amount
	cashHoldUntil = os.clock() + HOLD_CASH_MAX_SECONDS
	refreshCash(false)
	task.delay(HOLD_CASH_MAX_SECONDS + 0.1, function()
		if cashHold > 0 and os.clock() >= cashHoldUntil then
			cashHold = 0
			refreshCash(true)
		end
	end)
end

function HUDController.releaseCash()
	if cashHold <= 0 then
		return
	end
	cashHold = 0
	refreshCash(true)
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
	local status, statusScale, wanted, wantedStroke, siren, stars, escape, escapeSet, bust, bustSet, bustLabel =
		buildWanted(root)
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
	local theftHolder, theftScale, theft, theftStroke, theftTitle, theftTimer, theftFill, theftSet = buildTheft(root)
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
		status = status,
		statusScale = statusScale,
		wanted = wanted,
		wantedStroke = wantedStroke,
		siren = siren,
		stars = stars,
		escape = escape,
		escapeSet = escapeSet,
		bust = bust,
		bustSet = bustSet,
		bustLabel = bustLabel,
		menu = menu,
		grid = grid,
		topRow = topRow,
		buttons = buttons,
		home = home,
		theftHolder = theftHolder,
		theftScale = theftScale,
		theft = theft,
		theftStroke = theftStroke,
		theftTimer = theftTimer,
		theftTitle = theftTitle,
		theftFill = theftFill,
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
	-- desktop: the left column follows the default chat window's size
	pcall(function()
		for _, className in { "ChatWindowConfiguration", "ChatInputBarConfiguration" } do
			local cfg = TextChatService:FindFirstChildOfClass(className)
			if cfg then
				cfg:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
				cfg:GetPropertyChangedSignal("Enabled"):Connect(layout)
			end
		end
	end)
end

-- [👑 VIP] chat prefix for VIP pass holders, so the pass's "VIP tag" is visible to everyone (each client tags
-- incoming messages from senders whose replicated VIP attribute is set).
local function installVipChatTag()
	pcall(function()
		TextChatService.OnIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties?
			local source = message.TextSource
			if not source then
				return nil
			end
			local sender = Players:GetPlayerByUserId(source.UserId)
			local prefix =
				HUDController.vipChatPrefix(sender ~= nil and sender:GetAttribute("VIP") == true, message.PrefixText)
			if not prefix then
				return nil
			end
			local props = Instance.new("TextChatMessageProperties")
			props.PrefixText = prefix
			return props
		end
	end)
end

-- chase-events-dealer F3: dying while wanted is a bust on the server (penalty + Police HQ respawn), so the Reset
-- Character button is switched off while wanted instead of looking like a free escape. SetCore throws until the
-- CoreScripts register the callback: retry for a few seconds. The token cancels a retry that a newer state replaced.
local resetAllowed: boolean? = nil
local resetToken = 0
local function applyResetButton()
	local allow = HUDController.resetAllowed(player:GetAttribute("Wanted"))
	resetToken += 1
	if allow == resetAllowed then
		return
	end
	local token = resetToken
	task.spawn(function()
		for _ = 1, 20 do
			if token ~= resetToken then
				return
			end
			if pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", allow) then
				resetAllowed = allow
				return
			end
			task.wait(0.5)
		end
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
		if wantedSeen then
			-- a cop has eyes on you: police lights + wailing siren
			local phase = math.floor(now * 5) % 2 == 0
			if u.wantedStroke then
				u.wantedStroke.Color = if phase then Theme.Colors.Danger else Theme.Colors.Police
			end
			u.siren.Rotation = math.sin(now * 14) * 12
			if blinkApplied then
				blinkApplied = false
				for i, label in u.stars do
					label.TextTransparency = if i <= stars then 0 else label.TextTransparency
				end
			end
		else
			-- hidden: GTA-style blinking stars, lights off, escape bar filling toward the next star loss
			if u.wantedStroke then
				u.wantedStroke.Color = Theme.Colors.Stroke
			end
			u.siren.Rotation = 0
			local dim = if math.floor(now * 6) % 2 == 0 then 0 else 0.6
			for i = 1, math.min(stars, #u.stars) do
				u.stars[i].TextTransparency = dim
			end
			blinkApplied = true
		end
		local showEscape = not wantedSeen and decayAt > 0
		if u.escape.Visible ~= showEscape then
			u.escape.Visible = showEscape
		end
		if showEscape then
			local total = math.max(0.5, decayAt - decayStart)
			u.escapeSet(1 - math.clamp((decayAt - Workspace:GetServerTimeNow()) / total, 0, 1), false)
		end
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
		updateStatus()
		refreshHome()
		applyResetButton()
	end)
	applyResetButton()
	player:GetAttributeChangedSignal("WantedSeen"):Connect(refreshSeen)
	player:GetAttributeChangedSignal("WantedDecayAt"):Connect(refreshSeen)
	player:GetAttributeChangedSignal("BustProgress"):Connect(refreshBust)
	player:GetAttributeChangedSignal("Driving"):Connect(function()
		refreshHome()
		-- touch menu strip hides while driving; VehicleClient may toggle the backpack hotbar (HOME's clearance)
		applyFocus(true, true)
		layout()
		task.delay(0.5, layout)
	end)
	player:GetAttributeChangedSignal("Rebirths"):Connect(refreshBadges)
	installVipChatTag()

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
	refreshSeen()
	refreshStars(false)
	refreshBust()
	updateStatus()
	refreshHome()
	applyFocus(false)

	task.spawn(function()
		local ok, err = pcall(Net.listen, "Busted", function(lost: any, carLabel: any)
			HUDController.showBusted(
				if typeof(lost) == "number" then lost else 0,
				if typeof(carLabel) == "string" then carLabel else nil
			)
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
			updateStatus()
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
