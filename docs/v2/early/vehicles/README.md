# A4 vehicles v2: evidence

The realistic car roster that replaces v1's procedural cartoon cars. There are 30 car models, converted from CC-BY
Sketchfab sources by `tools/blender/carpipe`, uploaded as Roblox Models we own, and mounted at runtime on v1's arcade
raycast chassis by `Shared/Vehicle/CarBuilder` and `MeshCar`.

## Evidence

| File | What it shows |
|---|---|
| `roster.png` | Every uploaded car model in the studio with its **runtime look**: the paint, livery, glass and sirens the game sets, not the GLB's own materials. Each card shows the brand and model, the class, triangles, length in studs and the vehicle id. |
| `street_day.png` | Nine rigged cars on the golden-hour street. Each part is placed by the CarBuilder rig dump (`rig_dump.luau`): the template's built-pose CFrame and the rigged CFrame, with the front wheels steered 0.35 rad and every wheel spun through `WheelAnimator.wheelC0`. The police cruiser's lightbar lenses are lit. |
| `street_night.png` | Another nine cars on the wet night street, with headlamps and lightbar lit and front wheels steered. |
| `cloud_probe.json` | **Real engine** (Open Cloud Luau Execution on the game place). All 30 uploads load with `InsertService:LoadAsset` in 0.2–2.4 s. For each one it lists every instance the GLB importer made and the runtime writes CarBuilder relies on: `Body.TextureID`, `Color`, `Material`, and `MeshPart.Size` scaling. All of these succeed. `tests/spec/vehicles_v2.spec.luau` rebuilds the cruiser's imported tree from this file and runs `CarTemplates.prepare` on it. |
| `cloud_rig.json` | **Real engine.** This checkout's modules are bundled into the task (`cloud_rig_test.py`), then: `CarTemplates.loadAll()` loads 30/30 templates in about 2 s; CarBuilder builds 32 cars (one per model plus both police units), all as mesh cars; one server `VehicleController` step runs per car with no error; and a procedural car is converted in place by `applyMesh`. Per car it records 15–21 parts, AssemblyMass 1100–3000, the 4 suspension attachments, the seat, and that the wheel MeshParts sit on their welds and on the ground plane (worst 0.05 studs). |

The execution server does **not** step physics: it fires no PreSimulation ticks, and an unanchored part never falls (probed). Driving feel therefore stays a Studio playtest item.

## Roster (`tools/blender/carpipe/roster.json` → `src/shared/Config/Vehicles.luau`)

| Class | Car (vehicle id) | Source (CC-BY) |
|---|---|---|
| compact | Halden Wren (`wren`), Tamura Nami (`nami`) | DZ Milano '95, Ace '11 |
| hot hatch | Tamura Kaze (`kaze`) | rifdanzz '91 hatch |
| sedan | Tamura Aoi (`aoi`), Tamura Sena (`sena`), Halden Brookline (`brookline`) | DZ Kiri '10, Tozzo '98, Illinois '90 |
| luxury / limo | Kronberg K8 (`k8`), Kronberg K8 Pullman (`k8_pullman`) | DZ Trinity '03; the limo is the same car with a carpipe stretch cut, +72% length |
| muscle | Marlowe Ironside (`ironside`), Marlowe Kingsnake (`kingsnake`) | DZ Duke '69, '71 455 |
| lowrider | Marlowe Caliente (`caliente`) | mrkuza '64 lowrider |
| sports | Tamura Hayate (`hayate`), Tamura Shiden (`shiden`) | DZ JDM Sport '99, Lexyc16 S14 |
| super / hyper | Rossetti Ardente (`ardente`), Rossetti Furia (`furia`), Ashcombe Vireo (`vireo`), Velacor Nyx (`nyx`) | DZ '84 / V12 '95, s0h1o9b 2017 supercar, ollitei fictional V12 |
| SUV / pickup / van | Oakridge Trailhead (`trailhead`), Halden Bracken (`bracken`), Tamura Kuma (`kuma`), Halden Hauler (`hauler`) | DZ Urban '10, Lightbody '90, Conquer '89, Shvan '92 |
| taxi | Halden Brookline Cab (`brookline_cab`), Halden Metro Cab (`metro_cab`) | DZ Illinois '90 taxi, Canyon '75 taxi |
| police | Halden Brookline Interceptor (`brookline_interceptor`), Oakridge Trailhead Patrol (`trailhead_patrol`) | DZ Illinois '90 cruiser, Urban '10 enforcer |
| service / heavy | Halden Hauler Medic (`hauler_medic`), Brennan Vaultline (`vaultline`), Brennan Cargo 30 (`cargo`), Brennan Transit 40 (`transit`), Brennan Firebrand Ladder (`firebrand`) | DZ Shvan ambulance, MD '84 armored, LCT 3000 '07; own.guest town bus; overseerover12 ladder truck (6 wheels) |
| motorcycle | **deferred** | The chassis is a 4-attachment raycast car with an `Upright` AlignOrientation used only when airborne. A bike needs 2-wheel suspension, lean and its own controller. `mid-poly-street-motorcycle-6c576c` is the pick when that lands. |

