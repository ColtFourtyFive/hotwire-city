--!strict
-- Runtime-loaded art. The server's AssetLibrary loads every entry at boot, sanitizes it (no scripts),
-- normalizes orientation + scale around a ground-level root, and publishes templates under
-- ReplicatedStorage.AssetLibrary.<Category>.<key>. Everything here is optional: if an asset fails to load,
-- the procedural geometry (CarBuilder / MapBuilder / PlotService) is used instead.
--
-- source = "owned": asset belongs to the experience owner (uploaded via tools/upload_hero.py) -> InsertService:LoadAsset
-- source = "store": public free Creator Store asset -> AssetService:LoadAssetAsync (needs Game Settings > Security >
--                   "Allow Loading Third Party Assets"); falls back to InsertService:LoadAsset.

export type Fit = "length" | "height" | "maxDim" | "footprint"

export type AssetDef = {
	ids: { number }, -- primary first, then alternates
	source: "owned" | "store",
	fit: Fit, -- which dimension `size` constrains
	size: number, -- studs
	yaw: number?, -- degrees about +Y applied before fitting so the asset's front faces -Z
	collide: boolean?, -- keep collisions (default false: purely visual)
	castShadow: boolean?,
}

local Assets = {}

-- Hero vehicle shells (Higgsfield concept -> Meshy 3D -> Roblox Model). Keyed by Config/Cars id (or "police_unit").
-- These REPLACE the procedural body visuals while the procedural chassis/wheels/seat keep doing the physics.
Assets.Hero = {
	bank_truck = { ids = { 89554244940119 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	bigfoot = { ids = { 80067016260602 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	bull_charger = { ids = { 129097020644709 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	couch_cruiser = { ids = { 132127509054900 }, source = "owned", fit = "length", size = 13, yaw = 180 },
	crusher = { ids = { 87623790663196 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	diamond_dragster = { ids = { 135210735126816 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	dirt_hauler = { ids = { 133671772322331 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	family_suv = { ids = { 121890247527896 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	gold_rush = { ids = { 125880089051178 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	grandma_sedan = { ids = { 125004684536558 }, source = "owned", fit = "length", size = 14, yaw = -90 },
	hot_hatch = { ids = { 107359297953950 }, source = "owned", fit = "length", size = 12, yaw = 180 },
	hotdog_wagon = { ids = { 82630626019307 }, source = "owned", fit = "length", size = 14, yaw = -90 },
	hover_car = { ids = { 102948112413795 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	hyperion_x = { ids = { 126778418660689 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	ice_cream = { ids = { 81492067822740 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	midnight_phantom = { ids = { 95059911094876 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	mini_bean = { ids = { 128070737278044 }, source = "owned", fit = "length", size = 12, yaw = 180 },
	mini_tank = { ids = { 104831005648097 }, source = "owned", fit = "length", size = 14, yaw = -90 },
	neon_drift = { ids = { 86286290360164 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	night_raven = { ids = { 122146500133041 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	phantom_gt = { ids = { 84376633244806 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	pizza_van = { ids = { 70762042693755 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	police_unit = { ids = { 95225149784237 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	raging_bull = { ids = { 110891985950292 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	retired_cruiser = { ids = { 129341424773968 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	rocket_car = { ids = { 103823546408643 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	rubber_ducky = { ids = { 117804012770338 }, source = "owned", fit = "length", size = 13, yaw = 180 },
	rustbucket = { ids = { 139759221539718 }, source = "owned", fit = "length", size = 12, yaw = 180 },
	stallion_gt = { ids = { 99936070220028 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	stretch_limo = { ids = { 128471550662515 }, source = "owned", fit = "length", size = 18, yaw = 180 },
	toilet_turbo = { ids = { 94938152703221 }, source = "owned", fit = "length", size = 13, yaw = -90 },
	viper_strike = { ids = { 104359226400550 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	yellow_cab = { ids = { 133563404247410 }, source = "owned", fit = "length", size = 14, yaw = 180 },
} :: { [string]: AssetDef }

-- City dressing, keyed by role (MapBuilder places procedural placeholders tagged "AssetSlot" with attribute Role).
Assets.Props = {
	beach_chair = { ids = { 79867193758251 }, source = "owned", fit = "maxDim", size = 6, yaw = 180 },
	beach_umbrella = { ids = { 110527191112633 }, source = "owned", fit = "height", size = 10, yaw = 0 },
	bench = { ids = { 136432573607618 }, source = "owned", fit = "maxDim", size = 8, yaw = 180 },
	billboard = { ids = { 114772042601208 }, source = "owned", fit = "height", size = 40, yaw = 0 },
	bus_stop = { ids = { 119117098016654 }, source = "owned", fit = "maxDim", size = 16, yaw = 180 },
	bush = { ids = { 135605525314160 }, source = "owned", fit = "maxDim", size = 5, yaw = 0 },
	car_crusher = { ids = { 137671148503320 }, source = "owned", fit = "maxDim", size = 18, yaw = 0 },
	car_lift = { ids = { 99878746716178 }, source = "owned", fit = "maxDim", size = 14, yaw = 0 },
	crate_stack = { ids = { 90116511780933 }, source = "owned", fit = "maxDim", size = 7, yaw = 90 },
	dumpster = { ids = { 94934016712072 }, source = "owned", fit = "maxDim", size = 9, yaw = 180 },
	ferris_wheel = { ids = { 125709542843565 }, source = "owned", fit = "height", size = 90, yaw = 0 },
	fire_hydrant = { ids = { 114961407772066 }, source = "owned", fit = "height", size = 3.5, yaw = 0 },
	fountain = { ids = { 75095778830314 }, source = "owned", fit = "footprint", size = 30, yaw = 0 },
	garage_shelf = { ids = { 136193075921721 }, source = "owned", fit = "maxDim", size = 9, yaw = 0 },
	gold_bars = { ids = { 76649900213811 }, source = "owned", fit = "maxDim", size = 3, yaw = 0 },
	hotdog_stand = { ids = { 93258067399426 }, source = "owned", fit = "height", size = 10, yaw = 180 },
	lifeguard_tower = { ids = { 122228610473538 }, source = "owned", fit = "height", size = 18, yaw = 180 },
	mailbox = { ids = { 125138540039790 }, source = "owned", fit = "height", size = 4, yaw = 180 },
	money_bag = { ids = { 88043872881262 }, source = "owned", fit = "maxDim", size = 3, yaw = 180 },
	money_pile = { ids = { 74698303672028 }, source = "owned", fit = "maxDim", size = 6, yaw = 0 },
	newspaper_box = { ids = { 71497296792767 }, source = "owned", fit = "height", size = 4, yaw = 180 },
	oil_barrels = { ids = { 81254448700067 }, source = "owned", fit = "maxDim", size = 5, yaw = 0 },
	palm_tree_a = { ids = { 110680256553424 }, source = "owned", fit = "height", size = 34, yaw = 0 },
	palm_tree_b = { ids = { 129715816814065 }, source = "owned", fit = "height", size = 30, yaw = 0 },
	pine_tree = { ids = { 110984583829450 }, source = "owned", fit = "height", size = 26, yaw = 0 },
	police_barricade = { ids = { 113988738671570 }, source = "owned", fit = "maxDim", size = 7, yaw = 180 },
	road_barrier = { ids = { 129396054892600 }, source = "owned", fit = "maxDim", size = 8, yaw = 90 },
	rock = { ids = { 124248644353930 }, source = "owned", fit = "maxDim", size = 6, yaw = 0 },
	round_tree = { ids = { 100614181052484 }, source = "owned", fit = "height", size = 24, yaw = 0 },
	safe_vault = { ids = { 113630258962677 }, source = "owned", fit = "maxDim", size = 6, yaw = 180 },
	shipping_container = { ids = { 74494248506045 }, source = "owned", fit = "length", size = 20, yaw = 90 },
	street_lamp = { ids = { 97961613878373 }, source = "owned", fit = "height", size = 18, yaw = 180 },
	surfboard_rack = { ids = { 72757355013338 }, source = "owned", fit = "maxDim", size = 9, yaw = 180 },
	tire_stack = { ids = { 139831985857820 }, source = "owned", fit = "maxDim", size = 5, yaw = 0 },
	tool_chest = { ids = { 105309913792626 }, source = "owned", fit = "maxDim", size = 5, yaw = 180 },
	traffic_cone = { ids = { 80331275564441 }, source = "owned", fit = "height", size = 2.5, yaw = 0 },
	traffic_light = { ids = { 99965539907552 }, source = "owned", fit = "height", size = 20, yaw = 180 },
	trash_can = { ids = { 120431887412857 }, source = "owned", fit = "height", size = 4.5, yaw = 90 },
	trophy = { ids = { 80714653751593 }, source = "owned", fit = "maxDim", size = 6, yaw = 0 },
	water_tower = { ids = { 115392992764228 }, source = "owned", fit = "height", size = 60, yaw = 0 },
	workbench = { ids = { 125966881297568 }, source = "owned", fit = "maxDim", size = 8, yaw = 180 },
	cash_stack = { ids = { 9507277429 }, source = "store", fit = "maxDim", size = 2.5, yaw = 0 },
	construction_barrier = { ids = { 10558582668 }, source = "store", fit = "length", size = 8, yaw = 0 },
	donut_giant = { ids = { 13742217239 }, source = "store", fit = "maxDim", size = 8, yaw = 0 },
	flower_bed = { ids = { 4542793421 }, source = "store", fit = "footprint", size = 10, yaw = 0 },
	garage_door_rollup = { ids = { 10163587378 }, source = "store", fit = "length", size = 30, yaw = 0 },
	neon_sign_open = { ids = { 491723807 }, source = "store", fit = "maxDim", size = 7, yaw = 0 },
	parking_meter = { ids = { 8932663219 }, source = "store", fit = "height", size = 5, yaw = 0 },
	phone_booth = { ids = { 8932794862 }, source = "store", fit = "height", size = 9, yaw = 0 },
	police_helicopter = { ids = { 17797349765 }, source = "store", fit = "length", size = 34, yaw = 0 },
	scrap_car = { ids = { 8027653806 }, source = "store", fit = "length", size = 14, yaw = 0 },
	spray_can = { ids = { 5403252616 }, source = "store", fit = "height", size = 4, yaw = 0 },
	street_lamp_classic = { ids = { 14212653287 }, source = "store", fit = "height", size = 14, yaw = 0 },
} :: { [string]: AssetDef }

-- Buildings by class; MapBuilder marks building lots with "AssetSlot" Role = "building_<class>".
Assets.Buildings = {
	apartment_balcony = { ids = { 135882957318853 }, source = "owned", fit = "height", size = 70, yaw = 0 },
	beach_villa = { ids = { 128939028758957 }, source = "owned", fit = "height", size = 30, yaw = 0 },
	brick_loft = { ids = { 81064844944613 }, source = "owned", fit = "height", size = 60, yaw = 0 },
	car_showroom = { ids = { 83974576505747 }, source = "owned", fit = "footprint", size = 100, yaw = 180 },
	chop_shop = { ids = { 134559325763106 }, source = "owned", fit = "footprint", size = 60, yaw = 0 },
	convenience_store = { ids = { 100494932403416 }, source = "owned", fit = "height", size = 22, yaw = 180 },
	diner = { ids = { 128048405858739 }, source = "owned", fit = "height", size = 22, yaw = 0 },
	donut_shop = { ids = { 110799039766838 }, source = "owned", fit = "height", size = 28, yaw = 180 },
	gas_station = { ids = { 84236317094177 }, source = "owned", fit = "footprint", size = 60, yaw = 0 },
	gear_shop = { ids = { 109821139919069 }, source = "owned", fit = "height", size = 28, yaw = 180 },
	hotel_beach = { ids = { 123312818892511 }, source = "owned", fit = "height", size = 60, yaw = 180 },
	lighthouse = { ids = { 95904687488361 }, source = "owned", fit = "height", size = 70, yaw = 180 },
	office_block = { ids = { 137281558360232 }, source = "owned", fit = "height", size = 80, yaw = 180 },
	pizza_shop = { ids = { 94207549419234 }, source = "owned", fit = "height", size = 24, yaw = 180 },
	police_hq = { ids = { 97738719879167 }, source = "owned", fit = "height", size = 45, yaw = 180 },
	skyscraper_deco = { ids = { 85109070426469 }, source = "owned", fit = "height", size = 220, yaw = 0 },
	skyscraper_neon = { ids = { 133283744578331 }, source = "owned", fit = "height", size = 200, yaw = 0 },
	skyscraper_twist = { ids = { 109885448834475 }, source = "owned", fit = "height", size = 240, yaw = 0 },
	spray_booth = { ids = { 122378982559801 }, source = "owned", fit = "height", size = 22, yaw = 180 },
	suburban_house = { ids = { 79095679639420 }, source = "owned", fit = "height", size = 26, yaw = 180 },
	surf_shack = { ids = { 120191646577657 }, source = "owned", fit = "height", size = 18, yaw = 90 },
	warehouse = { ids = { 125047818646373 }, source = "owned", fit = "height", size = 35, yaw = 0 },
} :: { [string]: AssetDef }

-- NPC looks (HumanoidDescription fields). Catalog asset ids.
export type Outfit = { shirt: number?, pants: number?, accessories: { number }?, bodyColor: Color3? }
Assets.Outfits = {
	police = {} :: { Outfit },
	civilians = {} :: { Outfit },
}

-- Max concurrent loads at boot.
Assets.LOAD_CONCURRENCY = 4
-- Give up on a single asset after this many seconds.
Assets.LOAD_TIMEOUT = 20

return Assets
