--!strict
-- Economy tunables: prices, rewards, multipliers, timers. Balance the game from this file.

local Economy = {}

Economy.STARTING_CASH = 150
Economy.STARTER_CAR = "rustbucket" -- new players spawn in their garage with this car already earning
Economy.SELL_FRACTION = 0.5 -- sell value = price * SELL_FRACTION * mutation multiplier
Economy.CHOP_SHOP_FRACTION = 0.35 -- instant cash for chopping a non-owned car at the Chop Shop (of price * mutation)
Economy.INCOME_TICK = 1 -- seconds between garage income ticks

-- Garage slots -----------------------------------------------------------------
Economy.START_SLOTS = 4
Economy.MAX_SLOTS = 10 -- purchasable with cash
Economy.PASS_EXTRA_SLOTS = 2 -- "+2 Garage Slots" gamepass (physical garage has MAX_SLOTS + PASS_EXTRA_SLOTS pads)
-- Cost to unlock slot N (index = slot number). Slots 1..START_SLOTS are free.
Economy.SLOT_PRICES = {
	[5] = 1500,
	[6] = 8000,
	[7] = 40000,
	[8] = 200000,
	[9] = 1000000,
	[10] = 5000000,
} :: { [number]: number }

-- Upgrades (bought at the Gear Shop) --------------------------------------------
export type UpgradeDef = {
	id: string,
	name: string,
	description: string,
	maxLevel: number,
	prices: { number }, -- prices[level+1] = cost to go from level -> level+1
	values: { number }, -- values[level+1] = effect at that level (level 0 = values[1])
}

Economy.Upgrades = {
	lock = {
		id = "lock",
		name = "Laser Lock",
		description = "How long your garage laser gate stays locked.",
		maxLevel = 3,
		prices = { 2500, 30000, 350000 },
		values = { 45, 60, 90, 120 }, -- seconds
	},
	hotwire = {
		id = "hotwire",
		name = "Hotwire Kit",
		description = "Steal cars faster.",
		maxLevel = 4,
		prices = { 1200, 12000, 120000, 1200000 },
		values = { 1, 0.85, 0.72, 0.6, 0.5 }, -- hold-time multiplier
	},
	nitro = {
		id = "nitro",
		name = "Nitro Tank",
		description = "Bigger nitro tank, faster refill.",
		maxLevel = 4,
		prices = { 800, 9000, 90000, 900000 },
		values = { 2.5, 3.5, 4.5, 6, 8 }, -- seconds of boost per full tank
	},
	armor = {
		id = "armor",
		name = "Car Armor",
		description = "Cars you drive take less damage.",
		maxLevel = 3,
		prices = { 5000, 60000, 700000 },
		values = { 1, 0.8, 0.6, 0.4 }, -- damage multiplier
	},
} :: { [string]: UpgradeDef }

-- Tools (bought at the Gear Shop, permanent) -----------------------------------
export type ToolDef = {
	id: string,
	name: string,
	description: string,
	price: number,
	cooldown: number,
}

Economy.Tools = {
	bat = {
		id = "bat",
		name = "Bonk Bat",
		description = "Bonk thieves out of your cars. Free!",
		price = 0,
		cooldown = 0.8,
	},
	taser = {
		id = "taser",
		name = "Zapper",
		description = "Zap a thief from range. Stuns them and pops them out of their car.",
		price = 15000,
		cooldown = 6,
	},
	spikes = {
		id = "spikes",
		name = "Spike Strip",
		description = "Drop spikes behind you. Pops the tires of anyone chasing you.",
		price = 6000,
		cooldown = 12,
	},
} :: { [string]: ToolDef }

Economy.ToolOrder = { "bat", "taser", "spikes" }

-- Combat tuning
Economy.BAT_RANGE = 9
Economy.BAT_KNOCKBACK = 70
Economy.BAT_STUN = 1.6
Economy.TASER_RANGE = 60
Economy.TASER_STUN = 2.5
Economy.SPIKES_DURATION = 15 -- seconds the strip stays on the road
Economy.SPIKES_SLOW = 0.4 -- top speed multiplier while tires are popped
Economy.SPIKES_POP_TIME = 6

-- Rebirth ---------------------------------------------------------------------
Economy.REBIRTH_BASE_COST = 750000
Economy.REBIRTH_COST_GROWTH = 2.75
Economy.REBIRTH_INCOME_BONUS = 0.5 -- +50% income per rebirth (additive)
Economy.REBIRTH_KEEP_CARS = 2 -- rebirth keeps your best N cars (by income)
-- NOTE: rebirths do not change spawn luck (world spawns are shared); don't advertise luck.

-- Wanted / busted --------------------------------------------------------------
Economy.BUSTED_CASH_PENALTY = 0.1 -- lose 10% of cash on hand
Economy.BUSTED_MAX_PENALTY_SECONDS = 600 -- penalty capped at 10 minutes of income
Economy.SPRAY_COST_PER_STAR = 250 -- minimum cost to clear wanted at a Spray Shop, per star
Economy.CAB_FEE = 150 -- phone "Call a cab" fast trip to your own garage (PlotService GoHome; blocked while wanted)
Economy.SPRAY_INCOME_SECONDS = 15 -- per star: cost = stars * max(SPRAY_COST_PER_STAR, income/s * this)

