# Roblox Creator Store cars: offline inspection and runtime mapping

**Status:** done for the 11-car shortlist from `docs/v2/evidence/scout_0003_report.md`, plus 6 extras. Built 2026-10-27.

**Sheet:** `docs/v2/sourcing/roblox_cars_sheet.png`. Each car is rebuilt in Blender from the files we downloaded, not screenshotted in Studio. The left image is a 3/4 front view. The right image is an orthographic side view.

**Per-car mapping data:** `docs/v2/sourcing/roblox_car_maps/<assetId>.json`. Each file holds every visible part's path, its group, the rule that matched it, the hub positions, and the security findings.

## TL;DR

1. **Seven of the 11 shortlisted cars carry a backdoor.** Six use one malware family, "TextureConfiguration". The box truck uses a second kit. The taxi extra is also infected, and the Maxima extra has a script that moves itself into ServerScriptService.
   - **Where they hide:** inside a `BloomEffect`, a `Decal`, a wheel, the paint part, or code reversed into a string attribute.
   - **What they do:**
     - They `require` or `GetObjects` a remote module whose asset ID is stored in an attribute or a Value.
     - Some variants check `game.JobId` so they stay quiet in Studio.
     - Some hide the CoreGui or inject into StarterCharacterScripts.
   - **Affected cars:** Tundra, police interceptor, police hatch, box truck, Mercedes, Prius, plus the taxi extra.
   - **Payload IDs to blocklist:** `74145699488273`, `75521726909736`, `95925098868592`, `115188487528112`, `128320524036560`, `130049213376589`, `140312253726156`.
   - **Rule:** never parent an inserted Creator Store model into the DataModel before deleting every `LuaSourceContainer`. See section 4.
2. **Every shortlisted car has real-brand marks that must be overridden.**
   - Where they are: textures (Ford oval, Jaguar growler, Toyota/Prius badges, a BMW centre cap on the Kia), real police insignia (Michigan State Police, Ohio State Highway Patrol, Police Nationale), real-format plates, and modelled badges.
   - We override them at runtime by retexturing or hiding the specific parts listed below. We never re-upload the third-party mesh.
3. **Best picks:**
   - **Hero quality:**
     - Jaguar `11881862706`: separate doors, bonnet and boot; clean paint split.
     - Kia Sorento `117276253886376`.
     - F-150 `89890547548224`.
     - Toyota Tundra `126180570128588`: already badged "VELLFIRE", so it is the nearest to parody-ready.
     - Police hatch `103123587729335`: livery baked in a SurfaceAppearance.
   - **Usable after work:** Nissan Murano `73893179863762`, box truck `131180706902259`, Prius `132078381973405`.
   - **Poor fits:**
     - Patrol `14746413121`: 463k tris.
     - Mercedes `97965573521866`: 422k tris, and a backdoor.
     - Police "interceptor" `113053967699143`: a 2010-era brick-built sedan made of 183 Parts, not an SUV.
4. **Wheels are separable on 10 of 11 cars**, so a runtime rig can spin them. The box truck is one 5k-tri mesh with its wheels baked in.
   - On the A-Chassis cars, spinning parts (`Wheels/XX/Parts`) are already split from non-spinning parts (`Wheels/XX/Fixed` or `WheelFixed`).
5. **Scale:** most cars are within ±15 % of 1 stud = 0.28 m. Each map JSON has `suggested_uniform_scale`.
   - Oversized: police hatch ×0.78, police interceptor ×0.67, F-150 ×0.86, Kia ×0.84.

## 1. Pipeline (tools/sources/)

| Step | Tool | Output (under `assets/source/roblox/<id>/`, git-ignored except `meta.json`) |
|---|---|---|
| Download | `python3 -I tools/sources/rbxdl.py <id> [...]`. Open Cloud asset delivery; the key goes only in the `x-api-key` header via `tools/rbxcloud.py key()`. Retries, gunzip/zstd, magic-byte detection, 60 MB cap. | `asset.rbxm`, `.rbxmx`, `.mesh`, `.png`, `.jpg`… and `meta.json` (type, kind, size, sha256, mesh version, or the error such as `403: Asset is not approved for the requester`) |
| Inspect | `lune run tools/sources/rbxm_inspect.luau <asset> <tree.json>`. Uses `@lune/roblox` `deserializeModel`. Strips the `<?xml` prologue and empty `<BinaryString>` values, which rbx-dom otherwise rejects. | `tree.json`: every instance with class, path, Size, CFrame, Color, Material, Transparency, MeshId/TextureID (old and `*Content` properties), SurfaceAppearance maps, SpecialMesh, decals, lights, joints, attributes and tags. Script **sources are never written**. Each script gets a security `Scan` (flags, `require(<id>)`, long numeric literals). |
| Meshes and textures | `python3 -I tools/sources/rbxmesh.py model <id>`, or `convert <in.mesh> <out.obj|glb>` | `assets/source/roblox/<meshId>/mesh.obj`, `mesh.glb`, `mesh.json`; `assets/source/roblox/<imageId>/image.png` (Decal→Image indirection followed); `deps.json` per model |
| Rebuild and render | `python3 -I tools/sources/rbx_to_blender.py <id> [--glb] [--blend]`. Blender 5.2 as a module, Cycles CPU, 32 samples, OIDN, 960×540. | `preview_34.png`, `preview_side.png`, `build.json`; optionally `rebuilt.glb` and `rebuilt.blend` |
| Classify | `python3 -I tools/sources/rbx_car_map.py <id>` | `docs/v2/sourcing/roblox_car_maps/<id>.json` |
| All of the above, plus the sheet | `python3 -I tools/sources/rbx_cars.py run|map|texsheet|sheet [ids]` | `docs/v2/sourcing/roblox_cars_sheet.png`; `assets/source/roblox/<id>/textures_sheet.png` (every texture a car uses, for logo review) |

**Mesh format coverage.** The format comes from the devforum "Roblox Mesh Format" community spec, cross-checked against real payloads.

| Versions | How they were tested |
|---|---|
| 1.00 (text, positions ×0.5, V flipped), 2.00, 3.00, 3.01, 4.00, 4.01 | Parsed from real downloads: 834 meshes, 0 failures. All 25 sampled GLBs reloaded in trimesh with matching triangle counts. |
| 5.00 (v4 header + FACS), 6.00 (chunked COREMESH/LODS), 7.00 (Draco COREMESH v2, via `pip install DracoPy`) | Round-trip tests on synthetic files. Asset delivery served no ≥5.00 mesh for these cars. |

**Full-detail LOD.** Only the faces in `lods[0]..lods[1]` are kept.

**UV orientation.**
- GLB keeps Roblox's top-left UV origin.
- OBJ writes `v' = 1 − v`.

**Rebuild rules.**
- **MeshPart:**
  - The mesh is recentred on its bbox and scaled by `Size / InitialSize`.
  - The `TextureID` alpha is used as a cut-out.
  - SurfaceAppearance AlphaMode Overlay, Transparency and TintMask are honoured.
