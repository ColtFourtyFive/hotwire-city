# tools/look: materials, decals, skies and lighting for the v2 look

Pipeline for PLAN decision 3 ("materials, sky and lighting live in the place file"). Everything here is reproducible
from CC0 sources (ambientCG, Poly Haven; picks from `docs/v2/research/cc0_assets.md`).

| Step | Command | Output |
|---|---|---|
| 1. Materials + decals | `python3 -I tools/look/prep_materials.py --src <cc0 tex dir> [--fetch]` | `assets/materials/<key>/{color,normal,roughness[,metalness]}.png`, `assets/materials/decals/*.png`, `assets/materials/materials.json`, `docs/v2/early/look/{materials_sheet,materials_maps,decals_sheet}.png` |
| 2. Skies | `python3 -I tools/look/hdri_to_skybox.py --hdri-dir <dir> [--cache <dir>] [--fetch]` | `assets/sky/<sky>/{ft,bk,lf,rt,up,dn}.png`, `assets/sky/skies.json`, `docs/v2/early/look/sky_<sky>_cross.png` |
| 3. Upload | `python3 tools/look/upload.py [--jobs 4]` (`--status` refreshes moderation) | `assets/materials/manifest.json`, `assets/sky/manifest.json` (Image asset ids) |
| 4. Bake into the place | `python3 tools/look/gen_project.py` (`--check` = dry run, exit 1 on diff) | `default.project.json` → `MaterialService` + `Lighting` only; `src/shared/Config/Look.luau` generated block |
| 5. Verify the built place | `rojo build -o build/HotwireCity.rbxlx && lune run tools/look/verify_place.luau` | prints `OK` or the problems |
| Engine probe (once, or after an engine change) | `python3 tools/look/sun_probe.py` | `tools/look/sun_probe_result.json`: real-engine sun/moon directions, terrain-colour material support, a few defaults |

`--src` holds `ACG/<Id>/<Id>_1K-JPG_<Map>.jpg` and `PH/<id>/<id>_<map>_1k.jpg`; `--hdri-dir` holds Poly Haven
`<id>_4k.hdr` (4096 × 2048 → 1024 px per 90° face). `--fetch` downloads whatever is missing. Run the Python tools with
`-I` (they read downloaded files); they add their own folder to `sys.path` explicitly.

## Colour contract (read this before colouring parts)

Roblox multiplies a MaterialVariant's ColorMap by `BasePart.Color` (terrain: by the terrain material colour), exactly
like its own 2022 materials. Measured: Roblox's built-in colour maps are bright near-neutral detail maps (Brick mean
(223, 208, 197), Asphalt (225, 226, 227), downloaded asset 9920482813 / 9930003046). Our maps follow the same rule, so
the MaterialService **base-material overrides are drop-in**: parts already coloured for built-in materials keep their
colour, and get our PBR detail.

- Each map = graded source ÷ its (partly neutralised) mean × a bright target (≈ 0.8). `hue_remove` sets how much of
  the source's own hue moves into Part.Color (1 = neutral map: asphalt, concrete, stucco; ~0.5 keeps brick/mortar,
  rust/zinc, roof-tile variation in the map).
- `Look.Materials[name].color` is the Part.Color that reproduces the art-directed average albedo (`look` in
  `prep_materials.py`). `Look.TerrainColors[base]` is the same for `Terrain:SetMaterialColor`, only for materials the
  terrain accepts (engine probe: ClayRoofTiles, CorrodedMetal, Marble, Pebble and Plaster are "Invalid terrain
  material"). **LightingService applies them after MapBuilder**, together with `Look.Water` (deep green-blue,
  reflectance 1): the world builder should not set terrain material colours or water itself.
- Tintable: `HC_Stucco` (and plaster) is near-white; colour each building with Part.Color (pastels, LA beige).

## Materials (22 variants, 65 images)

