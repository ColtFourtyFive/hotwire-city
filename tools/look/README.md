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
engine against the model at boot (Lighting attribute `SunModelError`). These functions take an **engine** ClockTime
(see the engine clock below).

## Game time vs engine clock (lab round 2)

Job 0007 found that the engine **blacks out any skybox once its sun is well below the horizon**. At ClockTime 22.5 the
night sky is pure black, and at 18.7 (sun −10°) the blue hour is near-black and purple. The same night sky renders
moonlit clouds and a warm city glow at 14.2. So the game time of day and `Lighting.ClockTime` are decoupled
(`Look.EngineClock`, `LightingService.engineClockAt`):

- The **game hour** is the truth for every system. It drives the 24-minute cycle, the Workspace attributes
  `TimeOfDay` (0–24) and `NightFactor`, the street lights, lit windows, the presets and the sky schedule.
  `LightingService.getClockTime()` returns it.
- The **engine clock** equals the game hour by day (06:27–17:33). From the late golden hour it eases into the evening
  hold of 18.2, with the sun at −3° in the west. The ease is C1, so the sun slows to a stop and never visibly halts.
  - The engine sunset lands at game 18:08 and the sunrise at game 05:52.
  - At game midnight (`jumpHour`, NightFactor 1) the clock jumps in a single write to the morning hold of 5.8, with
    the sun at −3° in the east. It holds there and then eases back onto the game clock by 06:27.
  - The engine never renders the sun below −5°. The jump is one write and sits under the exposure dip. The fixed night
    sky is up during the jump, so nothing spins. All of this is tested tick by tick over a whole cycle.
- **The night is faked** by the blue-hour and night presets, because the held engine only renders early twilight.
  The presets use:
  - negative `ExposureCompensation`;
  - a faint key light (`Brightness` 0.4);
  - low, cool `Ambient` and `OutdoorAmbient`, which darken the world but not the sky;
  - a cool `ColorCorrection` desaturated by 0.12.

  The night HDRI stays visible above a thin haze (Haze 0.35, Density 0.2). Twilight and night haze, decay and cloud
  colours are neutral blue-grey with red never above green, so there is no magenta. The old blue hour used a mauve
  (132, 130, 142) haze.
- The Workspace attribute `EngineClockOverride` (hours) pins the engine clock without touching the game hour. Use it to
  compare holds from 18.0 to 18.3 in Play mode. `TimeOfDayLock` still locks the game hour, so locking it at 22.5 now
  renders ClockTime 18.2.
- **Still to check in the engine** (next lab round):
  - the moon and key light at the held clock: with the sun at −3°, the moon is at +3° on the opposite side;
  - the shadow direction flipping at the midnight jump;
  - the starting values of the night presets.

## Atmosphere (locked)

Lab round 2, step S1:
- Offset had no visible effect at Density 0.27; captures at 0 and 1.0 were pixel-identical.
- Haze 0.8 with Offset 0.25 was the best pair.

These are locked for the sunlit presets (day and both goldens) in `Look.AtmosphereLock`. Density stays ≤ 0.30. The
blue-hour and night presets use the same Offset with a lower Haze. The old haze bump at sky swaps is gone.

`default.project.json` still bakes day Haze 0.9. LightingService writes 0.8 at init. Re-run
`python3 tools/look/gen_project.py` on the branch that owns the project file; `--check` currently reports only this.

## One of each Lighting child (Team Create)

Rojo live-sync cannot apply the `Lighting` node ("Cannot change Parent of type Lighting"). A Team Create session
therefore ends up with duplicate Sky, Atmosphere, Bloom and SunRays children, and `LightingStyle` reads Soft. Those
place-file settings only arrive through a real publish.

`LightingService.dedupe()` keeps exactly one Sky, Atmosphere, BloomEffect, ColorCorrectionEffect and SunRaysEffect:
- The keeper is the instance it already owns (attribute `HCLookOwned`), otherwise the place file's instance by name,
  otherwise the first one.
- It destroys the extras and re-enables the kept post effects.
- It runs at init and again (deferred) whenever one of those classes is added to Lighting.

## Skies (4 skies, 24 images; 3 scheduled)

Times are **game** time. Sun elevations are the **engine** sun.

| Sky | HDRI (Poly Haven, CC0) | Up | Engine sun | Stars / sun-moon discs / volumetric clouds |
|---|---|---|---|---|
| day | `kloofendal_48d_partly_cloudy_puresky` | 05:39–18:21 | ≥ −1.5° | 0 / yes / 0 (painted cumulus) |
| golden | `kloppenheim_06_puresky` | **not scheduled** (see below) | — | 0 / yes / 0 |
| blue | `qwantani_dusk_2_puresky` | 05:00–05:39, 18:21–19:30 | −1.5…−3° | 0 / yes / 1 |
| night | `kloppenheim_07_puresky` | 19:30–05:00 | −3° (held) | 0 / no (moonlit deck) / 0 |

- Face mapping is the engine-verified one (`docs/v2/research/sky_orientation.md`): Ft −Z, Bk +Z, Lf +X, Rt −X (upright,
  not mirrored), Up image-top → +X, Dn image-top → −X. The equirect centre maps to −Z and the panorama is not mirrored.
  The cross sheets show Up as stored-rotated-90°-CW and Dn as stored-rotated-90°-CCW so every edge meets.
- Grading per sky: exposure, ACES filmic, desaturation, a whiter/hazier horizon band (GTA midday), the HDRI sun disc
  dimmed to its surroundings (no double sun), and a haze-colour fill below the horizon (the puresky lower half is a
  mirror of the sky). The day sky is also desaturated to 0.65 with an 18° horizon band and a 0.18 `lift` of the whole
  dome toward the haze colour, so the anti-sun side is a milky (90, 97, 120) instead of deep navy (55, 68, 109).
