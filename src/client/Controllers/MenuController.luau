--!strict
-- MenuController v2 (gta_ui_language §5.12-§5.15): every menu, re-housed in GTA's containers. The v1 modal "Kit.window"
-- cards are gone; the nine v1 menu names still route here (other systems and the OpenUI remote use them):
--
--   GearShop   -> a GTA interaction list menu at the gear counter (UI/ListMenu): upgrades + tools, Enter buys
--   Store      -> pause menu STORE tab (Robux passes / products)
--   Index      -> pause menu GARAGE tab (the car collection with a turntable preview)
--   Daily, Contracts, Gifts -> pause menu JOBS tab (daily contracts, the 7-day streak, playtime gifts)
--   Rebirth    -> pause menu STATS tab, "Prestige" section (the lead's rename)
--   Settings   -> pause menu SETTINGS tab
--   Codes      -> the phone's Codes app (PhoneController)
--
-- The pause menu (UI/PauseMenu): MAP · JOBS · GARAGE · STATS · STORE · SETTINGS. Opens on P (last tab) or M (MAP, via
-- MapScreenController), from the phone apps and the touch MAP button. Each tab is a list on the left (UI/ListMenu,
-- embedded) and a detail panel on the right. Keys: Up / Down / Enter / Left / Right inside the tab, Q / E tabs,
-- Backspace closes. Esc belongs to Roblox (opening the Roblox menu closes ours).
--
-- Public API
--   open(name): boolean / close(name?): boolean / toggle(name): boolean / isOpen(name) / has(name) / getOpen() /
--   closeAll(), Opened: Signal(name), Closed: Signal(name)      (v1 routing API, canonical names above + aliases)
--   openPause(tab?, focus?) / closePause() / togglePause(tab?) / isPauseOpen(), PauseChanged: Signal(open)
--   refresh()                                                     re-render whatever is open
-- Remotes: listens to OpenUI(name). Sends BuyUpgrade, BuyTool, ClaimDaily, ClaimPlaytime, Rebirth, SetSetting and
-- RerollContract, all re-validated by the server. Store rows call MarketplaceService prompts; the server grants. Items
-- the server would refuse are greyed. State comes only from StateController and player attributes.
-- Pure helpers (resolveName, routeOf, dailyTileStates, playtimeTiles, contractRows, upgradeRows, toolRows, storeItems,
-- storeBlock, indexGroups, rebirthView, keptCars, settingValue, windowScale, detailSignature, playerRows, ...) are
-- exported for tests. STATS also lists the players in the server (the CoreGui player list is off, §8). A tab's detail
-- pane is rebuilt only when what it shows changes (detailSignature), so its buttons survive the 1 Hz refresh.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")

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
local AudioMix = require(Shared:WaitForChild("Audio"):WaitForChild("Mix")) -- [C3 audio integration] volume rows

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local ListMenu = require(UI:WaitForChild("ListMenu"))
local PauseMenu = require(UI:WaitForChild("PauseMenu"))
local RichText = require(UI:WaitForChild("RichText"))

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
local CARD_PITCH = 20
local SPIN_SPEED = 30 -- degrees per second for the garage preview turntable
local FRAME_TIGHTNESS = 0.8 -- < 1 = car fills more of the viewport
local CONFIRM_WINDOW = 4 -- seconds the "press again" prestige confirm stays armed
local PENDING_SECONDS = 3 -- claim / buy rows show "..." this long waiting for the server
local SETTINGS_OVERRIDE_TTL = 4 -- optimistic setting values expire if the server never confirms them
local SWAP_REMOTE = "RerollContract" -- (contractId) daily free contract swap; the button hides until it exists
local SWAP_AVAILABLE = table.find(Remotes.ClientToServer, SWAP_REMOTE) ~= nil

local SECRET_COLOR = Theme.Rarity.Secret -- Secret's tier color is black: unreadable on dark panels

local DEFAULT_SETTINGS: { [string]: boolean } =
	{ music = true, sfx = true, hideHud = false, autoAccelerate = false, speedo = false }

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
		return { icon = "gift", text = "GIFT", sub = nil, color = Theme.Colors.Text }
	end
	local kind = reward.kind
	if kind == "cash" then
		return { icon = "cash", text = Format.cash(num(reward.amount, 0)), sub = "CASH", color = Theme.Colors.Green }
	elseif kind == "incomeMinutes" then
		local minutes = num(reward.amount, 0)
		local floor = if finite(reward.min) then math.max(0, reward.min) else MIN_INCOME_REWARD
		local estimate = math.max(floor, math.floor(minutes * 60 * math.max(0, num(incomePerSec, 0))))
		return {
			icon = "time",
			text = `{fmtNum(minutes)} MIN`,
			sub = `≈ {Format.cash(estimate)}`,
			color = Theme.Colors.Secondary,
		}
	elseif kind == "car" then
		local rid = if typeof(reward.rarity) == "string" then reward.rarity else "Rare"
		return {
			icon = "car",
			text = `{string.upper(rid)} CAR`,
			sub = "RANDOM",
			color = MenuController.rarityColor(rid),
		}
	end
	return { icon = "gift", text = "GIFT", sub = nil, color = Theme.Colors.Text }
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

-- Contract stat -> glyph key (Config/UIAssets hud sheet / minimap atlas names; no emoji).
local CONTRACT_ICONS: { [string]: string } = {
	steal = "car",
	deliverRare = "car",
	deliverEpic = "car",
	playerSteal = "person",
	escape3 = "badge",
	escape = "badge",
	defend = "person",
	collectCash = "cash",
	driftSeconds = "drift",
	topSpeedHit = "nitro",
	chop = "wrench",
	dealerBuy = "car",
	hotDrop = "flame",
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
					icon = CONTRACT_ICONS[def.stat] or "target",
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
	hotwire = { icon = "wrench", caption = "Hold time", color = Theme.Colors.Yellow },
	nitro = { icon = "nitro", caption = "Nitro tank", color = Theme.Colors.Yellow },
	armor = { icon = "car", caption = "Damage taken", color = Theme.Colors.Blue },
	lock = { icon = "lock", caption = "Lock time", color = Theme.Colors.Red },
}
local DEFAULT_UPGRADE_STYLE: UpgradeStyle = { icon = "plus", caption = "Level", color = Theme.Colors.Blue }

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
	bat = { icon = "person", color = Theme.Colors.Yellow },
	taser = { icon = "nitro", color = Theme.Colors.Blue },
	spikes = { icon = "minus", color = Theme.Colors.Red },
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
		local style = TOOL_STYLE[id] or { icon = "wrench", color = Theme.Colors.Blue }
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
	local hue = (Theme.Rarity :: any)[rid]
	if hue then
		return hue
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
		table.insert(out, "Store exclusive")
		return out
	end
	if def.street then
		table.insert(out, "Streets")
	end
	if def.dealer then
		table.insert(out, "Dealer")
	end
	local tier = (Rarity.Tiers :: any)[def.rarity]
	if tier and tier.order >= 5 then
		table.insert(out, "Hot Drops")
	end
	if REWARD_RARITIES[def.rarity] then
		table.insert(out, "Rewards")
	end
	if #out == 0 then
		table.insert(out, "Unknown")
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
-- Routing (pure)
-------------------------------------------------------------------------------------------------------------------------

export type Route = { kind: string, tab: string?, focus: string?, app: string? }

-- Where each canonical menu lives in v2: the gear counter is a list menu, Codes a phone app, everything else a pause
-- tab (focus = the section of the tab to select first).
MenuController.ROUTES = {
	GearShop = { kind = "list" },
	Store = { kind = "pause", tab = "STORE" },
	Index = { kind = "pause", tab = "GARAGE" },
	Daily = { kind = "pause", tab = "JOBS", focus = "daily" },
	Contracts = { kind = "pause", tab = "JOBS", focus = "contracts" },
	Gifts = { kind = "pause", tab = "JOBS", focus = "gifts" },
	Rebirth = { kind = "pause", tab = "STATS", focus = "prestige" },
	Codes = { kind = "phone", app = "codes" },
	Settings = { kind = "pause", tab = "SETTINGS" },
} :: { [string]: Route }

MenuController.PAUSE_TABS = {
	{ id = "MAP", label = "Map" },
	{ id = "JOBS", label = "Jobs" },
	{ id = "GARAGE", label = "Garage" },
	{ id = "STATS", label = "Stats" },
	{ id = "STORE", label = "Store" },
	{ id = "SETTINGS", label = "Settings" },
}

function MenuController.routeOf(name: any): Route?
	local canon = MenuController.resolveName(name)
	return if canon then MenuController.ROUTES[canon] else nil
end

-- Daily-track row text: "Day 3   $1.5K" / state word for the value column.
function MenuController.dailyRowValue(state: string, countdown: string?): string
	if state == "claimed" then
		return "CLAIMED"
	elseif state == "ready" then
		return "CLAIM"
	elseif state == "next" then
		return if countdown then countdown else "TOMORROW"
	end
	return ""
end

-- What a tab's detail pane shows for `item`, as a string: the pane is rebuilt only when this changes (not on every
-- 1 Hz refresh or snapshot), so its buttons survive and the garage preview keeps its car. `extra` carries state the
-- row text does not show (a prestige confirm, a swap that just became possible, ...).
function MenuController.detailSignature(item: any, extra: string?): string
	if typeof(item) ~= "table" then
		return ""
	end
	return table.concat({
		tostring(item.id or ""),
		tostring(item.label or ""),
		tostring(item.value or ""),
		tostring(item.disabled == true),
		tostring(item.optionIndex or ""),
		extra or "",
	}, "|")
