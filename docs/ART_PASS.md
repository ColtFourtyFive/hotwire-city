# Art pass — making Hotwire City beautiful

The v1 systems ship with procedural geometry so the game always works. The art pass layers real, cohesive art on top of it. **The procedural geometry stays as the fallback**: if an asset fails to load (or runs in the Lune harness), nothing breaks.

## What we have (all owned by the experience owner unless noted)

| Source | Config | Count | Load with |
|---|---|---|---|
| Hero and kit vehicle shells (Meshy and SAM-3 meshes, textured, ≤20k tris) | `Config/Assets.Hero[carId]` (+ `police_unit`) | 33 | `InsertService:LoadAsset` |
| Buildings and landmarks | `Config/Assets.Buildings[role]` | 22 | same |
| Props: nature, street, beach, garage, loot | `Config/Assets.Props[role]` | 41 owned + 12 Creator Store (`source="store"`) | same / `AssetService:LoadAssetAsync` |
| 2D art (billboard ads, logo, loading art) | `Config/Assets.Images[key]` (Content strings) | 12 | direct `rbxassetid://` |
| NPC outfits (avatar catalog) | `assets/curation/vehicles-characters-props.json` roles `npc_*` | ~10 | `HumanoidDescription` |
| Creator Store extras (police helicopter, Endorsed vehicles, etc.) | `assets/curation/*.json` | ~110 | `AssetService:LoadAssetAsync` |

Contact sheets: `docs/previews/hero_meshes.png`, `kit_cars.png`, `kit_buildings.png`, `kit_nature-street.png`, `kit_props.png`, `billboards.png`, `assets/curation/*.png`.

`Server/Systems/AssetLibrary` already loads everything in `Config/Assets` at boot. It normalizes each template as follows:
- Root `AssetRoot` sits at the bottom-centre.
- The front faces -Z.
- It is scaled per its def.
- Every part is anchored, non-colliding and script-free.

Templates are published to `ReplicatedStorage.AssetLibrary.<Category>.<key>`. API: `AssetLibrary.get/clone/Ready/AllReady/waitAll`. The folder carries the attribute `AllReady=true` once loading finishes.

## Workstreams

### AP1 — Vehicle shells (CarBuilder, client and server)

- `CarBuilder.applyShell(model)` looks up `ReplicatedStorage:FindFirstChild("AssetLibrary")` → `Hero[CarId]` (`police_unit` for police). When it exists:
  - clone it and destroy `AssetRoot`;
  - every shell part: unanchored, Massless, CanCollide/CanQuery/CanTouch false, `WeldConstraint` to Chassis;
  - scale to the model's `Length` attribute;
  - align the shell bottom to the ground plane (`pivot.Y - RideHeight`);
  - set procedural visual parts (Paint parts, glass, lights, wheels, rims) to Transparency 1, but keep the parts so attachments, SpotLights and siren logic keep working;
  - set attribute `HeroMesh=true`.

  `build()` calls `applyShell` automatically. It is a no-op in the harness or when the template is missing.
- Mutations on shells: Gold, Diamond and Galaxy clear `TextureID`/`SurfaceAppearance`, then apply the mutation `Color`/`Material` to the shell MeshParts. Rainbow keeps the texture off and cycles colour on the client (WheelAnimator already does this for Paint parts; extend it to shell parts when `HeroMesh=true`). Sparkle emitters still apply.
- **Late arrival.** When a Hero template becomes ready after cars already exist, re-skin every existing model with that `CarId` across Workspace.Vehicles, Workspace.Dealership and every Plot Display, on both the server and the client. Hook `AssetLibrary.Ready` on the server, and `ChildAdded` on `ReplicatedStorage.AssetLibrary.Hero` on the client for client-built Index viewports.
- WheelAnimator skips wheel spin and bob for `HeroMesh` cars (their wheels are part of the mesh) but keeps the rainbow and police siren logic. Police siren flashing must still work: keep `SirenRed`/`SirenBlue` visible (raised slightly above the shell roof) on police shells.
- Tests: the harness has no templates, so `applyShell` is a no-op there. Add a test that fakes a template folder in the harness ReplicatedStorage shim to exercise the code path.

### AP2 — City dressing (MapBuilder + new `Server/Systems/MapDresser`)

- MapBuilder already tags procedural trees as `AssetSlot` (attributes `Category`, `Role`, `Fit`) and rooftop ads as `Billboard`. Extend slots to buildings and props.
  - **Buildings** use roles that match `Assets.Buildings`. Pick by district: downtown gets skyscraper_neon/deco/twist and office_block; midtown gets apartment_balcony, brick_loft, office_block and convenience_store; shops on corners get diner, pizza_shop, donut_shop and gas_station; the beach ring gets hotel_beach, beach_villa and surf_shack; the outer suburbs get suburban_house and beach_villa; the dock/chop side gets warehouse.
  - **Props:** palm_tree_a/b, round_tree, pine_tree, bush, rock, street_lamp (keep a hidden light part with the PointLight + `StreetLight` tag), traffic_light (intersections), bench, fire_hydrant, trash_can, bus_stop, mailbox, newspaper_box, flower_bed, hotdog_stand, fountain (plaza), ferris_wheel and lighthouse (pier), water_tower, lifeguard_tower / beach_umbrella / beach_chair / surfboard_rack (beach), shipping_container / crate_stack / dumpster / car_crusher / oil_barrels (chop shop and docks), road_barrier / traffic_cone (stunt park).
