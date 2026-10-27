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
	bank_truck = { ids = { 116305714652232 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	bigfoot = { ids = { 125566000871977 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	bull_charger = { ids = { 98311923444788 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	couch_cruiser = { ids = { 114270204621865 }, source = "owned", fit = "length", size = 13, yaw = 180 },
	crusher = { ids = { 99568173403009 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	diamond_dragster = { ids = { 82729586890252 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	dirt_hauler = { ids = { 133671772322331 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	family_suv = { ids = { 80790964637946 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	gold_rush = { ids = { 134176655076422 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	grandma_sedan = { ids = { 108644551887146 }, source = "owned", fit = "length", size = 14, yaw = -90 },
	hot_hatch = { ids = { 121463774871527 }, source = "owned", fit = "length", size = 12, yaw = 180 },
	hotdog_wagon = { ids = { 127487523986734 }, source = "owned", fit = "length", size = 14, yaw = -90 },
	hover_car = { ids = { 110828081176528 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	hyperion_x = { ids = { 123266095634098 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	ice_cream = { ids = { 112852039520018 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	midnight_phantom = { ids = { 77227004108463 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	mini_bean = { ids = { 70719457207259 }, source = "owned", fit = "length", size = 12, yaw = 180 },
	mini_tank = { ids = { 120597533311748 }, source = "owned", fit = "length", size = 14, yaw = -90 },
	neon_drift = { ids = { 93727811373472 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	night_raven = { ids = { 81269142465843 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	phantom_gt = { ids = { 110943136230076 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	pizza_van = { ids = { 116177134269637 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	police_unit = { ids = { 127449515013006 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	raging_bull = { ids = { 94586537612005 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	retired_cruiser = { ids = { 76301800419535 }, source = "owned", fit = "length", size = 14, yaw = 180 },
	rocket_car = { ids = { 82364754748656 }, source = "owned", fit = "length", size = 15, yaw = -90 },
	rubber_ducky = { ids = { 98264051340541 }, source = "owned", fit = "length", size = 13, yaw = 180 },
	rustbucket = { ids = { 122685403225018 }, source = "owned", fit = "length", size = 12, yaw = 180 },
	stallion_gt = { ids = { 126855763937566 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	stretch_limo = { ids = { 79785269654240 }, source = "owned", fit = "length", size = 18, yaw = 180 },
	toilet_turbo = { ids = { 104566147194318 }, source = "owned", fit = "length", size = 13, yaw = -90 },
	viper_strike = { ids = { 118865804144080 }, source = "owned", fit = "length", size = 15, yaw = 180 },
	yellow_cab = { ids = { 122259834697762 }, source = "owned", fit = "length", size = 14, yaw = 180 },
} :: { [string]: AssetDef }

-- City dressing, keyed by role (MapBuilder places procedural placeholders tagged "AssetSlot" with attribute Role).
Assets.Props = {
	beach_chair = { ids = { 87897753885346 }, source = "owned", fit = "maxDim", size = 6, yaw = 180 },
	beach_umbrella = { ids = { 112139196789358 }, source = "owned", fit = "height", size = 10, yaw = 0 },
	bench = { ids = { 111310726126399 }, source = "owned", fit = "maxDim", size = 8, yaw = 180 },
	billboard = { ids = { 76059882165452 }, source = "owned", fit = "height", size = 40, yaw = 0 },
	bus_stop = { ids = { 108756593497198 }, source = "owned", fit = "maxDim", size = 16, yaw = 180 },
	bush = { ids = { 119735153363243 }, source = "owned", fit = "maxDim", size = 5, yaw = 0 },
	car_crusher = { ids = { 71188168948039 }, source = "owned", fit = "maxDim", size = 18, yaw = 0 },
	car_lift = { ids = { 128031363827163 }, source = "owned", fit = "maxDim", size = 14, yaw = 0 },
	crate_stack = { ids = { 114225863313067 }, source = "owned", fit = "maxDim", size = 7, yaw = 90 },
	dumpster = { ids = { 74042690518547 }, source = "owned", fit = "maxDim", size = 9, yaw = 180 },
	ferris_wheel = { ids = { 105836939780994 }, source = "owned", fit = "height", size = 90, yaw = 0 },
	fire_hydrant = { ids = { 109992151897788 }, source = "owned", fit = "height", size = 3.5, yaw = 0 },
	fountain = { ids = { 113440545087031 }, source = "owned", fit = "footprint", size = 30, yaw = 0 },
	garage_shelf = { ids = { 131360118393285 }, source = "owned", fit = "maxDim", size = 9, yaw = 0 },
	gold_bars = { ids = { 81860260998949 }, source = "owned", fit = "maxDim", size = 3, yaw = 0 },
	hotdog_stand = { ids = { 137281614119929 }, source = "owned", fit = "height", size = 10, yaw = 180 },
	lifeguard_tower = { ids = { 139088484130419 }, source = "owned", fit = "height", size = 18, yaw = 180 },
	mailbox = { ids = { 109543812899533 }, source = "owned", fit = "height", size = 4, yaw = 180 },
	money_bag = { ids = { 81919593127161 }, source = "owned", fit = "maxDim", size = 3, yaw = 180 },
	money_pile = { ids = { 97172474500018 }, source = "owned", fit = "maxDim", size = 6, yaw = 0 },
	newspaper_box = { ids = { 88321252600263 }, source = "owned", fit = "height", size = 4, yaw = 180 },
	oil_barrels = { ids = { 114597334687915 }, source = "owned", fit = "maxDim", size = 5, yaw = 0 },
	palm_tree_a = { ids = { 140473791124715 }, source = "owned", fit = "height", size = 34, yaw = 0 },
	palm_tree_b = { ids = { 125899429876316 }, source = "owned", fit = "height", size = 30, yaw = 0 },
	pine_tree = { ids = { 129354874676649 }, source = "owned", fit = "height", size = 26, yaw = 0 },
	police_barricade = { ids = { 140418308957466 }, source = "owned", fit = "maxDim", size = 7, yaw = 180 },
	road_barrier = { ids = { 135701545038450 }, source = "owned", fit = "maxDim", size = 8, yaw = 90 },
	rock = { ids = { 115244802276740 }, source = "owned", fit = "maxDim", size = 6, yaw = 0 },
	round_tree = { ids = { 106180339370146 }, source = "owned", fit = "height", size = 24, yaw = 0 },
	safe_vault = { ids = { 103043388370318 }, source = "owned", fit = "maxDim", size = 6, yaw = 180 },
	shipping_container = { ids = { 107122804301246 }, source = "owned", fit = "length", size = 20, yaw = 90 },
	street_lamp = { ids = { 82713886132788 }, source = "owned", fit = "height", size = 18, yaw = 180 },
	surfboard_rack = { ids = { 134656763679614 }, source = "owned", fit = "maxDim", size = 9, yaw = 180 },
	tire_stack = { ids = { 121096661264094 }, source = "owned", fit = "maxDim", size = 5, yaw = 0 },
	tool_chest = { ids = { 129867667198603 }, source = "owned", fit = "maxDim", size = 5, yaw = 180 },
	traffic_cone = { ids = { 75016313209986 }, source = "owned", fit = "height", size = 2.5, yaw = 0 },
	traffic_light = { ids = { 133072003948768 }, source = "owned", fit = "height", size = 20, yaw = 180 },
	trash_can = { ids = { 82188625799670 }, source = "owned", fit = "height", size = 4.5, yaw = 90 },
	trophy = { ids = { 123190223907695 }, source = "owned", fit = "maxDim", size = 6, yaw = 0 },
	water_tower = { ids = { 122579259480318 }, source = "owned", fit = "height", size = 60, yaw = 0 },
	workbench = { ids = { 133542583948108 }, source = "owned", fit = "maxDim", size = 8, yaw = 180 },
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
	apartment_balcony = { ids = { 135640370407303 }, source = "owned", fit = "height", size = 70, yaw = 0 },
	beach_villa = { ids = { 105622461115029 }, source = "owned", fit = "height", size = 30, yaw = 0 },
	brick_loft = { ids = { 99360508467413 }, source = "owned", fit = "height", size = 60, yaw = 0 },
	car_showroom = { ids = { 90854308003439 }, source = "owned", fit = "footprint", size = 100, yaw = 180 },
	chop_shop = { ids = { 81692127863598 }, source = "owned", fit = "footprint", size = 60, yaw = 0 },
	convenience_store = { ids = { 125652161141598 }, source = "owned", fit = "height", size = 22, yaw = 180 },
	diner = { ids = { 138878061721163 }, source = "owned", fit = "height", size = 22, yaw = 0 },
	donut_shop = { ids = { 135896859307925 }, source = "owned", fit = "height", size = 28, yaw = 180 },
	gas_station = { ids = { 115309925238713 }, source = "owned", fit = "footprint", size = 60, yaw = 0 },
	gear_shop = { ids = { 89963954819843 }, source = "owned", fit = "height", size = 28, yaw = 180 },
	hotel_beach = { ids = { 126168524790795 }, source = "owned", fit = "height", size = 60, yaw = 180 },
	lighthouse = { ids = { 120444344026342 }, source = "owned", fit = "height", size = 70, yaw = 180 },
	office_block = { ids = { 102502786471185 }, source = "owned", fit = "height", size = 80, yaw = 180 },
	pizza_shop = { ids = { 86133919619221 }, source = "owned", fit = "height", size = 24, yaw = 180 },
	police_hq = { ids = { 97092665150641 }, source = "owned", fit = "height", size = 45, yaw = 180 },
	skyscraper_deco = { ids = { 89642095826066 }, source = "owned", fit = "height", size = 220, yaw = 0 },
	skyscraper_neon = { ids = { 132265407670837 }, source = "owned", fit = "height", size = 200, yaw = 0 },
	skyscraper_twist = { ids = { 136251077265578 }, source = "owned", fit = "height", size = 240, yaw = 0 },
	spray_booth = { ids = { 94876848594661 }, source = "owned", fit = "height", size = 22, yaw = 180 },
	suburban_house = { ids = { 103343058626206 }, source = "owned", fit = "height", size = 26, yaw = 180 },
	surf_shack = { ids = { 114193388991289 }, source = "owned", fit = "height", size = 18, yaw = 90 },
	warehouse = { ids = { 139551179882492 }, source = "owned", fit = "height", size = 35, yaw = 0 },
} :: { [string]: AssetDef }

-- NPC looks (HumanoidDescription fields). Catalog asset ids.
export type Outfit = { shirt: number?, pants: number?, accessories: { number }?, bodyColor: Color3? }
Assets.Outfits = {
	police = {} :: { Outfit },
	civilians = {} :: { Outfit },
}

-- 2D art (Higgsfield-generated, uploaded as Image assets owned by the experience owner). Usable directly as
-- Content strings in Decal/Texture/ImageLabel/SurfaceGui. Billboards pick from the "ad_" keys.
Assets.Images = {
	ad_couch_cruiser = "rbxassetid://121096162394481",
	ad_donut_dash = "rbxassetid://74010446392752",
	ad_gold_rush = "rbxassetid://111057290103994",
	ad_hot_drop = "rbxassetid://135307431044010",
	ad_hotwire_motors = "rbxassetid://70828020326332",
	ad_nitro_cola = "rbxassetid://98358214059781",
	ad_pizza_van = "rbxassetid://133009385208205",
	ad_quack_insurance = "rbxassetid://98063305747867",
	ad_spray_me = "rbxassetid://116526585337940",
	ad_sunny_beach = "rbxassetid://77258665725831",
	loading_art = "rbxassetid://138388641469637",
	logo_hotwire_city = "rbxassetid://109068994523899",
} :: { [string]: string }

function Assets.billboardAds(): { string }
	local out = {}
	for key, content in Assets.Images do
		if string.sub(key, 1, 3) == "ad_" then
			table.insert(out, content)
		end
	end
	table.sort(out)
	return out
end

-- Max concurrent loads at boot.
Assets.LOAD_CONCURRENCY = 4
-- Give up on a single asset after this many seconds.
Assets.LOAD_TIMEOUT = 20

return Assets