end

export type PlayerEntry = {
	userId: number,
	name: string,
	cash: number,
	steals: number,
	rebirths: number,
	wanted: number,
	isYou: boolean,
}

-- STATS "Players" rows (the CoreGui player list is off, §8): you first, then by cash, richest first.
function MenuController.playerRows(entries: { PlayerEntry }): { any }
	local list = table.clone(entries)
	table.sort(list, function(a: PlayerEntry, b: PlayerEntry): boolean
		if a.isYou ~= b.isYou then
			return a.isYou
		end
		if a.cash ~= b.cash then
			return a.cash > b.cash
		end
		return a.name < b.name
	end)
	local rows = {}
	for _, e in list do
		-- display names may hold < > & and the rows are rich text
		local name = RichText.escape(e.name)
		table.insert(rows, {
			id = "player:" .. tostring(e.userId),
			label = if e.isYou then name .. "  (you)" else name,
			value = Format.cash(e.cash),
			data = { section = "players", entry = e },
		})
	end
	return rows
end

-------------------------------------------------------------------------------------------------------------------------
-- Runtime state
-------------------------------------------------------------------------------------------------------------------------

type Tab = {
	id: string,
	list: any?, -- UI/ListMenu (embedded)
	detail: Frame?,
	refresh: ((Tab) -> ())?,
	select: ((Tab, any) -> ())?,
	describe: ((Tab, any) -> ())?,
	change: ((Tab, any, number) -> ())?,
	sig: ((Tab, any) -> string)?, -- extra detail-pane state (MenuController.detailSignature)
	describedSig: string?,
	focus: string?,
}

local pause: any = nil -- UI/PauseMenu
local gear: any = nil -- UI/ListMenu (gear counter)
local tabs: { [string]: Tab } = {}
local current: string? = nil -- canonical name of the open route
local started = false
local refreshQueued = false
local playtimeBase: any = nil -- snapshot.playtime as last received
local playtimeAt = os.clock() -- os.clock() when it arrived
local settingOverrides: { [string]: { value: boolean, at: number } } = {}
local priceCache: { [string]: number | boolean } = {} -- "pass:123" -> Robux price, or false while unknown
local pending: { [string]: number } = {} -- purchase / claim key -> os.clock() it was sent
local prestigeArmedAt = -math.huge
local localPrefs = { cash = true }

-------------------------------------------------------------------------------------------------------------------------
-- Lazy dependencies
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

-- The over-the-shoulder camera (combat) locks and hides the cursor while a gun is drawn: the pause menu and the gear
-- list suspend it while they are up so their rows can be clicked (ShoulderCamera contract).
local function suspendShoulderCamera(reason: string, on: boolean)
	local cam = lazy("ShoulderCamera")
	if cam and typeof(cam.setSuspended) == "function" then
		pcall(cam.setSuspended, reason, on)
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
	return if typeof(v) == "number" and v == v then v else nil
end

local function currentCash(): number
	local a = attrNumber("Cash")
	if a then
		return a
	end
	local s = getSnapshot()
	return if s and finite(s.cash) then s.cash else 0
end

local function currentIncome(): number
	local a = attrNumber("IncomePerSec")
	if a then
		return a
	end
	local s = getSnapshot()
	return if s and finite(s.incomePerSec) then s.incomePerSec else 0
end

local function currentRebirths(): number
	local a = attrNumber("Rebirths")
	if a then
		return a
	end
	local s = getSnapshot()
	return if s and finite(s.rebirths) then s.rebirths else 0
end

local function serverNow(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return if ok and typeof(t) == "number" then t else os.time()
end

local function isPending(key: string): boolean
	local at = pending[key]
	return at ~= nil and os.clock() - at < PENDING_SECONDS
end

local function markPending(key: string)
	pending[key] = os.clock()
	task.delay(PENDING_SECONDS + 0.05, function()
		if pending[key] and os.clock() - pending[key] >= PENDING_SECONDS then
			pending[key] = nil
			MenuController.refresh()
		end
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Detail pane helpers (right half of a pause tab)
-------------------------------------------------------------------------------------------------------------------------

local C = Theme.Colors

local function clearDetail(f: Frame)
	for _, c in f:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local detailOrder = 0
local function nextOrder(): number
	detailOrder += 1
	return detailOrder
end

-- plain = `text` is user text (a display name): escaped after the upper-casing so < > & show as written.
local function dTitle(f: Frame, text: string, color: Color3?, plain: boolean?)
	local shown = string.upper(text)
	Kit.text(if plain then RichText.escape(shown) else shown, "condensed", 24, {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 32),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color or C.Text,
		LayoutOrder = nextOrder(),
		Parent = f,
	})
end

local function dLine(f: Frame, text: string, color: Color3?, size: number?)
	Kit.text(text, "body", size or 14, {
		Name = "Line",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color or C.Text,
		LayoutOrder = nextOrder(),
		Parent = f,
	})
end

local function dPair(f: Frame, label: string, value: string, color: Color3?)
	local row = Kit.new("Frame", {
		Name = "Pair",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = nextOrder(),
		Parent = f,
	})
	Kit.text(string.upper(label), "condensedMedium", 14, {
		Size = UDim2.fromScale(0.55, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		Parent = row,
	})
	Kit.text(value, "condensedMedium", 16, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.45, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = color or C.Text,
		Parent = row,
	})
end

local function dBar(f: Frame, fraction: number, color: Color3)
	local bar, set = Kit.progressBar(color, {
		Name = "Progress",
		Size = UDim2.new(1, 0, 0, 6),
		LayoutOrder = nextOrder(),
		Parent = f,
	})
	bar.BackgroundColor3 = color:Lerp(C.Black, 0.6)
	set(fraction, false)
end

local function dGap(f: Frame, h: number)
	Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, h),
		LayoutOrder = nextOrder(),
		Parent = f,
	})
