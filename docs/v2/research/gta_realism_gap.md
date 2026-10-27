# Realism gap audit: why v1 looks like a rudimentary Roblox game, and the exact changes that fix it

Date: 2026-10-27. Scope: the visual layers only (look and feel). Binding direction: `00_LEAD_DIRECTION.md`, which calls for grounded GTA V realism.

**Evidence used**
- Real-engine screenshots (Studio 0.744, job 0001) in `docs/v2/evidence/v1_real_engine/`: `spawn_dealership.jpg` and `downtown_street.jpg` (the same daylight frame saved twice; the night `spawn_player_view` exists only in `_sheet_job0001.jpg`), `overview_high_haze.jpg`, `overview_low_sw.jpg`, `driving.jpg`, `garage.jpg`, `dealership.jpg`, and `job0001_report.md`.
- Offline previews: `docs/previews/dressed_iso_ne.png`, `kit_buildings.png` and `cars_lineup.png`.
- Lighting lab round 1: `docs/v2/evidence/lighting_lab_0002_sheet.jpg` and `lighting_lab_0002_report.md`. The preset values are in `studio/jobs/0002-lighting-lab.md`.
- The source files cited below, by file and line.

Units: **1 stud = 0.28 m** (3.57 studs per metre), which is Roblox's physics definition. Line numbers refer to the tree as of commit `e4b63ac`.

---

## 0. The verdict in ten lines

v1 does not look cheap because Roblox can't do better. It looks cheap because it is tuned on purpose to look like a cartoon. The heads of the files say so: "bold cartoon look" (`LightingService.luau:2`), "Palette (bold cartoon)" (`MapBuilder.luau:93`), "bold cartoon style" (`CarBuilder.luau:2`), "bold cartoon-heist look" (`Theme.luau:2`).

Ranked by how much of each screenshot they ruin:

1. **The grade tints the whole world pink and then purple.**
   - Sunset ColorCorrection `TintColor` is (255,192,170), saturation is +0.24 to +0.36 at every hour, and `Ambient` is 104–130 by day (66–84 at night) where the default is 0.
   - Night is lit violet by design.
   - The cycle is 16 minutes, and new servers start at 16:12, so players reach the purple night after about 2 minutes (§2.3–2.4).
2. **The haze swallows the city.** Atmosphere Haze peaks at 2.1–2.5 (about 2.05 when `overview_high_haze.jpg` was taken). Haze, not Density, is what separates that brown wall from the lab preset that kept the skyline. Offset (0.12) was the same in both, so it is not the cause (§2.2).
3. **There are no real materials.**
   - `part()` defaults to SmoothPlastic (`MapBuilder.luau:225`).
   - Roads are blue-purple SmoothPlastic (58,61,80); sidewalks are lavender-white SmoothPlastic.
   - The Asphalt, Pavement, Concrete and Plaster materials are used **zero times** in the map. Brick is used once.
4. **Neon everywhere, on pastel and toy-saturated albedos.**
   - `MapBuilder.luau` has 31 `neon()` call sites, 6 more parts set to Neon directly, and 19 `nightGlow` parts that switch to Neon at night. The garages (`PlotService.luau`) add 26 `neon()` calls and 4 direct Neon parts, and `DealershipService.luau` adds 5. Several of these sites are inside loops, so the real part count is higher.
   - Pink and cyan rims sit on every pad, canopy and tower.
   - The palette tables are named PASTEL, SHOP and NEON (`MapBuilder.luau:140–180`).
5. **The scale is a toy.**
   - The road grid is 1,640 studs (0.46 km) across: 1,800 with the beach, and the boundary walls sit at ±960. A car at the median top speed of about 110 studs/s crosses it in about 15 s (9–25 s across the car roster).
   - Every road has the same 40-stud, two-lane cross-section.
   - Blocks are 120 studs (34 m). Towers top out at 240 studs (67 m).
   - Cars are 13.4 studs long but 6.8 wide: the stubby proportions of a toy.
6. **Blob AI meshes with baked, smeared lighting.** There are 96 owned Higgsfield/Meshy meshes: 22 buildings, 41 props and 33 car shells (`Config/Assets.luau`). They replace the procedural placeholders.
7. **Building massing reads as a board game.** Single towers or diagonal pairs sit on plinths in 104-stud lots. There are no street walls. Windows are "ring bands" wrapped around boxes (`MapBuilder.luau:1091–1109`), with no mullions, depth or rooftop clutter.
8. **Default Roblox characters.** NPCs use the blocky default R15 body and classic 2D shirts, and play the default `507777826` walk and idle animations. There are only 10–14 pedestrians on the whole map (`NPCService.luau:81–82, 126–129`).
9. **The default Roblox sky** (no textures, `LightingService.luau:479–483`), with a giant cartoon sun (16°) and moon (11°).
10. **Kid-simulator UI.**
    - FredokaOne, hot pink and cyan, 14 px corners and 3 px strokes (`Theme.luau:7–33`).
    - A left column of eight candy buttons.
    - A 500×110 tutorial card in the middle of the screen (`TutorialController.luau:677–679`).
    - Distances shown in "studs" (`EventsClient.luau:519`).

**Fastest big jump:** items 1–4, plus removing the item-6 meshes, are config and palette changes that need no new assets: about 1 to 1.5 days in all (§5 rows 1, 2, 3, 6, 7 and 8). Item 10, the UI, is another 6–10 h. Items 5, 7 and 8, and replacements for the item-6 meshes, are the v2 build waves (§5).

---

## 1. Scale baseline: real-world dimensions versus v1

At 1 stud = 0.28 m, a real 1.75 m adult would be 6.25 studs tall. The R15 default avatar is about 5–5.3 studs, roughly 1.45 m, so on the character's scale a stud is about 0.33–0.35 m.

Realistic Roblox games accept this mismatch: they build the world at about 0.28 m per stud and keep avatars at 5–6 studs. Recommendation:
- Build the world to the targets below.
- Set NPCs and players to `BodyHeightScale` 1.05–1.10 (about 5.6–5.9 studs) so a 17-stud car does not dwarf people.

