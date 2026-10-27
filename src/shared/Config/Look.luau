--!strict
-- Config/Look: the v2 "look" (docs/v2/PLAN.md decision 3, research/lighting_lab.md, research/gta_realism_gap.md).
--
-- * Day cycle, lighting presets, sky schedule and night thresholds for LightingService (server).
-- * MaterialVariants, base-material overrides, decal images and sky faces (GENERATED block at the bottom, written by
--   tools/look/gen_project.py from assets/materials + assets/sky manifests; the same data is baked into
--   default.project.json MaterialService / Lighting.Sky, because MaterialVariant maps cannot be set by game scripts).
--
-- Pure data: no Roblox types, colours are { r, g, b } in 0..255, so tools/look/export_look.luau can export this module
-- to JSON for the generator. LightingService converts colours at runtime.
--
-- COLOUR CONTRACT for HC_ MaterialVariants (same rule as Roblox's own 2022 materials): the colour maps are bright
-- near-neutral detail maps and BasePart.Color (or the terrain material colour) supplies the albedo. Use
-- Look.Materials[name].color as the default Part.Color for a part that uses that variant (or its base material,
-- since overrides are global). Terrain: Look.TerrainColors.

export type RGB = { number }

export type Preset = {
	brightness: number,
	exposure: number,
	ambient: RGB,
	outdoorAmbient: RGB,
	shadowSoftness: number,
	atmosphere: {
		density: number,
		offset: number,
		haze: number,
		glare: number,
		color: RGB,
		decay: RGB,
	},
	bloom: { intensity: number, size: number, threshold: number },
	colorCorrection: { brightness: number, contrast: number, saturation: number, tint: RGB },
	sunRays: { intensity: number, spread: number },
	clouds: { cover: number, density: number, color: RGB },
}

export type MaterialDef = {
	key: string,
	baseMaterial: string,
	override: boolean,
	colorMap: string,
	normalMap: string,
	roughnessMap: string,
	metalnessMap: string?,
	studsPerTile: number,
	pattern: string,
	color: RGB,
	note: string,
}

export type DecalDef = {
	image: string,
	width: number,
	height: number,
	studsPerTileU: number?,
	studsPerTileV: number?,
	note: string,
}

export type SkyDef = {
	faces: { [string]: string }, -- Bk/Dn/Ft/Lf/Rt/Up -> rbxassetid (Image assets)
	glowAzimuth: number, -- degrees, 0 = -Z, 90 = +X (azimuth of the HDRI's brightest region / sun before rotation)
	sunAzimuth: number?,
	sunElevation: number?,
	followSun: boolean, -- keep SkyboxOrientation aligned with the engine sun while this sky is up
	starCount: number,
	hazeColor: RGB,
}

local Look = {}

---------------------------------------------------------------------------------------------------------------------
-- Day cycle
---------------------------------------------------------------------------------------------------------------------

Look.Cycle = {
	lengthSeconds = 24 * 60, -- one full 24 h game day = 24 real minutes
	startHour = 11.0, -- new servers start late morning (first impressions in daylight)
	clockInterval = 1, -- seconds between Lighting.ClockTime writes (replicated)
	envInterval = 2, -- seconds between look evaluations (Atmosphere, post effects, sky)
	-- Relative clock speed per band (normalised so the whole day lasts lengthSeconds): night runs fast, dawn/dusk
	-- slow. With these weights: night ~4.6 min, dawn ~5.6 min, day ~8.1 min, golden evening + dusk ~5.6 min.
	bands = {
		{ from = 0, to = 4.5, weight = 0.5 },
		{ from = 4.5, to = 8.5, weight = 1.3 },
		{ from = 8.5, to = 16, weight = 1.0 },
		{ from = 16, to = 20, weight = 1.3 },
		{ from = 20, to = 24, weight = 0.5 },
	},
}

-- NightFactor (Workspace attribute, 0 = day .. 1 = night; smoothstep ramps) drives lit windows and street lights.
Look.Night = {
	duskStart = 17.9,
	duskFull = 19.4,
	dawnFull = 4.9,
	dawnEnd = 6.3,
	lightsOn = 0.5, -- v1 contract (StreetLight / NightGlow tags, Lighting "IsNight") switches here ...
	hysteresis = 0.05, -- ... with this much hysteresis
}

-- Hard limits from lighting lab round 1 (aerial views drown above ~0.35 density; the brown wall was Haze 2.05).
Look.Caps = {
	densityMax = 0.30,
	hazeMax = 1.2,
}

-- Lab round 2 (studio/jobs/0007) settles these. offset = nil keeps each preset's own Atmosphere.Offset.
-- Live overrides in Play mode: Workspace attributes "AtmosphereOffsetOverride" (number) and "TimeOfDayLock" (hour).
export type Tuning = { offset: number?, hazeScale: number, densityScale: number }
Look.Tuning = { hazeScale = 1, densityScale = 1 } :: Tuning

---------------------------------------------------------------------------------------------------------------------
-- Presets (lab-calibrated: day_clear is the base; neutral warm-grey haze by day, desaturated navy-grey at night)
---------------------------------------------------------------------------------------------------------------------

local Presets: { [string]: Preset } = {
	day = {
		brightness = 3.0,
		exposure = 0,
		ambient = { 14, 14, 16 },
		outdoorAmbient = { 120, 124, 132 },
		shadowSoftness = 0.12,
		atmosphere = {
			density = 0.27,
			offset = 0.25,
			haze = 0.9,
			glare = 0.25,
			color = { 200, 199, 194 },
			decay = { 128, 130, 134 },
		},
		bloom = { intensity = 0.45, size = 24, threshold = 1.75 },
		colorCorrection = { brightness = 0, contrast = 0.1, saturation = 0.02, tint = { 255, 252, 246 } },
		sunRays = { intensity = 0.04, spread = 0.6 },
		clouds = { cover = 0.32, density = 0.42, color = { 246, 246, 244 } },
	},
	goldenMorning = {
		brightness = 2.9,
		exposure = 0.05,
		ambient = { 16, 14, 14 },
		outdoorAmbient = { 124, 116, 108 },
		shadowSoftness = 0.16,
		atmosphere = {
			density = 0.27,
			offset = 0.28,
			haze = 1.0,
			glare = 0.45,
			color = { 226, 214, 196 },
			decay = { 124, 124, 134 },
		},
		bloom = { intensity = 0.55, size = 26, threshold = 1.6 },
		colorCorrection = { brightness = 0, contrast = 0.12, saturation = 0.05, tint = { 255, 248, 238 } },
		sunRays = { intensity = 0.09, spread = 0.65 },
		clouds = { cover = 0.3, density = 0.42, color = { 255, 232, 212 } },
	},
	goldenEvening = {
		brightness = 3.1,
		exposure = 0.05,
		ambient = { 18, 14, 12 },
		outdoorAmbient = { 130, 112, 100 },
		shadowSoftness = 0.18,
		atmosphere = {
			density = 0.27,
			offset = 0.3,
			haze = 1.05,
			glare = 0.55,
			color = { 234, 212, 184 },
			decay = { 128, 124, 140 },
		},
		bloom = { intensity = 0.6, size = 28, threshold = 1.5 },
		colorCorrection = { brightness = 0, contrast = 0.12, saturation = 0.07, tint = { 255, 244, 230 } },
		sunRays = { intensity = 0.11, spread = 0.65 },
		clouds = { cover = 0.34, density = 0.45, color = { 255, 226, 200 } },
	},
	blueMorning = {
		brightness = 1.4,
		exposure = 0.25,
		ambient = { 12, 13, 18 },
		outdoorAmbient = { 84, 90, 108 },
		shadowSoftness = 0.25,
		atmosphere = {
			density = 0.25,
			offset = 0.2,
			haze = 0.8,
			glare = 0.1,
			color = { 122, 128, 144 },
			decay = { 72, 76, 92 },
		},
		bloom = { intensity = 0.85, size = 30, threshold = 1.25 },
		colorCorrection = { brightness = 0, contrast = 0.12, saturation = -0.02, tint = { 242, 245, 255 } },
		sunRays = { intensity = 0.02, spread = 0.6 },
		clouds = { cover = 0.3, density = 0.4, color = { 132, 134, 148 } },
	},
	blueEvening = {
		brightness = 1.3,
		exposure = 0.28,
		ambient = { 12, 12, 17 },
		outdoorAmbient = { 88, 88, 104 },
		shadowSoftness = 0.25,
		atmosphere = {
			density = 0.25,
			offset = 0.2,
			haze = 0.8,
			glare = 0.1,
			color = { 132, 130, 142 },
			decay = { 74, 74, 90 },
		},
		bloom = { intensity = 0.9, size = 30, threshold = 1.2 },
		colorCorrection = { brightness = 0, contrast = 0.13, saturation = -0.02, tint = { 244, 244, 255 } },
		sunRays = { intensity = 0.02, spread = 0.6 },
		clouds = { cover = 0.32, density = 0.42, color = { 128, 126, 140 } },
	},
	night = {
		brightness = 1.0,
		exposure = 0.3,
		ambient = { 8, 9, 12 },
		outdoorAmbient = { 50, 56, 70 },
		shadowSoftness = 0.3,
		atmosphere = {
			density = 0.22,
			offset = 0.15,
			haze = 0.5,
			glare = 0,
			color = { 46, 52, 64 },
			decay = { 22, 24, 32 },
		},
		bloom = { intensity = 1.0, size = 30, threshold = 1.05 },
		colorCorrection = { brightness = 0, contrast = 0.15, saturation = -0.05, tint = { 236, 240, 255 } },
		sunRays = { intensity = 0, spread = 0.5 },
		clouds = { cover = 0.3, density = 0.4, color = { 52, 56, 68 } },
	},
}
Look.Presets = Presets

-- Keyframes (sorted, 0 and 24 are the same preset so midnight wraps). Between keys LightingService smoothsteps.
Look.Keys = {
	{ hour = 0, preset = "night" },
	{ hour = 4.4, preset = "night" },
	{ hour = 5.6, preset = "blueMorning" },
	{ hour = 6.9, preset = "goldenMorning" },
	{ hour = 9.4, preset = "day" },
	{ hour = 15.4, preset = "day" },
	{ hour = 17.3, preset = "goldenEvening" },
	{ hour = 18.6, preset = "blueEvening" },
	{ hour = 19.9, preset = "night" },
	{ hour = 24, preset = "night" },
}

---------------------------------------------------------------------------------------------------------------------
-- Sky schedule: each entry holds until the next (wraps at 24). Swaps sit where the change is least visible: with the
-- sun below the horizon (blue <-> night, golden -> blue) or under a short haze bump (day <-> golden).
---------------------------------------------------------------------------------------------------------------------

Look.SkySchedule = {
	{ hour = 5.0, sky = "blue" },
	{ hour = 5.95, sky = "golden" }, -- just before sunrise (Roblox sun rises at 06:00)
	{ hour = 8.7, sky = "day" },
	{ hour = 15.8, sky = "golden" },
	{ hour = 18.1, sky = "blue" },
	{ hour = 19.5, sky = "night" },
}

Look.SkySwap = {
	hazeBoost = 0.2, -- extra Atmosphere.Haze at a swap (still capped by Caps.hazeMax) ...
	width = 0.3, -- ... gaussian width in game hours
}

Look.SkyStyle = {
	sunAngularSize = 10, -- real sun ~0.5 deg; 21 default reads storybook
	moonAngularSize = 6,
	celestialBodiesShown = true,
	-- SkyboxOrientation.Y = yawSign * (sky glow azimuth - engine sun azimuth). +1 assumes the CFrame.Angles(0, y, 0)
	-- convention; studio/jobs/0007 step S0 verifies it (flip to -1 if the glow ends up mirrored).
	yawSign = 1,
	yawEpsilon = 2, -- degrees; SkyboxOrientation is only rewritten past this
}

-- Wet-road look at night: swap the Asphalt override to HC_AsphaltWet (low roughness). Off until lab round 2 judges it.
Look.WetStreets = {
	enabled = false,
	nightFactor = 0.6,
	dry = "HC_Asphalt",
	wet = "HC_AsphaltWet",
}

---------------------------------------------------------------------------------------------------------------------
-- BEGIN GENERATED (tools/look/gen_project.py) - do not edit by hand
---------------------------------------------------------------------------------------------------------------------

local Materials: { [string]: MaterialDef } = {
	HC_Asphalt = {
		key = "asphalt",
		baseMaterial = "Asphalt",
		override = true,
		colorMap = "rbxassetid://106080567087674",
		normalMap = "rbxassetid://82395533791334",
		roughnessMap = "rbxassetid://101400097276672",
		studsPerTile = 10.71,
		pattern = "Organic",
		color = { 103, 103, 106 },
		note = "Road asphalt for avenues and streets (fine dark aggregate).",
	},
	HC_AsphaltWet = {
		key = "asphalt_wet",
		baseMaterial = "Asphalt",
		override = false,
		colorMap = "rbxassetid://106080567087674",
		normalMap = "rbxassetid://82395533791334",
		roughnessMap = "rbxassetid://113458825437012",
		studsPerTile = 10.71,
		pattern = "Organic",
		color = { 77, 77, 80 },
		note = "Night/rain swap for HC_Asphalt (same colour+normal, wet roughness with puddles).",
	},
	HC_AsphaltWorn = {
		key = "asphalt_worn",
		baseMaterial = "Asphalt",
		override = false,
		colorMap = "rbxassetid://98395841471900",
		normalMap = "rbxassetid://125684889345496",
		roughnessMap = "rbxassetid://73345421491533",
		studsPerTile = 10.71,
		pattern = "Organic",
		color = { 179, 177, 171 },
		note = "Worn, cracked asphalt for older streets, alleys and lots.",
	},
	HC_BrickRed = {
		key = "brick_red",
		baseMaterial = "Brick",
		override = true,
		colorMap = "rbxassetid://130389958232148",
		normalMap = "rbxassetid://118833929106156",
		roughnessMap = "rbxassetid://80026467457562",
		studsPerTile = 5,
		pattern = "Regular",
		color = { 177, 141, 124 },
		note = "Red running-bond brick with grey mortar.",
	},
	HC_BrickTan = {
		key = "brick_tan",
		baseMaterial = "Brick",
		override = false,
		colorMap = "rbxassetid://119510173406235",
		normalMap = "rbxassetid://83497670939370",
		roughnessMap = "rbxassetid://121569179287723",
		studsPerTile = 8.57,
		pattern = "Regular",
		color = { 220, 197, 171 },
		note = "Tan/buff brick, LA mid-century commercial.",
	},
	HC_Concrete = {
		key = "concrete",
		baseMaterial = "Concrete",
		override = true,
		colorMap = "rbxassetid://88103143620940",
		normalMap = "rbxassetid://108032317587097",
		roughnessMap = "rbxassetid://108738468113416",
		studsPerTile = 9.29,
		pattern = "Organic",
		color = { 186, 183, 176 },
		note = "Plain cast concrete: curbs, medians, freeway decks and pillars, walls.",
	},
	HC_ConcreteModern = {
		key = "concrete_modern",
		baseMaterial = "Concrete",
		override = false,
		colorMap = "rbxassetid://116943333841057",
		normalMap = "rbxassetid://128078512570380",
		roughnessMap = "rbxassetid://127760521028360",
		studsPerTile = 7.86,
		pattern = "Organic",
		color = { 220, 218, 212 },
		note = "Smooth light architectural concrete for modern facades.",
	},
	HC_CorrugatedMetal = {
		key = "corrugated_metal",
		baseMaterial = "Metal",
		override = false,
		colorMap = "rbxassetid://139585554377083",
		normalMap = "rbxassetid://86254278193932",
		roughnessMap = "rbxassetid://138208845857735",
		metalnessMap = "rbxassetid://83264653619688",
		studsPerTile = 4,
		pattern = "Regular",
		color = { 190, 197, 197 },
		note = "Galvanised corrugated sheet (warehouses, sheds, fences). Not a global Metal override (lamp poles, cars).",
	},
	HC_DryGrass = {
		key = "grass_dry",
		baseMaterial = "Ground",
		override = true,
		colorMap = "rbxassetid://134312871013415",
		normalMap = "rbxassetid://98703175069894",
		roughnessMap = "rbxassetid://139888354024065",
		studsPerTile = 12.14,
		pattern = "Organic",
		color = { 207, 190, 158 },
		note = "Dry grass and dirt for hills and lots (Ground terrain).",
	},
	HC_Grass = {
		key = "grass",
		baseMaterial = "Grass",
		override = true,
		colorMap = "rbxassetid://75296867385240",
		normalMap = "rbxassetid://126844811194480",
		roughnessMap = "rbxassetid://120668241884998",
		studsPerTile = 10,
		pattern = "Organic",
		color = { 146, 161, 109 },
		note = "Mown lawn, slightly dry LA green (parts and terrain).",
	},
	HC_GrassLeafy = {
		key = "grass_leafy",
		baseMaterial = "LeafyGrass",
		override = true,
		colorMap = "rbxassetid://75296867385240",
		normalMap = "rbxassetid://126844811194480",
		roughnessMap = "rbxassetid://120668241884998",
		studsPerTile = 10,
		pattern = "Organic",
		color = { 137, 155, 105 },
		note = "Same maps as HC_Grass for the LeafyGrass terrain material.",
	},
	HC_GravelRoof = {
		key = "gravel_roof",
		baseMaterial = "Pebble",
		override = true,
		colorMap = "rbxassetid://127455141637614",
		normalMap = "rbxassetid://135941849676099",
		roughnessMap = "rbxassetid://82587919945553",
		studsPerTile = 5.36,
		pattern = "Organic",
		color = { 221, 217, 208 },
		note = "Flat-roof gravel ballast (downtown roofs seen from the air).",
	},
	HC_Rock = {
		key = "rock",
		baseMaterial = "Rock",
		override = true,
		colorMap = "rbxassetid://126554197799218",
		normalMap = "rbxassetid://118583349787184",
		roughnessMap = "rbxassetid://82781631164072",
		studsPerTile = 14.29,
		pattern = "Organic",
		color = { 190, 174, 157 },
		note = "Tan fractured rock for cliffs and hill cuts.",
	},
	HC_RockSlate = {
		key = "rock_slate",
		baseMaterial = "Slate",
		override = true,
		colorMap = "rbxassetid://126554197799218",
		normalMap = "rbxassetid://118583349787184",
		roughnessMap = "rbxassetid://82781631164072",
		studsPerTile = 14.29,
		pattern = "Organic",
		color = { 168, 162, 157 },
		note = "Same maps as HC_Rock for the Slate material (cliffs built from Slate).",
	},
	HC_RoofTiles = {
		key = "roof_tiles",
		baseMaterial = "ClayRoofTiles",
		override = true,
		colorMap = "rbxassetid://75493501087088",
		normalMap = "rbxassetid://110333215055924",
		roughnessMap = "rbxassetid://92854047635751",
		studsPerTile = 11.43,
		pattern = "Regular",
		color = { 214, 152, 132 },
		note = "Terracotta barrel tiles (Spanish/Mission).",
	},
	HC_RustyMetal = {
		key = "rusty_metal",
		baseMaterial = "CorrodedMetal",
		override = true,
		colorMap = "rbxassetid://121760156100942",
		normalMap = "rbxassetid://89843136414455",
		roughnessMap = "rbxassetid://74967078007968",
		metalnessMap = "rbxassetid://94311440452052",
		studsPerTile = 7.14,
		pattern = "Organic",
		color = { 180, 163, 155 },
		note = "Galvanised steel with rust bloom (port, industrial props).",
	},
	HC_Sand = {
		key = "sand",
		baseMaterial = "Sand",
		override = true,
		colorMap = "rbxassetid://113487495361728",
		normalMap = "rbxassetid://121798218902378",
		roughnessMap = "rbxassetid://83198137307610",
		studsPerTile = 12.14,
		pattern = "Organic",
		color = { 230, 216, 183 },
		note = "Pale wind-rippled beach sand.",
	},
	HC_Sidewalk = {
		key = "sidewalk",
		baseMaterial = "Pavement",
		override = true,
		colorMap = "rbxassetid://86008103423825",
		normalMap = "rbxassetid://110858632664595",
		roughnessMap = "rbxassetid://134979087290717",
		studsPerTile = 10.71,
		pattern = "Regular",
		color = { 200, 197, 188 },
		note = "US concrete sidewalk: 1.5 m panels with tooled joints and smooth margins (2x2 panels per tile).",
	},
	HC_Stucco = {
		key = "stucco",
		baseMaterial = "Plaster",
		override = true,
		colorMap = "rbxassetid://75989316793017",
		normalMap = "rbxassetid://72451504566057",
		roughnessMap = "rbxassetid://71730022657615",
		studsPerTile = 7.14,
		pattern = "Organic",
		color = { 255, 253, 244 },
		note = "Fine stucco/plaster, near-white: tint per building with Part.Color (pastels, beige).",
	},
	HC_Terrazzo = {
		key = "terrazzo",
		baseMaterial = "Marble",
		override = true,
		colorMap = "rbxassetid://117333312157689",
		normalMap = "rbxassetid://72451453239950",
		roughnessMap = "rbxassetid://112050889134517",
		studsPerTile = 5.71,
		pattern = "Organic",
		color = { 255, 250, 243 },
		note = "White terrazzo for plazas, lobbies, malls and the airport.",
	},
	HC_WindowGlass = {
		key = "window_glass",
		baseMaterial = "SmoothPlastic",
		override = false,
		colorMap = "rbxassetid://92834021315347",
		normalMap = "rbxassetid://129830663186003",
		roughnessMap = "rbxassetid://100876394263649",
		metalnessMap = "rbxassetid://132000550188044",
		studsPerTile = 12.14,
		pattern = "Regular",
		color = { 45, 55, 63 },
		note = "Opaque reflective facade glass (low roughness, slight metalness). Glass has no MaterialService override slot, so this variant sits on SmoothPlastic: set Material=SmoothPlastic + MaterialVariant=HC_WindowGlass.",
	},
	HC_WoodPlanks = {
		key = "wood_planks",
		baseMaterial = "WoodPlanks",
		override = true,
		colorMap = "rbxassetid://78080135923172",
		normalMap = "rbxassetid://93367484573314",
		roughnessMap = "rbxassetid://115688360387359",
		studsPerTile = 6.43,
		pattern = "Regular",
		color = { 158, 140, 122 },
		note = "Weathered boardwalk / pier planks.",
	},
}
Look.Materials = Materials

-- MaterialService.<Material>Name overrides baked into the place (global: every part and terrain voxel).
local Overrides: { [string]: string } = {
	Asphalt = "HC_Asphalt",
	Brick = "HC_BrickRed",
	ClayRoofTiles = "HC_RoofTiles",
	Concrete = "HC_Concrete",
	CorrodedMetal = "HC_RustyMetal",
	Grass = "HC_Grass",
	Ground = "HC_DryGrass",
	LeafyGrass = "HC_GrassLeafy",
	Marble = "HC_Terrazzo",
	Pavement = "HC_Sidewalk",
	Pebble = "HC_GravelRoof",
	Plaster = "HC_Stucco",
	Rock = "HC_Rock",
	Sand = "HC_Sand",
	Slate = "HC_RockSlate",
	WoodPlanks = "HC_WoodPlanks",
}
Look.Overrides = Overrides

-- Recommended Terrain:SetMaterialColor values for the overridden terrain materials (colour contract).
local TerrainColors: { [string]: RGB } = {
	Asphalt = { 103, 103, 106 },
	Brick = { 177, 141, 124 },
	ClayRoofTiles = { 214, 152, 132 },
	Concrete = { 186, 183, 176 },
	CorrodedMetal = { 180, 163, 155 },
	Grass = { 146, 161, 109 },
	Ground = { 207, 190, 158 },
	LeafyGrass = { 137, 155, 105 },
	Marble = { 255, 250, 243 },
	Pavement = { 200, 197, 188 },
	Pebble = { 221, 217, 208 },
	Plaster = { 255, 253, 244 },
	Rock = { 190, 174, 157 },
	Sand = { 230, 216, 183 },
	Slate = { 168, 162, 157 },
	WoodPlanks = { 158, 140, 122 },
}
Look.TerrainColors = TerrainColors

local Decals: { [string]: DecalDef } = {
	arrow_left = {
		image = "rbxassetid://138476430387108",
		width = 512,
		height = 1024,
		note = "White lane arrow (left), 512x1024; Decal on a 4 x 8 stud area, top = direction of travel.",
	},
	arrow_right = {
		image = "rbxassetid://139985337390616",
		width = 512,
		height = 1024,
		note = "White lane arrow (right), 512x1024; Decal on a 4 x 8 stud area, top = direction of travel.",
	},
	arrow_straight = {
		image = "rbxassetid://137814817858017",
		width = 512,
		height = 1024,
		note = "White lane arrow (straight), 512x1024; Decal on a 4 x 8 stud area, top = direction of travel.",
	},
	arrow_straight_left = {
		image = "rbxassetid://81584670920718",
		width = 512,
		height = 1024,
		note = "White lane arrow (straight_left), 512x1024; Decal on a 4 x 8 stud area, top = direction of travel.",
	},
	arrow_straight_right = {
		image = "rbxassetid://73659109134315",
		width = 512,
		height = 1024,
		note = "White lane arrow (straight_right), 512x1024; Decal on a 4 x 8 stud area, top = direction of travel.",
	},
	asphalt_damage_a = {
		image = "rbxassetid://119157152965634",
		width = 1024,
		height = 300,
		note = "Torn/patched asphalt patch (1024x300), Decal on roads to break tiling.",
	},
	asphalt_damage_b = {
		image = "rbxassetid://104288979462464",
		width = 1024,
		height = 280,
		note = "Torn/patched asphalt patch (1024x280), Decal on roads to break tiling.",
	},
	crack_network = {
		image = "rbxassetid://131283354388863",
		width = 1024,
		height = 1024,
		note = "Thin asphalt cracks (tileable). Texture over a road with StudsPerTile ~ 24, or Decal.",
	},
	crosswalk_bars_white = {
		image = "rbxassetid://102831471648000",
		width = 512,
		height = 512,
		studsPerTileU = 4.3,
		studsPerTileV = 10.7,
		note = "Continental crosswalk: one bar + one gap per tile along U, bars run along V. Strip 10.7 studs long (crossing width); StudsPerTileU = 4.3 (0.6 m bars), StudsPerTileV = 10.7.",
	},
	line_white_dash = {
		image = "rbxassetid://138755388050019",
		width = 128,
		height = 1024,
		studsPerTileV = 42.7,
		note = "White lane dash: 10 ft dash + 30 ft gap per tile. StudsPerTileV = 42.7 (period).",
	},
	line_white_solid = {
		image = "rbxassetid://77511707989575",
		width = 128,
		height = 1024,
		studsPerTileV = 12,
		note = "Solid white line. Texture on the top face of a 0.45-stud-wide marking strip; StudsPerTileV ~ 12.",
	},
	line_yellow_dash = {
		image = "rbxassetid://136667409302116",
		width = 128,
		height = 1024,
		studsPerTileV = 42.7,
		note = "Yellow centre dash (same period).",
	},
	line_yellow_double = {
		image = "rbxassetid://106993168199118",
		width = 255,
		height = 1024,
		studsPerTileV = 12,
		note = "Double solid yellow centre line: two 0.45 lines with a 0.45 gap (strip 1.35 studs wide).",
	},
	line_yellow_solid = {
		image = "rbxassetid://121731869713190",
		width = 128,
		height = 1024,
		studsPerTileV = 12,
		note = "Solid yellow line (same use).",
	},
	manhole_round = {
		image = "rbxassetid://79792433990918",
		width = 512,
		height = 512,
		note = "Round cast-iron manhole cover (Decal, ~2.6 x 2.6 studs).",
	},
	oil_stain_a = {
		image = "rbxassetid://127073388700985",
		width = 512,
		height = 512,
		note = "Oil/tyre stain for parking spots, junction stop zones, driveways (Decal ~6 x 6 studs).",
	},
	oil_stain_b = {
		image = "rbxassetid://92842659354972",
		width = 512,
		height = 512,
		note = "Oil/tyre stain for parking spots, junction stop zones, driveways (Decal ~6 x 6 studs).",
	},
	stop_line_white = {
		image = "rbxassetid://106240517825528",
		width = 1024,
		height = 256,
		studsPerTileU = 12,
		note = "Stop bar (full bleed, tile along U). Strip 1.6 studs deep across the lanes.",
	},
	tar_snakes = {
		image = "rbxassetid://116194143749346",
		width = 1024,
		height = 1024,
		note = "Crack-sealant 'tar snakes' (tileable), very LA. Texture with StudsPerTile ~ 30.",
	},
	wall_grime_streaks = {
		image = "rbxassetid://104901365216375",
		width = 512,
		height = 1024,
		note = "Rain-streak grime under ledges/windows/AC units (Decal on walls, top edge at the ledge).",
	},
}
Look.Decals = Decals

local Skies: { [string]: SkyDef } = {
	blue = {
		faces = {
			Bk = "rbxassetid://88562914711616",
			Dn = "rbxassetid://117299015005250",
			Ft = "rbxassetid://122246640713360",
			Lf = "rbxassetid://79579945003167",
			Rt = "rbxassetid://96569696092312",
			Up = "rbxassetid://128421368724949",
		},
		glowAzimuth = 32.7,
		followSun = true,
		starCount = 500,
		hazeColor = { 120, 112, 122 },
	},
	day = {
		faces = {
			Bk = "rbxassetid://114889706466400",
			Dn = "rbxassetid://126778055421344",
			Ft = "rbxassetid://83431819292615",
			Lf = "rbxassetid://85390262765714",
			Rt = "rbxassetid://79010093641079",
			Up = "rbxassetid://80903012956799",
		},
		glowAzimuth = 34.1,
		sunAzimuth = 34.1,
		sunElevation = 48.2,
		followSun = true,
		starCount = 0,
		hazeColor = { 164, 166, 171 },
	},
	golden = {
		faces = {
			Bk = "rbxassetid://114964142574668",
			Dn = "rbxassetid://108812301015843",
			Ft = "rbxassetid://107623397205280",
			Lf = "rbxassetid://114739838025939",
			Rt = "rbxassetid://117183852251891",
			Up = "rbxassetid://115058423870433",
		},
		glowAzimuth = 38.3,
		sunAzimuth = 38.3,
		sunElevation = 8.1,
		followSun = true,
		starCount = 0,
		hazeColor = { 171, 163, 157 },
	},
	night = {
		faces = {
			Bk = "rbxassetid://90717854341912",
			Dn = "rbxassetid://71763556424955",
			Ft = "rbxassetid://98461351795375",
			Lf = "rbxassetid://79552634608475",
			Rt = "rbxassetid://79230279114248",
			Up = "rbxassetid://80685099604519",
		},
		glowAzimuth = 35.5,
		followSun = false,
		starCount = 400,
		hazeColor = { 53, 54, 56 },
	},
}
Look.Skies = Skies

---------------------------------------------------------------------------------------------------------------------
-- END GENERATED
---------------------------------------------------------------------------------------------------------------------

return Look
