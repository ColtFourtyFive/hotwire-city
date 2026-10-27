--!strict
-- MenuController (SPEC §7): every modal menu in Hotwire City, built with UI/Kit + Theme inside ONE ScreenGui "Menus"
-- (DisplayOrder Theme.Layers.Menus). Only one menu is open at a time; a dim backdrop sits behind it (tap = close).
--
-- Public API
--   open(name): boolean       open a menu (closes any other). Unknown names -> false. Aliases accepted ("Gear",
--                             "CarIndex", "Playtime", ...; see MenuController.ALIASES; case/space-insensitive).
--   close(name?): boolean     close `name` (or whichever menu is open when nil). false when it was not open.
--   toggle(name): boolean     open if closed, close if open. false only for unknown names.
--   isOpen(name): boolean
--   has(name): boolean        `name` (or an alias) is a known menu. HUDController probes this.
--   getOpen(): string?        canonical name of the open menu.
--   closeAll()
--   Opened: Signal(name), Closed: Signal(name)
--   Canonical names: GearShop, Store, Index, Daily, Contracts, Gifts, Rebirth, Codes, Settings.
--
-- Remotes: listens to OpenUI(name). Sends BuyUpgrade, BuyTool, ClaimDaily, ClaimPlaytime, RedeemCode, Rebirth,
-- SetSetting and (once Shared.Remotes lists it) RerollContract, all re-validated by the server. Store buttons call
-- MarketplaceService prompts; the server grants. Store items the server would refuse (owned one-per-account car,
-- Lose the Cops with 0 stars) are disabled. Menus close on Esc / gamepad B / Backspace and when the Roblox menu opens.
-- State is read ONLY from StateController (snapshot + Changed) and player attributes (Cash, IncomePerSec, Rebirths,
-- Wanted).
-- The open menu refreshes on every snapshot and on Cash changes; countdowns tick once per second.
-- Index car previews (ViewportFrames via CarBuilder) are built lazily, a few per frame, only once the Index opens.
-- Pure helpers (resolveName, dailyTileStates, playtimeTiles, contractRows, upgradeRows, ...) are exported for tests.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = Shared:WaitForChild("Config")
local Cars = require(Config:WaitForChild("Cars"))
local Rarity = require(Config:WaitForChild("Rarity"))
local Economy = require(Config:WaitForChild("Economy"))
local Monetization = require(Config:WaitForChild("Monetization"))
local Util = Shared:WaitForChild("Util")
local EconomyMath = require(Util:WaitForChild("EconomyMath"))
local Format = require(Util:WaitForChild("Format"))
local Signal = require(Util:WaitForChild("Signal"))
local Trove = require(Util:WaitForChild("Trove"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER and the only source of player data: required directly.
local StateController = require(script.Parent:WaitForChild("StateController"))

type CarDef = Cars.CarDef

local MenuController = {}

MenuController.Opened = Signal.new()
MenuController.Closed = Signal.new()

local player = Players.LocalPlayer

-------------------------------------------------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------------------------------------------------

local MIN_CONTRACT_REWARD = 500 -- RewardsService pays max($500, reward seconds x income)
local MIN_INCOME_REWARD = 500 -- incomeMinutes rewards without their own `min` pay at least $500
local VIEW_FOV = 30
local CARD_YAW = 38 -- 3/4 front view
local CARD_PITCH = 20
local SPIN_SPEED = 50 -- degrees per second for the selected / hovered car
local FRAME_TIGHTNESS = 0.8 -- < 1 = car fills more of the viewport
local BACKDROP_TRANSPARENCY = 0.42
local CONFIRM_WINDOW = 4 -- seconds the "tap again" rebirth confirm stays armed
local PENDING_SECONDS = 3 -- claim/buy buttons stay "..." this long waiting for the server
local MODELS_PER_FRAME = 3 -- Index viewport builds per frame
local INDEX_DETAIL_W = 270
local INDEX_CARD = Vector2.new(112, 140) -- 5 per row
local SETTINGS_OVERRIDE_TTL = 4 -- optimistic setting values expire if the server never confirms them
local SWAP_REMOTE = "RerollContract" -- (contractId) daily free contract swap; the button hides until it exists
local SWAP_AVAILABLE = table.find(Remotes.ClientToServer, SWAP_REMOTE) ~= nil

local WHITE = Color3.new(1, 1, 1)
local SILHOUETTE = Color3.fromRGB(6, 6, 14)
local PIP_EMPTY = Color3.fromRGB(14, 15, 30)
local PURPLE = Color3.fromRGB(160, 90, 255)
local REBIRTH_COLOR = Color3.fromRGB(120, 70, 255)
local SETTINGS_COLOR = Color3.fromRGB(88, 100, 172)
local SECRET_COLOR = Color3.fromRGB(235, 235, 248) -- Secret's tier color is black: unreadable on dark panels
local DIM_TEXT = Color3.fromRGB(205, 208, 225)

local DEFAULT_SETTINGS: { [string]: boolean } = { music = true, sfx = true, hideHud = false, autoAccelerate = false }

-------------------------------------------------------------------------------------------------------------------------
-- Names
-------------------------------------------------------------------------------------------------------------------------

MenuController.NAMES = { "GearShop", "Store", "Index", "Daily", "Contracts", "Gifts", "Rebirth", "Codes", "Settings" }

MenuController.ALIASES = {
	Gear = "GearShop",
	Shop = "GearShop",
	Upgrades = "GearShop",
	Tools = "GearShop",
	Robux = "Store",
	CarIndex = "Index",
	Collection = "Index",
	DailyReward = "Daily",
	DailyRewards = "Daily",
	Streak = "Daily",
	Jobs = "Contracts",
	Missions = "Contracts",
	Quests = "Contracts",
	Playtime = "Gifts",
	PlaytimeGifts = "Gifts",
	Gift = "Gifts",
	Code = "Codes",
	Options = "Settings",
} :: { [string]: string }

local CANONICAL: { [string]: boolean } = {}
local LOOKUP: { [string]: string } = {}
for _, n in MenuController.NAMES do
	CANONICAL[n] = true
	LOOKUP[string.lower(n)] = n
end
for alias, target in MenuController.ALIASES do
	LOOKUP[string.lower(alias)] = target
end

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function num(v: any, default: number): number
	return if finite(v) then v else default
end

-- 2 -> "2", 2.5 -> "2.5", 0.85 -> "0.85"
local function fmtNum(v: number): string
	if v % 1 == 0 then
		return tostring(math.floor(v))
	end
	local s = string.format("%.2f", v)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return s
end
MenuController.fmtNum = fmtNum

local function hex(c: Color3): string
	return string.format(
		"%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

local HEX_DIM = hex(Theme.Colors.TextDim)
local HEX_CASH = hex(Theme.Colors.Cash)
local HEX_GOLD = hex(Theme.Colors.Gold)

-- Any menu name or alias -> canonical name (nil when unknown). Case, spaces, '_' and '-' are ignored.
function MenuController.resolveName(name: any): string?
	if typeof(name) ~= "string" then
		return nil
	end
	if CANONICAL[name] then
		return name
	end
	local key = string.gsub(string.lower(name), "[%s_%-]", "")
	return LOOKUP[key]
end

-- Seconds until the next UTC midnight (daily reset). Always in (0, 86400].
function MenuController.secondsUntilUtcMidnight(now: number): number
	if not finite(now) then
		return 86400
	end
	return 86400 - (now % 86400)
end

-- Countdown text "hh:mm" (minutes rounded up so "00:00" only shows at the very end).
function MenuController.formatHhMm(seconds: number): string
	local s = if finite(seconds) then math.max(0, seconds) else 0
	local totalMinutes = math.ceil(s / 60)
	return string.format("%02d:%02d", totalMinutes // 60, totalMinutes % 60)
end

-- 300 -> "5 min", 450 -> "7.5 min", 45 -> "45 sec", 3600 -> "1 hr"
function MenuController.durationWords(seconds: number): string
	local s = math.max(0, num(seconds, 0))
	if s >= 3600 and s % 3600 == 0 then
		return `{fmtNum(s / 3600)} hr`
	elseif s >= 60 then
		return `{fmtNum(math.floor(s / 6) / 10)} min`
	end
	return `{math.floor(s)} sec`
end

-- x1, x1.5, x2.25
function MenuController.formatMultiplier(m: number): string
	return "x" .. fmtNum(math.floor(num(m, 1) * 100 + 0.5) / 100)
end

export type RewardInfo = { icon: string, text: string, sub: string?, color: Color3 }

-- Display info for a daily / playtime reward entry ({kind="cash"|"incomeMinutes"|"car", amount?, min?, rarity?}).
-- incomeMinutes estimates mirror RewardsService: minutes of income, never less than the entry's `min`.
function MenuController.rewardInfo(reward: any, incomePerSec: number?): RewardInfo
	if typeof(reward) ~= "table" then
		return { icon = "🎁", text = "GIFT", sub = nil, color = Theme.Colors.Text }
	end
	local kind = reward.kind
	if kind == "cash" then
		return { icon = "💵", text = Format.cash(num(reward.amount, 0)), sub = "CASH", color = Theme.Colors.Cash }
	elseif kind == "incomeMinutes" then
		local minutes = num(reward.amount, 0)
		local floor = if finite(reward.min) then math.max(0, reward.min) else MIN_INCOME_REWARD
		local estimate = math.max(floor, math.floor(minutes * 60 * math.max(0, num(incomePerSec, 0))))
		return {
			icon = "⏱️",
			text = `{fmtNum(minutes)} MIN`,
			sub = `≈ {Format.cash(estimate)}`,
			color = Theme.Colors.Secondary,
		}
	elseif kind == "car" then
		local rid = if typeof(reward.rarity) == "string" then reward.rarity else "Rare"
		local tier = (Rarity.Tiers :: any)[rid]
		local color = if rid == "Secret" then SECRET_COLOR elseif tier then tier.color else Theme.Colors.Gold
		return { icon = "🚗", text = `{string.upper(rid)} CAR`, sub = "RANDOM", color = color }
	end
	return { icon = "🎁", text = "GIFT", sub = nil, color = Theme.Colors.Text }
end

export type TileState = "claimed" | "ready" | "next" | "locked"

-- Daily streak track. view = snapshot.daily {streak, canClaim, nextDay}. Returns one state per reward tile:
--   claimed (done this week), ready (claim now), next (claimable tomorrow), locked (later).
function MenuController.dailyTileStates(view: any, count: number?): { TileState }
	local n = math.max(1, math.floor(num(count, #Economy.DAILY_REWARDS)))
	local out: { TileState } = table.create(n, "locked" :: TileState)
	if typeof(view) ~= "table" then
		return out
	end
	local nextDay = math.clamp(math.floor(num(view.nextDay, 1)), 1, n)
	local streak = math.max(0, math.floor(num(view.streak, 0)))
	if view.canClaim == true then
		for i = 1, nextDay - 1 do
			out[i] = "claimed"
		end
		out[nextDay] = "ready"
		return out
	end
	if nextDay == 1 and streak > 0 then
		-- a full week was just completed: everything is claimed, the track restarts tomorrow
		for i = 1, n do
			out[i] = "claimed"
		end
		return out
	end
	for i = 1, nextDay - 1 do
		out[i] = "claimed"
	end
	out[nextDay] = "next"
	return out
end

export type GiftTile = { index: number, state: string, remaining: number, fraction: number }

-- Playtime gift tiles. playtime = snapshot.playtime {claimed: {[tostring(i)]: true}, sessionSeconds};
-- extraSeconds = local time elapsed since that snapshot arrived.
function MenuController.playtimeTiles(playtime: any, extraSeconds: number?): { GiftTile }
	local claimed: any = if typeof(playtime) == "table" and typeof(playtime.claimed) == "table"
		then playtime.claimed
		else {}
	local session = (if typeof(playtime) == "table" then math.max(0, num(playtime.sessionSeconds, 0)) else 0)
		+ math.max(0, num(extraSeconds, 0))
	local out: { GiftTile } = {}
	for i, def in Economy.PLAYTIME_REWARDS do
		local need = math.max(1, def.minutes * 60)
		local state, remaining
		if claimed[tostring(i)] == true or claimed[i] == true then
			state, remaining = "claimed", 0
		elseif session >= need then
			state, remaining = "ready", 0
		else
			state, remaining = "waiting", need - session
		end
		table.insert(
			out,
			{ index = i, state = state, remaining = remaining, fraction = math.clamp(session / need, 0, 1) }
		)
	end
	return out
end

local CONTRACT_BY_ID: { [string]: Economy.ContractDef } = {}
for _, def in Economy.Contracts do
	CONTRACT_BY_ID[def.id] = def
end

local CONTRACT_ICONS: { [string]: string } = {
	steal = "🚗",
	deliverRare = "💎",
	deliverEpic = "🔮",
	playerSteal = "🦹",
	escape3 = "🚨",
	escape = "🚓",
	defend = "🏏",
	collectCash = "💰",
	driftSeconds = "💨",
	topSpeedHit = "🔥",
	chop = "🔧",
	dealerBuy = "🏪",
	hotDrop = "📦",
}

export type ContractRow = {
	id: string,
	text: string,
	stat: string,
	icon: string,
	progress: number,
	goal: number,
	fraction: number,
	done: boolean,
	claimed: boolean,
	rewardSeconds: number,
	rewardCash: number,
	order: number,
}

-- Contract cards from snapshot.contracts ({day, list = {{id, progress, claimed}}}). Unknown ids are skipped.
-- Sort: unfinished first (in the server's order), finished/claimed last. Stable, so cards never jump while you play.
function MenuController.contractRows(contracts: any, incomePerSec: number?): { ContractRow }
	local list = if typeof(contracts) == "table" and typeof(contracts.list) == "table" then contracts.list else {}
	local income = math.max(0, num(incomePerSec, 0))
	local rows: { ContractRow } = {}
	for i, c in ipairs(list) do
		if typeof(c) == "table" and typeof(c.id) == "string" then
			local def = CONTRACT_BY_ID[c.id]
			if def then
				local goal = math.max(1, def.goal)
				local progress = math.clamp(num(c.progress, 0), 0, goal)
				local claimed = c.claimed == true
				local done = claimed or progress >= goal
				table.insert(rows, {
					id = def.id,
					text = def.text,
					stat = def.stat,
					icon = CONTRACT_ICONS[def.stat] or "🎯",
					progress = if done then goal else progress,
					goal = goal,
					fraction = if done then 1 else progress / goal,
					done = done,
					claimed = claimed,
					rewardSeconds = def.reward,
					rewardCash = math.max(MIN_CONTRACT_REWARD, math.floor(def.reward * income)),
					order = i,
				})
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.done ~= b.done then
			return not a.done
		end
		return a.order < b.order
	end)
	return rows
end

-- Daily free contract swap: offered on unfinished cards while today's swap is unused (contracts.rerolled) and the
-- server exposes the remote.
function MenuController.canSwapContract(contracts: any, row: any, remoteAvailable: boolean): boolean
	if not remoteAvailable or typeof(row) ~= "table" or row.done == true then
		return false
	end
	return typeof(contracts) == "table" and contracts.rerolled ~= true
end

-- "3/5", "$4.2K / $10K", "12s / 30s"
function MenuController.contractProgressText(row: ContractRow): string
	if row.stat == "collectCash" then
		return `{Format.cash(row.progress)} / {Format.cash(row.goal)}`
	elseif row.stat == "driftSeconds" then
		return `{math.floor(row.progress)}s / {fmtNum(row.goal)}s`
	end
	return `{math.floor(row.progress)}/{fmtNum(row.goal)}`
end

-- Gear Shop ------------------------------------------------------------------------------------------------------------

MenuController.UPGRADE_ORDER = { "hotwire", "nitro", "armor", "lock" }

type UpgradeStyle = { icon: string, caption: string, color: Color3 }
local UPGRADE_STYLE: { [string]: UpgradeStyle } = {
	hotwire = { icon = "🔧", caption = "HOLD TIME", color = Theme.Colors.Warning },
	nitro = { icon = "🔥", caption = "NITRO TANK", color = Theme.Colors.Primary },
	armor = { icon = "🛡️", caption = "DAMAGE TAKEN", color = Theme.Colors.Secondary },
	lock = { icon = "🔒", caption = "LOCK TIME", color = Theme.Colors.Danger },
}
local DEFAULT_UPGRADE_STYLE: UpgradeStyle = { icon = "⬆️", caption = "LEVEL", color = Theme.Colors.Secondary }

-- Value text for an upgrade at a level: hotwire/armor are multipliers shown as %, lock/nitro are seconds.
function MenuController.upgradeValueText(id: string, value: number): string
	if id == "hotwire" or id == "armor" then
		return `{math.floor(value * 100 + 0.5)}%`
	elseif id == "lock" or id == "nitro" then
		return fmtNum(value) .. "s"
	end
	return fmtNum(value)
end

-- Upgrade ids in display order (UPGRADE_ORDER first, then any new config ids alphabetically).
function MenuController.upgradeIds(): { string }
	local out, seen = {}, {}
	for _, id in MenuController.UPGRADE_ORDER do
		if Economy.Upgrades[id] then
			table.insert(out, id)
			seen[id] = true
		end
	end
	local extra = {}
	for id in Economy.Upgrades do
		if not seen[id] then
			table.insert(extra, id)
		end
	end
	table.sort(extra)
	for _, id in extra do
		table.insert(out, id)
	end
	return out
end

export type UpgradeRow = {
	id: string,
	name: string,
	description: string,
	icon: string,
	caption: string,
	color: Color3,
	level: number,
	maxLevel: number,
	maxed: boolean,
	price: number?,
	affordable: boolean,
	currentText: string,
	nextText: string?,
}

function MenuController.upgradeRows(snapshot: any, cash: number): { UpgradeRow }
	local levels = if typeof(snapshot) == "table" and typeof(snapshot.upgrades) == "table"
		then snapshot.upgrades
		else {}
	local money = num(cash, 0)
	local rows: { UpgradeRow } = {}
	for _, id in MenuController.upgradeIds() do
		local def = Economy.Upgrades[id]
		local level = math.clamp(math.floor(num((levels :: any)[id], 0)), 0, def.maxLevel)
		local maxed = level >= def.maxLevel
		local price = EconomyMath.upgradePrice(id, level)
		local style = UPGRADE_STYLE[id] or DEFAULT_UPGRADE_STYLE
		table.insert(rows, {
			id = id,
			name = def.name,
			description = def.description,
			icon = style.icon,
			caption = style.caption,
			color = style.color,
			level = level,
			maxLevel = def.maxLevel,
			maxed = maxed,
			price = price,
			affordable = price ~= nil and money >= price,
			currentText = MenuController.upgradeValueText(id, EconomyMath.upgradeValue(id, level)),
			nextText = if maxed
				then nil
				else MenuController.upgradeValueText(id, EconomyMath.upgradeValue(id, level + 1)),
		})
	end
	return rows
end

type ToolStyle = { icon: string, color: Color3 }
local TOOL_STYLE: { [string]: ToolStyle } = {
	bat = { icon = "🏏", color = Theme.Colors.Warning },
	taser = { icon = "⚡", color = Theme.Colors.Secondary },
	spikes = { icon = "📌", color = Theme.Colors.Danger },
}

export type ToolRow = {
	id: string,
	name: string,
	description: string,
	icon: string,
	color: Color3,
	price: number,
	cooldown: number,
	owned: boolean,
	affordable: boolean,
}

function MenuController.toolIds(): { string }
	local out, seen = {}, {}
	for _, id in Economy.ToolOrder do
		if Economy.Tools[id] and not seen[id] then
			table.insert(out, id)
			seen[id] = true
		end
	end
	local extra = {}
	for id in Economy.Tools do
		if not seen[id] then
			table.insert(extra, id)
		end
	end
	table.sort(extra)
	for _, id in extra do
		table.insert(out, id)
	end
	return out
end

-- The Zapper counts as owned with the Zapper Pass (CombatService hands it out).
function MenuController.toolRows(snapshot: any, cash: number): { ToolRow }
	local tools: any = if typeof(snapshot) == "table" and typeof(snapshot.tools) == "table" then snapshot.tools else {}
	local passes: any = if typeof(snapshot) == "table" and typeof(snapshot.passes) == "table"
		then snapshot.passes
		else {}
	local money = num(cash, 0)
	local rows: { ToolRow } = {}
	for _, id in MenuController.toolIds() do
		local def = Economy.Tools[id]
		local style = TOOL_STYLE[id] or { icon = "🧰", color = Theme.Colors.Secondary }
		local owned = tools[id] == true or (id == "taser" and passes.taser == true)
		table.insert(rows, {
			id = id,
			name = def.name,
			description = def.description,
			icon = style.icon,
			color = style.color,
			price = def.price,
			cooldown = def.cooldown,
			owned = owned,
			affordable = money >= def.price,
		})
	end
	return rows
end

-- Store ------------------------------------------------------------------------------------------------------------------

export type StoreItem = {
	key: string,
	id: number,
	kind: string, -- "pass" | "product"
	name: string,
	description: string,
	icon: string,
	owned: boolean,
}

-- Store contents in config order. Items with id 0 (not created yet) are hidden; comingSoon when nothing is left.
function MenuController.storeItems(
	ownedPasses: any
): { passes: { StoreItem }, products: { StoreItem }, comingSoon: boolean }
	local owned: any = if typeof(ownedPasses) == "table" then ownedPasses else {}
	local passes: { StoreItem } = {}
	local products: { StoreItem } = {}
	for _, key in Monetization.PassOrder do
		local def = Monetization.Passes[key]
		if def and finite(def.id) and def.id > 0 then
			table.insert(passes, {
				key = key,
				id = def.id,
				kind = "pass",
				name = def.name,
				description = def.description,
				icon = def.icon,
				owned = owned[key] == true,
			})
		end
	end
	for _, key in Monetization.ProductOrder do
		local def = Monetization.Products[key]
		if def and finite(def.id) and def.id > 0 then
			table.insert(products, {
				key = key,
				id = def.id,
				kind = "product",
				name = def.name,
				description = def.description,
				icon = def.icon,
				owned = false,
			})
		end
	end
	return { passes = passes, products = products, comingSoon = #passes == 0 and #products == 0 }
end

-- One-per-account products: product key -> the Exclusive car it grants (MonetizationService refuses a second one).
local ONE_PER_ACCOUNT: { [string]: string } = { diamond_dragster = "diamond_dragster" }

-- Why a Store item can't be bought right now (nil = buyable). Mirrors the server's refusals so nobody is prompted
-- for something that would be refused: "owned" = a pass you own, or a one-per-account car already in your garage;
-- "notWanted" = Lose the Cops with 0 stars.
function MenuController.storeBlock(item: any, snapshot: any, wantedStars: number?): string?
	if typeof(item) ~= "table" then
		return nil
	end
	if item.kind == "pass" then
		local passes: any = if typeof(snapshot) == "table" and typeof(snapshot.passes) == "table"
			then snapshot.passes
			else {}
		return if passes[item.key] == true then "owned" else nil
	end
	if item.key == "clear_wanted" then
		return if num(wantedStars, 0) <= 0 then "notWanted" else nil
	end
	local carId = ONE_PER_ACCOUNT[item.key]
	local garage: any = if typeof(snapshot) == "table" and typeof(snapshot.garage) == "table"
		then snapshot.garage
		else nil
	if carId and garage then
		for _, slot in garage do
			if typeof(slot) == "table" and slot.carId == carId then
				return "owned"
			end
		end
	end
	return nil
end

-- Index ------------------------------------------------------------------------------------------------------------------

export type IndexGroup = {
	rarity: string,
	color: Color3,
	cars: { CarDef },
	found: number,
	total: number,
	complete: boolean,
	bonusEligible: boolean,
}

local function rarityColor(rid: string): Color3
	if rid == "Secret" then
		return SECRET_COLOR
	end
	local tier = (Rarity.Tiers :: any)[rid]
	return if tier then tier.color else Theme.Colors.TextDim
end
MenuController.rarityColor = rarityColor

-- Every catalog car grouped by rarity (Rarity.Order), cheapest income first inside a group.
function MenuController.indexGroups(discovered: any): { IndexGroup }
	local disc: any = if typeof(discovered) == "table" then discovered else {}
	local out: { IndexGroup } = {}
	for _, rid in Rarity.Order do
		local pool = Cars.ByRarity[rid]
		if pool and #pool > 0 then
			local cars = table.clone(pool)
			table.sort(cars, function(a, b)
				if a.income ~= b.income then
					return a.income < b.income
				end
				return a.name < b.name
			end)
			local found = 0
			for _, def in cars do
				if disc[def.id] == true then
					found += 1
				end
			end
			table.insert(out, {
				rarity = rid,
				color = rarityColor(rid),
				cars = cars,
				found = found,
				total = #cars,
				complete = found == #cars,
				bonusEligible = rid ~= "Exclusive",
			})
		end
	end
	return out
end

-- (found, total, incomeBonus) across the whole catalog.
function MenuController.indexTotals(discovered: any): (number, number, number)
	local disc: any = if typeof(discovered) == "table" then discovered else {}
	local found = 0
	for _, def in Cars.List do
		if disc[def.id] == true then
			found += 1
		end
	end
	return found, #Cars.List, EconomyMath.indexBonus(disc)
end

-- Rarities handed out as random car rewards (daily streak, playtime gifts, referrals).
local REWARD_RARITIES: { [string]: boolean } = {}
for _, list in { Economy.DAILY_REWARDS :: { any }, Economy.PLAYTIME_REWARDS :: { any } } do
	for _, reward in list do
		if reward.kind == "car" and typeof(reward.rarity) == "string" then
			REWARD_RARITIES[reward.rarity] = true
		end
	end
end
if typeof(Economy.REFERRAL_REWARD_RARITY) == "string" then
	REWARD_RARITIES[Economy.REFERRAL_REWARD_RARITY] = true
end

-- Where a car can be found, for the Index detail panel.
function MenuController.carSources(def: CarDef): { string }
	local out = {}
	if def.rarity == "Exclusive" then
		table.insert(out, "💎 Store exclusive")
		return out
	end
	if def.street then
		table.insert(out, "🛣️ Streets")
	end
	if def.dealer then
		table.insert(out, "🏪 Dealer")
	end
	local tier = (Rarity.Tiers :: any)[def.rarity]
	if tier and tier.order >= 5 then
		table.insert(out, "📦 Hot Drops")
	end
	if REWARD_RARITIES[def.rarity] then
		table.insert(out, "🎁 Rewards")
	end
	if #out == 0 then
		table.insert(out, "❓ Somewhere...")
	end
	return out
end

-- Camera CFrame that frames a box of `size` centered at `center` (yaw 0 = looking at the car's front, which faces -Z).
function MenuController.cameraCFrame(
	center: Vector3,
	size: Vector3,
	fovDeg: number,
	yawDeg: number,
	pitchDeg: number?
): CFrame
	local radius = math.max(size.Magnitude * 0.5, 0.5)
	local dist = radius / math.sin(math.rad(math.clamp(fovDeg, 5, 120)) * 0.5) * FRAME_TIGHTNESS
	local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg or CARD_PITCH)
	local dir = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch))
	return CFrame.lookAt(center + dir * dist, center)
end

-- Rebirth ----------------------------------------------------------------------------------------------------------------

export type RebirthView = {
	rebirths: number,
	cost: number,
	cash: number,
	fraction: number,
	canAfford: boolean,
	missing: number,
	multiplier: number,
	nextMultiplier: number,
}

function MenuController.rebirthView(cash: number, rebirths: number): RebirthView
	local r = math.max(0, math.floor(num(rebirths, 0)))
	local c = math.max(0, num(cash, 0))
	local cost = EconomyMath.rebirthCost(r)
	return {
		rebirths = r,
		cost = cost,
		cash = c,
		fraction = if cost > 0 then math.clamp(c / cost, 0, 1) else 1,
		canAfford = c >= cost,
		missing = math.max(0, cost - c),
		multiplier = 1 + r * Economy.REBIRTH_INCOME_BONUS,
		nextMultiplier = 1 + (r + 1) * Economy.REBIRTH_INCOME_BONUS,
	}
end

export type KeptCar = { carId: string, mutation: string }

-- The regular cars a rebirth keeps, mirroring RebirthService._plan: the best `keep` (default
-- Economy.REBIRTH_KEEP_CARS) non-Exclusive cars by income, ties -> lowest slot. Robux Exclusives are always kept on
-- top and never count toward the limit, so they are not listed here.
function MenuController.keptCars(garage: any, keep: number?): { KeptCar }
	if typeof(garage) ~= "table" then
		return {}
	end
	local entries: { { carId: string, mutation: string, income: number, slot: number } } = {}
	for key, slot in garage do
		local def = if typeof(slot) == "table" and typeof(slot.carId) == "string" then Cars.get(slot.carId) else nil
		if def and def.rarity ~= "Exclusive" then
			local mut = if typeof(slot.mutation) == "string" then slot.mutation else "None"
			table.insert(entries, {
				carId = slot.carId,
				mutation = mut,
				income = EconomyMath.carIncome(slot.carId, mut :: any),
				slot = tonumber(key) or math.huge,
			})
		end
	end
	table.sort(entries, function(a, b)
		if a.income ~= b.income then
			return a.income > b.income
		end
		return a.slot < b.slot
	end)
	local limit = math.max(1, math.floor(num(keep, Economy.REBIRTH_KEEP_CARS)))
	local out: { KeptCar } = {}
	for i = 1, math.min(limit, #entries) do
		table.insert(out, { carId = entries[i].carId, mutation = entries[i].mutation })
	end
	return out
end

-- The best car a rebirth keeps (first of keptCars). Returns (carId, mutation).
function MenuController.bestCar(garage: any): (string?, string?)
	local best = MenuController.keptCars(garage, 1)[1]
	if not best then
		return nil, nil
	end
	return best.carId, best.mutation
end

-- "Gold Hot Hatch + Rustbucket" for the Rebirth menu's keep list ("" when nothing would be kept).
function MenuController.keptCarsText(kept: { KeptCar }): string
	local names: { string } = {}
	for _, k in kept do
		local def = Cars.get(k.carId)
		local mut = (Rarity.Mutations :: any)[k.mutation]
		local label = if mut and mut.label ~= "" then mut.label .. " " else ""
		table.insert(names, label .. (if def then def.name else k.carId))
	end
	return table.concat(names, " + ")
end

-- RebirthService refuses while a garage car is out driving or being stolen.
function MenuController.garageBusy(garage: any): boolean
	if typeof(garage) ~= "table" then
		return false
	end
	for _, slot in garage do
		if typeof(slot) == "table" and (slot.state == "Driving" or slot.state == "BeingStolen") then
			return true
		end
	end
	return false
end

-- Settings ---------------------------------------------------------------------------------------------------------------

-- Displayed value of a setting: optimistic local override, else the snapshot, else the default.
function MenuController.settingValue(settings: any, overrides: any, key: string): boolean
	if typeof(overrides) == "table" and typeof(overrides[key]) == "boolean" then
		return overrides[key]
	end
	if typeof(settings) == "table" and typeof(settings[key]) == "boolean" then
		return settings[key]
	end
	return DEFAULT_SETTINGS[key] == true
end

-- Layout -----------------------------------------------------------------------------------------------------------------

-- Extra scale for a window on top of Kit.screen's UIScale. Kit clamps its scale at 0.55, which leaves menu text tiny
-- on phones, so windows grow to use the free screen there (up to SMALL_SCREEN_MAX_SCALE). They never grow on
-- normal screens, and shrink only when they would not fit at all.
local SMALL_SCREEN_HEIGHT = 500 -- real pixels; below this we are on a phone in landscape
local SMALL_SCREEN_MAX_SCALE = 1.4
function MenuController.windowScale(viewport: Vector2, uiScale: number, winSize: Vector2): number
	local s = if finite(uiScale) and uiScale > 0 then uiScale else 1
	if viewport.X < 1 or viewport.Y < 1 or winSize.X < 1 or winSize.Y < 1 then
		return 1
	end
	local designW, designH = viewport.X / s, viewport.Y / s
	local fit = math.min(designW * 0.96 / winSize.X, designH * 0.9 / winSize.Y)
	local maxScale = if viewport.Y < SMALL_SCREEN_HEIGHT then SMALL_SCREEN_MAX_SCALE else 1
	return math.clamp(fit, 0.5, maxScale)
end

-------------------------------------------------------------------------------------------------------------------------
-- Runtime state
-------------------------------------------------------------------------------------------------------------------------

type Ctx = {
	name: string,
	size: Vector2, -- design size of the window
	win: Frame,
	body: ScrollingFrame,
	closeButton: TextButton,
	open: boolean,
	openToken: number,
	session: any, -- Trove: cleaned on every open/close
	ui: any,
	primary: GuiObject?,
	refresh: ((Ctx, any) -> ())?,
	tick: ((Ctx) -> ())?,
	onOpen: ((Ctx) -> ())?,
	onClose: ((Ctx) -> ())?,
}

type PageDef = { title: string, accent: Color3, size: Vector2 }

local PAGE_DEFS: { [string]: PageDef } = {
	GearShop = { title = "🔧 GEAR SHOP", accent = Theme.Colors.Secondary, size = Vector2.new(780, 548) },
	Store = { title = "🛒 STORE", accent = Theme.Colors.Gold, size = Vector2.new(780, 520) },
	Index = { title = "📖 CAR INDEX", accent = PURPLE, size = Vector2.new(920, 540) },
	Daily = { title = "🎁 DAILY REWARDS", accent = Theme.Colors.Primary, size = Vector2.new(760, 470) },
	Contracts = { title = "🎯 CONTRACTS", accent = Theme.Colors.Warning, size = Vector2.new(680, 500) },
	Gifts = { title = "⏰ FREE GIFTS", accent = Theme.Colors.Cash, size = Vector2.new(760, 516) },
	Rebirth = { title = "♻️ REBIRTH", accent = REBIRTH_COLOR, size = Vector2.new(680, 548) },
	Codes = { title = "🎟️ CODES", accent = Theme.Colors.Secondary, size = Vector2.new(540, 330) },
	Settings = { title = "⚙️ SETTINGS", accent = SETTINGS_COLOR, size = Vector2.new(560, 530) },
}

local BUILDERS: { [string]: (Ctx) -> () } = {}

local gui: ScreenGui? = nil
local backdrop: TextButton? = nil
local pages: { [string]: Ctx } = {}
local current: string? = nil
local started = false
local refreshQueued = false
local playtimeBase: any = nil -- snapshot.playtime as last received
local playtimeAt = os.clock() -- os.clock() when it arrived
local settingOverrides: { [string]: { value: boolean, at: number } } = {}
local priceCache: { [string]: number | boolean } = {} -- "pass:123" -> Robux price, or false while unknown

-------------------------------------------------------------------------------------------------------------------------
-- Lazy dependencies (other controllers are written in parallel; any of them may be missing)
-------------------------------------------------------------------------------------------------------------------------

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require :: any, mod)
	return if ok then result else nil
end

local function playSound(key: string)
	local sounds = lazy("SoundController")
	if sounds and typeof(sounds.play) == "function" then
		pcall(sounds.play, key)
	end
end

local function toast(kind: string, text: string)
	local notes = lazy("NotificationController")
	if notes and typeof(notes.toast) == "function" then
		pcall(notes.toast, kind, text)
	end
end

local function getSnapshot(): any
	return StateController.get()
end

local function attrNumber(name: string): number?
	local v = player:GetAttribute(name)
	return if finite(v) then v :: number else nil
end

local function currentCash(): number
	local a = attrNumber("Cash")
	if a then
		return a
	end
	local s = getSnapshot()
	return if s then num(s.cash, 0) else 0
end

local function currentIncome(): number
	local a = attrNumber("IncomePerSec")
	if a then
		return a
	end
	local s = getSnapshot()
	return if s then num(s.incomePerSec, 0) else 0
end

local function currentRebirths(): number
	local a = attrNumber("Rebirths")
	if a then
		return a
	end
	local s = getSnapshot()
	return if s then num(s.rebirths, 0) else 0
end

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and finite(t) then t else os.time()
end

-------------------------------------------------------------------------------------------------------------------------
-- UI helpers
-------------------------------------------------------------------------------------------------------------------------

local function apply(inst: any, props: Kit.Props?)
	if props then
		for k, v in props do
			inst[k] = v
		end
	end
end

local function mix(a: Color3, b: Color3, t: number): Color3
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

-- Small body-copy text (Gotham, no outline).
local function bodyLabel(text: string, size: number, props: Kit.Props?): TextLabel
	local lbl = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		FontFace = Theme.Fonts.Body,
		TextColor3 = Theme.Colors.TextDim,
		TextWrapped = true,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, size + 6),
	})
	apply(lbl, props)
	return lbl
end

-- Display label that shrinks long strings to fit (max = size).
local function fitLabel(text: string, size: number, props: Kit.Props?): TextLabel
	local lbl = Kit.label(text, size, { TextScaled = true, TextWrapped = false })
	Kit.new("UITextSizeConstraint", { MaxTextSize = size, MinTextSize = math.max(8, size - 8), Parent = lbl })
	apply(lbl, props)
	return lbl
end

-- Lighter rounded card for content inside a window.
local function card(props: Kit.Props?): Frame
	local f = Kit.new("Frame", { BackgroundColor3 = Theme.Colors.PanelLight, BorderSizePixel = 0 })
	Kit.corner().Parent = f
	Kit.stroke().Parent = f
	Kit.gradient(WHITE, Color3.fromRGB(196, 196, 214)).Parent = f
	apply(f, props)
	return f
end

-- Rounded square with a big emoji.
local function iconTile(icon: string, color: Color3, size: number, props: Kit.Props?): Frame
	local f = Kit.new("Frame", {
		Name = "IconTile",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
	})
	Kit.corner(UDim.new(0, math.floor(size * 0.26))).Parent = f
	Kit.stroke(Theme.Colors.Stroke, 3).Parent = f
	Kit.gradient(WHITE, Color3.fromRGB(150, 150, 168)).Parent = f
	Kit.new("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		Text = icon,
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		TextColor3 = WHITE,
		Parent = f,
	})
	apply(f, props)
	return f
end

-- Pill with outlined text; returns (frame, label).
local function chip(text: string, color: Color3, size: number?, props: Kit.Props?): (Frame, TextLabel)
	local s = size or 14
	local f = Kit.new("Frame", {
		Name = "Chip",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, s + 12),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	Kit.corner(UDim.new(1, 0)).Parent = f
	Kit.stroke(Theme.Colors.Stroke, 2).Parent = f
	Kit.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = f })
	local lbl = Kit.label(text, s, {
		Name = "Text",
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		Parent = f,
	})
	apply(f, props)
	return f, lbl
end

local function setButton(btn: TextButton, text: string, color: Color3, enabled: boolean, keepColor: boolean?)
	btn.Text = text
	btn.BackgroundColor3 = if enabled or keepColor then color else Theme.Colors.Disabled
	btn.TextColor3 = if enabled or keepColor then WHITE else DIM_TEXT
	btn:SetAttribute("Disabled", not enabled)
end

local SHAKE_INFO = TweenInfo.new(0.05, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 2, true)
local function shake(target: GuiObject)
	target.Rotation = 0
	TweenService:Create(target, SHAKE_INFO, { Rotation = 5 }):Play()
end

-- Activated handler with click sound, disabled-shake and a tiny double-tap guard.
local function onPress(btn: GuiButton, fn: () -> ())
	btn.Activated:Connect(function()
		if btn:GetAttribute("Disabled") == true then
			playSound("Click")
			shake(btn)
			return
		end
		local now = os.clock()
		local ready = btn:GetAttribute("ReadyAt")
		if typeof(ready) == "number" and now < ready then
			return
		end
		btn:SetAttribute("ReadyAt", now + 0.25)
		playSound("Click")
		fn()
	end)
end

-- Floating "+LEVEL!" style text that rises and fades over a gui.
local FLOAT_INFO = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local function floatText(parent: GuiObject, text: string, color: Color3)
	local lbl = Kit.label(text, 28, {
		Name = "Float",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(280, 36),
		TextColor3 = color,
		ZIndex = 20,
		Parent = parent,
	})
	Kit.pop(lbl, 1.5)
	TweenService:Create(lbl, FLOAT_INFO, { Position = UDim2.fromScale(0.5, -0.15), TextTransparency = 1 }):Play()
	local stroke = lbl:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, FLOAT_INFO, { Transparency = 1 }):Play()
	end
	task.delay(1, function()
		lbl:Destroy()
	end)