| Element | Real world | **v2 target (studs)** | v1 (studs) | v1 source |
|---|---|---|---|---|
| Travel lane | 3.3–3.7 m | **12–13** | about 11.5 (centre line to the parking lane) | `Map.luau:20` LANE_OFFSET 8 |
| Parking lane | 2.4–2.7 m | **8.5–9.5** | about 8 (cars at 15.5, edge line at 18.4) | `Map.luau:21`, `MapBuilder.luau:2259` |
| Local street, curb to curb (2 lanes + 2 parking) | 11–13 m | **42–46** | 40, and **every** road is this | `Map.luau:11` |
| 4-lane avenue with parking | 19–21 m | **68–74** | none | |
| 6-lane boulevard with median | 30–33 m | **105–118** | none | |
| Freeway, 4+4 lanes with shoulders | about 40 m | **140–150** deck, 25–35 high, clearance ≥18 | none | |
| Sidewalk, downtown | 3.5–6 m | **12–20** | 8 everywhere | `Map.luau:19` |
| Sidewalk, residential (including the planting strip) | 2.5–4 m | **9–14** | 8 | |
| Curb height and width | 0.15 m | **0.55 × 0.5** | 0.6 tall ✓, but no separate curb part | `Map.luau:18` |
| Corner curb radius | 4.5–7.5 m | **16–27** | 0: square corners | `MapBuilder.luau:2344–2440` |
| Lane line width, dash, gap | 0.1–0.15 m, 3 m, 9 m | **0.4–0.55, 10.7, 32** | 0.8 wide, a 16-long **yellow** centre dash every 40 | `MapBuilder.luau:2290–2293` |
| Continental crosswalk bar | 0.3–0.6 m × 3 m | **1.2–2 × 10–11, 1.8 gap** | chunky 6×5 blocks on a 9-stud pitch | `MapBuilder.luau:2316–2324` |
| Sedan L × W × H | 4.8 × 1.85 × 1.45 m | **17 × 6.6 × 5.2** | 13.4 × 6.8 × 5.55 | `CarBuilder.luau:835–856` |
| Sedan wheelbase, wheel diameter | 2.8 m, 0.67 m | **10, 2.4** | 8.5, 2.64 | same |
| SUV, pickup, van | 4.9 / 5.3 / 5.1 m long | **17.5 / 19 / 18** | 12–15 (shells) | `Assets.luau:28–60` |
| Bus, semi with trailer | 12 m, 16.5 m | **43, 59** | none | |
| Storey: residential / office / retail ground floor | 3.0 / 3.8 / 5 m | **10.7 / 13.5 / 16–20** | ribbon bands every ≥8.5; tower bands ≥13 | `MapBuilder.luau:1179, 1137` |
| Door | 2.1 m | **7.5** | none | |
| Street lamp (cobra head) | 9–11 m | **32–40** | 18 | `MapBuilder.luau:79` LAMP_FIT |
| Lamp spacing | 30–45 m | **110–160 per side** | about 1 per *block*, roughly 480 studs of curb | `MapBuilder.luau:2445` |
| Signal pole, head clearance | 6–8 m, ≥4.6 m | **22–29, ≥16.5** | 22 ✓ | `MapBuilder.luau:80` |
| Mexican fan palm (LA's signature) | 18–30 m | **65–107**, trunk 1.5–2.5 thick | 17–34 | `Assets.luau:87–88`, `palm()` at `MapBuilder.luau:713` |
| Downtown block, curb to curb | about 100 × 120–200 m | **360 × 430–700** | 120 × 120, including the sidewalks | `Map.luau:10–11` |
| Downtown towers | 100–335 m | **350–1,200**: one landmark of 700–900, 6–10 towers of 350–600 | 200–240 | `MapBuilder.luau:549–551` KIT_DIMS |
| Map | GTA V: tens of km² | **phase 1: at least 6,000 × 6,000 (1.7 km)²** with StreamingEnabled | 1,640 × 1,640 (0.21 km²), streaming **off** | `Map.luau:16`, `default.project.json:42` |

---

## 2. Layer by layer

Each layer lists the current values, why they read as cheap, and the target.

### 2.1 Sky

**Current**
- `HotwireSky` has no skybox textures, so it is the default Roblox sky: saturated cyan with puffy clouds (`LightingService.luau:479–483`).
- `SunAngularSize` is 16 and `MoonAngularSize` is 11. The moon in `overview_low_sw.jpg` covers about 8% of the frame width.
- `StarCount` is 3000.
- Terrain Clouds use Cover 0.45, Density 0.65 and Color (255,255,255) at every hour (`LightingService.luau:517–519`; MapBuilder labels them "soft cartoon clouds" at `MapBuilder.luau:3903`).

**Why it reads as cheap**
- The default sky is the single most recognizable "this is Roblox" signal. Lab round 1 confirms it reads as Roblox, not GTA.
- A 16° sun and an 11° moon are storybook sizes; the real sun and moon are about 0.5° across.
- White clouds at night glow.

**Target**
- Three custom skyboxes (day, golden, night), each made from a CC0 Poly Haven "puresky" HDRI converted to six 1024² faces, swapped by LightingService at the band edges. Candidates:
  - **Day:** `kloofendal_48d_partly_cloudy_puresky`, or `kloofendal_43d_clear_puresky` for clear skies.
  - **Golden hour:** `belfast_sunset_puresky`, `industrial_sunset_puresky`, or `kloppenheim_06_puresky` (low contrast).
  - **Night:** `kloppenheim_02_puresky` (clear night).
  - Source: [Poly Haven API](https://api.polyhaven.com/assets?t=hdris&c=skies).
- Desaturate the day sky about 15% and keep it whiter at the horizon. Match the golden sky's horizon colour to `Atmosphere.Color`; v1 had a cyan zenith over an orange horizon.
- `SunAngularSize` 9–11, `MoonAngularSize` 5–7, `StarCount` 1500.
- Clouds: Cover 0.35–0.5, Density 0.45. Color (245,245,245) by day, (255,226,200) at golden hour, (52,56,68) at night.
- The prototype for this already exists (task #8, skybox). This doc only fixes the numbers.

### 2.2 Atmosphere and haze: the brown-wall shot, explained numerically

**Current keys** (`LightingService.luau:100–259`; Offset is fixed at **0.12** at line 487 and is never keyed):

| Key | Hour | Density | Haze | Glare | Color | Decay |
|---|---|---|---|---|---|---|
| Night | 0 / 24 | 0.38 | **2.5** | 0 | (78,62,150) violet | (130,46,150) magenta |
| Day | 9 | 0.26 | 1.1 | 0.25 | (200,224,255) | (110,134,170) |
| Golden | 16.4 | 0.30 | **1.9** | 0.8 | (255,186,128) | (196,106,88) |
| Sunset | 17.6 | 0.32 | **2.1** | 0.6 | (255,150,132) | (172,80,112) |
| Blue hour | 18.8 | 0.36 | **2.3** | 0.1 | (112,76,162) | (154,60,150) |

**What `overview_high_haze.jpg` actually is**

*Time.*
- The cycle gives 12 game hours in 12 real minutes by day (`:27`), and servers start at 16.2 (`:34`).
- Play began, the operator waited 45 s, then took the shot first.
- So ClockTime was about **17.0–17.3**, between the golden and sunset keys. That is consistent with `downtown_street` still being in daylight and every later shot being night, as the report says.

*Interpolated look at 17.2* (smoothstep t ≈ 0.74; the code is at `:263–295`):

| Setting | Value |
|---|---|
| Density | **0.315** |
| Haze | **2.05** |
| Glare | 0.65 |
| Offset | 0.12 |
| Color | (255,159,131) |
| Decay | (178,87,106) |
| ColorCorrection Tint | (255,198,170) |
| Saturation | +0.31 |
| Contrast | +0.13 |
| Exposure | +0.10 |
| OutdoorAmbient | about (195,129,119) |

*Geometry.*
- The camera is at (0, 900, 900). Assuming it looked at the map centre, it was pitched −45°. Roblox's default vertical FOV of 70° then covers rays from −10° to −80°.
- The **closest** ground in frame (bottom edge) is 900 / sin 80° = **914 studs** away. The frame centre is 1,273 studs away. The far half of the island is 1,500–2,500 studs away. The top third of the frame looks past the island at 2,000–5,000 studs.

*Extinction: an empirical fit, since Roblox publishes no formula.* Model it as screen contrast ≈ exp(−d/L) and fit L from the lab sheet, which uses the same engine and cameras up to 1,750 studs:

| Case | Density / Haze / Offset | What the screenshots show | L (studs) |
|---|---|---|---|
| Lab day_clear | 0.32 / 0.9 / 0.12 | towers 1,250–1,750 away still at about 40–50% contrast | ≈ 1,800 |
| Lab golden_hour | 0.36 / 1.3 / 0.08 | the same towers at about 10–15% | ≈ 700–800 |
| **v1 at 17.2** | **0.315 / 2.05 / 0.12** | nothing visible from 914 studs onward, even at the bottom edge | **≲ 300** |

- v1's Density (0.315) was *lower* than the lab day preset (0.32), which kept the skyline.
- The difference is **Haze 2.05**, 2.3× the lab day value. Offset cannot explain it: lab `day_clear` used the same Offset, 0.12, and kept the skyline. A higher Offset may still help (the Roblox docs say to increase it "to create a horizon silhouette against the sky" or reduce it "to blend distant objects into the sky"), but that has not been tested here.
- At L ≈ 300 the bottom edge keeps exp(−914/300) ≈ 5% contrast and the frame centre about 1.4%. Visually that is zero, which is exactly the result.
- Conclusion: **the fog wall is mainly a Haze problem, made worse by the warm Color and Decay and by the grade. Density alone does not explain it, and Offset did not differ between the two cases.** `references.md` §1.2 blamed Density; this doc corrects that.

*Why it is brown rather than grey.*
- With Haze > 0 and Glare > 0, Roblox's in-scattered light ramps from `Color` (toward the sun) to `Decay` (away from it). ([Atmosphere guide](https://create.roblox.com/docs/en-us/environment/atmosphere); [Atmosphere API](https://create.roblox.com/docs/reference/engine/classes/Atmosphere.md).)
- ColorCorrection then multiplies every pixel by the tint (1.00, 0.78, 0.67) and adds 31% saturation:
  - Color (255,159,131) × tint → **(255,124,87)**, a peach-orange. That matches the top of the frame.
  - Decay (178,87,106) × tint → **(178,68,71)**, a brick brown. Darkened by the fogged ground below, that matches the bottom.
- The frame's measured gradient, from about (225,180,150) at the top to about (70,55,48) at the bottom, is consistent with this.

*An engine-config hazard found on the way: duplicate Lighting children.*
- The place has its own template children: `Sky`, `SunRays`, `Atmosphere`, `Bloom` and `DepthOfField` (lab report, CLEANUP).
- LightingService's `getOrCreate` matches by **name** (`:337–346`), so it adds `HotwireSky`, `HotwireAtmosphere`, `HotwireBloom` and `HotwireSunRays` **next to them**.
- Roblox renders only one Sky and one Atmosphere, and which one wins is unspecified. Post effects (Bloom, SunRays, DepthOfField) **stack**.
- The warm brown cast needs Haze > 0 on a warm Color, so `HotwireAtmosphere` was most likely the active one. But the template Bloom and SunRays add to v1's, and a template DepthOfField, if enabled, would blur the far city. The soft background in `spawn_dealership.jpg` is consistent with that.
- **Fix:** LightingService v2 destroys or adopts *every* `Sky`, `Atmosphere` and `PostEffect` in Lighting that it did not create. The operator should dump `Lighting:GetChildren()` with their properties in Play mode to confirm.

**Target.** Lab round 1 recommended a Density of about 0.25–0.30 and neutral fog colour. The limits Haze ≤ 1.0 and Offset ≥ 0.2 are this doc's own proposals and have not been tested: every lab preset used an Offset of 0.08–0.15.

| | Day (13:00) | Golden (17:30) | Night (22:00) |
|---|---|---|---|
| Density | 0.27 | 0.26 | 0.22 |
| Offset | 0.25 | 0.30 | 0.15 |
| Haze | 0.8 | 1.0 | 0.5 |
| Glare | 0.2 | 0.5 | 0 |
| Color | (199,208,220) neutral blue-grey | (255,210,165) warm | (46,52,68) desaturated navy-grey |
| Decay | (122,134,152) | (128,124,148) cool, for complementary shadows | (22,24,32) |

- With these values the downtown skyline should stay readable at about 1,500–2,000 studs. The marketing and overview cameras then work.
- A hard rule for every key: **Haze ≤ 1.2 and Offset ≥ 0.15.**

### 2.3 Sun, ambient and shadows: why everything is flat

**Current**
- `Lighting.Ambient` is (104,104,118) by day, (126,88,104) at sunset and (66,70,132) at night (`:103, :164, :221`).
- `OutdoorAmbient` is (150,152,166) by day, (192,122,120) at sunset and (74,82,152) at night.
- `Brightness` is 1.35–3.
- `ShadowSoftness` is 0.25 and `GeographicLatitude` is 23 (`:473–476`).
- Technology is Future, set in `default.project.json:50` ✓.

**Why it reads as cheap**
- `Ambient` is the light given to areas *occluded from the sky*, and it defaults to **0** ([Lighting API](https://create.roblox.com/docs/reference/engine/classes/Lighting.md)).
- At 104–130, the space under the dealership canopy, interiors and alleys are lit almost like open street. In `spawn_dealership.jpg` there is no shadow under a 106-stud roof. That is the "flat, no depth" in the verdict.
- `OutdoorAmbient` at about 60% of the sun's level fills shadows so much that the lit-to-shadow ratio is only about 1.5:1. GTA's daylight sits around 4:1 to 8:1.

**Target**

| | Day | Golden | Night |
|---|---|---|---|
| Brightness | 3.0 | 3.2 | 0.8 (moon) |
| ExposureCompensation | 0 | +0.05 | +0.3 |
| Ambient | (20,20,24) | (24,18,16) | (8,8,12) |
| OutdoorAmbient | (120,124,134) | (128,110,98) | (36,40,54) |
| ShadowSoftness | 0.12 | 0.2 | 0.25 |

- `GeographicLatitude` 34 (Los Angeles).
- `EnvironmentDiffuseScale` and `EnvironmentSpecularScale` stay at 1. These only pay off with a real skybox (§2.1).

**Cycle**
- v1 runs 12 min of day plus 4 min of night (`:27–28`) and starts at 16.2 (`:34`). Sunset arrives **1.8 real minutes** after boot, so most first impressions happen at the purple night. Five of the six operator shots are night shots.
- **Target:**
  - A 48-minute cycle, matching GTA V's 2 real seconds per game minute.
  - Night compressed to about 12 minutes and golden hour stretched to about 6 minutes.
  - New servers start at about 11:00–13:00.
  - A `TimeOfDayLock` attribute for operator and marketing shots.

### 2.4 Colour grading and bloom: why everything is pastel pink, then purple

**Current**
- ColorCorrection Saturation is **+0.24 to +0.36 at every hour** and Contrast +0.08 to +0.16.
- `TintColor` per key:

| Key | Tint |
|---|---|
| Day | (255,250,240) |
| Golden | (255,214,168) |
| **Sunset** | **(255,192,170)** |
| Blue hour | (214,196,255) |
| Night | (196,200,255) |

- Bloom runs Intensity 0.45 to 1.45, Size 24 to 32, Threshold 1.7 down to 1.15 (`:100–259`).

**The pink, numerically** (`spawn_dealership.jpg`, ClockTime about 17.5, almost exactly the sunset key)
- The dealership canopy is `C.white` (245,246,250) SmoothPlastic, and the sidewalks are (212,212,222).
- The tint multiplies white by (1.00, 0.75, 0.67), giving **(255,192,170)**, which is salmon.
- OutdoorAmbient (192,122,120) adds pink fill, and Ambient (126,88,104) lifts the shade under the canopy to the same mauve.
- Saturation +0.32 on top of that turns every white or grey surface pastel pink.
- Bloom (0.9 intensity, threshold 1.4) makes the 106-stud Neon `CanopyEdge` (C.pink, `MapBuilder.luau:2666`) and the pink and cyan `DealerPadRim`s (`MapBuilder.luau:2631`) glow.
- **The pink comes from the grade and the palette, not from the geometry.**

**The purple** (`overview_low_sw.jpg`, `driving.jpg`, `garage.jpg`, `dealership.jpg`; ClockTime about 19.9, roughly 88% blue-hour key)
- OutdoorAmbient (106,86,158), Ambient (84,72,138), Atmosphere (112,76,162) and (154,60,150), Tint (214,196,255) and Saturation +0.34 together make every surface violet.
- Buildings are lit by that ambient, not by lamps or windows. "Readable navy, not pitch black" is the stated intent (`:100`).

**Target**

| | Day | Golden | Night |
|---|---|---|---|
| CC Brightness | 0 | 0 | 0 |
| CC Contrast | +0.08 | +0.12 | +0.15 |
| CC Saturation | **0.0** | +0.06 | −0.05 |
| CC Tint | (255,253,248) | (255,244,230) | (236,240,255) |
| Bloom Intensity / Size / Threshold | 0.4 / 24 / 1.8 | 0.6 / 28 / 1.5 | 1.0 / 30 / 1.05 |
| SunRays Intensity / Spread | 0.03 / 0.6 | 0.10 / 0.65 | 0 |

- Colour belongs in **light sources** (warm sun, sodium lamps, signs). The grade should never carry it.
- Tint channels never drop below 225, and saturation never exceeds +0.10.
- The WASTED and BUSTED grayscale (Saturation −1) is the only big grade move (see `gta_ui_language.md` §0.4).

### 2.5 Ground: roads, markings, sidewalks and lots

**Current**
- Roads are one SmoothPlastic slab per grid line, 1,640 studs long, colour (58,61,80), a blue-purple (`MapBuilder.luau:102, 2257–2286`).
- Markings:
  - yellow centre *dashes* on two-way streets;
  - white edge lines 0.6 wide;
  - crosswalks only within downtown and midtown.
- Sidewalks are SmoothPlastic (212,212,222) (`:106, :2419`).
- There are no curb parts, square corners, no curb ramps at corners, and no drains, manholes, patches or cracks.
- Lot interiors are flat-coloured slabs (`ZONE_LOT`, `:2335`):
  - downtown and docks: SmoothPlastic;
  - "lowrise" and shops: **lime (118,198,92) Grass**.

**Why it reads as cheap**
- A uniform, untextured purple-grey ribbon with zero variation reads as a board-game track. From any height it gives the "Monopoly board" look of `dressed_iso_ne.png`.
- Square corners and unbroken slabs are the fingerprint of a grid generator.

**Target**
- **Asphalt:** `Enum.Material.Asphalt`, Color (62,62,64), neutral.
  - Better: a MaterialVariant `HC_Asphalt` from Poly Haven `asphalt_02` or `road_damaged_clean` (CC0), with StudsPerTile 14–18.
  - Intersections slightly darker, (54,54,56), with patch and crack decals.
  - Reflectance 0 by day and about 0.08 at night. A wet variant for rain later.
- **Markings** in US MUTCD style:
  - double solid yellow centre line (214,170,40), two 0.45-wide lines with a 0.45 gap;
  - white lane lines 0.45 × 10.7 dashes with 32 gaps;
  - solid white edge lines;
  - stop bars 1.6 wide;
  - continental crosswalks at every signalized intersection.
  - Paint colour is off-white (222,222,214), never pure white. Add 5–15% transparency or wear decals.
- **Curb:** a separate Concrete strip 0.55 tall × 0.5 wide, colour (182,178,170), with radiused corners of 16–27 studs and curb ramps.
- **Sidewalk:** `Pavement` or `Concrete`, or a MaterialVariant from `concrete_pavement` or `pavement_03`, colour (168,164,156). Show expansion joints every 5.4 studs (1.5 m). Tree grates downtown; a grass planting strip of 4–6 studs in residential areas.
- **Lots:** no coloured slabs.
  - Downtown: building footprints plus paver plazas.
  - Residential: Terrain `LeafyGrass` with `Terrain:SetMaterialColor` at about (96,108,62) (dry LA green), plus Concrete driveways.

### 2.6 Building massing and facades

**Current**
- **Downtown:** 11 blocks, each with a single tower or a diagonal "twin" pair, plus plazas (`DOWNTOWN_PLAN`, `MapBuilder.luau:1719–1814`). Each tower gets a Neon ground ring (`NeonEdge`, `:1666`) and a red beacon ball.
- **Procedural placeholders** (`:1111–1232`):
  - Glass shafts in saturated colours from `TOWER_GLASS`, `:141–149`: (64,178,214), (122,92,206), (206,104,176) and others.
  - Floor bands that turn Neon at night, Neon `Crown`s and `Fin`s.
  - Mid-rises use one wrapped `Windows` band per floor (`:1182`). Shops use a Neon `CapTrim` (`:1231`). Houses use `PASTEL` walls.
- **Dressed city:** these are replaced by the 22 AI meshes in `Assets.Buildings`:
  - `skyscraper_twist` (240 studs), `skyscraper_deco` (220), `skyscraper_neon` (200), `office_block` (80);
  - the `car_showroom` backdrop placed on the dealership roof (`DealershipService.luau:715`). This is the smeared pink building in the spawn shot.
  - See `docs/previews/kit_buildings.png`: toy proportions, baked blotchy textures, swirl and deco towers.
- **Garage:** a white box with Neon trim (`PlotService.luau`: 26 `neon()` calls plus 4 parts set to Neon directly).

**Why it reads as cheap**
- Objects sit on plinths instead of forming street walls. Every building is a different saturated colour.
- Windows are stripes with no reveal depth, so they cast no shadow under Future lighting.
- There is no rooftop clutter, and the silhouettes are cartoon (twist and deco).
- Tower height of 200–240 studs on 34 m blocks reads as a model-railway skyline.
- Neon outlines structure, which no real city does.

**Target**
- **Massing.**
  - Downtown buildings sit at the sidewalk line (setback 0–4 studs). Use 3–6-storey podiums (40–80 studs) with set-back towers.
  - Put 4–10 distinct buildings per block face, with alleys of 14–20 studs.
  - Heights: landmark 700–900; towers 350–600; mid-rise 60–160; retail 18–32; houses 12–28.
  - Rich and poor sit side by side, per `references.md` §1.1.
- **Facade grammar** (in flight as the Blender building kit, task #8; see `docs/v2/proto/buildkit/_iter/midtown_v1.png`, which already shows the right language):
  - floor-to-floor 10.7 (residential) or 13.5 (office);
  - windows 4–6 wide × 6–8 tall, recessed 0.4–0.8, with 0.3 sills;
  - mullions 0.3–0.5; a pilaster every 15–20-stud bay;
  - a cornice 1.5–3 proud and a parapet about 3 tall;
  - a ground-floor storefront of 16–20 studs: 70% glazing, a 3-stud sign band and an awning;
  - AC units, fire escapes and drainpipes.
- **Curtain walls:** Glass at (40,52,62) with Reflectance 0.35–0.45. Metal mullions (150,155,160) on a 5-stud pitch and spandrels 1.2 tall at each floor line. Never coloured glass.
- **Materials:**
  - `Brick` (140,74,58) / (165,110,85);
  - `Plaster` stucco (214,200,178) / (196,180,160);
  - `Concrete` (170,168,162);
  - `Metal`.
  - Albedo stays at or below about 225 per channel. Pure white (245–250) blows out under Future at Brightness 3.
  - PBR MaterialVariants come from Poly Haven: `red_brick_03`, `white_stucco_02`, `painted_plaster_wall`, `concrete_tile_facade` and `rectangular_facade_tiles_02` (all CC0).
- **Rooftops:** HVAC boxes, water tanks, antennas, a helipad on the landmark, and aviation lights (red, small).
- **Night:** 30–60% of windows lit, mixing warm (255,200,140) and cool (215,228,255). Use emissive panels set 0.5–1 stud *behind* the glass so they show parallax (lab finding 5).
- **Delete** `towerAccents` NeonEdge (`:1656–1682`), `Crown` and `Fin` (`:1147–1158`), `CapTrim` (`:1231`), `CanopyEdge` (`:2666`), `DealerPadRim` (`:2631`) and the garage Neon trims.
  - Neon is allowed only on light emitters and on at most one sign per storefront, lit at night through NightGlow.
- **Part budget:** `PART_BUDGET` is 9000 (`MapBuilder.luau:52`). A facade grammar at this density needs MeshPart kit modules with SurfaceAppearance, not hundreds of Parts per building.

### 2.7 Scale and city layout

**Current**
- An 11 × 11 grid on a 160-stud pitch (`Map.luau:10–16`): 100 blocks of 120 × 120.
- One road class. No freeway, no hills and no landmark sign. StreamingEnabled is **false** (`default.project.json:42`).

**Why it reads as cheap**
- The city fits in one screen (`dressed_iso_ne.png`). Everything is the same distance apart, and you cross the map before the radio song changes.
- GTA's sense of place comes from hierarchy: freeway, boulevard, avenue, local street, alley. It also comes from districts with distinct silhouettes.

**Target (phase 1)**
- A playable area of at least 6,000 × 6,000 studs, with StreamingEnabled true and the landmark models set Persistent.
- A road hierarchy using the cross-sections in §1:
  - an elevated freeway loop of about 15,000 studs;
  - 2–3 boulevards of 105–118 studs;
  - a grid of 68–74-stud avenues;
  - 42–46-stud local streets;
  - alleys.
- Downtown blocks of 360 × 450–700.
- Terrain hills to the north for the mansions and the letter sign, the port with cranes, a beach and pier, and a desert or highway exit.
- Landmarks visible from every district (`references.md` §1.1).
- v1's `Config/Map` constants (`LANE_OFFSET`, `PARK_OFFSET`, `ROAD_WIDTH`) are shared with traffic, NPC sidewalks and plots. v2 needs a road graph, not a single grid constant.

### 2.8 Props and street furniture

**Current**

| Item | v1 |
|---|---|
| Street lamps | 18 studs tall, **one per block**, about 100 city-wide. PointLight Range 34, Brightness 1.7, no shadows (`MapBuilder.luau:1036–1064, 2445`). |
| Traffic signals | Only at downtown intersections, in a checkerboard. Cartoon yellow head with a single always-on Neon green lamp (`:1067–1088, 2480–2492`). |
| Parked cars | 24–44 on about 70k studs of curb, roughly one per 1,600 studs (`StreetSpawnService.luau:38–40`). |
| Traffic | 18–36 cars (`TrafficService.luau:61–62`). |
| Kit props | 41 AI meshes: hydrant, bench, bus stop, the hot-dog stand at spawn (`DealershipService.luau:749`), and others. |
| Ads | Cartoon art and joke copy ("DUCK INSURANCE", "VROOM VITAMINS"; `MapBuilder.luau:182–193`). |

**Why it reads as cheap.** GTA streets are dense: a lamp, a tree, a meter, a sign or a parked car every few metres. In v1 the curbs are bare.

**Target**
- **Lamps:** cobra-head lamps 32–40 tall on arterials and 14–16 pedestrian lamps downtown, every 110–160 studs per side, staggered.
  - Night: a downward SpotLight with Angle 110–130, Range 50–60, Brightness 3–5.
  - Colour: sodium (255,176,96) in the hood and on arterials, LED (240,240,255) downtown.
  - Shadows on for the nearest 8–12 lamps only, through client LOD.
  - The lab's lamp (20 studs, SpotLight 4/48/120°) was the most GTA-like element of round 1.
- **Signals:** at every arterial intersection. Mast arms of 25–40 studs reaching over the lanes, 3–4 heads per approach, real red/amber/green cycling with lights, pedestrian signals, and street-name signs.
- **Density per 100 studs of downtown curb:** 1 tree in a grate, 0.7 lamps, 0.5 trash cans, 0.3 utility or newspaper boxes, parking meters at 7-stud pitch along parking lanes, 1 parked car per about 18–20 studs at 60–80% occupancy.
- **Elsewhere:** a hydrant every about 300; a bus stop about every 1,000; **utility poles with overhead wires** in residential and hood districts, an LA signature. Manholes, drains and a few potholes.
- **Ads:** keep the billboard system, but use photographic GTA-style parody ads (`references.md` §1.1). The hot-dog stand and the gold car stop being hero objects at spawn.

### 2.9 Vegetation and terrain

**Current**
- Palms 17–34 studs, as AI meshes `palm_tree_a/b` or procedural `palm()`.
- `round_tree` with a ball canopy. Shrubs are 7-stud green **balls** (C.leafB (92,204,84)). Hedges are green boxes.
- Lawns are lime SmoothPlastic or Grass (118,198,92).
- Terrain is used only for sea, seabed, the park lawn and planter beds (`MapBuilder.luau:3841–3908`). No hills.

**Target**
- Washingtonia fan palms 65–100 studs tall with thin trunks and a skirt of dead fronds, lining boulevards and the beach road every 30–40 studs. Canary palms 35–55.
- Street trees (ficus, jacaranda) 25–40 tall with a believable canopy. Foliage meshes with alpha cards, sourced as CC0/CC-BY (task #11) or from realistic Creator Store models.
- Terrain: `LeafyGrass` with decoration, and `Grass` colour about (96,108,62) dry and (84,110,58) irrigated. Ground and Rock hills with scrub to the north.
- No ball shrubs. No pure-green boxes.

### 2.10 Water and beach

**Current**
- `WaterColor` (24,186,214) tropical cyan, `WaterTransparency` 0.35, `WaterReflectance` 0.6, `WaveSize` 0.12, `WaveSpeed` 9 (`MapBuilder.luau:3879–3883`).
- Pond `C.water` (60,196,255). Sand (248,224,162) is a saturated yellow; promenade (236,196,150) (`:114, :125`).

**Target (Pacific / LA)**
- `WaterColor` about (22,70,84), `WaterTransparency` 0.2, `WaterReflectance` 1.0, `WaveSize` 0.15, `WaveSpeed` 10.
- Terrain `Sand` set to `SetMaterialColor` about (204,186,150), with a darker wet-sand band at the shoreline.
- A concrete boardwalk; a pier of WoodPlanks at about (120,96,72).
- The day Atmosphere (§2.2) handles the horizon blend.

### 2.11 Vehicles

**Current**
- Procedural cars are 26–37 box Parts each, all SmoothPlastic with Neon head- and taillights (`CarBuilder.luau:173–174, 266–282`). Glass is (34,50,78) at 0.3 transparency. "Chrome" is SmoothPlastic with Reflectance 0.15.
- The sedan is 13.4 × 6.8, a length-to-width ratio of **1.97**; a real sedan is **2.6**.
- `Underglow` and Neon accents appear on several cars.
- The hero shells are 33 AI meshes of about 9k triangles each with muddy baked textures. The `rustbucket` in `driving.jpg` is the example.
- See `cars_lineup.png`. Meme cars (duck, toilet, couch, hot-dog) are core content.

**Why it reads as cheap**
- Proportions are the first thing the eye reads on a car: short and wide reads as a toy.
- Flat panels with no curvature, no specular glass or chrome, and Neon lamps look like LEGO.

**Target**
- Real-proportioned meshes at the dimensions in §1, from the car kit (task #8) or CC0/CC-BY sources (task #11). Parody brands only.
- LOD0 of 10–25k triangles. Four separate wheel MeshParts that spin, with rims and tyre sidewalls.
- **Paint:** a SurfaceAppearance with `AlphaMode.TintMask`, so `SurfaceAppearance.Color` drives customizable paint ([AlphaMode enum](https://create.roblox.com/docs/reference/engine/enums/AlphaMode.md)), with low roughness.
- **Chrome:** metalness 1, roughness about 0.1.
- **Glass:** (30,36,42), Transparency 0.35–0.45, Reflectance 0.3.
- **Lights:** headlight lenses with SpotLights. Brake lights go Neon only while braking. No underglow by default.
- Meme cars become at most 1–2 hidden collectibles (lead direction).

### 2.12 Characters

**Current**
- NPC templates come from `CreateHumanoidModelFromDescription` with classic 2D `Shirt`/`Pants` and accessories only (`NPCService.luau:743–792`).
- No body parts, so they get the default **blocky** R15 body. Classic decal face (`:130`).
- Default R15 walk and idle (`507777826`, `507766388`; `:126–129`).
- 10–14 pedestrians in total (`:81–82`), with a 40-humanoid budget (`:70–71`).

**Why it reads as cheap.** Blocky R15 dummies with flat 2D clothing are the second-strongest "this is Roblox" signal after the sky. A street with 3 people on it is dead.

**Target**
- **Body:** proportioned bodies with dynamic heads and neutral expressions, and varied skin tones.
  - Free Roblox bundles compared visually (`img_gta/realism_gap_body_bundles_238_239_337.jpg`):
    - **"City Life Woman" (337)** has believable proportions;
    - "Man" (238) and "Woman" (239) are humanoid but still stylized. Bundle 238 includes Brown Hair 62234425, the accessory behind the §3.3 404, so leave its hair out.
    - Source: [catalog bundle details](https://catalog.roblox.com/v1/bundles/details?bundleIds=238&bundleIds=239&bundleIds=337).
  - Pick a male counterpart in the asset-sourcing pass (task #11). `BodyHeightScale` 1.05–1.10.
- **Clothing:** layered 3D clothing (jackets, hoodies, jeans, suits, uniforms) over the classic 2D shirts.
- **Animation:** a realistic walk, idle and run pack replacing `507777826` and `507766388`, plus phone, idle-smoke, cower, hands-up, flee and aim clips.
- **Density:** 30–60 pedestrians within about 300 studs downtown. Use client-animated lightweight rigs (AnimationController, no Humanoid state machine) to stay inside the budget.

### 2.13 UI (detailed spec in `gta_ui_language.md`)

**Current**
- Theme (`Theme.luau:7–33`): FredokaOne display font, Gotham body, hot pink (255,52,140) and cyan (0,214,255), 14 px corners, 3 px dark strokes.
- FredokaOne is also hard-coded in `MapBuilder.luau:90`, `PlotService.luau:129`, `LoadingScreen.client.luau:48` and `NotificationController.luau:437`.
- Layout:
  - a cash pill at top-centre with an emoji bill;
  - a left column of eight candy-coloured square buttons with "!" badges;
  - a 500×110 tutorial card at bottom-centre with a SKIP chip (`TutorialController.luau:677–679`, `CARD_BOTTOM` 186);
  - a Hot Drop banner at top-centre;
  - a rainbow-segment speedometer;
  - a "🏠 HOME" button;
  - "919 studs away".

**Why it reads as cheap.** These are the conventions of a kid simulator. In every screenshot the UI covers about 25% of the frame, in the centre, so it dominates the impression even before the world loads.

**Target.** Follow `gta_ui_language.md` §0:
- minimap bottom-left with health and armour bars;
- stars, cash and ammo top-right as outlined text;
- help text in a small black box top-left;
- Kanit Black, Oswald, Montserrat and Damion; no pink or cyan;
- distances in m or ft.
- Delete the left column, the cash pill and the HOME button.

### 2.14 Camera (cheap, and it changes how scale feels)

**Current:** Roblox default vertical FOV of 70; `CameraMaxZoomDistance` 90 (`default.project.json:26`).

**Target**
- On foot: vertical FOV 55–60 with a slight over-the-shoulder offset. A narrower FOV makes buildings and roads feel larger and less fish-eyed.
- In a car: a dynamic chase cam at 62–75 (VehicleClient already lerps FOV; retune it).
- Gravity of 196.2 studs/s² is about 5.6 g at 0.28 m per stud (`default.project.json:41`). That makes jumps and crashes snappy and toy-like.
  - This is a driving-feel decision for the vehicle wave, not a quick change: every chassis tune depends on it.
  - Flag it, and test 120–140 with retuned suspension.

---

## 3. Console errors from the operator run (job 0001)

The raw `console.txt` the operator mentions was **not committed**; only the summary in `job0001_report.md` exists in this repo. The exact ID list therefore cannot be reproduced here. Ask the operator to commit `console.txt` into `docs/v2/evidence/v1_real_engine/` on every job.

### 3.1 "Asset content representation is being generated" (about 170 warnings; the meshes did load)

**Which assets**
- The only 3D content fetched at boot is the **96 `source = "owned"` entries** in `Config/Assets.luau`:
  - 33 Hero car shells (`:28–60`);
  - 41 Props (`:65–105`);
  - 22 Buildings (`:122–143`).
- `AssetLibrary` loads them with `InsertService:LoadAsset` (`AssetLibrary.luau:146–160`).
- All 96 were uploaded **hours before the run** (2026-10-26/27) by `tools/upload_hero.py`, through Open Cloud, as a GLB turned into a `Model` (`upload_hero.py:19`; `assets/hero/manifest.json`).
- The 13 `store` props are years-old Creator Store models. All are AssetTypeId 10, checked through `economy.roblox.com/v2/assets/{id}/details`. They are not the cause.

**Cause**
- Roblox's content platform stores the uploaded source and derives runtime forms lazily: mesh LODs, GPU-compressed textures and so on. Roblox calls these "alternative content representations", or ACRs.
- On a cache miss it queues a transcoder job and, if no fallback format is ready, answers "Not ready – retry later". The client retries. Roblox describes this fallback as "part of the content contract", not an error.
- Source: Roblox's SIGGRAPH 2026 talk *SLIM: Scaling User-Generated 3D Worlds on Roblox* ([PDF](https://www.advances.realtimerendering.com/s2026/content/SMAK_SIG26_SLIM-Scaling_User-Generated_3D_Worlds_on_Roblox_8_Aug_2026.pdf), pp. on asset transcoders and ACRs).
- 96 brand-new models, each with a mesh and textures, fetched for the first time by a new Studio build, plus retries, gives roughly 170 lines.

**Impact**
- The warnings are benign and heal themselves once each ACR exists.
- But while they last, `AssetLibrary` waits up to `LOAD_TIMEOUT` = 20 s per asset (`Assets.luau:184`), and `MapDresser`, `PlotService` and `DealershipService` wait 25–30 s (`waitAll`).
- On the first server after an upload, players can see procedural placeholders or late pop-in.

**Fix**
1. In v2, most of these 96 meshes are on the kill list: blob AI buildings and props, and meme cars. Removing them from `Config/Assets` removes the warnings.
2. For v2 assets, **ship meshes inside the place**: Rojo-built `.rbxm` or MeshParts in packages. Do not `InsertService:LoadAsset` whole models at server boot.
3. After any upload, pre-warm it: the operator opens the place once and plays for about 60 s before screenshots or publishing.
4. Keep the procedural fallback, but log the IDs that time out, so the next report can list them.

### 3.2 "Asset type does not match requested type" (21 warnings; "old 91xxxxxxxx ids and others")

- The only `91…` IDs in `src` are the **16 ProSoundEffects sounds** in `Config/Sounds.luau:29–59`.
  - Examples: TireScreech 9119186024, Siren 9119165131, CityAmbience 9112758500.
  - The economy API returns AssetTypeId **3 (Audio)**, public domain, for every one, so the IDs themselves are valid.
- **Likely cause:** `SoundController.luau:1000–1012` preloads them with `ContentProvider:PreloadAsync(ids)` as **raw strings**.
  - The documented contract is "an array of instances to load" ([ContentProvider API](https://create.roblox.com/docs/reference/engine/classes/ContentProvider.md)); the docs' example preloads a `Sound` instance.
  - A bare string carries no asset type, so audio requested this way can be fetched as the wrong type.
  - 27 non-radio audio IDs are preloaded, which is in line with 21 warnings once cache hits are allowed for.
- **Fix:** build one `Sound` per definition (`SoundId = def.id`, not parented) and preload those instances.

### 3.3 404 on `Workspace.NPCs.Shopkeeper.Hat1.Handle.TextureId` = rbxassetid://81504106

- The economy API lists 81504106 as "TX_MaleChunk_Hero", **AssetTypeId 4 (Mesh)**, created by Roblox in 2012. The file it serves is actually a PNG of 71,938 bytes. So it is a texture registered under the wrong asset type, and the client's request for it as an image fails with a 404.
- The accessory that points at it is **62234425, "Brown Hair"** (2011, free, by Roblox). Its asset file holds an Accessory named `Hat1` whose Handle has MeshId 81504052 and TextureId 81504106. That matches the console path exactly. The salesman's fedora 19027209 is named `Fedora` and uses texture 18987684, so it is not the culprit. (Corrected in the Verification pass; the first draft blamed the fedora.)
- 62234425 is the `HairAccessory` for `car_salesman` and `chef_vendor` and their alternates (`NPCOutfits.luau:73, 81, 91, 99, 107`), and it is in the civilian hair pool (`:204`). All three shopkeepers are named "Shopkeeper" (`NPCService.luau:1576`).
- **Fix:** replace 62234425 everywhere in `NPCOutfits.luau`. v2 outfits will be re-curated anyway.

### 3.4 "Wrap-deformer fetching meshes resulted in error" (repeated)

- These are layered-clothing cage meshes that failed to fetch. v1 NPC outfits are classic 2D clothing plus rigid accessories, so the likely source is the operator's own avatar (`LoadCharacterAppearance` true) or a layered accessory.
- Harmless for now. Once v2 NPCs use layered clothing (§2.12), any template that logs this must be rejected at curation time.

### 3.5 DataStore 404 on `global/__studio_probe` and `p_<userId>`

Expected for a first-time player in Studio. Not a bug.

---

## 4. What carries over, and what to stop doing

- **Keep:** Future lighting; the NightGlow and StreetLight tag contract (`LightingService.luau:13–16`), which is a good mechanism with a wrong palette; the procedural-fallback pattern; the billboard pipeline; and the lab-proven street layout (52-stud road, 20-stud lamps, 12-stud floors).
- **Stop:**
  - colour in the grade;
  - Neon on structure;
  - SmoothPlastic as the default material;
  - any palette table named PASTEL, SHOP or NEON;
  - AI-generated 3D meshes for anything the player looks at closely;
  - "studs" in UI copy.

---

## 5. Prioritized fix list: biggest realism jump per hour

Hours are for one builder agent plus one operator verification pass. Jump is the expected visual improvement in the operator's street, elevated and skyline shots, judged against the GTA references.

| # | Change | Files | Est. hours | Jump | Why first |
|---|---|---|---|---|---|
| 1 | **Lighting v2 presets** (§2.2–2.4 tables): Ambient near 0, neutral tint, saturation ≤ +0.06, Haze ≤ 1.0, Offset ≥ 0.2, neutral night, 48-min cycle starting at 13:00, sun and moon sizes, and destroy duplicate Lighting children | `LightingService.luau` | 2–3 | ★★★★★ | Removes pink, purple and the fog wall, and restores shadows and depth. Fixes every screenshot. |
| 2 | **Kill Neon and pastel**: delete NeonEdge, Crown, Fin, CapTrim, CanopyEdge, pad rims and garage trims; replace PASTEL, SHOP and TOWER_GLASS with natural albedos ≤225; glass (40,52,62) with Reflectance 0.35 | `MapBuilder.luau`, `PlotService.luau`, `DealershipService.luau` | 2–3 | ★★★★ | Removes the "kids simulator" read from every frame. |
| 3 | **Ground materials and markings**: Asphalt, Pavement and Concrete built-ins (MaterialVariants later), neutral asphalt colour, US markings, curb strip, lots as terrain grass and pavers | `MapBuilder.luau` | 3–4 | ★★★★ | The ground is 40–60% of every gameplay frame. |
| 4 | **UI theme and layout swap** per `gta_ui_language.md` §0; tutorial moved to a top-left help box; left column, cash pill and HOME deleted; "studs" changed to m | `Theme.luau`, `Kit.luau`, `HUDController.luau`, `TutorialController.luau`, `EventsClient.luau` | 6–10 | ★★★★ | The UI covers about 25% of every screenshot, centre-screen. |
| 5 | **HDRI skyboxes ×3** plus clouds keyed per band | `LightingService.luau`, sky assets (task #8) | 3–4 | ★★★ | Removes the most recognizable Roblox signal and gives glass and paint real reflections. |
| 6 | **Remove AI blob meshes** from `Config/Assets` (buildings, props, meme hero shells) until kit replacements exist; also clears the §3.1 warnings | `Assets.luau` | 0.5 | ★★★ (as a removal) | Nothing smeared on screen; the procedural fallback, improved by #2 and #3, looks more grounded. |
| 7 | **Camera FOV** 55–60 on foot | camera controller | 0.5 | ★★ | Instantly makes the world feel bigger. |
| 8 | **Water, sand and grass colours** (§2.9–2.10) | `MapBuilder.luau` | 0.5 | ★★ | Cheap; removes the Caribbean cartoon cyan and lime. |
| 9 | **Street-furniture density**: tall cobra lamps with downward SpotLights, signals at every arterial intersection, parked-car density ×10 near players, utility poles | `MapBuilder.luau`, `StreetSpawnService.luau` | 8–12 | ★★★ | Makes streets read as lived in. |
| 10 | **Facade grammar kit and massing** (street walls, podium plus tower, rooftop clutter, emissive windows) | Blender kit (task #8), MapBuilder v2 | 3–5 days | ★★★★★ | The core of "GTA city"; depends on #11. |
| 11 | **Scale and layout v2**: road hierarchy, freeway, ≥6k-stud map, StreamingEnabled, hills | `Config/Map` v2 road graph, MapBuilder v2, traffic, NPC sidewalks | 5–8 days | ★★★★★ | Foundation for every v2 world wave; do it before mass art production. |
| 12 | **Realistic vehicles**: proportions, PBR paint with TintMask, wheels, lights; meme cars removed from the core pool | CarBuilder v2, car kit | 4–6 days | ★★★★ | Cars are the hero objects of a car-heist game. |
| 13 | **Realistic NPCs**: bodies, layered outfits, animation pack, 30–60 lightweight pedestrians | `NPCService.luau`, `NPCOutfits.luau` | 3–5 days | ★★★ | Blocky dummies kill realism up close. |
| 14 | **Vegetation**: tall Washingtonia palms, street trees, terrain hills | MapBuilder v2, foliage assets | 2–3 days | ★★★ | The LA silhouette. |
| 15 | **Console hygiene**: preload Sound instances, replace Brown Hair 62234425, ship meshes in-place, commit `console.txt` | `SoundController.luau`, `NPCOutfits.luau`, operator procedure | 1–2 | ★ | Clean logs; no pop-in. |

**Recommended order**
1. Items 1, 2, 3, 6, 7 and 8 in one "de-cartoon" pass, about 1.5 days.
2. Then item 4 (UI), in parallel with 5 (sky).
3. Then the v2 waves: 11 → 10 → 12 → 13 / 14 / 9.

Items 1–8 alone won't make v1 look like GTA. The city is still a toy-scale grid. But they remove every kill-list item that needs no new assets, and they give the v2 waves an honest baseline to compare against.

## 6. Verification (operator job proposal)

**Shots**
- Reuse the job 0001 cameras plus the lab cameras:
  - street at eye level, (12,7,−130) → (12,22,60);
  - elevated, (−190,150,−270);
  - skyline, (0,320,−760);
  - the overview at (0,900,900) **aimed at (0,0,0)**.
- Lock ClockTime at **13.0, 17.5 and 22.0** through the new `TimeOfDayLock` attribute.
- Before capturing, dump `Lighting:GetChildren()` with each child's class, name and properties.

**Pass criteria**
1. The overview shows the street grid and the downtown silhouette (contrast at least about 30% at 1,300 studs).
2. A white test plate at street level reads neutral within ±8 per channel at 13:00, and warm (R − B ≤ 60) at 17.5.
3. There is a visible cast shadow under the dealership canopy (shade-to-sun luminance ≤ 0.35).
4. At night, the lamps and windows are the brightest things in frame and the sky is not violet.
5. Each shot is placed side by side with a GTA reference in `img_gta/`, per the lead direction's evidence standard.

---

## Sources

- Roblox Atmosphere API (properties; "Density … the more in-game objects/terrain will be obscured"; Offset; Decay needs Haze and Glare above 0): https://create.roblox.com/docs/reference/engine/classes/Atmosphere.md
- Roblox atmospheric effects guide (Offset: a low value "blends distant objects into the sky"; Haze, Color and Decay examples): https://create.roblox.com/docs/en-us/environment/atmosphere.md
- Atmosphere defaults (Density 0.395; Color 200,170,108; Decay 92,60,14): https://robloxapi.github.io/ref-temp/class/Atmosphere.html
- Roblox Lighting API (Ambient defaults to black and is for sky-occluded areas; OutdoorAmbient default 127): https://create.roblox.com/docs/reference/engine/classes/Lighting.md
- Roblox ContentProvider API (`PreloadAsync` takes "an array of instances to load"; the example preloads `Sound` and `Decal` instances): https://create.roblox.com/docs/reference/engine/classes/ContentProvider.md
- Roblox AlphaMode enum (`TintMask` tints by `SurfaceAppearance.Color`): https://create.roblox.com/docs/reference/engine/enums/AlphaMode.md
- Roblox, SIGGRAPH 2026, *SLIM: Scaling User-Generated 3D Worlds on Roblox* (alternative content representations, "Not ready – retry later"): https://www.advances.realtimerendering.com/s2026/content/SMAK_SIG26_SLIM-Scaling_User-Generated_3D_Worlds_on_Roblox_8_Aug_2026.pdf
- The stud is defined as 0.28 m (April 2019): https://roblox.fandom.com/wiki/Stud_(unit)
- Poly Haven HDRIs (pure-sky list) and textures (asphalt, concrete, brick, stucco, plaster, all CC0): https://api.polyhaven.com/assets?t=hdris&c=skies and https://api.polyhaven.com/assets?t=textures
- Roblox economy asset details. Checked IDs: 16 ProSoundEffects audio (type 3), 81504106 (type 4 Mesh, but the file is a PNG), 62234425 "Brown Hair" (type 41), 19027209, 96678446 and 10476359 (type 8 Hat), and the 13 store props (type 10). Endpoint: `https://economy.roblox.com/v2/assets/{id}/details`
- Roblox catalog bundles 238 "Man", 239 "Woman" and 337 "City Life Woman" (free, by Roblox), with thumbnails saved to `img_gta/realism_gap_body_bundles_238_239_337.jpg`: https://catalog.roblox.com/v1/bundles/details?bundleIds=238&bundleIds=239&bundleIds=337
- In-repo: `docs/v2/evidence/v1_real_engine/*`, `docs/v2/evidence/lighting_lab_0002_*`, `studio/jobs/0002-lighting-lab.md`, `docs/v2/research/references.md`, `docs/v2/research/gta_ui_language.md`, `docs/v2/proto/buildkit/_iter/midtown_v1.png`.