- **SpecialMesh:** `FileMesh` uses `vertex * Scale + Offset` with no normalisation. Brick, Wedge, Cylinder, Sphere and Head are primitives.
- **Decals and Textures** are projected along the face axis onto the triangles facing that way. That is how Roblox draws decals on MeshParts and cylinders, so tyre treads and wheel photos wrap correctly.
- **Roblox Material** maps to roughness and metalness. Glass, Transparency → alpha; Neon → emission; Reflectance → clear coat.

**Known approximations.**
- **Unions** (`UnionOperation`) are drawn as their bounding box, because CSG geometry is not decoded. None of the 11 shortlisted cars has a visible union. The GMC extra has 64.
- **Top and Bottom decal "up" direction** is inferred: hood text reads correctly from the front. It is not verified in Studio.
- **Moderated images** (403 "not approved") are skipped: 2 on the Prius and 1 on the interceptor. They would not render in-game either.

## 2. Shortlist summary

| Asset | Depicts | L × W × H (studs) | Scale to 0.28 m/stud | Visible parts | Unique meshes | ~Tris | Textures | Scripts | Backdoor |
|---|---|---|---|---|---|---|---|---|---|
| `89890547548224` | 2009-14 Ford F-150 SuperCrew 5.5 ft bed | 24.4 × 10.56 × 8.03 | ×0.862 | 24 | 11 | 19k | 8/8 | 27 | no |
| `11881862706` | Jaguar XKR-S GT | 19.14 × 7.99 × 5.25 | ×0.894 | 210 | 185 | 107k | 93/93 | 24 | no |
| `14746413121` | Nissan Patrol Y61 5-door | 18.78 × 8.36 × 6.93 | ×0.96 | 101 | 92 | 462k | 3/3 | 31 | no |
| `117276253886376` | Kia Sorento XM 2011 | 19.84 × 9.17 × 7.58 | ×0.844 | 44 | 29 | 18k | 8/8 | 4 | no |
| `73893179863762` | Nissan Murano Z50 2005 | 16.69 × 9.06 × 6.41 | ×1.021 | 20 | 16 | 38k | 2/2 | 16 | no |
| `126180570128588` | 2022 Toyota Tundra CrewMax (badged "VELLFIRE") | 22.08 × 8.76 × 7.27 | ×0.959 | 41 | 35 | 41k | 4/4 | 1 | **YES** |
| `113053967699143` | brick-built 2000s police sedan (Crown Victoria proportions) | 27.0 × 14.05 × 9.38 | ×0.712 | 183 | 1 | 2k | 8/9 | 13 | **YES** |
| `103123587729335` | Peugeot 308-style Police Nationale hatchback | 19.39 × 9.96 × 7.26 | ×0.783 | 57 | 35 | 29k | 3/3 | 5 | **YES** |
| `131180706902259` | Isuzu NPR-style 16 ft box truck | 25.59 × 9.14 × 12.24 | ×0.977 | 3 | 1 | 5k | 1/1 | 2 | **YES** |
| `97965573521866` | Mercedes-AMG GLE 53 4MATIC+ coupe SUV (listed as sedan) | 17.92 × 7.88 × 6.14 | ×0.985 | 107 | 95 | 422k | 1/1 | 25 | **YES** |
| `132078381973405` | Toyota Prius XW30 2010 | 16.04 × 7.44 × 5.93 | ×0.993 | 96 | 90 | 15k | 10/12 | 3 | **YES** |

Notes on the columns:
- **~Tris** sums LOD0 triangles over the visible MeshParts. A Part counts as 12.
- **Textures** counts images that downloaded and decoded, out of those referenced.
- **Scale** is the real length ÷ 0.28 ÷ model length. A 17-stud sedan is the city reference (`gta_realism_gap.md` §1).

## 3. Proposed runtime mapping spec

The target is the existing **CarBuilder HeroShell contract**, read from `src/shared/Vehicle/CarBuilder.luau` lines 1–40 and not changed here:
- A procedural `Chassis` holds `WheelFL`… attachments at the hub centres.
- Visual `Wheel_FL`… parts are driven by `WheelWeld_FL`… C0 from `WheelAnimator`.
- `Paint` attributes are `primary`, `accent` or `glass`.
- `Headlight` and `Taillight` lamp parts exist.
- A store model becomes `AssetLibrary.Hero[key]` (`Config/Assets` `source = "store"`) and is cloned in as `HeroShell`.

Today that shell is one rigid lump: the procedural wheels hide under it, and its paint and lights are inert. The map JSON gives the shell the structure it needs.

### 3.1 Groups (per visible BasePart; a Decal follows its part)

| Group | Becomes | Rule order (first match wins) |
|---|---|---|
| `Wheel_FL/FR/RL/RR` | WeldConstraint to the procedural `Wheel_XX`, which is moved to the shell hub (`hubs.XX.center`, radius `hubs.XX.radius`), so the shell wheel spins and steers. | 1. Descendant of a wheel container (`Wheels/FL`… A-Chassis, or a round part named FL/FR/RL/RR). 2. Wheel-ish name: wheel, tire/tyre, rim, hub, rotor, disc, pneu, jante. 3. Geometry: the biggest round part (Ball, Cylinder, or two equal dimensions) low in each corner, plus everything inside its radius. The quadrant comes from the position in the car frame. |
| `WheelStatic_XX` | WeldConstraint to Chassis at the hub (no spin). Steer-follow can come later. | Under a wheel container but inside `Fixed`, `WheelFixed`, `Caliper` or `Plaquette`. |
| `Lights_Head` / `Tail` / `Brake` / `Reverse` / `Indicator_L` / `Indicator_R` / `Emergency` | Attribute `Lamp=<kind>`. The light controller toggles Material Neon or brightness. Procedural `Headlight` beams are re-pivoted to the `Lights_Head` centroid. | Name matches light, lamp, led, drl, indicator, signal, brake, reverse, fog, tail, head, phare, feu, clignot, gyro (not headrest); or Material Neon; or a Light child. Saturated red parts in the rear quarter count. So do parts sharing a dedicated lamp texture (≤6 users, ≥30 % already lamps). The subtype comes from the name, then colour or position. |
| `Glass` | Attribute `Paint=glass`. | Material Glass; or name matches glass, window, windscreen or vitre (not trim, contour or frame); or 0.15 ≤ Transparency ≤ 0.85 with a dark colour. |
| `Plate` | Our own plate decal replaces the texture. | Name matches plate, licence, plaque or matricula. |
| `Interior` | Static. Can be dropped for LOD or traffic. | Name matches interior, seat, dash, steer, gauge, needle, speedo, siège or volant. |
| `Paint` | Attribute `Paint=primary` plus `BaseColor`, so it is recolourable. | Untextured parts whose Color equals the paint colour. The colour comes from parts named paint, body colour, carrosserie or COLOR; if none are named, from the area-dominant chromatic colour. |
| `PaintBaked` | Static. Recolouring needs our own ColorMap. | The named body part carries a TextureID or SurfaceAppearance, so `Color` does nothing. |
| `Body` | Static, welded to Chassis. | Everything else that is visible. |
| *(hidden)* | Dropped. | Transparency ≥ 0.98: A-Chassis wheel balls, axles, seats, downforce parts. |