end

-- Looping glow on a gui's first UIStroke (claimable things). Restores the stroke when turned off.
local PULSE_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
type Pulse = { tween: Tween, color: Color3, thickness: number }
local pulses: { [Instance]: Pulse } = setmetatable({}, { __mode = "k" }) :: any
local function setPulse(target: GuiObject, on: boolean, color: Color3?)
	local stroke = target:FindFirstChildOfClass("UIStroke")
	if not stroke then
		return
	end
	local existing = pulses[target]
	if on then
		if existing then
			return
		end
		local tween = TweenService:Create(stroke, PULSE_INFO, { Thickness = 6, Color = color or WHITE })
		pulses[target] = { tween = tween, color = stroke.Color, thickness = stroke.Thickness }
		tween:Play()
	elseif existing then
		existing.tween:Cancel()
		pulses[target] = nil
		stroke.Color = existing.color
		stroke.Thickness = existing.thickness
	end
end

-- Vertical list helper for window bodies.
local function vlist(parent: Instance, padding: number?, hAlign: Enum.HorizontalAlignment?)
	Kit.list(Enum.FillDirection.Vertical, padding or 10, hAlign or Enum.HorizontalAlignment.Center).Parent = parent
end

local function autoFrame(name: string, order: number, parent: Instance): Frame
	return Kit.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