Overrides (global, `MaterialService.<Material>Name`): Asphalt, Pavement, Concrete, Brick, Plaster, ClayRoofTiles,
Pebble, CorrodedMetal, WoodPlanks, Grass, LeafyGrass, Ground, Sand, Rock, Slate, Marble (16). Per-part only (set
`Material` = base and `MaterialVariant` = name): HC_AsphaltWorn, HC_AsphaltWet, HC_ConcreteModern, HC_BrickTan,
HC_CorrugatedMetal, HC_WindowGlass.

- **No `GlassName` exists** (API dump 0.744: MaterialService has no Glass/Neon/ForceField slots), so there is no global
  glass look. `HC_WindowGlass` is an opaque **mirror-coated** facade glass (metalness ≈ 1, roughness ≈ 0.06) on
  **SmoothPlastic**: use `Material = SmoothPlastic`, `MaterialVariant = "HC_WindowGlass"`, Color (118, 132, 147). With
  metalness 1 the Part.Color is the reflection tint, so the facade shows a lightly blue-grey tinted sky; a dark
  dielectric (the first version: metalness 0.25 on (45, 55, 63)) only reflects ~4 % and reads as flat slate. Keep
  `Enum.Material.Glass` for see-through glass (car windows, shop windows you look into).
- **`MetalName` is deliberately not overridden**: v1 and v2 use Metal for lamp poles, mullions, car parts and guns, and
  a corrugated sheet on all of them would be wrong. `HC_CorrugatedMetal` is per-part.
- `HC_GrassLeafy` reuses the HC_Grass images (only BaseMaterial differs). `HC_RockSlate` has its own grey layered cliff
  rock (ambientCG Rock030), so Slate cliffs no longer look exactly like the tan HC_Rock.
- Large tiles where repetition shows: HC_Asphalt 4.5 m (16 studs) with soft tileable tone patches (`macro`) so a road is
  not a uniform slab (8 × 8 block variation 5.4/255, was 1.4); HC_AsphaltWorn 4 m with its baked full-height crack
  removed (`decrack`) and its own blotches flattened (`flatten`): cracks come from the `crack_network` / `tar_snakes`
  decals (put them as Textures on roads, 24–30 studs per tile); HC_Rock 9 m (32 studs) so fracture shapes do not repeat
  up a cliff.
- `HC_AsphaltWet` shares HC_Asphalt's normal and has its own **darker** colour map (× 0.75, puddles a little darker)
  plus a wet roughness map, and uses HC_Asphalt's Part.Color: `Look.WetStreets` only swaps the Asphalt override
  (`MaterialService:SetBaseMaterialOverride`, never Part.Color), so the darkening has to live in the map. Off until lab
  round 2 judges it; when on it switches at NightFactor 0.6 ± 0.05 and is applied at server start too.
- StudsPerTile = real tile size (m) / 0.28. Terrain uses the same StudsPerTile, so terrain materials use bigger tiles.
- Normals are OpenGL (+Y/green up): sources are ambientCG `NormalGL` / Poly Haven `nor_gl`; procedural ones come from
  `lookcommon.height_to_normal`. The lit contact sheet (light from the upper left) shows bumps lit on their top edge.

Decals (20 images, `Look.Decals`): pre-coloured white/yellow paint with wear in alpha: solid/dashed/double lines (tile
along V with `Texture.StudsPerTileV`), stop bar, continental crosswalk bars, five lane arrows; a plain procedural
manhole (the ambientCG scan carried an embossed foundry brand, so it is no longer used), two asphalt damage patches,
crack network, tar snakes, two oil stains, wall grime streaks. Decal/Texture `Color3` still multiplies.

## The engine sun (measured)

