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