DZ = Daniel Zhabotinsky. Full credits are in `assets/ATTRIBUTION.md` ("Shipped: Vehicles v2"), generated together with `Config/Vehicles`.

**Names.** All brands are our own: Halden, Tamura, Kronberg, Marlowe, Rossetti, Ashcombe, Velacor, Oakridge and Brennan. The model names are our own too. `vehicles_v2.spec` fails on any GTA name (Phoenix, Cheetah, Burrito, Dukes, Infernus, Banshee, Stallion, GTA makes…), on any real make, and on any of the source models' own names.

## Decisions

1. **The GLB importer, measured in the real engine.** The importer:
   - makes one MeshPart per GLB object, inside an `<Object>_Node` Model, with names kept;
   - turns the geometry 180° about Y (front at +Z) and leaves identity part rotations;
   - drops colour factors, leaving grey Plastic;
   - turns PBR sets (Trim, Interior, Wheels) into SurfaceAppearances;
   - turns a lone base map (Lights, Sign) into a TextureID.

   `CarTemplates.prepare` does not hard-code any of this. It solves the import frame (yaw, translation and uniform scale) from the four wheel MeshParts against the sidecar, so a future importer change still lands right.
2. **Paint.** The Body goes into the GLB *untextured*, and `MeshPart.Color` is the paint.
   - **Strip-route** cars (the source paint was its own material) are untextured, and the colour is the whole look.
   - **Tint-mask** cars (paint inside an atlas) get the carpipe *overlay* PNG as an uploaded Image, set as `Body.TextureID` at runtime. Paint pixels are transparent there, so the Color shows through.
   - **Liveries** (police, taxis, ambulance, armored truck) get the full baked body texture as the TextureID.
   - The **TintMask SurfaceAppearance path** (`<id>_Body_tintmask.png`, `AlphaMode = TintMask`, scripted `SurfaceAppearance.Color`) keeps shading inside the paint, but it can only be authored in Studio, because SurfaceAppearance maps are not scriptable. It is documented in `tools/blender/carpipe/README.md` for hero cars and not used yet.
3. **The rig keeps the v1 contract** (`MeshCar`). This means:
   - an invisible Chassis sized from the Body (curb-safe floor at 0.75 studs) with the class mass;
   - `WheelFL..` attachments at the true axles;
   - wheel MeshParts on `WheelWeld_XX` welds, which WheelAnimator spins, steers and bobs; extra axles spin with the rear;
   - the DriverSeat at the sidecar hip point, and bump stops;
   - invisible `Headlight` / `Taillight` anchors carrying the Beam SpotLights, plus Brake and Reverse PointLights;
   - lightbar lenses `SirenRed` / `SirenBlue`. carpipe splits them by texture colour; they are Neon on police units, which EffectsController flashes;
   - a taxi `TaxiSign`.

   VehicleService, VehicleController, WheelAnimator, Traffic, Police, Garage, Dealership and the Index use the cars unchanged.
4. **Fallback and late arrival.**
   - With no template ready (Lune harness, still loading, failed load, `assetId = 0`), CarBuilder builds the v1 procedural car with `MeshPending = <vehicle>`.
   - When the template arrives, `CarBuilder.applyMesh` converts the car **in place**. The Model, Chassis, seat and prompts are kept, so other systems' references stay valid. On the server this is VehicleService's `CarTemplates.Ready` handler; on the client it is the WheelAnimator template watcher for Index previews.
   - v1 hero shells never dress a v2 car, and AssetLibrary no longer loads them.
