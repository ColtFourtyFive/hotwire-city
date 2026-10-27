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
  `prep_materials.py`). `Look.TerrainColors[base]` is the same for `Terrain:SetMaterialColor`.
- Tintable: `HC_Stucco` (and plaster) is near-white; colour each building with Part.Color (pastels, LA beige).

## Materials (22 variants, 61 images)

Overrides (global, `MaterialService.<Material>Name`): Asphalt, Pavement, Concrete, Brick, Plaster, ClayRoofTiles,
Pebble, CorrodedMetal, WoodPlanks, Grass, LeafyGrass, Ground, Sand, Rock, Slate, Marble (16). Per-part only (set
`Material` = base and `MaterialVariant` = name): HC_AsphaltWorn, HC_AsphaltWet, HC_ConcreteModern, HC_BrickTan,
HC_CorrugatedMetal, HC_WindowGlass.

- **No `GlassName` exists** (API dump 0.744: MaterialService has no Glass/Neon/ForceField slots), so there is no global
  glass look. `HC_WindowGlass` is an opaque reflective facade glass (roughness ≈ 0.07, metalness ≈ 0.25) on
  **SmoothPlastic**: use `Material = SmoothPlastic`, `MaterialVariant = "HC_WindowGlass"`, Color (45, 55, 63). Keep
  `Enum.Material.Glass` for see-through glass (car windows, shop windows you look into).
- **`MetalName` is deliberately not overridden**: v1 and v2 use Metal for lamp poles, mullions, car parts and guns, and
  a corrugated sheet on all of them would be wrong. `HC_CorrugatedMetal` is per-part.
- `HC_GrassLeafy` and `HC_RockSlate` reuse HC_Grass / HC_Rock images (no extra uploads), only BaseMaterial differs.
- `HC_AsphaltWet` reuses HC_Asphalt colour + normal with a wet roughness map (puddles). `Look.WetStreets` can swap the
  Asphalt override at night with `MaterialService:SetBaseMaterialOverride` (off until lab round 2 judges it).
- StudsPerTile = real tile size (m) / 0.28. Terrain uses the same StudsPerTile, so terrain materials use bigger tiles.
- Normals are OpenGL (+Y/green up): sources are ambientCG `NormalGL` / Poly Haven `nor_gl`; procedural ones come from
  `lookcommon.height_to_normal`. The lit contact sheet (light from the upper left) shows bumps lit on their top edge.

Decals (20 images, `Look.Decals`): pre-coloured white/yellow paint with wear in alpha: solid/dashed/double lines (tile
along V with `Texture.StudsPerTileV`), stop bar, continental crosswalk bars, five lane arrows; manhole, two asphalt
damage patches, crack network, tar snakes, two oil stains, wall grime streaks. Decal/Texture `Color3` still multiplies.

## Skies (4 skies, 24 images)

| Sky | HDRI (Poly Haven, CC0) | Up |
|---|---|---|
| day | `kloofendal_48d_partly_cloudy_puresky` | 08:42–15:48 |
| golden | `kloppenheim_06_puresky` | 05:57–08:42, 15:48–18:06 |
| blue | `qwantani_dusk_2_puresky` | 05:00–05:57, 18:06–19:30 |
| night | `kloppenheim_07_puresky` | 19:30–05:00 |

- Face mapping is the engine-verified one (`docs/v2/research/sky_orientation.md`): Ft −Z, Bk +Z, Lf +X, Rt −X (upright,
  not mirrored), Up image-top → +X, Dn image-top → −X. The equirect centre maps to −Z and the panorama is not mirrored.
  The cross sheets show Up as stored-rotated-90°-CW and Dn as stored-rotated-90°-CCW so every edge meets.
- Grading per sky: exposure, ACES filmic, desaturation, a whiter/hazier horizon band (GTA midday), the HDRI sun disc
  dimmed to its surroundings (no double sun), and a haze-colour fill below the horizon (the puresky lower half is a
  mirror of the sky).
- `glowAzimuth` (0 = −Z, 90 = +X) is the HDRI's sun / brightest region. LightingService sets
  `SkyboxOrientation.Y = yawSign × (glowAzimuth − engine sun azimuth)` using `Lighting:GetSunDirection()`, so the glow
  sits under the engine sun. `yawSign = +1` assumes the `CFrame.Angles(0, y, 0)` convention; studio job 0007 step S0
  verifies it.
- Swaps are scheduled where they are hardest to see: blue ↔ night in the dark, golden ↔ blue with the sun below the
  horizon (Roblox's sun rises at 06:00 and sets at 18:00), day ↔ golden under a short capped haze bump
  (`Look.SkySwap`). A Sky cannot cross-fade, so day ↔ golden is the visible one; lab round 2 judges it.

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
Rojo versions understand (`rokit.toml` pins 7.6.1; not re-verified here because only 7.7.1 is installed).

Open question kept for lab round 2: with `Technology` absent from the file, the engine should take `LightingStyle` /
`PrioritizeLightingQuality` as written. Job 0007 step 9 reads them back with `inspect_instance` after a publish.

## Asset ids

All 105 images are uploaded as `assetType = Image` to user 11686693147 (`upload.py` polls the operation for the
`assetId`). Moderation starts as `Reviewing`; `python3 tools/look/upload.py --status` refreshes it. The ids live in the
manifests and in `src/shared/Config/Look.luau` (generated), and the default (day) sky + every MaterialVariant are baked
into `default.project.json`.
