--!strict
-- Pure economy formulas. The SERVER result is authoritative; the client uses these for display only.

local Cars = require(script.Parent.Parent.Config.Cars)
local Economy = require(script.Parent.Parent.Config.Economy)
local Rarity = require(script.Parent.Parent.Config.Rarity)

local EconomyMath = {}

-- Base $/s of one car (catalog income * mutation multiplier).
function EconomyMath.carIncome(carId: string, mutation: Rarity.MutationId): number
	local def = Cars.get(carId)
	if not def then
		return 0
	end
	return def.income * Rarity.getMutation(mutation).multiplier
end

-- Cash received for selling a car from your garage.
function EconomyMath.sellValue(carId: string, mutation: Rarity.MutationId): number
	local def = Cars.get(carId)
	if not def then
		return 0
	end
	local base = if def.price > 0 then def.price else def.income * 120
	return math.floor(base * Economy.SELL_FRACTION * Rarity.getMutation(mutation).multiplier)
end

-- Cash received for chopping a car at the Chop Shop.
function EconomyMath.chopValue(carId: string, mutation: Rarity.MutationId): number
	local def = Cars.get(carId)
	if not def then
		return 0
	end
	local base = if def.price > 0 then def.price else def.income * 120
	return math.floor(base * Economy.CHOP_SHOP_FRACTION * Rarity.getMutation(mutation).multiplier)
end

-- Price to unlock slot number `slot` (nil when free or not purchasable).
function EconomyMath.slotPrice(slot: number): number?
	return Economy.SLOT_PRICES[slot]
end

function EconomyMath.rebirthCost(rebirths: number): number
	return math.floor(Economy.REBIRTH_BASE_COST * Economy.REBIRTH_COST_GROWTH ^ rebirths)
end

export type MultiplierInputs = {
	rebirths: number,
	vip: boolean,
	eventMultiplier: number, -- e.g. 2 during a 2x Cash event
	friendsInServer: number,
	inGroup: boolean,
	indexBonus: number, -- additive, from completed index rarities
}

-- Total multiplier applied to all garage income for a player.
function EconomyMath.playerMultiplier(m: MultiplierInputs): number
	local additive = 1
		+ m.rebirths * Economy.REBIRTH_INCOME_BONUS
		+ math.min(m.friendsInServer, Economy.FRIEND_BONUS_MAX) * Economy.FRIEND_BONUS_EACH
		+ (if m.inGroup then Economy.GROUP_BONUS else 0)
		+ m.indexBonus
	local vip = if m.vip then 2 else 1
	return additive * vip * math.max(1, m.eventMultiplier)
end

-- Index bonus from discovered cars: +INDEX_RARITY_BONUS for each rarity whose every car is discovered.
function EconomyMath.indexBonus(discovered: { [string]: boolean }): number
	local bonus = 0
	for _, rid in Rarity.Order do
		local pool = Cars.ByRarity[rid]
		if pool and #pool > 0 and rid ~= "Exclusive" then
			local all = true
			for _, def in pool do
				if not discovered[def.id] then
					all = false
					break
				end
			end
			if all then
				bonus += Economy.INDEX_RARITY_BONUS
			end
		end
	end
	return bonus
end

-- Level value helper for upgrades: value at a level (clamped).
function EconomyMath.upgradeValue(upgradeId: string, level: number): number
	local def = Economy.Upgrades[upgradeId]
	assert(def, "unknown upgrade " .. upgradeId)
	local idx = math.clamp(level, 0, def.maxLevel) + 1
	return def.values[idx]
end

function EconomyMath.upgradePrice(upgradeId: string, level: number): number?
	local def = Economy.Upgrades[upgradeId]
	if not def or level >= def.maxLevel then
		return nil
	end
	return def.prices[level + 1]
end

-- Today's day number (UTC) for daily rewards.
function EconomyMath.dayNumber(unixTime: number): number
	return unixTime // 86400
end

return EconomyMath
