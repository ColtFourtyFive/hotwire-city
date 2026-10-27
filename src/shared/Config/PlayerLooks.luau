--!strict
-- PlayerLooks (C4a characters): every catalog item a player character can wear. The look a player saves is a set of
-- KEYS into these lists (Appearance/LookCodec); the creator and the remotes use 1-based INDICES; the server builds
-- the HumanoidDescription from them (Appearance/DescriptionSpec) and applies it with Humanoid:ApplyDescriptionAsync.
--
-- Rules (00_LEAD_DIRECTION, CONTENT_SAFETY, gta_assets §3):
--   * Roblox catalog items only (no uploads of faces or people). Realistic bodies only: the Base Body family (bundles
--     988-995) plus the Rthro-proportioned 337 / 572 / 573 / 722 bodies. Never the anime bodies (979-987) or the
--     blocky 238 / 239. The 337 and 722 HEADS are stylized (anime eyes, blush) and are not offered; their bodies are.
--   * Never 62234425 (Brown Hair: its texture 404s). PlayerLooks.BANNED lists it; tests fail if it ever appears.
--   * No logo items: the Roblox-logo tees / sweats were rejected on sight (thumbnail sheet in the evidence).
--   * Every garment has a fallback (Roblox-made where one exists); DescriptionSpec walks level 0 (as chosen) ->
--     level 1 (every slot on its fallback) -> level 2 (SAFE: the Base Body bundle's own tank top and shorts, white
--     sneakers, the Roblox "Realistic" animation set) if ApplyDescriptionAsync fails.
--   * Every id below was resolved through economy.roblox.com/v2/assets/<id>/details and
--     assetdelivery.roblox.com/v2/assetId/<id>, and the downloaded accessory files were opened to check that every
--     mesh / texture / cage they reference resolves too: tools/characters/verify_looks.py ->
--     docs/v2/evidence/characters_catalog_verify.json (re-run it after editing this file).
--   * The 2023 Roblox hair line, eyebrows, eyelashes, shoes and all clothing here are LAYERED (their Handle carries a
--     WrapLayer; checked in the downloaded files), so they go into HumanoidDescription:SetAccessories with
--     IsLayered = true and an Order from LAYER_ORDER.
--
-- Bundle part ids: catalog.roblox.com/v1/bundles/<id>/details (2026-10-27).

local PlayerLooks = {}

PlayerLooks.VERSION = 1

-- GTA characters are a touch taller than Roblox's default body; the creator keeps proportions realistic.
PlayerLooks.HEIGHT_SCALE = 1.05
PlayerLooks.HEAD_SCALE = 1.0

-- Asset ids that must never be worn (tests scan this whole module for them).
PlayerLooks.BANNED = {
	[62234425] = "Brown Hair: TextureId 81504106 404s (gta_realism_gap §3.3)",
} :: { [number]: string }
-- Bundles that must never be used (anime 979-987, blocky 238 / 239).
PlayerLooks.BANNED_BUNDLES = {
	[238] = true,
	[239] = true,
	[979] = true,
	[980] = true,
	[981] = true,
	[982] = true,
	[983] = true,
	[984] = true,
	[985] = true,
	[986] = true,
	[987] = true,
} :: { [number]: boolean }

export type BodyParts = { torso: number, leftArm: number, rightArm: number, leftLeg: number, rightLeg: number }

export type Body = {
	key: string,
	name: string,
	bundle: number,
	parts: BodyParts,
	width: number, -- WidthScale / DepthScale (1 = as authored)
	faces: { string }, -- faces the RANDOM look pairs with this frame (the creator allows any face)
	weight: number, -- random-look weight
}

export type Face = {
	key: string,
	name: string,
	bundle: number,
	head: number, -- DynamicHead asset (type 79)
	eyebrows: number?, -- layered, type 76
	eyelashes: number?, -- layered, type 77
}

export type SkinTone = { key: string, name: string, color: Color3 }

export type HairStyle = {
	key: string,
	name: string,
	-- per HairColors key; nil for a shaved head
	ids: { [string]: number }?,
	weight: number,
}

export type HairColor = { key: string, name: string, weight: number }

