--!strict
-- Weighted random rolls for cars and mutations. Pure: pass your own Random for testability.

local Cars = require(script.Parent.Parent.Config.Cars)
local Rarity = require(script.Parent.Parent.Config.Rarity)

local Rolls = {}

-- Generic weighted pick from { [key]: weight }. Returns nil if all weights are 0.
function Rolls.weighted<K>(weights: { [K]: number }, rng: Random): K?
	local total = 0
	for _, w in weights do
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil
	end
	local r = rng:NextNumber() * total
	local last: K? = nil
	for k, w in weights do
		if w > 0 then
			last = k
			r -= w
			if r <= 0 then
				return k
			end
		end
	end
	return last
end

export type Source = "street" | "dealer"

-- Rolls a rarity for a source. `luck` >= 1 boosts every tier above Common/Uncommon by that factor.
function Rolls.rarity(source: Source, luck: number, rng: Random): Rarity.RarityId
	local weights: { [Rarity.RarityId]: number } = {}
	for id, def in Rarity.Tiers do
		local w = if source == "street" then def.streetWeight else def.dealerWeight
		if def.order >= 3 then
			w *= math.max(1, luck)
		end
		weights[id] = w
	end
	return Rolls.weighted(weights, rng) or "Common"
end

-- Picks a random car of a rarity valid for the source. Falls back to lower rarities if none exist.
function Rolls.carOfRarity(rarity: Rarity.RarityId, source: Source | "any", rng: Random): Cars.CarDef
	local order = Rarity.Tiers[rarity].order
	for o = order, 1, -1 do
		local rid = Rarity.Order[o]
		local pool = {}
		for _, def in Cars.ByRarity[rid] or {} do
			local ok = (source == "any" and def.rarity ~= "Exclusive")
				or (source == "street" and def.street)
				or (source == "dealer" and def.dealer)
			if ok then
				table.insert(pool, def)
			end
		end
		if #pool > 0 then
			return pool[rng:NextInteger(1, #pool)]
		end
	end
	return Cars.List[1]
end

-- Full roll: rarity then car.
function Rolls.car(source: Source, luck: number, rng: Random): Cars.CarDef
	return Rolls.carOfRarity(Rolls.rarity(source, luck, rng), source, rng)
end

-- Mutation roll. `boost` multiplies the weight of every non-None mutation.
function Rolls.mutation(boost: number, rng: Random): Rarity.MutationId
	local weights: { [Rarity.MutationId]: number } = {}
	for id, def in Rarity.Mutations do
		weights[id] = if id == "None" then def.weight else def.weight * math.max(1, boost)
	end
	return Rolls.weighted(weights, rng) or "None"
end

return Rolls
