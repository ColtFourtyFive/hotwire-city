# Roblox Creator Store cars: offline inspection and runtime mapping

**Status:** done for the 11-car shortlist from `docs/v2/evidence/scout_0003_report.md`, plus 6 extras. Built 2026-10-27.

**Sheet:** `docs/v2/sourcing/roblox_cars_sheet.png`. Each car is rebuilt in Blender from the files we downloaded, not screenshotted in Studio. The left image is a 3/4 front view. The right image is an orthographic side view.

**Per-car mapping data:** `docs/v2/sourcing/roblox_car_maps/<assetId>.json`. Each file holds every visible part's path, its group, the rule that matched it, the hub positions, and the security findings.

## TL;DR

1. **Six of the 11 shortlisted cars contain a backdoor script.** The same malware family is in all six, plus the taxi extra (7 of 17 downloaded models).
   - **What it is:** the "TextureConfiguration" loader. It hides inside a `BloomEffect`, a `Decal`, a wheel or the paint part.
   - **What it does:**
     - It `require`s a remote module whose asset ID is stored in an attribute or a Value.
     - Some variants check `game.JobId` so they stay quiet in Studio.
     - A LocalScript disables every CoreGui.
   - **Affected cars:** Tundra, police interceptor, police hatch, Mercedes, Prius and taxi.
   - **Payload IDs to blocklist:** `74145699488273`, `95925098868592`, `115188487528112`, `128320524036560`, `130049213376589`, `140312253726156`.
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
| `89890547548224` | 2009–14 Ford F-150 SuperCrew 5.5 ft bed | 24.4 × 10.56 × 8.03 | ×0.862 | 24 | 11 | 19k | 8/8 | 27 | no |
| `11881862706` | Jaguar XKR-S GT | 19.14 × 7.99 × 5.25 | ×0.894 | 210 | 185 | 107k | 93/93 | 24 | no |
| `14746413121` | Nissan Patrol Y61 5-door | 18.78 × 8.36 × 6.93 | ×0.96 | 101 | 92 | 462k | 3/3 | 31 | no |
| `117276253886376` | Kia Sorento XM 2011 | 19.84 × 9.17 × 7.58 | ×0.844 | 44 | 29 | 18k | 8/8 | 4 | no |
| `73893179863762` | Nissan Murano Z50 2005 | 16.69 × 9.06 × 6.41 | ×1.021 | 20 | 16 | 38k | 2/2 | 16 | no |
| `126180570128588` | 2022 Toyota Tundra CrewMax (badged "VELLFIRE") | 22.08 × 8.76 × 7.27 | ×0.959 | 41 | 35 | 41k | 4/4 | 1 | **YES** |
| `113053967699143` | Brick-built 2000s police sedan (not an SUV) | 27.0 × 14.05 × 9.38 | ×0.71 | 183 | 1 | 2k | 8/9 | 13 | **YES** |
| `103123587729335` | Peugeot 308-style Police Nationale hatchback | 19.39 × 9.96 × 7.26 | ×0.783 | 57 | 35 | 29k | 3/3 | 5 | **YES** |
| `131180706902259` | Isuzu NPR-style 16 ft box truck | 25.59 × 9.14 × 12.24 | ×0.977 | 3 | 1 | 5k | 1/1 | 2 | no |
| `97965573521866` | Mercedes-AMG GLE 53 4MATIC+ coupé SUV (listed as "sedan") | 17.92 × 7.88 × 6.14 | ×0.985 | 107 | 95 | 422k | 1/1 | 25 | **YES** |
| `132078381973405` | Toyota Prius XW30 2010 | 16.04 × 7.44 × 5.93 | ×0.993 | 96 | 90 | 15k | 10/12 | 3 | **YES** |

Notes on the columns:
- **~Tris** sums LOD0 triangles over the visible MeshParts. A Part counts as 12.
- **Textures** counts images that downloaded and decoded, out of those referenced.
- **Scale** is the real length ÷ 0.28 ÷ model length. A 17-stud sedan is the city reference (`gta_realism_gap.md` §1).

DATA_TABLE_PLACEHOLDER