-- kind = Enum.AccessoryType name (layered clothing). fallback = { id, kind? } (kind defaults to the garment's).
export type Garment = { kind: string, id: number, fallback: { id: number, kind: string? }? }

export type Variant = { key: string, name: string, garments: { Garment }, shoes: string }

export type Outfit = { key: string, name: string, desc: string, variants: { Variant } }

export type Shoes = { key: string, name: string, bundle: number, left: number, right: number }

export type AnimPack = {
	key: string,
	name: string,
	desc: string,
	bundle: number,
	idle: number,
	walk: number,
	run: number,
	jump: number,
	fall: number,
	climb: number,
	swim: number,
	weight: number,
}

-------------------------------------------------------------------------------------------------------------------------
-- Bodies (torso + limbs) and faces (dynamic head + brows + lashes)
-------------------------------------------------------------------------------------------------------------------------

local BASE_FACES = { "addison", "harper", "robin", "dawson", "rene", "andi", "jordan", "billie" }

PlayerLooks.Bodies = {
	{
		key = "harper",
		name = "Harper",
		bundle = 989,
		parts = {
			torso = 11702749784,
			leftArm = 11702744222,
			rightArm = 11702746286,
			leftLeg = 11702745067,
			rightLeg = 11702748396,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "andi",
		name = "Andi",
		bundle = 993,
		parts = {
			torso = 11715264057,
			leftArm = 11715257112,
			rightArm = 11715260558,
			leftLeg = 11715258659,
			rightLeg = 11715262273,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "billie",
		name = "Billie",
		bundle = 995,
		parts = {
			torso = 11748986529,
			leftArm = 11748981874,
			rightArm = 11748984354,
			leftLeg = 11748983268,
			rightLeg = 11748985458,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "dawson",
		name = "Dawson",
		bundle = 991,
		parts = {
			torso = 11709869073,
			leftArm = 11709862883,
			rightArm = 11709865568,
			leftLeg = 11709864101,
			rightLeg = 11709867346,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "addison",
		name = "Addison",
		bundle = 988,
		parts = {
			torso = 11702287641,
			leftArm = 11702279057,
			rightArm = 11702284438,
			leftLeg = 11702282072,
			rightLeg = 11702286099,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "robin",
		name = "Robin",
		bundle = 990,
		parts = {
			torso = 11709146274,
			leftArm = 11709138329,
			rightArm = 11709143116,
			leftLeg = 11709141448,
			rightLeg = 11709144753,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "rene",
		name = "Rene",
		bundle = 992,
		parts = {
			torso = 11714041015,
			leftArm = 11714033534,
			rightArm = 11714037276,
			leftLeg = 11714035598,
			rightLeg = 11714039415,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "jordan",
		name = "Jordan",
		bundle = 994,
		parts = {
			torso = 11740060397,
			leftArm = 11740050465,
			rightArm = 11740055375,
			leftLeg = 11740052832,
			rightLeg = 11740057815,
		},
		width = 1.0,
		faces = BASE_FACES,
		weight = 1,
	},
	{
		key = "oliver",
		name = "Oliver (athletic)",
		bundle = 573,
		parts = {
			torso = 3963871432,
			leftArm = 3963861732,
			rightArm = 3963867514,
			leftLeg = 3963864909,
			rightLeg = 3963869770,
		},
		width = 1.0,
		faces = { "oliver", "harper", "andi", "billie" },
		weight = 2,
	},
	{
		key = "summer",
		name = "Summer (athletic)",
		bundle = 572,
		parts = {
			torso = 3963485362,
			leftArm = 3963476651,
			rightArm = 3963481369,
			leftLeg = 3963479563,
			rightLeg = 3963483107,
		},
		width = 1.0,
		faces = { "summer", "addison", "robin", "jordan" },
		weight = 1.5,
	},
	{
		key = "denny",
		name = "Denny (broad)",
		bundle = 722,
		parts = {
			torso = 6445268819,
			leftArm = 6445260402,
			rightArm = 6445263379,
			leftLeg = 6445262286,
			rightLeg = 6445265102,
		},
		width = 1.04,
		faces = { "oliver", "harper" },
		weight = 1,
	},
	{
		key = "citylife",
		name = "City Life",
		bundle = 337,
		parts = {
			torso = 2492674027,
			leftArm = 2492667589,
			rightArm = 2492669375,
			leftLeg = 2492671662,
			rightLeg = 2492670347,
		},
		width = 1.0,
		faces = { "summer", "robin", "rene" },
		weight = 1,
	},
} :: { Body }

PlayerLooks.Faces = {
	{
		key = "harper",
		name = "Harper",
		bundle = 989,
		head = 11702751287,
		eyebrows = 11702755085,
		eyelashes = 11702757409,
	},
	{ key = "andi", name = "Andi", bundle = 993, head = 11715265417, eyebrows = 11715267394, eyelashes = 11715268504 },
	{
		key = "billie",
		name = "Billie",
		bundle = 995,
		head = 11748988354,
		eyebrows = 11748989953,
		eyelashes = 11748991080,
	},
	{
		key = "dawson",
		name = "Dawson",
		bundle = 991,
		head = 11709871094,
		eyebrows = 11709883139,
		eyelashes = 11709884954,
	},
	{
		key = "addison",
		name = "Addison",
		bundle = 988,
		head = 11702291006,
		eyebrows = 11702295477,
		eyelashes = 11702297008,
	},
	{ key = "robin", name = "Robin", bundle = 990, head = 11709148634, eyebrows = 11709149939, eyelashes = 11709152004 },
	{ key = "rene", name = "Rene", bundle = 992, head = 11714044513, eyebrows = 11714047676, eyelashes = 11714050380 },
	{
		key = "jordan",
		name = "Jordan",
		bundle = 994,
		head = 11740063830,
		eyebrows = 11740066767,
		eyelashes = 11740069153,
	},
	{ key = "oliver", name = "Oliver", bundle = 573, head = 12778883791, eyebrows = 12778888565 },
	{
		key = "summer",
		name = "Summer",
		bundle = 572,
		head = 12853000475,
		eyebrows = 12853002044,
		eyelashes = 12853004141,
	},
} :: { Face }

-- Mood (dynamic-head expression). 0 = the engine's default mood (neutral, blinks). The Base Body bundles ship the
-- "Anime - Mood" 11573370910, which is NOT used.
PlayerLooks.MOOD = 0

-------------------------------------------------------------------------------------------------------------------------
-- Skin tones (BodyColors; every base body here is recolorable)
-------------------------------------------------------------------------------------------------------------------------

PlayerLooks.SkinTones = {
	{ key = "t1", name = "Porcelain", color = Color3.fromRGB(243, 214, 196) },
	{ key = "t2", name = "Fair", color = Color3.fromRGB(234, 194, 166) },
	{ key = "t3", name = "Light", color = Color3.fromRGB(222, 172, 138) },
	{ key = "t4", name = "Warm beige", color = Color3.fromRGB(205, 158, 120) },
	{ key = "t5", name = "Olive", color = Color3.fromRGB(190, 142, 104) },
	{ key = "t6", name = "Tan", color = Color3.fromRGB(170, 120, 84) },
	{ key = "t7", name = "Bronze", color = Color3.fromRGB(146, 98, 66) },
	{ key = "t8", name = "Brown", color = Color3.fromRGB(120, 78, 52) },
	{ key = "t9", name = "Dark brown", color = Color3.fromRGB(94, 60, 40) },
	{ key = "t10", name = "Deep", color = Color3.fromRGB(68, 42, 29) },
} :: { SkinTone }

-------------------------------------------------------------------------------------------------------------------------
-- Hair: the free 2023 Roblox hair line, four colours per style (all layered, all Roblox-made, all free)
-------------------------------------------------------------------------------------------------------------------------

PlayerLooks.HairColors = {
	{ key = "black", name = "Black", weight = 0.4 },
	{ key = "brown", name = "Brown", weight = 0.35 },
	{ key = "blonde", name = "Blonde", weight = 0.15 },
	{ key = "red", name = "Auburn", weight = 0.1 },
} :: { HairColor }

PlayerLooks.HairStyles = {
	{
		key = "sidepart",
		name = "Side Part",
		ids = { black = 9244021842, brown = 7193419595, blonde = 7193386173, red = 9244024443 },
		weight = 1,
	},
	{
		key = "fringe",
		name = "Short Fringe",
		ids = { black = 7193401217, brown = 9243976603, blonde = 7193397693, red = 9243983205 },
		weight = 1,
	},
	{
		key = "sleek",
		name = "Short and Sleek",
		ids = { black = 9243992729, brown = 6993758617, blonde = 9243987340, red = 9243995099 },
		weight = 1,
	},
	{
		key = "fade",
		name = "Curly Fade",
		ids = { black = 7193405096, brown = 9244010432, blonde = 9244008307, red = 9244014391 },
		weight = 1,
	},
	{
		key = "curls",
		name = "Short Curls",
		ids = { black = 7193452166, brown = 9244137452, blonde = 9244134513, red = 9244145658 },
		weight = 1,
	},
	{
		key = "surfer",
		name = "Surfer",
		ids = { black = 9174353649, brown = 9244033194, blonde = 9244029916, red = 9244038785 },
		weight = 0.8,
	},
	{
		key = "middlepart",
		name = "Middle Part",
		ids = { black = 9244089488, brown = 7193437847, blonde = 7193424874, red = 9244091757 },
		weight = 0.8,
	},
	{
		key = "wavy",
		name = "Wavy Middle Part",
		ids = { black = 9244111257, brown = 7193448258, blonde = 7193445686, red = 9244114211 },
		weight = 0.7,
	},
	{
		key = "bangs",
		name = "Straight Bangs",
		ids = { black = 6993754725, brown = 7193449810, blonde = 7193448988, red = 9244122897 },
		weight = 0.6,
	},
	{
		key = "ponytail",
		name = "Ponytail",
		ids = { black = 7193442167, brown = 9244097555, blonde = 9244095135, red = 7193444640 },
		weight = 0.6,
	},
	{
		key = "braids",
		name = "Braids",
		ids = { black = 7193454569, brown = 9244150641, blonde = 9244148336, red = 7193455510 },
		weight = 0.6,
	},
	{
		key = "afro",
		name = "Curly Afro",
		ids = { black = 7193450455, brown = 7193451306, blonde = 9244125859, red = 9244131570 },
		weight = 0.6,
	},
	{ key = "shaved", name = "Shaved", ids = nil, weight = 0.5 },
} :: { HairStyle }

-- The style whose BLACK variant is every hair slot's fallback.
PlayerLooks.HAIR_FALLBACK_STYLE = "sidepart"

-------------------------------------------------------------------------------------------------------------------------
-- Shoes (Roblox shoe bundles: a layered left + right accessory)
-------------------------------------------------------------------------------------------------------------------------

PlayerLooks.Shoes = {
	sneakers_white = {
		key = "sneakers_white",
		name = "White sneakers",
		bundle = 896,
		left = 9482987287,
		right = 9482991343,
	},
	canvas_white = { key = "canvas_white", name = "White canvas", bundle = 894, left = 9481782649, right = 9481786623 },
	canvas_gray = { key = "canvas_gray", name = "Grey canvas", bundle = 905, left = 9483690316, right = 9483697460 },
	dress_black = { key = "dress_black", name = "Black dress shoes", bundle = 907, left = 8044843668, right = 8044852814 },
	dress_brown = { key = "dress_brown", name = "Brown dress shoes", bundle = 925, left = 8044823721, right = 8044826993 },
	boots_black = { key = "boots_black", name = "Black work boots", bundle = 916, left = 9542395442, right = 9542450828 },
	boots_tan = { key = "boots_tan", name = "Tan work boots", bundle = 882, left = 7193170137, right = 7193171232 },
	military_black = {
		key = "military_black",
		name = "Black military boots",
		bundle = 930,
		left = 9614836327,
		right = 9614841343,
	},
	hightops_black = {
		key = "hightops_black",
		name = "Black high tops",
		bundle = 928,
		left = 9614791602,
		right = 9614793581,
	},
} :: { [string]: Shoes }

PlayerLooks.SHOES_FALLBACK = "sneakers_white" -- Roblox-made, free

-------------------------------------------------------------------------------------------------------------------------
-- Outfits: 5 styles x 3-5 variants of layered clothing (gta_assets §3.3, Roblox-made first)
-------------------------------------------------------------------------------------------------------------------------

-- Roblox-made fallbacks used below
local TEE_GRAY = 9112474888 -- Basic T-Shirt - Gray (Roblox, free)
local BASEBALL_TEE = 9120031517 -- Baseball Long Sleeve - B&W (Roblox, free)
local CARGO_BROWN = 6984740059 -- Cargo Pants - Brown (Roblox, free)
local MOTO_PANTS = 8721985925 -- Motorcycle Pants - Brown (Roblox, free)
local HOODED_GRAY = 8516620262 -- Hooded Jacket - Gray (Roblox, free)
local ZIP_BLACK = 7192553841 -- Zip Hoodie - Black (Roblox, free)
local BIZ_GRAY = 8516638468 -- Business Coat - Gray (Roblox, free)
local LEATHER_BLACK = 7192549218 -- Leather Jacket - Black (Roblox, free)
local LEATHER_BROWN = 6984767443 -- Leather Jacket - Brown (Roblox, free)
local FLORAL = 9728267998 -- Floral Button Down - Forest (Roblox)
local BERMUDA = 9174391966 -- Bermuda Shorts - Black (Roblox, free)
local SWIM_WHITE = 9274635732 -- Floral Swim Trunks - White (Roblox, free)
local SWEATER_GRAY = 9240758221 -- Knit Sweater - Gray (Roblox, free)
local SWEATER_BLACK = 9240757332 -- Knit Sweater - Black (Roblox, free)

-- Third-party (verified creators, realistic, no logos)
local TEE_WHITE = 132094497182540 -- Plain White T-Shirt (exactly ablimity)
local TEE_BLACK = 104803779228359 -- Plain Black T-Shirt (exactly ablimity)
local JEANS_NAVY = 85947788964178 -- Navy Straight Leg Jeans (Kool closet)
local JEANS_LIGHT = 85259263998312 -- Straight Light Blue Jeans (Kool closet)
local JEANS_BLACK = 128896444649642 -- Black Slim Jeans (Kool closet)
local JEANS_SLATE = 122004327092802 -- Slate Gray Slim Jeans (Kool closet)
local CHINO_BLACK = 13958227340 -- Black Chinos (Eternos Digital)
local CHINO_GREY = 13958225096 -- Grey Chinos (Eternos Digital)
local CHINO_NAVY = 13958229751 -- Navy Blue Chinos (Eternos Digital)
local WHITE_SHIRT = 16993920746 -- Plain White Shirt (Clarity of Magic)

local function g(kind: string, id: number, fbId: number?, fbKind: string?): Garment
	return {
		kind = kind,
		id = id,
		fallback = if fbId then { id = fbId, kind = fbKind } else nil,
	}
end

PlayerLooks.Outfits = {
	{
		key = "street",
		name = "Street",
		desc = "Hoodies, jackets and jeans: the default city look.",
		variants = {
			{
				key = "street_hoodie",
				name = "Black zip hoodie",
				garments = {
					g("Jacket", ZIP_BLACK, HOODED_GRAY),
					g("TShirt", TEE_WHITE, TEE_GRAY),
					g("Pants", JEANS_NAVY, CARGO_BROWN),
				},
				shoes = "sneakers_white",
			},
			{
				key = "street_hooded",
				name = "Grey hooded jacket",
				garments = {
					g("Jacket", HOODED_GRAY, ZIP_BLACK),
					g("TShirt", TEE_BLACK, TEE_GRAY),
					g("Pants", JEANS_BLACK, CARGO_BROWN),
				},
				shoes = "hightops_black",
			},
			{
				key = "street_denim",
				name = "Denim jacket",
				garments = {
					g("Jacket", 8516609675, HOODED_GRAY), -- Denim Jacket - Light Wash (Roblox)
					g("TShirt", TEE_GRAY, BASEBALL_TEE),
					g("Pants", JEANS_SLATE, CARGO_BROWN),
				},
				shoes = "canvas_white",
			},
			{
				key = "street_teal",
				name = "Teal hoodie",
				garments = {
					g("Jacket", 8648389231, ZIP_BLACK), -- Zip Hoodie - Teal (Roblox)
					g("TShirt", TEE_WHITE, TEE_GRAY),
					g("Pants", JEANS_LIGHT, CARGO_BROWN),
				},
				shoes = "sneakers_white",
			},
			{
				key = "street_knit",
				name = "Knit sweater",
				garments = {
					g("Sweater", 6984769289, SWEATER_GRAY), -- Knit Sweater - Beige (Roblox)
					g("Pants", JEANS_NAVY, CARGO_BROWN),
				},
				shoes = "canvas_white",
			},
		},
	},
	{
		key = "business",
		name = "Business",
		desc = "Suits, coats and chinos for the financial district.",
		variants = {
			{
				key = "business_suit",
				name = "Black suit",
				garments = {
					g("Jacket", 12300764586, BIZ_GRAY), -- Black Business Tuxedo Blazer (Eternos Digital)
					g("Shirt", WHITE_SHIRT, TEE_GRAY, "TShirt"),
					g("Pants", 12331823194, CHINO_BLACK), -- Black Business Tuxedo Pants (Eternos Digital)
				},
				shoes = "dress_black",
			},
			{
				key = "business_coat",
				name = "Grey business coat",
				garments = {
					g("Jacket", BIZ_GRAY, 8516648620),
					g("Shirt", WHITE_SHIRT, TEE_GRAY, "TShirt"),
					g("Pants", CHINO_GREY, CARGO_BROWN),
				},
				shoes = "dress_black",
			},
			{
				key = "business_pinstripe",
				name = "Pinstripe coat",
				garments = {
					g("Jacket", 8516648620, BIZ_GRAY), -- Business Coat - Striped Gray (Roblox)
					g("TShirt", TEE_BLACK, TEE_GRAY),
					g("Pants", CHINO_BLACK, MOTO_PANTS),
				},
				shoes = "dress_brown",
			},
			{
				key = "business_tie",
				name = "Blazer and tie",
				garments = {
					g("Shirt", 121486536255417, BIZ_GRAY, "Jacket"), -- Black Blazer w/ Shirt & Tie (ANGVLI)
					g("Pants", CHINO_NAVY, CARGO_BROWN),
				},
				shoes = "dress_black",
			},
			{
				key = "business_trench",
				name = "Trench coat",
				garments = {
					g("Jacket", 8648380153, BIZ_GRAY), -- Trench Coat - White (Roblox)
					g("Sweater", SWEATER_BLACK, SWEATER_GRAY),
					g("Pants", CHINO_NAVY, CARGO_BROWN),
				},
				shoes = "dress_brown",
			},
		},
	},
	{
		key = "biker",
		name = "Biker",
		desc = "Leather, denim and boots.",
		variants = {
			{
				key = "biker_black",
				name = "Black leather",
				garments = {
					g("Jacket", LEATHER_BLACK, LEATHER_BROWN),
					g("TShirt", TEE_BLACK, TEE_GRAY),
					g("Pants", JEANS_BLACK, MOTO_PANTS),
				},
				shoes = "boots_black",
			},
			{
				key = "biker_brown",
				name = "Brown leather",
				garments = {
					g("Jacket", LEATHER_BROWN, LEATHER_BLACK),
					g("TShirt", TEE_WHITE, TEE_GRAY),
					g("Pants", MOTO_PANTS, CARGO_BROWN),
				},
				shoes = "boots_tan",
			},
			{
				key = "biker_collar",
				name = "Collared leather",
				garments = {
					g("Jacket", 7192547628, LEATHER_BROWN), -- Collared Leather Jacket - Brown (Roblox)
					g("TShirt", TEE_GRAY, BASEBALL_TEE),
					g("Pants", JEANS_NAVY, CARGO_BROWN),
				},
				shoes = "military_black",
			},
		},
	},
	{
		key = "beach",
		name = "Beach",
		desc = "Aloha shirts, shorts and trunks for the boardwalk.",
		variants = {
			{
				key = "beach_floral",
				name = "Floral shirt",
				garments = {
					g("Shirt", FLORAL, TEE_GRAY, "TShirt"),
					g("Shorts", BERMUDA, SWIM_WHITE),
				},
				shoes = "canvas_white",
			},
			{
				key = "beach_red",
				name = "Red aloha shirt",
				garments = {
					g("Shirt", 9342978533, FLORAL), -- Red Hawaiian Open Shirt (KelvinBlues1)
					g("TShirt", TEE_WHITE, TEE_GRAY),
					g("Shorts", SWIM_WHITE, BERMUDA),
				},
				shoes = "sneakers_white",
			},
			{
				key = "beach_turquoise",
				name = "Turquoise aloha shirt",
				garments = {
					g("Shirt", 9342985332, FLORAL), -- Turquoise Hawaiian Open Shirt (KelvinBlues1)
					g("Shorts", 7192687500, BERMUDA), -- Jean Shorts - Light Wash (Roblox)
				},
				shoes = "canvas_white",
			},
			{
				key = "beach_trunks",
				name = "Tee and trunks",
				garments = {
					g("TShirt", TEE_WHITE, TEE_GRAY),
					g("Shorts", 7192685245, SWIM_WHITE), -- Floral Swim Trunks - Blue (Roblox)
				},
				shoes = "canvas_gray",
			},
		},
	},
	{
		key = "workwear",
		name = "Workwear",
		desc = "Hi-vis, cargo pants and work boots.",
		variants = {
			{
				key = "work_vest_green",
				name = "Hi-vis vest",
				garments = {
					g("Jacket", 18863624639, 18863614932), -- Neon Green Construction Vest (Builder_Boy UGC)
					g("TShirt", TEE_GRAY, BASEBALL_TEE),
					g("Pants", CARGO_BROWN, MOTO_PANTS),
				},
				shoes = "boots_tan",
			},
			{
				key = "work_vest_orange",
				name = "Orange safety vest",
				garments = {
					g("Jacket", 18863614932, 18863624639), -- Orange Construction Vest (Builder_Boy UGC)
					g("TShirt", TEE_BLACK, TEE_GRAY),
					g("Pants", JEANS_NAVY, CARGO_BROWN),
				},
				shoes = "boots_black",
			},
			{
				key = "work_parka",
				name = "Parka",
				garments = {
					g("Jacket", 8648397446, HOODED_GRAY), -- Parka - Brown (Roblox)
					g("Sweater", SWEATER_GRAY, SWEATER_BLACK),
					g("Pants", CARGO_BROWN, MOTO_PANTS),
				},
				shoes = "boots_black",
			},
			{
				key = "work_flannel",
				name = "Flannel shirt",
				garments = {
					g("Shirt", 7178744611, 7178743190), -- Flannel - Red / Green (Roblox)
					g("Pants", JEANS_SLATE, CARGO_BROWN),
				},
				shoes = "boots_tan",
			},
		},
	},
} :: { Outfit }

-------------------------------------------------------------------------------------------------------------------------
-- Walk styles: catalog avatar-animation packs set on the HumanoidDescription (no ownership needed, gta_assets §3.2)
-------------------------------------------------------------------------------------------------------------------------

PlayerLooks.WalkStyles = {
	{
		key = "community",
		name = "Natural",
		desc = "adidas Community mocap: relaxed, natural steps.",
		bundle = 2623795,
		idle = 126354114956642,
		walk = 106810508343012,
		run = 124765145869332,
		jump = 115715495289805,
		fall = 93993406355955,
		climb = 123695349157584,
		swim = 106537993816942,
		weight = 0.6,
	},
	{
		key = "sports",
		name = "Athletic",
		desc = "adidas Sports mocap: a quicker, sporty stride.",
		bundle = 427999,
		idle = 18538150608,
		walk = 18538146480,
		run = 18538133604,
		jump = 18538153691,
		fall = 18538164337,
		climb = 18538170170,
		swim = 18538158932,
		weight = 0.25,
	},
	{
		key = "realistic",
		name = "Casual",
		desc = "Roblox Realistic set (the Base Body animations).",
		bundle = 988,
		idle = 11600321661,
		walk = 11600331426,
		run = 11600327265,
		jump = 11600324801,
		fall = 11600319649,
		climb = 11600317961,
		swim = 11600329588,
		weight = 0.15,
	},
	-- scout_platforms §4.2 (catalog bundle details 2026-10-27)
	{
		key = "aura",
		name = "Young",
		desc = "adidas aura mocap: light, young and athletic.",
		bundle = 4294795,
		idle = 73137983344853,
		walk = 75183215343859,
		run = 123973978164540,
		jump = 129527230938281,
		fall = 99457463463495,
		climb = 140398319728398,
		swim = 119007025452432,
		weight = 0.15,
	},
	{
		key = "stylish",
		name = "Swagger",
		desc = "Roblox Stylish pack: a downtown strut.",
		bundle = 83,
		idle = 619511648,
		walk = 619512767,
		run = 619512153,
		jump = 619511974,
		fall = 619511417,
		climb = 619509955,
		swim = 619512450,
		weight = 0.1,
	},
	{
		key = "elder",
		name = "Weathered",
		desc = "Roblox Elder pack: a slower, heavier gait.",
		bundle = 48,
		idle = 892268340,
		walk = 892267099,
		run = 892265784,
		jump = 892267917,
		fall = 892267521,
		climb = 892269341,
		swim = 892268710,
		weight = 0, -- offered in the creator, never rolled at random
	},
} :: { AnimPack }

-- Idle variety (scout_platforms §4.1): Roblox-owned emotes played now and then while the player stands still on foot
-- (FootMovement). `anim` is the INNER Animation id (what Animator:LoadAnimation takes); `emote` the catalog item.
export type Fidget = { key: string, emote: number, anim: number, weight: number }
PlayerLooks.IdleFidgets = {
	{ key = "bored", emote = 5230661597, anim = 10713992055, weight = 0.5 },
	{ key = "tilt", emote = 0, anim = 10714338461, weight = 0.3 },
	{ key = "shrug", emote = 3576968026, anim = 10714374484, weight = 0.2 },
} :: { Fidget }

-- Level-1 fallback for any walk style, and the level-2 safe set: Roblox-made, free.
PlayerLooks.ANIM_FALLBACK = "realistic"
PlayerLooks.ANIM_SAFE = {
	key = "rthro",
	name = "Rthro",
	desc = "Roblox Rthro animation package (bundle 356, free).",
	bundle = 356,
	idle = 2510235063,
	walk = 2510242378,
	run = 2510238627,
	jump = 2510236649,
	fall = 2510233257,
	climb = 2510230574,
	swim = 2510240941,
	weight = 0,
} :: AnimPack

-------------------------------------------------------------------------------------------------------------------------
-- Level-2 safe look and layering
-------------------------------------------------------------------------------------------------------------------------

-- If both the chosen items and their fallbacks fail to apply: the Base Body bundle's own clothes (Roblox, bundled
-- with 992 Rene) on the chosen body, white sneakers, no hair accessory changes beyond the fallback style.
PlayerLooks.SAFE = {
	body = "dawson",
	face = "dawson",
	garments = {
		{ kind = "TShirt", id = 11625093004 }, -- Tank Top - Gray (Roblox, bundle 992)
		{ kind = "Shorts", id = 11625096506 }, -- Shorts - Gray (Roblox, bundle 992)
	} :: { Garment },
	shoes = "sneakers_white",
}

-- Layered-clothing Order (lower = closer to the body): shoes under the trouser legs, tops untucked over the
-- trousers, sweaters over shirts, jackets outermost. Brows / lashes sit on the face (nothing overlaps them); hair is
-- worn over the jacket collar.
PlayerLooks.LAYER_ORDER = {
	Eyebrow = 1,
	Eyelash = 1,
	LeftShoe = 2,
	RightShoe = 2,
	Pants = 3,
	Shorts = 3,
	DressSkirt = 4,
	TShirt = 5,
	Shirt = 6,
	Sweater = 7,
	Jacket = 9,
	Hair = 12,
} :: { [string]: number }

-- Every slot the look builder fills, for the verify tool and the tests.
PlayerLooks.GARMENT_KINDS = { "TShirt", "Shirt", "Sweater", "Jacket", "Pants", "Shorts", "DressSkirt" }

return PlayerLooks