end

local function dAction(f: Frame, key: string?, label: string, fn: () -> ())
	local btn = Kit.instructionButton(if Kit.isTouch() then nil else key, label, {
		LayoutOrder = nextOrder(),
		Parent = f,
	})
	if Kit.isTouch() then
		btn.BackgroundColor3 = C.TextPure
		btn.BackgroundTransparency = 0
		btn.Size = UDim2.fromOffset(0, 40)
		Kit.padding(0, 14).Parent = btn
		local l = btn:FindFirstChild("Label")
		if l and l:IsA("TextLabel") then
			l.TextColor3 = C.Black
			l.TextSize = 18
		end
	end
	btn.Activated:Connect(fn)
end

local redescribe: (tab: Tab, force: boolean?) -> ()

-- A two-pane tab: list left (42%), detail panel right.
local function twoPane(tab: Tab, content: Frame, subtitle: string)
	local left = Kit.new("Frame", {
		Name = "ListHost",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.42, 1),
		Parent = content,
	})
	local touch = Kit.isTouch()
	tab.list = ListMenu.embed(left, {
		title = subtitle,
		subtitle = subtitle,
		visibleRows = if touch then 6 else 13,
		bindKeys = false,
	})
	local detail = Kit.panel({
		Name = "Detail",
		Position = UDim2.fromScale(0.44, 0),
		Size = UDim2.fromScale(0.56, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = content,
	})
	Kit.padding(14, 18).Parent = detail
	Kit.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = detail
	Kit.new("UISizeConstraint", { MinSize = Vector2.new(0, 120), Parent = detail })
	tab.detail = detail
	tab.list.Moved:Connect(function()
		redescribe(tab)
	end)
	tab.list.Selected:Connect(function(item: any)
		if tab.select then
			tab.select(tab, item)
		end
	end)
	tab.list.Changed:Connect(function(item: any, index: number)
		if tab.change then
			tab.change(tab, item, index)
		end
	end)
end

-- Rebuild the detail pane only when what it shows changed (force: state the signature cannot see changed).
redescribe = function(tab: Tab, force: boolean?)
	local list = tab.list
	local detail = tab.detail
	if not (list and detail and tab.describe) then
		return
	end
	local item = list:getSelected()
	local sig = if item then MenuController.detailSignature(item, if tab.sig then tab.sig(tab, item) else nil) else ""
	if not force and sig == tab.describedSig then
		return
	end
	tab.describedSig = sig
	clearDetail(detail)
	detailOrder = 0
	if item then
		tab.describe(tab, item)
	end
end

local function focusSection(tab: Tab, sectionId: string?)
	local list = tab.list
	if not (list and sectionId) then
		return
	end
	for i, item in list.items do
		if item.data and item.data.section == sectionId and not item.separator then
			list:select(i)
			return
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- JOBS: daily contracts, the 7-day streak, playtime gifts
-------------------------------------------------------------------------------------------------------------------------

local function sessionExtra(): number
	return os.clock() - playtimeAt
end

local function refreshJobs(tab: Tab)
	local snap = getSnapshot()
	local income = currentIncome()
	local items = {}
	local resetIn = MenuController.formatHhMm(MenuController.secondsUntilUtcMidnight(serverNow()))
	table.insert(items, { separator = true, label = "Daily contracts  ·  new in " .. resetIn })
	for _, row in MenuController.contractRows(if snap then snap.contracts else nil, income) do
		table.insert(items, {
			id = row.id,
			label = row.text,
			value = if row.claimed then "PAID" elseif row.done then "DONE" else MenuController.contractProgressText(row),
			disabled = row.done,
			data = { section = "contracts", row = row },
		})
	end
	table.insert(items, { separator = true, label = "Daily reward" })
	local daily = if snap then snap.daily else nil
	for i, state in MenuController.dailyTileStates(daily) do
		local info = MenuController.rewardInfo(Economy.DAILY_REWARDS[i], income)
		local key = "daily"
		table.insert(items, {
			id = "daily" .. i,
			label = `Day {i}   {info.text}`,
			value = if state == "ready" and isPending(key) then "..." else MenuController.dailyRowValue(state, nil),
			disabled = state ~= "ready",
			color = if state == "ready" then C.Green else nil,
			data = { section = "daily", day = i, state = state, info = info },
		})
	end
	table.insert(items, { separator = true, label = "Playtime gifts" })
	for _, tile in MenuController.playtimeTiles(playtimeBase, sessionExtra()) do
		local def = Economy.PLAYTIME_REWARDS[tile.index]
		local info = MenuController.rewardInfo(def, income)
		local key = "gift" .. tile.index
		local value = if tile.state == "claimed"
			then "CLAIMED"
			elseif tile.state == "ready" then (if isPending(key) then "..." else "CLAIM")
			else Format.clock(math.ceil(tile.remaining))
		table.insert(items, {
			id = key,
			label = `{def.minutes} min   {info.text}`,
			value = value,
			disabled = tile.state ~= "ready",
			color = if tile.state == "ready" then C.Green else nil,
			data = { section = "gifts", tile = tile, info = info },
		})
	end
	tab.list:setItems(items, true)
	redescribe(tab)
end

local function describeJobs(tab: Tab, item: any)
	local f = tab.detail :: Frame
	local d = item.data or {}
	if d.section == "contracts" then
		local row = d.row
		dTitle(f, row.text)
		dLine(f, "Daily contract. Progress counts automatically; the reward pays out the moment it is done.", C.TextDim)
		dGap(f, 4)
		dPair(f, "Progress", MenuController.contractProgressText(row))
		dBar(f, row.fraction, if row.done then C.Green else C.Yellow)
		dPair(f, "Reward", Format.cash(row.rewardCash), C.Green)
		local snap = getSnapshot()
		if MenuController.canSwapContract(if snap then snap.contracts else nil, row, SWAP_AVAILABLE) then
			dGap(f, 6)
			dAction(f, "X", "Swap this job (free, once a day)", function()
				Net.fire(SWAP_REMOTE, row.id)
				playSound("Click")
				markPending("swap")
			end)
		end
	elseif d.section == "daily" then
		dTitle(f, `Day {d.day} reward`)
		dLine(f, `{d.info.text}{if d.info.sub then "  (" .. d.info.sub .. ")" else ""}`, d.info.color, 18)
		local snap = getSnapshot()
		local streak = if snap and typeof(snap.daily) == "table" then num(snap.daily.streak, 0) else 0
		dPair(f, "Current streak", `{math.floor(streak)} days`)
		if d.state == "ready" then
			dLine(f, "Ready to claim. Come back every day to keep the streak.", C.Green)
			dAction(f, "Enter", "Claim", function()
				tab.select(tab, item)
			end)
		elseif d.state == "next" then
			local left = MenuController.formatHhMm(MenuController.secondsUntilUtcMidnight(serverNow()))
			dLine(f, `Claimable in {left}.`, C.TextDim)
		elseif d.state == "claimed" then
			dLine(f, "Claimed.", C.TextDim)
		else
			dLine(f, "Keep your streak going to reach this day.", C.TextDim)
		end
	elseif d.section == "gifts" then
		dTitle(f, "Playtime gift")
		dLine(f, `{d.info.text}{if d.info.sub then "  (" .. d.info.sub .. ")" else ""}`, d.info.color, 18)
		dBar(f, d.tile.fraction, if d.tile.state == "ready" then C.Green else C.Yellow)
		if d.tile.state == "ready" then
			dAction(f, "Enter", "Claim", function()
				tab.select(tab, item)
			end)
		elseif d.tile.state == "waiting" then
			dLine(f, `Ready in {Format.clock(math.ceil(d.tile.remaining))} of play today.`, C.TextDim)
		end
	end
end

local function sigJobs(_tab: Tab, item: any): string
	local d = item.data or {}
	if d.section == "contracts" then
		local snap = getSnapshot()
		local canSwap = MenuController.canSwapContract(if snap then snap.contracts else nil, d.row, SWAP_AVAILABLE)
		return `{canSwap}|{isPending("swap")}`
	elseif d.section == "daily" then
		local snap = getSnapshot()
		local streak = if snap and typeof(snap.daily) == "table" then num(snap.daily.streak, 0) else 0
		local left = if d.state == "next"
			then MenuController.formatHhMm(MenuController.secondsUntilUtcMidnight(serverNow()))
			else ""
		return `{streak}|{left}`
	end
	return ""
end

local function selectJobs(_tab: Tab, item: any)
	local d = item.data or {}
	if d.section == "daily" and d.state == "ready" and not isPending("daily") then
		Net.fire("ClaimDaily")
		markPending("daily")
		playSound("ClickBright")
		MenuController.refresh()
	elseif d.section == "gifts" and d.tile.state == "ready" and not isPending("gift" .. d.tile.index) then
		Net.fire("ClaimPlaytime", d.tile.index)
		markPending("gift" .. d.tile.index)
		playSound("ClickBright")
		MenuController.refresh()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- GARAGE: the car collection (v1 Index) with a turntable preview
-------------------------------------------------------------------------------------------------------------------------

local preview: { view: ViewportFrame?, model: Model?, camera: Camera?, carId: string?, yaw: number } = { yaw = 30 }

local function buildCarModel(carId: string): Model?
	local ok, model = pcall(function()
		local CarBuilder = (require :: any)(Shared:WaitForChild("Vehicle"):WaitForChild("CarBuilder"))
		return CarBuilder.build(carId, "None", { forDisplay = true, noShell = false })
	end)
	if ok and typeof(model) == "Instance" and model:IsA("Model") then
		return model
	end
	return nil
end

local function showPreview(f: Frame, carId: string?)
	local view = Kit.new("ViewportFrame", {
		Name = "Preview",
		BackgroundColor3 = C.Black,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 170),
		Ambient = Color3.fromRGB(150, 150, 160),
		LightColor = Color3.new(1, 1, 1),
		LightDirection = Vector3.new(-0.5, -1, -0.6),
		LayoutOrder = nextOrder(),
		Parent = f,
	})
	preview.view = view
	preview.model = nil
	preview.carId = carId
	if not carId then
		return
	end
	task.spawn(function()
		-- skimming the list with the mouse should not build a car per row passed over
		task.wait(0.12)
		if preview.view ~= view or not view.Parent then
			return
		end
		local model = buildCarModel(carId)
		if not model or preview.view ~= view or not view.Parent then
			if model then
				model:Destroy()
			end
			return
		end
		model.Parent = view
		local cam = Instance.new("Camera")
		cam.FieldOfView = VIEW_FOV
		cam.Parent = view
		view.CurrentCamera = cam
		preview.model = model
		preview.camera = cam
	end)