end

local function grid(parent: Instance, cell: Vector2, pad: number)
	Kit.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(cell.X, cell.Y),
		CellPadding = UDim2.fromOffset(pad, pad),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = parent,
	})
end

-------------------------------------------------------------------------------------------------------------------------
-- Gear Shop
-------------------------------------------------------------------------------------------------------------------------

-- Fixed tab bar under the window header; moves the body below it. Returns select(i).
local function makeTabs(ctx: Ctx, labels: { string }, accent: Color3, onSelect: (number) -> ()): (number) -> ()
	local bar = Kit.new("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 64),
		Size = UDim2.new(1, -28, 0, 46),
		Parent = ctx.win,
	})
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		bar
	ctx.body.Position = UDim2.fromOffset(0, 114)
	ctx.body.Size = UDim2.new(1, 0, 1, -118)
	local buttons: { TextButton } = {}
	local function selectTab(i: number)
		for j, b in buttons do
			b.BackgroundColor3 = if j == i then accent else Theme.Colors.Panel
			b.TextColor3 = if j == i then WHITE else Theme.Colors.TextDim
		end
		onSelect(i)
	end
	for i, text in labels do
		local b = Kit.button(text, Theme.Colors.Panel, {
			Name = "Tab" .. i,
			Size = UDim2.fromOffset(220, 44),
			TextSize = 22,
			LayoutOrder = i,
			Parent = bar,
		})
		table.insert(buttons, b)
		onPress(b, function()
			selectTab(i)
		end)
	end
	return selectTab
end

