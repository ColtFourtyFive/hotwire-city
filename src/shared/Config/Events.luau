--!strict
-- Server-wide events that create "everyone rush over there" moments.

local Events = {
	HOT_DROP_INTERVAL = { 360, 540 }, -- seconds between hot drops (random in range)
	HOT_DROP_WARNING = 20, -- countdown before the car appears
	HOT_DROP_LIFETIME = 180, -- seconds until an unclaimed drop disappears
	HOT_DROP_HOLD = 5, -- seconds to hotwire the drop
	-- rarity weights for hot drop cars
	HOT_DROP_RARITY = { Legendary = 70, Mythic = 25, Secret = 5 },
	HOT_DROP_MUTATION_BOOST = 3, -- multiplier on non-None mutation weights

	CASH_RAIN_INTERVAL = { 600, 900 },
	CASH_RAIN_DURATION = 45,
	CASH_RAIN_BAGS = 60,
	CASH_RAIN_BAG_SECONDS = 20, -- each bag is worth this many seconds of the collector's income (min $250)

	RUSH_HOUR_INTERVAL = { 480, 720 },
	RUSH_HOUR_DURATION = 120,
	RUSH_HOUR_TRAFFIC_MULT = 1.8,
	RUSH_HOUR_LUCK = 2.5,

	DOUBLE_CASH_DURATION = 300, -- random "2x CASH" events
	DOUBLE_CASH_INTERVAL = { 1500, 2400 },
}

return Events
