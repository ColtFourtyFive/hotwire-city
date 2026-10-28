--!strict
-- Config/Look: the v2 "look" (docs/v2/PLAN.md decision 3, research/lighting_lab.md rounds 1 + 2,
-- research/gta_realism_gap.md).
--
-- * Day cycle, engine clock mapping, lighting presets, sky schedule and night thresholds for LightingService (server).
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
	glowAzimuth: number, -- degrees, 0 = -Z, 90 = +X (azimuth of the sky's sun glow / brightest region before rotation)
	horizonGlowAzimuth: number, -- brightest part of the 0..6 deg band (a night sky's city glow)
	sunAzimuth: number?,
	sunElevation: number?,
	followSun: boolean, -- keep the glow on the engine sun while up; else park horizonGlow on SkyStyle.fixedGlowAzimuth
	starCount: number,
	celestialBodiesShown: boolean, -- engine sun + moon discs
	clouds: number, -- multiplier on the preset's volumetric Clouds.Cover while this sky is up
	hazeColor: RGB,
}

export type WindowParams = {
	lit: boolean, -- this window is one of the share that lights up at night
	warm: boolean,
	level: number, -- 0..1: where this window sits in a brightness / factor range
	brightness: number, -- Look.Windows.brightness at `level` (Neon colour multiplier)
	threshold: number, -- NightFactor at which it switches on (and back off at dawn)
}

local Look = {}

---------------------------------------------------------------------------------------------------------------------
-- Day cycle
---------------------------------------------------------------------------------------------------------------------

Look.Cycle = {
	lengthSeconds = 24 * 60, -- one full 24 h game day = 24 real minutes
	startHour = 11.0, -- new servers start late morning (first impressions in daylight)
	-- seconds between Lighting.ClockTime writes (replicated) and sky-yaw updates: at 4 Hz the sun steps ~0.06 deg,
	-- so a 50-stud building's golden-hour shadow tip moves ~1 stud per step instead of ~4 at 1 Hz
	clockInterval = 0.25,
	envInterval = 1, -- seconds between look evaluations (Atmosphere, post effects, clouds)
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

-- The engine sun, MEASURED in the real engine (Open Cloud Luau Execution, Lighting:GetSunDirection at
-- GeographicLatitude 0 / 23.5 / 34 / 41.733 x 28 ClockTimes; tools/look/sun_probe.py, result in
-- tools/look/sun_probe_result.json). Roblox moves the sun on a circle about the horizontal Z axis:
--   dir = (cos(phi) * cos(theta), cos(phi) * sin(theta), sin(phi)),  phi = latitude - 23.5 deg,
--   theta = 15 deg * (ClockTime - 6)
-- so it rises at 06:00 near +X, sets at 18:00 near -X at EVERY latitude (12 h day), and at latitude 34 culminates at
-- 79.5 deg elevation toward +Z. The moon is exactly opposite the sun. LightingService.sunDirectionAt implements this
-- (unit-tested against the probe); at runtime the engine's own GetSunDirection is used and checked against it.
Look.Sun = {
	latitude = 34, -- Lighting.GeographicLatitude (Los Angeles)
	tiltOffset = 23.5, -- phi = latitude - tiltOffset
	rise = 6.0, -- elevation 0 (measured: -0.74 deg at 5.95, +0.74 at 6.05)
	set = 18.0, -- elevation 0 (measured: +1.47 deg at 17.9, -1.47 at 18.1)
}

-- Engine clock (lab round 2, job 0007 S2): the engine blacks out ANY skybox once its sun is well below the horizon:
-- pure black at ClockTime 22.5, near-black and purple at 18.7 (sun -10 deg), while the same night sky at 14.2 shows
-- moonlit clouds and a warm city glow. So the GAME time of day (the 24-minute cycle, Workspace "TimeOfDay",
-- NightFactor, street lights, windows) is decoupled from Lighting.ClockTime:
--   * by day the engine clock IS the game clock (from morningHold + ease / 2 to eveningHold - ease / 2: 6.45 h to
--     17.55 h with the values below);
--   * from the late golden hour it eases into eveningHold (C1: the sun slows smoothly to a stop, never a visible halt)
--     and stays there through the first half of the night;
--   * at jumpHour (full night, NightFactor 1, under a Look.SkySwap exposure dip) it jumps to morningHold in ONE write,
--     so the engine never renders a deep-night sun in between (both holds put the sun at -3 deg);
--   * it eases back onto the game clock after dawn.
-- Night darkness is faked by the night presets (ExposureCompensation, Ambient / OutdoorAmbient, a cool desaturated
-- ColorCorrection) and the night HDRI stays visible. Live override for labs: Workspace "EngineClockOverride" (hours).
Look.EngineClock = {
	eveningHold = 18.2, -- engine sun -3.0 deg toward -X (west); lab rule: hold at ~18.0-18.3
	morningHold = 5.8, -- engine sun -3.0 deg toward +X (east); lab rule: ~5.7-6.0
	ease = 1.3, -- game hours over which the engine clock eases into / out of a hold
	jumpHour = 0, -- game hour of the evening -> morning hold jump (midnight: NightFactor 1 on both sides)
	minElevation = -5, -- deg: the engine sun never goes below this (tested over the whole cycle)
}

-- NightFactor (Workspace attribute, 0 = day .. 1 = night; smoothstep ramps over the GAME hour) drives lit windows and
-- street lights.
--
-- windowEmissive: guidance + data for the building package's lit windows (lab round 2 S6: Neon at colour x 0.55-1.0
-- under the night Bloom turned ribbon windows into glowing slabs and lit whole towers as glowing columns):
--   * light individual window CELLS (one part / one grid cell per window), never a whole facade, ribbon or tower part;
--   * pick the lit cells at random (litFraction; LightingService.windowParams gives a deterministic per-position pick,
--     the same one the LitWindow system uses), warm / cool 70 / 30 (reads correctly in the lab);
--   * a dim surface that cannot bloom: `material` (SmoothPlastic, or Glass) with colour = warm / cool x factor, faded
--     in by NightFactor over fadeIn (LightingService.windowEmissiveColor). These materials are not self-lit, so a lit
--     cell never blooms into a slab: it reads as a warm / cool panel among dark glass, brightened by the street lamps;
--   * Neon only for small cells (a panel behind glass, <= maxNeonArea studs^2 face) and only at neonFactor, which keeps
--     the cell under the night Bloom threshold (Look.Presets.night.bloom). LightingService applies the same rule to
--     the parts it lights ("LitWindow" + adopted v1 glass): bigger parts get `material`, never Neon.
local WindowEmissive = {
	material = "SmoothPlastic",
	litFraction = 0.4, -- lab S6: ~35 % lit "is fine"
	warmShare = 0.7,
	warm = { 255, 196, 136 },
	cool = { 214, 226, 255 },
	factor = { 0.75, 1.0 }, -- colour multiplier range at full night for `material` (not self-lit: needs a bright colour)
	neonFactor = { 0.25, 0.4 }, -- colour multiplier range if a small cell is Neon (lab S6: 0.25-0.4, not 0.55-1.0)
	fadeIn = { 0.15, 0.9 }, -- NightFactor range over which a lit cell's colour fades in from its day colour
	maxNeonArea = 80, -- studs^2 (largest face): a 6 x 12 window cell is 72; facade bands / towers are far bigger
}

Look.Night = {
	duskStart = 17.9,
	duskFull = 19.4,
	dawnFull = 4.9,
	dawnEnd = 6.3,
	lightsOn = 0.5, -- v1 contract (StreetLight / NightGlow tags, Lighting "IsNight") switches here ...
	hysteresis = 0.05, -- ... with this much hysteresis
	windowEmissive = WindowEmissive,
}

-- Hard limits from lighting lab round 1 (aerial views drown above ~0.35 density; the brown wall was Haze 2.05).
Look.Caps = {
	densityMax = 0.30,
	hazeMax = 1.2,
}

-- LOCKED by lab round 2 (job 0007 S1) for the DAY preset: Offset made no visible difference at Density 0.27 (captures
-- at Offset 0 and 1.0 were pixel-identical), and Haze 0.8 + Offset 0.25 was the best pair (hazy but readable,
-- white-grey horizon; Haze 1.2 greys the lower sky). Do not tune these again. The blue-hour and night presets keep the
-- same Offset and their own (lower) Haze. The golden presets have their own Atmosphere (Look.GoldenAtmosphere).
Look.AtmosphereLock = {
	offset = 0.25,
	haze = 0.8,
}

-- Golden hour Atmosphere (job 0018 vibe audit, docs/v2/VIBE_ROUTING.md row 13): from the low south-west aerial at
-- 17.6 a flat grey haze wall swallowed the city beyond ~600 studs. Two causes:
--   * draw distance: at client quality Automatic nothing past a few hundred studs is drawn (job 0011: a flat grey frame
--     even at Density 0.01; the whole city at Level 21). The Atmosphere cannot fix that (SLIM / StreamingMesh can, the
--     streaming wave owns it), but it decides what the empty far band LOOKS like: with the camera facing away from the
--     low sun that band is the Decay hue, and a dull (126, 126, 134) Decay under Haze 0.8 read as a smog wall;
--   * the haze itself: Density 0.18 + Haze 0.8 was the day's milky noon haze, held into the low sun.
-- GTA V's golden hour is the opposite: a warm, clear long view, gentle aerial perspective, a warm glow round the sun.
-- So, for both golden presets: thinner fog (Density 0.13, job 0011's "crisp but gentle" band), a thinner horizon band
-- (Haze 0.5, kept > 0 because Glare needs it), Offset 0.4 (distant towers silhouette against the sky instead of fading
-- into it; no visible effect was measured at Density 0.27, job 0012 sweeps it), a strong warm Glare round the low sun
-- (0.8 / 0.7), a light warm-cream Color on the sun side, and a light rose-grey Decay away from it: aerial perspective
-- that recedes warm-pale, never grey. Still no sepia (job 0009): the colours stay light and low-chroma, the grade keeps
-- its faint warm tint and no saturation boost, and the warmth comes from the engine's low sun on the facades.
Look.GoldenAtmosphere = {
	offset = 0.4,
	haze = 0.5,
}

-- Atmosphere.Density: THE single fog tunable of each preset (the presets below read it from here). Job 0009 (real
-- engine, v30): at 0.27 everything beyond ~350-400 studs became a flat grey wall from the overview camera and hid
-- downtown, on a city ~3 km across. Lowered so a skyline 1,500-2,500 studs away stays readable with gentle aerial
-- perspective; Offset 0.25 / Haze 0.8 stay locked (above). Job 0011 sweeps 0.12 / 0.16 / 0.2 / 0.27 at noon from the
-- overview cameras (Workspace "AtmosphereDensityOverride") and picks the final values. Night stays the thinnest: the
-- far city lights and the night sky's horizon glow must read through it. Golden: 0.13 since job 0018 (row 13, see
-- Look.GoldenAtmosphere; job 0011 kept 0.18 at Level 21, the owner saw a haze wall).
Look.AtmosphereDensity = {
	day = 0.16,
	goldenMorning = 0.13,
	goldenEvening = 0.13,
	blueMorning = 0.16,
	blueEvening = 0.16,
	night = 0.12,
}

-- offset = nil keeps each preset's own Atmosphere.Offset (the lock above). Live overrides in Play mode: see "Live
-- overrides" below (TimeOfDayLock, AtmosphereOffsetOverride, AtmosphereDensityOverride, ExposureOverride, ...).
export type Tuning = { offset: number?, hazeScale: number, densityScale: number }
Look.Tuning = { hazeScale = 1, densityScale = 1 } :: Tuning

---------------------------------------------------------------------------------------------------------------------
-- Presets (lab-calibrated: day_clear is the base; neutral warm-grey haze by day, desaturated navy-grey at night)
--
-- Blue hour and night are FAKED (Look.EngineClock): the engine sun is held at -3 deg. Job 0009 (real engine, v30)
-- measured what the engine makes of that: at the old night (Exposure -0.3, Brightness 0.4, OutdoorAmbient (40, 46, 60))
-- the street was almost black and the overview completely black, while a diagnostic at Exposure +2 / Brightness 2
-- showed the night HDRI and a readable city: the engine already darkens a -3 deg world heavily, so the presets must
-- LIFT it ~2 stops (positive ExposureCompensation, a moonlight-level key, a brighter cool OutdoorAmbient), not darken
-- it further. "Still clearly night" comes from the low key light, the cool desaturated grade, the dark navy haze and
-- the night sky. The engine also tints that held world and its sky reddish-brown, so the night grade is a clear blue
-- tint (Look.Presets.night.colorCorrection; job 0011 kept Exposure +0.8 and tint (212, 226, 255)). The blue hour sits
-- between golden and night and is never darker than the night. Haze / decay / cloud colours are neutral blue-grey with
-- red never above green (no magenta, tested). Job 0011 swept night exposure and tint ("ExposureOverride",
-- "TintOverride").
--
-- The night / dawn / dusk sky faces are built AGAINST these presets (tools/look/procedural_sky.py reads the exposure
-- and ColorCorrection at its reference hours and pre-compensates the engine's sky cast for them): after changing the
-- night or blue-hour exposure or grade, re-run it (and re-upload), or the sky drifts from its target colours.
--
-- Blue hour exposure (+1.0, above the night's +0.8; was +0.6 until job 0018): at the held sun the engine renders the
-- sky ~20x darker than its face, with a hard ceiling (a white face renders at most ~(70, 45, 55) at the horizon,
-- research/lighting_lab.md round 5), so at +0.6 the dusk sky was darker than the NIGHT sky and its warm-to-blue
-- gradient could not read (job 0011: "blue hour reads as night"). The sky's ceiling scales as 2^(1.2 * EV); the city
-- gets ~0.4 EV brighter, which is what job 0011 saw at night +1.2 ("reads as dusk / early night"): right for dusk.
--
-- Golden hour (job 0009): the old warm Atmosphere colour + warm tint + saturation boost read sepia / brown (dusty,
-- smoggy) on top of the engine's own orange low sun. The grade is now warm-but-neutral: a faint warm tint, no
-- saturation boost; the warmth comes from the engine's low sun itself. Its Atmosphere is thinner and clearer since
-- job 0018 (Look.GoldenAtmosphere): light warm-cream haze toward the sun, light rose-grey away from it.
---------------------------------------------------------------------------------------------------------------------

local LOCK = Look.AtmosphereLock
local GOLDEN = Look.GoldenAtmosphere
local DENSITY = Look.AtmosphereDensity

local Presets: { [string]: Preset } = {
	day = {
		brightness = 3.0,
		exposure = 0,
		ambient = { 14, 14, 16 },
		outdoorAmbient = { 120, 124, 132 },
		shadowSoftness = 0.12,
		atmosphere = {
			density = DENSITY.day,
			offset = LOCK.offset,
			haze = LOCK.haze,
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
		ambient = { 15, 14, 14 },
		outdoorAmbient = { 122, 119, 116 },
		shadowSoftness = 0.16,
		atmosphere = {
			density = DENSITY.goldenMorning,
			offset = GOLDEN.offset,
			haze = GOLDEN.haze,
			glare = 0.7,
			color = { 224, 214, 198 }, -- a touch fresher than the evening
			decay = { 146, 142, 146 },
		},
		bloom = { intensity = 0.5, size = 26, threshold = 1.6 },
		colorCorrection = { brightness = 0, contrast = 0.1, saturation = 0, tint = { 255, 251, 245 } },
		sunRays = { intensity = 0.08, spread = 0.65 },
		clouds = { cover = 0.3, density = 0.42, color = { 250, 240, 230 } },
	},
	goldenEvening = {
		brightness = 3.0,
		exposure = 0.05,
		ambient = { 16, 14, 13 },
		outdoorAmbient = { 126, 119, 114 },
		shadowSoftness = 0.18,
		atmosphere = {
			density = DENSITY.goldenEvening,
			offset = GOLDEN.offset,
			haze = GOLDEN.haze,
			glare = 0.8, -- the warm glow round the low sun (needs Haze > 0)
			color = { 228, 212, 192 }, -- light warm cream toward the sun
			decay = { 152, 144, 142 }, -- light rose-grey away from it (job 0018: (126, 126, 134) read as a smog wall)
		},
		bloom = { intensity = 0.55, size = 28, threshold = 1.55 },
		colorCorrection = { brightness = 0, contrast = 0.1, saturation = 0, tint = { 255, 250, 242 } },
		sunRays = { intensity = 0.1, spread = 0.65 },
		clouds = { cover = 0.34, density = 0.45, color = { 252, 236, 220 } },
	},
	blueMorning = {
		brightness = 1.5,
		exposure = 1.0, -- above the night's: the twilight sky needs the headroom (see the note above)
		ambient = { 12, 13, 18 },
		outdoorAmbient = { 82, 92, 112 },
		shadowSoftness = 0.3,
		atmosphere = {
			density = DENSITY.blueMorning,
			offset = LOCK.offset,
			haze = 0.7,
			glare = 0.1,
			color = { 116, 124, 138 },
			decay = { 66, 72, 86 },
		},
		bloom = { intensity = 0.6, size = 28, threshold = 1.4 },
		colorCorrection = { brightness = 0, contrast = 0.12, saturation = -0.06, tint = { 232, 240, 255 } },
		sunRays = { intensity = 0.02, spread = 0.6 },
		clouds = { cover = 0.3, density = 0.4, color = { 124, 130, 142 } },
	},
	blueEvening = {
		brightness = 1.4,
		exposure = 1.0,
		ambient = { 12, 13, 18 },
		outdoorAmbient = { 84, 92, 110 },
		shadowSoftness = 0.3,
		atmosphere = {
			density = DENSITY.blueEvening,
			offset = LOCK.offset,
			haze = 0.7,
			glare = 0.1,
			color = { 120, 124, 134 },
			decay = { 68, 72, 84 },
		},
		bloom = { intensity = 0.6, size = 28, threshold = 1.4 },
		colorCorrection = { brightness = 0, contrast = 0.12, saturation = -0.06, tint = { 232, 240, 255 } },
		sunRays = { intensity = 0.02, spread = 0.6 },
		clouds = { cover = 0.32, density = 0.42, color = { 120, 124, 136 } },
	},
	night = {
		-- job 0009: Brightness 0.4 / Exposure -0.3 rendered nearly black (the overview completely black); the report's
		-- starting point is Brightness ~1.2, Exposure +0.6..+1.0 and an OutdoorAmbient lift (~2 stops in all)
		brightness = 1.2, -- a moonlight-level key from the held engine sun / low moon: faint long shadows
		exposure = 0.8,
		ambient = { 12, 14, 20 },
		outdoorAmbient = { 60, 70, 92 },
		shadowSoftness = 0.45,
		atmosphere = {
			density = DENSITY.night,
			offset = LOCK.offset,
			haze = 0.35, -- thin: the night sky's stars and city-glow band stay visible above the haze
			glare = 0,
			color = { 40, 43, 50 },
			decay = { 20, 22, 27 },
		},
		-- lab round 2 S6 (windows bloomed into slabs at 1.05 / 1.0); threshold up a little more for the +0.8 EV lift
		bloom = { intensity = 0.6, size = 26, threshold = 1.4 },
		-- a clear blue tint + desaturation: cools the engine's reddish-brown cast on the held world (job 0009) while warm
		-- lamps and windows stay warm. It cannot fix the sky alone (job 0011): the night sky faces are pre-compensated
		-- for this grade instead (Look.SkySchedule)
		colorCorrection = { brightness = 0, contrast = 0.12, saturation = -0.2, tint = { 212, 226, 255 } },
		sunRays = { intensity = 0, spread = 0.5 },
		clouds = { cover = 0.3, density = 0.4, color = { 48, 52, 62 } },
	},
}
Look.Presets = Presets

-- Keyframes in GAME hours (sorted, 0 and 24 are the same preset so midnight wraps). Between keys LightingService
-- smoothsteps. Golden keys sit at sun elevation ~10 deg and the day plateau starts/ends at ~38-42 deg (mirror images
-- around noon: 6.7 / 17.3 and 8.6 / 15.4). At the blue keys (5.6 / 18.6) the engine sun is already below the horizon
-- (Look.EngineClock puts the engine sunrise / sunset at game ~5.87 / ~18.13).
Look.Keys = {
	{ hour = 0, preset = "night" },
	{ hour = 4.4, preset = "night" },
	{ hour = 5.6, preset = "blueMorning" },
	{ hour = 6.7, preset = "goldenMorning" },
	{ hour = 8.6, preset = "day" },
	{ hour = 15.4, preset = "day" },
	{ hour = 17.3, preset = "goldenEvening" },
	{ hour = 18.6, preset = "blueEvening" },
	{ hour = 19.9, preset = "night" },
	{ hour = 24, preset = "night" },
}

---------------------------------------------------------------------------------------------------------------------
-- Sky schedule (GAME hours; each entry holds until the next, wraps at 24). Five sky swaps a day, all with the ENGINE
-- sun below the horizon, each under a short exposure dip (Look.SkySwap; `dip` overrides its depth for one entry):
--   night -> nightLate at midnight, in the SAME tick as the engine-clock jump (Look.EngineClock.jumpHour) and under
--   its dip; nightLate -> dawn in the dark, dawn -> day just before the engine sunrise, day -> blue (dusk) just after
--   the engine sunset, blue -> night in the dark.
-- Why two night skies (job 0018 row 12): the engine's cast on the sky depends on where the held sun is (west until the
-- jump, east after it; the sun side is cast less red). One texture for both holds could only be right on average and
-- changed colour at the jump; `night` is pre-compensated for the evening hold and `nightLate` for the morning hold, so
-- each is exact for the clock it is seen under, and the jump + swap is one masked step. nightLate is also the late
-- night: a slightly deeper zenith, a fainter city glow, a few more stars.
--
-- The night, dawn and dusk skies are procedural (tools/look/procedural_sky.py), not HDRIs (backlog 14,
-- research/lighting_lab.md round 5): the engine renders a skybox at the held -3 deg sun ~20x darker than the face and
-- strongly red (R/G 2.8, measured on two real-engine shots), which is what turned the navy-grey night HDRI
-- reddish-brown (jobs 0009 / 0011). Their faces are the inverse of that measured transfer applied to the look we want
-- on screen at the preset's grade: a deep blue night needs a pale cyan-blue face. The twilight <-> night swaps change
-- the most (the sun-side glow goes, the stars come out), so they get a deeper dip; the dusk and dawn zeniths match the
-- night's, so the rest of the dome does not step.
--
-- No golden sky (decision after lab round 2 S3). The day <-> golden swap popped visibly: thin warm wisps <-> white
-- cumulus, seen straight through a Haze 1.2 bump, and the facades shifted with it because the sky feeds ambient and
-- specular light. A Sky cannot cross-fade, and that swap cannot be hidden: it has to happen with the sun UP (the
-- golden HDRI paints its sun glow at 8 deg, so it must be up during the golden hour and must not sit under a high
-- sun). Moving it to the horizon would leave golden up for a minute of twilight, add two more swaps and put an 8 deg
-- glow over a set sun. So the day sky stays up from sunrise to sunset; the golden HOUR still comes from the presets
-- (warm low key light, warm Atmosphere colour + glare tinting the horizon band, warm grade) under the milky,
-- desaturated day dome. The golden faces stay in Look.Skies (generated) but are not scheduled or preloaded.
---------------------------------------------------------------------------------------------------------------------

export type SkySwapEntry = {
	hour: number, -- GAME hour the sky comes up
	sky: string, -- a Look.Skies name
	dip: number?, -- this swap's ExposureCompensation dip in EV (default Look.SkySwap.exposureDip)
}

Look.SkySchedule = {
	{ hour = 0, sky = "nightLate", dip = 0.3 }, -- = EngineClock.jumpHour: west hold -> east hold in the same tick
	{ hour = 5.0, sky = "dawn", dip = 0.35 }, -- NightFactor 0.99; engine sun held at -3 deg (east)
	{ hour = 5.65, sky = "day" }, -- engine ClockTime 5.90: sun -1.5 deg, just before the engine sunrise
	{ hour = 18.35, sky = "blue" }, -- engine ClockTime 18.10: sun -1.5 deg, just after the engine sunset
	{ hour = 19.5, sky = "night", dip = 0.35 }, -- NightFactor 1; engine sun held at -3 deg (west)
} :: { SkySwapEntry }

-- Mask for sky swaps and the engine-clock jump (Look.EngineClock.jumpHour): ExposureCompensation dips by up to
-- exposureDip EV (gaussian over +-width game hours, ~20 real seconds at dusk), so the frame is slightly darker while
-- the sky (and the sky-fed ambient) changes; a schedule entry's `dip` sets its own depth. The old haze bump is gone:
-- lab round 2 saw the swap straight through it, and the day Haze is locked (Look.AtmosphereLock). Volumetric cloud
-- cover also blends over +-width around a swap.
Look.SkySwap = {
	exposureDip = 0.2,
	width = 0.25,
}

Look.SkyStyle = {
	sunAngularSize = 10, -- real sun ~0.5 deg; 21 default reads storybook
	-- Job 0009: a large pale moon disc sat on the horizon opposite the golden-hour sun, next to a bright cumulus day
	-- sky. The engine moon is now small and HIDDEN (Sky.MoonAngularSize 0) whenever the engine sun is above
	-- moonHideAboveElevation (LightingService.moonSizeAt); it only shows at twilight under the dusk / dawn skies (the
	-- night skies hide all celestial bodies anyway). Live override: Workspace "MoonSizeOverride" (degrees, 0 hides).
	moonAngularSize = 1.5,
	moonHideAboveElevation = -2, -- deg, engine sun; below both day <-> blue swaps (-1.5): never under the day sky
	-- SkyboxOrientation.Y = yawSign * (sky glow azimuth - target azimuth), the CFrame.Angles(0, y, 0) convention.
	-- CONFIRMED in the engine (lab round 2 S0, job 0007): yaw 0 shows Ft, yaw 90 shows Lf, nothing mirrored.
	yawSign = 1,
	-- A following sky turns at most this fast (deg per real second; reads as cloud drift). Near noon the engine sun's
	-- azimuth sweeps ~70-80 deg per game hour (~1.2 deg/s: it passes 10.5 deg from the zenith), which would visibly
	-- spin the painted clouds, so the day sky lags there and catches up in the afternoon. Swaps snap.
	maxYawRate = 0.3,
	yawEpsilon = 0.02, -- degrees; SkyboxOrientation is only rewritten past this (steps are ~0.075 deg at 4 Hz)
	-- Skies that do not follow the sun (night) park their horizon glow (the warm city glow) here: east / +X, inland. The Palmera Beach ocean horizon is the -X side (WorldLayout coast), and should stay dark.
	fixedGlowAzimuth = 90,
}

-- Wet-road look at night: swap the Asphalt override to HC_AsphaltWet (darker colour map, low roughness, puddles) once
-- NightFactor reaches nightFactor (hysteresis Look.Night.hysteresis). Off until lab round 2 judges it.
Look.WetStreets = {
	enabled = false,
	nightFactor = 0.6,
	dry = "HC_Asphalt",
	wet = "HC_AsphaltWet",
}

-- Lit windows at night (lighting lab finding 5, gta_realism_gap: 30-60 % lit, warm and cool mixed, on through dusk).
-- Parts tagged "LitWindow" (the v2 contract for MapBuilder v2 / the building kit: an emissive panel 0.5-1 stud behind
-- the glass) and, while v1 buildings exist, "NightGlow" parts whose DayMaterial is Glass. A deterministic hash of each
-- part's position picks whether it lights at all, warm or cool, its brightness and its own NightFactor threshold, so
-- the city fills in over dusk instead of every window switching at once. Unlit or daytime: the part's DayColor /
-- DayMaterial attributes (captured on first sight when missing). "LitWindowColor" (Color3) overrides the colour.
-- Dim, per lab round 2 S6 (Look.Night.windowEmissive): small cells light as Neon at colour x 0.25-0.4 (under the
-- night Bloom threshold); a part whose largest face exceeds maxNeonArea (a v1 facade band, ribbon or whole tower)
-- lights as facadeMaterial at facadeBrightness instead, so it can never glow as a slab or a column.
Look.Windows = {
	tag = "LitWindow",
	adoptGlassNightGlow = true,
	share = WindowEmissive.litFraction, -- of windows that light up at all
	warmShare = WindowEmissive.warmShare,
	warm = WindowEmissive.warm,
	cool = WindowEmissive.cool,
	brightness = WindowEmissive.neonFactor, -- Neon colour multiplier range (Neon glow scales with the colour)
	onBand = { 0.15, 0.9 }, -- NightFactor range the per-window thresholds spread over
	material = "Neon",
	maxNeonArea = WindowEmissive.maxNeonArea,
	facadeMaterial = WindowEmissive.material,
	facadeBrightness = WindowEmissive.factor,
	batch = 200, -- windows switched per frame
}

-- Terrain water (the v1 tropical-pool cyan was the largest surface in every skyline shot). Applied by LightingService
-- after MapBuilder; Config/Look owns it (gta_realism_gap 2.10: deep green-blue, fully reflective).
Look.Water = {
	color = { 22, 72, 84 },
	transparency = 0.25,
	reflectance = 1,
	waveSize = 0.15,
	waveSpeed = 10,
}

-- Live overrides for Play-mode tuning / lab rounds (Workspace attributes, set on the SERVER; LightingService reads them
-- every tick / every look step, ~1 s). Unset in production, where they cost nothing:
--   "TimeOfDayLock" (game hours)  "EngineClockOverride" (engine ClockTime, e.g. to compare holds 18.0 .. 18.3)
--   "AtmosphereOffsetOverride" (number)  "CloudsOverride" (multiplier on the cloud cover)
-- Sweep overrides (job 0011; each REPLACES one value of the interpolated look, after the caps and the swap dip, so the
-- frame shows exactly the value set):
--   "AtmosphereDensityOverride" (number)  "AtmosphereHazeOverride" (number)  "ExposureOverride" (EV)
--   "BrightnessOverride" (number)  "OutdoorAmbientOverride" (Color3)  "TintOverride" (Color3, ColorCorrection)
--   "SaturationOverride" (number, ColorCorrection)  "MoonSizeOverride" (degrees, 0 hides the engine moon)
--   "SkyOverride" (string, a Look.Skies name: that sky instead of Look.SkySchedule, e.g. "night" at 19.0 to compare
--   it with the dusk sky in job 0012; yaw / stars / sun-moon discs follow that sky's own settings)
--   "AtmosphereGlareOverride" (number)  "AtmosphereColorOverride" / "AtmosphereDecayOverride" (Color3): the golden
--   hour sweep of job 0012 (Look.GoldenAtmosphere)

---------------------------------------------------------------------------------------------------------------------
-- BEGIN GENERATED (tools/look/gen_project.py) - do not edit by hand
---------------------------------------------------------------------------------------------------------------------

local Materials: { [string]: MaterialDef } = {
	HC_Asphalt = {
		key = "asphalt",
		baseMaterial = "Asphalt",
		override = true,
		colorMap = "rbxassetid://112223103107268",
		normalMap = "rbxassetid://82395533791334",
		roughnessMap = "rbxassetid://121272890641417",
		studsPerTile = 16.07,
		pattern = "Organic",
		color = { 104, 104, 107 },
		note = "Road asphalt for avenues and streets (fine dark aggregate, soft tone patches; 16-stud tiles). Add the tar_snakes / crack_network decals as Textures on top (24-30 studs per tile) to break it up further.",
	},
	HC_AsphaltWet = {
		key = "asphalt_wet",
		baseMaterial = "Asphalt",
		override = false,
		colorMap = "rbxassetid://79911827799879",
		normalMap = "rbxassetid://82395533791334",
		roughnessMap = "rbxassetid://117195630363033",
		studsPerTile = 16.07,
		pattern = "Organic",
		color = { 104, 104, 107 },
		note = "Night/rain swap for HC_Asphalt: same normal, darker wet colour map (puddles darker still) and a wet roughness map; uses HC_Asphalt's Part.Color, so swapping the override darkens and wets the roads.",
	},
	HC_AsphaltWorn = {
		key = "asphalt_worn",
		baseMaterial = "Asphalt",
		override = false,
		colorMap = "rbxassetid://129122867914138",
		normalMap = "rbxassetid://82636250794801",
		roughnessMap = "rbxassetid://89336615364349",
		studsPerTile = 14.29,
		pattern = "Organic",
		color = { 179, 177, 171 },
		note = "Worn coarse asphalt for older streets, alleys and lots (baked cracks removed: add crack_network).",
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
		studsPerTile = 32.14,
		pattern = "Organic",
		color = { 190, 174, 157 },
		note = "Tan fractured rock for cliffs and hill cuts (32-stud tiles: big fracture shapes must not repeat up a cliff face).",
	},
	HC_RockSlate = {
		key = "rock_slate",
		baseMaterial = "Slate",
		override = true,
		colorMap = "rbxassetid://91210253580661",
		normalMap = "rbxassetid://78165355072262",
		roughnessMap = "rbxassetid://71227972729969",
		studsPerTile = 21.43,
		pattern = "Organic",
		color = { 202, 200, 195 },
		note = "Grey layered cliff rock for the Slate material (distinct from the tan HC_Rock).",
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
		roughnessMap = "rbxassetid://72033955747974",
		metalnessMap = "rbxassetid://92418495410749",
		studsPerTile = 12.14,
		pattern = "Regular",
		color = { 118, 132, 147 },
		note = "Opaque mirror-coated facade glass: metalness ~1 + roughness ~0.06, so Part.Color is the reflection tint and the facade shows a lightly blue-grey tinted sky (a dark dielectric only reflects ~4%). Glass has no MaterialService override slot, so this variant sits on SmoothPlastic: set Material=SmoothPlastic + MaterialVariant=HC_WindowGlass.",
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

-- Global base-material overrides (every part and terrain voxel). Baked into the place as
-- MaterialService.<Material>Name, which the real engine does not honour (job 0009), so
-- Util/MaterialOverrides applies them at runtime too (server + every client).
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

-- Terrain:SetMaterialColor values for the overridden TERRAIN materials (colour contract), applied by
-- LightingService after MapBuilder. Part-only materials are left out (the engine rejects them).
local TerrainColors: { [string]: RGB } = {
	Asphalt = { 104, 104, 107 },
	Brick = { 177, 141, 124 },
	Concrete = { 186, 183, 176 },
	Grass = { 146, 161, 109 },
	Ground = { 207, 190, 158 },
	LeafyGrass = { 137, 155, 105 },
	Pavement = { 200, 197, 188 },
	Rock = { 190, 174, 157 },
	Sand = { 230, 216, 183 },
	Slate = { 202, 200, 195 },
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
		image = "rbxassetid://105997865515655",
		width = 512,
		height = 512,
		note = "Round cast-iron manhole cover, plain (no foundry mark or brand), procedural (Decal, ~2.6 x 2.6 studs).",
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
			Bk = "rbxassetid://97757961136617",
			Dn = "rbxassetid://98952593275525",
			Ft = "rbxassetid://79742849062319",
			Lf = "rbxassetid://129863789995610",
			Rt = "rbxassetid://86621266446209",
			Up = "rbxassetid://135650798270190",
		},
		glowAzimuth = 0,
		horizonGlowAzimuth = 0,
		followSun = true,
		starCount = 0,
		celestialBodiesShown = true,
		clouds = 0,
		hazeColor = { 28, 40, 58 },
	},
	dawn = {
		faces = {
			Bk = "rbxassetid://98043044936404",
			Dn = "rbxassetid://98952593275525",
			Ft = "rbxassetid://129901905692620",
			Lf = "rbxassetid://123519574914603",
			Rt = "rbxassetid://73235550196971",
			Up = "rbxassetid://78912621534818",
		},
		glowAzimuth = 0,
		horizonGlowAzimuth = 0,
		followSun = true,
		starCount = 0,
		celestialBodiesShown = true,
		clouds = 0,
		hazeColor = { 27, 39, 56 },
	},
	day = {
		faces = {
			Bk = "rbxassetid://109617092990906",
			Dn = "rbxassetid://88475019141975",
			Ft = "rbxassetid://109667193500398",
			Lf = "rbxassetid://101438554097333",
			Rt = "rbxassetid://84358563474483",
			Up = "rbxassetid://99148174677802",
		},
		glowAzimuth = 34.1,
		horizonGlowAzimuth = 25.5,
		sunAzimuth = 34.1,
		sunElevation = 48.2,
		followSun = true,
		starCount = 0,
		celestialBodiesShown = true,
		clouds = 0,
		hazeColor = { 165, 166, 170 },
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
		horizonGlowAzimuth = 32.2,
		sunAzimuth = 38.3,
		sunElevation = 8.1,
		followSun = true,
		starCount = 0,
		celestialBodiesShown = true,
		clouds = 0,
		hazeColor = { 171, 163, 157 },
	},
	night = {
		faces = {
			Bk = "rbxassetid://94984348100656",
			Dn = "rbxassetid://98952593275525",
			Ft = "rbxassetid://102872066736317",
			Lf = "rbxassetid://95939202131007",
			Rt = "rbxassetid://95896070267520",
			Up = "rbxassetid://88812082275800",
		},
		glowAzimuth = 0,
		horizonGlowAzimuth = 90,
		followSun = false,
		starCount = 0,
		celestialBodiesShown = false,
		clouds = 0,
		hazeColor = { 28, 36, 52 },
	},
	nightLate = {
		faces = {
			Bk = "rbxassetid://110094107388282",
			Dn = "rbxassetid://98952593275525",
			Ft = "rbxassetid://93141238500720",
			Lf = "rbxassetid://88251663305809",
			Rt = "rbxassetid://74764785598053",
			Up = "rbxassetid://85952127286680",
		},
		glowAzimuth = 0,
		horizonGlowAzimuth = 90,
		followSun = false,
		starCount = 0,
		celestialBodiesShown = false,
		clouds = 0,
		hazeColor = { 26, 33, 49 },
	},
}
Look.Skies = Skies

---------------------------------------------------------------------------------------------------------------------
-- END GENERATED
---------------------------------------------------------------------------------------------------------------------

return Look