local function buildUpgradeCard(parent: Instance, row: UpgradeRow, order: number): any
	local c = card({ Name = row.id, Size = UDim2.new(1, 0, 0, 92), LayoutOrder = order, Parent = parent })
	iconTile(row.icon, row.color, 72, { Position = UDim2.fromOffset(12, 10), Parent = c })
	Kit.label(row.name, 24, {
		Name = "Title",
		Position = UDim2.fromOffset(98, 6),
		Size = UDim2.new(1, -430, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = c,
	})
	bodyLabel(row.description, 14, {
		Name = "Description",
		Position = UDim2.fromOffset(98, 34),
		Size = UDim2.new(1, -430, 0, 34),
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = c,
	})
	local pipRow = Kit.new("Frame", {
		Name = "Pips",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(98, 70),
		Size = UDim2.new(1, -430, 0, 16),
		Parent = c,
	})
	Kit.list(Enum.FillDirection.Horizontal, 5, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		pipRow
	local pips: { Frame } = {}
	for i = 1, row.maxLevel do
		local pip = Kit.new("Frame", {
			Name = "Pip" .. i,
			BackgroundColor3 = PIP_EMPTY,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(30, 14),
			LayoutOrder = i,
			Parent = pipRow,
		})
		Kit.corner(UDim.new(1, 0)).Parent = pip
		Kit.stroke(Theme.Colors.Stroke, 2).Parent = pip
		table.insert(pips, pip)
	end
	local levelLabel = Kit.label("LV 0", 15, {
		Name = "Level",
		Size = UDim2.fromOffset(70, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 100,
		Parent = pipRow,
	})
	bodyLabel(row.caption, 13, {
		Name = "Caption",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -178, 0, 16),
		Size = UDim2.fromOffset(154, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = c,
	})
	local valueLabel = Kit.label("", 24, {
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -178, 0, 36),
		Size = UDim2.fromOffset(154, 30),
		TextWrapped = false,
		Parent = c,
	})
	local button = Kit.button("$0", Theme.Colors.Cash, {
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(152, 56),
		TextSize = 26,
		Parent = c,
	})
	local id = row.id
	onPress(button, function()
		Net.fire("BuyUpgrade", id)
		Kit.pop(button, 0.88)
	end)
	return { card = c, pips = pips, level = levelLabel, value = valueLabel, button = button, color = row.color }
end

local function buildToolCard(parent: Instance, row: ToolRow, order: number): any
	local c = card({ Name = row.id, LayoutOrder = order, Parent = parent })
	iconTile(row.icon, row.color, 104, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Parent = c,
	})
	Kit.label(
		row.name,
		26,
		{ Name = "Title", Position = UDim2.fromOffset(8, 124), Size = UDim2.new(1, -16, 0, 30), Parent = c }
	)
	bodyLabel(row.description, 14, {
		Name = "Description",
		Position = UDim2.fromOffset(12, 158),
		Size = UDim2.new(1, -24, 0, 56),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = c,
	})
	chip(`⏱️ {fmtNum(row.cooldown)}s cooldown`, Theme.Colors.Background, 14, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 216),
		Parent = c,
	})
	local button = Kit.button("", Theme.Colors.Cash, {
		Name = "Buy",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(190, 54),
		TextSize = 24,
		Parent = c,
	})
	local badge = chip("OWNED", Theme.Colors.Cash, 15, {
		Name = "Owned",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 8),
		Rotation = 10,
		Visible = false,
		ZIndex = 5,
		Parent = c,
	})
	local id = row.id
	onPress(button, function()
		Net.fire("BuyTool", id)
		Kit.pop(button, 0.88)
	end)
	return { card = c, button = button, badge = badge }
end

local function refreshGearShop(ctx: Ctx, snapshot: any)
	local ui = ctx.ui
	local cash = currentCash()
	for _, row in MenuController.upgradeRows(snapshot, cash) do
		local u = ui.upgrades[row.id]
		if u then
			for i, pip in u.pips do
				pip.BackgroundColor3 = if i <= row.level then row.color else PIP_EMPTY
			end
			u.level.Text = if row.maxed then "MAX!" else `LV {row.level}/{row.maxLevel}`
			if row.nextText then
				u.value.Text =
					`<font color="#{HEX_DIM}">{row.currentText}</font> → <font color="#{HEX_CASH}">{row.nextText}</font>`
			else
				u.value.Text = `<font color="#{HEX_GOLD}">{row.currentText}</font>`
			end
			if row.maxed then
				setButton(u.button, "MAX ⭐", Theme.Colors.Gold, false, true)
			else
				setButton(u.button, Format.cash(row.price or 0), Theme.Colors.Cash, row.affordable)
			end
			if u.lastLevel ~= nil and row.level > u.lastLevel then
				Kit.pop(u.card, 1.04)
				floatText(u.card, "LEVEL UP!", row.color)
			end
			u.lastLevel = row.level
		end
	end
	for _, row in MenuController.toolRows(snapshot, cash) do
		local t = ui.tools[row.id]
		if t then
			t.badge.Visible = row.owned
			if row.owned then
				setButton(t.button, "✅ OWNED", Theme.Colors.CashDark, false, true)
			elseif row.price <= 0 then
				setButton(t.button, "FREE", Theme.Colors.Cash, true)
			else
				setButton(t.button, Format.cash(row.price), Theme.Colors.Cash, row.affordable)
			end
			if t.lastOwned == false and row.owned then
				Kit.pop(t.card, 1.05)
				floatText(t.card, "NEW TOOL!", row.color)
			end
			t.lastOwned = row.owned
		end
	end
end

BUILDERS.GearShop = function(ctx: Ctx)
	local ui = { upgrades = {}, tools = {} }
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 10)
	local upgradesFrame = autoFrame("Upgrades", 1, body)
	vlist(upgradesFrame, 10)
	for i, row in MenuController.upgradeRows(nil, 0) do
		ui.upgrades[row.id] = buildUpgradeCard(upgradesFrame, row, i)
	end
	local toolsFrame = autoFrame("Tools", 2, body)
	toolsFrame.Visible = false
	vlist(toolsFrame, 12)
	local toolGrid = autoFrame("Grid", 1, toolsFrame)
	grid(toolGrid, Vector2.new(234, 312), 10)
	for i, row in MenuController.toolRows(nil, 0) do
		ui.tools[row.id] = buildToolCard(toolGrid, row, i)
	end
	bodyLabel("🎒 Tools go in your hotbar. Bonk thieves out of your cars to get them back!", 15, {
		Name = "Tip",
		LayoutOrder = 2,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = toolsFrame,
	})
	local selectTab = makeTabs(ctx, { "🔧 UPGRADES", "🧰 TOOLS" }, Theme.Colors.Secondary, function(i)
		upgradesFrame.Visible = i == 1
		toolsFrame.Visible = i == 2
		ctx.body.CanvasPosition = Vector2.zero
	end)
	selectTab(1)
	ui.selectTab = selectTab
	ctx.refresh = refreshGearShop
end

-------------------------------------------------------------------------------------------------------------------------
-- Store (Robux)
-------------------------------------------------------------------------------------------------------------------------

local function promptPurchase(item: StoreItem)
	local ok, err = pcall(function()
		if item.kind == "pass" then
			MarketplaceService:PromptGamePassPurchase(player, item.id)
		else
			MarketplaceService:PromptProductPurchase(player, item.id)
		end
	end)
	if not ok then
		warn("[MenuController] purchase prompt failed: " .. tostring(err))
		toast("error", "The store isn't available right now. Try again in a moment!")
	end
end

local function priceKey(item: StoreItem): string
	return item.kind .. ":" .. tostring(item.id)
end

-- Fetches a Robux price once (GetProductInfoAsync); calls done() when it becomes known.
local function fetchPrice(item: StoreItem, done: () -> ())
	local key = priceKey(item)
	if priceCache[key] ~= nil then
		return
	end
	priceCache[key] = false
	task.spawn(function()
		local ok, info = pcall(function()
			local infoType = if item.kind == "pass" then Enum.InfoType.GamePass else Enum.InfoType.Product
			return (MarketplaceService :: any):GetProductInfoAsync(item.id, infoType)
		end)
		if ok and typeof(info) == "table" and finite(info.PriceInRobux) then
			priceCache[key] = info.PriceInRobux
			done()
		end
	end)
end

local function buildStoreCard(parent: Instance, item: StoreItem, order: number): any
	local accent = if item.kind == "pass" then Theme.Colors.Gold else Theme.Colors.Secondary
	local c = card({ Name = item.key, LayoutOrder = order, Parent = parent })
	iconTile(
		item.icon,
		accent,
		72,
		{ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Parent = c }
	)
	fitLabel(
		item.name,
		22,
		{ Name = "Title", Position = UDim2.fromOffset(8, 90), Size = UDim2.new(1, -16, 0, 26), Parent = c }
	)
	bodyLabel(item.description, 13, {
		Name = "Description",
		Position = UDim2.fromOffset(12, 118),
		Size = UDim2.new(1, -24, 0, 46),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = c,
	})
	local button = Kit.button("BUY", Theme.Colors.Cash, {
		Name = "Buy",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.fromOffset(178, 48),
		TextSize = 24,
		Parent = c,
	})
	onPress(button, function()
		-- re-checked at tap time: the button may not have refreshed yet (e.g. stars just ran out)
		if MenuController.storeBlock(item, getSnapshot(), attrNumber("Wanted")) ~= nil then
			shake(button)
			return
		end
		promptPurchase(item)
	end)
	return { card = c, button = button, item = item }
end

local function refreshStore(ctx: Ctx, snapshot: any)
	local wanted = attrNumber("Wanted")
	for _, entry in ctx.ui.cards do
		local item: StoreItem = entry.item
		local block = MenuController.storeBlock(item, snapshot, wanted)
		if block == "owned" then
			setButton(entry.button, "✅ OWNED", Theme.Colors.CashDark, false, true)
		elseif block == "notWanted" then
			setButton(entry.button, "😇 NOT WANTED", Theme.Colors.Cash, false)
		else
			local price = priceCache[priceKey(item)]
			setButton(
				entry.button,
				if typeof(price) == "number" then `R$ {price}` else "R$ BUY",
				Theme.Colors.Cash,
				true
			)
		end
	end
end

