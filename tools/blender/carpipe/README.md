# carpipe: realistic car import and rig pipeline (Blender, then Roblox)

`carpipe` takes **any realistic car model** and produces a **Roblox-ready car GLB** plus a **JSON sidecar**. Supported inputs:

- `.glb` `.gltf` `.fbx` `.obj` `.blend` `.usd*` `.ply` `.stl`
- `.dae` `.3ds` `.off` `.wrl` `.x3d`, as geometry only, through pymeshlab

Typical sources are Sketchfab downloads, OpenGameArt, Khronos samples and Creator Store exports.

It replaces the procedural car modelling under `tools/blender/carkit/`, which produced blobs (`docs/v2/proto/carkit/dev/body_sedan_34.png`).

```
python3 -I tools/blender/carpipe/fetch_models.py                 # test cars + CC0 HDRIs/textures -> _cache/
python3 -I tools/blender/carpipe/build_car.py --model carconcept # or: --in any/car.glb --name sedan01 --length 17
python3 -I tools/blender/carpipe/validate_glb.py tools/blender/carpipe/out/carconcept/carconcept.glb
python3 -I tools/blender/carpipe/render_car.py --model carconcept    # before/after renders -> docs/v2/proto/carpipe/
```

Requirements: Blender 5.2 as a Python module (`import bpy`), numpy, Pillow and pymeshlab. Always run with `python3 -I`. A GLB that is already under budget builds in 1–5 minutes on 4 CPU cores. Cycles bakes take most of that time.

## Output contract

Output goes to `tools/blender/carpipe/out/<name>/`, which contains `<name>.glb`, `<name>.json`, `textures/*.png` and `islands_debug.txt`.

**Coordinates.** The GLB is +Y up and the car's front faces **−Z**, which is the Roblox `LookVector` and the "built pose" in `CarBuilder.luau`. The origin sits on the ground plane, centred between the wheel contact patches. 1 unit = 1 stud. The default length is 17 studs; set it with `--length` or a per-model `length`.

**Objects.** The Open Cloud importer turns one object into one MeshPart, so the GLB holds exactly one object, and one material, per role:

| Object | What it holds | Material in the GLB | Budget (tris) |
|---|---|---|---|
| `Body` | primary paint | **no texture**: base colour = source paint, so recolour with `MeshPart.Color`. Tint-mask route if the paint lives inside an atlas (see below). | 7000 shared with Body2 (≤ 8000 total) |
| `Body2` | secondary paint (two-tone, cladding) if the source has one | untextured, recolourable | share of the 8000 |
| `Glass` | all windows | untextured, dark tint, alpha 0.45 (use Material=Glass) | 700 |
| `LightsFront` / `LightsRear` | head- and tail-light lenses and housings | baked colour + emissive (toggle Material=Neon) | 450 each |
| `Trim` | chrome, black plastic, grilles, badges, mirrors, plates, calipers, exhausts, underbody | 1024² baked atlas: colour·AO, metal/rough, normal | 2600 |
| `Interior` | seats, dash, steering wheel, door cards (only what can be seen through the glass) | 512² baked atlas | 1500 |
| `WheelFL` `WheelFR` `WheelRL` `WheelRR` | tyre, rim, brake disc. **The origin is the wheel centre** (node translation), the axle is X, and steered front wheels are straightened. | one shared 512² atlas | 900 each |

Every car is ≤ 18,000 triangles and every MeshPart is ≤ 20,000. Textures are ≤ 1024 px PNG. `validate_glb.py` checks all of this, plus the wheel centres and the front direction.

**Sidecar (`<name>.json`)** has the following fields. All values are in studs and Roblox coordinates.

- `dimensions`: length, width, height, wheelbase, track widths and the bounding box.
- `wheels.FL/FR/RL/RR`:
  - `center` is the true axle point;
  - `radius` and `width`;
  - `part_center` is where Roblox will put the MeshPart, which is its bounding-box centre;
  - `attachment_offset` is the axle point relative to the part;
  - `steer` is true for the front axle.
- `seats.driver` and `seats.passenger`: the hip point, taken from seat geometry when it is named, else estimated (`estimated: true`).
- `lights.front` and `lights.rear`: positions per side, plus a direction.
- `exhausts`, `center_of_mass_hint`.
- `paint`: the route, the default colour, and how to recolour.
- `objects`: triangles, bounding box and texture files per object.
- `triangles`: source count versus output count.
- `orientation`: the front/back vote breakdown.
- `classes`: island counts per role.
- `source`: licence and attribution, which must stay with the asset.
- `warnings`.

## Recolouring in Roblox

There are two routes. The sidecar's `paint.route` says which one a car uses.

