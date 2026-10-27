# Job 0002 report: lighting & materials lab

- **Studio:** 0.744.0.7441077 (macOS), Hotwire City place 106226892419530. Everything ran in Edit mode with no Play.
- **Editor Quality Level:** `settings().Rendering.EditQualityLevel` was already `Level21`, the maximum. I set it to Level21 again, so every shot is at maximum quality.
- **Lighting.Technology:** I could not read or set it. `execute_luau` runs without RobloxScript capability ("cannot write 'Technology'"), so the `pcall` in SETUP failed silently. The shots use whatever Technology the place already has. The night shots show shadowed SpotLight pools and soft shadows, which suggests ShadowMap or Future, but I could not confirm it. If Future matters, set it once in the place's Lighting properties, or have Rojo set it.
- **Run:** SETUP built 454 lab parts. Then I applied each PRESET and took its 3 cameras, in the order `day_clear`, `golden_hour`, `night`, `overcast`.
- **CLEANUP:** confirmed. `Workspace.HCLightingLab` is gone and Baseplate and SpawnLocation have Transparency 0 again. Lighting is back to the place's own children: Sky, SunRays, Atmosphere, Bloom and DepthOfField. ClockTime is back to 16.5, and no lab Clouds are left. I did not save the place.
- **Note:** the place had no Terrain `Clouds` before the lab, so none was restored.

## Impressions

**day_clear: the best overall base.**
- The street shot reads as a clean, believable midday. Asphalt, brick and pavement textures hold up at eye level, and shadows are crisp and in the right direction.
- The far skyline fades well into blue haze.
- Weak spots:
  - The glass tower and the ribbon windows look flat and pale blue, with almost no sky reflection.
  - The sky is a saturated cartoon blue with puffy clouds, more Roblox than GTA. GTA V's midday is whiter and hazier near the horizon, with lower saturation.
  - The elevated shot has a visible hard horizon band where the ground plane meets the haze.
- **GTA-likeness:** about 5/10. Haze density is roughly right, but the sky needs desaturating and the glass needs real reflections or SurfaceAppearance.

**golden_hour: the most cinematic, but the haze is too strong.**
- At street level it is close to GTA's warm afternoon: warm fog at the end of the street, dark asphalt, a slight bloom, and an amber key light on the brick.
- From elevated and skyline heights the orange haze swallows everything. The skyline shot is mostly a beige wall, and the far towers are barely visible.
- The top of the sky stays cyan while the horizon is orange, which looks like two unrelated layers.
- **GTA-likeness:** street 6/10, aerial 3/10. Lowering `Atmosphere.Density` (about 0.28) and Haze would keep the warmth without the fog bank.

**night: the strongest mood at street level.**
- Lamp heads bloom nicely, and the warm pools on the asphalt with real SpotLight shadows give a good "LA at night" read. Road reflectance is subtle.
- The buildings are nearly black silhouettes, though. With no window emissives or interior lights, the city looks dead, while GTA V nights are lit by thousands of windows.
- From elevated and skyline heights everything sinks into a uniform royal-blue fog, and the skyline is barely visible. The lamp line looks nice from above.
- **GTA-likeness:** street 6/10, aerial 3/10. It needs emissive windows, less blue in the Atmosphere color, and lower Density at night.

**overcast: the weakest preset.**
- The street shot is believable as a grey day, with low contrast, soft shadows and a flat sky. Low saturation helps the realism.
- At Density 0.42 and Haze 2, the elevated view is heavy fog, and the skyline shot is a nearly solid blue-grey wall with only the road visible.
- The fog is blue-teal rather than neutral grey, which reads as underwater.
- **GTA-likeness:** street 5/10, aerial 2/10.

**Across all presets:**
- Scale feels right: 52-stud road, 20-stud lamps, 12-stud floors.
- Plain Parts with built-in materials get about halfway to GTA. The biggest gaps are:
  1. Window and glass reflections, and window emissives at night.
  2. Sky and atmosphere colour: a less saturated sky, and neutral rather than blue fog.
  3. Atmosphere Density, which is too high above about 0.35 for any aerial view. This matches the job 0001 finding that the v1 `overview_high` was all fog.
- For v2, I recommend `day_clear` as the base with sky saturation reduced, and `golden_hour` and `night` as variants with Density about 0.25–0.3.