5. **Ids are stable.** Every v1 id with a realistic counterpart keeps its id and its v1 economy, with a new name and model.
   - `rustbucket` is now the Halden Wren and stays `Economy.STARTER_CAR`.
   - The meme and fantasy cars (monster trucks, hover, tank, rocket, hot dog, duck, couch, toilet, ice cream) left the catalog. `Config/CarAliases` maps each to the closest-value realistic car, and `Cars.get` resolves aliases.
   - New ids: `metro_cab`, `tamura_sena`, `tamura_aoi`, `tamura_kuma`, `brennan_cargo`, `halden_medic`, `brennan_transit`, `kronberg_k8`, `marlowe_caliente`, `brennan_firebrand`, `ashcombe_vireo_lm`, and the Secret prototypes `kronberg_sovereign` and `velacor_nyx_prototype` (LOOP_V2 §2.10).
   - Police units: `Cars.Police` (cruiser) and `Cars.PoliceSUV`.
6. **BACKLOG 6.** Spawned models are named `<carId>_<VehicleId>`. Street kinds roll a factory paint from the model's palette; liveries are excepted.
7. **BACKLOG 4 (chase-camera clipping).** WheelAnimator fades any car whose box holds the camera (`LocalTransparencyModifier` 0.85, checking the driven car first, then the 3 nearest). The camera never sits inside an opaque body panel.
8. **BACKLOG 3 (skids and smoke)**, observer side, in WheelAnimator:
   - smoke rate ×1.3 (was 0.8);
   - darker skid trails (transparency 0.12 → 0.3 → 1);
   - drift FX only on the real rear pair, so bus and truck tandem axles don't double it.

   The driver's own smoke and marks are in VehicleClient and the shared presets are in Config/VFX. Both are outside this package; see open issues.

## Numbers

| | |
|---|---|
| Car models | 30, plus 2 police units sharing them. 35 catalog cars and 10 aliases; the motorcycle is deferred. |
| Uploads | 30 Models, all moderation **Approved**. 9 body Images (8 Reviewing at upload time, 1 Approved). Recorded in `assets/vehicles/manifest.json`. |
| Triangles | 6.1k (Ashcombe Vireo) to 15.8k (Tamura Hayate) per car, 12.8k on average; every car ≤ 18k and every MeshPart ≤ 20k |
| Instances per car | 15–21 BaseParts: 8–13 MeshParts, chassis, seat, 2 bump stops, 4 light anchors |
| Template load (engine) | 30 / 30 in about 2 s, 4 in parallel |
| Gates | selene 0/0, stylua clean, Lune tests all passing (including the new `vehicles_v2.spec`), `rojo build` |

## Open issues

- **Studio playtest needed.** In the real engine we have yet to see:
  - driving feel at realistic scale (wheel radius 0.9–2.3, mass by class);
  - Neon on TextureID lens MeshParts at night;
  - Glass at 0.35;
  - the body overlay alpha over `Color`;
  - siren flashing on the mesh lenses;
  - the camera fade.
- **Garage pads are 16 studs** (v1 plots). Realistic cars run 13–26 studs, the bus is 44 and the ladder truck 38. The bus and ladder truck carry `oversize = true` and `street = false`. Plot and dealership pad sizing belongs to A1 / C1.
- **Driver-side drift FX (BACKLOG 3)** need the VFX owner: raise the `TireSmoke` rate and opacity and the `SkidMark` opacity in Config/VFX, and verify VehicleClient's skid-contact height on mesh cars in a stationary drift test.
- **8 body Images were still in moderation review** at upload time. If one is rejected, `gen_vehicles.py` drops it, and that car shows a flat Body colour (liveries go white). Re-run `upload_roster.py --status` and then `gen_vehicles.py`.
- **LOOP_V2 §2.10** wants the Diamond Dragster re-tuned (bound, $300/s, top speed 160) before it is sold. Its v1 economy is kept here; that is Monetization's / C1's call.
- **Leftover marks on some models.** Some DZ liveries carry generic text ("POLICE", "TAXI", "AMBULANCE", "911"), and plates carry the authors' handles (for example "LEXY 6"). There are no makes or logos. Badge meshes and centre-line emblem geometry are dropped by carpipe.
- **Second police unit and service vehicles.** `Cars.PoliceSUV` is ready, but PoliceService still spawns only `Cars.Police`. Escalating to the SUV at higher wanted levels belongs to C2. Traffic can use the bus and service vehicles once C2's kinematic traffic lands.