-- Theft ------------------------------------------------------------------------
Economy.THEFT_HOLD_MULTIPLIER = 1.4 -- player-garage steal hold = rarity hotwireTime * this
Economy.DEALER_STEAL_HOLD_MULTIPLIER = 1.6
Economy.THEFT_TIME_LIMIT = 150 -- seconds to deliver a car stolen from a player
Economy.THEFT_ABANDON_LIMIT = 12 -- seconds a stolen car may sit with no driver before it returns
Economy.NEWBIE_PROTECTION_CARS = 3 -- players with fewer cars than this can't be robbed
Economy.THEFT_VICTIM_COOLDOWN = 25 -- seconds after a theft before the same victim can be robbed again
Economy.DROPPED_CAR_TIMEOUT = 20 -- a stolen car whose thief got knocked out sits "dropped" this long before returning home
Economy.RECOVERY_BONUS_SECONDS = 30 -- victim who recovers their dropped car gets this many seconds of income as a bonus
Economy.BONUS_PAIR_COOLDOWN = 600 -- recovery/revenge bonuses pay at most once per (victim, thief) pair per this many seconds
Economy.RECOVERY_MIN_SECONDS = 15 -- recovery bonus only if the theft lasted this long or the car left the victim's garage
Economy.REVENGE_BONUS_SECONDS = 20 -- bonking/zapping the thief who robbed you pays this many seconds of income

-- Daily / playtime / offline ------------------------------------------------------
-- Daily streak. "incomeMinutes" = that many minutes of the player's current income (never less than `min`),
-- so rewards stay meaningful at every stage of progression.
Economy.DAILY_REWARDS = {
	{ kind = "incomeMinutes", amount = 5, min = 750 },
	{ kind = "incomeMinutes", amount = 8, min = 1500 },
	{ kind = "incomeMinutes", amount = 12, min = 4000 },
	{ kind = "car", rarity = "Rare" },
	{ kind = "incomeMinutes", amount = 20, min = 15000 },
	{ kind = "incomeMinutes", amount = 30, min = 30000 },
	{ kind = "car", rarity = "Epic" },
} :: { { kind: string, amount: number?, min: number?, rarity: string? } }

-- minutes of play in the session -> reward
-- Playtime gifts: minutes played per UTC DAY (persisted; rejoining does not reset them).
Economy.PLAYTIME_REWARDS = {
	{ minutes = 3, kind = "incomeMinutes", amount = 2, min = 300 },
	{ minutes = 8, kind = "incomeMinutes", amount = 5 },
	{ minutes = 15, kind = "car", rarity = "Rare" },
	{ minutes = 25, kind = "incomeMinutes", amount = 15 },
	{ minutes = 40, kind = "car", rarity = "Epic" },
	{ minutes = 60, kind = "car", rarity = "Legendary" },
} :: { { minutes: number, kind: string, amount: number?, rarity: string? } }

Economy.OFFLINE_RATE = 0.3 -- fraction of income earned while offline
Economy.OFFLINE_CAP_HOURS = 6
Economy.VIP_OFFLINE_RATE = 0.6

-- Referral (Roblox friend referral: GetJoinData().ReferredByPlayerId)
Economy.REFERRAL_REWARD_RARITY = "Epic" -- both inviter (if in server) and invitee get a random car of this rarity

-- Contracts (daily missions). 3 are rolled per day per player from this pool.
export type ContractDef = { id: string, text: string, stat: string, goal: number, reward: number } -- reward = seconds of income (min $500)
Economy.CONTRACTS_PER_DAY = 3
Economy.Contracts = {
	{ id = "steal5", text = "Steal 5 cars", stat = "steal", goal = 5, reward = 300 },
	{ id = "steal12", text = "Steal 12 cars", stat = "steal", goal = 12, reward = 900 },
	{ id = "rare1", text = "Deliver a Rare or better", stat = "deliverRare", goal = 1, reward = 600 },
	{ id = "epic1", text = "Deliver an Epic or better", stat = "deliverEpic", goal = 1, reward = 1500 },
	{ id = "rob1", text = "Steal a car from another player", stat = "playerSteal", goal = 1, reward = 900 },
	{ id = "escape3", text = "Escape a 3-star chase", stat = "escape3", goal = 1, reward = 900 },
	{ id = "escape1", text = "Lose the cops 3 times", stat = "escape", goal = 3, reward = 600 },
	{ id = "bonk3", text = "Bonk 3 thieves out of cars", stat = "defend", goal = 3, reward = 900 },
	{ id = "collect", text = "Collect $10,000 from your garage", stat = "collectCash", goal = 10000, reward = 300 },
	{ id = "drift", text = "Drift for 30 seconds total", stat = "driftSeconds", goal = 30, reward = 300 },
	{ id = "nitro", text = "Hit 150 mph-ish (top speed with nitro)", stat = "topSpeedHit", goal = 1, reward = 300 },
	{ id = "chop2", text = "Chop 2 cars at the Chop Shop", stat = "chop", goal = 2, reward = 450 },
	{ id = "dealer1", text = "Buy a car at the Dealership", stat = "dealerBuy", goal = 1, reward = 300 },
	{ id = "hotdrop", text = "Claim a Hot Drop", stat = "hotDrop", goal = 1, reward = 1800 },
} :: { ContractDef }

-- Social bonuses -----------------------------------------------------------------
Economy.GROUP_ID = 0 -- set to your Roblox group id; 0 disables the group bonus
Economy.GROUP_BONUS = 0.1
Economy.FRIEND_BONUS_EACH = 0.1
Economy.FRIEND_BONUS_MAX = 3 -- max friends counted

-- Index (collection) bonus: +X income when you have discovered every car of a rarity
Economy.INDEX_RARITY_BONUS = 0.05

-- Codes live server-side only: src/server/Config/Codes.luau (never replicate redeemable codes).

return Economy
