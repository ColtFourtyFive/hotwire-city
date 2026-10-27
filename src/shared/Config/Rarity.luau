--!strict
-- Rarity tiers and mutation variants. Single source of truth for odds, colors and multipliers.

export type RarityId = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Secret" | "Exclusive"
export type MutationId = "None" | "Gold" | "Diamond" | "Rainbow" | "Galaxy"

export type RarityDef = {
	id: RarityId,
	order: number, -- 1 = lowest
	color: Color3,
	streetWeight: number, -- relative weight for street/traffic spawns
	dealerWeight: number, -- relative weight for dealership stock
	hotwireTime: number, -- seconds to hotwire a street car of this rarity
	wantedOnSteal: number, -- wanted stars added when stealing from the street
	wantedChance: number, -- probability that a street steal of this tier attracts wantedOnSteal (min 1) stars ("witness")
	announce: boolean, -- server-wide announcement when it appears
}

export type MutationDef = {
	id: MutationId,
	order: number,
	multiplier: number, -- income + sell value multiplier
	weight: number, -- relative roll weight
	color: Color3?, -- body color override (nil = keep base color)
	material: Enum.Material?, -- body material override
	label: string,
}

local Rarity = {}

Rarity.Order = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Exclusive" } :: { RarityId }

Rarity.Tiers = {
	Common = {
		id = "Common",
		order = 1,
		color = Color3.fromRGB(200, 200, 200),
		streetWeight = 60,
		dealerWeight = 45,
		hotwireTime = 0.8,
		wantedOnSteal = 0,
		wantedChance = 0.35,
		announce = false,
	},
	Uncommon = {
		id = "Uncommon",
		order = 2,
		color = Color3.fromRGB(85, 220, 95),
		streetWeight = 26,
		dealerWeight = 30,
		hotwireTime = 1.2,
		wantedOnSteal = 1,
		wantedChance = 1,
		announce = false,
	},
	Rare = {
		id = "Rare",
		order = 3,
		color = Color3.fromRGB(60, 150, 255),
		streetWeight = 10,
		dealerWeight = 15,
		hotwireTime = 1.8,
		wantedOnSteal = 1,
		wantedChance = 1,
		announce = false,
	},
	Epic = {
		id = "Epic",
		order = 4,
		color = Color3.fromRGB(175, 80, 255),
		streetWeight = 3.2,
		dealerWeight = 7,
		hotwireTime = 2.5,
		wantedOnSteal = 1,
		wantedChance = 1,
		announce = false,
	},
	Legendary = {
		id = "Legendary",
		order = 5,
		color = Color3.fromRGB(255, 190, 40),
		streetWeight = 0.7,
		dealerWeight = 2.5,
		hotwireTime = 3.5,
		wantedOnSteal = 2,
		wantedChance = 1,
		announce = true,
	},
	Mythic = {
		id = "Mythic",
		order = 6,
		color = Color3.fromRGB(255, 60, 90),
		streetWeight = 0.08,
		dealerWeight = 0.45,
		hotwireTime = 4.5,
		wantedOnSteal = 3,
		wantedChance = 1,
		announce = true,
	},
	Secret = {
		id = "Secret",
		order = 7,
		color = Color3.fromRGB(20, 20, 20),
		streetWeight = 0,
		dealerWeight = 0.05,
		hotwireTime = 6,
		wantedOnSteal = 3,
		wantedChance = 1,
		announce = true,
	},
	Exclusive = {
		id = "Exclusive",
		order = 8,
		color = Color3.fromRGB(0, 255, 230),
		streetWeight = 0,
		dealerWeight = 0,
		hotwireTime = 6,
		wantedOnSteal = 3,
		wantedChance = 1,
		announce = true,
	},
} :: { [RarityId]: RarityDef }

Rarity.MutationOrder = { "None", "Gold", "Diamond", "Rainbow", "Galaxy" } :: { MutationId }

Rarity.Mutations = {
	None = { id = "None", order = 1, multiplier = 1, weight = 86, label = "" },
	Gold = {
		id = "Gold",
		order = 2,
		multiplier = 2,
		weight = 8,
		color = Color3.fromRGB(255, 200, 40),
		material = Enum.Material.Foil,
		label = "GOLD",
	},
	Diamond = {
		id = "Diamond",
		order = 3,
		multiplier = 3,
		weight = 3.8,
		color = Color3.fromRGB(150, 235, 255),
		material = Enum.Material.Glass,
		label = "DIAMOND",
	},
	Rainbow = {
		id = "Rainbow",
		order = 4,
		multiplier = 5,
		weight = 1.6,
		material = Enum.Material.SmoothPlastic, -- color cycled client-side
		label = "RAINBOW",
	},
	Galaxy = {
		id = "Galaxy",
		order = 5,
		multiplier = 8,
		weight = 0.6,
		color = Color3.fromRGB(120, 40, 255),
		material = Enum.Material.ForceField,
		label = "GALAXY",
	},
} :: { [MutationId]: MutationDef }

function Rarity.get(id: RarityId): RarityDef
	return Rarity.Tiers[id]
end

function Rarity.getMutation(id: MutationId): MutationDef
	return Rarity.Mutations[id] or Rarity.Mutations.None
end

return Rarity
