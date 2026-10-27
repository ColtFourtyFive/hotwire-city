--!strict
-- CarAliases: v1 car ids that left the catalog in v2 -> the realistic v2 car that replaces them (PLAN wave A4).
--
-- v2 keeps every v1 id whose car has a realistic counterpart (rustbucket, grandma_sedan, yellow_cab, ... now Halden,
-- Tamura, Marlowe, Rossetti... parody cars on uploaded models, same rarity / income / price), so saved garages,
-- Economy.STARTER_CAR, admin commands and the LOOP_V2 examples stay valid. The meme and fantasy cars (monster trucks,
-- hover car, tank, rocket car, hot dog, duck, couch, toilet, ice-cream truck) are gone from the catalog (lead direction:
-- meme vehicles are not core content); each maps to the realistic car closest to its value (rarity band first, then
-- price), so a record carrying one of these ids loads as that car instead of being retired. Config/Cars.get resolves
-- these transparently; the target ids are checked against the catalog by tests/spec/vehicles_v2.spec.luau.
--
-- Data migration: LOOP_V2 §9.3 starts v2 on a fresh DataStore, so this table is the safety net for any profile, test
-- fixture or hard-coded id that still says a v1 meme id; CarService / sanitize (C1) can call CarAliases.resolve.

local CarAliases = {}

CarAliases.Map = {
	-- Uncommon
	ice_cream = "brennan_cargo", -- ice-cream truck -> Brennan Cargo 30 box truck ($1.8K, same band)
	-- Rare
	bigfoot = "kronberg_k8", -- monster truck ($8K) -> Kronberg K8 ($8.5K)
	-- Epic
	crusher = "phantom_gt", -- monster truck ($45K) -> Rossetti Furia ($50K)
	-- Legendary
	rocket_car = "midnight_phantom", -- rocket car ($400K) -> Velacor Nyx ($320K)
	-- Mythic
	hover_car = "ashcombe_vireo_lm", -- hover car ($2.0M) -> Ashcombe Vireo LM ($2.2M)
	mini_tank = "ashcombe_vireo_lm", -- mini tank ($2.5M) -> Ashcombe Vireo LM ($2.2M)
	-- Secret (realistic prototypes, LOOP_V2 §2.10)
	hotdog_wagon = "kronberg_sovereign", -- $10M -> Kronberg Sovereign armored limousine ($12M)
	rubber_ducky = "kronberg_sovereign", -- $15M -> Kronberg Sovereign ($12M)
	couch_cruiser = "velacor_nyx_prototype", -- $20M -> Velacor Nyx Prototype ($25M)
	toilet_turbo = "velacor_nyx_prototype", -- $30M -> Velacor Nyx Prototype ($25M)
} :: { [string]: string }

-- The v2 id for `id` when it is an alias, else `id` unchanged (callers check the catalog themselves).
function CarAliases.resolve(id: string): string
	return CarAliases.Map[id] or id
end

function CarAliases.isAlias(id: string): boolean
	return CarAliases.Map[id] ~= nil
end

return CarAliases