local function sectionHeader(parent: Instance, text: string, sub: string, color: Color3, order: number)
	local row = Kit.new("Frame", {
		Name = "Header" .. order,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		row
	Kit.label(text, 26, {
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		TextColor3 = color,
		LayoutOrder = 1,
		Parent = row,
	})
	bodyLabel(sub, 15, { Size = UDim2.new(0, 260, 1, 0), LayoutOrder = 2, Parent = row })
end

BUILDERS.Store = function(ctx: Ctx)
	local ui = { cards = {} }
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 12)
	local items = MenuController.storeItems(nil)
	if items.comingSoon then
		local c = card({ Name = "ComingSoon", Size = UDim2.new(1, 0, 0, 300), LayoutOrder = 1, Parent = body })
		iconTile("🚧", Theme.Colors.Gold, 110, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 24),
			Parent = c,
		})
		Kit.label("STORE COMING SOON!", 38, {
			Position = UDim2.fromOffset(0, 148),
			Size = UDim2.new(1, 0, 0, 44),
			TextColor3 = Theme.Colors.Gold,
			Parent = c,
		})
		bodyLabel(
			"Passes and boosts are on the way. Until then, every car in Hotwire City is earned on the streets. Go steal something shiny! 🚗💨",
			17,
			{
				Position = UDim2.fromOffset(60, 200),
				Size = UDim2.new(1, -120, 0, 70),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = Theme.Colors.Text,
				Parent = c,
			}
		)
		-- Point players at the free stuff instead of a dead end.
		local row = Kit.new("Frame", {
			Name = "FreeStuff",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 70),
			LayoutOrder = 2,
			Parent = body,
		})
		Kit.list(Enum.FillDirection.Horizontal, 16, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
			row
		for i, link in
			{
				{ "🎟️ ENTER A CODE", Theme.Colors.Secondary, "Codes" },
				{ "🎁 FREE DAILY GIFT", Theme.Colors.Primary, "Daily" },
			}
		do
			local b = Kit.button(link[1] :: string, link[2] :: Color3, {
				Name = link[3] :: string,
				Size = UDim2.fromOffset(270, 58),
				TextSize = 24,
				LayoutOrder = i,
				Parent = row,
			})
			onPress(b, function()
				MenuController.open(link[3] :: string)
			end)
		end
		ctx.refresh = nil
		return
	end
	bodyLabel("💎 Optional extras. No loot boxes: you always know exactly what you get.", 15, {
		Name = "Intro",
		LayoutOrder = 1,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = body,
	})
	local order = 2
	local function section(list: { StoreItem }, title: string, sub: string, color: Color3)
		if #list == 0 then
			return
		end
		sectionHeader(body, title, sub, color, order)
		local holder = autoFrame("Grid" .. order, order + 1, body)
		grid(holder, Vector2.new(236, 222), 10)
		for i, item in list do
			table.insert(ui.cards, buildStoreCard(holder, item, i))
		end
		order += 2
	end
	section(items.passes, "⭐ GAME PASSES", "yours forever", Theme.Colors.Gold)
	section(items.products, "⚡ BOOSTS", "one-time use", Theme.Colors.Secondary)
	ctx.refresh = refreshStore
	ctx.onOpen = function(c: Ctx)
		for _, entry in c.ui.cards do
			fetchPrice(entry.item, function()
				if c.open then
					refreshStore(c, getSnapshot())
				end
			end)
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Car Index
-------------------------------------------------------------------------------------------------------------------------

local STAT_MAX = { speed = 1, accel = 1 }
for _, def in Cars.List do
	STAT_MAX.speed = math.max(STAT_MAX.speed, def.topSpeed)
	STAT_MAX.accel = math.max(STAT_MAX.accel, def.accel)
end

local function isDiscovered(id: string): boolean
	local s = getSnapshot()
	return s ~= nil and typeof(s.discovered) == "table" and s.discovered[id] == true
end

local function buildCarModel(carId: string): Model?
	local ok, model = pcall(function()
		local CarBuilder = (require :: any)(Shared:WaitForChild("Vehicle"):WaitForChild("CarBuilder"))
		return CarBuilder.build(carId, "None", { forDisplay = true })
	end)
	if ok and typeof(model) == "Instance" and model:IsA("Model") then
		return model
	end
	if not ok then
		warn("[MenuController] Index preview failed for " .. carId .. ": " .. tostring(model))
	end
	return nil
end

-- Parents `model` into `view`, reuses `camera` (or creates the viewport's Camera) and frames the model.
-- Returns (camera, center, size). The camera is tracked by the caller, never read back from view.CurrentCamera.
local function attachModel(
	view: ViewportFrame,
	model: Model,
	yaw: number,
	pitch: number,
	camera: Camera?
): (Camera, Vector3, Vector3)
	model.Parent = view
	local cam: Camera
	if camera and camera.Parent == view then
		cam = camera
	else
		cam = Instance.new("Camera")
		cam.FieldOfView = VIEW_FOV
		cam.Parent = view
		view.CurrentCamera = cam
	end
	local cf, size = model:GetBoundingBox()
	local center = cf.Position
	cam.CFrame = MenuController.cameraCFrame(center, size, VIEW_FOV, yaw, pitch)
	return cam, center, size
end

local function makeViewport(props: Kit.Props?): ViewportFrame
	local vp = Kit.new("ViewportFrame", {
		Name = "View",
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(150, 150, 170),
		LightColor = WHITE,
		LightDirection = Vector3.new(-0.5, -1, -0.6),
	})
	Kit.corner(Theme.CornerSmall).Parent = vp
	apply(vp, props)
	return vp
end

-- Model needed for a card? Undiscovered Secret cars stay a "❓" (no silhouette) to keep the mystery.
local function needsModel(def: CarDef, discovered: boolean): boolean
	return discovered or def.rarity ~= "Secret"
end

local function ensureCardModel(entry: any)
	if entry.model or entry.failed then
		return
	end
	local model = buildCarModel(entry.def.id)
	if not model then
		entry.failed = true
		return
	end
	entry.model = model
	entry.camera, entry.center, entry.size = attachModel(entry.view, model, CARD_YAW, CARD_PITCH, entry.camera)
end

local function styleIndexCard(ctx: Ctx, entry: any, discovered: boolean)
	local def: CarDef = entry.def
	local selected = ctx.ui.selected == def.id
	entry.stroke.Color = if selected then WHITE else rarityColor(def.rarity)
	entry.stroke.Thickness = if selected then 5 else 3
	entry.view.ImageColor3 = if discovered then WHITE else SILHOUETTE
	entry.mystery.Visible = not needsModel(def, discovered)
	entry.name.Text = if discovered then def.name else "???"
	entry.name.TextColor3 = if discovered then WHITE else Theme.Colors.TextDim
	entry.income.Text = if discovered then `{Format.cash(def.income)}/s` else "$?/s"
	entry.income.TextColor3 = if discovered then Theme.Colors.Cash else Theme.Colors.Disabled
	entry.button.BackgroundColor3 = if discovered then Theme.Colors.PanelLight else Theme.Colors.Panel
end

local updateIndexDetail: (Ctx) -> () -- forward declaration

local function selectCar(ctx: Ctx, id: string)
	local ui = ctx.ui
	local previous = ui.selected
	ui.selected = id
	for _, cid in { previous, id } do
		local entry = cid and ui.cards[cid]
		if entry then
			styleIndexCard(ctx, entry, isDiscovered(cid))
		end
	end
	local entry = ui.cards[id]
	if entry then
		Kit.pop(entry.button, 1.08)
	end
	updateIndexDetail(ctx)
end

local function buildIndexCard(ctx: Ctx, parent: Instance, def: CarDef, order: number): any
	local button = Kit.new("TextButton", {
		Name = def.id,
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Theme.Colors.PanelLight,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.corner(Theme.CornerSmall).Parent = button
	local stroke = Kit.stroke(rarityColor(def.rarity), 3)
	stroke.Parent = button
	Kit.gradient(WHITE, Color3.fromRGB(190, 190, 208)).Parent = button
	local view = makeViewport({
		BackgroundColor3 = mix(rarityColor(def.rarity), Theme.Colors.Background, 0.72),
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.new(1, -12, 0, 80),
		Parent = button,
	})
	local mystery = Kit.label("❓", 40, {
		Name = "Mystery",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = view,
	})
	local name = fitLabel(def.name, 16, {
		Name = "CarName",
		Position = UDim2.fromOffset(4, 90),
		Size = UDim2.new(1, -8, 0, 22),
		Parent = button,
	})
	local income = Kit.label("", 15, {
		Name = "Income",
		Position = UDim2.fromOffset(4, 113),
		Size = UDim2.new(1, -8, 0, 20),
		Parent = button,
	})
	Kit.juice(button)
	local entry = {
		def = def,
		button = button,
		stroke = stroke,
		view = view,
		mystery = mystery,
		name = name,
		income = income,
		model = nil :: Model?,
		camera = nil :: Camera?,
		center = nil :: Vector3?,
		size = nil :: Vector3?,
		failed = false,
		discovered = nil :: boolean?,
	}
	button.MouseEnter:Connect(function()
		ctx.ui.hovered = def.id
	end)
	button.MouseLeave:Connect(function()
		if ctx.ui.hovered == def.id then
			ctx.ui.hovered = nil
		end
	end)
	onPress(button, function()
		selectCar(ctx, def.id)
	end)
	return entry
end

local function buildIndexDetail(ctx: Ctx): any
	local panel = card({
		Name = "Detail",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 66),
		Size = UDim2.new(0, INDEX_DETAIL_W, 1, -78),
		Parent = ctx.win,
	})
	local view = makeViewport({ Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 0, 150), Parent = panel })
	local mystery = Kit.label("❓", 80, {
		Name = "Mystery",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = view,
	})
	local name = fitLabel("TAP A CAR", 26, {
		Name = "CarName",
		Position = UDim2.fromOffset(10, 166),
		Size = UDim2.new(1, -20, 0, 30),
		Parent = panel,
	})
	local rarityChip, rarityText = chip("COMMON", Theme.Colors.Panel, 14, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 198),
		Parent = panel,
	})
	local flavor = bodyLabel("", 14, {
		Name = "Flavor",
		Position = UDim2.fromOffset(12, 230),
		Size = UDim2.new(1, -24, 0, 52),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Theme.Colors.Text,
		Parent = panel,
	})
	local function valueRow(y: number, caption: string): TextLabel
		bodyLabel(caption, 14, {
			Position = UDim2.fromOffset(12, y),
			Size = UDim2.fromOffset(110, 22),
			TextColor3 = Theme.Colors.Text,
			Parent = panel,
		})
		return Kit.label("", 19, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, y - 2),
			Size = UDim2.fromOffset(140, 24),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			Parent = panel,
		})
	end
	local function statBar(y: number, caption: string, color: Color3): (number, boolean?) -> ()
		bodyLabel(caption, 13, {
			Position = UDim2.fromOffset(12, y),
			Size = UDim2.fromOffset(84, 20),
			TextColor3 = Theme.Colors.Text,
			Parent = panel,
		})
		local _, set = Kit.progressBar(color, {
			Position = UDim2.fromOffset(98, y + 3),
			Size = UDim2.new(1, -110, 0, 14),
			Parent = panel,
		})
		return set
	end
	local income = valueRow(288, "💵 INCOME")
	local price = valueRow(314, "🏷️ PRICE")
	local setSpeed = statBar(342, "🏁 SPEED", Theme.Colors.Secondary)
	local setAccel = statBar(366, "⚡ ACCEL", Theme.Colors.Primary)
	local setGrip = statBar(390, "🛞 GRIP", Theme.Colors.Warning)
	local where = bodyLabel("", 13, {
		Name = "Where",
		Position = UDim2.fromOffset(10, 416),
		Size = UDim2.new(1, -20, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = panel,
	})
	return {
		panel = panel,
		view = view,
		mystery = mystery,
		name = name,
		rarityChip = rarityChip,
		rarityText = rarityText,
		flavor = flavor,
		income = income,
		price = price,
		setSpeed = setSpeed,
		setAccel = setAccel,
		setGrip = setGrip,
		where = where,
		model = nil :: Model?,
		camera = nil :: Camera?,
		center = nil :: Vector3?,
		size = nil :: Vector3?,
		carId = nil :: string?,
	}
end

updateIndexDetail = function(ctx: Ctx)
	local ui = ctx.ui
	local d = ui.detail
	local id: string? = ui.selected
	local def = if id then Cars.get(id) else nil
	if not def then
		d.name.Text = "TAP A CAR"
		d.flavor.Text = "Pick any car to see its stats."
		return
	end
	local discovered = isDiscovered(def.id)
	local hidden = not needsModel(def, discovered)
	if d.carId ~= def.id or (d.model == nil and not hidden) then
		if d.model then
			d.model:Destroy()
			d.model = nil
		end
		d.carId = def.id
		if not hidden then
			local entry = ui.cards[def.id]
			local model = if entry and entry.model then entry.model:Clone() else buildCarModel(def.id)
			if model then
				d.model = model
				d.camera, d.center, d.size = attachModel(d.view, model, CARD_YAW + (ui.spinYaw or 0), 16, d.camera)
			end
		end
	end
	d.view.ImageColor3 = if discovered then WHITE else SILHOUETTE
	d.view.BackgroundColor3 = mix(rarityColor(def.rarity), Theme.Colors.Background, 0.7)
	d.mystery.Visible = hidden
	d.name.Text = if discovered then def.name else "???"
	local tier = (Rarity.Tiers :: any)[def.rarity]
	d.rarityChip.BackgroundColor3 = if tier then tier.color else Theme.Colors.Panel
	d.rarityText.Text = string.upper(def.rarity)
	if discovered then
		d.flavor.Text = def.flavor
	elseif def.rarity == "Secret" then
		d.flavor.Text = "A secret car. Nobody knows where it hides... 👀"
	else
		d.flavor.Text = "Not discovered yet! Steal one to add it to your Index."
	end
	d.income.Text = if discovered then `{Format.cash(def.income)}/s` else "???"
	d.income.TextColor3 = Theme.Colors.Cash
	d.price.Text = if not discovered
		then "???"
		elseif def.dealer and def.price > 0 then Format.cash(def.price)
		else "Not for sale"
	d.setSpeed(if discovered then def.topSpeed / STAT_MAX.speed else 0, true)
	d.setAccel(if discovered then def.accel / STAT_MAX.accel else 0, true)
	d.setGrip(if discovered then math.clamp((def.grip - 0.7) / 0.3, 0.05, 1) else 0, true)
	d.where.Text = "Found at: " .. table.concat(MenuController.carSources(def), "  ·  ")
end

local function refreshIndex(ctx: Ctx, snapshot: any)
	local ui = ctx.ui
	local disc: any = if snapshot and typeof(snapshot.discovered) == "table" then snapshot.discovered else {}
	for _, group in MenuController.indexGroups(disc) do
		local g = ui.groups[group.rarity]
		if g then
			g.title.Text = `{string.upper(group.rarity)}  <font color="#FFFFFF">{group.found}/{group.total}</font>`
			if not group.bonusEligible then
				g.badgeText.Text = "💎 Robux exclusive"
				g.badge.BackgroundColor3 = Theme.Colors.Panel
			elseif group.complete then
				g.badgeText.Text = `✅ +{math.floor(Economy.INDEX_RARITY_BONUS * 100 + 0.5)}% INCOME`
				g.badge.BackgroundColor3 = Theme.Colors.CashDark
			else
				g.badgeText.Text = `+{math.floor(Economy.INDEX_RARITY_BONUS * 100 + 0.5)}% income when complete`
				g.badge.BackgroundColor3 = Theme.Colors.Panel
			end
		end
		for _, def in group.cars do
			local entry = ui.cards[def.id]
			if entry then
				local discovered = disc[def.id] == true
				if entry.discovered ~= discovered then
					local wasLocked = entry.discovered == false
					entry.discovered = discovered
					styleIndexCard(ctx, entry, discovered)
					if ctx.open and discovered and not entry.model then
						ensureCardModel(entry) -- e.g. a Secret car (shown as "❓", no model yet) just got discovered
					end
					if wasLocked and discovered then
						Kit.pop(entry.button, 1.2)
						floatText(entry.button, "NEW!", Theme.Colors.Gold)
					end
				end
			end
		end
	end
	local found, total, bonus = MenuController.indexTotals(disc)
	-- only animate real changes: snapshots arrive often and each tween is a per-frame thread
	if ui.summaryText:GetAttribute("Value") ~= found then
		Kit.tweenNumber(ui.summaryText, found, function(n: number): string
			return `📖 COLLECTED {math.floor(n + 0.5)}/{total}`
		end)
	end
	ui.setSummary(found / math.max(1, total), true)
	ui.bonusText.Text = if bonus > 0
		then `🏆 INDEX BONUS +{math.floor(bonus * 100 + 0.5)}% INCOME`
		else "Complete a rarity for +income!"
	updateIndexDetail(ctx)
end

-- Default selection when the Index opens: your best discovered car, else the first car.
local function defaultSelection(): string?
	local best: CarDef? = nil
	for _, def in Cars.List do
		if isDiscovered(def.id) and (best == nil or def.income > (best :: CarDef).income) then
			best = def
		end
	end
	return if best then best.id elseif Cars.List[1] then Cars.List[1].id else nil
end

local function spinStep(ctx: Ctx, dt: number)
	local ui = ctx.ui
	ui.spinYaw = ((ui.spinYaw or 0) + dt * SPIN_SPEED) % 360
	local yaw = CARD_YAW + ui.spinYaw
	local d = ui.detail
	if d.camera and d.center and d.size then
		d.camera.CFrame = MenuController.cameraCFrame(d.center, d.size, VIEW_FOV, yaw, 16)
	end
	local spinning: { [string]: boolean } = {}
	for _, id in { ui.selected, ui.hovered } do
		local entry = id and ui.cards[id]
		if entry and entry.camera and entry.center and entry.size then
			spinning[id] = true
			entry.camera.CFrame = MenuController.cameraCFrame(entry.center, entry.size, VIEW_FOV, yaw, CARD_PITCH)
		end
	end
	-- cards that stopped spinning snap back to the catalog pose
	for id in ui.spun do
		if not spinning[id] then
			local entry = ui.cards[id]
			if entry and entry.camera and entry.center and entry.size then
				entry.camera.CFrame =
					MenuController.cameraCFrame(entry.center, entry.size, VIEW_FOV, CARD_YAW, CARD_PITCH)
			end
		end
	end
	ui.spun = spinning
end

local function onIndexOpen(ctx: Ctx)
	local ui = ctx.ui
	if not ui.selected then
		local id = defaultSelection()
		if id then
			selectCar(ctx, id)
		end
	end
	ctx.session:Connect(RunService.PreRender, function(dt: number)
		spinStep(ctx, dt)
	end)
	-- Build the viewport previews progressively, a few per frame, only while the Index is open.
	ctx.session:Add(task.spawn(function()
		local builtThisFrame = 0
		for _, group in MenuController.indexGroups(nil) do
			for _, def in group.cars do
				if not ctx.open then
					return
				end
				local entry = ui.cards[def.id]
				if entry and not entry.model and not entry.failed and needsModel(def, isDiscovered(def.id)) then
					ensureCardModel(entry)
					builtThisFrame += 1
					if builtThisFrame >= MODELS_PER_FRAME then
						builtThisFrame = 0
						task.wait()
					end
				end
			end
		end
		if ctx.open then
			updateIndexDetail(ctx)
		end
	end))
end

BUILDERS.Index = function(ctx: Ctx)
	local ui = { cards = {}, groups = {}, selected = nil, hovered = nil, spinYaw = 0, spun = {} }
	ctx.ui = ui
	local body = ctx.body
	body.Size = UDim2.new(1, -(INDEX_DETAIL_W + 16), 1, -64)
	vlist(body, 10, Enum.HorizontalAlignment.Left)

	local summary = card({ Name = "Summary", Size = UDim2.new(1, 0, 0, 66), LayoutOrder = 0, Parent = body })
	ui.summaryText = Kit.label("📖 COLLECTED 0/0", 22, {
		Name = "Count",
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(0.5, -14, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		Parent = summary,
	})
	ui.bonusText = fitLabel("", 16, {
		Name = "Bonus",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 9),
		Size = UDim2.new(0.5, -10, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Theme.Colors.Gold,
		Parent = summary,
	})
	local _, setSummary = Kit.progressBar(PURPLE, {
		Name = "Bar",
		Position = UDim2.fromOffset(14, 38),
		Size = UDim2.new(1, -28, 0, 16),
		Parent = summary,
	})
	ui.setSummary = setSummary

	for gi, group in MenuController.indexGroups(nil) do
		local holder = autoFrame(group.rarity, gi, body)
		vlist(holder, 8, Enum.HorizontalAlignment.Left)
		local header = Kit.new("Frame", {
			Name = "Header",
			BackgroundColor3 = Theme.Colors.Background,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 40),
			LayoutOrder = 1,
			Parent = holder,
		})
		Kit.corner(Theme.CornerSmall).Parent = header
		Kit.stroke(group.color, 2).Parent = header
		local stripe = Kit.new("Frame", {
			Name = "Stripe",
			BackgroundColor3 = group.color,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.new(0, 6, 1, -12),
			Parent = header,
		})
		Kit.corner(UDim.new(1, 0)).Parent = stripe
		local title = Kit.label(string.upper(group.rarity), 22, {
			Name = "Title",
			Position = UDim2.fromOffset(20, 0),
			Size = UDim2.new(0.5, -20, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			TextColor3 = group.color,
			Parent = header,
		})
		local badge, badgeText = chip("", Theme.Colors.Panel, 13, {
			Name = "Badge",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Parent = header,
		})
		ui.groups[group.rarity] = { title = title, badge = badge, badgeText = badgeText }
		local cardsFrame = autoFrame("Cards", 2, holder)
		Kit.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(INDEX_CARD.X, INDEX_CARD.Y),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Parent = cardsFrame,
		})
		for ci, def in group.cars do
			ui.cards[def.id] = buildIndexCard(ctx, cardsFrame, def, ci)
		end
	end
	ui.detail = buildIndexDetail(ctx)
	ctx.refresh = refreshIndex
	ctx.onOpen = onIndexOpen
	ctx.onClose = function(c: Ctx)
		c.ui.hovered = nil
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Daily rewards
-------------------------------------------------------------------------------------------------------------------------