end

local function refreshGarage(tab: Tab)
	local snap = getSnapshot()
	local disc = if snap then snap.discovered else nil
	local found, total, bonus = MenuController.indexTotals(disc)
	local items = {}
	table.insert(items, {
		separator = true,
		label = `Collection {found}/{total}  ·  income bonus +{math.floor(bonus * 100 + 0.5)}%`,
	})
	for _, g in MenuController.indexGroups(disc) do
		table.insert(items, { separator = true, label = `{g.rarity}  {g.found}/{g.total}` })
		for _, def in g.cars do
			local known = typeof(disc) == "table" and disc[def.id] == true
			table.insert(items, {
				id = def.id,
				label = if known then def.name else "Undiscovered",
				value = if known then Format.cash(def.income) .. "/s" else "",
				color = if known then rarityColor(def.rarity) else nil,
				locked = not known,
				data = { section = "cars", def = def, known = known },
			})
		end
	end
	tab.list:setItems(items, true)
	redescribe(tab)
end

local function describeGarage(tab: Tab, item: any)
	local f = tab.detail :: Frame
	local d = item.data or {}
	local def = d.def
	if not def then
		return
	end
	if d.known then
		dTitle(f, def.name)
		Kit.text(string.upper(def.rarity), "condensedMedium", 14, {
			Size = UDim2.new(1, 0, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = rarityColor(def.rarity),
			LayoutOrder = nextOrder(),
			Parent = f,
		})
		showPreview(f, def.id)
		dPair(f, "Garage income", Format.cash(def.income) .. "/s", C.Green)
		dPair(f, "Top speed", `{math.floor(def.topSpeed)}`)
		dPair(f, "Found at", table.concat(MenuController.carSources(def), ", "))
	else
		dTitle(f, "Undiscovered", C.TextDim)
		Kit.text(string.upper(def.rarity), "condensedMedium", 14, {
			Size = UDim2.new(1, 0, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = rarityColor(def.rarity),
			LayoutOrder = nextOrder(),
			Parent = f,
		})
		showPreview(f, nil)
		dLine(f, "Steal or buy this car to add it to your collection.", C.TextDim)
		dPair(f, "Found at", table.concat(MenuController.carSources(def), ", "))
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- STATS: your numbers + Prestige (v1 Rebirth)
-------------------------------------------------------------------------------------------------------------------------

local function garageCount(snap: any): number
	if typeof(snap) ~= "table" or typeof(snap.garage) ~= "table" then
		return 0
	end
	local count = 0
	for _ in snap.garage do
		count += 1
	end
	return count
end

local function refreshStats(tab: Tab)
	local snap = getSnapshot()
	local stats: any = if snap and typeof(snap.stats) == "table" then snap.stats else {}
	local cash = currentCash()
	local rebirths = currentRebirths()
	local v = MenuController.rebirthView(cash, rebirths)
	local function n(k: string): string
		return Format.commas(num(stats[k], 0))
	end
	local mult = if snap and finite(snap.multiplier) then snap.multiplier else 1
	local vip = player:GetAttribute("VIP") == true or (snap and typeof(snap.passes) == "table" and snap.passes.vip)
	local items = {
		{ separator = true, label = "Career" },
		{ id = "cash", label = "Cash", value = Format.cash(cash), data = { section = "career" } },
		{
			id = "earned",
			label = "Total earned",
			value = Format.cash(if snap then num(snap.totalEarned, 0) else 0),
			data = { section = "career" },
		},
		{
			id = "income",
			label = "Garage income",
			value = Format.cash(currentIncome()) .. "/s",
			data = { section = "career" },
		},
		{
			id = "mult",
			label = "Income multiplier",
			value = MenuController.formatMultiplier(mult),
			data = { section = "career" },
		},
		{ id = "cars", label = "Cars in garage", value = tostring(garageCount(snap)), data = { section = "career" } },
		{ id = "steals", label = "Cars delivered", value = n("steals"), data = { section = "career" } },
		{ id = "psteals", label = "Player steals", value = n("playerSteals"), data = { section = "career" } },
		{ id = "hotdrops", label = "Hot drops", value = n("hotDrops"), data = { section = "career" } },
		{ id = "busted", label = "Times busted", value = n("busted"), data = { section = "career" } },
		{ id = "robbed", label = "Times robbed", value = n("timesRobbed"), data = { section = "career" } },
		{ id = "vip", label = "VIP", value = if vip then "YES" else "NO", data = { section = "career" } },
		{ separator = true, label = "Prestige" },
		{ id = "prestige", label = "Prestige level", value = tostring(v.rebirths), data = { section = "prestige" } },
		{
			id = "prestige_go",
			label = "Prestige now",
			value = if v.canAfford then Format.cash(v.cost) else "NEED " .. Format.cash(v.missing),
			disabled = not v.canAfford,
			data = { section = "prestige", action = true },
		},
	}
	-- the player list lives here (§8: the CoreGui PlayerList is off; leaderstats Cash / Steals still feed it)
	local entries: { PlayerEntry } = {}
	for _, p in Players:GetPlayers() do
		local ls = p:FindFirstChild("leaderstats")
		local cashV = ls and ls:FindFirstChild("Cash")
		local stealsV = ls and ls:FindFirstChild("Steals")
		local cashA = p:GetAttribute("Cash")
		table.insert(entries, {
			userId = p.UserId,
			name = Kit.sanitize(p.DisplayName),
			cash = if cashV and cashV:IsA("NumberValue")
				then cashV.Value
				elseif typeof(cashA) == "number" then cashA
				else 0,
			steals = if stealsV and stealsV:IsA("IntValue") then stealsV.Value else 0,
			rebirths = num(p:GetAttribute("Rebirths"), 0),
			wanted = num(p:GetAttribute("Wanted"), 0),
			isYou = p == player,
		})
	end
	table.insert(items, { separator = true, label = `Players in this city  ·  {#entries}` })
	for _, row in MenuController.playerRows(entries) do
		table.insert(items, row)
	end
	tab.list:setItems(items, true)
	redescribe(tab)
end

local function sigStats(_tab: Tab, item: any): string
	local d = item.data or {}
	if d.section == "prestige" then
		local v = MenuController.rebirthView(currentCash(), currentRebirths())
		local snap = getSnapshot()
		local armed = os.clock() - prestigeArmedAt < CONFIRM_WINDOW
		local kept = MenuController.keptCarsText(MenuController.keptCars(if snap then snap.garage else nil))
		return `{armed}|{v.canAfford}|{v.rebirths}|{math.floor(v.fraction * 100)}|{kept}`
	elseif d.section == "players" then
		local e = d.entry
		return `{e.steals}|{e.rebirths}|{e.wanted}`
	end
	return ""
end

local function describeStats(tab: Tab, item: any)
	local f = tab.detail :: Frame
	local d = item.data or {}
	if d.section == "prestige" then
		local v = MenuController.rebirthView(currentCash(), currentRebirths())
		local snap = getSnapshot()
		dTitle(f, "Prestige", C.Gold)
		dLine(
			f,
			"Cash in your run for a permanent income bonus. Your cash, garage cars and upgrades reset; your best cars stay.",
			C.TextDim
		)
		dGap(f, 4)
		dPair(f, "Level", `{v.rebirths} -> {v.rebirths + 1}`)
		dPair(
			f,
			"Income bonus",
			`{MenuController.formatMultiplier(v.multiplier)} -> {MenuController.formatMultiplier(v.nextMultiplier)}`,
			C.Green
		)
		dPair(f, "Cost", Format.cash(v.cost))
		dBar(f, v.fraction, if v.canAfford then C.Green else C.Gold)
		local kept = MenuController.keptCarsText(MenuController.keptCars(if snap then snap.garage else nil))
		dPair(f, "You keep", if kept ~= "" then kept else "-")
		if v.canAfford then
			local armed = os.clock() - prestigeArmedAt < CONFIRM_WINDOW
			dAction(f, "Enter", if armed then "Confirm prestige" else "Prestige", function()
				tab.select(tab, { data = { section = "prestige", action = true } })
			end)
		end
	elseif d.section == "players" then
		local e: PlayerEntry = d.entry
		dTitle(f, e.name, nil, true)
		dPair(f, "Cash", Format.cash(e.cash), C.Green)
		dPair(f, "Cars delivered", Format.commas(e.steals))
		dPair(f, "Prestige level", tostring(math.floor(e.rebirths)))
		dPair(
			f,
			"Wanted",
			if e.wanted > 0 then `{math.floor(e.wanted)} star{if e.wanted >= 2 then "s" else ""}` else "-",
			if e.wanted > 0 then C.Red else nil
		)
	else
		dTitle(f, item.label)
		dLine(f, item.value or "", C.Text, 22)
	end
end

local function selectStats(tab: Tab, item: any)
	local d = item.data or {}
	if not (d.section == "prestige" and d.action) then
		return
	end
	local v = MenuController.rebirthView(currentCash(), currentRebirths())
	local snap = getSnapshot()
	if not v.canAfford then
		toast("warning", "You need " .. Format.cash(v.missing) .. " more to prestige.")
		return
	end
	if MenuController.garageBusy(if snap then snap.garage else nil) then
		toast("warning", "Bring your cars home first: one is out driving or being stolen.")
		return
	end
	if os.clock() - prestigeArmedAt < CONFIRM_WINDOW then
		prestigeArmedAt = -math.huge
		Net.fire("Rebirth")
		playSound("ClickBright")
	else
		prestigeArmedAt = os.clock()
		playSound("Click")
		toast("info", "Press again to confirm your prestige.")
	end
	redescribe(tab, true)
end

-------------------------------------------------------------------------------------------------------------------------
-- STORE (Robux)
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
		toast("error", "The store isn't available right now. Try again in a moment.")
	end
end

local function priceKey(item: StoreItem): string
	return item.kind .. ":" .. tostring(item.id)
end

local function fetchPrice(item: StoreItem)
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
			MenuController.refresh()
		end
	end)
end

local BLOCK_TEXT: { [string]: string } = {
	owned = "OWNED",
	notWanted = "NOT WANTED",
}

local function refreshStore(tab: Tab)
	local snap = getSnapshot()
	local store = MenuController.storeItems(if snap then snap.passes else nil)
	local wanted = attrNumber("Wanted") or 0
	local items = {}
	if store.comingSoon then
		table.insert(items, { separator = true, label = "The store opens soon" })
	end
	local function add(list: { StoreItem }, caption: string)
		if #list == 0 then
			return
		end
		table.insert(items, { separator = true, label = caption })
		for _, it in list do
			fetchPrice(it)
			local block = MenuController.storeBlock(it, snap, wanted)
			local price = priceCache[priceKey(it)]
			table.insert(items, {
				id = it.key,
				label = it.name,
				value = if block
					then BLOCK_TEXT[block] or ""
					elseif typeof(price) == "number" then `R$ {price}`
					else "...",
				disabled = block ~= nil,
				data = { section = "store", item = it, block = block },
			})
		end
	end
	add(store.passes, "Game passes")
	add(store.products, "Products")
	tab.list:setItems(items, true)
	redescribe(tab)
end

local function describeStore(tab: Tab, item: any)
	local f = tab.detail :: Frame
	local d = item.data or {}
	local it = d.item
	if not it then
		dTitle(f, "Store")
		dLine(f, "Passes and boosts arrive soon.", C.TextDim)
		return
	end
	dTitle(f, it.name, if it.kind == "pass" then C.Gold else C.Text)
	dLine(f, it.description, C.Text)
	dGap(f, 6)
	if d.block then
		dLine(f, if d.block == "owned" then "You own this." else "Only while the police are after you.", C.TextDim)
	else
		dAction(f, "Enter", "Purchase", function()
			tab.select(tab, item)
		end)
	end
	dLine(f, "Robux purchases never sell power over other players.", C.TextDim, 12)
end

local function selectStore(_tab: Tab, item: any)
	local d = item.data or {}
	if not d.item then
		return
	end
	if d.block then
		playSound("Click")
		return
	end
	promptPurchase(d.item)
end

-------------------------------------------------------------------------------------------------------------------------
-- SETTINGS
-------------------------------------------------------------------------------------------------------------------------

type SettingDef = { key: string, label: string, desc: string, server: boolean }

local SETTING_DEFS: { SettingDef } = {
	{ key = "music", label = "Music and radio", desc = "Car radio and background music.", server = true },
	{ key = "sfx", label = "Sound effects", desc = "Engines, sirens, the city and the interface.", server = true },
	{
		key = "hideHud",
		label = "Streamer mode",
		desc = "Hides the HUD and other players' names for clean clips. Turn it off here, or on a touch screen with "
			.. "the small HUD button in the top-left corner.",
		server = true,
	},
	{
		key = "autoAccelerate",
		label = "Auto-accelerate",
		desc = "Cars drive forward on their own; steer and brake only. Handy on touch screens.",
		server = true,
	},
	{
		key = "speedo",
		label = "Speed readout",
		desc = "Shows your speed in mph while driving (GTA has none; off by default).",
		server = true,
	},
}

local function applySettingLocally(key: string, value: boolean)
	if key == "music" or key == "sfx" then
		local sounds = lazy("SoundController")
		if sounds and typeof(sounds.setEnabled) == "function" then
			pcall(sounds.setEnabled, key, value)
		end
	elseif key == "speedo" then
		player:SetAttribute("HC_ShowSpeedo", value)
	end
end

local function settingNow(def: SettingDef): boolean
	if not def.server then
		return (localPrefs :: any)[def.key] == true
	end
	local snap = getSnapshot()
	local overrides: { [string]: boolean } = {}
	for k, o in settingOverrides do
		overrides[k] = o.value
	end
	return MenuController.settingValue(if snap then snap.settings else nil, overrides, def.key)
end

local function refreshSettings(tab: Tab)
	local items = { { separator = true, label = "Game" } }
	for _, def in SETTING_DEFS do
		table.insert(items, {
			id = def.key,
			label = def.label,
			options = { "Off", "On" },
			optionIndex = if settingNow(def) then 2 else 1,
			desc = def.desc,
			data = { section = "settings", def = def },
		})
	end
	-- [C3 audio integration] per-channel volume sliders (Shared/Audio/Mix.SLIDERS -> SoundController.setVolume)
	local sounds = lazy("SoundController")
	if sounds and typeof(sounds.getVolume) == "function" and typeof(sounds.setVolume) == "function" then
		table.insert(items, { separator = true, label = "Audio" })
		local labels = AudioMix.stepLabels()
		for _, slider in AudioMix.SLIDERS do
			local okVol, vol = pcall(sounds.getVolume, slider.channel)
			local step = AudioMix.volumeToStep(if okVol and typeof(vol) == "number" then vol else 1)
			table.insert(items, {
				id = "vol_" .. slider.channel,
				label = slider.label,
				options = labels,
				optionIndex = step,
				desc = slider.desc,
				data = { section = "volume", slider = slider, step = step },
			})
		end
	end
	table.insert(items, { separator = true, label = "More" })
	table.insert(items, { id = "codes", label = "Redeem a code", value = "PHONE", data = { section = "codes" } })
	local tut = lazy("TutorialController")
	if tut and typeof(tut.isActive) == "function" and tut.isActive() then
		table.insert(items, { id = "skip", label = "Skip the tutorial", value = "", data = { section = "skip" } })
	end
	tab.list:setItems(items, true)
	redescribe(tab)
end

local function setSetting(def: SettingDef, value: boolean)
	if def.server then
		settingOverrides[def.key] = { value = value, at = os.clock() }
		Net.fire("SetSetting", def.key, value)
	end
	applySettingLocally(def.key, value)
	playSound("Click")
end

-- [C3 audio integration] apply a volume row's step (clamped at the ends: the list wraps, a slider must not)
local function setVolumeRow(tab: Tab, item: any, step: number)
	local d = item.data
	local sounds = lazy("SoundController")
	d.step = step
	item.optionIndex = step
	if sounds and typeof(sounds.setVolume) == "function" then
		pcall(sounds.setVolume, d.slider.channel, AudioMix.stepToVolume(step))
	end
	tab.list:setItems(tab.list.items, true)
	playSound("Click")
end

local function describeSettings(tab: Tab, item: any)
	local f = tab.detail :: Frame
	local d = item.data or {}
	if d.section == "volume" then
		dTitle(f, d.slider.label)
		dLine(f, d.slider.desc, C.TextDim)
		dPair(f, "Now", ("%d%%"):format(math.floor(AudioMix.stepToVolume(d.step or AudioMix.STEPS) * 100 + 0.5)))
		dLine(
			f,
			if Kit.isTouch() then "Tap the selected row to turn it up." else "Left / Right to set the level.",
			C.TextDim,
			if Kit.isTouch() then 16 else 12
		)
	elseif d.section == "settings" then
		dTitle(f, d.def.label)
		dLine(f, d.def.desc, C.TextDim)
		dPair(f, "Now", if settingNow(d.def) then "ON" else "OFF", if settingNow(d.def) then C.Green else C.TextDim)
		dLine(
			f,
			if Kit.isTouch() then "Tap the selected row to switch." else "Left / Right or Enter to switch.",
			C.TextDim,
			if Kit.isTouch() then 16 else 12
		)
	elseif d.section == "codes" then
		dTitle(f, "Codes")
		dLine(f, "Codes are redeemed in the Codes app on your phone.", C.TextDim)
	elseif d.section == "skip" then
		dTitle(f, "Skip the tutorial")
		dLine(f, "You can always find help in the phone's Jobs app.", C.TextDim)
	end
end

local function changeSettings(tab: Tab, item: any, index: number)
	local d = item.data or {}
	if d.section == "volume" then
		setVolumeRow(tab, item, AudioMix.sliderStep(d.step or AudioMix.STEPS, index, AudioMix.STEPS))
		redescribe(tab, true)
	elseif d.section == "settings" then
		setSetting(d.def, index == 2)
		redescribe(tab, true)
	end
end

local function selectSettings(tab: Tab, item: any)
	local d = item.data or {}
	if d.section == "volume" then
		-- Enter / tap: one step up, 100 % wraps to 0 % (touch has no Left / Right)
		local step = d.step or AudioMix.STEPS
		setVolumeRow(tab, item, if step >= AudioMix.STEPS then 1 else step + 1)
		redescribe(tab, true)
	elseif d.section == "settings" then
		local now = settingNow(d.def)
		item.optionIndex = if now then 1 else 2
		setSetting(d.def, not now)
		tab.list:setItems(tab.list.items, true)
		redescribe(tab, true)
	elseif d.section == "codes" then
		MenuController.closePause()
		local phone = lazy("PhoneController")
		if phone and typeof(phone.openApp) == "function" then
			pcall(phone.openApp, "codes")
		end
	elseif d.section == "skip" then
		local tut = lazy("TutorialController")
		if tut and typeof(tut.skip) == "function" then
			pcall(tut.skip)
		end
		refreshSettings(tab)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Gear counter (list menu)
-------------------------------------------------------------------------------------------------------------------------

local function refreshGear()
	if not gear then
		return
	end
	local snap = getSnapshot()
	local cash = currentCash()
	local items = { { separator = true, label = "Upgrades" } }
	for _, row in MenuController.upgradeRows(snap, cash) do
		local key = "up:" .. row.id
		local value = if row.maxed then "MAX" elseif isPending(key) then "..." else Format.cash(row.price or 0)
		table.insert(items, {
			id = row.id,
			label = `{row.name}  {row.level}/{row.maxLevel}`,
			value = value,
			disabled = row.maxed or not row.affordable,
			desc = if row.maxed
				then `{row.description} Maxed out: {row.currentText}.`
				else `{row.description} {row.caption}: {row.currentText} -> {row.nextText}.`,
			data = { kind = "upgrade", row = row },
		})
	end
	table.insert(items, { separator = true, label = "Tools" })
	for _, row in MenuController.toolRows(snap, cash) do
		local key = "tool:" .. row.id
		table.insert(items, {
			id = row.id,
			label = row.name,
			value = if row.owned then "OWNED" elseif isPending(key) then "..." else Format.cash(row.price),
			disabled = row.owned or not row.affordable,
			desc = row.description,
			data = { kind = "tool", row = row },
		})
	end
	gear:setItems(items, true)
	gear:setSubtitle("Gear  ·  " .. Format.cash(cash))
end

local function selectGear(item: any)
	local d = item.data or {}
	local row = d.row
	if not row then
		return
	end
	if d.kind == "upgrade" then
		-- the row shows "..." while a buy is on its way: a second Enter / tap must not buy a second level
		if row.maxed or isPending("up:" .. row.id) then
			playSound("Click")
			return
		elseif not row.affordable then
			toast("warning", "Not enough cash for " .. row.name .. ".")
			return
		end
		Net.fire("BuyUpgrade", row.id)
		markPending("up:" .. row.id)
	elseif d.kind == "tool" then
		if row.owned or isPending("tool:" .. row.id) then
			playSound("Click")
			return
		elseif not row.affordable then
			toast("warning", "Not enough cash for " .. row.name .. ".")
			return
		end
		Net.fire("BuyTool", row.id)
		markPending("tool:" .. row.id)
	end
	playSound("ClickBright")
	refreshGear()
end

local function ensureGear(): any
	if gear then
		return gear
	end
	gear = ListMenu.new({ title = "Gear Shop", banner = "gear", subtitle = "Gear" })
	gear.Selected:Connect(selectGear)
	gear.Closed:Connect(function()
		suspendShoulderCamera("gear", false)
		if current == "GearShop" then
			current = nil
			MenuController.Closed:Fire("GearShop")
		end
	end)
	return gear
end

-------------------------------------------------------------------------------------------------------------------------
-- Pause menu
-------------------------------------------------------------------------------------------------------------------------

local TAB_IMPL: {
	[string]: {
		subtitle: string,
		refresh: (Tab) -> (),
		describe: (Tab, any) -> (),
		select: ((Tab, any) -> ())?,
		change: ((Tab, any, number) -> ())?,
		sig: ((Tab, any) -> string)?,
	},
} =
	{
		JOBS = { subtitle = "Jobs", refresh = refreshJobs, describe = describeJobs, select = selectJobs, sig = sigJobs },
		GARAGE = { subtitle = "Car collection", refresh = refreshGarage, describe = describeGarage },
		STATS = {
			subtitle = "Stats",
			refresh = refreshStats,
			describe = describeStats,
			select = selectStats,
			sig = sigStats,
		},
		STORE = { subtitle = "Store", refresh = refreshStore, describe = describeStore, select = selectStore },
		SETTINGS = {
			subtitle = "Settings",
			refresh = refreshSettings,
			describe = describeSettings,
			select = selectSettings,
			change = changeSettings,
		},
	}

local function commaCash(n: number): string
	return "$" .. Format.commas(n)
end

local function pauseInfo()
	if not pause then
		return
	end
	local clock = Lighting.ClockTime
	local h = math.floor(clock)
	local m = math.floor((clock - h) * 60)
	local day = os.date("!%A", math.floor(serverNow()))
	pause:setInfo(
		player.DisplayName,
		`{string.upper(string.sub(day, 1, 3))} {string.format("%02d:%02d", h, m)}`,
		commaCash(currentCash())
	)
end

local NAV_ACTION = "HC_PauseNav"

local function activeTab(): Tab?
	if not (pause and pause:isOpen()) then
		return nil
	end
	return tabs[pause:getTab()]
end

local function bindNav()
	ContextActionService:BindActionAtPriority(
		NAV_ACTION,
		function(_, state: Enum.UserInputState, input: InputObject)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local tab = activeTab()
			local list = tab and tab.list
			if not list then
				return Enum.ContextActionResult.Pass
			end
			local k = input.KeyCode
			if k == Enum.KeyCode.Up or k == Enum.KeyCode.DPadUp then
				list:move(-1)
			elseif k == Enum.KeyCode.Down or k == Enum.KeyCode.DPadDown then
				list:move(1)
			elseif k == Enum.KeyCode.Left or k == Enum.KeyCode.DPadLeft then
				list:change(-1)
			elseif k == Enum.KeyCode.Right or k == Enum.KeyCode.DPadRight then
				list:change(1)
			elseif k == Enum.KeyCode.Return or k == Enum.KeyCode.KeypadEnter or k == Enum.KeyCode.ButtonA then
				list:activate()
			elseif k == Enum.KeyCode.X or k == Enum.KeyCode.ButtonX then
				if tab and tab.id == "JOBS" then
					local item = list:getSelected()
					local d = item and item.data
					local snap = getSnapshot()
					if
						d
						and d.section == "contracts"
						and MenuController.canSwapContract(if snap then snap.contracts else nil, d.row, SWAP_AVAILABLE)
					then
						Net.fire(SWAP_REMOTE, d.row.id)
						playSound("Click")
					end
				end
			else
				return Enum.ContextActionResult.Pass
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 29,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter,
		Enum.KeyCode.X,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.ButtonX
	)
end

local function onTab(id: string)
	local map = lazy("MapScreenController")
	if id == "MAP" then
		pause:setTransparent(true)
		pause:setFooter({ { key = "Q", label = "Prev" }, { key = "E", label = "Next" } })
		if map and typeof(map.show) == "function" then
			pcall(map.show)
		end
	else
		pause:setTransparent(false)
		if map and typeof(map.hide) == "function" then
			pcall(map.hide)
		end
		pause:setFooter({
			{ key = "Enter", label = "Select" },
			{ key = "Q", label = "Prev" },
			{ key = "E", label = "Next" },
		})
		local tab = tabs[id]
		if tab and tab.refresh then
			tab.refresh(tab)
			if tab.focus then
				focusSection(tab, tab.focus)
				tab.focus = nil
			end
			redescribe(tab)
		end
	end
	playSound("Click")
end

local function ensurePause(): any
	if pause then
		return pause
	end
	pause = PauseMenu.new({ tabs = MenuController.PAUSE_TABS })
	for id, impl in TAB_IMPL do
		local tab: Tab = {
			id = id,
			refresh = impl.refresh,
			describe = impl.describe,
			select = impl.select,
			change = impl.change,
			sig = impl.sig,
		}
		twoPane(tab, pause:content(id), impl.subtitle)
		tabs[id] = tab
	end
	pause.TabChanged:Connect(onTab)
	pause.Closed:Connect(function()
		ContextActionService:UnbindAction(NAV_ACTION)
		local map = lazy("MapScreenController")
		if map and typeof(map.hide) == "function" then
			pcall(map.hide)
		end
		local was = current
		if was and MenuController.ROUTES[was] and MenuController.ROUTES[was].kind == "pause" then
			current = nil
			MenuController.Closed:Fire(was)
		end
		suspendShoulderCamera("pause", false)
		MenuController.PauseChanged:Fire(false)
	end)
	return pause
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

MenuController.PauseChanged = Signal.new() -- (open: boolean)

-- Open the pause menu on a tab ("MAP", "JOBS", "GARAGE", "STATS", "STORE", "SETTINGS").
function MenuController.openPause(tabId: string?, focus: string?)
	local p = ensurePause()
	local id = if typeof(tabId) == "string" and tabs[tabId] ~= nil or tabId == "MAP" then tabId else nil
	if gear and gear:isOpen() then
		gear:close()
	end
	local phone = lazy("PhoneController")
	if phone and typeof(phone.close) == "function" then
		pcall(phone.close)
	end
	if id and focus and tabs[id] then
		tabs[id].focus = focus
	end
	local wasOpen = p:isOpen()
	pauseInfo()
	p:open(id)
	if not wasOpen then
		bindNav()
		playSound("Whoosh")
		suspendShoulderCamera("pause", true)
		MenuController.PauseChanged:Fire(true)
	end
end

function MenuController.closePause()
	if pause and pause:isOpen() then
		pause:close()
	end
end

function MenuController.isPauseOpen(): boolean
	return pause ~= nil and pause:isOpen()
end

function MenuController.togglePause(tabId: string?)
	if MenuController.isPauseOpen() and (tabId == nil or pause:getTab() == tabId) then
		MenuController.closePause()
	else
		MenuController.openPause(tabId)
	end
end

-- Re-render whatever is open (snapshot / cash changes, purchases).
function MenuController.refresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		local tab = activeTab()
		if tab and tab.refresh then
			local ok, err = pcall(tab.refresh :: any, tab)
			if not ok then
				warn("[MenuController] refresh failed: " .. tostring(err))
			end
		end
		if gear and gear:isOpen() then
			refreshGear()
		end
		if pause and pause:isOpen() then
			pauseInfo()
		end
	end)