- **strip** (default): the source has its own paint material. `Body` and `Body2` are exported untextured, and `MeshPart.Color` is the paint. Optionally, for panel-line detail, build a SurfaceAppearance from the extra maps:
  - ColorMap: `textures/<name>_Body_ao.png`
  - NormalMap: `<name>_Body_normal.png`
  - `AlphaMode = TintMask`
  - then script `SurfaceAppearance.Color`.
- **tintmask**: the paint lives inside an atlas texture, as with the OpenGameArt and low-poly game models. `Body` keeps its baked texture so it imports looking right. carpipe also writes two extra files:
  - `<name>_Body_tintmask.png`: alpha = 1 on paint pixels, and paint RGB is flattened to neutral shading. Use it as the SurfaceAppearance ColorMap with `AlphaMode = TintMask`, then set `.Color`.
  - `<name>_Body_overlay.png`: paint pixels are transparent. Set it as `MeshPart.TextureID` and the part's `Color` shows through.

SurfaceAppearance maps cannot be set by scripts at runtime, so the SurfaceAppearance has to be authored in Studio. Its `Color` tint *can* be scripted.

`roblox/CarpipeRig.luau` is a reference adapter that converts an imported carpipe Model plus its sidecar into the existing car model contract from `src/shared/Vehicle/CarBuilder.luau`:

- the `Chassis` PrimaryPart;
- `WheelFL..` attachments;
- `Wheel_FL` parts with `WheelWeld_FL`;
- `DriverSeat`;
- `Headlight` / `Taillight` with `Beam` spotlights;
- `Paint` attributes;
- `RideHeight` and the other model attributes.

With it, `VehicleService` and `WheelAnimator` can drive a carpipe car unchanged. `sidecar_to_luau.py out/*/*.json` turns the sidecars into a Luau spec table. Neither file has been run in Roblox yet, and nothing in `src/` has been changed.

## How it works (`carpipe/`)

1. **`importer.py`** imports any format and then:
   - flattens hierarchies, applies modifiers (subdivision is capped at 1), and realises collection instances;
   - bakes transforms, flipping normals where an object was mirrored;
   - removes cameras, lights and armatures;
   - keeps each part's ancestor names (`cp_path`) for classification;
   - auto-discovers textures for materials that have none, by name or through an explicit `textures` map, which helps with OBJ files that lack a `.mtl`;
   - fills in plausible PBR values from material names (chrome, tyre, plastic and so on) where the importer left defaults.
2. **`analyze.py`** joins everything into one working mesh and works per face and per **island**. An island is a connected part, after welding by position, that never crosses a source object.
   - **Junk removal.** Drops ground and shadow planes and backdrops, by name and by size.
   - **Orientation.**
     - The length axis is the longer horizontal extent.
     - The front is chosen by a weighted vote, and the sidecar records every term:
       - names: front/head/hood/grille versus rear/tail/trunk/exhaust;
       - red tail-light colours (sampled from textures; ignored on red cars);
       - white emissive headlights;
       - deck height, because the taller end is the rear;
       - the cabin's roof peak;
       - side-mirror position.
     - `front` / `up` overrides exist for the rare miss.
   - **Wheels.**
     - Finds disc-shaped islands near the bottom corners, or ones with wheel/tyre/rim names, one per side per axle.
     - Takes the radius from the vertical extent, so steered wheels still measure right.
     - Pulls in every island inside each wheel's cylinder: rim, disc and hub. Calipers stay on the body.
     - Measures steer with PCA and straightens it.
     - Grounds the car at the wheel contact point and scales it to the target length.
   - **Roles.** Applied in this order:
     1. Config regex overrides.
     2. Keyword tables matched on the material name, then on the object path. A weak "body"/"panel" material name loses to an "Interior..." path.
     3. Material properties: transmission or alpha means glass, emission means light, bright metal means trim.
     4. **Ray-cast visibility** from outside, with and without the glass. Hidden islands are dropped (engine, axles, insides of panels), and islands seen only through glass become Interior.
     5. **Clear-coat overlay shells** (a duplicate body with a black or transparent glossy material) are dropped before the visibility test.
     6. **Paint**: the body-named or largest visible material becomes `Body`. A second paint-named material holding more than 10% of the paint area becomes `Body2`.
     7. Lights are split front/rear by position. Everything else is `Trim`.
3. **`optimize.py`** handles the meshes:
   - splits roles into objects;
   - welds;
   - drops crumbs when a part is far over budget;
   - decimates (Blender collapse, symmetric for the body, falling back to pymeshlab quadric decimation when collapse stalls on open boundaries);
   - sets smooth-by-angle shading;
   - unwraps a fresh atlas UV, shrinking the islands that face the ground.