local function buildDailyTile(parent: Instance, index: number, reward: any): any
	local info = MenuController.rewardInfo(reward, 0)
	local isJackpot = index == #Economy.DAILY_REWARDS
	local tile = Kit.new("Frame", {
		Name = "Day" .. index,
		BackgroundColor3 = Theme.Colors.PanelLight,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(94, 178),
		LayoutOrder = index,
		Parent = parent,
	})
	Kit.corner().Parent = tile
	local stroke = Kit.stroke(if isJackpot then Theme.Colors.Gold else Theme.Colors.Stroke, 3)
	stroke.Parent = tile
	Kit.gradient(WHITE, Color3.fromRGB(190, 190, 208)).Parent = tile
	Kit.label("DAY " .. index, 18, {
		Name = "Day",
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 22),
		TextColor3 = if isJackpot then Theme.Colors.Gold else WHITE,
		Parent = tile,
	})
	iconTile(info.icon, if isJackpot then Theme.Colors.Gold else Theme.Colors.Panel, 54, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 32),
		Parent = tile,
	})
	fitLabel(info.text, 18, {
		Name = "Reward",
		Position = UDim2.fromOffset(4, 92),
		Size = UDim2.new(1, -8, 0, 22),
		TextColor3 = info.color,
		Parent = tile,
	})
	local sub = bodyLabel(info.sub or "", 12, {
		Name = "Sub",
		Position = UDim2.fromOffset(2, 116),
		Size = UDim2.new(1, -4, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Parent = tile,
	})
	local state = Kit.label("", 15, {
		Name = "State",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -8),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = tile,
	})
	local done = Kit.new("Frame", {
		Name = "Claimed",
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 5,
		Parent = tile,
	})
	Kit.corner().Parent = done
	Kit.label("✅", 44, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(60, 54),
		ZIndex = 6,
		Parent = done,
	})
	return { tile = tile, stroke = stroke, sub = sub, state = state, done = done, reward = reward, jackpot = isJackpot }
end

local function refreshDaily(ctx: Ctx, snapshot: any)
	local ui = ctx.ui
	local view = if snapshot then snapshot.daily else nil
	local states = MenuController.dailyTileStates(view)
	local streak = if typeof(view) == "table" then math.max(0, math.floor(num(view.streak, 0))) else 0
	ui.streak.Text = if streak > 0 then `🔥 {streak}-DAY STREAK!` else "🔥 START YOUR STREAK!"
	local income = currentIncome()
	for i, t in ui.tiles do
		local st = states[i] or "locked"
		local info = MenuController.rewardInfo(t.reward, income)
		t.sub.Text = info.sub or ""
		t.done.Visible = st == "claimed"
		setPulse(t.tile, st == "ready", Theme.Colors.Primary)
		if st ~= "ready" then
			t.stroke.Color = if st == "next"
				then Theme.Colors.Secondary
				elseif t.jackpot then Theme.Colors.Gold
				else Theme.Colors.Stroke
			t.stroke.Thickness = if st == "next" then 4 else 3
		end
		t.tile.BackgroundColor3 = if st == "ready"
			then Theme.Colors.Primary
			elseif st == "locked" then Theme.Colors.Panel
			else Theme.Colors.PanelLight
		if st == "ready" then
			t.state.Text = "TODAY!"
			t.state.TextColor3 = WHITE
		elseif st == "next" then
			t.state.Text = "TOMORROW"
			t.state.TextColor3 = Theme.Colors.Secondary
		elseif st == "locked" then
			t.state.Text = if t.jackpot then "JACKPOT" else "🔒"
			t.state.TextColor3 = if t.jackpot then Theme.Colors.Gold else Theme.Colors.TextDim
		else
			t.state.Text = ""
		end
	end
	local canClaim = typeof(view) == "table" and view.canClaim == true
	if ui.lastCanClaim == true and not canClaim then
		-- just claimed: celebrate the tile that was ready
		local t = ui.tiles[ui.lastReady or 0]
		if t then
			Kit.pop(t.tile, 1.15)
			floatText(t.tile, "CLAIMED!", Theme.Colors.Cash)
		end
		ui.pendingUntil = 0
	end
	ui.lastCanClaim = canClaim
	ui.lastReady = table.find(states, "ready")
	local pending = os.clock() < (ui.pendingUntil or 0)
	if canClaim and not pending then
		local day = ui.lastReady or 1
		setButton(ui.claim, `🎁 CLAIM DAY {day}!`, Theme.Colors.Primary, true)
		setPulse(ui.claim, true)
	elseif canClaim then
		setButton(ui.claim, "CLAIMING...", Theme.Colors.Primary, false)
		setPulse(ui.claim, false)
	else
		setButton(
			ui.claim,
			`⏳ NEXT IN {MenuController.formatHhMm(MenuController.secondsUntilUtcMidnight(serverNow()))}`,
			Theme.Colors.Primary,
			false
		)
		setPulse(ui.claim, false)
	end
end

BUILDERS.Daily = function(ctx: Ctx)
	local ui = { tiles = {} }
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 10)
	ui.streak = Kit.label("🔥 START YOUR STREAK!", 32, {
		Name = "Streak",
		Size = UDim2.new(1, 0, 0, 38),
		TextColor3 = Theme.Colors.Warning,
		LayoutOrder = 1,
		Parent = body,
	})
	bodyLabel("Claim a reward every day. Miss a day and the streak starts over!", 15, {
		LayoutOrder = 2,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = body,
	})
	local row = Kit.new("Frame", {
		Name = "Tiles",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 182),
		LayoutOrder = 3,
		Parent = body,
	})
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		row
	for i, reward in Economy.DAILY_REWARDS do
		ui.tiles[i] = buildDailyTile(row, i, reward)
	end
	local footer = Kit.new("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 76),
		LayoutOrder = 4,
		Parent = body,
	})
	ui.claim = Kit.button("🎁 CLAIM!", Theme.Colors.Primary, {
		Name = "Claim",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(340, 64),
		TextSize = 28,
		Parent = footer,
	})
	onPress(ui.claim, function()
		Net.fire("ClaimDaily")
		ui.pendingUntil = os.clock() + PENDING_SECONDS
		refreshDaily(ctx, getSnapshot())
	end)
	ctx.primary = ui.claim
	ctx.refresh = refreshDaily
	ctx.onClose = function(c: Ctx)
		c.ui.lastCanClaim = nil
	end
	ctx.tick = function(c: Ctx)
		refreshDaily(c, getSnapshot())
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Contracts
-------------------------------------------------------------------------------------------------------------------------

local function buildContractCard(parent: Instance, order: number): any
	local c = card({ Name = "Contract" .. order, Size = UDim2.new(1, 0, 0, 110), LayoutOrder = order, Parent = parent })
	local icon = iconTile("🎯", Theme.Colors.Warning, 78, { Position = UDim2.fromOffset(14, 16), Parent = c })
	local title = fitLabel("", 22, {
		Name = "Title",
		Position = UDim2.fromOffset(106, 12),
		Size = UDim2.new(1, -306, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = c,
	})
	local bar, setBar = Kit.progressBar(Theme.Colors.Warning, {
		Name = "Bar",
		Position = UDim2.fromOffset(106, 54),
		Size = UDim2.new(1, -306, 0, 24),
		Parent = c,
	})
	local progress = Kit.label("", 16, {
		Name = "Progress",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = bar,
	})
	bodyLabel("REWARD", 13, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 16),
		Size = UDim2.fromOffset(176, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = c,
	})
	local reward = Kit.label("", 28, {
		Name = "Reward",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 34),
		Size = UDim2.fromOffset(176, 34),
		TextColor3 = Theme.Colors.Cash,
		TextWrapped = false,
		Parent = c,
	})
	local rewardSub = bodyLabel("", 13, {
		Name = "RewardSub",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 70),
		Size = UDim2.fromOffset(176, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = c,
	})
	local stamp = Kit.label("✅ DONE!", 34, {
		Name = "Stamp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 40, 0.5, 0),
		Size = UDim2.fromOffset(220, 44),
		Rotation = -8,
		TextColor3 = Theme.Colors.Cash,
		Visible = false,
		ZIndex = 6,
		Parent = c,
	})
	-- daily free swap (only shown while the server offers it; see MenuController.canSwapContract)
	local swap = Kit.button("🎲 SWAP", Theme.Colors.Secondary, {
		Name = "Swap",
		Position = UDim2.fromOffset(106, 82),
		Size = UDim2.fromOffset(150, 24),
		TextSize = 15,
		Visible = false,
		Parent = c,
	})
	return {
		card = c,
		icon = icon:FindFirstChild("Icon"),
		title = title,
		setBar = setBar,
		progress = progress,
		reward = reward,
		rewardSub = rewardSub,
		stamp = stamp,
		swap = swap,
		swapArmedUntil = 0,
		swapPendingUntil = 0,
	}
end

local function refreshContracts(ctx: Ctx, snapshot: any)
	local ui = ctx.ui
	local contracts = if snapshot then snapshot.contracts else nil
	local rows = MenuController.contractRows(contracts, currentIncome())
	local now = os.clock()
	for i, slot in ui.cards do
		local row = rows[i]
		slot.card.Visible = row ~= nil
		local canSwap = row ~= nil
			and now >= slot.swapPendingUntil
			and MenuController.canSwapContract(contracts, row, SWAP_AVAILABLE)
		slot.swap.Visible = canSwap
		if canSwap then
			local armed = now < slot.swapArmedUntil
			setButton(
				slot.swap,
				if armed then "🎲 TAP TO SWAP" else "🎲 SWAP",
				if armed then Theme.Colors.Danger else Theme.Colors.Secondary,
				true
			)
		end
		slot.rowId = if row then row.id else nil
		if row then
			if slot.icon then
				slot.icon.Text = row.icon
			end
			slot.title.Text = row.text
			slot.setBar(row.fraction, true)
			slot.progress.Text = if row.done then "" else MenuController.contractProgressText(row)
			slot.reward.Text = "≈ " .. Format.cash(row.rewardCash)
			slot.rewardSub.Text = MenuController.durationWords(row.rewardSeconds) .. " of income"
			slot.stamp.Visible = row.done
			slot.stamp.Text = if row.claimed then "✅ CLAIMED!" else "✅ DONE!"
			slot.card.BackgroundColor3 = if row.done then Theme.Colors.Panel else Theme.Colors.PanelLight
			if slot.lastId == row.id and slot.lastDone == false and row.done then
				Kit.pop(slot.card, 1.05)
				Kit.pop(slot.stamp, 1.6)
			end
			slot.lastId = row.id
			slot.lastDone = row.done
		end
	end
	ui.empty.Visible = #rows == 0
	ui.timer.Text =
		`🔄 NEW CONTRACTS IN {MenuController.formatHhMm(MenuController.secondsUntilUtcMidnight(serverNow()))}`
end

BUILDERS.Contracts = function(ctx: Ctx)
	local ui = { cards = {} }
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 10)
	local top = Kit.new("Frame", {
		Name = "Top",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = 0,
		Parent = body,
	})
	bodyLabel("Finish jobs for big cash. Rewards grow with your income!", 15, {
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -290, 1, 0),
		Parent = top,
	})
	local timerChip, timerText = chip("🔄 NEW CONTRACTS IN 00:00", Theme.Colors.Background, 15, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Parent = top,
	})
	ui.timerChip = timerChip
	ui.timer = timerText
	for i = 1, Economy.CONTRACTS_PER_DAY do
		local slot = buildContractCard(body, i)
		ui.cards[i] = slot
		onPress(slot.swap, function()
			local id = slot.rowId
			if typeof(id) ~= "string" then
				return
			end
			local now = os.clock()
			if now < slot.swapArmedUntil then
				-- second tap: swap (one per day, the server decides which job you get)
				slot.swapArmedUntil = 0
				slot.swapPendingUntil = now + PENDING_SECONDS
				Net.fire(SWAP_REMOTE, id)
			else
				slot.swapArmedUntil = now + CONFIRM_WINDOW
				shake(slot.swap)
			end
			refreshContracts(ctx, getSnapshot())
		end)
	end
	ui.empty = bodyLabel("📭 Your contracts are on the way. Check back in a moment!", 17, {
		Name = "Empty",
		LayoutOrder = 50,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Theme.Colors.Text,
		Visible = false,
		Parent = body,
	})
	ctx.refresh = refreshContracts
	ctx.tick = function(c: Ctx)
		c.ui.timer.Text =
			`🔄 NEW CONTRACTS IN {MenuController.formatHhMm(MenuController.secondsUntilUtcMidnight(serverNow()))}`
		-- a swap confirm / pending state just ran out: redraw so the button resets
		local now = os.clock()
		for _, slot in c.ui.cards do
			if
				(slot.swapArmedUntil > 0 and now >= slot.swapArmedUntil)
				or (slot.swapPendingUntil > 0 and now >= slot.swapPendingUntil)
			then
				slot.swapArmedUntil = 0
				slot.swapPendingUntil = 0
				refreshContracts(c, getSnapshot())
				return
			end
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Playtime gifts
-------------------------------------------------------------------------------------------------------------------------

local function sessionExtra(): number
	return math.max(0, os.clock() - playtimeAt)
end

local function buildGiftTile(parent: Instance, index: number, def: any): any
	local info = MenuController.rewardInfo(def, 0)
	local tile = card({ Name = "Gift" .. index, LayoutOrder = index, Parent = parent })
	iconTile(info.icon, if def.kind == "car" then info.color else Theme.Colors.Panel, 62, {
		Position = UDim2.fromOffset(12, 12),
		Parent = tile,
	})
	fitLabel(info.text, 24, {
		Name = "Reward",
		Position = UDim2.fromOffset(84, 14),
		Size = UDim2.new(1, -94, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = info.color,
		Parent = tile,
	})
	local sub = bodyLabel("", 13, {
		Name = "Sub",
		Position = UDim2.fromOffset(84, 44),
		Size = UDim2.new(1, -94, 0, 20),
		Parent = tile,
	})
	local timer = Kit.label("", 26, {
		Name = "Timer",
		Position = UDim2.fromOffset(0, 84),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = tile,
	})
	local barFrame, setBar = Kit.progressBar(Theme.Colors.Cash, {
		Name = "Bar",
		Position = UDim2.fromOffset(16, 124),
		Size = UDim2.new(1, -32, 0, 14),
		Parent = tile,
	})
	local claim = Kit.button("CLAIM!", Theme.Colors.Cash, {
		Name = "Claim",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 90),
		Size = UDim2.fromOffset(176, 52),
		TextSize = 26,
		Visible = false,
		Parent = tile,
	})
	return {
		tile = tile,
		def = def,
		sub = sub,
		timer = timer,
		bar = barFrame,
		setBar = setBar,
		claim = claim,
		pendingUntil = 0,
	}
