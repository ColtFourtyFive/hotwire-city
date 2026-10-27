# Building kit (procedural, Blender 5.2)

Parametric generators for Hotwire City buildings in a grounded GTA V / Los Santos-Vice City look. Every building comes
out as a few mesh objects, one per material role. Open Cloud turns each object into one MeshPart, so a building is
about 10 to 20 MeshParts, each under 20k triangles. Textures are CC0 and 1024 px.

Scale is 1 Blender unit = 1 stud. A storey is 12-13 studs, a door about 8, a parked car about 16.6 long.

## Quick start

```bash
cd /home/user/HotwireCity
python3 -I tools/blender/buildkit/fetch_assets.py      # Poly Haven CC0 textures + sky HDRIs + OFL fonts -> _cache/ (idempotent)
python3 -I tools/blender/buildkit/gen_textures.py      # window/sign/brand/awning/grime atlases + grey tint bases -> out/textures/
python3 -I tools/blender/buildkit/build.py --arch house --seed 3 --render /tmp/h.png      # quick look
python3 -I tools/blender/buildkit/build.py --arch tower --seed 5 --kw '{"floors":30,"style":"fins","crown":"spire"}' --render /tmp/t.png
python3 -I tools/blender/buildkit/manifest.py          # export every archetype x 4 seeds + out/manifest.json + out/texlib/
python3 -I tools/blender/buildkit/render_kit.py --all  # hero renders -> docs/v2/proto/buildkit/
```

To debug winding, run `build.py ... --backfaces --render x.png`. It renders back faces red. Roblox culls back faces,
so anything red is wrong. The awnings and umbrellas are double-sided on purpose.

## Archetypes (`build.py --arch`)

| arch | district | what it is | main parameters (`--kw` JSON) |
|---|---|---|---|
| `tower` | downtown | Glass or steel office tower. Stone podium with a glass lobby, name board and canopy. Shaft segments with 0-2 setbacks. Facade systems `curtain`, `ribbon`, `grid` or `fins`. Crowns `mech`, `spire`, `stepped`, `slant` or `helipad`. Cooling towers, gantry and antennas on the roof | `W D floors style crown setbacks glass frame stone name_idx` |
| `midtown` | midtown | Brick, painted-brick or stucco mid-rise. Punched windows with frames, sills, keystones and quoins. Fire escape, balconies, AC units, storefronts with awnings and signs, cornice, water tank, bulkhead | `W D floors wall pastel frame party:["left","right"]` |
| `strip` | commercial | LA mini-mall: 3-6 storefronts under a canopy (flat or clay mansard), fascia signs, a parking lot with stalls and a pylon sign | `units unit_w bd canopy stucco` |
| `corner_store` | commercial | 24/7 store with posters, a lit brand fascia, an ice chest, a propane cage, bollards and front parking | `W bd stucco` |
| `gas` | commercial | Branded canopy with 3 pump islands (6 pumps), kiosk store, price pylon, concrete forecourt and air machine | `W D` |
| `diner` | commercial | Stainless roadside diner with rounded ends. Ribbed skirt, ribbon of booth windows, colour stripe and neon, rooftop EAT sign, parking | `bw stripe` |
| `deco` | beach | Ocean-Drive art-deco hotel: centre tower bay with fins and a blade sign, eyebrows, racing stripes, portholes, cafe terrace with umbrellas, parapet neon | `W D floors accent blade tower_rise` |
| `house` | suburbs | LA ranch, Spanish or two-storey tract house. Hip or gable roof in clay or shingle with fascia, soffit and gutters. Two-car garage, driveway, entry, AC unit, block or wood fence, optional pool, mailbox | `style floors roof roof_form stucco fence pool garage W D` |
| `warehouse` | industrial | `metal` corrugated shed (gable, ridge vents, clerestory) or `tiltup` concrete box (panel joints, parapet, skylights). Docks with roller doors, seals, bumpers and lights, plus a drive-in door, an office annex with a sign, a truck court and dumpsters | `style bw bd h docks siding brand` |
| `mansion` | hills | Modern hillside villa. Stone plinth reaching `base_depth` below grade, glass ground floor, cantilevered white upper box, timber slats, thin roof slabs with soffit lights, glass balustrades, infinity pool, garage and drive | `W D base_depth stone slats cantilever gw pool_w` |