`tools/look/sun_probe.py` ran `Lighting:GetSunDirection()` in the real engine (Open Cloud Luau Execution) at latitudes
0 / 23.5 / 34 / 41.733 and 28 ClockTimes (`sun_probe_result.json`). Roblox moves the sun on a circle about the
horizontal Z axis: `dir = (cos φ cos θ, cos φ sin θ, sin φ)`, φ = latitude − 23.5°, θ = 15° × (ClockTime − 6). So:
sunrise 06:00 near +X and sunset 18:00 near −X at **every** latitude; at latitude 34 the sun culminates at 79.5° toward
+Z and its azimuth sweeps ~70–80° per game hour around noon; the moon is the sun's antipode. `Config/Look.Sun` +
`LightingService.sunDirectionAt` reproduce every sample within 0.2° (tested), and LightingService checks the live
engine against the model at boot (Lighting attribute `SunModelError`).

## Skies (4 skies, 24 images)

| Sky | HDRI (Poly Haven, CC0) | Up | Sun elevation | Stars / sun-moon discs / volumetric clouds |
|---|---|---|---|---|
| day | `kloofendal_48d_partly_cloudy_puresky` | 07:15–16:45 | ≥ 18.4° | 0 / yes / 0 (painted cumulus) |
| golden | `kloppenheim_06_puresky` | 05:57–07:15, 16:45–18:06 | −0.7…18.4° | 0 / yes / 0 |
| blue | `qwantani_dusk_2_puresky` | 05:00–05:57, 18:06–19:30 | below the horizon | 0 / yes / 1 |
| night | `kloppenheim_07_puresky` | 19:30–05:00 | below the horizon | 0 / no (moonlit deck) / 0 |

- Face mapping is the engine-verified one (`docs/v2/research/sky_orientation.md`): Ft −Z, Bk +Z, Lf +X, Rt −X (upright,
  not mirrored), Up image-top → +X, Dn image-top → −X. The equirect centre maps to −Z and the panorama is not mirrored.
  The cross sheets show Up as stored-rotated-90°-CW and Dn as stored-rotated-90°-CCW so every edge meets.
- Grading per sky: exposure, ACES filmic, desaturation, a whiter/hazier horizon band (GTA midday), the HDRI sun disc
  dimmed to its surroundings (no double sun), and a haze-colour fill below the horizon (the puresky lower half is a
  mirror of the sky). The day sky is also desaturated to 0.65 with an 18° horizon band and a 0.18 `lift` of the whole
  dome toward the haze colour, so the anti-sun side is a milky (90, 97, 120) instead of deep navy (55, 68, 109).
- `glowAzimuth` (0 = −Z, 90 = +X) is the HDRI's sun / brightest region, `horizonGlowAzimuth` the brightest part of the
  0–6° band. A following sky (`followSun`) gets `SkyboxOrientation.Y = yawSign × (glowAzimuth − engine sun azimuth)`
  from `Lighting:GetSunDirection()` (the model when headless), eased at most `Look.SkyStyle.maxYawRate` = 0.3°/s on
  the 4 Hz clock tick (reads as cloud drift; the day sky lags the noon azimuth sweep and catches up in the afternoon;
  swaps and admin clock jumps snap). The night sky does not follow: its warm city glow is parked on
  `fixedGlowAzimuth` = 90 (+X, inland; the Palmera Beach ocean horizon is −X). `yawSign = +1` assumes the
  `CFrame.Angles(0, y, 0)` convention; studio job 0007 step S0 verifies it.
- Swaps are scheduled where they are hardest to see: blue ↔ night in the dark, golden ↔ blue with the sun just below
  the horizon (measured 06:00 / 18:00), day ↔ golden at sun elevation 18.4° under a short capped haze bump
  (`Look.SkySwap`), with the light already ~80 % golden. The golden HDRI (its own sun at 8°) is never up under a high
  engine sun. A Sky cannot cross-fade, so day ↔ golden is the visible one; lab round 2 judges it. Volumetric cloud
  cover follows each sky's `clouds` share, blended over ± 0.3 h around a swap.
- `src/client/Controllers/LookClient.luau` preloads every sky's faces (`ContentProvider:PreloadAsync`, the next sky
  first) a few seconds after joining, so the first swap on a client does not stream six 1024 px faces live.

## Property names and value formats (verified)