end

local function refreshGifts(ctx: Ctx, snapshot: any)
	local ui = ctx.ui
	local income = currentIncome()
	-- playtimeBase is captured when each snapshot arrives; fall back to the current one before start() ran
	local base = playtimeBase or (if snapshot then snapshot.playtime else nil)
	local extra = if playtimeBase then sessionExtra() else 0
	local tiles = MenuController.playtimeTiles(base, extra)
	-- sessionSeconds = seconds played TODAY (UTC, saved across rejoins), not just this session
	local session = (if typeof(base) == "table" then num(base.sessionSeconds, 0) else 0) + extra
	ui.session.Text = `🕒 Played today: {Format.clock(session)}`
	local resetIn = MenuController.formatHhMm(MenuController.secondsUntilUtcMidnight(serverNow()))
	ui.footer.Text = `Play time counts all day, even if you rejoin. New gifts in {resetIn}!`
	for i, t in ui.tiles do
		local st = tiles[i]
		if st then
			local info = MenuController.rewardInfo(t.def, income)
			local pending = os.clock() < t.pendingUntil
			t.sub.Text = if info.sub and t.def.kind ~= "car" then info.sub else `after {t.def.minutes} min`
			t.timer.Visible = st.state ~= "ready"
			t.bar.Visible = st.state == "waiting"
			t.claim.Visible = st.state == "ready"
			t.tile.BackgroundColor3 = if st.state == "claimed" then Theme.Colors.Panel else Theme.Colors.PanelLight
			if st.state == "waiting" then
				t.timer.Text = "⏳ " .. Format.clock(math.ceil(st.remaining))
				t.timer.TextColor3 = WHITE
				t.setBar(st.fraction, false)
			elseif st.state == "claimed" then
				t.timer.Text = "✅ CLAIMED"
				t.timer.TextColor3 = Theme.Colors.TextDim
			end
			if st.state == "ready" then
				setButton(t.claim, if pending then "..." else "CLAIM!", Theme.Colors.Cash, not pending)
			end
			setPulse(t.claim, st.state == "ready" and not pending)
			if t.lastState == "waiting" and st.state == "ready" then
				Kit.pop(t.tile, 1.08)
			elseif t.lastState == "ready" and st.state == "claimed" then
				Kit.pop(t.tile, 1.1)
				floatText(t.tile, "GOT IT!", Theme.Colors.Cash)
			end
			t.lastState = st.state
		end
	end
end

BUILDERS.Gifts = function(ctx: Ctx)
	local ui = { tiles = {} }
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 10)
	Kit.label("FREE GIFTS FOR PLAYING!", 28, {
		Name = "Headline",
		Size = UDim2.new(1, 0, 0, 34),
		TextColor3 = Theme.Colors.Cash,
		LayoutOrder = 1,
		Parent = body,
	})
	ui.session = bodyLabel("🕒 Played today: 0:00", 15, {
		Name = "Session",
		LayoutOrder = 2,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Theme.Colors.Text,
		Parent = body,
	})
	local tilesFrame = autoFrame("Tiles", 3, body)
	grid(tilesFrame, Vector2.new(226, 152), 10)
	for i, def in Economy.PLAYTIME_REWARDS do
		local t = buildGiftTile(tilesFrame, i, def)
		ui.tiles[i] = t
		onPress(t.claim, function()
			Net.fire("ClaimPlaytime", i)
			t.pendingUntil = os.clock() + PENDING_SECONDS
			refreshGifts(ctx, getSnapshot())
		end)
	end
	ui.footer = bodyLabel("Play time counts all day, even if you rejoin. New gifts every day!", 13, {
		LayoutOrder = 4,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = body,
	})
	ctx.refresh = refreshGifts
	ctx.tick = function(c: Ctx)
		refreshGifts(c, getSnapshot())
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Rebirth
-------------------------------------------------------------------------------------------------------------------------

local KEEP_CARS_LINE = if Economy.REBIRTH_KEEP_CARS == 1
	then "🚗 Your best car"
	else `🚗 Your best {Economy.REBIRTH_KEEP_CARS} cars`

local function refreshRebirth(ctx: Ctx, snapshot: any)
	local ui = ctx.ui
	local view = MenuController.rebirthView(currentCash(), currentRebirths())
	local nowText = MenuController.formatMultiplier(view.multiplier)
	local nextText = MenuController.formatMultiplier(view.nextMultiplier)
	ui.mult.Text = `<font color="#{HEX_DIM}">{nowText}</font> → {nextText}`
	ui.count.Text = `REBIRTHS: {view.rebirths}`
	ui.cost.Text = "COST: " .. Format.cash(view.cost)
	ui.setBar(view.fraction, true)
	ui.barText.Text = `{Format.cash(view.cash)} / {Format.cash(view.cost)}`
	local keptText = MenuController.keptCarsText(MenuController.keptCars(if snapshot then snapshot.garage else nil))
	ui.keepCar.Text = KEEP_CARS_LINE .. (if keptText ~= "" then ` ({keptText})` else "")
	local busy = MenuController.garageBusy(if snapshot then snapshot.garage else nil)
	local now = os.clock()
	if now < (ui.pendingUntil or 0) then
		setButton(ui.button, "♻️ REBIRTHING...", REBIRTH_COLOR, false, true)
	elseif not view.canAfford then
		setButton(ui.button, `NEED {Format.cash(view.missing)} MORE`, REBIRTH_COLOR, false)
		ui.confirmUntil = 0
	elseif busy then
		setButton(ui.button, "PARK YOUR CARS FIRST", REBIRTH_COLOR, false)
		ui.confirmUntil = 0
	elseif now < (ui.confirmUntil or 0) then
		setButton(ui.button, "⚠️ TAP AGAIN TO CONFIRM", Theme.Colors.Danger, true)
	else
		setButton(ui.button, "♻️ REBIRTH", REBIRTH_COLOR, true)
	end
	setPulse(ui.button, view.canAfford and not busy and now >= (ui.pendingUntil or 0), Theme.Colors.Gold)
	if ui.lastRebirths ~= nil and view.rebirths > ui.lastRebirths then
		Kit.pop(ui.showcase, 1.08)
		floatText(ui.showcase, "REBIRTHED!", Theme.Colors.Gold)
		ui.pendingUntil = 0
	end
	ui.lastRebirths = view.rebirths
end

local function listCard(parent: Instance, title: string, color: Color3, lines: { string }, order: number): { TextLabel }
	local c = card({ Name = "List" .. order, Size = UDim2.new(0.5, -5, 1, 0), LayoutOrder = order, Parent = parent })
	Kit.label(title, 20, {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color,
		Parent = c,
	})
	local labels = {}
	for i, line in lines do
		table.insert(
			labels,
			bodyLabel(line, 14, {
				Position = UDim2.fromOffset(14, 36 + (i - 1) * 22),
				Size = UDim2.new(1, -24, 0, 20),
				TextColor3 = Theme.Colors.Text,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = c,
			})
		)
	end
	return labels
end

BUILDERS.Rebirth = function(ctx: Ctx)
	local ui: any = {}
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 10)

	local showcase = card({ Name = "Showcase", Size = UDim2.new(1, 0, 0, 108), LayoutOrder = 1, Parent = body })
	ui.showcase = showcase
	bodyLabel("INCOME MULTIPLIER", 14, {
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = showcase,
	})
	ui.mult = Kit.label("x1 → x1.5", 50, {
		Name = "Multiplier",
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 56),
		TextColor3 = Theme.Colors.Gold,
		TextWrapped = false,
		Parent = showcase,
	})
	-- perks are income + lock time only: rebirths never change spawn luck (world spawns are shared)
	bodyLabel(
		`💰 +{math.floor(Economy.REBIRTH_INCOME_BONUS * 100 + 0.5)}% income   •   🔒 +10s garage lock   (every rebirth)`,
		13,
		{
			Position = UDim2.fromOffset(0, 82),
			Size = UDim2.new(1, 0, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = showcase,
		}
	)

	local costCard = card({ Name = "Cost", Size = UDim2.new(1, 0, 0, 84), LayoutOrder = 2, Parent = body })
	ui.cost = Kit.label("COST: $0", 24, {
		Name = "CostText",
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(0.6, 0, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		Parent = costCard,
	})
	ui.count = Kit.label("REBIRTHS: 0", 18, {
		Name = "Count",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 10),
		Size = UDim2.new(0.4, -14, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Theme.Colors.TextDim,
		Parent = costCard,
	})
	local bar, setBar = Kit.progressBar(Theme.Colors.Cash, {
		Name = "Bar",
		Position = UDim2.fromOffset(14, 44),
		Size = UDim2.new(1, -28, 0, 28),
		Parent = costCard,
	})
	ui.setBar = setBar
	ui.barText = Kit.label("", 17, { Name = "BarText", Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = bar })

	local cols = Kit.new("Frame", {
		Name = "KeepLose",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 150),
		LayoutOrder = 3,
		Parent = body,
	})
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top).Parent =
		cols
	local keep = listCard(cols, "✅ YOU KEEP", Theme.Colors.Cash, {
		KEEP_CARS_LINE,
		"🔧 All upgrades & tools",
		"📖 Your Car Index",
		"💎 Passes & Robux cars",
		"♻️ Bigger income, forever",
	}, 1)
	ui.keepCar = keep[1]
	-- RebirthService pays uncollected garage cash out first (it counts toward Total Earned), then cash resets
	listCard(cols, "❌ YOU LOSE", Theme.Colors.Danger, {
		`💵 Cash (resets to {Format.cash(Economy.STARTING_CASH)})`,
		"💰 Garage cash (paid out, then reset)",
		"🚗 Every other car",
		"🅿️ Bought garage slots",
		"💡 Spend it on upgrades first!",
	}, 2)

	local footer = Kit.new("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 76),
		LayoutOrder = 4,
		Parent = body,
	})
	ui.button = Kit.button("♻️ REBIRTH", REBIRTH_COLOR, {
		Name = "Rebirth",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(400, 66),
		TextSize = 30,
		Parent = footer,
	})
	onPress(ui.button, function()
		local now = os.clock()
		if now < (ui.confirmUntil or 0) then
			ui.confirmUntil = 0
			ui.pendingUntil = now + PENDING_SECONDS
			Net.fire("Rebirth")
		else
			ui.confirmUntil = now + CONFIRM_WINDOW
			shake(ui.button)
			task.delay(CONFIRM_WINDOW + 0.05, function()
				if ctx.open then
					refreshRebirth(ctx, getSnapshot())
				end
			end)
		end
		refreshRebirth(ctx, getSnapshot())
	end)
	ctx.primary = ui.button
	ctx.refresh = refreshRebirth
	ctx.onClose = function(c: Ctx)
		c.ui.confirmUntil = 0
	end
	ctx.tick = function(c: Ctx)
		-- re-enables the button when a refused rebirth's pending state times out
		if (c.ui.pendingUntil or 0) > 0 and os.clock() >= c.ui.pendingUntil then
			c.ui.pendingUntil = 0
			refreshRebirth(c, getSnapshot())
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Codes
-------------------------------------------------------------------------------------------------------------------------

BUILDERS.Codes = function(ctx: Ctx)
	local ui: any = {}
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 14)
	bodyLabel("🎟️ Got a code? Punch it in for free loot!", 18, {
		LayoutOrder = 1,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Theme.Colors.Text,
		Parent = body,
	})
	local box = Kit.new("TextBox", {
		Name = "CodeBox",
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(440, 62),
		FontFace = Theme.Fonts.Display,
		TextSize = 30,
		Text = "",
		PlaceholderText = "ENTER CODE",
		PlaceholderColor3 = Theme.Colors.Disabled,
		TextColor3 = WHITE,
		ClearTextOnFocus = false,
		LayoutOrder = 2,
		Parent = body,
	})
	Kit.corner().Parent = box
	Kit.stroke(Theme.Colors.Secondary, 3).Parent = box
	ui.box = box
	local button = Kit.button("REDEEM", Theme.Colors.Cash, {
		Name = "Redeem",
		Size = UDim2.fromOffset(240, 58),
		TextSize = 28,
		LayoutOrder = 3,
		Parent = body,
	})
	ui.button = button
	bodyLabel("New codes drop with updates and milestones. Follow the game so you never miss one!", 13, {
		LayoutOrder = 4,
		Size = UDim2.new(1, -40, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = body,
	})
	local function redeem()
		if button:GetAttribute("Disabled") == true then
			return
		end
		local text = string.gsub(box.Text, "%s+", "")
		if text == "" or #text > 32 then
			shake(box)
			playSound("Click")
			return
		end
		Net.fire("RedeemCode", text)
		box.Text = ""
		box:ReleaseFocus()
		Kit.pop(button, 0.9)
		setButton(button, "SENT!", Theme.Colors.Cash, false, true)
		task.delay(1.5, function()
			setButton(button, "REDEEM", Theme.Colors.Cash, true)
		end)
	end
	onPress(button, redeem)
	box.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			redeem()
		end
	end)
	ctx.primary = box
	ctx.refresh = nil
end

-------------------------------------------------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------------------------------------------------

type SettingRow = { key: string, icon: string, title: string, desc: string, color: Color3 }
local SETTING_ROWS: { SettingRow } = {
	{ key = "music", icon = "🎵", title = "MUSIC", desc = "City ambience and music", color = Theme.Colors.Primary },
	{
		key = "sfx",
		icon = "🔊",
		title = "SOUND FX",
		desc = "Engines, sirens, cash and bonks",
		color = Theme.Colors.Secondary,
	},
	{
		key = "hideHud",
		icon = "🎥",
		title = "STREAMER MODE",
		desc = "Hide the HUD for clean clips. Tap 👁️ to bring it back.",
		color = Theme.Colors.Warning,
	},
	{
		key = "autoAccelerate",
		icon = "🚗",
		title = "AUTO-DRIVE",
		desc = "Cars speed up on their own. Great on mobile!",
		color = Theme.Colors.Cash,
	},
}

local KNOB_ON = UDim2.new(1, -40, 0.5, 0)
local KNOB_OFF = UDim2.new(0, 4, 0.5, 0)

local function setSwitch(sw: any, on: boolean, animate: boolean)
	local knobPos = if on then KNOB_ON else KNOB_OFF
	local color = if on then Theme.Colors.Cash else Theme.Colors.Disabled
	if animate then
		TweenService:Create(sw.knob, Theme.TweenMedium, { Position = knobPos }):Play()
		TweenService:Create(sw.track, Theme.TweenMedium, { BackgroundColor3 = color }):Play()
	else
		sw.knob.Position = knobPos
		sw.track.BackgroundColor3 = color
	end
	sw.text.Text = if on then "ON" else "OFF"
	sw.text.Position = if on then UDim2.fromOffset(12, 0) else UDim2.new(1, -46, 0, 0)
	sw.on = on
end

local function applySettingLocally(key: string, value: boolean)
	if key == "music" or key == "sfx" then
		local sounds = lazy("SoundController")
		if sounds and typeof(sounds.setEnabled) == "function" then
			pcall(sounds.setEnabled, key, value)
		end
	end