All randomness comes from `Building.rng`, which is seeded by `crc32("<arch>:<seed>")`. A seed reproduces the same
building in any process. Any parameter you pass in `--kw` overrides the random choice for it. Lot origin is the
bottom-centre of the lot at grade, and the street side is -Y (glTF +Z). Retail, house, warehouse and mansion
include their own lot: parking, driveway, lawn, fences, pool and so on. Tower, midtown and deco cover the lot
edge to edge, so the city's sidewalk meets the facade.

## Material roles (one mesh object = one MeshPart each)

| role | used for | material kind | in Roblox |
|---|---|---|---|
| Walls / Walls2 / Walls3 | main / secondary / tertiary facade | tiling PBR (`tint` in JSON) | SurfaceAppearance; tintable sets (stucco, painted brick, plaster, metal siding, CMU, precast) are grey bases, so tint with `SurfaceAppearance.Color` |
| Trim | sills, cornices, copings, fascias, slabs | tiling PBR | SurfaceAppearance |
| Accent, Frames, Paint | stripes, doors, mullions, parking paint | plain colour | `Color` + `Material`, recolourable at runtime |
| Glass | every window, UV'd into `windows_day.png` (16 interior cells) | atlas + low roughness, metalness for mirror glass | SurfaceAppearance |
| Clear | glass balustrades | see-through | `Material=Glass`, Transparency ~0.65 |
| Roof / Roof2 | tar, gravel, clay tile, shingle, corrugated | tiling PBR | SurfaceAppearance |
| Details / Doors | AC, tanks, rails, pumps, vents / roller and garage doors | tiling metal / shutter | SurfaceAppearance |
| Awning, Sign, Brand | awnings / storefront signs (`signs.png`) / blades, name boards, price boards, posters (`brands.png`) | atlas | SurfaceAppearance |
| Site, Asphalt, Lawn, Water | lot paving / parking / grass / pool | tiling PBR / colour | drop Lawn if the world uses terrain grass |
| Neon | parapet tubes, canopy and soffit lights, wall packs, beacons | colour | `SmoothPlastic` with `day_color` by day, `Material=Neon` with `color` at night |
| Grime | alpha dirt decals: rising damp, rain streaks, rust leaks, soot | RGBA atlas `grime.png` | SurfaceAppearance `AlphaMode=Transparency`, `CastShadow=false` |
| WindowsLit | about 30-55% of the window quads, duplicated 0.03 studs proud with `windows_lit.png` | night only | `Transparency=1` by day. At night, show it with `Material=Neon` and a warm `Color`, or with the SurfaceAppearance emissive mask if the engine has it |

Colours in the specs and JSON are **sRGB**. That is what `Color3` and `SurfaceAppearance.Color` use, so they can be
copied straight across. The Cycles previews linearise them (`bk_mat.lin`), so what you see is what Roblox should show.

`UV tile_studs` in the JSON gives the studs per texture repeat for each role. Tiling roles use world-space box UVs,
so texel density is the same on every building. That is why one shared SurfaceAppearance per texture set works
city-wide.

### Night approach

- By day, `WindowsLit` is hidden.
- At dusk, the client turns on `WindowsLit` and switches `Neon` parts to `Material=Neon`. Sign and Brand can get a
  small emissive boost.
- Each building has its own random lit subset (`lit_ratio` per archetype). For more variety at runtime, randomise
  `Transparency` on whole buildings.

## Exports and manifest

`manifest.py` writes to `out/`:

- `glb/<arch>_<seed>.glb` and `.json`
  - These are light GLBs. Each material is named `<Role>__<kind>__<set>`, for example `Walls__texture__brick_red`.
    It keeps its colour, roughness and metal factors, but the images are not embedded.
  - To texture a part, the importer attaches the shared SurfaceAppearance for `<set>` from `texlib/`.
  - This keeps uploads small: about 0.1-0.5 MB each instead of 10-16 MB, and every texture is uploaded once.
- `glb/<arch>_00_embedded.glb`: seed 0 of each archetype with all textures inside, for drag-and-drop tests in Studio.
- `texlib/`
  - Every tiling set as `color`, `normal` (OpenGL convention, which Roblox uses), `roughness` and `metalness` maps.
  - The atlases.
  - `texlib.json`, with the Poly Haven source of each set.
- `manifest.json`: for every building, the footprint, height, `base_depth`, tags, total and maximum part triangles,
  each part (role, triangles, material, night-only flag), parked-car `spawns` in lot space, files and GLB size.
  Budget violations are listed at the top. The budgets are part > 20,000 triangles and texture > 1024 px.

The axes go from Blender to glTF. In Roblox, a building's front faces -Z after a yaw of 180 degrees, which is the
same rule as the car kit.

## Renders (`render_kit.py`, written to `docs/v2/proto/buildkit/`)

**Street level, late afternoon**

- `downtown_street`
- `midtown_street`
- `strip_mall`
- `gas_station`
- `diner`
- `corner_store`
- `deco_beach`
- `suburbs_street`
- `industrial_warehouse`
- `hills_mansion`

**Wide shot:** `block_wide`, a district sampler of 35 blocks with the beach, the hills and the skyline.

**Night:** `deco_night` and `downtown_night`. Both use WindowsLit, Neon, backlit signs and sodium street lights.

**Parametric range:** `variants_<arch>` puts 3-6 seeds of each archetype side by side.

The preview lighting is a Poly Haven pure-sky HDRI with the sun removed, plus a Sun lamp matched to it. The sky fill
is 2.2x, the view transform is AgX Medium High Contrast and the compositor adds mist-pass haze. The scene props
(palms, trees, bushes, lamps, cars, terrain) exist only in the previews.

## Files

| file | role |
|---|---|
| `bk_geo.py` | Mesh buffers, boxes with optional chamfer, cylinders, sweeps, caps, facades with holed walls and reveals, hip, gable and shed roofs, prisms |
| `bk_mat.py` | Cycles materials limited to what a SurfaceAppearance can show, plus decal, neon, water and clear |
| `bk_arch.py` | `Building` (roles, RNG, windows, storefronts, awnings, signs, brands, cornices, parapets, HVAC, tanks, grime, parking, lot lights) + `midtown` |
| `bk_tower.py`, `bk_retail.py`, `bk_deco.py`, `bk_house.py`, `bk_industrial.py`, `bk_mansion.py` | Archetypes |
| `bk_scene.py` | Preview-only world. Sun-removed HDRI + matched Sun lamp + compositor haze, streets, palms (fan or date), trees, bushes, cobra-head lamps, scale cars, terrain |
| `build.py` | Build, instantiate, split, export one building, quick preview, back-face debug |
| `manifest.py` | Batch export, texture library, manifest, budget checks |
| `render_kit.py` | Hero scenes: downtown, midtown, strip, gas, diner, store, deco, suburbs, industrial, mansion, block, plus night variants |
| `fetch_assets.py`, `gen_textures.py` | Asset download and procedural atlases |

## Licences

- Textures and HDRIs come from Poly Haven and are CC0. Each texture set's folder has a `SOURCE.txt`.
- The fonts used for signs are SIL OFL Google Fonts, and are baked into atlases.
- The brand names are our own parodies: PUMP & GO, QUIK STOP, PACIFIC TRUST and others.