- `glowAzimuth` (0 = −Z, 90 = +X) is the HDRI's sun or brightest region. `horizonGlowAzimuth` is the brightest part of
  the 0–6° band.
- A following sky (`followSun`) gets `SkyboxOrientation.Y = yawSign × (glowAzimuth − engine sun azimuth)`:
  - The sun comes from `Lighting:GetSunDirection()`, or from the model at the engine clock when headless.
  - The yaw is eased at most `Look.SkyStyle.maxYawRate` = 0.3°/s on the 4 Hz clock tick, which reads as cloud drift.
    The day sky lags the noon azimuth sweep and catches up in the afternoon.
  - Swaps and admin clock jumps snap.
- The night sky does not follow. Its warm city glow is parked on `fixedGlowAzimuth` = 90 (+X, inland); the Palmera
  Beach ocean horizon is −X.
- **`yawSign = +1` is confirmed in the engine** (job 0007 S0): yaw 0 shows Ft, yaw 90 shows Lf, and nothing is
  mirrored.
- **Four swaps a day, all with the engine sun below the horizon** (`Look.SkySchedule`):
  - night → blue in the dark (05:00, NightFactor 0.99);
  - blue → day just before the engine sunrise (05:39, sun −1.5°);
  - day → blue just after the engine sunset (18:21, sun −1.5°);
  - blue → night in the dark (19:30).

  Each swap, and the engine-clock jump, sits on a short `ExposureCompensation` dip (`Look.SkySwap`: 0.2 EV, gaussian
  ± 0.25 game h, about 20 s at dusk). Volumetric cloud cover follows each sky's `clouds` share, blended over that width.
- **No golden sky.** Lab round 2 S3 saw the day ↔ golden swap clearly, straight through a Haze 1.2 bump. The facades
  shifted with it too, because the sky feeds ambient and specular light.
  - A Sky cannot cross-fade, and that swap has to happen with the sun up: the golden HDRI paints its sun glow at 8°.
  - Moving the swap to the horizon would keep golden up for only a minute of twilight. It would also add two swaps
    and put an 8° glow over a set sun.
  - So the day sky stays up from sunrise to sunset. The golden hour comes from the presets: a warm low key light, a
    warm Atmosphere colour and glare on the horizon band, and a warm grade, all under the milky, desaturated day dome.
  - The golden faces stay in the generated data but are neither scheduled nor preloaded.
- `src/client/Controllers/LookClient.luau` preloads the faces of every **scheduled** sky a few seconds after joining
  (`ContentProvider:PreloadAsync`, next sky first). This way the first swap on a client does not stream six 1024 px
  faces live.

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

Job 0007 read `LightingStyle` back as Soft and `PrioritizeLightingQuality` as true in a Team Create session where
Rojo live-sync had failed on the Lighting node (see "One of each Lighting child"). `LightingStyle` from the file only
arrives through a real publish. Read it back again after the next publish.

## Night windows (runtime `Look.Windows`, building guidance `Look.Night.windowEmissive`)

Lab round 2 S6 found the windows too strong. Neon at colour × 0.55–1.0 under the night Bloom turned ribbon windows into
glowing slabs. Each v1 glass tower is one part, so it lit as a whole glowing column.

The rules now:
- **Light individual window cells, never whole facades.** The lit cells are picked at random: about 40 %, 70 % warm
  (255, 196, 136) and 30 % cool (214, 226, 255). The lab judged a ~35 % share and the 70 / 30 mix as reading
  correctly.
- **Dim surfaces.** The recommended lit cell is `SmoothPlastic` (or `Glass`) with colour = warm or cool × 0.75–1.0,
  faded in by NightFactor. These materials are not self-lit, so a lit cell can never bloom into a slab.
- **Neon only for small cells** (largest face ≤ 80 studs², e.g. a panel behind glass), and only at colour × 0.25–0.4.
  The night Bloom threshold is now 1.25, with intensity 0.7.

What LightingService does with these rules:
- **LitWindow parts** (the v2 contract: an emissive panel 0.5–1 stud behind the glass) and, while v1 buildings exist,
  **`NightGlow` parts whose `DayMaterial` is Glass** light up over dusk.
- A deterministic position hash picks which of them light, warm or cool, their brightness level, and a per-window
  NightFactor threshold in 0.15–0.9, so the city fills in instead of switching at once.
- A cell lights as dim Neon (× 0.25–0.4). A facade-sized part lights as `SmoothPlastic` (× 0.75–1.0) and is never Neon.
- Unlit and by day, parts show their `DayColor` / `DayMaterial` (captured on first sight). The `LitWindowColor`
  attribute (Color3) overrides the colour.

**For the building package:** tag each window cell `LitWindow` and LightingService handles it. Or build the cells
yourself with `LightingService.windowEmissiveColor(x, y, z, nightFactor, dayColor?, material?)`:
- It returns whether that cell is lit (the same pick as the tag system) and its colour at that NightFactor.
- The day colour fades to warm or cool × factor over NightFactor 0.15–0.9. `material = "Neon"` selects the dim
  factor range.
- Update it as `NightFactor` (a Workspace attribute) moves, or quantise. The config lives in
  `Look.Night.windowEmissive`.

## Asset ids

All 109 images (65 material maps, 20 decals, 24 sky faces) are uploaded as `assetType = Image` to user 11686693147
(`upload.py` polls the operation for the `assetId`; re-runs only upload images whose sha1 changed). Moderation starts
as `Reviewing`; `python3 tools/look/upload.py --status` refreshes it. The ids live in the manifests and in
`src/shared/Config/Look.luau` (generated), and the default (day) sky + every MaterialVariant are baked into
`default.project.json`.
