# Lighting lab, round 1 (real engine, Studio job 0002)

Sources: `docs/v2/evidence/lighting_lab_0002_sheet.jpg` and `lighting_lab_0002_report.md`. Four presets, three cameras each; rows are day_clear, golden_hour, night, overcast. The preset values are in `studio/jobs/0002-lighting-lab.md`.

## Findings

These are binding for LightingService v2.

1. **Ground level.** Built-in Roblox materials on simple parts look like a believable GTA street at eye level: Asphalt road, Pavement sidewalks, a Concrete curb, Brick, Concrete and Glass buildings, with real lane markings at real scale (a 52-stud road, 20-stud lamps, 12-stud floors). Use `day_clear` as the base.
2. **Aerial views break at Atmosphere Density ≥ 0.36.** Above street level the city drowns in fog; v1 used 0.28 with Haze 1.2, which gave the brown wall in job 0001.
   - Target: Density 0.24–0.30, Offset ≥ 0.2, Haze ≤ 1.0.
   - The fog colour must be neutral and slightly warm by day: not blue-teal, never purple or orange.
3. **Sky.** The default Roblox skybox (saturated cyan with puffy clouds) reads as "Roblox", not GTA. Use a custom HDRI skybox, desaturated and whiter near the horizon. The golden-hour sky must match the fog colour: v1 had a cyan zenith over an orange horizon.
4. **Glass.** Plain Glass parts look flat pale-blue, with no sky reflection.
   - Use Reflectance 0.3–0.5 on darker, less saturated glass, plus mullions or spandrels for detail.
   - Use a SurfaceAppearance or MaterialVariant (low roughness, some metalness) where possible.
   - Confirm `Lighting.Technology = Future` in the place (see Technology below).
5. **Night.**
   - Street-level lamp pools with real shadows look good.
   - The city is dead without lit windows. Add emissive window variants (Neon or emissive textures) on a share of windows, varied warm and cool.
   - Night Atmosphere is too blue and too dense. Use Density ≤ 0.3 and a dark, desaturated navy-grey colour.
6. **Overcast.** Not worth shipping as-is. If weather is added, use neutral grey fog, Density ≤ 0.3, plus rain effects.
7. **Technology.** `Lighting.Technology` cannot be set from `execute_luau`, because that lacks the capability. Set it through the Rojo project file (`default.project.json` Lighting properties), or once by hand in Studio, and verify with `inspect_instance`.

# Lighting lab, round 2 (real engine, Studio job 0007; full report in docs/v2/evidence/lighting_lab_0007_report.md)

These findings are binding and override round 1 where they conflict.

1. **Sky rotation.** `yawSign = +1` is confirmed: at yaw 0 the camera sees Ft, at yaw 90 it sees Lf.
2. **Atmosphere Offset** has no visible effect at Density 0.27; captures at 0 and 1.0 were pixel-identical. Lock **Haze 0.8 and Offset 0.25**.
3. **Day and golden HDRI skies are excellent.** The engine sun sits inside the golden glow, and there is no double sun.
4. **BLOCKER: the engine blacks out the skybox when the sun is well below the horizon.**
   - At ClockTime 22.5 the night sky is pure black. The same night sky at 14.2 renders moonlit clouds and city glow.
   - Blue hour at 18.7 (sun at −10°) is near-black and purple.
   - Rule: never run `Lighting.ClockTime` deep into night. Hold it near the horizon: ~18.0–18.3 for the first half of the night, then ~5.7–6.0 for the second half.
   - Fake night darkness with ExposureCompensation, Ambient and OutdoorAmbient, and ColorCorrection; the night HDRI then stays visible.
5. **The golden ↔ day sky swap pops visibly,** and the lighting shifts with it. Minimise swaps and hide them, or drop the day ↔ golden swap entirely.
6. **Lit windows using Neon plus bloom become glowing slabs** and light up whole towers. Use a dimmer emissive (Glass or SmoothPlastic, colour × factor), per-cell windows, or a random lit-cell mask.
7. **Rojo live-sync limits** (Studio Team Create session):
   - The Lighting node fails ("Cannot change Parent of type Lighting"), leaving duplicate Sky, Atmosphere, Bloom and SunRays.
   - LightingStyle reads Soft.
   - MaterialService stays empty.

   These settings only arrive through a real publish. At runtime LightingService must dedupe Lighting children and keep exactly one of each effect.