### 3.2 Selector grammar used in this doc and in `groups.*.selectors`

- Paths are relative to the asset's root Model.
- `#k` means the k-th child with that name, counting in file order. The JSON lists the full explicit paths too.
- `/**` means every visible descendant.
- `{a, b}` means alternatives.

Runtime resolution:
1. Resolve the selectors on the sanitised clone.
2. Check that the resolved count equals `groups.*.count`.
3. If a count differs, because the asset was updated or sibling order changed, fall back to the rule table above on the live instances.

The rules use only Name, Material, Color, Transparency, TextureID and position, all of which Luau can read.

### 3.3 Integration checklist (for the vehicle owner, not done here)

1. **Configure the asset.**
   - Add a `Config/Assets.Hero` entry: `source="store"`, `fit="length"`, `size = dims_studs.length × suggested_uniform_scale`, `yaw = assetsYaw` (from the JSON).
   - `AssetLibrary` sanitises store models with a whitelist (`STORE_KEEP` = BasePart, DataModelMesh, SurfaceAppearance, Model, Folder). That already removes every script before parenting, so the backdoors in §4 cannot run (`AssetLibrary.luau:96-122,166`).
   - **Add `Decal` and `Texture` to `STORE_KEEP`.** Tyre treads, wheel photos (Murano, Patrol, Prius), plates and the interceptor's livery are Decals, and today they would vanish. A Script nested *inside* a Decal (the Prius does this) is still removed, because the whitelist is checked per descendant.
2. **Ship the groups.** Convert `roblox_car_maps/<id>.json` → `groups.*.paths`, `hubs` and `paint` into a Luau table per car (generated, like `kitgeo.py luau`). Ship those tables, not the JSON.
3. **Apply them in `applyShell`.**
   - Tag the parts: `Paint=primary` on `Paint`, `Paint=glass` on `Glass`, `Lamp=*` on lamps.
   - Weld `Wheel_XX` to the procedural wheel and hide that wheel's cylinder.
   - Set the `WheelFL`… attachments and `WheelRadius` from `hubs`, times the fit scale.
   - Weld `WheelStatic_XX` to the Chassis.
4. **Override brands** using the per-car list in §5. Hide the part, or set our own `TextureID` or SurfaceAppearance. Never re-upload the third-party mesh.
5. **Watch the budget.** MeshParts cost draw calls; Roblox auto-LODs them. The Patrol (463k tris) and Mercedes (422k) are too heavy for traffic. Use them as hero or garage cars only, or not at all.

## 4. Security: backdoors in 7 of 11 shortlisted cars

The six "TextureConfiguration" models share one kit (the box truck and Maxima rows below are different):
- A `Script` named to look like an engine feature: `CoreTextureSystem`, `CoreSkyboxSystem`, `Package`, `PoseTexture`, `PoseLink` or `qTexture`.
- It hides somewhere a quick look misses:
  - inside a `BloomEffect` named `BloomDefect`;
  - inside a wheel `Decal`;
  - inside the `PAINT` part;
  - at the model root, under `NumberPose`, `AlignPosition` or `RigidConstraint` chains.
- A `ModuleScript` named `TextureConfiguration` sits beside it. It is about 9 KB of plausible "texture preset" code with a `Version` attribute holding an asset ID.
- The loader runs `require(script:WaitForChild("TextureConfiguration", 4):GetAttribute("Version"))` or `.Module.Value`. That is a remote module, so the attacker can change behaviour at any time.
- The `CoreSkyboxSystem` variant checks `game.JobId` so it stays dormant in Studio.
- A `LocalScript` sets `script.Parent = nil` and turns off every CoreGui, hiding chat and the menu.

| Asset | Where | Payload IDs found |
|---|---|---|
| `97965573521866` Mercedes | `Model/BloomDefect/CoreTextureSystem` (+ LocalScript) | `74145699488273` |
| `132078381973405` Prius | `Body/Model/PAINT#1/CoreSkyboxSystem`, `Wheels/Wheel#4/Decal/Package` | `115188487528112`, `130049213376589` |
| `126180570128588` Tundra | `CoreSkyboxSystem` (root) | `95925098868592` |
| `103123587729335` Police hatch | `PoseTexture` (root) | `140312253726156` |
| `113053967699143` Police interceptor | `BloomDefect/ExtraData/Shifter/PoseLink` | none visible (obfuscated) |
| `131180706902259` Box truck | Different kit. `MeshPart/DO NOT DELETE/Material` (a 10 KB fake "texture streaming" Script) clones a `Credits` ScreenGui into StarterGui. Its LocalScript un-reverses a `PlaneConstraint` attribute into `game:GetObjects('rbxassetid://75521726909736')…Parent = StarterCharacterScripts`. | `75521726909736` |
| `94301391128632` Taxi (extra) | 5 nested copies under `Object.5240` | `115188487528112`, `128320524036560`, `140312253726156` |
| `951086064` Maxima (extra) | `…/LeanPatcher/Patcher/ThrottlePatcher` runs `script.Parent = game.ServerScriptService`. This is a 2016-era free-model "virus" pattern. | none |

`rbxm_inspect.luau` flags these patterns without writing any source:
- `require-by-attribute`, `studio-evasion(JobId)`, `self-hide`, `coregui-toggle`;
- `odd-parent:<class>` (a script under a PostEffect, Light, Decal or Sky);
- `backdoor-family:TextureConfiguration`;
- `string-reverse-loop`, `injects-into-services`;
- `code-in-attribute`: any string attribute that holds `GetObjects`, `require(`, `loadstring` or an asset URL, forwards or reversed.

`rbx_car_map.py` collects the payload IDs from attributes and Values anywhere under a flagged script, and from 10+ digit literals. The scout's Studio inserts were safe because Studio sandboxes inserted scripts and the scout deleted them. A runtime `LoadAssetAsync` path is only safe because `AssetLibrary` strips scripts before parenting. Keep it that way.

<!-- PER_CAR_BEGIN -->
## 5. Per-car notes and mapping

"Mapping" lists the selectors from `roblox_car_maps/<id>.json`. The JSON holds the full path lists. Wheel groups that differ only by corner are folded into one row. `yaw` is the `Config/Assets` value that turns the front to −Z.

### 5.1 `89890547548224` Ford F-150 XLT SuperCrew (4/5, recommended pickup)

