--!strict
-- HUDController v2 (gta_ui_language §2.1, §5): the GTA V heads-up display. Sparse and contextual; nothing has card
-- chrome and nothing bounces. Every anchor comes from UI/HudLayout (desktop GTA V layout, touch layout of §7).
--
--  * Health | armour | ability bar (50 / 25 / 25) under the radar: HC_HUD > Root > Minimap (the radar's rect;
--    MinimapController draws the map in the same rect and reports it with setRadarRect, e.g. while expanded) > Bars.
--    That "Minimap > Bars" pair is the contract the combat package's CombatHUD looks for: it then hides its own copy,
--    so there is one set of bars (feed it through setAbility / setAmmo). Health from the Humanoid (red pulse under
--    25%), armour from the "Armor" player attribute (0..100, set by the combat package; "MaxArmor" optional), ability
--    = nitro while driving (VehicleClient), else stamina ("Stamina" attribute 0..1 when present, full otherwise).
--    Event driven (HealthChanged / attribute signals, 0.2 s tweens); per frame only the low-health pulse and the
--    nitro reading while driving.
--  * Wanted stars top-right (star sprites, no panel): white while a cop sees you, flashing white / grey while they
--    search (WantedSeen false), a 1.25 -> 1 settle on each new star, blink-and-fade when cleared. "BEING ARRESTED"
--    with a thin blue bar while BustProgress > 0.
--  * Cash top-right in Kanit with an outline, "$15,150" with commas; always on (lead decision); a separate +$700 /
--    -$5,000 delta line that holds, then the total counts up. Ammo "12  48" under it (setAmmo; combat package).
--  * Help text top-left (UI/HelpText: one at a time, key caps, colour tags); objective / subtitles bottom-centre
--    (touch: top-centre); vehicle / district / street script lines bottom-right (touch: one line top-centre); GTA
--    Online timer bars above them (the delivery timer from TheftState); the car radio station top-centre.
--  * The feed host above the radar (NotificationController renders feed cards into getFeedHost()).
--  * Touch: PHONE and MAP buttons above Roblox's jump button (measured from the TouchGui when it exists, else
--    HudLayout.jumpButton from the UIScale: it is bigger on tablets); while driving the PHONE button joins the driving
--    cluster
--    (HudLayout buttons.phoneDriving) and MAP goes. Desktop: a mini phone glyph by the radar with the unread count.
--  * Phone open (setPhoneOpen): the location lines hide; HudLayout.withPhone keeps the cash, stars and the delivery
--    timer clear of the handset. Touch feed cards stack under the help box and follow its height.
--  * Big messages: shard(kind, title, subtitle, opts) -> UI/Shard. The Busted remote plays the "busted" shard
--    (unless the combat package's DeathScreenController is present and handles it).
--  * CoreGui (§8): PlayerList (the player list lives in Pause > STATS), Health, EmotesMenu and SelfView off; the
--    Backpack hotbar goes off once a weapon wheel controller exists; the chat window moves to the left-middle in
--    Montserrat on black 45%.
--  * Hidden (VisibilityChanged): streamer mode (snapshot.settings.hideHud; on touch a small "HUD" button in its own
--    ScreenGui turns it back off), photo mode (setLocalHidden) and the pause menu (§5.12, MenuController.PauseChanged).
--  * Desktop: while a shop list menu (UI/ListMenu) holds the top-left corner, the help box moves right of it.
--  * Chat: a gold [VIP] prefix on messages from VIP pass holders. Reset Character is off while wanted.
--
-- Public API (beyond init/start):
--   getLayout(): HudLayout.Layout, LayoutChanged: Signal(layout)
--   help(text, opts?) -> id / clearHelp(id?) / currentHelp() -> id?   opts = { id, duration, urgent }
--   objective(text?) / subtitle(text, seconds?)          rich text with GTA colour tags (UI/RichText)
--   showLocation(vehicle?, district?, street?)           fades in, holds 4.5 s, fades out
--   setTimer(id, label, value, color?, order?) / clearTimer(id)   GTA Online timer bars
--   setAmmo(clip?, reserve?)                             nil hides the ammo line
--   showRadio(station?, track?)                          station name top-centre for 3 s
--   setAbility(fraction?, color?)                        override the third bar segment (nil = automatic)
--   setUnread(count)                                     mini phone badge (PhoneController)
--   shard(kind, title?, subtitle?, opts?)                big message (UI/Shard)
--   showBusted(lostCash, carLabel?)                      the busted shard + grade
--   getFeedHost(): Frame?                                where feed cards go
--   getCashAnchor(): GuiObject?, getMenuButton(id): GuiButton?, isHidden(): boolean, VisibilityChanged: Signal,
--   hiddenState(): (streamer, photo, paused)          why the HUD is hidden (VehicleClient keeps EXIT in streamer mode)
--   setRadarRect(x, y, w, h)                          MinimapController: where the radar is (the bars hang under it)
--   getBottomClearance(): number, getTopStackBottom(): number, getFeedAnchor(): Vector2?, getMenuBottom(): number
--   holdCash(amount) / releaseCash(), setFocusMode(on), setLocalHidden(on) (photo mode),
--   setMinimapReserve(...) (kept as a no-op for old callers; the layout owns the corners)
-- Pure helpers (tests): clampStars, starStates, starVisual, cashTrend, formatCash, theftView, theftMode,
--   playtimeClaimable, rebirthReady, gearAffordable, homeState, gridFit, touchMenuGrid, touchStripLayout,
--   touchFeedAnchor, countGarage, countDiscovered, menuNameCandidates, vipChatPrefix, resetAllowed, barFractions,
--   mergeDelta, starLook, showHudToggle.

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
local Signal = require(Util:WaitForChild("Signal"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local HudLayout = require(UI:WaitForChild("HudLayout"))
local HelpText = require(UI:WaitForChild("HelpText"))
local RichText = require(UI:WaitForChild("RichText"))
local Shard = require(UI:WaitForChild("Shard"))
local ListMenu = require(UI:WaitForChild("ListMenu"))
local UISound = require(UI:WaitForChild("UISound"))
local CoreGuiSetup = require(UI:WaitForChild("CoreGuiSetup"))

-- Earlier in the client ORDER: safe to require at the top.
local StateController = require(script.Parent:WaitForChild("StateController"))

local HUDController = {}

-- Fired with (hidden: boolean) when streamer mode toggles.
HUDController.VisibilityChanged = Signal.new()
-- Fired with (layout) whenever the canvas / input type changes the HUD anchors.
HUDController.LayoutChanged = Signal.new()

local player = Players.LocalPlayer
local C = Theme.Colors

-------------------------------------------------------------------------------------------------------------------------
-- Tuning
-------------------------------------------------------------------------------------------------------------------------

local MAX_STARS = PoliceConfig.MAX_STARS or 5
local THEFT_TOTAL = Economy.THEFT_TIME_LIMIT or 150
local DROPPED_TOTAL = Economy.DROPPED_CAR_TIMEOUT or 20
local THEFT_URGENT = 20 -- seconds left when the delivery timer turns red
local SEARCH_FLASH = 0.35 -- seconds per white / grey phase while the cops search (§5.3)
local DELTA_HOLD = 1.0 -- seconds the +$ line holds before the total counts up
local DELTA_MERGE = 1.0 -- gains inside this window merge into one delta
local LOCATION_HOLD = 4.5
local RADIO_HOLD = 3
local OBJECTIVE_HOLD = 7
local HOLD_CASH_MAX_SECONDS = 40 -- safety: a held-back offline grant is always released after this
local LOW_HEALTH = 0.25
local BAR_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) -- §5.2
local VIP_CHAT_TAG = '<font color="#D6B563">[VIP]</font>'

export type MenuDef = { id: string, icon: string, caption: string, color: Color3, names: { string } }

-- v1 HUD menu ids -> MenuController names. The left icon column is gone (the phone and the pause menu replace it);
-- the table stays as the id -> menu name map for menuNameCandidates / tests / Tutorial pointers. icon = a
-- Config/UIAssets apps cell.
HUDController.MENU = {
	{ id = "Store", icon = "apps.store", caption = "STORE", color = C.Gold, names = { "Store" } },
	{ id = "GearShop", icon = "hud.wrench", caption = "GEAR", color = C.Blue, names = { "GearShop", "Gear" } },
	{ id = "Index", icon = "apps.garage", caption = "GARAGE", color = C.Purple, names = { "Index", "CarIndex" } },
	{ id = "Daily", icon = "apps.daily", caption = "DAILY", color = C.Accent, names = { "Daily" } },
	{ id = "Contracts", icon = "apps.jobs", caption = "JOBS", color = C.Yellow, names = { "Contracts" } },
	{
		id = "Playtime",
		icon = "apps.gifts",
		caption = "GIFTS",
		color = C.Green,
		names = { "Playtime", "Gifts", "PlaytimeGifts" },
	},
	{ id = "Rebirth", icon = "apps.prestige", caption = "PRESTIGE", color = C.Gold, names = { "Rebirth" } },
} :: { MenuDef }

HUDController.MENU_TOP_ROW = {
	{ id = "Codes", icon = "apps.codes", caption = "CODES", color = C.MenuDark, names = { "Codes" } },
	{ id = "Settings", icon = "apps.settings", caption = "SETTINGS", color = C.MenuDark, names = { "Settings" } },
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

export type StarVisual = { sprite: string, color: Color3, transparency: number }

-- GTA V star look (§5.3) for star i of `stars` at time t: filled white while seen; filled stars alternate white /
-- grey every SEARCH_FLASH seconds while the cops search; unfilled slots are hollow at 0.3. Returns a tuple: the HUD
-- calls it for every star every frame (no table per call).
function HUDController.starLook(i: number, stars: number, seen: boolean, t: number): (string, Color3, number)
	if i > stars then
		return "hud.star_hollow", C.Text, 0.3
	end
	if not seen and math.floor(t / SEARCH_FLASH) % 2 == 1 then
		return "hud.star_fill", C.TextDim, 0
	end
	return "hud.star_fill", C.Text, 0
end

-- starLook as a table (tests, tools).
function HUDController.starVisual(i: number, stars: number, seen: boolean, t: number): StarVisual
	local sprite, color, transparency = HUDController.starLook(i, stars, seen, t)
	return { sprite = sprite, color = color, transparency = transparency }
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

-- "$15,150" (commas on the HUD, never K / M; menus keep Format.cash).
function HUDController.formatCash(n: number): string
	local v = if typeof(n) == "number" and n == n then n else 0
	return (if v < 0 then "-$" else "$") .. Format.commas(math.abs(v))
end

-- Delta line text: "+$700" / "-$5,000".
function HUDController.formatDelta(n: number): string
	local v = if typeof(n) == "number" and n == n then n else 0
	return (if v < 0 then "-$" else "+$") .. Format.commas(math.abs(v))
end

-- Merges a cash change into the pending delta when it lands within DELTA_MERGE seconds of the last one and goes the
-- same way. Returns (newDelta, merged).
function HUDController.mergeDelta(pending: number, pendingAt: number, amount: number, now: number): (number, boolean)
	if pending ~= 0 and now - pendingAt <= DELTA_MERGE and (pending > 0) == (amount > 0) then
		return pending + amount, true
	end
	return amount, false
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

local function barFrac(v: any, max: any, default: number): number
	if typeof(v) ~= "number" or v ~= v then
		return default
	end
	local m = if typeof(max) == "number" and max == max and max > 0 then max else 100
	return math.clamp(v / m, 0, 1)
end

-- Health / armour / ability fractions for the split bar (all clamped 0..1; junk -> sensible defaults).
function HUDController.barFractions(
	health: any,
	maxHealth: any,
	armor: any,
	maxArmor: any,
	ability: any
): (number, number, number)
	local a = if typeof(ability) == "number" and ability == ability then math.clamp(ability, 0, 1) else 1
	return barFrac(health, maxHealth, 1), barFrac(armor, maxArmor, 0), a
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

-- The fast trip home (v1 HOME button, now the phone's "Call a cab"): why it can't run right now.
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

-- As few rows as fit `availableWidth`, trying each cell size in `cells` (largest first) until the rows fit
-- `availableHeight`. Falls back to the smallest cell even when it overflows. Returns (cols, rows, cell).
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

export type TouchStrip = {
	left: number,
	topCell: number,
	menuTop: number,
	cols: number,
	rows: number,
	cell: number,
	bottom: number,
	fits: boolean,
}

-- v1 touch strip geometry (kept for the shared grid helpers' tests; the strip itself no longer exists).
function HUDController.touchStripLayout(
	count: number,
	canvasW: number,
	canvasH: number,
	reserveLeft: number,
	top: number
): TouchStrip
	local left = 12 + math.max(0, reserveLeft)
	local zone = canvasH / 3
	local first: TouchStrip? = nil
	for _, topCell in { 62, 52 } do
		local menuTop = top + topCell + 14
		local cols, rows, cell =
			HUDController.touchMenuGrid(count, canvasW / 2 - 168 - left, zone - menuTop, { 76, 62, 52 }, 6)
		local bottom = menuTop + math.max(1, rows) * (cell + 6) - 6
		local strip: TouchStrip = {
			left = left,
			topCell = topCell,
			menuTop = menuTop,
			cols = cols,
			rows = rows,
			cell = cell,
			bottom = bottom,
			fits = bottom <= zone + 1e-6,
		}
		if strip.fits then
			return strip
		end
		first = first or strip
	end
	return first :: TouchStrip
end

function HUDController.touchFeedAnchor(strip: TouchStrip, menuVisible: boolean, minimapBottom: number): (number, number)
	local below = if menuVisible then strip.bottom + 8 else strip.menuTop
	if minimapBottom > 0 then
		return 12, math.max(below, minimapBottom + 8)
	end
	return strip.left, below
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

-- MenuController names to try for a v1 HUD menu id.
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
-- Lazy dependencies
-------------------------------------------------------------------------------------------------------------------------

local lazyCache: { [string]: any } = {} -- sibling controllers, once required (the bars ask every frame)
local function lazy(name: string): any
	local cached = lazyCache[name]
	if cached then
		return cached
	end
	local mod = script.Parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	if ok and typeof(result) == "table" then
		lazyCache[name] = result
		return result
	end
	return nil
end

local function playSound(key: string)
	local sc = lazy("SoundController")
	if sc and typeof(sc.play) == "function" then
		pcall(sc.play, key)
	end
end

local function tween(inst: Instance, info: TweenInfo, props: { [string]: any }): Tween
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

local FADE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

-------------------------------------------------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------------------------------------------------

type TimerBar = { frame: Frame, label: TextLabel, value: TextLabel, order: number }

type HudUI = {
	gui: ScreenGui,
	scale: UIScale?,
	root: Frame,
	radarBox: Frame,
	bars: Frame,
	healthFill: Frame,
	healthTrack: Frame,
	armorFill: Frame,
	armorTrack: Frame,
	abilityFill: Frame,
	abilityTrack: Frame,
	stars: { ImageLabel },
	starRow: Frame,
	arrest: Frame,
	arrestSet: (number, boolean?) -> (),
	cash: TextLabel,
	delta: TextLabel,
	ammo: TextLabel,
	help: HelpText.View,
	feed: Frame,
	objective: TextLabel,
	location: Frame,
	locationLines: { TextLabel },
	timers: Frame,
	radio: Frame,
	radioStation: TextLabel,
	radioTrack: TextLabel,
	phoneButton: TextButton,
	mapButton: TextButton,
	miniPhone: ImageButton,
	miniBadge: TextLabel,
	toggleGui: ScreenGui,
	toggleButton: TextButton,
}

local ui: HudUI? = nil
local layoutNow: HudLayout.Layout = HudLayout.compute(1280, 720, false)
local started = false
local hidden = false
local focusMode = false
local lastStars: number? = nil
local wantedSeen = true
local starsShown = false
local clearingStars = false
local lastCash: number? = nil
local deltaAmount = 0
local deltaAt = 0
local deltaToken = 0
local cashHold = 0
local cashHoldUntil = 0
local hiddenOverrideUntil = 0
local theftActive = false
local theftEndsAt: number? = nil
local theftTotal = THEFT_TOTAL
local theftDropped = false
local bustShown = false
local abilityOverride: number? = nil
local abilityColor: Color3? = nil
local timers: { [string]: TimerBar } = {}
local objectiveText: string? = nil
local theftObjective: string? = nil -- the objective line the delivery set (cleared only if it is still the one shown)
local objectiveToken = 0
local subtitleUntil = 0
local locationToken = 0
local radioToken = 0
local unread = 0
local serverHidden = false -- streamer mode (snapshot.settings.hideHud)
local localHidden = false -- photo mode
local pauseOpen = false -- the pause menu hides the HUD (§5.12)
local phoneOpen = false
local listOpenCount = 0 -- own-screen list menus open (desktop: the help box moves right of them)
local listOpenWidth = 0
local radarRect: HudLayout.Rect? = nil -- where MinimapController drew the radar (nil: the layout's rect)
local drivingNow = false -- cached (Driving attribute / VehicleClient Entered / Exited): no per-frame lookups
local hum: Humanoid? = nil -- cached on CharacterAdded
local humConns: { RBXScriptConnection } = {}
local barFrac = { h = -1, a = -1, ab = -1 }
local lowHealth = false
local jumpTop: number? = nil -- measured top edge of Roblox's touch jump button (design px), when it exists

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

-- What the cash counter shows: real cash minus an offline grant held back until it is claimed.
local function displayCash(): number
	local cash = currentCash()
	if cashHold > 0 and os.clock() < cashHoldUntil then
		return math.max(0, cash - cashHold)
	end
	cashHold = 0
	return cash
end

local function isDriving(): boolean
	if player:GetAttribute("Driving") == true then
		return true
	end
	-- the seat is ours a moment before the server flips the attribute: lay out for driving straight away
	local vc = lazy("VehicleClient")
	if vc and typeof(vc.isDriving) == "function" then
		local ok, driving = pcall(vc.isDriving)
		return ok and driving == true
	end
	return false
end

-------------------------------------------------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------------------------------------------------

local function segment(parent: Frame, name: string, track: Color3, fill: Color3): (Frame, Frame)
	local t = Kit.new("Frame", {
		Name = name,
		BackgroundColor3 = track,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	local f = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fill,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = t,
	})
	return t, f
end

local function makeTimer(id: string, label: string, order: number): TimerBar
	local u = ui :: HudUI
	local T = HudLayout.TIMER
	local frame = Kit.panel({
		Name = "Timer_" .. id,
		Size = UDim2.fromOffset(T.w, T.h),
		LayoutOrder = order,
		Parent = u.timers,
	})
	Kit.padding(0, 10).Parent = frame
	local l = Kit.text(string.upper(label), "condensedMedium", 14, {
		Name = "Label",
		Size = UDim2.fromScale(0.6, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local v = Kit.numeric("", 20, {
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.4, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})
	return { frame = frame, label = l, value = v, order = order }
end

local function build()
	local gui = Kit.screen("HC_HUD", Theme.Layers.HUD, { touchMin = Theme.TouchMinScale })
	local scale = gui:FindFirstChildOfClass("UIScale")
	local root = Kit.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})

	-- health | armour | ability, hanging under the radar's box (the combat package looks for Minimap > Bars)
	local radarBox = Kit.new("Frame", { Name = "Minimap", BackgroundTransparency = 1, Parent = root })
	local bars = Kit.new("Frame", {
		Name = "Bars",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 1, HudLayout.BAR_GAP),
		Size = UDim2.new(1, 0, 0, HudLayout.BAR_H),
		Parent = radarBox,
	})
	local healthTrack, healthFill = segment(bars, "Health", C.HealthTrack, C.Health)
	local armorTrack, armorFill = segment(bars, "Armour", C.BlueDark, C.Blue)
	local abilityTrack, abilityFill = segment(bars, "Ability", C.YellowDark, C.Yellow)

	-- wanted stars
	local starRow = Kit.new("Frame", { Name = "Stars", BackgroundTransparency = 1, Visible = false, Parent = root })
	local stars: { ImageLabel } = {}
	for i = 1, MAX_STARS do
		local star = Kit.image("hud.star_hollow", {
			Name = "Star" .. i,
			Size = UDim2.fromOffset(HudLayout.STAR_SIZE, HudLayout.STAR_SIZE),
			Position = UDim2.fromOffset((i - 1) * HudLayout.STAR_PITCH, 0),
			ImageTransparency = 0.3,
			Parent = starRow,
		})
		if star.Image == "" then
			star.BackgroundColor3 = C.Text
			star.BackgroundTransparency = 0.6
		end
		Kit.new("UIScale", { Parent = star })
		stars[i] = star
	end

	-- arrest progress
	local arrest = Kit.new("Frame", { Name = "Arrest", BackgroundTransparency = 1, Visible = false, Parent = root })
	Kit.text("BEING ARRESTED", "condensedMedium", 12, {
		Name = "Label",
		Size = UDim2.new(1, 0, 0, 14),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = arrest,
	})
	local arrestBar, arrestSet = Kit.progressBar(C.Blue, {
		Name = "Bar",
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 4),
		Parent = arrest,
	})
	arrestBar.BackgroundColor3 = C.BlueDark

	-- cash, delta, ammo
	local cash = Kit.numeric("$0", 30, { Name = "Cash", TextXAlignment = Enum.TextXAlignment.Right, Parent = root })
	local delta = Kit.numeric("", 24, {
		Name = "Delta",
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Green,
		Visible = false,
		Parent = root,
	})
	local ammo = Kit.numeric("", 26, {
		Name = "Ammo",
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = root,
	})

	-- help text
	local help = HelpText.new(root, 20, 20, HudLayout.HELP_W, 16)
	help.onBeep = function()
		UISound.play("help", { life = 2 }) -- Settings > Sound effects applies
	end

	-- feed host (NotificationController renders its cards here)
	local feed = Kit.new("Frame", { Name = "Feed", BackgroundTransparency = 1, Parent = root }, {
		Kit.list(Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom),
	})

	-- objective / subtitle
	local objective = Kit.text("", "body", 18, {
		Name = "Objective",
		TextWrapped = true,
		TextTransparency = 1,
		Parent = root,
	})
	Kit.new("UIStroke", {
		Color = C.Black,
		Thickness = 1,
		Transparency = 0.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = objective,
	})

	-- vehicle / district / street (script)
	local location = Kit.new("Frame", { Name = "Location", BackgroundTransparency = 1, Parent = root })
	local locationLines: { TextLabel } = {}
	for i = 1, 3 do
		locationLines[i] = Kit.script("", 26, {
			Name = "Line" .. i,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextTransparency = 1,
			Parent = location,
		})
	end

	-- timer bars
	local timersFrame = Kit.new("Frame", { Name = "Timers", BackgroundTransparency = 1, Parent = root })
	Kit.list(Enum.FillDirection.Vertical, HudLayout.TIMER.gap, Enum.HorizontalAlignment.Right).Parent = timersFrame

	-- radio (top-centre)
	local radio = Kit.new("Frame", { Name = "Radio", BackgroundTransparency = 1, Visible = false, Parent = root })
	local radioStation = Kit.text("", "condensed", 18, {
		Name = "Station",
		Size = UDim2.new(1, 0, 0, 24),
		Parent = radio,
	})
	Kit.new("UIStroke", {
		Color = C.Black,
		Thickness = 1,
		Transparency = 0.4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = radioStation,
	})
	local radioTrack = Kit.text("", "body", 14, {
		Name = "Track",
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 18),
		TextColor3 = C.TextDim,
		Parent = radio,
	})

	-- touch buttons
	local phoneButton =
		Kit.circleButton("Phone", 56, "hud.phone", { Name = "PhoneButton", Visible = false, Parent = root })
	local mapButton = Kit.circleButton("Map", 56, "hud.map", { Name = "MapButton", Visible = false, Parent = root })

	-- desktop mini phone glyph + unread badge (by the radar)
	local miniPhone = Kit.new("ImageButton", {
		Name = "MiniPhone",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(18, 18),
		Image = "",
		Visible = false,
		Parent = root,
	})
	Kit.setImage(miniPhone :: any, "hud.phone")
	miniPhone.ImageColor3 = C.Text
	local miniBadge = Kit.numeric("", 12, {
		Name = "Count",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(1, 2, 0.5, 0),
		Size = UDim2.fromOffset(20, 14),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Red,
		Parent = miniPhone,
	})

	-- Streamer mode on touch: P / B are keyboard keys, and the PHONE / MAP buttons and the radar tap all live in the
	-- hidden HUD, so a small button in its own ScreenGui brings the HUD back (start() wires it).
	local toggleGui = Kit.screen("HC_HudToggle", Theme.Layers.HUD, { touchMin = Theme.TouchMinScale })
	toggleGui.Enabled = false
	local toggleButton = Kit.circleButton("HUD", 48, nil, {
		Name = "ShowHud",
		Position = UDim2.fromOffset(HudLayout.SAFE_TOUCH, HudLayout.SAFE_TOUCH),
		Parent = toggleGui,
	})
	local toggleCaption = toggleButton:FindFirstChild("Caption")
	if toggleCaption and toggleCaption:IsA("TextLabel") then
		toggleCaption.TextSize = 16
	end

	ui = {
		gui = gui,
		scale = scale,
		root = root,
		radarBox = radarBox,
		bars = bars,
		healthFill = healthFill,
		healthTrack = healthTrack,
		armorFill = armorFill,
		armorTrack = armorTrack,
		abilityFill = abilityFill,
		abilityTrack = abilityTrack,
		stars = stars,
		starRow = starRow,
		arrest = arrest,
		arrestSet = arrestSet,
		cash = cash,
		delta = delta,
		ammo = ammo,
		help = help,
		feed = feed,
		objective = objective,
		location = location,
		locationLines = locationLines,
		timers = timersFrame,
		radio = radio,
		radioStation = radioStation,
		radioTrack = radioTrack,
		phoneButton = phoneButton,
		mapButton = mapButton,
		miniPhone = miniPhone :: any,
		miniBadge = miniBadge,
		toggleGui = toggleGui,
		toggleButton = toggleButton,
	}
end

-- Button handlers (kept out of build() so the HUD builds headlessly: HUDController.mount).
local function wireButtons(u: HudUI)
	local function togglePhone()
		local pc = lazy("PhoneController")
		if pc and typeof(pc.toggle) == "function" then
			pcall(pc.toggle)
		end
	end
	u.phoneButton.Activated:Connect(togglePhone)
	u.miniPhone.Activated:Connect(togglePhone)
	u.mapButton.Activated:Connect(function()
		local mc = lazy("MenuController")
		if mc and typeof(mc.openPause) == "function" then
			pcall(mc.openPause, "MAP")
		end
	end)
end

local function place(obj: GuiObject, r: HudLayout.Rect)
	obj.Position = UDim2.fromOffset(r.x, r.y)
	obj.Size = UDim2.fromOffset(r.w, r.h)
end

local function uiScaleOf(u: HudUI): number
	return if u.scale and u.scale.Scale > 0 then u.scale.Scale else 1
end

-- Help box: top-left; on desktop right of an open own-screen list menu (they share the corner).
local function placeHelp()
	local u = ui
	if not u then
		return
	end
	local L = layoutNow
	local r = if not L.touch and listOpenCount > 0 then HudLayout.helpBesideList(L, listOpenWidth) else L.help
	HelpText.move(u.help, r.x, r.y, r.w)
end

-- Feed host: desktop grows upward from above the radar; touch stacks under the help box and follows its height, so
-- a card never draws over a help message (§7).
local function refreshFeedAnchor()
	local u = ui
	if not u then
		return
	end
	local L = layoutNow
	if not L.touch then
		place(u.feed, L.feed)
		return
	end
	local box = u.help.box
	local helpH = if box.Visible then box.AbsoluteSize.Y / uiScaleOf(u) else 0
	local y = HudLayout.feedTop(L, helpH)
	u.feed.Position = UDim2.fromOffset(L.feed.x, y)
	u.feed.Size = UDim2.fromOffset(L.feed.w, math.max(80, L.h - L.safe - y))
end

-- Touch buttons: PHONE on foot above the jump button, in the right-hand cluster while driving (§7); MAP on foot.
local function refreshButtons()
	local u = ui
	if not u then
		return
	end
	local L = layoutNow
	local touch = L.touch
	local driving = isDriving()
	u.phoneButton.Visible = touch and not focusMode
	u.mapButton.Visible = touch and not driving and not focusMode
	local btn = L.buttons
	local phoneRect = if driving then btn.phoneDriving else btn.phone
	if phoneRect then
		place(u.phoneButton, phoneRect)
	end
	if btn.map then
		place(u.mapButton, btn.map)
	end
	u.miniPhone.Visible = not touch and (unread > 0)
	u.miniBadge.Text = if unread > 0 then tostring(math.min(unread, 99)) else ""
end

-- The radar box (and the bars under it): where MinimapController drew the radar, else the layout's rect.
local function placeRadarBox()
	local u = ui
	if not u then
		return
	end
	local r = radarRect or layoutNow.radar
	place(u.radarBox, r)
	local a, b, c = HudLayout.barSegments(r.w, 2)
	local h = HudLayout.BAR_H
	u.healthTrack.Position = UDim2.fromOffset(0, 0)
	u.healthTrack.Size = UDim2.fromOffset(a, h)
	u.armorTrack.Position = UDim2.fromOffset(a + 2, 0)
	u.armorTrack.Size = UDim2.fromOffset(b, h)
	u.abilityTrack.Position = UDim2.fromOffset(a + b + 4, 0)
	u.abilityTrack.Size = UDim2.fromOffset(c, h)
	u.miniPhone.Position = UDim2.fromOffset(r.x + r.w + 6, r.y + r.h - 18)
end

-- Top edge (design px, HC_HUD canvas) of Roblox's touch jump button when its TouchGui exists; nil otherwise (then the
-- layout works it out from the UIScale).
local jumpWatched: Instance? = nil
local function measureJump(u: HudUI): number?
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local touchGui = pg and pg:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local jump = frame and frame:FindFirstChild("JumpButton")
	if not (jump and jump:IsA("GuiObject")) then
		return nil
	end
	if jumpWatched ~= jump then
		jumpWatched = jump
		-- it moves / resizes with the screen (and appears after us): re-lay out; applyLayout measures it again
		local function relayout()
			task.defer(HUDController.relayout)
		end
		jump:GetPropertyChangedSignal("AbsolutePosition"):Connect(relayout)
		jump:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
		jump:GetPropertyChangedSignal("Visible"):Connect(relayout)
	end
	if not jump.Visible or jump.AbsoluteSize.Y < 1 then
		return nil
	end
	local s = uiScaleOf(u)
	return (jump.AbsolutePosition.Y - u.gui.AbsolutePosition.Y) / s
end

local function applyLayout()
	local u = ui
	if not u then
		return
	end
	local canvas = Kit.canvasSize(u.gui)
	local touch = Kit.isTouch()
	if touch then
		local ok, top = pcall(measureJump, u)
		jumpTop = if ok then top else nil
	end
	local L = HudLayout.compute(canvas.X, canvas.Y, touch, { scale = uiScaleOf(u), jumpTop = jumpTop })
	if phoneOpen then
		L = HudLayout.withPhone(L) -- the right-hand block / timer bars step out of the phone's way
	end
	layoutNow = L
	local driving = isDriving()
	drivingNow = driving

	placeRadarBox()

	place(u.starRow, L.stars)
	place(u.arrest, L.arrest)
	place(u.cash, L.cash)
	place(u.delta, L.delta)
	place(u.ammo, L.ammo)

	placeHelp()
	u.help.label.TextSize = if touch then 18 else 16

	refreshFeedAnchor()
	local list = u.feed:FindFirstChildOfClass("UIListLayout")
	if list then
		list.VerticalAlignment = if touch then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Bottom
	end

	u.objective.TextSize = 18
	if touch then
		u.objective.AnchorPoint = Vector2.new(0.5, 0)
		u.objective.Position = UDim2.fromOffset(L.objective.x + L.objective.w / 2, L.objective.y)
		u.objective.TextYAlignment = Enum.TextYAlignment.Top
	else
		u.objective.AnchorPoint = Vector2.new(0.5, 1)
		u.objective.Position = UDim2.fromOffset(L.objective.x + L.objective.w / 2, L.objective.y + L.objective.h)
		u.objective.TextYAlignment = Enum.TextYAlignment.Bottom
	end
	u.objective.Size = UDim2.fromOffset(L.objective.w, L.objective.h)

	local loc = if driving then L.locationDriving else L.location
	place(u.location, loc)
	local lineH = loc.h / L.locationLines
	for i, line in u.locationLines do
		line.Visible = i <= L.locationLines
		line.TextSize = L.locationSize
		line.TextXAlignment = if touch then Enum.TextXAlignment.Center else Enum.TextXAlignment.Right
		line.Position = UDim2.fromOffset(0, (i - 1) * lineH)
		line.Size = UDim2.new(1, 0, 0, lineH)
	end

	local tr = if driving then L.timersDriving else L.timers
	local tlist = u.timers:FindFirstChildOfClass("UIListLayout")
	local maxTimers = 4
	local stackH = maxTimers * (HudLayout.TIMER.h + HudLayout.TIMER.gap)
	if L.timerStep < 0 then
		-- desktop: bottom-anchored stack ending at the first bar's bottom
		u.timers.Position = UDim2.fromOffset(tr.x, tr.y + tr.h - stackH)
		if tlist then
			tlist.VerticalAlignment = Enum.VerticalAlignment.Bottom
			tlist.HorizontalAlignment = Enum.HorizontalAlignment.Right
		end
	else
		u.timers.Position = UDim2.fromOffset(tr.x, tr.y)
		if tlist then
			tlist.VerticalAlignment = Enum.VerticalAlignment.Top
			tlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		end
	end
	u.timers.Size = UDim2.fromOffset(tr.w, stackH)

	place(u.radio, L.radio)

	refreshButtons()
	HUDController.LayoutChanged:Fire(L)
end

function HUDController.relayout()
	applyLayout()
end

-------------------------------------------------------------------------------------------------------------------------
-- Visibility
-------------------------------------------------------------------------------------------------------------------------

local function setHidden(value: boolean)
	if value == hidden and ui then
		return
	end
	hidden = value
	local u = ui
	if u then
		u.gui.Enabled = not hidden
	end
	HUDController.VisibilityChanged:Fire(hidden)
end

-- The HUD is off in streamer mode, in photo mode and under the pause menu. The touch "HUD" button shows only for
-- streamer mode (the pause menu has its own close button; photo mode its Exit).
local function applyHidden()
	setHidden(serverHidden or localHidden or pauseOpen)
	local u = ui
	if u then
		u.toggleGui.Enabled = HUDController.showHudToggle(serverHidden, localHidden, pauseOpen, layoutNow.touch)
	end
end

-- Pure: whether the touch "show HUD" button is up.
function HUDController.showHudToggle(streamer: boolean, photo: boolean, paused: boolean, touch: boolean): boolean
	return streamer and touch and not photo and not paused
end

-- Photo mode (phone Camera app): hide the HUD locally without touching the saved streamer-mode setting.
function HUDController.setLocalHidden(on: boolean)
	localHidden = on == true
	applyHidden()
end

local function readHidden(snap: any): boolean
	return typeof(snap) == "table" and typeof(snap.settings) == "table" and snap.settings.hideHud == true
end

-------------------------------------------------------------------------------------------------------------------------
-- Cash
-------------------------------------------------------------------------------------------------------------------------

local function refreshCash(animate: boolean)
	local u = ui
	if not u then
		return
	end
	local value = displayCash()
	local trend = HUDController.cashTrend(value, lastCash)
	local previous = lastCash
	lastCash = value
	if not animate or trend == "none" or previous == nil then
		u.cash:SetAttribute("TweenToken", (u.cash:GetAttribute("TweenToken") or 0) + 1)
		u.cash:SetAttribute("Value", value)
		u.cash.Text = HUDController.formatCash(value)
		return
	end
	-- GTA: the change shows as its own line first, then the total rolls to the new value
	local now = os.clock()
	local merged
	deltaAmount, merged = HUDController.mergeDelta(deltaAmount, deltaAt, value - previous, now)
	deltaAt = now
	deltaToken += 1
	local my = deltaToken
	u.delta.Text = HUDController.formatDelta(deltaAmount)
	u.delta.TextColor3 = if deltaAmount >= 0 then C.Green else C.Red
	if not merged or not u.delta.Visible then
		u.delta.Visible = true
		Kit.fadeTree(u.delta, 1, 0)
		Kit.fadeTree(u.delta, 0, 0.15)
	end
	task.delay(DELTA_HOLD, function()
		if my ~= deltaToken then
			return
		end
		Kit.tweenNumber(u.cash, value, HUDController.formatCash, 0.5)
		Kit.fadeTree(u.delta, 1, 0.45)
		task.delay(0.5, function()
			if my == deltaToken then
				u.delta.Visible = false
				deltaAmount = 0
			end
		end)
	end)
	playSound("Click")
end

-------------------------------------------------------------------------------------------------------------------------
-- Stars + arrest
-------------------------------------------------------------------------------------------------------------------------

local starSprites: { string } = {} -- the sprite each star shows (no attribute reads per frame)

local function renderStars(now: number)
	local u = ui
	if not u then
		return
	end
	local stars = lastStars or 0
	for i, img in u.stars do
		local sprite, color, transparency = HUDController.starLook(i, stars, wantedSeen, now)
		if starSprites[i] ~= sprite then
			starSprites[i] = sprite
			Kit.setImage(img, sprite)
		end
		if not clearingStars then
			img.ImageColor3 = color
			img.ImageTransparency = transparency
		end
	end
end

local function refreshStars(animate: boolean)
	local u = ui
	if not u then
		return
	end
	local stars = HUDController.clampStars(player:GetAttribute("Wanted"))
	local states = HUDController.starStates(stars, lastStars)
	local prev = lastStars or stars
	lastStars = stars
	if stars > 0 then
		clearingStars = false
		if not starsShown then
			starsShown = true
			u.starRow.Visible = true
			Kit.fadeTree(u.starRow, 1, 0)
			Kit.fadeTree(u.starRow, 0, 0.3)
		end
		renderStars(os.clock())
		if animate then
			for i, st in states do
				if st.gained then
					local s = u.stars[i]:FindFirstChildOfClass("UIScale")
					if s then
						s.Scale = 1.25
						tween(s, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
					end
				end
			end
		end
	elseif starsShown then
		-- cleared: the stars blink three times, then fade (§5.3)
		starsShown = false
		clearingStars = true
		task.spawn(function()
			for _ = 1, 3 do
				for _, img in u.stars do
					img.ImageTransparency = 1
				end
				task.wait(0.15)
				if not clearingStars then
					return
				end
				for i, img in u.stars do
					img.ImageTransparency = if i <= prev then 0 else 0.3
				end
				task.wait(0.15)
				if not clearingStars then
					return
				end
			end
			Kit.fadeTree(u.starRow, 1, 0.4)
			task.wait(0.45)
			if clearingStars then
				u.starRow.Visible = false
				clearingStars = false
			end
		end)
		local nc = lazy("NotificationController")
		if animate and prev > 0 and nc and typeof(nc.post) == "function" then
			pcall(nc.post, { body = "Wanted level cleared.", key = "wanted_cleared" })
		end
	end
end

local function refreshSeen()
	local seen = player:GetAttribute("WantedSeen")
	wantedSeen = seen ~= false -- nil (not replicated yet) counts as seen
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
		u.arrest.Visible = show
	end
	if show then
		u.arrestSet(p, true)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Bars
-------------------------------------------------------------------------------------------------------------------------

-- Write a fill only when its fraction moved (tween for event-driven changes, direct for per-frame readings).
local function setFill(fill: Frame, key: string, frac: number, animate: boolean)
	if math.abs((barFrac :: any)[key] - frac) < 0.002 then
		return
	end
	(barFrac :: any)[key] = frac
	local size = UDim2.fromScale(frac, 1)
	if animate then
		TweenService:Create(fill, BAR_TWEEN, { Size = size }):Play()
	else
		fill.Size = size
	end
end

-- Health + armour (HealthChanged / MaxHealth / Armor / MaxArmor signals).
local function refreshHealthArmor()
	local u = ui
	if not u then
		return
	end
	local h, a = HUDController.barFractions(
		if hum then hum.Health else nil,
		if hum then hum.MaxHealth else nil,
		player:GetAttribute("Armor"),
		player:GetAttribute("MaxArmor"),
		nil
	)
	setFill(u.healthFill, "h", h, true)
	setFill(u.armorFill, "a", a, true)
	local low = h <= LOW_HEALTH
	if low ~= lowHealth then
		lowHealth = low
		u.healthFill.BackgroundColor3 = if low then C.Damage else C.Health
		u.healthFill.BackgroundTransparency = 0
	end
end

-- The third segment: an override (setAbility), nitro while driving (read per frame: it drains continuously), else
-- the Stamina attribute (full when absent).
local function abilityNow(): (number, Color3)
	if abilityOverride then
		return abilityOverride, abilityColor or C.Yellow
	end
	if drivingNow then
		local vc = lazy("VehicleClient")
		local ctrl = if vc and typeof(vc.getController) == "function" then vc.getController() else nil
		if ctrl and typeof(ctrl.nitro) == "number" then
			return math.clamp(ctrl.nitro, 0, 1), C.Yellow
		end
	end
	local stamina = attrNumber("Stamina")
	return if stamina then math.clamp(stamina, 0, 1) else 1, C.Yellow
end

local function refreshAbility(animate: boolean)
	local u = ui
	if not u then
		return
	end
	local frac, color = abilityNow()
	setFill(u.abilityFill, "ab", frac, animate)
	if u.abilityFill.BackgroundColor3 ~= color then
		u.abilityFill.BackgroundColor3 = color
	end
end

-- Per frame: only the low-health pulse (0 <-> 0.4 at 1.5 Hz) and the nitro reading while driving.
local function stepBars(now: number)
	local u = ui
	if not u then
		return
	end
	if lowHealth then
		u.healthFill.BackgroundTransparency = 0.2 + 0.2 * math.sin(now * math.pi * 3)
	end
	if drivingNow and not abilityOverride then
		refreshAbility(false)
	end
end

local function bindHumanoid(char: Model?)
	for _, c in humConns do
		c:Disconnect()
	end
	table.clear(humConns)
	hum = nil
	if not char then
		refreshHealthArmor()
		return
	end
	local h = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
	if not (h and h:IsA("Humanoid")) or player.Character ~= char then
		return
	end
	hum = h
	table.insert(humConns, h.HealthChanged:Connect(refreshHealthArmor))
	table.insert(humConns, h:GetPropertyChangedSignal("MaxHealth"):Connect(refreshHealthArmor))
	refreshHealthArmor()
end

-------------------------------------------------------------------------------------------------------------------------
-- Theft timer (GTA Online timer bar + objective)
-------------------------------------------------------------------------------------------------------------------------

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and typeof(t) == "number" then t else os.time()
end

local THEFT_TIMER = "delivery"

local function applyTheft(state: any)
	local active = typeof(state) == "table" and state.active == true
	local dropped, endsAt = HUDController.theftMode(state)
	theftEndsAt = endsAt
	if dropped ~= theftDropped then
		theftDropped = dropped
		theftTotal = if dropped then math.max(1, (endsAt or 0) - serverNow()) else THEFT_TOTAL
	end
	if active ~= theftActive or active then
		theftActive = active
		if active then
			local text = if dropped
				then "Get back in the <blue>car</blue> before it is towed home."
				else "Take the car to your <y>garage</y>."
			theftObjective = text
			HUDController.objective(text)
		else
			HUDController.clearTimer(THEFT_TIMER)
			-- only take down our own line: the tutorial (or another system) may own the objective by now
			if theftObjective ~= nil and objectiveText == theftObjective then
				HUDController.objective(nil)
			end
			theftObjective = nil
		end
	end
end

local function refreshTheft()
	if not theftActive then
		return
	end
	local text, _, urgent = HUDController.theftView(theftEndsAt, serverNow(), theftTotal)
	HUDController.setTimer(
		THEFT_TIMER,
		if theftDropped then "GET BACK IN" else "DELIVERY",
		text,
		if urgent or theftDropped then C.Red else nil,
		1,
		if theftDropped then C.Red else nil
	)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

function HUDController.getLayout(): HudLayout.Layout
	return layoutNow
end

function HUDController.help(text: string, opts: any?): string?
	local u = ui
	if not u or typeof(text) ~= "string" then
		return nil
	end
	return u.help.show(text, opts)
end

function HUDController.clearHelp(id: string?)
	local u = ui
	if u then
		u.help.clear(id)
	end
end

-- Id of the help message on screen right now (nil = none).
function HUDController.currentHelp(): string?
	local u = ui
	return if u then u.help.current() else nil
end

-- Objective line (persistent until replaced / cleared, re-shown after a subtitle). nil clears.
function HUDController.objective(text: string?)
	local u = ui
	objectiveText = text
	if not u then
		return
	end
	if os.clock() < subtitleUntil then
		-- a subtitle owns the slot; its end shows objectiveText. Leave the token alone or that end never runs.
		return
	end
	objectiveToken += 1
	local my = objectiveToken
	if text then
		u.objective.Text = RichText.format(Kit.sanitize(text))
		tween(u.objective, FADE_IN, { TextTransparency = 0 })
		task.delay(OBJECTIVE_HOLD, function()
			if my == objectiveToken and os.clock() >= subtitleUntil then
				tween(u.objective, FADE_IN, { TextTransparency = 1 })
			end
		end)
	else
		tween(u.objective, FADE_IN, { TextTransparency = 1 })
	end
end

-- Re-shows the current objective (after a key press, a respawn, ...).
function HUDController.repeatObjective()
	if objectiveText then
		HUDController.objective(objectiveText)
	end
end

-- Dialogue / one-off subtitle in the objective slot; the objective returns afterwards.
function HUDController.subtitle(text: string, seconds: number?)
	local u = ui
	if not u then
		return
	end
	local hold = seconds or 4
	subtitleUntil = os.clock() + hold
	objectiveToken += 1
	local my = objectiveToken
	u.objective.Text = RichText.format(Kit.sanitize(text))
	tween(u.objective, FADE_IN, { TextTransparency = 0 })
	task.delay(hold, function()
		if my ~= objectiveToken then
			return
		end
		subtitleUntil = 0
		if objectiveText then
			HUDController.objective(objectiveText)
		else
			tween(u.objective, FADE_IN, { TextTransparency = 1 })
		end
	end)
end

-- Vehicle / district / street script lines (bottom-right; touch: "District · Street" top-centre).
function HUDController.showLocation(vehicle: string?, district: string?, street: string?)
	local u = ui
	if not u or hidden then
		return
	end
	locationToken += 1
	local my = locationToken
	local lines: { string } = {}
	if layoutNow.touch then
		local parts = {}
		for _, s in { district, street } do
			if s and s ~= "" then
				table.insert(parts, s)
			end
		end
		if vehicle and vehicle ~= "" and #parts == 0 then
			table.insert(parts, vehicle)
		end
		lines = { table.concat(parts, " · ") }
	else
		lines = { vehicle or "", district or "", street or "" }
		-- pack the shown lines toward the bottom (the block is bottom-anchored)
		local packed: { string } = {}
		for _, s in lines do
			if s ~= "" then
				table.insert(packed, s)
			end
		end
		while #packed < 3 do
			table.insert(packed, 1, "")
		end
		lines = packed
	end
	for i, label in u.locationLines do
		label.Text = Kit.sanitize(lines[i] or "")
		label.TextTransparency = 1
		local stroke = label:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 1
			tween(stroke, FADE_IN, { Transparency = 0.6 })
		end
		tween(label, FADE_IN, { TextTransparency = 0 })
	end
	task.delay(0.3 + (if layoutNow.touch then 3 else LOCATION_HOLD), function()
		if my ~= locationToken then
			return
		end
		local out = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
		for _, label in u.locationLines do
			tween(label, out, { TextTransparency = 1 })
			local stroke = label:FindFirstChildOfClass("UIStroke")
			if stroke then
				tween(stroke, out, { Transparency = 1 })
			end
		end
	end)
end

-- GTA Online timer bar: "LABEL     1:42". color tints the value (nil = white); labelColor the label.
function HUDController.setTimer(
	id: string,
	label: string,
	value: string,
	color: Color3?,
	order: number?,
	labelColor: Color3?
)
	local u = ui
	if not u then
		return
	end
	local bar = timers[id]
	if not bar then
		bar = makeTimer(id, label, order or 10)
		timers[id] = bar
	end
	bar.label.Text = string.upper(Kit.sanitize(label))
	bar.label.TextColor3 = labelColor or C.Text
	bar.value.Text = value
	bar.value.TextColor3 = color or C.Text
end

function HUDController.clearTimer(id: string)
	local bar = timers[id]
	if bar then
		timers[id] = nil
		bar.frame:Destroy()
	end
end

-- Ammo "12  48" (clip white, reserve grey). nil clip hides it.
function HUDController.setAmmo(clip: number?, reserve: number?)
	local u = ui
	if not u then
		return
	end
	if typeof(clip) ~= "number" then
		u.ammo.Visible = false
		return
	end
	u.ammo.Visible = true
	local r = if typeof(reserve) == "number" then `  <font color="#9B9B9B">{math.floor(reserve)}</font>` else ""
	u.ammo.Text = tostring(math.floor(clip)) .. r
end

function HUDController.showRadio(station: string?, track: string?)
	local u = ui
	if not u then
		return
	end
	radioToken += 1
	local my = radioToken
	if not station then
		u.radio.Visible = false
		return
	end
	u.radio.Visible = true
	u.radioStation.Text = string.upper(Kit.sanitize(station))
	u.radioTrack.Text = Kit.sanitize(track or "")
	Kit.fadeTree(u.radio, 1, 0)
	Kit.fadeTree(u.radio, 0, 0.25)
	task.delay(RADIO_HOLD, function()
		if my == radioToken then
			Kit.fadeTree(u.radio, 1, 0.5)
			task.delay(0.5, function()
				if my == radioToken then
					u.radio.Visible = false
				end
			end)
		end
	end)
end

-- Third bar segment override (e.g. a special ability); nil = automatic (nitro while driving, stamina on foot).
function HUDController.setAbility(fraction: number?, color: Color3?)
	abilityOverride = if typeof(fraction) == "number" and fraction == fraction then math.clamp(fraction, 0, 1) else nil
	abilityColor = color
	refreshAbility(true)
end

-- Where MinimapController drew the radar (design px on the shared HUD canvas): the bars follow it (expanded radar).
function HUDController.setRadarRect(x: number, y: number, w: number, h: number)
	if typeof(x) ~= "number" or typeof(y) ~= "number" or typeof(w) ~= "number" or typeof(h) ~= "number" then
		return
	end
	radarRect = { x = x, y = y, w = w, h = h }
	placeRadarBox()
end

-- Why the HUD is hidden: streamer mode (settings.hideHud), photo mode, the pause menu.
function HUDController.hiddenState(): (boolean, boolean, boolean)
	return serverHidden, localHidden, pauseOpen
end

function HUDController.setUnread(count: number)
	unread = if typeof(count) == "number" then math.max(0, math.floor(count)) else 0
	refreshButtons()
end

function HUDController.shard(kind: string, title: string?, subtitle: string?, opts: any?): number
	return Shard.show(kind, title, subtitle, opts)
end

-- The arrest: busted shard, grayscale grade, and a feed note once the cut is over.
function HUDController.showBusted(lostCash: number, carLabel: string?)
	local lost = if typeof(lostCash) == "number" and lostCash == lostCash then math.max(0, lostCash) else 0
	local parts = {}
	if lost > 0 then
		table.insert(parts, "Bail " .. HUDController.formatDelta(-lost))
	end
	if carLabel and carLabel ~= "" then
		table.insert(parts, RichText.escape(Kit.sanitize(carLabel)) .. " impounded")
	end
	Shard.show("busted", nil, table.concat(parts, "  ·  "), {
		grade = true,
		onDone = function()
			local nc = lazy("NotificationController")
			if nc and typeof(nc.post) == "function" then
				local body = "Released from Police HQ."
				if lost > 0 then
					body ..= " Bail " .. HUDController.formatDelta(-lost) .. "."
				end
				pcall(nc.post, { body = body, key = "busted_release" })
			end
		end,
	})
end

function HUDController.getFeedHost(): Frame?
	local u = ui
	return if u then u.feed else nil
end

function HUDController.getCashAnchor(): GuiObject?
	local u = ui
	if not u or hidden or not u.gui.Enabled then
		return nil
	end
	return u.cash
end

-- v1 menu buttons are gone: the touch PHONE button (or the mini phone) is the pointer target.
function HUDController.getMenuButton(_id: string): GuiButton?
	local u = ui
	if not u then
		return nil
	end
	return if layoutNow.touch then u.phoneButton else u.miniPhone
end

function HUDController.isHidden(): boolean
	return hidden
end

-- Design px reserved at bottom-centre (the objective line on desktop).
function HUDController.getBottomClearance(): number
	if layoutNow.touch then
		return 16
	end
	return layoutNow.h - layoutNow.objective.y
end

-- Real px (inset-relative) where the top-centre HUD ends: other top-centre stacks (event pills) go below it.
function HUDController.getTopStackBottom(): number
	local u = ui
	if not u or hidden then
		return 0
	end
	local s = if u.scale and u.scale.Scale > 0 then u.scale.Scale else 1
	local L = layoutNow
	local bottom = if L.touch then L.timers.y + 2 * (HudLayout.TIMER.h + HudLayout.TIMER.gap) else L.radio.y + L.radio.h
	return bottom * s
end

function HUDController.getFeedAnchor(): Vector2?
	local u = ui
	if not u or hidden then
		return nil
	end
	local s = uiScaleOf(u)
	return Vector2.new(u.feed.Position.X.Offset * s, u.feed.Position.Y.Offset * s)
end

-- Real px bottom of the top-left HUD (help box when shown, else the radar block on touch).
function HUDController.getMenuBottom(): number
	local u = ui
	if not u or hidden then
		return 0
	end
	local s = if u.scale and u.scale.Scale > 0 then u.scale.Scale else 1
	if u.help.box.Visible then
		return (u.help.box.AbsolutePosition.Y + u.help.box.AbsoluteSize.Y)
	end
	return (if layoutNow.touch then layoutNow.bars.y + layoutNow.bars.h else layoutNow.help.y) * s
end

-- Offline earnings: the server already credited `amount`; keep showing the pre-grant cash until releaseCash.
function HUDController.holdCash(amount: number)
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	cashHold += amount
	cashHoldUntil = os.clock() + HOLD_CASH_MAX_SECONDS
	-- the Cash attribute usually lands first and has already queued a "+$X" line and a count-up: cancel them, or
	-- releaseCash shows the grant a second time
	deltaToken += 1
	deltaAmount = 0
	local u = ui
	if u then
		u.delta.Visible = false
	end
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

-- The phone sits over the bottom-right location lines: hide them while it is up (GTA does the same). The cash stays
-- on screen (lead decision) and the delivery timer stays readable: HudLayout.withPhone moves them out of its way.
function HUDController.setPhoneOpen(on: boolean)
	phoneOpen = on == true
	local u = ui
	if u then
		u.location.Visible = not phoneOpen
	end
	applyLayout()
end

-- Tutorial focus: hides the touch phone / map buttons for the first steps.
function HUDController.setFocusMode(on: boolean)
	focusMode = on == true
	refreshButtons()
end

-- v1 API (MinimapController reserved a corner); the shared layout owns the corners now.
function HUDController.setMinimapReserve(_touchLeft: number, _desktopBottom: number, _touchBottom: number?) end

-------------------------------------------------------------------------------------------------------------------------
-- CoreGui + chat (§8)
-------------------------------------------------------------------------------------------------------------------------

local function configureCoreGui()
	-- C4b: the CoreGui / chat / bubble setup lives in UI/CoreGuiSetup (it also moves the chat window out of the way of
	-- the left-side menus, job 0006 bug 3). The weapon wheel replaces the hotbar once a wheel controller exists.
	local controllers = script.Parent
	local wheel = controllers:FindFirstChild("WeaponWheelController") ~= nil
		or controllers:FindFirstChild("WeaponWheel") ~= nil
	CoreGuiSetup.apply({
		wheel = wheel,
		-- Esc lands in the Roblox menu (job 0018 VIBE row 20): in the first minute its close opens our pause MAP
		openPause = function()
			local menu = lazy("MenuController")
			if menu and typeof(menu.openPause) == "function" then
				pcall(menu.openPause, "MAP")
			end
		end,
		hint = function(text: string)
			HUDController.help(text, { id = "esc_hint", duration = 8 })
		end,
	})
end

-- [VIP] chat prefix for VIP pass holders (each client tags incoming messages from senders whose VIP attribute is set).
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

-- Dying while wanted is a bust on the server, so Reset Character is off while wanted. SetCore throws until the
-- CoreScripts register the callback: retry for a few seconds; a newer state cancels an older retry.
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

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function HUDController.init() end

-- Build the HUD and lay it out without wiring engine events (start() calls this first; headless specs call it alone).
function HUDController.mount()
	if ui then
		return
	end
	build()
	applyLayout()
end

function HUDController.start()
	if started then
		return
	end
	started = true
	HUDController.mount()
	local u = ui :: HudUI
	wireButtons(u)
	u.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
	if u.scale then
		u.scale:GetPropertyChangedSignal("Scale"):Connect(applyLayout)
	end
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(function()
			applyLayout()
			applyHidden()
		end)
	end)
	configureCoreGui()
	installVipChatTag()
	-- the PlayerModule makes the TouchGui (jump button) after us: re-lay out the PHONE / MAP buttons when it shows up
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if pg then
		pg.ChildAdded:Connect(function(child: Instance)
			if child.Name == "TouchGui" then
				task.delay(0.5, applyLayout)
			end
		end)
	end

	-- touch feed follows the help box's height (it stacks under it)
	u.help.box:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshFeedAnchor)
	u.help.box:GetPropertyChangedSignal("Visible"):Connect(refreshFeedAnchor)

	-- desktop: an open shop / list menu owns the top-left corner; the help box steps right of it
	ListMenu.ScreenListsChanged:Connect(function(count: number, widest: number)
		listOpenCount = count
		listOpenWidth = widest
		placeHelp()
	end)
	listOpenCount, listOpenWidth = ListMenu.openScreens()

	-- streamer mode's way back on touch
	u.toggleButton.Activated:Connect(function()
		playSound("Click")
		hiddenOverrideUntil = os.clock() + 2 -- ignore the stale snapshot that still says hideHud = true
		serverHidden = false
		applyHidden()
		Net.fire("SetSetting", "hideHud", false)
	end)

	-- the pause menu hides the HUD (§5.12)
	task.defer(function()
		local menu = lazy("MenuController")
		if menu and menu.PauseChanged then
			menu.PauseChanged:Connect(function(open: boolean)
				pauseOpen = open == true
				applyHidden()
			end)
			if typeof(menu.isPauseOpen) == "function" then
				local ok, open = pcall(menu.isPauseOpen)
				pauseOpen = ok and open == true
				applyHidden()
			end
		end
	end)

	player:GetAttributeChangedSignal("Cash"):Connect(function()
		refreshCash(true)
	end)
	player:GetAttributeChangedSignal("Wanted"):Connect(function()
		refreshStars(true)
		applyResetButton()
	end)
	applyResetButton()
	player:GetAttributeChangedSignal("WantedSeen"):Connect(refreshSeen)
	player:GetAttributeChangedSignal("BustProgress"):Connect(refreshBust)
	local function onDrivingChanged()
		applyLayout()
		refreshButtons()
		refreshAbility(true)
	end
	player:GetAttributeChangedSignal("Driving"):Connect(onDrivingChanged)
	local vc = lazy("VehicleClient")
	if vc and vc.Entered and vc.Exited then
		vc.Entered:Connect(onDrivingChanged)
		vc.Exited:Connect(onDrivingChanged)
	end

	local function onSnapshot(snap: any, previous: any)
		local wantHidden = readHidden(snap)
		if
			(wantHidden ~= serverHidden or previous == nil) and not (wantHidden and os.clock() < hiddenOverrideUntil)
		then
			serverHidden = wantHidden
			applyHidden()
		end
		if attrNumber("Cash") == nil then
			refreshCash(previous ~= nil)
		end
	end
	StateController.Changed:Connect(onSnapshot)
	local snap = StateController.get()
	if snap then
		onSnapshot(snap, nil)
	end

	StateController.TheftChanged:Connect(applyTheft)
	applyTheft(StateController.getTheft())

	refreshCash(false)
	refreshSeen()
	refreshStars(false)
	refreshBust()
	refreshButtons()

	task.spawn(function()
		if script.Parent:FindFirstChild("DeathScreenController") then
			return -- the combat package owns the wasted / busted screens
		end
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

	-- bars: event driven (bindHumanoid + the attribute signals); per frame only the pulse + nitro
	player.CharacterAdded:Connect(function(char: Model)
		task.spawn(bindHumanoid, char)
	end)
	task.spawn(bindHumanoid, player.Character)
	for _, attr in { "Armor", "MaxArmor" } do
		player:GetAttributeChangedSignal(attr):Connect(refreshHealthArmor)
	end
	player:GetAttributeChangedSignal("Stamina"):Connect(function()
		refreshAbility(true)
	end)
	refreshHealthArmor()
	refreshAbility(false)

	-- per-frame cosmetics: help expiry (always: a message must not outlive its time while the HUD is hidden), the
	-- low-health pulse, nitro, search-flash stars (property writes only)
	RunService.Heartbeat:Connect(function()
		u.help.step()
		if hidden then
			return
		end
		local now = os.clock()
		stepBars(now)
		if (lastStars or 0) > 0 then
			renderStars(now)
		end
	end)

	-- 4 Hz: timers
	while true do
		local ok, err = pcall(refreshTheft)
		if not ok then
			warn("[HUDController] tick error: " .. tostring(err))
		end
		task.wait(0.25)
	end
end

return HUDController
