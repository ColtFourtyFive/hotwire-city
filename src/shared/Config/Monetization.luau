--!strict
-- Gamepass + Developer Product definitions. Live ids come from the generated MonetizationIds (LOOP_V2 §8 catalog,
-- created by `python3 tools/monetization/sync.py --apply`); see the bottom of this file. Any entry with id 0 is hidden
-- from the store and treated as not owned.

local MonetizationIds = require(script.Parent.MonetizationIds)

export type PassDef = { key: string, id: number, name: string, description: string, icon: string }
export type ProductDef = { key: string, id: number, name: string, description: string, icon: string }

local Monetization = {}

Monetization.Passes = {
	vip = {
		key = "vip",
		id = 0,
		name = "VIP",
		description = "2x cash forever, VIP tag, double offline earnings.",
		icon = "👑",
	},
	slots = {
		key = "slots",
		id = 0,
		name = "+2 Garage Slots",
		description = "Two extra garage slots on top of the max.",
		icon = "🅿️",
	},
	nitro = {
		key = "nitro",
		id = 0,
		name = "Infinite Nitro",
		description = "Your nitro never runs out.",
		icon = "🔥",
	},
	hotwire = {
		key = "hotwire",
		id = 0,
		name = "Master Thief",
		description = "Hotwire every car 40% faster.",
		icon = "🔧",
	},
	taser = {
		key = "taser",
		id = 0,
		name = "Stun Gun Pass", -- C4b: was "Zapper Pass" (display name only)
		description = "Own the Kessler Stun Gun right away, with half the cooldown.",
		icon = "⚡",
	},
} :: { [string]: PassDef }

Monetization.PassOrder = { "vip", "slots", "hotwire", "nitro", "taser" }
Monetization.MASTER_THIEF_MULT = 0.6

Monetization.Products = {
	cash_small = {
		key = "cash_small",
		id = 0,
		name = "Stack of Cash",
		description = "10 minutes of your income (min $5,000).",
		icon = "💵",
	},
	cash_big = {
		key = "cash_big",
		id = 0,
		name = "Briefcase of Cash",
		description = "1 hour of your income (min $50,000).",
		icon = "💼",
	},
	lock_10 = {
		key = "lock_10",
		id = 0,
		name = "Lockdown",
		description = "Lock your garage for 10 minutes.",
		icon = "🔒",
	},
	clear_wanted = {
		key = "clear_wanted",
		id = 0,
		name = "Lose the Cops",
		description = "Instantly clear your wanted level.",
		icon = "🚔",
	},
	server_luck = {
		key = "server_luck",
		id = 0,
		name = "Server Luck x2",
		description = "Doubles rare car spawns for everyone in the server for 15 minutes.",
		icon = "🍀",
	},
	diamond_dragster = {
		key = "diamond_dragster",
		id = 0,
		name = "Diamond Dragster",
		description = "Exclusive unstealable hypercar. $15,000/s.",
		icon = "💎",
	},
} :: { [string]: ProductDef }

Monetization.ProductOrder = { "cash_small", "cash_big", "server_luck", "lock_10", "clear_wanted", "diamond_dragster" }

Monetization.VIP_CASH_MULT = 2
Monetization.SERVER_LUCK_DURATION = 15 * 60
Monetization.LOCKDOWN_DURATION = 10 * 60

-- Ids: a v1 key takes the id of the LOOP_V2 item with the same key (vip, slots, cash_small, cash_big, server_luck,
-- diamond_dragster). Two products were renamed in LOOP_V2 §8.3 and read the V2 id under their v1 key. Retired v1 passes
-- (§8.4: nitro, hotwire, taser) have no V2 item, so they keep id 0 and stay hidden.
Monetization.V1_PRODUCT_ALIASES = { lock_10 = "lockdown", clear_wanted = "lose_cops" }

local function applyIds(defs: { [string]: PassDef }, ids: { [string]: number }, aliases: { [string]: string })
	for key, def in defs do
		local id = ids[aliases[key] or key]
		if typeof(id) == "number" and id > 0 then
			def.id = id
		end
	end
end

applyIds(Monetization.Passes, MonetizationIds.passes, {})
applyIds(Monetization.Products, MonetizationIds.products, Monetization.V1_PRODUCT_ALIASES)

return Monetization