`Ford F-150 XLT Supercrew`. Depicts: 2009-14 Ford F-150 SuperCrew 5.5 ft bed.

- **Size:** 24.4 × 10.56 × 8.03 studs. Scale ×0.862, yaw 0.
- **Front from:** `seat:DriveSeat`.
- **Parts:** 24 visible (24 MeshParts, 11 unique meshes, ~19,523 tris). 17 hidden, 32 decals, 0 SurfaceAppearance, 27 scripts.
- **Look:** Clean red crew cab built from a few layers: one Paint shell MeshPart, a detail-atlas MeshPart (`Body/Texture`: grille, lamps, trim baked in), and Chrome and Underbody parts. Very light: 11 meshes, 19k tris. It is 16 % oversized for our scale.
- **Wheels:** A-Chassis. `Wheels/XX/Parts` holds Tyre, Rim and Disk, which spin; the tread and sidewall come from decals. `Wheels/XX/Fixed/Caliper` stays static. The hidden `Wheels/FL…` balls (3.5 studs) are the hubs.
- **Paint:** A single MeshPart, `Body/Model/Paint`, rgb(196,40,28), Reflectance 0.05. It is fully recolourable.
- **Glass:** Every window is one dark MeshPart, `Body/MeshPart#1` (Transparency 0.5).
- **Lights:** There are **no separate lamp meshes.** Head and tail lamps are painted into the `Body/Texture` atlas, so the Lights groups are empty. The rig must add its own emissive lamp quads at the lamp positions.
- **Logos:** The Ford oval (TextureID 3652511491) is on `Body/MeshPart#3` and `#4` (grille and tailgate). The "F-150 XLT 5.4 TRITON" badge (3652526999) is on `Body/MeshPart#2`. Override all three TextureIDs with our parody badges. The tyre-sidewall decal 323779525 is generic.
- **Other:** 27 scripts (A-Chassis and plugins). No backdoor pattern.

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 3/3/3/3 | `Wheels/FL/Parts/**` (the same pattern for each corner) |
| WheelStatic_{FL,FR,RL,RR} | 1/1/1/1 | `Wheels/FL/Fixed/**` (the same pattern for each corner) |
| Paint | 1 | `Body/Model/**` |
| Glass | 1 | `Body/MeshPart#1` |
| Body | 6 | `Body/{Chrome, MeshPart#2, MeshPart#3, MeshPart#4, Texture, Underbody}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-3.50, -2.27, +8.10) r=1.74, FR (+3.29, -2.27, +8.24) r=1.74, RL (-3.33, -2.27, -7.10) r=1.74, RR (+3.66, -2.27, -6.96) r=1.74.

### 5.2 `11881862706` Jaguar XKR-S GT (5/5, best hero: sports)

`XKR-S GT`. Depicts: Jaguar XKR-S GT.

- **Size:** 19.14 × 7.99 × 5.25 studs. Scale ×0.894, yaw -180.
- **Front from:** `seat:DriveSeat`.
- **Parts:** 210 visible (206 MeshParts, 185 unique meshes, ~107,060 tris). 20 hidden, 0 decals, 0 SurfaceAppearance, 24 scripts.
- **Look:** The most complete model:
  - 210 MeshParts with a full interior (gauges, needles, steering wheel).
  - **Separate opening doors** (`Misc/FL`, `Misc/FR`), **bonnet** (`Misc/HK`) and **boot** (`Misc/TK`).
  - GT wing and bonnet stripes.
  - At 107k tris it suits hero, garage or dealership use, not dense traffic.
- **Wheels:** A-Chassis. `Wheels/XX/Parts` holds 7 meshes (tyre, rim layers, centre cap), which spin. `Wheels/XX/WheelFixed` holds the caliper and disc, which stay static. `Misc/Wheel` is the steering wheel and is excluded.
- **Paint:** Twelve `Meshes/Paint*` parts on the body, doors, bonnet and boot, rgb(9,137,207), untextured, so the car is fully recolourable. The bonnet stripes are a separate textured part (`Misc/HK/…Stripes…`).
- **Glass:** Ten parts: Window*, Glass*, windscreen and the `Red Glass` tail lens.
- **Lights:** 31 `Light(s).*` MeshParts that share the lights atlas, split by position into 13 front and 18 rear. There are no Neon parts or SpotLights. Brake and indicator areas are regions of the atlas, so each cluster can only switch as a whole.
- **Logos:** Heavy:
  - JAGUAR lettering textures 4790631987 (`Body/Model/Meshes/XKRS_Badges…`), 4790647681 (`Misc/TK/…/Transparency.004`) and 4790636670 (calipers, `Wheels/XX/WheelFixed/…Transparency.001`).
  - Growler centre cap 4790637601 (`Wheels/XX/Parts/Model/Meshes/wheel (1)`).
  - The growler is also in the shared interior and lights atlas (dash dials), visible only in the cabin.
  - Override the 4 badge textures. The atlas logo can stay for v2.
- **Other:** 24 scripts. No backdoor pattern.

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 7/7/7/7 | `Wheels/FL/Parts/**` (the same pattern for each corner) |
| WheelStatic_{FL,FR,RL,RR} | 2/2/2/2 | `Wheels/FL/WheelFixed/**` (the same pattern for each corner) |
| Paint | 12 | `Misc/FL/Door/Model/{Meshes/Paint.006 (1), Meshes/Paint.007 (1)}`; `Misc/HK/Model/Meshes/Paint.001_Transparency.006_bonnet_ok.001`; `Misc/FR/Door/Model/{Meshes/Paint.008 (1), Meshes/Paint.009 (1)}`; `Misc/TK/Model/Meshes/Paint.001 (1)`; `Body/Model/{Meshes/Paint (4), Meshes/Paint.002 (1), Meshes/Paint.003 (1), Meshes/Paint.004 (1), Meshes/Paint.005 (1), Meshes/Paint_Transparency.006_bonnet_ok.003}` |
| Glass | 10 | `Misc/FL/Door/Model/Meshes/Window.001 (1)`; `Misc/FR/Door/Model/Meshes/Window.002 (1)`; `Misc/TK/Model/{Meshes/Glass.001, Meshes/Red Glass (1), Meshes/Window.003 (1)}`; `Body/Model/{Meshes/F Glass (1), Meshes/Glass, Meshes/Window (1), Meshes/Windows (5), Meshes/windscreen_ok.001}` |
| Lights_Head | 13 | `Misc/FL/Door/Model/Meshes/Light (2)`; `Misc/FR/Door/Model/Meshes/Light.001 (2)`; `Body/Model/{Meshes/Light(s).003 (2), Meshes/Light(s).005 (2), Meshes/Light(s).006 (2), Meshes/Light(s).007 (2), Meshes/Light(s).008 (2), Meshes/Light(s).009 (2), +5 more}` |
| Lights_Tail | 18 | `Misc/TK/Model/{Meshes/Light(s).014 (1), Meshes/Light(s).015 (1), Meshes/Light(s).016, Meshes/Light(s).017, Meshes/Light(s).018, Meshes/Light(s).019, +1 more}`; `Body/Model/{Meshes/Light(s) (2), Meshes/Light(s).001 (1), Meshes/Light(s).002 (1), Meshes/Light(s).004 (2), Meshes/Light(s).010 (2), Meshes/Light(s).011 (2), +5 more}` |
| Interior | 26 | `Misc/Speedo/Parts/Needle`; `Misc/Tach/Parts/Needle`; `Misc/Wheel/**`; `Body/Model/{Meshes/XK_Interior, Meshes/XK_Interior.001, Meshes/XK_Interior.002, Meshes/XK_Interior.003, Meshes/XK_Interior.004, Meshes/XK_Interior.005, +12 more}` |
| Body | 95 | `Misc/Speedo/Parts/Part`; `Misc/Tach/Parts/Part`; `Misc/FL/Door/Model/{Meshes/Black.011 (1), Meshes/Mirror.001 (1), Meshes/Silver (1), Meshes/Tex TR.024, Meshes/Tex TR.025, Meshes/Tex TR.026, +12 more}`; `Misc/HK/Model/{Meshes/Black_Transparency.006_bonnet_ok.002, Meshes/Stripes_Transparency.006_bonnet_ok.004}`; … (see JSON) |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-3.05, -1.26, +5.72) r=1.364, FR (+3.03, -1.26, +5.72) r=1.364, RL (-3.27, -1.26, -5.23) r=1.364, RR (+3.26, -1.26, -5.23) r=1.364.

### 5.3 `14746413121` Nissan Patrol Y61 (3/5: right look, far too heavy)

`2005 Nissan Patrol`. Depicts: Nissan Patrol Y61 5-door.

- **Size:** 18.78 × 8.36 × 6.93 studs. Scale ×0.96, yaw -90.
- **Front from:** `seat:DriveSeat`.
- **Parts:** 101 visible (91 MeshParts, 92 unique meshes, ~462,802 tris). 43 hidden, 6 decals, 0 SurfaceAppearance, 31 scripts.
- **Look:** A convincing black Y61 with a chrome grille and roof spoiler. But **463k tris** with several 20k-tri meshes: about 4× the Jaguar and 25× the F-150. Decimating it would mean re-uploading third-party meshes, which is not allowed. Use it only as a single showroom piece, or skip it.
- **Wheels:** Each `Wheels/FL…` Part is the visible wheel: one Part with a SpecialMesh and a wheel-photo Decal on its Top face. Weld the Part itself to the procedural wheel.
- **Paint:** Twenty `*_SUB*` subsets (bodyshell, doors, chassis), rgb(17,17,17), untextured. Recolouring works, but some black trim subsets share the colour, so check per subset.
- **Glass:** Eight `window_*` MeshParts. They are **opaque** (SmoothPlastic, Transparency 0), so set Material Glass and Transparency about 0.4 at runtime.
- **Lights:** The best-labelled lamps of the set: `headlight_l/r`, `extralight_1/2` (fog), `indicator_lf/lr/rf/rr`, `brakelight_l/r`, `taillight_l/r` and `reversinglight_l/r`. There are also hidden SpotLight holders under `Body/Lights/{Headlights, Brakes, Reverse, LeftSignal, RightSignal, Hazards}`. The 2 `arrow` Neon parts are dash indicators.
- **Logos:** The Nissan badge is modelled into the grille mesh, so it cannot be retextured. The Nissan logo also shows on the wheel-photo decal 10000275087. The Qatar plates (16626386735, 16614652644) are in the `Plate` group.

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 1/1/1/1 | `Wheels/FL` (the same pattern for each corner) |
| Paint | 20 | `Body/{6b8a_SUB0, bodyshell_SUB0, bodyshell_SUB1, chassis_SUB4, door_dside_f001_SUB0, door_dside_f001_SUB1, +14 more}` |
| Glass | 8 | `Body/{window_lf, window_lm, window_lr, window_rf, window_rm, window_rr, +2 more}` |
| Lights_Head | 6 | `Body/{extralight_1_SUB0, extralight_1_SUB1, extralight_2_SUB0, extralight_2_SUB1, headlight_l_SUB0, headlight_r_SUB0}` |
| Lights_Tail | 8 | `Body/{safari_detail_SUB0, safari_detail_SUB1, safari_detail_SUB2, safari_detail_SUB3, taillight_l_SUB0, taillight_l_SUB1, +2 more}` |
| Lights_Brake | 4 | `Body/{brakelight_l_SUB0, brakelight_l_SUB1, brakelight_r_SUB0, brakelight_r_SUB1}` |
| Lights_Reverse | 2 | `Body/{reversinglight_l, reversinglight_r}` |
| Lights_Indicator_L | 7 | `Body/{arrow#1, arrow#2, indicator_lf_SUB0, indicator_lf_SUB1, indicator_lf_SUB2, indicator_lf_SUB3, +1 more}` |
| Lights_Indicator_R | 5 | `Body/{indicator_rf_SUB0, indicator_rf_SUB1, indicator_rf_SUB2, indicator_rf_SUB3, indicator_rr}` |
| Plate | 2 | `Body/Front Plate/**`; `Body/Rear Plate/**` |
| Interior | 9 | `Body/{safari_dash_SUB0, safari_dash_SUB1, safari_dash_SUB2, safari_dash_SUB3, safari_dash_SUB4, safari_dash_SUB5, +3 more}` |
| Body | 26 | `Body/{6b8a_SUB1, Part#1, Part#2, bodyshell_SUB2, bodyshell_SUB3, chassis_SUB0, +20 more}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-2.66, -1.94, +6.01) r=1.523, FR (+2.66, -1.94, +6.03) r=1.523, RL (-2.66, -1.94, -4.82) r=1.523, RR (+2.58, -1.94, -4.80) r=1.523.

### 5.4 `117276253886376` Kia Sorento EX 2011 (4/5, recommended crossover)

`2011 Kia Sorento EX`. Depicts: Kia Sorento XM 2011.

- **Size:** 19.84 × 9.17 × 7.58 studs. Scale ×0.844, yaw 0.
- **Front from:** `light-names+long-axis`.
- **Parts:** 44 visible (44 MeshParts, 29 unique meshes, ~18,435 tris). 20 hidden, 32 decals, 0 SurfaceAppearance, 4 scripts.
- **Look:** A clean, correct-looking 2011 Sorento in white: 44 parts, 29 meshes, 18k tris. It is 16 % oversized.
- **Wheels:** A-Chassis. `Wheels/XX/Parts` holds the tyre and the rim with photo decals, which spin. `Wheels/XX/WheelFixed` holds the caliper.
- **Paint:** `paint#1`, `paint#2` and `sorento_Plane.017`, rgb(248,248,248), untextured, so recolourable.
- **Glass:** Five parts, Material Glass.
- **Lights:** Photo-textured. Atlas 6860781390 (photos of real Sorento lamps) is on `sorento_Plane.005`, `.016` and `.018`. Plain red parts `.007` and `.019` are tail lamps. Front is `.016`. An emissive overlay is needed for night.
- **Logos:** A real-car **front photo** (6937989294) is on `sorento_Plane.011`: grille and Kia badge. Every wheel carries a **BMW** centre-cap decal (`Wheels/XX/Parts/Wheel/Rims/InnerSide`, 1521496996) and a rim photo decal (`…/PlaceDecalHereOr3DRim`, 6937462196). Replace all three.
- **Other:** Front direction comes from the lamp names, since the model has no seat. 4 scripts. No backdoor pattern.

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 4/4/4/4 | `Wheels/FL/Parts/**` (the same pattern for each corner) |
| WheelStatic_{FL,FR,RL,RR} | 1/1/1/1 | `Wheels/FL/WheelFixed/**` (the same pattern for each corner) |
| Paint | 3 | `Body/Model/{Meshes/sorento_Plane.017, paint#1, paint#2}` |
| Glass | 5 | `Body/Model/{Meshes/sorento_Plane.020, Meshes/sorento_Plane.021 (1), Meshes/sorento_Plane.022 (1), Meshes/sorento_Plane.023 (1), Meshes/sorento_Plane.024}` |
| Lights_Head | 1 | `Body/Model/Meshes/sorento_Plane.016` |
| Lights_Tail | 4 | `Body/Model/{Meshes/sorento_Plane.005, Meshes/sorento_Plane.007, Meshes/sorento_Plane.018, Meshes/sorento_Plane.019}` |
| Body | 11 | `Body/Model/{Meshes/sorento_Plane, Meshes/sorento_Plane.001, Meshes/sorento_Plane.003, Meshes/sorento_Plane.004, Meshes/sorento_Plane.008, Meshes/sorento_Plane.010, +5 more}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-3.39, -1.85, +6.00) r=1.573, FR (+3.39, -1.82, +5.98) r=1.534, RL (-3.33, -2.15, -5.47) r=1.552, RR (+3.34, -2.17, -5.46) r=1.579.

### 5.5 `73893179863762` Nissan Murano 2005 (3.5/5: good shape, cheap wheels)

`2005 Nissan Murano`. Depicts: Nissan Murano Z50 2005.

- **Size:** 16.69 × 9.06 × 6.41 studs. Scale ×1.021, yaw 0.
- **Front from:** `seat:1`.
- **Parts:** 20 visible (16 MeshParts, 16 unique meshes, ~38,901 tris). 4 hidden, 20 decals, 0 SurfaceAppearance, 16 scripts.
- **Look:** A clean, well-named, light model: 20 parts, 39k tris, already at the right scale (×1.02). Paint, glass and every lamp are separate.
- **Wheels:** `Wheels/FL…` are plain cylinder Parts with a wheel photo (899081061) and tread decals (266213021). They look flat up close, and could be swapped for our own wheel mesh later.
- **Paint:** `Body/Paint/**`: 4 parts, white, recolourable.
- **Glass:** `Body/Windshield/**`, 2 parts.
- **Lights:** `Body/Lights/Headlights/{Headlights Cover, Indicators}` and `Body/Lights/Taillights/{Taillights, Brakelight, Reverse Lights}`. This is a ready-made lamp hierarchy.
- **Logos:** `Body/Badges` (modelled Nissan badges): hide the part. The wheel photo shows no legible logo.
- **Other:** 4 VehicleSeats and 16 scripts. No backdoor pattern.

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 1/1/1/1 | `Wheels/FL` (the same pattern for each corner) |
| Paint | 4 | `Body/Paint/**` |
| Glass | 2 | `Body/Windshield/**` |
| Lights_Head | 1 | `Body/Lights/Headlights/Headlights Cover` |
| Lights_Tail | 1 | `Body/Lights/Taillights/Taillights` |
| Lights_Brake | 1 | `Body/Lights/Taillights/Brakelight` |
| Lights_Reverse | 1 | `Body/Lights/Taillights/Reverse Lights` |
| Lights_Indicator_R | 1 | `Body/Lights/Headlights/Indicators` |
| Interior | 1 | `Body/Interior` |
| Body | 4 | `Body/{Badges, Chassis+Trim, Chrome, Windows Trim}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-3.11, -1.80, +5.14) r=1.396, FR (+3.14, -1.83, +5.14) r=1.365, RL (-2.99, -1.83, -5.08) r=1.374, RR (+3.08, -1.84, -5.04) r=1.365.

### 5.6 `126180570128588` 2022 Toyota Tundra ("2022 Vellfire Prairie") (4/5, recommended pickup; strip the backdoor)

`2022 Vellfire Prairie`. Depicts: 2022 Toyota Tundra CrewMax (badged "VELLFIRE").

- **Size:** 22.08 × 8.76 × 7.27 studs. Scale ×0.959, yaw 90.
- **Front from:** `light-names+long-axis`.
- **Parts:** 41 visible (41 MeshParts, 35 unique meshes, ~41,886 tris). 18 hidden, 6 decals, 0 SurfaceAppearance, 1 scripts.
- **Look:** A 2022 Tundra TRD Pro crew cab in sand: 41 parts, 42k tris, about the right scale (×0.96). The grille already reads **"VELLFIRE"** instead of TOYOTA, so it is the closest to parody-ready: only that word changes.
- **Wheels:** `Wheels/XX/Parts/{Rim, Tire}` spin. There is no static caliper.
- **Paint:** `Body/COLOR#1`, `Body/COLOR#2`, rgb(211,190,150), recolourable.
- **Glass:** Two parts. One is Material Glass; the other is a Transparency 0.65 part.
- **Lights:** `Body/Vehicle_Lights/*`: 14 parts named Left/Right/Light#n, classified by position into 7 head, 6 tail and 1 indicator.
- **Logos:** The "VELLFIRE" lettering is grille geometry, not a texture. A `Body/LicensePlate` part is present. The dirt decals are fine to keep.
- **Other:** Front direction comes from the lamp names and the long axis, since there is no seat. **Backdoor:** `CoreSkyboxSystem` at the root (JobId check, payload 95925098868592).

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 2/2/2/2 | `Wheels/FL/**` (the same pattern for each corner) |
| Paint | 2 | `Body/{COLOR#1, COLOR#2}` |
| Glass | 2 | `Body/{Mesh Part#4, Mesh Part#5}` |
| Lights_Head | 7 | `Body/Vehicle_Lights/{Left#1, Left#3, Light#1, Light#2, Light#3, Right#1, +1 more}` |
| Lights_Tail | 6 | `Body/Vehicle_Lights/{Left#2, Light#10, Light#4, Light#5, Light#6, Right#3}` |
| Lights_Indicator_L | 1 | `Body/Vehicle_Lights/Light#8` |
| Body | 15 | `Body/{Mesh Part#1, Mesh Part#10, Mesh Part#11, Mesh Part#12, Mesh Part#13, Mesh Part#14, +9 more}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-3.21, -2.06, +7.33) r=1.578, FR (+3.25, -2.06, +7.33) r=1.578, RL (-3.21, -2.06, -6.36) r=1.578, RR (+3.25, -2.06, -6.36) r=1.578.

### 5.7 `113053967699143` Police "interceptor" (1.5/5: drop)

`Model`. Depicts: brick-built 2000s police sedan (Crown Victoria proportions).

- **Size:** 27.0 × 14.05 × 9.38 studs. Scale ×0.712, yaw -180.
- **Front from:** `seat:VehicleSeat`.
- **Parts:** 183 visible (0 MeshParts, 1 unique meshes, ~2,504 tris). 2 hidden, 23 decals, 0 SurfaceAppearance, 13 scripts.
- **Look:** **Not** the Explorer-style SUV the scout described. It is a 2010-era brick build: 183 plain Parts and Wedges, Ball wheels and a single FileMesh ring. Its proportions are blocky and it is 27 studs long (×0.71). Its look comes from decals carrying **real agency insignia**: "POLICE", the Michigan State Police patch and the Ohio State Highway Patrol hood seal.
- **Wheels:** Four 3×3×3 Ball Parts, found only by the geometry fallback.
- **Paint:** 101 black parts. The white door panels are separate parts.
- **Lights:** `Light#1-4` plus a Part-built lightbar.
- **Logos:** Every insignia decal (28749523, 31161332, 58407478, 58407686, 32563199) would have to go, which would leave a bare brick car.
- **Other:** **Backdoor:** `BloomDefect/ExtraData/Shifter/PoseLink`. It also holds 170 `Fire` objects. Use the police hatch below or our own cruiser instead.

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 1/1/1/1 | `./Part#6` (the same pattern for each corner) |
| Paint | 101 | `./{Part#1, Part#10, Part#100, Part#103, Part#105, Part#109, +95 more}` |
| Glass | 12 | `./{B, C, Part#111, Part#118, Part#20, Part#25, +6 more}` |
| Lights_Head | 2 | `./{Light#1, Light#2}` |
| Lights_Tail | 2 | `./{Light#3, Light#4}` |
| Interior | 5 | `./{Seat#1, Seat#2, Seat#3, Seat#4, VehicleSeat}` |
| Body | 57 | `./{2#1, 2#2, A, J, Part#101, Part#102, +51 more}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-5.50, -2.78, +9.00) r=1.5, FR (+5.50, -2.71, +9.00) r=1.5, RL (-5.50, -2.80, -8.00) r=1.5, RR (+5.50, -2.77, -8.00) r=1.5.

### 5.8 `103123587729335` Police hatchback (Peugeot 308-style, "LeoRosa44's Car") (4/5 as police or parked prop; strip the backdoor)

`LeoRosa44's Car`. Depicts: Peugeot 308-style Police Nationale hatchback.

- **Size:** 19.39 × 9.96 × 7.26 studs. Scale ×0.783, yaw -176.7.
- **Front from:** `seat:Seat3`.
- **Parts:** 57 visible (48 MeshParts, 35 unique meshes, ~29,693 tris). 70 hidden, 5 decals, 1 SurfaceAppearance, 5 scripts.
- **Look:** A clean Police Nationale livery, lightbar, antennas and interior: 57 visible parts, 30k tris. It is 28 % oversized (×0.78). The part names are French.
- **Wheels:** `Wheels/XX/Parts/{Pneu, Jante, Disque}` spin. `Plaquette` (brake pad) stays static. The A-Chassis-style physics parts (Axle, Arm, #SA/#SB) are hidden.
- **Paint:** **PaintBaked.** The livery is the SurfaceAppearance ColorMap 18777161260 on `Body/Body/Carrosserie`. To make it ours, swap in our own ColorMap painted on the same UVs (layout visible in `assets/source/roblox/103123587729335/textures_sheet.png`), for example a city-PD parody. Color alone does nothing.
- **Glass:** `Vitres` (windows) plus the lamp lenses and lightbar glass.
- **Lights:** `Body/Lights/{HeadLight, HeadLightLeft, LeftF, RightF, LeftB, RightB}`, `Body/Body/Phare*`, and `Body/Emergency/Lightbar/**` (Emergency).
- **Logos:** "POLICE" and "POLICE NATIONALE" with the French tricolour are in the livery. There is an EU-flag plate decal (124053905511758) and a hidden `Body/Taxi` sign variant.
- **Other:** **Backdoor:** `PoseTexture` (payload 140312253726156).

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 3/3/3/3 | `Wheels/FL/Parts/{Disque, Jante, Pneu}` (the same pattern for each corner) |
| WheelStatic_{FL,FR,RL,RR} | 1/1/1/1 | `Wheels/FL/Parts/Plaquette` (the same pattern for each corner) |
| PaintBaked | 1 | `Body/Body/Carrosserie` |
| Glass | 4 | `Body/Body/{Vitre de phare arrière, Vitre de phare avant, Vitres}`; `Body/Emergency/Lightbar/Model/Glass` |
| Lights_Head | 5 | `Body/Body/Phare`; `Body/Lights/{HeadLight, HeadLightLeft, LeftF, RightF}` |
| Lights_Tail | 5 | `Body/Body/{Phare arrière, Phare décoration, Phare décoration 2}`; `Body/Lights/{LeftB, RightB}` |
| Lights_Emergency | 7 | `Body/Emergency/Lightbar/Model/{Lights#1, Lights#2, Support, Top}`; `Body/Emergency/Antennes/Model#2/**` |
| Plate | 7 | `Body/Plaques/**` |
| Interior | 4 | `Body/Body/{Interieur, Interieur 2, Sièges, Volant}` |
| Body | 8 | `Body/Body/{Avant 1, Avant 2, Avant 3, Contours de vitre, Rétroviseurs, Soubassement}`; `Body/Emergency/Antennes/Model#1/**` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-3.56, -2.47, +5.28) r=1.409, FR (+3.25, -2.47, +5.28) r=1.409, RL (-3.35, -2.46, -6.15) r=1.409, RR (+3.01, -2.47, -6.14) r=1.409.

### 5.9 `131180706902259` Box truck ("TruckProp") (3.5/5 as a parked or delivery prop; not drivable)

`TruckProp`. Depicts: Isuzu NPR-style 16 ft box truck.

- **Size:** 25.59 × 9.14 × 12.24 studs. Scale ×0.977, yaw -180.
- **Front from:** `thumbnail-camera+long-axis`.
- **Parts:** 3 visible (1 MeshParts, 1 unique meshes, ~5,023 tris). 0 hidden, 0 decals, 0 SurfaceAppearance, 2 scripts.
- **Look:** A convincing Isuzu NPR-style 16 ft box truck with the roll-up door open. It is **one MeshPart** (5k tris) with a 2010-era atlas texture, plus 2 black helper parts. The scale is right (×0.98).
- **Wheels:** **Not separable.** The wheels are baked into the single mesh, so spinning wheels need our own wheel meshes over hidden baked ones. Use it as a parked prop, or for distant traffic.
- **Paint:** Baked into the atlas (white). Not recolourable.
- **Logos:** No legible brand in the atlas.
- **Other:** **Backdoor (different kit):** `MeshPart/DO NOT DELETE/Material` plus a `Credits` GUI. A reversed string attribute holds `game:GetObjects('rbxassetid://75521726909736')` → StarterCharacterScripts.

| Group | Parts | Selectors |
|---|---|---|
| Paint | 2 | `./{Part, Wedge}` |
| Body | 1 | `./MeshPart` |

### 5.10 `97965573521866` Mercedes-AMG GLE 53 Coupé (scouted as a "sedan") (4.5/5 looks, 1/5 usable: skip)

`Model`. Depicts: Mercedes-AMG GLE 53 4MATIC+ coupe SUV (listed as sedan).

- **Size:** 17.92 × 7.88 × 6.14 studs. Scale ×0.985, yaw 90.
- **Front from:** `seat:DriveSeat`.
- **Parts:** 107 visible (107 MeshParts, 95 unique meshes, ~422,046 tris). 8 hidden, 0 decals, 0 SurfaceAppearance, 25 scripts.
- **Look:** Superb fidelity, with the AMG Panamericana grille and wheels. But it is **422k tris** (95 meshes of about 10k each) and has a backdoor. All parts are named `MeshPart`, so selectors depend on indexes and break if the asset is updated.
- **Wheels:** A-Chassis. `Wheels/XX/Parts/Rim/MeshPart#1-4`.
- **Paint:** `Body/Color/**` (9 parts) plus `Body/MeshPart#8`, white, recolourable.
- **Glass:** Five parts, found by transparency.
- **Lights:** Two Neon heads and 2 Neon indicators; 4 red rear parts are the tail lamps.
- **Logos:** The three-pointed stars on the grille and bonnet are geometry inside generically named parts.
- **Other:** **Backdoor:** `Model/BloomDefect/CoreTextureSystem` (require-by-attribute 74145699488273, a CoreGui-hiding LocalScript).

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 4/4/4/4 | `Model/Model/GLE 53 4MATIC+/Wheels/FL/**` (the same pattern for each corner) |
| Paint | 10 | `Model/Model/GLE 53 4MATIC+/Body/Color/**`; `Model/Model/GLE 53 4MATIC+/Body/MeshPart#8` |
| Glass | 5 | `Model/Model/GLE 53 4MATIC+/Body/{MeshPart#21, MeshPart#3, MeshPart#31, MeshPart#4, MeshPart#7}` |
| Lights_Head | 2 | `Model/Model/GLE 53 4MATIC+/Body/{MeshPart#18, MeshPart#41}` |
| Lights_Tail | 4 | `Model/Model/GLE 53 4MATIC+/Body/{MeshPart#15, MeshPart#19, MeshPart#67, MeshPart#9}` |
| Lights_Indicator_L | 2 | `Model/Model/GLE 53 4MATIC+/Body/{MeshPart#28, MeshPart#69}` |
| Body | 68 | `Model/Model/GLE 53 4MATIC+/Body/{MeshPart#1, MeshPart#10, MeshPart#11, MeshPart#12, MeshPart#13, MeshPart#14, +62 more}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-2.99, -1.67, +5.58) r=1.409, FR (+3.02, -1.67, +5.59) r=1.409, RL (-3.06, -1.67, -5.07) r=1.409, RR (+3.09, -1.67, -5.06) r=1.409.

### 5.11 `132078381973405` Toyota Prius 2010 (3.5/5: good civilian or taxi filler after cleanup)

`2010 Toyota Prius`. Depicts: Toyota Prius XW30 2010.

- **Size:** 16.04 × 7.44 × 5.93 studs. Scale ×0.993, yaw -180.
- **Front from:** `light-names+long-axis`.
- **Parts:** 96 visible (90 MeshParts, 90 unique meshes, ~15,376 tris). 0 hidden, 6 decals, 6 SurfaceAppearance, 3 scripts.
- **Look:** An accurate silver XW30: 96 parts but only 15k tris, with 6 SurfaceAppearances. Scale is right (×0.99).
- **Wheels:** `Wheels/Wheel#1…4`: one MeshPart each with a wheel photo on its Top decal (2641836074), which shows a **Toyota** hubcap.
- **Paint:** `Body/Model/**`: 11 `PAINT` parts, rgb(159,161,172), recolourable. `PAINT#1` also hosts the backdoor script.
- **Glass:** Sixteen parts: door glass, `glass*` and boot glass.
- **Lights:** `Body/light`, `light.001–.005` and `f_brake_ax-10`. The lamp photos are in atlas 9480432754.
- **Logos:** The Toyota emblem, "PRIUS" and "Hybrid Synergy Drive" are in badge atlas 9480432732, on `Body/badge`, `badge_ok.001`, `glass_badge_ok.001` (SurfaceAppearance) and the steering wheel `f_steer.002`. California plate decals (11515452186) are on `Body/Front` and `Body/Rear`. Two moderated images returned 403.
- **Other:** **Backdoor:** two copies, `Body/Model/PAINT#1/CoreSkyboxSystem` and `Wheels/Wheel#4/Decal/Package` (payloads 115188487528112, 130049213376589).

| Group | Parts | Selectors |
|---|---|---|
| Wheel_{FL,FR,RL,RR} | 1/1/1/1 | `Wheels/Wheel#1` (the same pattern for each corner) |
| Paint | 11 | `Body/Model/**` |
| Glass | 16 | `Body/{boot_ok.005, door_lf_ok, door_lr_ok, door_rf_ok, door_rr_ok, glass, +10 more}` |
| Lights_Head | 2 | `Body/{light, light.005}` |
| Lights_Tail | 4 | `Body/{light.001, light.002, light.003, light.004}` |
| Lights_Brake | 1 | `Body/f_brake_ax-10` |
| Interior | 10 | `Body/{f_steer, f_steer.001, f_steer.002, f_steer.003, interior_badge, interior_pisos, +4 more}` |
| Body | 48 | `Body/{Front, Rear, badge, badge_ok, badge_ok.001, block_engine, +42 more}` |

**Hubs** (car frame: x right, y up, z forward; studs, unscaled): FL (-2.52, -1.76, +4.76) r=1.2, FR (+2.52, -1.76, +4.76) r=1.2, RL (-2.52, -1.76, -4.97) r=1.2, RR (+2.52, -1.76, -4.97) r=1.2.

<!-- PER_CAR_END -->
