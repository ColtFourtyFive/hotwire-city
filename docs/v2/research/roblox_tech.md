# Roblox engine techniques for GTA-grade realism at city scale (2025–2026)

*Research note for Hotwire City v2, written 2026-10-27. It answers "what can the Roblox engine actually do, how is each thing set, and what will bite us", for the grounded GTA V look in `00_LEAD_DIRECTION.md`.*

## How to read this note

**Sources**, used in this order of trust:
1. The live create.roblox.com docs, snapshot of 2026-10-27.
2. The engine API dump `0.744.0.7441077`. This is the same build the Studio operator runs (see `docs/v2/evidence/lighting_lab_0002_report.md`).
3. Rojo build tests run in this container with `rojo 7.7.1`.
4. Official DevForum announcements, cited by thread.

**Confidence tags:**

| Tag | Meaning |
|---|---|
| **[DOC]** | Stated in the official docs. |
| **[DUMP]** | Read from API-dump security, capability or serialization flags. |
| **[ROJO]** | Tested here with `rojo build`. |
| **[ANN]** | Stated in an official DevForum announcement. |
| **[EVID]** | Seen by our operator in real Studio. |
| **[UNVERIFIED]** | My inference. It needs an operator job before we rely on it. |

**Units:** 1 stud = 28 cm ([Roblox units](https://create.roblox.com/docs/physics/units)).

---

## 0. Decisions this forces (read first)

1. **Turn on instance streaming.** `default.project.json` still has `StreamingEnabled: false`.
   - These all need streaming: SLIM LODs, Server Authority, multiple replication foci, frustum and predictive streaming, mesh-memory scaling and SLIM avatars.
   - None of them work without it.
2. **Stop setting `Lighting.Technology`.** It is deprecated and has RobloxScript security.
   - `src/server/Systems/LightingService.luau:470` writes it at runtime. That write will always fail.
   - Instead, set `LightingStyle = Realistic` and `PrioritizeLightingQuality = true` in the Rojo project. They are also non-scriptable, so they cannot be set at runtime.
   - **Update (look-fix3, [EVID]): keep `Technology = Future` in the FILE too.** On load the engine maps the legacy Technology onto LightingStyle and PrioritizeLightingQuality and ignores the file's own values. A headless server of v30 (no Technology) loaded Soft with quality off; v31 (`Technology = Future`) loaded Realistic with quality on (`tools/look/probe_place.py`). Only the runtime write stays forbidden.
3. **Assume the Open Cloud place-publish API will not deliver `SurfaceAppearance` or unions (`PartOperation`)** from our Rojo-built file ([DOC], [place publishing](https://create.roblox.com/docs/cloud/guides/usage-place-publishing)).
   - MaterialVariants are not on that list. Make them our main PBR route for world surfaces (roads, walls, sidewalks).
   - Deliver meshes that carry a SurfaceAppearance (cars, guns, hero props) as uploaded **Model assets**, loaded at runtime with `InsertService:LoadAsset`. v1 already proved this path.
   - Or deliver them through a Luau Execution "bake" with `SavePlaceAsync`. That must be verified first.
4. **Add a bake step to the deploy pipeline.** Rojo build → publish `Saved` → Luau Execution task → `AssetService:SavePlaceAsync()` ([Luau Execution](https://create.roblox.com/docs/cloud/reference/features/luau-execution), [ANN 3805169](https://devforum.roblox.com/t/saveplaceasync-now-supports-all-places/3805169)). The task would:
   - generate terrain with `WriteVoxelChannels`;
   - run MapBuilder and MapDresser once, so the city exists in the place file instead of being built on every server boot. SLIM is generated from saved places [UNVERIFIED for runtime-built models];
   - set the properties that are writable only from Open Cloud or plugins (`RenderFidelity`, `LevelOfDetail`, `CollisionFidelity`).

   Without this step, every Rojo publish wipes the terrain. A Rojo file cannot carry voxels except through a TerrainRegion `.rbxm` (§6).
5. **Lighting must look right in two modes.** Graphics quality decides the lighting path. Shadows are off below quality level 4 ([DOC] [improve](https://create.roblox.com/docs/performance-optimization/improve)). A developer cannot force Future-style lighting on a phone.
   - The mobile look has to come from emissive windows, the sky, the atmosphere and the colour grade, not from shadows.
6. **Keep Atmosphere Density at 0.25–0.30.** Above about 0.35 the aerial and skyline views turn into a wall ([EVID] lab job 0002, and the v1 `overview_high_haze.jpg`).
7. **Use SurfaceAppearance `AlphaMode = TintMask` with `SurfaceAppearance.Color` for car paint.** `Color` is scriptable at runtime, and the docs say tinting "does not affect performance". One texture set can serve every paint colour.
   - For skinned or Humanoid models, Roblox announced that `SurfaceAppearance.Color` changes would stop triggering FastCluster rebuilds "in early 2026" ([ANN 4147160](https://devforum.roblox.com/t/making-avatar-rendering-more-performant/4147160)). I have not confirmed that it shipped. It does not affect rigid cars either way.
8. **Content rules make three GTA staples illegal at Moderate:**
   - **Alcohol:** any bar, liquor store or beer sign makes the game 18+ only.
   - **Strong language:** Restricted.
   - **Romantic themes:** Restricted.

   Guns and realistic non-gory death are fine at **Moderate**. Paid crates and trading of Robux-bought cars need PolicyService gating (§16).
9. **Server Authority** has been GA since 2026-07-09. It is the engine's real answer to speed and teleport hacks in cars.
   - It requires streaming, the Input Action System, deferred signals, fixed simulation and next-generation replication, plus `BindToSimulation` rewrites.
   - Pilot it for driving and gunplay in a branch place. Do not flip it on for v2 launch.
10. **Pin one Rojo version.** `rokit.toml` pins `rojo 7.6.1`, but the container has `7.7.1`. Property-name migrations differ between versions (for example `SkyboxBk` → `SkyboxBackContent`). Builds and the operator's live-sync must use the same version.

---

## 1. Where each property can be set: runtime vs file vs Studio

**What "file" means.** Rojo `.project.json` or `.model.json` `$properties` are written into the `.rbxl` by `rojo build`. Any property the engine marks as serialized (`can_load: true`) can be set this way, including NotScriptable and Plugin-only ones.

I confirmed this by building a test project with every property below. All of them appeared in the output XML [ROJO]. Rojo transparently renamed several:
- `Use2022Materials` → `Use2022MaterialsXml`
- `SkyboxBk` → `SkyboxBackContent`
- `MeshId` → `MeshContent`
- `ColorMap` → `ColorMapContent`
- `SignalBehavior` → `SignalBehavior2`

**Live-sync is different.** `rojo serve` live-sync, which the operator uses, applies properties through plugin Lua. It cannot apply **NotScriptable** properties, so they only arrive through a lead build and publish [UNVERIFIED but follows from the flags]. The operator's open Studio may therefore show stale streaming or lighting settings until the place is reopened from Roblox.

**Column key:**
- **Game script**: a normal server or client script in a live server.
- **OC/Plugin**: Studio plugins, the command bar, or Open Cloud Luau Execution. These hold the `PluginOrOpenCloud` capability or plugin security.

| Property | Game script | OC/Plugin | Rojo file | Notes |
|---|---|---|---|---|
| `MaterialVariant.ColorMap/Normal/Roughness/Metalness/EmissiveMask` | ✗ | Plugin | ✓ | PluginSecurity read and write [DUMP]. Runtime scripts cannot even read them. |
| `MaterialVariant.BaseMaterial` | read only | Plugin | ✓ | |
| `MaterialVariant.StudsPerTile`, `MaterialPattern`, `CustomPhysicalProperties`, `EmissiveStrength/Tint`, `AlphaMode` | ✓ | ✓ | ✓ | `AlphaMode` on MaterialVariant is a **Studio beta** (2026-02-18, [ANN 4406303](https://devforum.roblox.com/t/4406303)). |
| `MaterialService.<Material>Name` overrides | ✗ (NotScriptable) | ✗ | ✓ | At runtime, use `MaterialService:SetBaseMaterialOverride(material, name)` (Security None) [DOC]. |
| `MaterialService.Use2022Materials` | ✗ | ✗ | ✓ (`Use2022MaterialsXml`) | Must be `true`. |
| `SurfaceAppearance.*Map/*Content` | ✗ | Plugin | ✓, **but see the publish caveat** | The docs say maps "can't be modified by scripts during a game because the engine requires some pre-processing". |
| `SurfaceAppearance.Color`, `AlphaMode`, `EmissiveStrength/Tint`, `ResampleMode` | ✓ | ✓ | ✓ | |
| `MeshPart.MeshId/MeshContent` | ✗ (NotAccessible) | ✗ | ✓, **but the collision and physics data is not created** | Use `AssetService:CreateMeshPartAsync` (Security None) or a Studio-made `.rbxm`. |
| `MeshPart.RenderFidelity` | [UNVERIFIED] | ✓ | ✓ | Write capability is `PluginOrOpenCloud` [DUMP]. It is ignored once mesh streaming is on (§7). |
| `MeshPart.CollisionFidelity`, `CollisionPrecision` | ✗ in practice | ✓ | load-only | `CanSave=false`. Studio computes the hulls at import. |
| `Model.LevelOfDetail` | ✗ | ✓ | ✓ | Read and write capability `PluginOrOpenCloud` [DUMP]. |
| `Model.ModelStreamingMode` | ✓ | ✓ | ✓ | |
| `Workspace.StreamingEnabled` | ✗ in practice | ✓ | ✓ | The docs say "cannot be set in a script". |
| `Workspace.StreamingTargetRadius/MinRadius/StreamOutBehavior/ModelStreamingBehavior/StreamingIntegrityMode/PredictiveStreamingMode/EnableSLIMAvatars/MeshStreamingAndImprovedLods/ExpandedTerrain` | ✗ | ✗ | ✓ | NotScriptable or RolloutState settings. |
| `Workspace.AuthorityMode` | ✗ | ✗ | ✓ | RobloxScriptSecurity. |
| `Player.FrustumStreaming` | ✓ (server) | ✓ | — | |
| `Lighting.Technology` | ✗ (deprecated) | ✗ | ✓ | Maps to the new properties on load. Remove it from our project. |
| `Lighting.LightingStyle`, `PrioritizeLightingQuality` | ✗ | ✓ (`PluginOrOpenCloud`) | ✓ | The operator's `execute_luau` (no RobloxScript) could not change Technology [EVID]. |
| `Lighting.ClockTime`, `Brightness`, `ExposureCompensation`, `Ambient*`, `EnvironmentDiffuse/SpecularScale`, `ShadowSoftness` | ✓ | ✓ | ✓ | |
| `Sky.Skybox*`, `SkyboxOrientation`, `SunAngularSize` | ✓ | ✓ | ✓ | Sky faces can be swapped at runtime, for example for weather. |
| `Atmosphere.*`, `Clouds.*`, post effects | ✓ | ✓ | ✓ | |
| `Terrain.Decoration`, `Terrain.GrassLength`, `Terrain.MaterialColors` | ✗ (NotScriptable) | ✗ | ✓ | Use `SetMaterialColor()` at runtime. The docs show `GrassLength` as writable, but the API dump says NotScriptable. Set it in the file. |
| `Terrain.Water*` | ✓ | ✓ | ✓ | |
| `SoundService.DefaultListenerLocation`, `CharacterSoundsUseNewApi` | ✗ | Plugin | ✓ | Set `DefaultListenerLocation = Camera` in the file. |
| `SoundService.AcousticSimulationEnabled` | ✓ | ✓ | ✓ | |
| `StarterGui.ClipsDescendantsSupportsRotation` | ✗ | ✗ | ✓ | Enabled by default since 2026-09-24. The property is removed in November 2026. |

Sources: [MaterialVariant](https://create.roblox.com/docs/reference/engine/classes/MaterialVariant), [MaterialService](https://create.roblox.com/docs/reference/engine/classes/MaterialService), [MeshPart](https://create.roblox.com/docs/reference/engine/classes/MeshPart), [Workspace](https://create.roblox.com/docs/reference/engine/classes/Workspace), [Lighting](https://create.roblox.com/docs/reference/engine/classes/Lighting), [Terrain](https://create.roblox.com/docs/reference/engine/classes/Terrain), [script capabilities](https://create.roblox.com/docs/scripting/capabilities).

**Publishing caveat [DOC]**

> "The place publishing API doesn't update certain instance types. If your game contains `EditableImage`, `EditableMesh`, `PartOperation`, `SurfaceAppearance`, or `BaseWrap` instances, publish from Studio after modifying them." ([usage-place-publishing](https://create.roblox.com/docs/cloud/guides/usage-place-publishing))

We publish Rojo builds through exactly that API. So:
- Rojo-authored SurfaceAppearances and unions must be treated as broken until an operator job proves otherwise.
- The proven alternatives are:
  - GLB uploaded as a Model, then loaded at runtime with `InsertService:LoadAsset`. v1's `AssetLibrary.luau` does this, and the meshes loaded [EVID job 0001].
  - Operator publishes from Studio.
  - Luau Execution bake with `SavePlaceAsync` [UNVERIFIED for SurfaceAppearance].

---

## 2. MaterialService and MaterialVariant (the world-surface workhorse)

Sources: [Materials guide](https://create.roblox.com/docs/parts/materials), [MaterialVariant](https://create.roblox.com/docs/reference/engine/classes/MaterialVariant), [MaterialService](https://create.roblox.com/docs/reference/engine/classes/MaterialService), [texture specifications](https://create.roblox.com/docs/art/modeling/texture-specifications).

### Maps

| Map | Format | Notes |
|---|---|---|
| `ColorMap` | Albedo, RGB 24-bit | The alpha channel is ignored unless AlphaMode is used (beta). |
| `NormalMap` | Tangent space, RGB | **OpenGL convention (+Y / green up).** `(127,127,255)` is flat. Bytes 0–255 map to −1…1.016. If bumps read as dents, invert G. Meshes must be exported **with tangents**, or the normal map does nothing [DOC]. |
| `RoughnessMap` | Grayscale 8-bit | Separate image. |
| `MetalnessMap` | Grayscale 8-bit | Separate image. |
| `EmissiveMaskContent` | Grayscale | Use with `EmissiveStrength` and `EmissiveTint`. Live in published games since 2026-02-12 ([ANN 4369565](https://devforum.roblox.com/t/4369565)). |

- **There is no ORM channel packing.** Each map is its own image upload, so one material costs 3–5 image uploads.
- **Normal maps from our sources:**
  - Poly Haven: use `*_nor_gl`, never `*_nor_dx`.
  - ambientCG: use `NormalGL`.

### Tiling

- `StudsPerTile` sets the tile size in studs. Our formula: StudsPerTile = real tile size in metres ÷ 0.28.
  - Example: a 2 m Poly Haven asphalt tile needs about 7 studs.
- `MaterialPattern` takes two values:
  - `Regular`: plain tiling.
  - `Organic`: breaks up repetition, so use it for asphalt, concrete, grass and dirt.
- Built-in materials put a 1024² texture over 8×8 studs on parts, and 512² over 8×8 studs on terrain [DOC].

### Applying materials

There are three ways:

| Route | Where it is set | Effect |
|---|---|---|
| `BasePart.MaterialVariant = "<name>"` | Per part | The variant must live under MaterialService and match the part's `Material` = `BaseMaterial`. |
| **Global override** | `MaterialService.<Mat>Name` in the file, or `MaterialService:SetBaseMaterialOverride(Enum.Material.Asphalt, "HC_Asphalt")` at runtime | Every Asphalt part **and terrain voxel** uses the variant. |
| Custom terrain slots | §6 | |

- **Runtime-override trick:** keep `HC_Asphalt_Dry` and `HC_Asphalt_Wet` variants, the wet one with low roughness. Call `SetBaseMaterialOverride` when rain or night starts. That swaps the whole road network in one call [UNVERIFIED: watch for a one-frame hitch].
- `Use2022Materials` must be true. Mixing legacy terrain materials with MaterialVariants costs performance [DOC].

### Other properties and constraints

- **4K textures:** MaterialVariant joined texture streaming with 4K support. Since 2026-01-30, up to 4096² is rendered when the device can afford it ([ANN 4316229](https://devforum.roblox.com/t/4k-texture-rendering/4316229)). Low-end Android and iOS devices (under 3.5 GB) do not get 4K ([ANN 4144855](https://devforum.roblox.com/t/introducing-texture-streaming/4144855)).
  - Upload city materials at 2048² and let streaming choose.
- **AlphaMode** (Studio beta, so do not ship on it):
  - `Opaque`, `Overlay`, `TintMask` (tints with `Part.Color`) and `Transparency` (fences, grates).
  - When it ships, one grey brick MaterialVariant plus `Part.Color` gives every facade its own colour.
- **CustomPhysicalProperties** applies to parts. It is **not** honoured by custom terrain material slots yet ([custom terrain materials](https://create.roblox.com/docs/parts/custom-terrain-materials)).
- **Runtime creation is impossible** because the maps are Plugin-only (§1). Every MaterialVariant must ship in the Rojo file.
  - Pattern: `MaterialService/<Name>` entries in `default.project.json`, or a `src/materials/*.model.json` tree.

---

## 3. SurfaceAppearance (unique-UV meshes: cars, guns, hero props)

Sources: [PBR textures guide](https://create.roblox.com/docs/art/modeling/surface-appearance), [SurfaceAppearance](https://create.roblox.com/docs/reference/engine/classes/SurfaceAppearance), [AssetService](https://create.roblox.com/docs/reference/engine/classes/AssetService).

### Maps

The maps are the same as MaterialVariant: Color, Normal (OpenGL, tangent space), Roughness, Metalness and EmissiveMask. SurfaceAppearance **overrides `MeshPart.TextureID`** and uses the mesh's single UV set (0–1).

### AlphaMode

| Mode | Effect |
|---|---|
| `Overlay` (default) | Transparent areas show `MeshPart.Color`. |
| `Transparency` | Cut-out. Set `MeshPart.Transparency = 0` for hard cut-outs with proper depth, or ≥ 0.02 for smooth blends. |
| `TintMask` | Alpha is the mask for `SurfaceAppearance.Color`. |
| `Opaque` | Beta. |

### Tint

- **`SurfaceAppearance.Color` multiplies the colour map.**
  - It costs no performance and saves memory by reusing one map [DOC].
  - It is scriptable.
  - For the strongest tint, author the painted regions near-white.
- **Car paint recipe:**
  - Albedo: near-white on body panels, real colours on trim.
  - Alpha: 1 on paint and 0 on trim, rubber, lights and chrome. Turn off premultiplied alpha.
  - Set `AlphaMode = TintMask`.
  - Paint colour = `SA.Color`.
  - Metallic or pearl finishes: swap the roughness and metalness through a different template SurfaceAppearance.

### Scriptability

- Maps are Plugin-write.
- `Color`, `AlphaMode`, `EmissiveStrength`, `EmissiveTint` and `ResampleMode` are writable at runtime.
- Runtime patterns:
  - **Clone a template SurfaceAppearance** and parent it to the MeshPart. This is the normal way.
  - `AssetService:CreateSurfaceAppearanceAsync({ColorMap=Content.fromObject(editableImage), ...})` (Security None) **only accepts EditableImage content today**. Editable images are memory-expensive. Avoid it except for player decals or liveries.
- Publish caveat: see §1. SurfaceAppearances should reach the game inside **Model assets**, or through a Studio or bake publish.

### MeshPart.TextureID vs SurfaceAppearance for uploaded buildings (A3, verified 2026-10-27)

- **`MeshPart.TextureID` (`TextureContent`) is scriptable at runtime**; `MeshId` is not, and SurfaceAppearance maps are
  not (see above). So one uploaded Image can texture any number of MeshParts set from a game script.
- **What the Open Cloud GLB importer makes** [EVID: probe upload `95401734300558`, downloaded and inspected with Lune]:
  - glTF base-colour / roughness / metallic **factors are dropped**: every MeshPart arrives grey `Plastic`.
  - A material with only a base-colour image becomes `MeshPart.TextureID` (the image is uploaded as a new asset).
  - A full PBR set (colour + normal + roughness) becomes a **SurfaceAppearance** (four new image assets).
  - Hierarchy: `Model(displayName) > Model(root) > Model "<object>_Node" > MeshPart "<object>"`; positions in studs;
    a 180° turn about Y (glTF +Z front -> Roblox -Z front; Blender x -> Roblox -x).
- **Decision for buildings:** upload geometry + UVs only and surface the parts at runtime: tiling roles use
  `Enum.Material` + the place's global MaterialVariants tinted by `BasePart.Color` (community reports and the open
  "MaterialVariant obey MeshPart UV maps" feature request agree that MaterialVariants on MeshParts are projected per
  face at StudsPerTile, not UV-mapped, so texel density stays constant when a building is scaled); atlas roles
  (window interiors, signs, brands, awnings) use `TextureID` with four shared Images. Embedding textures would have
  cost ~5 image assets per building and no reuse.
- **Real-engine check** [EVID: `tools/blender/buildkit/cloud_probe.py` -> `docs/v2/early/buildings/cloud_probe.json`]:
  11 building Models load with `InsertService:LoadAsset` in 0.23-0.37 s each, every expected MeshPart is present, the
  front sits at -Z, and `Material` / `MaterialVariant = "HC_BrickTan"` / `TextureID` writes read back.
- `TextureID` alpha is a hard cut-out (ROBLOX_CARS §3), so soft grime decals are not shipped on buildings.

### Budgets

| Asset | Map sizes |
|---|---|
| General guidance [DOC] | Up to 1024² for an 8×8×8-stud object. Higher works through texture streaming. |
| Car body | 2048² albedo; 1024² normal, roughness and metal (`ResampleMode` default). |
| Gun | 1024² albedo; 512² for the other maps. |

- Duvall Drive's example trim set: normal 1024, colour 512, roughness 256, no metalness ([Duvall Drive](https://create.roblox.com/docs/resources/the-mystery-of-duvall-drive/materialize-the-world)).
- **Instancing:** copies render in one draw call only when the `MeshContent` matches and the SurfaceAppearances are identical ([improve](https://create.roblox.com/docs/performance-optimization/improve)).
  - Whether a different `SA.Color` breaks instancing is not documented [UNVERIFIED]. Measure draw calls with 20 parked cars of the same model in different colours.

---

## 4. Sky: six faces, orientation and resolution

Sources: [Skyboxes](https://create.roblox.com/docs/environment/skybox), [Sky](https://create.roblox.com/docs/reference/engine/classes/Sky), Roblox community tutorial ["Custom Skyboxes 101"](https://devforum.roblox.com/t/custom-skyboxes-101/2849003).

### Properties

- **Faces:** `SkyboxBk/Dn/Ft/Lf/Rt/Up`. The modern names are `Skybox{Back,Down,Front,Left,Right,Up}Content`, and Rojo migrates the old names.
- **Orientation:** `SkyboxOrientation` is a Vector3 in degrees. Y is applied first, then X, then Z.
  - It is cheap and works on every platform.
  - It does not rotate celestial bodies, indoor reflections or dynamic clouds.
- **Sun and moon:** `SunAngularSize` defaults to 21 and is clamped to 0–60. Also `MoonAngularSize`, `StarCount`, `CelestialBodiesShown` and `Sun/MoonTextureId`.

### Face mapping

The mapping from a standard cubemap converter (Jaxry "panorama-to-cubemap", three.js names) is:

| Converter face | Roblox face |
|---|---|
| `px` | `SkyboxRt` |
| `nx` | `SkyboxLf` |
| `py` | `SkyboxUp`, **rotated 90° clockwise** |
| `ny` | `SkyboxDn`, **rotated 90° counter-clockwise** |
| `pz` | `SkyboxBk` |
| `nz` | `SkyboxFt` |

- The Roblox camera looks down −Z by default, with +X to the right.
- The official docs do not state face orientation. My axis analysis suggests the converter's faces may come out **mirrored** in a right-handed world.
  - That mirroring is invisible for clouds but matters for any text or landmarks.
  - It also matters for matching the painted-out sun to `ClockTime` [UNVERIFIED].
- **Diagnostic kit, generated for this note.** Upload these six 512² images and screenshot looking north, east, up and down:
  - `docs/v2/research/img/sky_test_{ft,rt,bk,lf,up,dn}.png`
  - Sheet: `docs/v2/research/img/sky_test_sheet.png`

  What the operator checks:
  - The side faces carry readable text, so mirrored text shows the faces are flipped.
  - They also carry neighbour arrows and colour bands.
  - The Up and Dn faces carry lettered edges A–D.
  - The report should say which side-face colour band touches which letter. That fixes the rotation once and for all.

### Resolution

- Sky is **not yet** part of texture streaming. The 2026-03 status lists Sky as "work in progress" ([ANN 4144855](https://devforum.roblox.com/t/introducing-texture-streaming/4144855)).
- Plan **1024² per face**. Treat 2048 as possibly downsampled until tested.
- Image uploads must be under 8000×8000 ([assets usage](https://create.roblox.com/docs/cloud/guides/usage-assets)).

### HDRI workflow

1. Tone-map the HDR to 8-bit sRGB, because Roblox skies are LDR.
2. **Paint out the sun disk**, since Roblox draws its own sun, which drives shadows and Atmosphere glare.
3. Match `ClockTime` and `GeographicLatitude` to the HDRI's sun azimuth with `SkyboxOrientation.Y`.
4. Convert the equirect to faces.
5. Upload the faces as Image assets.

- `EnvironmentDiffuseScale = 1` and `EnvironmentSpecularScale = 1` make the sky drive the ambient light and glass reflections. This was the lab's biggest missing piece for glass.
- A `Sky` placed inside a ViewportFrame acts as its reflection cubemap.

---

## 5. Lighting, Atmosphere, Clouds, post effects and light budgets

Sources: [Global lighting](https://create.roblox.com/docs/environment/lighting), [Lighting](https://create.roblox.com/docs/reference/engine/classes/Lighting), [Technology enum](https://create.roblox.com/docs/reference/engine/enums/Technology), [ANN Unified Lighting 3401512](https://devforum.roblox.com/t/let-there-be-unified-light-unified-lighting-is-fully-live/3401512).

### Unified Lighting

Unified Lighting has been live since 2025-07-23. `Technology` is deprecated and maps on load:

| Old `Technology` | `LightingStyle` | `PrioritizeLightingQuality` |
|---|---|---|
| Future | Realistic | Enabled |
| ShadowMap | Soft | Enabled |
| Voxel | Soft | Disabled |

- Neither new property is scriptable.
- **Our setting:** `Technology = Future` **and** `LightingStyle = Realistic` + `PrioritizeLightingQuality = true` in `default.project.json`.
  - Rojo writes both `Technology` and `LightingStyle` when both are present [ROJO]. The engine then derives the new properties from Technology on load [EVID look-fix3: v30 without it loaded Soft and quality off; v31 with Future loaded Realistic and quality on]. So Technology must agree with them.
- `ShadowSoftness` only works with Realistic.

### Mobile reality

- The lighting path scales with the client's graphics quality.
- Shadows degrade, and are **off below quality level 4** [DOC].
- Developers cannot force a quality level. A 2026-10 DevForum thread confirms quality level 6 vs 10 gives visibly different lighting ([4911437](https://devforum.roblox.com/t/4911437)).

What the low-quality frame still renders: the sky, Atmosphere, emissive surfaces and Neon, ColorCorrection, and textures. Design the low-end frame on purpose:
- lit-window emissive masks on towers;
- strong but low-Density Atmosphere colour;
- a colour grade.

### Atmosphere ([guide](https://create.roblox.com/docs/environment/atmosphere), [class](https://create.roblox.com/docs/reference/engine/classes/Atmosphere))

| Property | Role |
|---|---|
| `Density` | How much distant objects are hidden. |
| `Offset` | Horizon silhouette vs blending. Too low causes "ghosting" through objects. |
| `Haze` | Haze in the sky and the distance. |
| `Glare` | Glow around the sun. Needs `Haze` > 0. |
| `Color` and `Decay` | The tint toward and away from the sun. |

From lab job 0002 [EVID]:
- Density ≥ 0.35 destroys aerial and skyline views. Use 0.25–0.30.
- Blue or teal fog reads as "underwater". Use neutral or warm grey.
- At night, lower the Density and the blue.

### Clouds ([guide](https://create.roblox.com/docs/environment/clouds))

`Terrain/Clouds` has `Cover` (0–1), `Density`, `Color` and `Enabled`. These are dynamic volumetric clouds, unaffected by `SkyboxOrientation`. Use `Cover` of about 0.3–0.5 for LA haze days.

### Post effects ([guide](https://create.roblox.com/docs/environment/post-processing-effects))

- Available effects: Bloom, Blur, ColorCorrection, DepthOfField, SunRays, and **ColorGradingEffect**. ColorGradingEffect's `TonemapperPreset` is `Default` or `Retro` ([class](https://create.roblox.com/docs/reference/engine/classes/ColorGradingEffect)).
- Effects under `Lighting` are global. Effects under `Camera` are per player (for example, blur behind the phone UI, or a red tint at low health).
- **Cost:** Roblox publishes no per-effect costs. Some effects do not render at low quality levels [DOC].
- Our rule:
  - Always on: Bloom (low intensity), ColorCorrection and ColorGrading.
  - Subtle: SunRays.
  - DepthOfField only in menus, the phone UI and cutscenes. DOF also fights alpha-blended foliage.

### Local lights ([light sources](https://create.roblox.com/docs/effects/light-sources))

- PointLight, SpotLight and SurfaceLight have a **maximum Range of 120 studs**, doubled from 60 on 2025-09-23 ([ANN 3954367](https://devforum.roblox.com/t/extended-light-ranges-doubling-the-limit-to-120/3954367)). Cost rises steeply with range.
- `Light.Shadows` is the expensive part [DOC]. The docs advise disabling shadows on moving objects and limiting range and angle.
- **Our budget** (heuristic, verify with the MicroProfiler `computeLightingPerform` and `ShadowMapSystem` markers):
  - At most about 4–6 shadow-casting local lights near the camera. These are the player's headlights, the police lightbar near the player, and lamps in the current block.
  - At most about 40 visible non-shadow lights.
  - Everything else (windows, signs, far lamps) uses EmissiveMask or Neon, which has no light cost.
- Traffic headlights: SpotLights with `Shadows = false`, enabled only within about 150 studs of the camera.
- **Wet streets:** Roblox has no screen-space reflections. Reflections come from the sky environment map (`EnvironmentSpecularScale`) plus specular highlights of local lights on low-roughness surfaces.
  - Fake the GTA night-wet look with the wet asphalt MaterialVariant (§2), lamp SpotLights pointing down, and decal puddles.
- **Day and night:** `Lighting.ClockTime` is scriptable and replicates. Clients may also override Lighting locally, for example for interiors.

---

## 6. Terrain for a ~5000×5000-stud island

Sources: [Terrain guide](https://create.roblox.com/docs/parts/terrain), [Terrain class](https://create.roblox.com/docs/reference/engine/classes/Terrain), [custom terrain materials](https://create.roblox.com/docs/parts/custom-terrain-materials), [ANN 4950620](https://devforum.roblox.com/t/4950620), [ANN 4703282](https://devforum.roblox.com/t/4703282).

### Grid and write calls

- Voxels are 4 studs. The editable extent is ±32,000 cells, or ±128,000 studs.
- `WriteVoxels` and `WriteVoxelChannels` rules:
  - Resolution must be 4.
  - The region must be grid-aligned.
  - **Each call is capped at 4,194,304 voxels.**
  - `WriteVoxelChannels` takes `SolidMaterial`, `SolidOccupancy` and `LiquidOccupancy`. Water is written as `SolidMaterial = Air` plus `LiquidOccupancy`.
- `FillBlock`, `FillBall`, `FillCylinder` and `FillWedge` cover simple shapes, such as the beach shelf and the seabed.

### Island scale

- 5000×5000 studs is 1250×1250 columns.
- With 32–64 voxels of vertical range (128–256 studs), that is **50–100 million voxels**, or at least 12–24 maximum-size calls.
- **Measured here:** building the three channel arrays in Luau runs at about **48 M voxels/s**. That was Lune 0.10 on this 4-CPU container, with no noise maths. So the script side is seconds.
- The engine-side write and meshing cost is **unmeasured** [UNVERIFIED]. Use 256×256-stud tiles (64×Y×64 voxels) and `task.wait()` between tiles.
- **Run it as a bake** (Luau Execution, 5-minute cap), not on server boot.

### Expanded Terrain

Expanded Terrain reached full launch on 2026-10-22 and is set with `Workspace.ExpandedTerrain = Enabled` (file only).
- **Up to 62 custom terrain materials** via `Terrain:SetMaterialSlot(i, baseMaterial, variantName, color)`, for example sand shades, dry grass, dirt and cliff rock.
- Client memory is 40–60% lower in the EAP measurements.
- Terrain is **stored as an asset outside the place file**. This matters because publishes cap at **100 MB** per place file (stated in the EAP announcement).
- Known issues:
  - Terrain less than 16 voxels thick can vanish with a small streaming radius.
  - An iOS terrain-streaming crash has a fix pending (2026-10-22 update).
  - Custom physical properties do not work on the slots.

### Grass and water

- **Grass:** `Terrain.Decoration` animates grass blades on the `Grass` material only. Both `Decoration` and `GrassLength` must be set in the file.
- **Water:** `WaterColor`, `WaterReflectance`, `WaterTransparency`, `WaterWaveSize` and `WaterWaveSpeed` are all scriptable. For the GTA turquoise coast, use colour around (0.05, 0.4, 0.5), reflectance 0.8–1.0 and transparency about 0.6.
- **Coming soon (EAP, late 2026):** terrain object scattering for custom grass and foliage, path splines, projected terrain decals, virtual texturing and SDF terrain ([ANN 4865617](https://devforum.roblox.com/t/4865617)). Do not plan on them for launch.
- **Use terrain only for** hills, beach, cliffs, countryside and the seabed. Roads, curbs and sidewalks stay as Parts or meshes with MaterialVariants. Terrain cannot hold a crisp curb edge.

### Pipeline problem

A Rojo build has no voxels. Publishing it replaces the place, so **terrain is wiped on every lead publish**. Options:

| Option | How | Verdict |
|---|---|---|
| **A (recommended)** | Bake step: Luau Execution generates the terrain, then calls `SavePlaceAsync`. | Needs the place permission "Allow place to be updated using Save Place API". An active Team Create session blocks the save. An approximately 8 MiB `SavePlaceAsync` size bug got a fix around 2026-09-30 ([4859850](https://devforum.roblox.com/t/4859850)). |
| B | Ship a `TerrainRegion` `.rbxm` through Rojo, then call `Terrain:PasteRegion` at server start. | rbx-dom round-trips BinaryString, so the file survives. Compatibility with Expanded Terrain storage is [UNVERIFIED]. |
| C | Generate the terrain at every server boot. | Simple, but it costs boot time and server CPU. |

---

## 7. Meshes, LOD, collision, instancing and budgets

Sources: [General specifications](https://create.roblox.com/docs/art/modeling/specifications), [Meshes](https://create.roblox.com/docs/parts/meshes), [MeshPart](https://create.roblox.com/docs/reference/engine/classes/MeshPart), [RenderFidelity](https://create.roblox.com/docs/reference/engine/enums/RenderFidelity), [CollisionFidelity](https://create.roblox.com/docs/reference/engine/enums/CollisionFidelity), [ModelLevelOfDetail](https://create.roblox.com/docs/reference/engine/enums/ModelLevelOfDetail), [SLIM](https://create.roblox.com/docs/workspace/streaming/slim), [improve](https://create.roblox.com/docs/performance-optimization/improve).

### Hard limits

| Limit | Value |
|---|---|
| Triangles per mesh | **20,000** [DOC] |
| EditableMesh | 60k vertices / 20k triangles |
| UV sets | One (0–1) |
| Materials per MeshPart | **One** |
| Vertex bone influences | Up to 4 |
| Open Cloud Model upload | ≤ 20 MB per call |

- A GTA car is therefore a Model of several MeshParts: body, glass, chrome, rubber, lights, interior, and four wheels. That is about 8–12 draw calls per car before instancing.

### RenderFidelity

- `Automatic`: highest detail under 250 studs, medium at 250–500, lowest at 500 and beyond.
- `Precise` and `Performance` are the other values.
- **Mesh streaming and improved LoDs:**
  - Opt-in phase since 2026-04-27, set with `Workspace.MeshStreamingAndImprovedLods = Enabled` ([ANN 4601232](https://devforum.roblox.com/t/4601232)).
  - When enabled, `RenderFidelity` is **ignored**. A new cloud transcoder makes better LoDs and streams meshes by scene importance under a memory budget.
  - The demo city rendered 403k triangles instead of 1.08M.
  - Phase 3 removes both properties. **Enable it now** and stop authoring RenderFidelity.

### CollisionFidelity

- Values: `Default`, `Hull`, `Box`, `PreciseConvexDecomposition`, and `Tunable` with `CollisionPrecision` (2026-09-17, [ANN 4878198](https://devforum.roblox.com/t/4878198)).
- Collision hulls are computed by Studio or the importer. The data lives in hidden `PhysicsData` and `PhysicalConfigData`.
- **A MeshPart created only in Rojo JSON gets no collision data** [UNVERIFIED in-engine, but the hidden properties are RobloxEngine-only].
- Either:
  - keep MeshParts in Studio-made or Open Cloud-uploaded assets; or
  - create them with `AssetService:CreateMeshPartAsync(Content, {CollisionFidelity=..., RenderFidelity=...})` (Security None) at bake or runtime.
- **Rules:**
  - Decorative meshes: `CanCollide = false`, `CanTouch = false`, `Box`. Also `CanQuery = false` unless bullets should hit them.
  - Buildings: `Box` or `Hull` shells plus invisible box colliders.
  - Cars: `Hull` body plus a box chassis.
  - Never use Precise on mass props, because collision geometry stays in memory even when collision is off [DOC].

### Model.LevelOfDetail (set in file or bake)

| Value | Behaviour |
|---|---|
| `Automatic` | Currently the same as Disabled. |
| `StreamingMesh` | Untextured imposter. |
| `Disabled` | No low-detail stand-in. |
| `SLIM` | Composite multi-LOD with textures. |

SLIM requirements and limits:
- Streaming on.
- **The place must be saved to Roblox** and transcoded in the cloud on first publish or play.
- Static models only: no runtime part changes, no Humanoids.
- On unsupported platforms it falls back to Disabled.
- Debug it with the Developer Console **DebugVisualizations → SlimTintMode** (needs edit permission; [ANN 4924019](https://devforum.roblox.com/t/4924019)).
- Wrap each building and prop cluster in a Model. Use Folders for pure organisation, because SLIM ignores Folders.
- Parked props are fine as SLIM. **Driveable cars are not.**

### Instancing

- Identical `MeshContent`, with identical SurfaceAppearance, TextureContent or material, renders as **one draw call** [DOC].
- Upload each mesh **once** and reuse its ID. Re-uploading the same building twice doubles its memory and its draw calls.
- AI or Higgsfield exports that bake a whole scene into unique meshes defeat this.

### Budgets

Roblox gives no official mobile instance budgets. The docs' worked example is a baseline device at **under 1,000 draw calls and 1,000,000 triangles** ([design](https://create.roblox.com/docs/performance-optimization/design)). Our starting targets (heuristic, measure with Shift+F2 render stats, the MicroProfiler and the 2026-09 Device Simulator):

| Metric | Mobile | PC |
|---|---|---|
| Draw calls | ≤ 600 | ≤ 1,500 |
| Triangles | ≤ 600k | ≤ 2M |
| Client `InstanceCount` | ≤ about 60k streamed | — |

- **Server memory** = 6.25 GiB + 100 MiB × the peak player count. Keep it under 50% ([identify](https://create.roblox.com/docs/performance-optimization/identify)).

---

## 8. StreamingEnabled for a driving game

Sources: [Instance streaming](https://create.roblox.com/docs/workspace/streaming), [techniques](https://create.roblox.com/docs/workspace/streaming/techniques), [frustum](https://create.roblox.com/docs/workspace/streaming/frustum), [ModelStreamingMode](https://create.roblox.com/docs/reference/engine/enums/ModelStreamingMode), [ANN predictive 4764052](https://devforum.roblox.com/t/4764052), [ANN frustum 4904553](https://devforum.roblox.com/t/4904553), [ANN MRF 3848736](https://devforum.roblox.com/t/3848736).

### Workspace settings (all file-only)

| Property | Value for Hotwire | Why |
|---|---|---|
| `StreamingEnabled` | true | Required by everything in §0. |
| `StreamingMinRadius` | 128 | Default 64. Cars cover 64 studs in under 0.5 s. |
| `StreamingTargetRadius` | 1024 (default) | About 7 s of look-ahead at 150 studs/s. Frustum streaming extends it. |
| `StreamOutBehavior` | `Opportunistic` | Bounds memory while driving across the map. |
| `StreamingIntegrityMode` | `PauseOutsideLoadedArea` (docs' recommendation) | Stops cars driving into unloaded voids. |
| `ModelStreamingBehavior` | `Improved` (docs' recommendation) | Models are not sent at join. |
| `PredictiveStreamingMode` | `Enabled` | Pre-streams spawn and hospital areas and CFrame returns (2026-07-29). |
| `MeshStreamingAndImprovedLods` | `Enabled` | §7. |
| `EnableSLIMAvatars` | `Enabled` | Crowded servers. R15 platform avatars only. |

### ModelStreamingMode

| Mode | Behaviour | Use for |
|---|---|---|
| `Default` / `Nonatomic` | Parts stream individually. | Most city geometry. |
| `Atomic` | The model and all its initial descendants stream in together, and out only when every part is eligible. The guarantee holds only for **initial** descendants. | **Every vehicle**, so client scripts never see a car without wheels. Also shops and interactable POIs. |
| `Persistent` | Sent at join, before `Workspace.PersistentLoaded`, and never streamed out. | Almost nothing. Overuse defeats streaming. |
| `PersistentPerPlayer` | Persistent only for players added with `Model:AddPersistentPlayer()`. | The owner's own garage and plot. |

### Client patterns

- Treat CollectionService `InstanceAdded` and `InstanceRemoved` as "entered or left the stream", not "spawned or destroyed".
- Streamed-out instances are re-parented to `nil`, not destroyed. Removal signals fire on the **parent**.
- `WaitForChild` should always have a timeout outside atomic models.
- The server should call `Player:RequestStreamAroundAsync(pos)` before teleports, respawns and mission starts.
- `Player:AddReplicationFocus(part)` keeps an area loaded and simulated, for example the heist site while the crew is inside or the player's garage. Each focus costs about as much as another player.
- `Player.FrustumStreaming = Automatic` streams what the camera sees, up to min(render distance, 100k studs).
  - It turns on for high-speed driving in the view direction, narrow FOV (sniper scopes) and free cameras.
  - It is a union with the radius and the replication foci, and is budgeted like a focus.
- **Physics is simulated only in streamed areas**, even for client-created parts.
  - AI traffic beyond the radius must be server-simulated or abstract, not client-simulated.
- **The minimap cannot read Workspace for far blips**, because those cars and players are streamed out.
  - The server must replicate a compact blip table: positions, kinds and wanted state. Use a remote at 5–10 Hz or attributes on a non-streamed Folder.

### Pitfalls in our current code

- `MapBuilder` builds the city at runtime, and MapDresser loads assets after that. Both replicate on boot.
- Scripts that `GetDescendants()` the map at start will break under streaming.
- Server-created runtime models are probably not SLIM-transcoded [UNVERIFIED]. Bake them into the saved place (§0.4).

---

## 9. Vehicles over the network

Sources: [Network ownership](https://create.roblox.com/docs/physics/network-ownership), [security: network ownership](https://create.roblox.com/docs/scripting/security/network-ownership), [Server authority](https://create.roblox.com/docs/projects/server-authority), [techniques](https://create.roblox.com/docs/projects/server-authority/techniques), [ANN SA GA 4727993](https://devforum.roblox.com/t/4727993), [ANN physics replication 4675512](https://devforum.roblox.com/t/4675512), [cylindrical constraint](https://create.roblox.com/docs/physics/constraints/cylindrical), [mover constraints](https://create.roblox.com/docs/physics/mover-constraints), [sleep system](https://create.roblox.com/docs/physics/sleep-system).

### Classic model (v2 launch)

- **The driver owns the car.** On VehicleSeat occupancy, call `seat:SetNetworkOwner(player)`, and `SetNetworkOwnershipAuto()` on exit. This is the docs' own example, and v1 already does it.
- Loose parts on top of the car must be given the same owner.
- The server **cannot verify the physics of an owned part.** An exploiter can teleport, fly or "speed-hack" their car, and can fire `Touched` for parts they own [DOC].
- **Server validation:**
  - per-class speed caps;
  - a teleport check from a 1–2 s position history;
  - no damage from client `Touched` events;
  - ram or PIT damage computed on the server;
  - ownership revoked and the player kicked or banned with `Players:BanAsync` on repeat offences. Device blocking was added on 2026-06-04.

### AI traffic and police

v1 sets `SetNetworkOwner(nil)` on these, so the server simulates every assembly. That does not scale to GTA density. Recommended split:
- Ambient traffic is a **deterministic, server-driven kinematic lane system**: anchored or CFrame-tweened along road splines, with no physics.
- It becomes a physical assembly only when it interacts (hit, carjacked, chasing).
- Police in pursuit stay server-owned physics cars.

### Chassis options

| Option | Notes |
|---|---|
| (a) Constraint chassis | `CylindricalConstraint` per wheel (suspension travel plus axle) or `SpringConstraint` plus `HingeConstraint` (motor). Simple, but wheel–ground physics at speed is twitchy. |
| (b) **Raycast suspension** (recommended for GTA "weight") | One body. Four down-rays per physics step apply spring and damper forces through `VectorForce`, with grip and drift as lateral forces. Wheels are visual only. It is stable at high speed, cheap, and tunable for body roll, drift and skids. |

- **Crash feedback:** `BasePart:BindToCollisionSummaries` (2026-10-06, [ANN 4918568](https://devforum.roblox.com/t/4918568)) gives the contact point, normal, relative velocity and area once per frame. Drive sparks, impact audio, skids and damage scaled by impact speed from it.
- `ImprovedPhysicsReplication` rolled out in June 2026 (eventual consistency, so dropped packets no longer lose updates).

### Server Authority (GA 2026-07-09)

- `Workspace.AuthorityMode = Server` automatically sets:
  - `NextGenerationReplication`;
  - `PlayerScriptsUseInputActionSystem`;
  - `SignalBehavior = Deferred`;
  - `StreamingEnabled`;
  - `UseFixedSimulation`.
- The server owns cars and characters. The client predicts, then rolls back and resimulates.
- Gameplay code must live in `RunService:BindToSimulation()`, read inputs only from `InputAction`, and keep state in attributes.
- Attribute limits: 64 per instance, names and strings of 50 characters or fewer.
- Limits:
  - 8 playing animation tracks per Animator;
  - remotes are not on the synced timeline;
  - mobile and console clients lag desktop rollouts by days.
- Roblox ships a **Racing template**.
- Verdict: it removes the main class of car exploits. However, it is a rewrite of VehicleService, CarBuilder and the input handling. **Prototype it in a separate place first.**

---

## 10. Guns: raycasts, projectiles and anti-cheat

Sources: [Raycasting](https://create.roblox.com/docs/workspace/raycasting), [Detect hits (laser tag)](https://create.roblox.com/docs/tutorials/curriculums/gameplay-scripting/detect-hits), [Security tactics](https://create.roblox.com/docs/scripting/security/security-tactics), [Weapons kit](https://create.roblox.com/docs/resources/weapons-kit).

### APIs

- `WorldRoot:Raycast`, `Blockcast`, `Spherecast`, `Shapecast`, plus `GetPartsInPart` and `GetPartBoundsInBox` for melee.
- `RaycastParams` has `FilterType`, `FilterDescendantsInstances`, `CollisionGroup` and `RespectCanCollide`.
- **Raycasts ignore `CanCollide` by default.** Use `CanQuery = false` on decorative meshes, or `RespectCanCollide = true`.

### Hitscan for pistols, SMGs, rifles and shotgun pellets

This is the docs' laser-tag pattern.
1. The client casts from the camera for instant feedback: tracer, impact and hit-marker.
2. It sends the origin, the direction(s), the claimed hit and a timestamp.
3. The server validates:
   - the weapon is equipped and the server-side ammo count is above zero;
   - the fire rate, checked against the server clock;
   - the origin is within a tolerance of the character's muzzle;
   - the ray angle is within the weapon's spread (the server recomputes the expected directions from shared config);
   - the target was near the claimed point in a **position history**, which is our lag compensation;
   - an obstruction re-raycast on the server.
4. The server applies the damage. The client never sends damage.

### Other weapons

- **Slow projectiles** (grenades, RPG later): the server steps a `Spherecast` each Heartbeat, and the client only renders.
- **NPC and police fire:** server raycasts inside an accuracy cone that grows with the target's speed, rate-limited per officer.

### Anti-cheat

- Rate-limit every remote.
- Type-check, and reject NaN and infinity.
- Keep the authoritative ammo, cash and wanted state on the server.
- Escalate with `BanAsync`.

### Content

- Effects: muzzle flash, tracer, sparks and dust.
- **No blood decals or particles.** Death is the ragdoll plus the WASTED screen (§16).

---

## 11. Particles, beams and trails

Sources: [Particle emitters](https://create.roblox.com/docs/effects/particle-emitters), [Beams](https://create.roblox.com/docs/effects/beams), [Trails](https://create.roblox.com/docs/effects/trails), [ANN custom flipbooks 4005128](https://devforum.roblox.com/t/4005128).

- **Lifetime** is capped at **20 s**. Mobile particle limits are "much lower" than desktop [DOC]. Quality level scales all three effect types, so review them at the lowest and highest Editor Quality Level.
- **Flipbooks:**
  - square grids: `Grid2x2`, `Grid4x4`, `Grid8x8`;
  - `Custom` with `FlipbookSizeX/Y` for non-square sheets (client beta 2025-10);
  - pad frames to avoid mip bleeding.
- **Pooling:**
  - Pre-place disabled emitters on the car, the gun and an impact pool.
  - Fire bursts with `ParticleEmitter:Emit(n)` instead of toggling `Rate`.
  - Use this for muzzle flash, sparks, glass shards, dust and tire smoke.
- **Beam:** default 10 segments, and a gradient with *n* keypoints needs at least n−1 segments. Use 1–2 segments for bullet tracers and police lightbar beams.
- **Trail:** speed lines and light streaks. Skid marks are better as pooled decals or thin parts on the road.
- Texture streaming covers Beam and ParticleEmitter textures [ANN 4144855].

---

## 12. The Audio API (Sound is now "discouraged")

Sources: [Audio objects](https://create.roblox.com/docs/audio/objects), [Audio effects](https://create.roblox.com/docs/audio/effects), [Audio assets](https://create.roblox.com/docs/audio/assets), [AudioEmitter](https://create.roblox.com/docs/reference/engine/classes/AudioEmitter), [ANN acoustic simulation 4307121](https://devforum.roblox.com/t/4307121), [ANN 3282100](https://devforum.roblox.com/t/3282100).

### The graph

| Object | Role |
|---|---|
| `AudioPlayer` | Plays an asset. Properties: `Asset`, `Looping`, `PlaybackSpeed`, `LoopRegion`, `PlaybackRegion`, `Volume`, `TimePosition`. |
| `Wire` | Connects objects (`SourceInstance` → `TargetInstance`). |
| `AudioEmitter` | The 3D source, on a part or attachment. |
| `AudioListener` | Picks up 3D audio. |
| `AudioDeviceOutput` | The speakers. |

- **2D audio** (radio, UI): Player → Wire → DeviceOutput.
- **3D audio:** Player → Wire → Emitter, then Listener → Wire → DeviceOutput.
- Set `SoundService.DefaultListenerLocation = Camera` in the file (Plugin-write).

### Effects

- AudioEqualizer, AudioReverb, AudioCompressor, AudioLimiter, AudioFader, AudioPitchShifter and others.
- `AudioEmitter:SetDistanceAttenuation(curve)` for custom fall-off.
- Angle attenuation for megaphones and sirens.

### Acoustic simulation

- Out of beta on 2026-09-22.
- Settings: `SoundService.AcousticSimulationEnabled`, `BasePart.AudioCanCollide`, `PhysicalProperties.AcousticAbsorption`.
- It gives occlusion, diffraction and reverb automatically, but **only for Audio API sources**, not legacy `Sound`.
- v1 has about 45 `Sound` references. Migrate them.

### Recipes

- **Engines:** 3–4 loop layers (idle, low, mid, high) crossfaded with `AudioFader`. Set `PlaybackSpeed` from RPM and use the `LoopRegion` loops.
- **Guns:** close shot through the emitter, plus a distant "tail" through a second emitter with long attenuation.
- **Sirens:** emitter with angle attenuation.
- **Doppler:** not built in, as far as I can find [UNVERIFIED]. Fake it with `PlaybackSpeed` from radial velocity.
- **Radio:** a 2D bus with an AudioEqualizer "car speaker" EQ. Use **licensed** Creator Store music only.

### Quotas and permissions

- Audio uploads: **100 per month** if ID-verified (10 otherwise), up to 7 minutes each.
- Audio, Video, Animation and Model assets are always "Restricted". The experience needs permission:
  - Creator Hub → experience → Permissions → Assets; or
  - Open Cloud `asset-permissions` (§15).
- AudioPlayer internal volume doubled on 2025-08-29 ([ANN 3907391](https://devforum.roblox.com/t/3907391)). Re-balance any volumes ported from v1.

---

## 13. UI: CanvasGroup and ViewportFrame costs, and the minimap

Sources: [CanvasGroup](https://create.roblox.com/docs/reference/engine/classes/CanvasGroup), [ViewportFrame](https://create.roblox.com/docs/reference/engine/classes/ViewportFrame), [viewport frames guide](https://create.roblox.com/docs/ui/viewport-frames), [Minimap system (battle royale)](https://create.roblox.com/docs/resources/battle-royale/minimap-system), [ANN rotated clipping 4737864](https://devforum.roblox.com/t/4737864).

### CanvasGroup

- Renders its descendants into an **off-screen texture**, which costs extra memory capped by `QualityLevel`. **Above the cap it renders blank.**
- Re-allocates when resized, so keep it a fixed size.
- Requires `ZIndexBehavior = Sibling`.
- Use only where needed: the rounded minimap mask, and fading whole panels with `GroupTransparency`.

### ViewportFrame

- No shadows and no post effects. Neon and Glass render at the lowest quality.
- Ambient light is zero unless a `Sky` child is added.
- It re-renders its scene.
- Good for the dealership and garage turntable (one at a time) and the phone camera.
- **Not** for the weapon wheel or HUD icons: pre-render those to PNGs.

### GTA minimap

1. A pre-rendered top-down map image. The repo already has `tools/minimap`. Split it into ≤ 2048² tiles, because UI textures are not streamed yet [ANN 4144855].
2. Put it in an `ImageLabel` inside a fixed clipping frame. Rotate and translate the image, not the frame.
   - Since 2026-09-24, rotated children clip correctly with `ClipsDescendants` (the property is removed in November 2026).
   - A rounded or rotated *parent* clip still needs a CanvasGroup.
3. Draw the GPS route with `Path2D`.
4. Blips come from the server blip table (§8), not from Workspace.

### Polish

- UI Styling (GA 2026-01-20), UI shadows and per-corner radius (GA 2026-05-14), and the upgraded UIStroke and gradients suit the dark translucent GTA panels.
- **Fonts:** FredokaOne is on the kill list and v1 uses it in 7 places. Font choice is covered in the separate font research.

---

## 14. Avatars and NPCs

Sources: [HumanoidDescription](https://create.roblox.com/docs/reference/engine/classes/HumanoidDescription), [Players](https://create.roblox.com/docs/reference/engine/classes/Players), [Humanoid](https://create.roblox.com/docs/reference/engine/classes/Humanoid), [character appearance](https://create.roblox.com/docs/characters/appearance), [NPC kit](https://create.roblox.com/docs/resources/npc-kit), [using animations](https://create.roblox.com/docs/animation/using), [ANN 3982903](https://devforum.roblox.com/t/3982903), [ANN AJU 4656414](https://devforum.roblox.com/t/4656414), [ANN throttling 4568218](https://devforum.roblox.com/t/4568218), [ANN SLIM avatars 4632702](https://devforum.roblox.com/t/4632702), [ANN animation permissions 3852101](https://devforum.roblox.com/t/3852101).

### Outfits

- Use `Players:CreateHumanoidModelFromDescriptionAsync(desc, R15, verification)` and `Humanoid:ApplyDescriptionAsync`.
  - **The non-Async versions are deprecated** [DUMP]. `NPCService.luau:762/773` uses the deprecated one.
- `AssetTypeVerification` now defaults to **Always**, which means server-verified catalog avatar assets.
  - Custom or non-avatar assets need `ClientOnly`.

### Cost

- Humanoids are expensive [DOC]. Disable unused `HumanoidStateType`s with `SetStateEnabled`, and use no Humanoid for static NPCs.
- Avoid constant spawning and respawning. An `updateInvalidatedFastClusters` marker over 4 ms means too many rebuilds.
  - **Pool** about 30–40 pre-built outfit rigs and `Clone()` them.
- Prefer classic Shirt and Pants plus rigid accessories for pedestrians. Layered clothing is heavier, and v1 logged WrapDeformer fetch errors.

### Scaling

- **SLIM avatars** (`Workspace.EnableSLIMAvatars`) cover **R15 platform avatars** only, plus StarterCharacter since 2026-10-20. NPCs fall back to normal rendering.
- So distant pedestrian crowds must be our own LOD: impostor models or a cheap rig without a Humanoid, using `AnimationController`.
- `ClientAnimatorThrottling` has been always-on since 2026-04-29. It cuts animation CPU 25–30%. Set `Animator.PreferLodEnabled = false` only on hero characters.
- **Avatar Joint Upgrade, phase 2** (2026-05-27; forced by the end of 2026):
  - Motor6D is replaced by AnimationConstraint and BallSocket.
  - Procedural aim, recoil and lean should multiply `AnimationConstraint.Transform` in `RunService.PreSimulation`.
  - Do not edit C0 and C1 or RigAttachments.
  - Ragdolls use BallSockets.

### Animations

- Animations are **Restricted assets**. The experience needs permission, which is automatic when the owner inserts them.
- Owner-uploaded animations plus Adaptive Animation (GA 2026-04-29) let one clip drive any R15 proportions.

---

## 15. Open Cloud endpoints we will call

Base URL: `https://apis.roblox.com`. Use API key auth with the `x-api-key` header. Handle `429` and the `x-ratelimit-*` headers ([rate limits](https://create.roblox.com/docs/cloud/reference/rate-limits), [patterns](https://create.roblox.com/docs/cloud/reference/patterns)). **Never target universe 10767670318.**

### Endpoints

| Purpose | Endpoint | Scope | Rate | Notes |
|---|---|---|---|---|
| Publish a place | `POST /universes/v1/{u}/places/{p}/versions?versionType=Saved\|Published`. Body: raw `.rbxl` (`application/octet-stream`) or `.rbxlx` (`application/xml`). | `universe-places:write` | 30/min | Returns `{"versionNumber": n}`. `Saved` does not go live. **Does not update SurfaceAppearance, PartOperation, Editable* or BaseWrap.** ([guide](https://create.roblox.com/docs/cloud/guides/usage-place-publishing), [ref](https://create.roblox.com/docs/cloud/reference/features/places)) |
| Run Luau (CI, bake, tests) | `POST /cloud/v2/universes/{u}/places/{p}[/versions/{v}]/luau-execution-session-tasks` with `{script, timeout, binaryInput?, enableBinaryOutput?}` | `universe.place.luau-execution-session:write` | create 5/min | Poll `GET /cloud/v2/{task.path}` (200/min). States: `QUEUED`, `PROCESSING`, `COMPLETE`, `FAILED`, `CANCELLED`. Logs: `GET /cloud/v2/{task.path}/logs` (45/min, paged, 450 KB kept). See limits below. ([ref](https://create.roblox.com/docs/cloud/reference/features/luau-execution), [guide](https://create.roblox.com/docs/cloud/guides/instance)) |
| Binary input for a task | `POST /cloud/v2/universes/{u}/luau-execution-session-task-binary-inputs` | same | 5/min | Returns `uploadUri`. Up to 100 MiB, valid 15 min. Read it in the script as `({...})[1].BinaryInput`. |
| Upload an asset | `POST /assets/v1/assets`, multipart: `request` JSON `{assetType, displayName, description, creationContext:{creator:{userId\|groupId}}}` plus `fileContent` | `asset:read`, `asset:write` | — | Types: **Model** (fbx, gltf, glb, rbxm; uploads as a package), **Image/Decal** (png, jpeg, bmp, tga, under 8000²), **Audio** (mp3, ogg, wav, flac, ≤ 7 min, 100 per month verified), Animation (rbxm), Video, Mesh (re-upload only). ≤ 20 MB per call. ([guide](https://create.roblox.com/docs/cloud/guides/usage-assets), [ref](https://create.roblox.com/docs/cloud/reference/features/assets)) |
| Poll an upload | `GET /assets/v1/operations/{id}` | `asset:read` | 300/min | `done: true` gives `response.assetId` and `moderationResult.moderationState`. |
| Update an asset | `PATCH /assets/v1/assets/{id}?updateMask=…` | `asset:write` | — | Content updates are **FBX only**. Metadata updates for anything. |
| Grant asset use to the experience | `PATCH /asset-permissions-api/v1/assets/permissions` (`application/json-patch+json`, `subjectType`, `subjectId`, `assetIds`) | `asset-permissions:write` | — | For Restricted audio, animation and models. |
| Game pass create / update | `POST /game-passes/v1/universes/{u}/game-passes`; `PATCH …/game-passes/{id}`. Multipart: `name` (required on create), `description`, `imageFile` (icon), `isForSale`, `price`, `isRegionalPricingEnabled`, `isManagedPricingEnabled`. | `game-pass:write` | 5/s | List with `GET …/game-passes/creator`. ([ref](https://create.roblox.com/docs/cloud/reference/features/game-passes)) |
| Developer product create / update | `POST /developer-products/v2/universes/{u}/developer-products`; `PATCH …/{productId}`. Same fields; PATCH adds `storePageEnabled`. | `developer-product:write` | 3/s | ([ref](https://create.roblox.com/docs/cloud/reference/features/developer-products)) |
| Localised pass and product icons | `POST /legacy-game-internationalization/v1/{game-passes\|developer-products}/{id}/icons/language-codes/{lang}` | `legacy-game-pass:manage` / similar | 100/min | |
| Game icon and thumbnails | `POST /legacy-game-internationalization/v1/game-icon/games/{universeId}/language-codes/{lang}`; `…/game-thumbnails/games/{id}/language-codes/{lang}/image` | `legacy-universe:manage` | 100/min | **A custom thumbnail has been required for homepage recommendations since 2026-10-19** ([ANN 4945086](https://devforum.roblox.com/t/4945086)). |
| Universe config | `GET/PATCH /cloud/v2/universes/{u}?updateMask=…`: `visibility`, `voiceChatEnabled`, `privateServerPriceRobux`, `desktop/mobile/tablet/console/vrEnabled`; `displayName` and `description` go through the root place. | `universe:write` | 100/min | `ageRating` is exposed. Set maturity through the questionnaire, not the API. ([ref](https://create.roblox.com/docs/cloud/reference/features/universes)) |
| Restart servers after publish | `POST /cloud/v2/universes/{u}:restartServers` | `universe:write` | — | |
| Place config | `PATCH /cloud/v2/universes/{u}/places/{p}`: `displayName`, `description`, `serverSize` | `universe.place:write` | 100/min | |
| Live tunables (no republish) | Configs API: `/creator-configs-public-api/v1/configs/universes/{u}/repositories/{repo}/draft` → `…/publish` | — | — | Launched 2026-03-10; the endpoints are still BETA ([ref](https://create.roblox.com/docs/cloud/reference/features/configs)). Good for economy and wanted-level tuning. |

### Luau Execution limits

- 5 minutes per task.
- Scripts up to 4 MB. Return values up to 4 MB as JSON.
- 10 incomplete tasks per place.
- Task records are kept for 24 h.
- **No physics, and place scripts do not auto-run.**
- **`AssetService:SavePlaceAsync()` persists changes**, but only if the per-place Creator Hub permission "Allow place to be updated using Save Place API" is on, and no Team Create session is open.

### Recommended deploy pipeline

1. `rojo build`.
2. Publish with `versionType=Saved`.
3. Luau Execution **bake** on that version: terrain, city build, MeshPart creation, LOD settings, `SavePlaceAsync({SaveWithoutPublish=true})`.
4. Luau Execution **tests** against the baked version.
5. Promote by publishing, or by `SavePlaceAsync` without `SaveWithoutPublish`.
6. `:restartServers`.

`tools/cloud_smoke.py` already covers steps 2 and 4.

---

## 16. Content maturity for GTA-style guns at Moderate

Sources: [Content maturity and compliance](https://create.roblox.com/docs/production/promotion/content-maturity), [Roblox Kids and Select](https://create.roblox.com/docs/production/publishing/kids-and-select), [ANN publishing requirements 4573166](https://devforum.roblox.com/t/4573166).

### Labels and audiences

| Label | Who can play |
|---|---|
| Minimal / Mild | Roblox Kids (5–8) and Select (9–15). |
| **Moderate** | Select (9–15) and Roblox (16+). |
| Content May Vary | Age-checked 16+ only. |
| Restricted | Age-verified 18+ only. |

- "13+" in the user brief corresponds to a **Moderate** rating. The API also exposes a universe `ageRating` enum (`AGE_RATING_13_PLUS` and others).

### Violence

- Realistic-looking, non-graphic violence or death, such as people falling or ragdolling and a WASTED screen, is **Moderate**. Our gunplay will be "Repeated" frequency.
- The following are **Restricted (18+)**: decapitation, dismemberment, impalement, hanging, mutilation, organs, electrocution, and any realistic consequence that is "graphic".
- Torture, animal abuse, extreme gore and war crimes are not allowed at all.

### Other content rules

| Content | Rule |
|---|---|
| **Blood** | We plan none. Even distant realistic splatter becomes "light realistic blood" (still Moderate). Heavy blood is 18+. |
| **Alcohol** | Any depiction or reference, *including bars and shops that sell alcohol*, makes the game **18+ age-verified only**. Strip all bars, liquor stores, beer billboards and drunk NPCs from GTA-parody content. |
| Strong language | Restricted. NPC chatter, radio and the phone must stay clean. |
| Romantic themes | Restricted. No strip clubs and no "date" missions. |
| Crude humour | Moderate is OK. |
| Gambling | Showing casino imagery that cannot be played is Moderate. **Playable gambling for Robux or Robux-bought items is not allowed.** Treat "pink-slip races" for Robux-bought cars as wagering [UNVERIFIED policy reading]. Restrict them to earned cars, or remove the stake. |
| Paid random items (Robux crates, "1 in X" reveals) | Disclose them, and gate them with `PolicyService:GetPolicyInfoForPlayerAsync().ArePaidRandomItemsRestricted`. |
| Paid item trading (trading cars bought with Robux) | Disclose it, and gate it with `IsPaidItemTradingAllowed`. |
| Guns as such | Do **not** trigger the "sensitive issues" disclosure. The docs' own example is "guns in a first-person shooter game". |

- **Uploaded assets** (images, meshes, audio) with realistic or excessive violence can be moderated *regardless of the game's label*. Keep icons, thumbnails and gun art non-gory.
- Inaccurate answers lead to label removal or replacement and then account action. **Retake the questionnaire whenever content changes.**

### Reaching under-16 (Select) players

Since 2026-05-19, all of these are needed:
- an age-checked owner;
- ID verification;
- 2-Step Verification;
- an active 2-month Roblox Plus or Premium subscription, **or** a one-time refundable fee of 1,000 Robux per game;
- a completed questionnaire;
- an **evaluation**: a 16+-only trial until 250 unique plays from "highly engaged" age-checked users within 60 days.

An expedited review costs a refundable 50,000 Robux. A group-owned game is checked against the **group owner**.

---

## 17. Gotchas that would break us

1. **Rojo publish wipes terrain.** A Rojo `.rbxl` has no voxels, so every Open Cloud publish replaces the place. Bake the terrain (§6, option A) or ship a TerrainRegion.
2. **SurfaceAppearance and unions are not updated by the place-publish API** [DOC]. Cars, guns and hero props built from Rojo files may render untextured live. Ship them as Model assets loaded at runtime, or bake and verify.
3. **Rojo-only MeshParts have no collision or physics data.** Use `CreateMeshPartAsync`, Studio-made `.rbxm` files, or uploaded Models.
4. **`StreamingEnabled = false` in `default.project.json`.** SLIM, Server Authority, MRF, frustum and predictive streaming all silently do nothing.
5. **Turning streaming on breaks v1 assumptions:** start-up `GetDescendants` scans, unguarded `WaitForChild`, client code that assumes the car or map exists, and minimap blips read from Workspace. Audit every client system.
6. **`Lighting.Technology` is deprecated and RobloxScript-only.** `LightingService.luau:470` cannot set it. `LightingStyle` and `PrioritizeLightingQuality` are file-only, and the engine derives both from the file's `Technology` on load, so the file needs `Technology = Future` [EVID look-fix3].
7. **Players on low graphics quality never see shadows** (below level 4), and nothing can force a higher level. A look that depends on shadows collapses on phones.
8. **Atmosphere Density ≥ 0.35 hides the city from the air** (v1 and the lab [EVID]).
9. **MaterialVariant maps cannot be created or changed at runtime** (Plugin security). All variants ship in the file. Only `SetBaseMaterialOverride` swaps them at runtime. Studio did not honour the file's `<Material>Name` overrides in job 0009 (a headless server did), so we also apply them with `SetBaseMaterialOverride` on the server and every client. The docs do not say whether that call replicates.
10. **Normal maps must be OpenGL (+Y)**, and meshes must be exported with tangents. A DirectX map gives inverted bumps, and missing tangents make the map invisible.
11. **Sky faces probably stop at 1024²** (Sky is not in texture streaming yet), and their orientation is undocumented. Run the diagnostic kit before baking any HDRI.
12. **NotScriptable properties do not live-sync through `rojo serve`.** The operator's Studio will not show new streaming or lighting settings until the published place is reopened. The repo pins Rojo 7.6.1 while the lead builds with 7.7.1.
13. **SLIM needs:** a place saved to Roblox, cloud transcode time (1–2 min, then rejoin), static models with no Humanoids, and Team Create for troubleshooting. Local `.rbxl` tests show nothing.
14. **Team Create blocks `SavePlaceAsync`**, so the bake fails while the operator has Team Create open. Schedule bakes when Studio is closed.
15. **Luau Execution creates are limited to 5 per minute**, with a 5-minute run cap and no physics. Batch the bake into one or two tasks. Do not run per-asset tasks.
16. **Audio, animations and models are Restricted assets.** They load only where the experience has permission. Uploads from another account or group need grants, or they fail silently. Audio uploads are capped at 100 per month.
17. **Deprecated APIs in v1:** `CreateHumanoidModelFromDescription` (use the Async version) and legacy `Sound` (no acoustic simulation). `AssetTypeVerification` now defaults to `Always`, which breaks non-catalog outfit assets.
18. **Avatar Joint Upgrade will be forced by the end of 2026.** Any v1 code that edits Motor6D `C0/C1` for aiming or leaning breaks. Move it to `AnimationConstraint.Transform` in `PreSimulation`.
19. **Server-owned AI vehicles** (`SetNetworkOwner(nil)` across Traffic and Police) will exhaust server physics at GTA density. Make ambient traffic kinematic.
20. **Client-owned cars can be teleported and speed-hacked**, and their `Touched` events forged. Validate speed and position on the server and never trust client contacts. Server Authority is the long-term fix.
21. **`RespectCanCollide` defaults to false for raycasts.** Bullets will stop on invisible decorative parts unless those parts have `CanQuery = false`.
22. **Content traps:** any alcohol location means 18+ only; swearing or romance means Restricted. Robux crates and trading need PolicyService gating, and pink-slip wagers on Robux-bought cars are likely gambling. Reaching under-16 players needs ID, 2FA, Plus or a fee, and a 250-highly-engaged-player evaluation.
23. **The place file has a 100 MB publishing limit.** Pre-Expanded-Terrain voxels and duplicated meshes push toward it. Enable Expanded Terrain and keep mesh IDs deduplicated.
24. **Mesh-streaming rollout:** once `MeshStreamingAndImprovedLods` is the default, `RenderFidelity` is ignored and then removed. Do not build LOD logic on it.
25. **CanvasGroup goes blank on low-memory devices** when its texture budget is exceeded. Never put critical HUD (health, wanted stars) inside one.

### Operator jobs this note asks for (to clear the [UNVERIFIED] items)

| # | Test |
|---|---|
| a | Sky diagnostic kit (images listed in §4). |
| b | Rojo-built SurfaceAppearance, published through Open Cloud. Does it render? |
| c | Luau Execution bake (terrain `WriteVoxelChannels` for one 1000×1000 tile, plus `SavePlaceAsync`). Time it, check that it persists, and check that a SurfaceAppearance survives. |
| d | Draw calls for 20 identical cars with different `SA.Color`. |
| e | Whether `MeshPart.RenderFidelity` or `Model.LevelOfDetail` writes from a live game script throw. |
| f | The `SetBaseMaterialOverride` wet/dry swap hitch. |