- **MapDresser** runs after `AssetLibrary.waitAll(25)`. For every `AssetSlot` it clones the role's asset onto the slot's ground CFrame. Variants are chosen deterministically from the slot position. It hides or destroys the placeholder only after the clone is placed. Buildings use `fit` to match the lot.
- **POIs:**
  - police_hq, car_showroom, gear_shop, spray_booth and chop_shop meshes sit as **backdrops beside or behind** the functional zones (spray/chop drive-in boxes, dealer pads, gear-shop counter). They must never block a zone or the drive-out paths: assert this with the MapLayout boxes.
  - The procedural signs stay.
  - The `logo_hotwire_city` image goes on big plaza and dealership signs.
- **Billboards:** every `Billboard`-tagged board and the `billboard` prop gets a `Decal` (Front, plus Back when visible) with an `Assets.billboardAds()` image, chosen deterministically.
- **Terrain:** grass terrain in the Park and plaza beds, sand on the beach (keep the procedural sand parts if they are simpler), the water already exists, and `Workspace.Terrain.Clouds` gets a soft cover.
- **Budget (mobile):**
  - ≤ 110 building meshes, ≤ 320 prop meshes, ≤ 9,000 remaining parts;
  - no colliders on small props (collide=false);
  - buildings collide;
  - CastShadow false on small props.

  Measure with the harness (`lune run tools/dump.luau map`) by counting AssetSlots.

### AP2b — Garages, dealership and spawn dressing (PlotService + DealershipService + MapBuilder POI interiors)

- Garage interior AssetSlots along the walls and back corners must stay clear of the slot pads, the aisle, the drop-off, the collect pad and the lock button (assert against MapLayout). Roles: car_lift, tool_chest, tire_stack, oil_barrels, workbench, garage_shelf, neon sign, and a money_pile / gold_bars / safe_vault / trophy cluster. Use deterministic variety per plot.
- Dealership: a `car_showroom` backdrop, pads, flags and banners, `Images.ad_hotwire_motors` banners, palms and a hotdog_stand at the plaza.

### AP3 — NPCs (new `Server/Systems/NPCService`)

- Build R15 templates once with `Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)`. Fill `HumanoidDescription.Shirt`/`Pants`/`HatAccessory`/`HairAccessory` from the curated outfits (pcall; fall back to the blocky dummy).
- **Traffic drivers:** replace the TrafficService block dummies with a seated humanoid clone (anchored, welded to the seat, Humanoid `PlatformStand`, no physics). On carjack they get yeeted (comic ragdoll, removed after 3s).
- **Police officers:** seated in police units. On a bust, one officer steps out beside the player for the BUSTED moment. This is visual only and the officer is removed after 4s.
- **Pedestrians:** 10–14 civilians walk the sidewalk ring of nearby blocks with `Humanoid:MoveTo` and play the walk animation through `Animator` (Roblox default R15 walk/idle animation ids; pcall). They flee from fast cars and ragdoll if hit (Mild: they fall over comically, get up and keep walking, never die). They are server-owned with a low tick rate, and only exist within 400 studs of some player.
- **Shopkeepers** stand at the Gear Shop counter (chef/salesman outfits), the Dealership desk and the hotdog stand, playing idle animations.

### AP4 — Atmosphere, loading screen and radio

- **Loading screen.** Add a `src/first/` folder mapped to `ReplicatedFirst` with `LoadingScreen.client.luau`. It is the only extra LocalScript, as ReplicatedFirst requires. It shows `Images.loading_art` with `Images.logo_hotwire_city`, a progress bar using `ContentProvider:PreloadAsync` of key UI images, and a tip carousel. It calls `ReplicatedFirst:RemoveDefaultLoadingScreen()` and fades out when the game is loaded and `ReplicatedStorage.AssetLibrary.AllReady` is true or 12s pass. Use `default.project.json`, which the lead edits: tell the lead the mapping.
- **Car radio.** Curate 6–10 public **music** tracks from Roblox-owned/APMOfficial audio. Search the toolbox API with `searchCategoryType=Audio` and filter the creator to APMOfficial / Roblox / Roblox Resources, using queries like "upbeat electronic", "hip hop instrumental", "synthwave", "funk", "rock". Verify each is public via `https://apis.roblox.com/toolbox-service/v2/assets/<id>`. Add `Config/Sounds` keys `Radio_*` and implement radio stations in SoundController, playing only while driving. Display the station name, with ◀ ▶ buttons on DrivingUI next to the speedometer and R/T keys. This lives in SoundController + VehicleClient; respect the music setting.
- **Lighting polish** (LightingService): a golden-hour default, a moody neon night, Atmosphere density/haze per time, a stronger bloom at night, and ColorCorrection contrast/saturation. Keep server writes cheap (see PERF-11 fix).