# Lighting lab, round 3 (real engine: Studio job 0009 on v29/30, Open Cloud probes on v30/31)

Sources: `docs/v2/evidence/look_0009_report.md` + `look_0009_sheet.jpg`, `docs/v2/evidence/look_fix3_probe_v30.json` and
`look_fix3_probe_v31.json` (`tools/look/probe_place.py`). These findings are binding and override rounds 1 and 2 where
they conflict. Job 0011 (`studio/jobs/0011-look-sweep.md`) sweeps the new values.

1. **LightingStyle comes from the legacy `Technology`.** On load the engine maps Technology onto LightingStyle and
   PrioritizeLightingQuality and ignores the file's own values. v30 (no Technology in the file) loaded Soft and
   quality false on a headless server; v31 (`Technology = Future`) loaded Realistic and quality true. Keep
   `Technology = "Future"` in the file (round 1 finding 7 was right; the "delete Technology" advice was wrong).
2. **Base-material overrides.** Studio (Edit, Play server and client) read the stock names on v29/30. A headless
   server of v30/v31 reads all 16 file overrides as active. The cause of the Studio result is unknown: re-creating or
   renaming a variant does not reset an override. The overrides are now also applied at runtime on the server and on
   every client (`Util/MaterialOverrides`).
3. **Fog wall.** At Atmosphere Density 0.27, everything beyond about 350–400 studs is a flat grey band from the
   overview camera, which hides downtown on a city about 3 km across. Density is now one tunable per preset
   (`Look.AtmosphereDensity`): day 0.16, golden 0.18, blue 0.16, night 0.12. Offset 0.25 / Haze 0.8 stay locked.
4. **Night exposure.** The engine darkens the held −3° world on its own. Exposure −0.3 / Brightness 0.4 was about two
   stops too dark: the street was nearly black and the overview completely black. Exposure +2 / Brightness 2 showed a
   readable city and the night HDRI. The night preset now lifts the frame: Exposure +0.8, Brightness 1.2,
   OutdoorAmbient (60, 70, 92). The blue hours are lifted with it, so they are never darker than the night.
5. **Night sky colour.** At the held clock the engine renders the navy-grey night HDRI reddish-brown. The night grade
   is a clear blue tint (212, 226, 255) with saturation −0.2.
6. **Golden hour** read sepia / brown. The cause was a warm haze colour, a warm tint and a saturation boost on top of
   the engine's orange low sun. The grade is now warm-but-neutral.
7. **The engine moon** showed as a large disc on the golden-hour horizon. It is now 1.5° (was 6°) and hidden
   (`MoonAngularSize` 0) whenever the engine sun is above −2°.

# Lighting lab, round 4 (real engine, job 0011, partial: paused by the account moderation)

Full report: `docs/v2/evidence/look_0011_partial_report.md`.

1. **Confirmed fixed.**
   - Overrides: 16/16 active in Edit, Server and Client.
   - `LightingStyle` is Realistic and `PrioritizeLightingQuality` is true, now that `Technology: "Future"` is in the file.
   - Day fog density is 0.16; choose 0.16 even though 0.27 does not wall at Level 21.
2. **The "grey wall" in the v1 overviews was mostly draw distance at low quality, not fog.**
   - At client quality Automatic, an overview is a flat grey frame even at density 0.01; at QualityLevel 21 the whole city renders.
   - **Consequence:** phones (low quality) will not draw a distant skyline. Use StreamingEnabled plus **Model.LevelOfDetail = StreamingMesh (SLIM)** on buildings and landmarks, so distant impostors render. Hero landmarks (Pinnacle Tower, the hillside sign, the bridge) get priority. Assigned to the streaming/integration wave.
3. **Night.** The default variant (exposure +0.8, tint 212/226/255) is a huge improvement and readable. The **night sky texture is still reddish-brown** in every variant; this needs a different or cooler-processed night sky, which the grade alone cannot fix.
4. **Golden hour** is warm-neutral, not sepia (subtle). The moon is hidden. Keep density 0.18.
5. **Blue hour** reads as night: its sky has no blue gradient. It needs a blue-hour sky that keeps a gradient with the sun just below the horizon.
6. **Still to redo after the moderation clears:** step 4, PBR slabs. Texture loads currently return 403.