Verified with `rojo build` (Rojo 7.7.1, this container) on a probe project and on the real `default.project.json`
(`tools/look/verify_place.luau` reads the built `.rbxlx` with `@lune/roblox`), and against the engine API dump
`0.744.0.7441077` (the operator's Studio build).

| JSON (`default.project.json`) | Value format | In the built place | API notes |
|---|---|---|---|
| `MaterialVariant.BaseMaterial` | `"Asphalt"` (enum item name) | `<token name="BaseMaterial">` | write PluginSecurity: file-only |
| `MaterialVariant.ColorMap` / `NormalMap` / `RoughnessMap` / `MetalnessMap` | `"rbxassetid://<Image id>"` | migrated to `ColorMapContent` … `<Content><uri>` | PluginSecurity read+write: game scripts cannot even read them |
| `MaterialVariant.StudsPerTile` | number | `<float>` | scriptable |
| `MaterialVariant.MaterialPattern` | `"Regular"` / `"Organic"` | `<token>` 0 / 1 | scriptable |
| `MaterialService.<Material>Name` | `"HC_…"` | `<string>` | RobloxSecurity, NotScriptable: file-only; runtime uses `SetBaseMaterialOverride` |
| `MaterialService.Use2022Materials` | `true` | migrated to `Use2022MaterialsXml` | |
| `Lighting.LightingStyle` | `"Realistic"` | `<token>` 0 (Realistic = 0, Soft = 1) | exists in 0.744; research says not settable by game scripts |
| `Lighting.PrioritizeLightingQuality` | `true` | `<bool>` | exists in 0.744 |
| `Lighting.Technology` | **removed** | absent | Deprecated, RobloxScriptSecurity; Unified Lighting maps it on load (Future → Realistic + quality). We no longer write it at runtime or in the file |
| `Lighting.Ambient` etc. (Color3) | `[r, g, b]` floats 0..1 | `<Color3>` | |
| `Sky.SkyboxBk` … `SkyboxUp` | `"rbxassetid://<Image id>"` | migrated to `SkyboxBackContent` … | Image ids only: Decal ids fail with 403 IncorrectAssetType |
| `Sky.SkyboxOrientation` | `[x, y, z]` degrees | `<Vector3>` | scriptable; Y applied first |

The legacy names (`ColorMap`, `SkyboxBk`) are used on purpose: Rojo 7.7.1 migrates them, and they are the names older
Rojo versions understand. The pinned Rojo 7.6.1 (`rokit.toml`) also builds the project and `verify_place.luau` passes
on its output; 7.6.1 writes the Sky faces under the legacy `SkyboxBk`… names, which still load.

Open question kept for lab round 2: with `Technology` absent from the file, the engine should take `LightingStyle` /
`PrioritizeLightingQuality` as written. Job 0007 step 11 reads them back with `inspect_instance` after a publish.

## Night windows (runtime, `Look.Windows`)

Parts tagged **`LitWindow`** (the v2 contract: an emissive panel 0.5–1 stud behind the glass) and, while v1 buildings
exist, `NightGlow` parts whose `DayMaterial` is Glass, light up over dusk: a deterministic position hash picks ~50 % of
them, 70 % warm (255, 196, 136) / 30 % cool (214, 226, 255), brightness 0.55–1.0 and a per-window NightFactor
threshold in 0.15–0.9, so the city fills in instead of switching at once. Unlit and by day they show their
`DayColor` / `DayMaterial` (captured on first sight). `LitWindowColor` (Color3 attribute) overrides the colour.

## Asset ids

All 109 images (65 material maps, 20 decals, 24 sky faces) are uploaded as `assetType = Image` to user 11686693147
(`upload.py` polls the operation for the `assetId`; re-runs only upload images whose sha1 changed). Moderation starts
as `Reviewing`; `python3 tools/look/upload.py --status` refreshes it. The ids live in the manifests and in
`src/shared/Config/Look.luau` (generated), and the default (day) sky + every MaterialVariant are baked into
`default.project.json`.