end

local function refreshSettings(ctx: Ctx, snapshot: any)
	local ui = ctx.ui
	local settings = if snapshot then snapshot.settings else nil
	local overrides: { [string]: boolean } = {}
	for k, o in settingOverrides do
		overrides[k] = o.value
	end
	for key, sw in ui.switches do
		local value = MenuController.settingValue(settings, overrides, key)
		if sw.on ~= value then
			setSwitch(sw, value, sw.on ~= nil)
		end
	end
	local stats: any = if snapshot and typeof(snapshot.stats) == "table" then snapshot.stats else {}
	local function stat(k: string): string
		return Format.short(num(stats[k], 0))
	end
	ui.stats.steals.Text = "🚗 Steals: " .. stat("steals")
	ui.stats.playerSteals.Text = "🦹 Player steals: " .. stat("playerSteals")
	ui.stats.hotDrops.Text = "📦 Hot Drops: " .. stat("hotDrops")
	ui.stats.busted.Text = "🚓 Busted: " .. stat("busted")
	ui.stats.timesRobbed.Text = "😱 Robbed: " .. stat("timesRobbed")
	ui.stats.totalEarned.Text = "💰 Earned: " .. Format.cash(if snapshot then num(snapshot.totalEarned, 0) else 0)
end

local function buildSettingRow(parent: Instance, row: SettingRow, order: number): any
	local c = card({ Name = row.key, Size = UDim2.new(1, 0, 0, 74), LayoutOrder = order, Parent = parent })
	iconTile(row.icon, row.color, 54, { Position = UDim2.fromOffset(12, 10), Parent = c })
	Kit.label(row.title, 22, {
		Position = UDim2.fromOffset(80, 8),
		Size = UDim2.new(1, -200, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = c,
	})
	bodyLabel(row.desc, 13, {
		Position = UDim2.fromOffset(80, 38),
		Size = UDim2.new(1, -200, 0, 30),
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = c,
	})
	local track = Kit.new("TextButton", {
		Name = "Switch",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Theme.Colors.Disabled,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(100, 46),
		Parent = c,
	})
	Kit.corner(UDim.new(1, 0)).Parent = track
	Kit.stroke().Parent = track
	local text = Kit.label("OFF", 16, {
		Name = "State",
		Size = UDim2.new(0, 34, 1, 0),
		Position = UDim2.new(1, -46, 0, 0),
		TextWrapped = false,
		Parent = track,
	})
	local knob = Kit.new("Frame", {
		Name = "Knob",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = KNOB_OFF,
		Size = UDim2.fromOffset(36, 36),
		Parent = track,
	})
	Kit.corner(UDim.new(1, 0)).Parent = knob
	Kit.stroke(Theme.Colors.Stroke, 2).Parent = knob
	Kit.juice(track)
	local sw = { track = track, knob = knob, text = text, on = nil :: boolean? }
	onPress(track, function()
		local value = not (sw.on == true)
		settingOverrides[row.key] = { value = value, at = os.clock() }
		setSwitch(sw, value, true)
		applySettingLocally(row.key, value)
		Net.fire("SetSetting", row.key, value)
	end)
	return sw
end

BUILDERS.Settings = function(ctx: Ctx)
	local ui = { switches = {}, stats = {} }
	ctx.ui = ui
	local body = ctx.body
	vlist(body, 10)
	for i, row in SETTING_ROWS do
		ui.switches[row.key] = buildSettingRow(body, row, i)
	end
	local statsCard = card({ Name = "Stats", Size = UDim2.new(1, 0, 0, 100), LayoutOrder = 10, Parent = body })
	Kit.label("📊 YOUR STATS", 20, {
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(1, -28, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = statsCard,
	})
	local statGrid = Kit.new("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 34),
		Size = UDim2.new(1, -28, 0, 60),
		Parent = statsCard,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -6, 0, 26),
		CellPadding = UDim2.fromOffset(8, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = statGrid,
	})
	for i, key in { "steals", "playerSteals", "hotDrops", "busted", "timesRobbed", "totalEarned" } do
		ui.stats[key] = bodyLabel("", 14, {
			Name = key,
			LayoutOrder = i,
			TextColor3 = Theme.Colors.Text,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = statGrid,
		})
	end
	ctx.refresh = refreshSettings
end

-------------------------------------------------------------------------------------------------------------------------
-- Window management
-------------------------------------------------------------------------------------------------------------------------

local function ensureGui(): ScreenGui
	local existing = gui
	if existing then
		return existing
	end
	local g = Kit.screen("Menus", Theme.Layers.Menus)
	g.IgnoreGuiInset = true -- full-bleed backdrop; windows are centered so the top bar never covers them
	local b = Kit.new("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Color3.fromRGB(6, 6, 18),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 0,
		Parent = g,
	})
	b.Activated:Connect(function()
		MenuController.close()
	end)
	gui = g
	backdrop = b
	return g
end

local function ensurePage(name: string): Ctx?
	local existing = pages[name]
	if existing then
		return existing
	end
	local def = PAGE_DEFS[name]
	local builder = BUILDERS[name]
	if not def or not builder then
		return nil
	end
	local g = ensureGui()
	local win, body, kitClose = Kit.window(g, def.title, def.accent, UDim2.fromOffset(def.size.X, def.size.Y))
	win.Name = name
	win.Active = true -- swallow clicks so they never reach the backdrop
	win.ZIndex = 2
	-- Replace Kit's close button: its built-in handler hides the window behind our back (races a quick reopen).
	kitClose:Destroy()
	local header = win:FindFirstChild("Header") :: Frame?
	local close = Kit.button("X", Theme.Colors.Danger, {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(46, 46),
		TextSize = 26,
		ZIndex = 3,
		Parent = header or win,
	})
	if header then
		-- glossy highlight across the top half of the header
		local shine = Kit.new("Frame", {
			Name = "Shine",
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.82,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(8, 4),
			Size = UDim2.new(1, -16, 0.38, 0),
			ZIndex = 1,
			Parent = header,
		})
		Kit.corner(Theme.CornerSmall).Parent = shine
	end
	body.VerticalScrollBarInset = Enum.ScrollBarInset.Always
	body.ScrollBarImageColor3 = def.accent
	local ctx: Ctx = {
		name = name,
		size = def.size,
		win = win,
		body = body,
		closeButton = close,
		open = false,
		openToken = 0,
		session = Trove.new(),
		ui = {},
		primary = nil,
		refresh = nil,
		tick = nil,
		onOpen = nil,
		onClose = nil,
	}
	onPress(close, function()
		MenuController.close(name)
	end)
	builder(ctx)
	pages[name] = ctx
	return ctx
end

local function refreshCtx(ctx: Ctx)
	local fn = ctx.refresh
	if fn then
		local ok, err = pcall(fn, ctx, getSnapshot())
		if not ok then
			warn(("[MenuController] refresh %s failed: %s"):format(ctx.name, tostring(err)))
		end
	end
end

local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		local name = current
		local ctx = if name then pages[name] else nil
		if ctx and ctx.open then
			refreshCtx(ctx)
		end
	end)
end

local function showBackdrop(on: boolean)
	local b = backdrop
	if not b then
		return
	end
	if on then
		b.Visible = true
		TweenService:Create(b, Theme.TweenMedium, { BackgroundTransparency = BACKDROP_TRANSPARENCY }):Play()
	else
		local tween = TweenService:Create(b, Theme.TweenFast, { BackgroundTransparency = 1 })
		tween.Completed:Once(function()
			if current == nil then
				b.Visible = false
			end
		end)
		tween:Play()
	end
end

local function isGamepadInput(): boolean
	local ok, last = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	return ok and typeof(last) == "EnumItem" and string.find(last.Name, "Gamepad", 1, true) ~= nil
end

-- Target UIScale of a window for the current screen (see MenuController.windowScale).
local function fitScale(ctx: Ctx): number
	local cam = Workspace.CurrentCamera
	local g = gui
	local screenScale = if g then g:FindFirstChildOfClass("UIScale") else nil
	if not cam or not screenScale then
		return 1
	end
	return MenuController.windowScale(cam.ViewportSize, screenScale.Scale, ctx.size)
end

local function showWindow(ctx: Ctx)
	local win = ctx.win
	ctx.openToken += 1
	win.Visible = true
	local scale = win:FindFirstChildOfClass("UIScale")
	if scale then
		local target = fitScale(ctx)
		scale.Scale = target * 0.6
		TweenService:Create(scale, Theme.TweenPop, { Scale = target }):Play()
	end
	win.Position = UDim2.fromScale(0.5, 0.56)
	TweenService:Create(win, Theme.TweenMedium, { Position = UDim2.fromScale(0.5, 0.52) }):Play()
end

local function hideWindow(ctx: Ctx, instant: boolean)
	local win = ctx.win
	local scale = win:FindFirstChildOfClass("UIScale")
	if instant or not scale then
		win.Visible = false
		return
	end
	local token = ctx.openToken
	local tween = TweenService:Create(scale, Theme.TweenFast, { Scale = scale.Scale * 0.6 })
	tween.Completed:Once(function()
		if ctx.open or ctx.openToken ~= token then
			return -- reopened while closing
		end
		win.Visible = false
	end)
	tween:Play()
end

local function deactivate(ctx: Ctx, instant: boolean)
	if not ctx.open then
		return
	end
	ctx.open = false
	ctx.session:Clean()
	for target in pulses do
		if target:IsDescendantOf(ctx.win) then
			setPulse(target :: GuiObject, false)
		end
	end
	if ctx.onClose then
		pcall(ctx.onClose :: any, ctx)
	end
	hideWindow(ctx, instant)
	local ok, selected = pcall(function()
		return GuiService.SelectedObject
	end)
	if ok and typeof(selected) == "Instance" and selected:IsDescendantOf(ctx.win) then
		pcall(function()
			GuiService.SelectedObject = nil
		end)
	end
	MenuController.Closed:Fire(ctx.name)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

function MenuController.has(name: string): boolean
	return MenuController.resolveName(name) ~= nil
end

function MenuController.getOpen(): string?
	return current
end

function MenuController.isOpen(name: string): boolean
	local canon = MenuController.resolveName(name)
	return canon ~= nil and current == canon
end

function MenuController.open(name: string): boolean
	local canon = MenuController.resolveName(name)
	if not canon then
		return false
	end
	local ok, result = pcall(ensurePage, canon)
	if not ok then
		warn(("[MenuController] could not build %s: %s"):format(canon, tostring(result)))
		return false
	end
	local ctx = result :: Ctx?
	if not ctx then
		return false
	end
	if current == canon and ctx.open then
		local scale = ctx.win:FindFirstChildOfClass("UIScale")
		if scale then
			local target = fitScale(ctx)
			scale.Scale = target * 1.04
			TweenService:Create(scale, Theme.TweenPop, { Scale = target }):Play()
		end
		return true
	end
	local prev = current
	if prev then
		local prevCtx = pages[prev]
		current = nil
		if prevCtx then
			deactivate(prevCtx, true)
		end
	end
	current = canon
	ctx.open = true
	ctx.session:Clean()
	showBackdrop(true)
	showWindow(ctx)
	if ctx.onOpen then
		local okOpen, err = pcall(ctx.onOpen :: any, ctx)
		if not okOpen then
			warn(("[MenuController] onOpen %s failed: %s"):format(canon, tostring(err)))
		end
	end
	refreshCtx(ctx)
	if isGamepadInput() then
		pcall(function()
			GuiService.SelectedObject = ctx.primary or ctx.closeButton
		end)
	end
	MenuController.Opened:Fire(canon)
	return true
end

function MenuController.close(name: string?): boolean
	local canon = if name == nil then current else MenuController.resolveName(name)
	if canon == nil or current ~= canon then
		return false
	end
	current = nil
	local ctx = pages[canon]
	if ctx then
		deactivate(ctx, false)
	end
	showBackdrop(false)
	return true
end

function MenuController.toggle(name: string): boolean
	local canon = MenuController.resolveName(name)
	if not canon then
		return false
	end
	if current == canon then
		return MenuController.close(canon)
	end
	return MenuController.open(canon)
end

function MenuController.closeAll()
	MenuController.close()
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local function onSnapshot(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end
	if typeof(snapshot.playtime) == "table" then
		playtimeBase = snapshot.playtime
		playtimeAt = os.clock()
	end
	-- optimistic settings: drop overrides the server has confirmed (or that never got confirmed)
	local settings = snapshot.settings
	local now = os.clock()
	for key, o in settingOverrides do
		local confirmed = typeof(settings) == "table" and settings[key] == o.value
		if confirmed or now - o.at > SETTINGS_OVERRIDE_TTL then
			settingOverrides[key] = nil
		end
	end
	queueRefresh()
end

function MenuController.init() end

function MenuController.start()
	if started then
		return
	end
	started = true
	ensureGui()

	StateController.Changed:Connect(onSnapshot)
	local existing = StateController.get()
	if existing then
		onSnapshot(existing)
	end
	-- Wanted: the Store's "Lose the Cops" button is only enabled while you have stars
	for _, attr in { "Cash", "IncomePerSec", "Rebirths", "Wanted" } do
		player:GetAttributeChangedSignal(attr):Connect(queueRefresh)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if current == nil then
			return
		end
		local key = input.KeyCode
		-- Backspace = keyboard "back" (Esc is mostly eaten by the Roblox menu); never while typing in the Codes box
		local back = key == Enum.KeyCode.Escape
			or key == Enum.KeyCode.ButtonB
			or (key == Enum.KeyCode.Backspace and not gameProcessed)
		if back then
			MenuController.close()
		end
	end)
	-- Esc / Android back open the Roblox menu instead of reaching InputBegan: close ours so it isn't left behind it
	pcall(function()
		GuiService.MenuOpened:Connect(function()
			if current ~= nil then
				MenuController.close()
			end
		end)
	end)

	-- Net.listen waits for the remote; never let that block the ticker below.
	task.spawn(function()
		local ok, err = pcall(Net.listen, "OpenUI", function(name: any)
			local canon = MenuController.resolveName(name)
			if not canon then
				return
			end
			if current ~= canon then
				playSound("Whoosh")
			end
			MenuController.open(canon)
		end)
		if not ok then
			warn("[MenuController] OpenUI listener failed: " .. tostring(err))
		end
	end)

	-- 1 Hz ticker for countdowns (daily reset, contracts reset, playtime gifts).
	while true do
		task.wait(1)
		local name = current
		local ctx = if name then pages[name] else nil
		local scale = if ctx and ctx.open then ctx.win:FindFirstChildOfClass("UIScale") else nil
		if ctx and scale then
			local target = fitScale(ctx)
			if math.abs(scale.Scale - target) > 0.02 then
				TweenService:Create(scale, Theme.TweenMedium, { Scale = target }):Play()
			end
		end
		if ctx and ctx.open and ctx.tick then
			local ok, err = pcall(ctx.tick :: any, ctx)
			if not ok then
				warn(("[MenuController] tick %s failed: %s"):format(ctx.name, tostring(err)))
			end
		end
	end
end

return MenuController
