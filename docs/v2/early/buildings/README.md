# A3 buildings: evidence

The production building set placed on the v2 world by `BuildingService`'s own planner, rendered in Blender from the
**uploaded GLBs** (`assets/buildings/glb`), with the surfaces the game applies at runtime.

Pipeline: `tools/world/gen` (parcels) → `lune run tools/blender/buildkit/export_placements.luau` (runs
`BuildingService.planAll`, writes `_cache/placements.json`) → `python3 -I tools/blender/buildkit/render_city.py`.
The render emulates the runtime surfaces: `rbxmat.surface` per part, the plan's wall finish and glass tint, the
place's HC_ MaterialVariant maps box-projected at their StudsPerTile, the atlas Images on the GLB UVs, and lit
windows from the plan's night state. Roads, sidewalks, lamps, palms and cars are preview-only context; the ground is a
flat plane, not the world's terrain.

| Image | What it shows |
|---|---|
| `downtown.png` | Pinnacle Heights skyline from the south-west: the planned towers (160 × 160 lots, 220–645 studs, hero crowns), free-standing slabs, office mid-rises, brick walk-ups at the edge |
| `downtown_street.png` | Street level in the core: curtain-wall, ribbon and grid towers on stone podiums with lobbies and name boards |
| `midtown.png` | A Midtown street: composite rows of brick / stucco walk-ups and shops (awnings, signs, fire escapes) under office towers |
| `beach.png`, `beach_aerial.png` | Palmera Beach: art-deco hotels and apartments (blade signs, eyebrows, cafe terraces), muted pastels |
| `suburbs.png` | Southgate: ranch / Spanish / two-storey tract houses with yards, garages, pools and fences, a corner walk-up |
| `downtown_night.png` | Same skyline at NightFactor 1: per-building lit windows (warm / cool, ~12 % of buildings dark), neon crowns and canopies |
| `cloud_probe.json` | Real-engine probe (Open Cloud Luau Execution): 11 uploaded Models load with InsertService in 0.23–0.37 s, every part present, front at −Z, surfaces apply |

## Decisions (with evidence)

1. **Surfaces are applied at runtime, not baked into the upload.** A probe upload (`95401734300558`, downloaded and
   read with Lune) showed that the GLB importer drops glTF colour factors (every MeshPart grey Plastic), turns a lone
   base-colour image into `TextureID` (a new Image asset) and a PBR set into a SurfaceAppearance (four new Image assets).
   SurfaceAppearance maps are not scriptable. So the uploads carry geometry and UVs only (0.06–1.4 MB each), and
   `Config/Buildings` holds each part's surface:
   - tiling roles (walls, trim, roofs, details, lots) → `Enum.Material` + the place's global PBR MaterialVariants
     (`Brick` → HC_BrickRed, `Plaster` → HC_Stucco, `Concrete` → HC_Concrete, per-part HC_BrickTan / HC_ConcreteModern /
     HC_CorrugatedMetal), tinted with Look's colour contract. MaterialVariants are projected per face at StudsPerTile on
     MeshParts, so scaling a building never stretches its brick;
   - atlas roles (window interiors, shop signs, brands, awnings) → `MeshPart.TextureID` with four shared Images;
   - towers / offices → mirror curtain wall (`SmoothPlastic` + HC_WindowGlass, tinted per building);
   - WindowsLit → Neon, `Transparency = 1` by day, lit per building over dusk; Neon parts → SmoothPlastic by day.
   Noted in `docs/v2/research/roblox_tech.md` §3.
2. **Orientation:** the importer turns the model 180° about Y, so the kit's front (Blender −Y) arrives at Roblox −Z,
   the parcel CFrame's LookVector. Verified on the real upload (awning at z = −33, rear doors at z = +31) and in the
   engine probe.
3. **Fit before stretch.** Each parcel is matched by family (use + style), footprint and height; scale stays within
   `Config/Buildings.Fit` (width 0.86–1.14, depth 0.72–1.12, height 0.85–1.18, facade anisotropy ≤ 0.24). Wide urban
   frontages become rows of 2–3 buildings (131 rows). Shallow (25–45 deep) and narrow (34–40 wide) lots got their own
   variants instead of distortion.
4. **Content rules:** the sign atlases no longer carry "LUCKY LIQUOR", "COLD BEER" or "LOTTO" (alcohol makes the
   experience 18+; lottery is gambling). Grime decals are not shipped (TextureID alpha is a hard cut-out).

## Numbers (generator parcels of 2026-10-27)

| | |
|---|---|
| Parcels | 1,330 (232 open lots, 1,098 built) |
| Buildings | 1,238: 1,195 templates, 28 procedural parking decks, 15 procedural massing (1.2 %) |
| Variants | 155 uploaded Models (tower 34, office 10, midtown 42, deco 15, retail 8, house 19, villa 5, mansion 8, industrial 14); 147 used, max 33 copies of one |
| Uploads | 155 Models + 7 Images, all moderation **Approved** (`assets/buildings/manifest.json`) |
| Parts | ~14,500 BaseParts city-wide (budget 22,000 → core roles only, 26,000 → massing); 9–16 MeshParts per building |
| Triangles | 0.7k (house) to 20.6k (600-stud tower) per building, largest MeshPart 8.3k (limit 20k); 4.3 M city-wide |
| Height fit | median error 0 %, p90 10 % |

## Open issues

- The renders use the generator's parcels directly. The game reads `Config/WorldData` / `WorldServerData` (A1's bake)
  or `Config/WorldLayout`; when A1 lands, re-run `export_placements.luau` and the renders.
- Studio screenshots of the dressed city are still needed (operator job): MaterialVariant scale on the scaled
  MeshParts, the TextureID atlases, WindowsLit at dusk, and draw calls on mobile.
- Hillside lots: buildings sit at the parcel's street grade; stilt lots get a 24-stud concrete plinth. A terrain-aware
  foundation needs A1's ground height query.
- Streaming: each building is one Model with `ModelStreamingMode = Atomic` (it streams in whole). Towers beyond
  `StreamingTargetRadius` are not sent at all, so the far skyline needs A1's skyline proxies or a baked
  `LevelOfDetail = StreamingMesh` (file / bake only, not settable at runtime).
- Until the v2 MapBuilder lands, `BuildingService` stands down on the v1 map (its `Map.Buildings` holds v1 slots), so
  main keeps booting the v1 city unchanged.
- Not instanced in a strict sense: per-building wall tints split draw-call batching between buildings of one variant.