end

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
	local route = MenuController.ROUTES[canon]
	if not route or not started then
		return false
	end
	local prev = current
	if prev and prev ~= canon then
		MenuController.close(prev)
	end
	current = canon
	if route.kind == "list" then
		local g = ensureGear()
		MenuController.closePause()
		refreshGear()
		g:open()
		suspendShoulderCamera("gear", true)
		current = canon
	elseif route.kind == "pause" then
		MenuController.openPause(route.tab, route.focus)
		current = canon
	elseif route.kind == "phone" then
		MenuController.closePause()
		local phone = lazy("PhoneController")
		if phone and typeof(phone.openApp) == "function" then
			pcall(phone.openApp, route.app)
		end
	end
	MenuController.Opened:Fire(canon)
	return true
end

function MenuController.close(name: string?): boolean
	local target = if name ~= nil then MenuController.resolveName(name) else current
	if target == nil or current ~= target then
		return false
	end
	local route = MenuController.ROUTES[target]
	current = nil
	if route and route.kind == "list" and gear then
		gear:close()
	elseif route and route.kind == "pause" then
		MenuController.closePause()
	elseif route and route.kind == "phone" then
		local phone = lazy("PhoneController")
		if phone and typeof(phone.close) == "function" then
			pcall(phone.close)
		end
	end
	MenuController.Closed:Fire(target)
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
	if current then
		MenuController.close(current)
	end
	MenuController.closePause()
	if gear then
		gear:close()
	end
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
	-- the saved speed readout setting (VehicleClient reads the local attribute)
	local overrides: { [string]: boolean } = {}
	for k, o in settingOverrides do
		overrides[k] = o.value
	end
	local speedo = MenuController.settingValue(settings, overrides, "speedo")
	if player:GetAttribute("HC_ShowSpeedo") ~= speedo then
		player:SetAttribute("HC_ShowSpeedo", speedo)
	end
	MenuController.refresh()