4. **`bake.py`** runs Cycles selected-to-active bakes from the original high-res parts:
   - base colour, roughness, metallic and emission, through an emission proxy so metallic paint doesn't bake black;
   - a tangent normal map;
   - AO on the low mesh, multiplied into the Trim, Interior and Wheel colour.

   It also builds the paint tint mask: the dominant colour in the body atlas, matched by chroma, with a brightness band.
5. **`pipeline.py`** assigns final materials, puts the wheel origins at the axle, exports the GLB and writes the sidecar.
6. **`render.py`** and **`render_car.py`** make the preview renders:
   - the studio cyclorama;
   - a GTA-like four-lane street at golden hour (the Poly Haven `sunset_jhbcentral` HDRI, with the sun lamp aligned to the HDRI sun);
   - a wet night street with sodium lamps;
   - before (raw import) versus after, a role breakdown, and paint variants.

## Adding a car

- **Sketchfab.** `sketchfab_fetch.py search "taxi"`, then `sketchfab_fetch.py get <uid> --id my_taxi`. This needs `SKETCHFAB_API_TOKEN` or `~/.config/hotwire/sketchfab_token`. It refuses NC, ND and SA licences, writes `SOURCE.json` and registers the car in `models_local.json`. Then run `build_car.py --model my_taxi`.
- **Any file.** `build_car.py --in file --name id [--length 17] [--front -y]`.
- **Config keys** go in a `models.json` / `models_local.json` entry, or in a `--config` JSON file:

| Key | What it does |
|---|---|
| `length` | Target length in studs. |
| `front` / `up` | Override the axes, in the file's Blender axes after import. |
| `textures` | `{material: image}`. Add `"_no_fuzzy": true` to turn off name matching. |
| `roles` | `{regex: Role}`, where Role is Body, Body2, Glass, LightsFront, Trim, Interior or Discard. |
| `budget` | `{Object: tris}`. |
| `paint_default` | Default paint colour as sRGB 0–1. |
| `select` | Regex that picks one car out of a multi-car pack. |
| `subsurf_cap` | Maximum subdivision level when applying modifiers. |

**Quality check: always look at `docs/v2/proto/carpipe/<id>_roles.png`.** Mis-classified parts show up immediately in that render. `islands_debug.txt` lists every island with its role, visibility and the reason it was classified that way.

## Test cars

`models.json` and `models_local.json` record the licence and attribution for each car.

| id | Source | Licence | Notes |
|---|---|---|---|
| carconcept | Khronos glTF Sample Assets | CC-BY 4.0 | 213k → 17.0k tris. Two-tone paint (Body + Body2) and clear-coat. The hardest test. |
| fairheaven_lt | Sketchfab, Daniel Zhabotinsky | CC-BY 4.0 | Fictional 1980 sedan, a game-ready glTF (19.7k → 13.3k tris). |
| goblin_supercar | Sketchfab, ollitei | CC-BY 4.0 | 86.6k tris, an atlas body and a clear-coat overlay shell (dropped). Uses the tint-mask route. |
| fairheaven_cop, canyon_taxi, shvan_van | Sketchfab, Daniel Zhabotinsky | CC-BY 4.0 | Fictional cop cruiser, taxi and van. |
| musclecar | OpenGameArt, brightretro | CC-BY 3.0 | OBJ with no `.mtl` (textures mapped in `models.json`, material presets). |
| corrado | OpenGameArt, rohezal | CC0 | One atlas material, centimetre units, length along X. Rebrand before shipping. |
| uaz452 | OpenGameArt, Mehozavr | CC0 | FBX van, atlas. |
| camaro | OpenGameArt, Lotnik | CC-BY 3.0 | `.blend`, untextured and unnamed parts. Robustness only. |
| bmw27 | blender.org benchmark | **unverified** | Collection instances and subdivision. Robustness only, do not ship. |

`SOURCING.md` evaluates the options for getting 20+ realistic cars: Sketchfab API, Creator Store and AI image-to-3D. It includes a shortlist of 32 fictional CC-BY cars.

## Known limits

- Front/back detection is a vote. Low-poly models with an atlas texture and no names can still fail. Check `orientation.confidence` in the sidecar, and set `front` if it is low.
- Wheels must be separate geometry, meaning their own islands. A body welded to its wheels, as in most AI meshes, is not split.
- 6-wheel trucks are named `WheelM*`. `CarpipeRig` only wires FL/FR/RL/RR.
- Lights that are only painted into a texture get **estimated** positions (`estimated: true`).
- The interior is decimated hard (1.5k tris). That is fine behind tinted glass, but rough close up.
- Paint in an atlas needs SurfaceAppearance authoring in Studio, because TintMask textures can't be set from scripts.