end

function MenuController.init() end

function MenuController.start()
	if started then
		return
	end
	started = true
	ListMenu.tick = function()
		playSound("Click")
	end
	player:SetAttribute("HC_ShowSpeedo", DEFAULT_SETTINGS.speedo)

	StateController.Changed:Connect(onSnapshot)
	local existing = StateController.get()
	if existing then
		onSnapshot(existing)
	end
	for _, attr in { "Cash", "IncomePerSec", "Rebirths", "Wanted" } do
		player:GetAttributeChangedSignal(attr):Connect(MenuController.refresh)
	end

	-- P: pause menu (last tab); M is the map (MapScreenController). Esc belongs to Roblox, and so does the gamepad's
	-- Start (it opens Roblox's menu and arrives here as gameProcessed): gamepads use Back / View (ButtonSelect). That
	-- button also toggles Roblox's gamepad GUI selection, so that is switched off: our menus drive themselves with the
	-- D-pad / A / B (ContextActionService).
	pcall(function()
		GuiService.AutoSelectGuiEnabled = false
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.P or k == Enum.KeyCode.ButtonSelect or k == Enum.KeyCode.ButtonStart then
			MenuController.togglePause(nil)
		end
	end)
	-- Esc / Android back open the Roblox menu: close ours so nothing is left behind it
	pcall(function()
		GuiService.MenuOpened:Connect(function()
			MenuController.closeAll()
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

	-- 1 Hz: countdowns (daily reset, gifts), the pause clock; the garage preview turntable spins per frame
	RunService.RenderStepped:Connect(function(dt: number)
		local model = preview.model
		local cam = preview.camera
		local view = preview.view
		if model and cam and view and view.Parent and model.Parent == view then
			preview.yaw = (preview.yaw + SPIN_SPEED * dt) % 360
			local cf, size = model:GetBoundingBox()
			cam.CFrame = MenuController.cameraCFrame(cf.Position, size, VIEW_FOV, preview.yaw, CARD_PITCH)
		end
	end)
	while true do
		task.wait(1)
		local tab = activeTab()
		if tab and (tab.id == "JOBS" or tab.id == "STATS") then
			MenuController.refresh()
		elseif pause and pause:isOpen() then
			pauseInfo()
		end
	end
end

return MenuController
