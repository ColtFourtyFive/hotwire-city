# CC0 / CC-BY assets for grounded GTA realism

Date: 2026-10-27.

**Machine-readable companion:** `docs/v2/research/cc0_manifest.json` holds 45 slots and 219 entries, each with every URL, verified sizes, triangle counts and notes.

**How this was verified.** Every texture set below (97 sets) was downloaded at 1k into the container scratchpad (`.../scratchpad/cc0/dl/tex`) and opened:

- every colour map is 1024², except `Tape001`, which is a 128×1024 strip;
- the colour maps were tiled 2×2 into contact sheets to check seams.

Every model marked *verified* was also downloaded:

- Objaverse GLBs, Poly Haven glTFs and OpenGameArt OBJ/glTF files were parsed and rendered with `scratchpad/cc0/tools/glbinfo.py` (numpy/PIL software renderer);
- triangle counts and node names come from the files, not from the listing pages.

HDRIs were decoded (Radiance RGBE, 1024×512) and tonemapped with `tools/hdr.py`.

These contact sheets (under `docs/v2/research/img/`) are the "look" evidence:

| Sheet | Contents |
|---|---|
| `cc0_tex_roads.jpg` | asphalt, lanes, decals, sidewalk, curb |
| `cc0_tex_buildings.jpg` | brick, stucco, concrete, facades, roofs |
| `cc0_tex_metal_nature.jpg` | metals, wood, grass, sand, rock, terrazzo, chain-link, rubber, chrome |
| `cc0_hdri.jpg` | 18 HDRIs, tonemapped |
| `cc0_cars_objaverse_a.jpg`, `cc0_cars_objaverse_b.jpg` | 21 vehicles |
| `cc0_guns_objaverse.jpg` | 12 weapons |
| `cc0_props_objaverse.jpg`, `cc0_props_polyhaven.jpg` | street props |
| `cc0_models_opengameart.jpg` | OpenGameArt models |
| `cc0_palms_nobiax.jpg` | CC0 palm pack |

The renders use flat per-face texture sampling, so they show shape and colour only, not final shading. Alpha-card foliage renders as solid quads.

---

## 1. Decision summary

1. **Textures are a solved problem, and all of them are CC0.**
   - Poly Haven and ambientCG together fill every slot the lead direction asks for, with colour, normal (GL and DX), roughness and AO maps. Metalness comes as a separate map, or as `arm.B` for Poly Haven.
   - ambientCG has assets nobody else has:
     - the **Road series**, with lane lines baked into the asphalt (`Road007` multi-lane white, `Road011A` yellow centre);
     - the **RoadLines decals**, with alpha (`RoadLines019A` is a full marking atlas, `RoadLines020A` is crosswalk bars);
     - **street decals**: manholes, pothole atlases, a graffiti atlas and police tape;
     - **office facades** with day and night variants. `Facade009` even ships an **Emission** map, and Roblox texture specs list an emissive mask for SurfaceAppearance.
2. **Realistic vehicles and guns: the unlock is Objaverse 1.0 on huggingface.co.** Objaverse is the AllenAI snapshot of about 800k Sketchfab models with per-object licence metadata.
   - Sketchfab downloads need a login, but the same GLBs download anonymously from `huggingface.co/datasets/allenai/objaverse` in this container (tested).
   - Filtering its 160 metadata shards for licences `by`/`cc0` plus vehicle, weapon or prop keywords gave 64,011 hits (63,893 CC-BY, 118 CC0).
   - **Downloaded and rendered so far:** 21 vehicles, 12 weapons and 5 props. A further 32 good hits are listed metadata-only.
3. **Best vehicle source: DanielZhabotinsky's "Generic … – Low poly model" series** (CC-BY 4.0).
   - **Size:** 15–28k tris each.
   - **Structure:**
     - per-wheel nodes (`Wheel_FL/FR/RL/RR`), so the wheels are separable for spinning;
     - separate doors, hood and interior;
     - one `Bodycolor` material, so the paint is customisable.
   - **Verified models:** 80s police car, mid-size sedan, station wagon, '71 muscle car, Checker-style taxi, **F700 armored truck (the armored-truck event vehicle)**, ambulance van, '07 coupe, SUV, 90s pickup and panel van.
   - **Listed but unverified:** 7 more, including a Foxbody police car and two American sedans.
   - **Caveat:** the look is retro-leaning, 80s–00s Americana. That fits a GTA Vice City/San Andreas vibe more than GTA V.
4. **Modern traffic and service vehicles: comrade1280's two packs** (CC-BY).
   - The "Generic passenger car pack" has 10 modern generic bodies (compact, coupe, hatchback, minivan, off-road, pickup, SUV, sedan, sport, wagon), with **separate wheels** and about 6–7k tris each.
   - The "Generic civil service vehicles pack" has ambulance, city bus, fire truck, garbage truck, police, road-service truck, school bus, taxi, tow truck and post van. Its **wheels are fused**, so they must be split by loose parts in Blender.
   - Together with the DZ set, this covers every vehicle class in the brief except super cars and motorcycles. Fill those with the **fictional "V12 Goblin" supercar** (separate wheels and brakes; no trademark risk) and the Silas6 motorcycle.
5. **Guns** (all CC-BY, textured, 2–30k tris). These match the GTA archetypes:
   - USP → combat pistol
   - AR-15/HK416 → carbine
   - AK-47 → assault rifle
   - MP5 → SMG
   - Mini Uzi → micro SMG
   - Remington 870 → pump shotgun
   - sawn-off double barrel
   - bolt sniper
   - baseball bats

   **CC0-only fallbacks:**
   - OpenGameArt **M4A1** (PBR FBX);
   - OpenGameArt loafbrr **pistol** (8 animatable parts, glTF);
   - Lamoot **AK-47** (untextured);
   - Poly Haven `service_pistol` and `bolt_action_rifle_7_62` (vintage).
6. **No realistic CC0 car exists on Poly Haven or OpenGameArt.**
   - Poly Haven only has `covered_car` (under a tarp).
   - OpenGameArt cars are stylized: Kenney Car Kit, rgsdev and Quaternius are toy-like, which puts them on the kill list. The old VW Corradon is too crude.
   - Realistic cars therefore mean **CC-BY attribution**.
7. **CC-BY obligations and risk controls:**
   - Ship an in-game **Credits** screen, or text in the experience description, listing model, author, "CC BY 4.0" and the Sketchfab link. The manifest's `model_*_objaverse` entries are the ledger.
   - **Debadge and rename real brands** in GTA parody style: Ford F700, Crown Victoria, HK, Colt, Remington.
   - Objaverse licence data is from the 2022–23 scrape. Before shipping, spot-check each Sketchfab page, and skip anything that looks like a game rip.
8. **HDRIs:** Poly Haven's `*_puresky` set has no ground baked in, so it is ideal for a Roblox `Sky`, with city geometry covering the mirrored lower half. The picks:

   | Time of day | Primary HDRI | Look |
   |---|---|---|
   | Midday | `kloofendal_48d_partly_cloudy_puresky` | GTA V midday cumulus |
   | Golden hour | `kloppenheim_06_puresky` | |
   | Blue hour | `qwantani_dusk_2_puresky` | Pink-lavender Vice dusk |
   | Night | `kloppenheim_07_puresky` | Overcast with city glow |

   - The HDRIs must be converted from equirect to 6 cube faces (1024² LDR) in the skybox pipeline. The RGBE decode already works in-container (`tools/hdr.py`).
   - The urban HDRIs (`shanghai_bund`, `rooftop_night`, `sunset_jhbcentral`) are lighting and colour references only. They are not skyboxes.
9. **Roblox import rules learned:**
   - Roblox **only supports OpenGL tangent-space normals**, so use `NormalGL` / `nor_gl`. Never use the DX maps.
   - Roblox's texture spec gives 1024² as the texture-map space (it also mentions 4K support for textures in general), so the 1k sets match. Validate in Studio.
   - AO is not a Roblox slot; multiply it into the colour map if you want it.
   - `PaintedBricks004`, `Plaster001` and the corrugated panels are near-neutral, so tint them per building through `Part.Color`. One stucco can give pastel Miami pink, mint and peach.
   - The ambientCG RoadLines decals are **yellow** paint. Desaturate them to make white US lane and crosswalk paint; you cannot tint yellow to white.
   - Decimate heavy meshes to Roblox's per-MeshPart triangle cap. It has historically been 20k at import; confirm on the operator's Studio import. Heavy meshes found: fire hydrant set 86k, Jersey barrier 61k, Goblin 87k, CVPI 42k, motorcycle 70k.
   - Convert `KHR_materials_pbrSpecularGlossiness` models (Goblin, Fiat Punto, MAC-11) to metal/rough.
   - Normalise units: several GLBs are in cm, and others are tiny or huge.
10. **Remaining gaps:**
    - No CC0 **LA cobra-head street light**. The Poly Haven lamps are Victorian. The Objaverse kloworks light is CC-BY at 608 tris; alternatively build one from primitives.
    - No tall **Washingtonia fan palm**. The Nobiax CC0 palms are coconut palms, which suit Miami.
    - No tire-tread texture. Use `Rubber004` plus modelled tread.
    - No modern (2015+) generic sedan of DZ quality was verified. The comrade1280 pack is the best modern option; Objaverse has more, unverified.
    - Kenney downloads, poly.pizza and GitHub stay blocked. OpenGameArt mirrors Kenney's car kit (it downloaded fine), but that kit is stylized.

## 2. Reachability and sources tested

| Source | Reachable from container | Licence | Used for |
|---|---|---|---|
| Poly Haven (`api.polyhaven.com`, `dl.polyhaven.org`, `cdn.polyhaven.com` thumbs) | yes | CC0 | textures, HDRIs, 22 props/guns |
| ambientCG (`ambientcg.com/api/v2`, `/get?file=` zips, `acg-media` thumbs) | yes | CC0 | textures, decals, atlases. 2,037 materials, 127 decals, 61 atlases and 434 HDRIs indexed |
| huggingface.co, Objaverse 1.0 (`allenai/objaverse`) | **yes** (anonymous) | per object; filtered to CC-BY 4.0 and CC0 | realistic cars, guns, props |
| OpenGameArt (search, pages, `/sites/default/files/` downloads) | yes | CC0 / CC-BY / OGA-BY | CC0 guns (M4A1, pistol, AK), Nobiax palms; cars are stylized |
| Sketchfab API (`api.sketchfab.com`) | search only; `media.sketchfab.com` thumbs are **403**; downloads need OAuth | — | superseded by the Objaverse mirror |
| quaternius.com, sharetextures, texturecan, cgbookcase, 3dtextures.me, freepbr | reachable, not needed | CC0 | Quaternius is stylized; the texture sites duplicate PH/ACG coverage |
| 3dmodelscc0.com | domain now redirects to a spam site | — | dead (one OGA M4A1 originated there) |
| kenney.nl downloads, poly.pizza, github.com, free3d, turbosquid | blocked (403) or excluded | — | — |

---

## 3. Texture slots (all CC0)

★ marks the primary pick; the others are alternates.

**URL rules:**

- **Poly Haven:** direct per-map URLs on `dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/<id>/<id>_<map>_1k.jpg`, where `<map>` is one of `diff`, `nor_gl`, `nor_dx`, `rough`, `ao`, `arm` (and `metal` where it exists).
- **ambientCG:** serves only zips. `https://ambientcg.com/get?file=<ID>_1K-JPG.zip` contains `<ID>_1K-JPG_{Color,NormalGL,NormalDX,Roughness,AmbientOcclusion,Metalness,Opacity,Emission,Displacement}.jpg`. The members present vary per asset; the details lists below and the manifest give the exact ones.

### `asphalt_clean`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Road012A](https://ambientcg.com/a/Road012A) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY. Dark, even modern asphalt with fine aggregate; tiles cleanly; best base for new downtown avenues. |
| 2 | [clean_asphalt](https://polyhaven.com/a/clean_asphalt) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Smooth fresh blacktop, slightly blue-grey, very low detail; good for freeway decks and parking lots. |
| 3 | [Asphalt010](https://ambientcg.com/a/Asphalt010) | ambientCG · CC0 | color, normal_dx, normal_gl, opacity, roughness | Dark blue-black with a few rust specks; ships an Opacity map you can ignore. |

<details><summary>Exact 1k URLs</summary>

- **Road012A**: zip `https://ambientcg.com/get?file=Road012A_1K-JPG.zip` with members ao=`Road012A_1K-JPG_AmbientOcclusion.jpg`, color=`Road012A_1K-JPG_Color.jpg`, height=`Road012A_1K-JPG_Displacement.jpg`, normal_dx=`Road012A_1K-JPG_NormalDX.jpg`, normal_gl=`Road012A_1K-JPG_NormalGL.jpg`, roughness=`Road012A_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **clean_asphalt**:
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clean_asphalt/clean_asphalt_ao_1k.jpg
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clean_asphalt/clean_asphalt_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clean_asphalt/clean_asphalt_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clean_asphalt/clean_asphalt_nor_gl_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clean_asphalt/clean_asphalt_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clean_asphalt/clean_asphalt_arm_1k.jpg  (B channel)
- **Asphalt010**: zip `https://ambientcg.com/get?file=Asphalt010_1K-JPG.zip` with members color=`Asphalt010_1K-JPG_Color.jpg`, height=`Asphalt010_1K-JPG_Displacement.jpg`, normal_dx=`Asphalt010_1K-JPG_NormalDX.jpg`, normal_gl=`Asphalt010_1K-JPG_NormalGL.jpg`, opacity=`Asphalt010_1K-JPG_Opacity.jpg`, roughness=`Asphalt010_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `asphalt_worn`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [asphalt_02](https://polyhaven.com/a/asphalt_02) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY worn. Mid-grey cracked asphalt with long longitudinal cracks; the cracks repeat visibly at 2x2, so rotate or scale UVs. |
| 2 | [Road013A](https://ambientcg.com/a/Road013A) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Grey asphalt with darker rectangular repair patches; reads as a city street that has had utility work. |
| 3 | [Asphalt026C](https://ambientcg.com/a/Asphalt026C) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Dark asphalt covered in alligator cracking; for alleys, the industrial zone and ghetto streets. |

<details><summary>Exact 1k URLs</summary>

- **asphalt_02**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/asphalt_02/asphalt_02_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/asphalt_02/asphalt_02_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/asphalt_02/asphalt_02_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/asphalt_02/asphalt_02_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/asphalt_02/asphalt_02_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/asphalt_02/asphalt_02_arm_1k.jpg  (B channel)
- **Road013A**: zip `https://ambientcg.com/get?file=Road013A_1K-JPG.zip` with members ao=`Road013A_1K-JPG_AmbientOcclusion.jpg`, color=`Road013A_1K-JPG_Color.jpg`, height=`Road013A_1K-JPG_Displacement.jpg`, normal_dx=`Road013A_1K-JPG_NormalDX.jpg`, normal_gl=`Road013A_1K-JPG_NormalGL.jpg`, roughness=`Road013A_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Asphalt026C**: zip `https://ambientcg.com/get?file=Asphalt026C_1K-JPG.zip` with members ao=`Asphalt026C_1K-JPG_AmbientOcclusion.jpg`, color=`Asphalt026C_1K-JPG_Color.jpg`, height=`Asphalt026C_1K-JPG_Displacement.jpg`, normal_dx=`Asphalt026C_1K-JPG_NormalDX.jpg`, normal_gl=`Asphalt026C_1K-JPG_NormalGL.jpg`, roughness=`Asphalt026C_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `asphalt_wet_night`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Asphalt025C](https://ambientcg.com/a/Asphalt025C) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Wet or rain-darkened asphalt with damp blotches; for a night wet-street variant (pair with low roughness). |

<details><summary>Exact 1k URLs</summary>

- **Asphalt025C**: zip `https://ambientcg.com/get?file=Asphalt025C_1K-JPG.zip` with members ao=`Asphalt025C_1K-JPG_AmbientOcclusion.jpg`, color=`Asphalt025C_1K-JPG_Color.jpg`, height=`Asphalt025C_1K-JPG_Displacement.jpg`, normal_dx=`Asphalt025C_1K-JPG_NormalDX.jpg`, normal_gl=`Asphalt025C_1K-JPG_NormalGL.jpg`, roughness=`Asphalt025C_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `road_lanes_baked`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Road007](https://ambientcg.com/a/Road007) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | PRIMARY lanes. Grey asphalt with baked white edge lines and dashed white lane dividers in a multi-lane layout; drop-in avenue strip. |
| 2 | [Road011A](https://ambientcg.com/a/Road011A) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Asphalt with a yellow dashed centre line and a solid yellow edge; two-lane suburban or rural road. |
| 3 | [Road001](https://ambientcg.com/a/Road001) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | Patched dark asphalt with white dashed and solid lines; grittier city road. |

<details><summary>Exact 1k URLs</summary>

- **Road007**: zip `https://ambientcg.com/get?file=Road007_1K-JPG.zip` with members color=`Road007_1K-JPG_Color.jpg`, height=`Road007_1K-JPG_Displacement.jpg`, normal_dx=`Road007_1K-JPG_NormalDX.jpg`, normal_gl=`Road007_1K-JPG_NormalGL.jpg`, roughness=`Road007_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Road011A**: zip `https://ambientcg.com/get?file=Road011A_1K-JPG.zip` with members ao=`Road011A_1K-JPG_AmbientOcclusion.jpg`, color=`Road011A_1K-JPG_Color.jpg`, height=`Road011A_1K-JPG_Displacement.jpg`, normal_dx=`Road011A_1K-JPG_NormalDX.jpg`, normal_gl=`Road011A_1K-JPG_NormalGL.jpg`, roughness=`Road011A_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Road001**: zip `https://ambientcg.com/get?file=Road001_1K-JPG.zip` with members color=`Road001_1K-JPG_Color.jpg`, height=`Road001_1K-JPG_Displacement.jpg`, normal_dx=`Road001_1K-JPG_NormalDX.jpg`, normal_gl=`Road001_1K-JPG_NormalGL.jpg`, roughness=`Road001_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `road_markings_decal`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [RoadLines019A](https://ambientcg.com/a/RoadLines019A) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, opacity, roughness | PRIMARY markings ATLAS (RGBA): arrows, BUS/TAXI/LANE/SLOW/STOP-style words, hatching, zebra bars and a numeral set. Yellow paint, so desaturate for white US lane paint. |
| 2 | [RoadLines023B](https://ambientcg.com/a/RoadLines023B) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, opacity, roughness | Dashed centre line plus solid edges on a transparent background; decal strip. |
| 3 | [RoadLines031A](https://ambientcg.com/a/RoadLines031A) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, opacity, roughness | Straight/left-turn arrow decal (yellow, alpha). |

<details><summary>Exact 1k URLs</summary>

- **RoadLines019A**: zip `https://ambientcg.com/get?file=RoadLines019A_1K-JPG.zip` with members ao=`RoadLines019A_1K-JPG_AmbientOcclusion.jpg`, color=`RoadLines019A_1K-JPG_Color.jpg`, height=`RoadLines019A_1K-JPG_Displacement.jpg`, normal_dx=`RoadLines019A_1K-JPG_NormalDX.jpg`, normal_gl=`RoadLines019A_1K-JPG_NormalGL.jpg`, opacity=`RoadLines019A_1K-JPG_Opacity.jpg`, roughness=`RoadLines019A_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **RoadLines023B**: zip `https://ambientcg.com/get?file=RoadLines023B_1K-JPG.zip` with members ao=`RoadLines023B_1K-JPG_AmbientOcclusion.jpg`, color=`RoadLines023B_1K-JPG_Color.jpg`, height=`RoadLines023B_1K-JPG_Displacement.jpg`, normal_dx=`RoadLines023B_1K-JPG_NormalDX.jpg`, normal_gl=`RoadLines023B_1K-JPG_NormalGL.jpg`, opacity=`RoadLines023B_1K-JPG_Opacity.jpg`, roughness=`RoadLines023B_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **RoadLines031A**: zip `https://ambientcg.com/get?file=RoadLines031A_1K-JPG.zip` with members ao=`RoadLines031A_1K-JPG_AmbientOcclusion.jpg`, color=`RoadLines031A_1K-JPG_Color.jpg`, height=`RoadLines031A_1K-JPG_Displacement.jpg`, normal_dx=`RoadLines031A_1K-JPG_NormalDX.jpg`, normal_gl=`RoadLines031A_1K-JPG_NormalGL.jpg`, opacity=`RoadLines031A_1K-JPG_Opacity.jpg`, roughness=`RoadLines031A_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `crosswalk`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [RoadLines020A](https://ambientcg.com/a/RoadLines020A) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, opacity, roughness | PRIMARY crosswalk. Parallel thick bars (zebra/continental crosswalk) with alpha; desaturate to white. |
| 2 | [RoadLines035B](https://ambientcg.com/a/RoadLines035B) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, opacity, roughness | Pedestrian stick-figure decal with alpha. |

<details><summary>Exact 1k URLs</summary>

- **RoadLines020A**: zip `https://ambientcg.com/get?file=RoadLines020A_1K-JPG.zip` with members ao=`RoadLines020A_1K-JPG_AmbientOcclusion.jpg`, color=`RoadLines020A_1K-JPG_Color.jpg`, height=`RoadLines020A_1K-JPG_Displacement.jpg`, normal_dx=`RoadLines020A_1K-JPG_NormalDX.jpg`, normal_gl=`RoadLines020A_1K-JPG_NormalGL.jpg`, opacity=`RoadLines020A_1K-JPG_Opacity.jpg`, roughness=`RoadLines020A_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **RoadLines035B**: zip `https://ambientcg.com/get?file=RoadLines035B_1K-JPG.zip` with members ao=`RoadLines035B_1K-JPG_AmbientOcclusion.jpg`, color=`RoadLines035B_1K-JPG_Color.jpg`, height=`RoadLines035B_1K-JPG_Displacement.jpg`, normal_dx=`RoadLines035B_1K-JPG_NormalDX.jpg`, normal_gl=`RoadLines035B_1K-JPG_NormalGL.jpg`, opacity=`RoadLines035B_1K-JPG_Opacity.jpg`, roughness=`RoadLines035B_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `street_decals`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [ManholeCover009](https://ambientcg.com/a/ManholeCover009) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, opacity, roughness | Round cast-iron manhole decal, rusty, with alpha; also has metalness. |
| 2 | [AsphaltDamageSet001](https://ambientcg.com/a/AsphaltDamageSet001) | ambientCG · CC0 | color, normal_dx, normal_gl, opacity, roughness | Atlas of pothole and torn-asphalt patches with alpha, to break up road tiling. |
| 3 | [TireTracks001](https://ambientcg.com/a/TireTracks001) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Tire-track and skid impression decal (mostly normal/height detail); for skid marks. |
| 4 | [GraffitiSet001](https://ambientcg.com/a/GraffitiSet001) | ambientCG · CC0 | color, normal_dx, normal_gl, opacity, roughness | Atlas of 16 colourful graffiti tags with alpha; for alleys and the industrial zone. |
| 5 | [Tape001](https://ambientcg.com/a/Tape001) | ambientCG · CC0 | color, normal_dx, normal_gl, opacity, roughness | Yellow/black police-tape strip (128x1024) with alpha; for crime scenes and roadblocks. |
| 6 | [Leaking012A](https://ambientcg.com/a/Leaking012A) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, roughness | Water-streak and leak decal for wall grime under windows and AC units. |

<details><summary>Exact 1k URLs</summary>

- **ManholeCover009**: zip `https://ambientcg.com/get?file=ManholeCover009_1K-JPG.zip` with members ao=`ManholeCover009_1K-JPG_AmbientOcclusion.jpg`, color=`ManholeCover009_1K-JPG_Color.jpg`, height=`ManholeCover009_1K-JPG_Displacement.jpg`, metalness=`ManholeCover009_1K-JPG_Metalness.jpg`, normal_dx=`ManholeCover009_1K-JPG_NormalDX.jpg`, normal_gl=`ManholeCover009_1K-JPG_NormalGL.jpg`, opacity=`ManholeCover009_1K-JPG_Opacity.jpg`, roughness=`ManholeCover009_1K-JPG_Roughness.jpg`
- **AsphaltDamageSet001**: zip `https://ambientcg.com/get?file=AsphaltDamageSet001_1K-JPG.zip` with members color=`AsphaltDamageSet001_1K-JPG_Color.jpg`, height=`AsphaltDamageSet001_1K-JPG_Displacement.jpg`, normal_dx=`AsphaltDamageSet001_1K-JPG_NormalDX.jpg`, normal_gl=`AsphaltDamageSet001_1K-JPG_NormalGL.jpg`, opacity=`AsphaltDamageSet001_1K-JPG_Opacity.jpg`, roughness=`AsphaltDamageSet001_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **TireTracks001**: zip `https://ambientcg.com/get?file=TireTracks001_1K-JPG.zip` with members ao=`TireTracks001_1K-JPG_AmbientOcclusion.jpg`, color=`TireTracks001_1K-JPG_Color.jpg`, height=`TireTracks001_1K-JPG_Displacement.jpg`, normal_dx=`TireTracks001_1K-JPG_NormalDX.jpg`, normal_gl=`TireTracks001_1K-JPG_NormalGL.jpg`, roughness=`TireTracks001_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **GraffitiSet001**: zip `https://ambientcg.com/get?file=GraffitiSet001_1K-JPG.zip` with members color=`GraffitiSet001_1K-JPG_Color.jpg`, height=`GraffitiSet001_1K-JPG_Displacement.jpg`, normal_dx=`GraffitiSet001_1K-JPG_NormalDX.jpg`, normal_gl=`GraffitiSet001_1K-JPG_NormalGL.jpg`, opacity=`GraffitiSet001_1K-JPG_Opacity.jpg`, roughness=`GraffitiSet001_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Tape001**: zip `https://ambientcg.com/get?file=Tape001_1K-JPG.zip` with members color=`Tape001_1K-JPG_Color.jpg`, height=`Tape001_1K-JPG_Displacement.jpg`, normal_dx=`Tape001_1K-JPG_NormalDX.jpg`, normal_gl=`Tape001_1K-JPG_NormalGL.jpg`, opacity=`Tape001_1K-JPG_Opacity.jpg`, roughness=`Tape001_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Leaking012A**: zip `https://ambientcg.com/get?file=Leaking012A_1K-JPG.zip` with members color=`Leaking012A_1K-JPG_Color.jpg`, height=`Leaking012A_1K-JPG_Displacement.jpg`, metalness=`Leaking012A_1K-JPG_Metalness.jpg`, normal_dx=`Leaking012A_1K-JPG_NormalDX.jpg`, normal_gl=`Leaking012A_1K-JPG_NormalGL.jpg`, roughness=`Leaking012A_1K-JPG_Roughness.jpg`

</details>

### `sidewalk_paving`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Tiles038](https://ambientcg.com/a/Tiles038) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY sidewalk. Light grey square concrete slabs about 60 cm with thin joints; the cleanest US-sidewalk look. |
| 2 | [large_square_pattern_01](https://polyhaven.com/a/large_square_pattern_01) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Darker grey large square pavers with mossy joints; plaza or older downtown. |
| 3 | [PavingStones128](https://ambientcg.com/a/PavingStones128) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Beige/grey rectangular stone pavers in staggered bond; upscale shopping street or hotel forecourt. |

<details><summary>Exact 1k URLs</summary>

- **Tiles038**: zip `https://ambientcg.com/get?file=Tiles038_1K-JPG.zip` with members ao=`Tiles038_1K-JPG_AmbientOcclusion.jpg`, color=`Tiles038_1K-JPG_Color.jpg`, height=`Tiles038_1K-JPG_Displacement.jpg`, normal_dx=`Tiles038_1K-JPG_NormalDX.jpg`, normal_gl=`Tiles038_1K-JPG_NormalGL.jpg`, roughness=`Tiles038_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **large_square_pattern_01**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/large_square_pattern_01/large_square_pattern_01_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/large_square_pattern_01/large_square_pattern_01_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/large_square_pattern_01/large_square_pattern_01_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/large_square_pattern_01/large_square_pattern_01_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/large_square_pattern_01/large_square_pattern_01_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/large_square_pattern_01/large_square_pattern_01_arm_1k.jpg  (B channel)
- **PavingStones128**: zip `https://ambientcg.com/get?file=PavingStones128_1K-JPG.zip` with members ao=`PavingStones128_1K-JPG_AmbientOcclusion.jpg`, color=`PavingStones128_1K-JPG_Color.jpg`, height=`PavingStones128_1K-JPG_Displacement.jpg`, normal_dx=`PavingStones128_1K-JPG_NormalDX.jpg`, normal_gl=`PavingStones128_1K-JPG_NormalGL.jpg`, roughness=`PavingStones128_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `curb_concrete`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [concrete_floor_worn_001](https://polyhaven.com/a/concrete_floor_worn_001) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY curb. Flat medium-grey worn concrete; also good for parking structures and the freeway. |
| 2 | [Concrete042A](https://ambientcg.com/a/Concrete042A) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, roughness | Smooth light concrete with faint stains; cleaner curb or median. |

<details><summary>Exact 1k URLs</summary>

- **concrete_floor_worn_001**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_floor_worn_001/concrete_floor_worn_001_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_floor_worn_001/concrete_floor_worn_001_nor_dx_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_floor_worn_001/concrete_floor_worn_001_rough_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_floor_worn_001/concrete_floor_worn_001_ao_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_floor_worn_001/concrete_floor_worn_001_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_floor_worn_001/concrete_floor_worn_001_arm_1k.jpg  (B channel)
- **Concrete042A**: zip `https://ambientcg.com/get?file=Concrete042A_1K-JPG.zip` with members ao=`Concrete042A_1K-JPG_AmbientOcclusion.jpg`, color=`Concrete042A_1K-JPG_Color.jpg`, height=`Concrete042A_1K-JPG_Displacement.jpg`, metalness=`Concrete042A_1K-JPG_Metalness.jpg`, normal_dx=`Concrete042A_1K-JPG_NormalDX.jpg`, normal_gl=`Concrete042A_1K-JPG_NormalGL.jpg`, roughness=`Concrete042A_1K-JPG_Roughness.jpg`

</details>

### `brick_red`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [red_brick](https://polyhaven.com/a/red_brick) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY red brick. Classic red running bond with grey mortar and slight colour variation. |
| 2 | [Bricks085](https://ambientcg.com/a/Bricks085) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Bright factory-red brick with light mortar; warehouses. |
| 3 | [brick_wall_001](https://polyhaven.com/a/brick_wall_001) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Dark mixed red/brown brick, older and dirtier; industrial or old downtown. |

<details><summary>Exact 1k URLs</summary>

- **red_brick**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/red_brick/red_brick_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/red_brick/red_brick_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/red_brick/red_brick_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/red_brick/red_brick_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/red_brick/red_brick_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/red_brick/red_brick_arm_1k.jpg  (B channel)
- **Bricks085**: zip `https://ambientcg.com/get?file=Bricks085_1K-JPG.zip` with members ao=`Bricks085_1K-JPG_AmbientOcclusion.jpg`, color=`Bricks085_1K-JPG_Color.jpg`, height=`Bricks085_1K-JPG_Displacement.jpg`, normal_dx=`Bricks085_1K-JPG_NormalDX.jpg`, normal_gl=`Bricks085_1K-JPG_NormalGL.jpg`, roughness=`Bricks085_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **brick_wall_001**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/brick_wall_001/brick_wall_001_diffuse_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/brick_wall_001/brick_wall_001_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/brick_wall_001/brick_wall_001_rough_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/brick_wall_001/brick_wall_001_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/brick_wall_001/brick_wall_001_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/brick_wall_001/brick_wall_001_arm_1k.jpg  (B channel)

</details>

### `brick_tan`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Bricks105](https://ambientcg.com/a/Bricks105) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY tan. Warm tan/buff brick, clean urban; LA mid-century commercial. |
| 2 | [Bricks016](https://ambientcg.com/a/Bricks016) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Orange-red smooth modern brick (NOT tan despite the tags); alternate red. |
| 3 | [yellow_bricks](https://polyhaven.com/a/yellow_bricks) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Yellow-ochre rough brick with dirty mortar; older, gritty. |

<details><summary>Exact 1k URLs</summary>

- **Bricks105**: zip `https://ambientcg.com/get?file=Bricks105_1K-JPG.zip` with members ao=`Bricks105_1K-JPG_AmbientOcclusion.jpg`, color=`Bricks105_1K-JPG_Color.jpg`, height=`Bricks105_1K-JPG_Displacement.jpg`, normal_dx=`Bricks105_1K-JPG_NormalDX.jpg`, normal_gl=`Bricks105_1K-JPG_NormalGL.jpg`, roughness=`Bricks105_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Bricks016**: zip `https://ambientcg.com/get?file=Bricks016_1K-JPG.zip` with members ao=`Bricks016_1K-JPG_AmbientOcclusion.jpg`, color=`Bricks016_1K-JPG_Color.jpg`, height=`Bricks016_1K-JPG_Displacement.jpg`, normal_dx=`Bricks016_1K-JPG_NormalDX.jpg`, normal_gl=`Bricks016_1K-JPG_NormalGL.jpg`, roughness=`Bricks016_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **yellow_bricks**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/yellow_bricks/yellow_bricks_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/yellow_bricks/yellow_bricks_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/yellow_bricks/yellow_bricks_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/yellow_bricks/yellow_bricks_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/yellow_bricks/yellow_bricks_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/yellow_bricks/yellow_bricks_arm_1k.jpg  (B channel)

</details>

### `brick_painted`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [PaintedBricks004](https://ambientcg.com/a/PaintedBricks004) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY painted. Brick painted flat light blue-grey; the colour map is almost uniform with the brick relief in the normal map, so it is ideal to tint via Part.Color. |
| 2 | [painted_brick](https://polyhaven.com/a/painted_brick) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Teal-blue painted brick with chipping; Miami side streets. |
| 3 | [whitewashed_brick](https://polyhaven.com/a/whitewashed_brick) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Thin whitewash over brown brick; aged look. |

<details><summary>Exact 1k URLs</summary>

- **PaintedBricks004**: zip `https://ambientcg.com/get?file=PaintedBricks004_1K-JPG.zip` with members ao=`PaintedBricks004_1K-JPG_AmbientOcclusion.jpg`, color=`PaintedBricks004_1K-JPG_Color.jpg`, height=`PaintedBricks004_1K-JPG_Displacement.jpg`, normal_dx=`PaintedBricks004_1K-JPG_NormalDX.jpg`, normal_gl=`PaintedBricks004_1K-JPG_NormalGL.jpg`, roughness=`PaintedBricks004_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **painted_brick**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_brick/painted_brick_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_brick/painted_brick_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_brick/painted_brick_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_brick/painted_brick_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_brick/painted_brick_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_brick/painted_brick_arm_1k.jpg  (B channel)
- **whitewashed_brick**:
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/whitewashed_brick/whitewashed_brick_ao_1k.jpg
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/whitewashed_brick/whitewashed_brick_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/whitewashed_brick/whitewashed_brick_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/whitewashed_brick/whitewashed_brick_nor_gl_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/whitewashed_brick/whitewashed_brick_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/whitewashed_brick/whitewashed_brick_arm_1k.jpg  (B channel)

</details>

### `stucco_pastel_tintable`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Plaster001](https://ambientcg.com/a/Plaster001) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | PRIMARY Miami stucco. Near-white fine stucco with subtle trowel variation; tint pastel (pink, mint, peach) via Part.Color. |
| 2 | [Plaster003](https://ambientcg.com/a/Plaster003) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | White rough stucco with heavier texture; Spanish Revival walls. |
| 3 | [painted_plaster_wall](https://polyhaven.com/a/painted_plaster_wall) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Light warm-grey painted plaster, very even. |

<details><summary>Exact 1k URLs</summary>

- **Plaster001**: zip `https://ambientcg.com/get?file=Plaster001_1K-JPG.zip` with members color=`Plaster001_1K-JPG_Color.jpg`, height=`Plaster001_1K-JPG_Displacement.jpg`, normal_dx=`Plaster001_1K-JPG_NormalDX.jpg`, normal_gl=`Plaster001_1K-JPG_NormalGL.jpg`, roughness=`Plaster001_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Plaster003**: zip `https://ambientcg.com/get?file=Plaster003_1K-JPG.zip` with members color=`Plaster003_1K-JPG_Color.jpg`, height=`Plaster003_1K-JPG_Displacement.jpg`, normal_dx=`Plaster003_1K-JPG_NormalDX.jpg`, normal_gl=`Plaster003_1K-JPG_NormalGL.jpg`, roughness=`Plaster003_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **painted_plaster_wall**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_plaster_wall/painted_plaster_wall_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_plaster_wall/painted_plaster_wall_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_plaster_wall/painted_plaster_wall_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_plaster_wall/painted_plaster_wall_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_plaster_wall/painted_plaster_wall_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/painted_plaster_wall/painted_plaster_wall_arm_1k.jpg  (B channel)

</details>

### `stucco_la_beige`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [beige_wall_001](https://polyhaven.com/a/beige_wall_001) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY LA beige. Warm sand-beige painted render with very low detail; ready-coloured. |
| 2 | [beige_wall_002](https://polyhaven.com/a/beige_wall_002) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Darker khaki stucco; shows a faint tile seam at 2x2, so prefer 001. |

<details><summary>Exact 1k URLs</summary>

- **beige_wall_001**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_001/beige_wall_001_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_001/beige_wall_001_nor_dx_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_001/beige_wall_001_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_001/beige_wall_001_rough_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_001/beige_wall_001_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_001/beige_wall_001_arm_1k.jpg  (B channel)
- **beige_wall_002**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_002/beige_wall_002_diff_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_002/beige_wall_002_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_002/beige_wall_002_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_002/beige_wall_002_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/beige_wall_002/beige_wall_002_arm_1k.jpg  (B channel)

</details>

### `concrete_modern`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Concrete034](https://ambientcg.com/a/Concrete034) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | PRIMARY modern concrete. Light smooth grey concrete/plaster with soft mottling. |
| 2 | [Concrete008](https://ambientcg.com/a/Concrete008) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Architectural formwork concrete with panel joints and tie-holes (Tadao Ando look); upscale towers and the parking garage. |
| 3 | [concrete](https://polyhaven.com/a/concrete) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Board-formed brutalist concrete with vertical board lines; freeway pillars and civic buildings. |

<details><summary>Exact 1k URLs</summary>

- **Concrete034**: zip `https://ambientcg.com/get?file=Concrete034_1K-JPG.zip` with members color=`Concrete034_1K-JPG_Color.jpg`, height=`Concrete034_1K-JPG_Displacement.jpg`, normal_dx=`Concrete034_1K-JPG_NormalDX.jpg`, normal_gl=`Concrete034_1K-JPG_NormalGL.jpg`, roughness=`Concrete034_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Concrete008**: zip `https://ambientcg.com/get?file=Concrete008_1K-JPG.zip` with members ao=`Concrete008_1K-JPG_AmbientOcclusion.jpg`, color=`Concrete008_1K-JPG_Color.jpg`, height=`Concrete008_1K-JPG_Displacement.jpg`, normal_dx=`Concrete008_1K-JPG_NormalDX.jpg`, normal_gl=`Concrete008_1K-JPG_NormalGL.jpg`, roughness=`Concrete008_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **concrete**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete/concrete_diff_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete/concrete_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete/concrete_rough_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete/concrete_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete/concrete_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete/concrete_arm_1k.jpg  (B channel)

</details>

### `concrete_block_cmu`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [concrete_brick_wall_001](https://polyhaven.com/a/concrete_brick_wall_001) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Split-face concrete block (CMU) wall, beige-grey; LA alleys, back walls and the industrial zone. |

<details><summary>Exact 1k URLs</summary>

- **concrete_brick_wall_001**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_brick_wall_001/concrete_brick_wall_001_diffuse_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_brick_wall_001/concrete_brick_wall_001_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_brick_wall_001/concrete_brick_wall_001_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_brick_wall_001/concrete_brick_wall_001_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_brick_wall_001/concrete_brick_wall_001_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_brick_wall_001/concrete_brick_wall_001_arm_1k.jpg  (B channel)

</details>

### `facade_office_glass`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Facade006](https://ambientcg.com/a/Facade006) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, roughness | PRIMARY office glass (day). White mullion grid over pale glass, roughly 4x12 window bays per tile; downtown towers. |
| 2 | [Facade001](https://ambientcg.com/a/Facade001) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, roughness | Blue-grey reflective curtain wall with baked sky reflection; mirror-glass towers (keep roughness low). |
| 3 | [Facade019A](https://ambientcg.com/a/Facade019A) | ambientCG · CC0 | ao, color, emission, metalness, normal_dx, normal_gl, roughness | Mid-rise office: dark brick piers, ribbon windows, interior blinds (day). |
| 4 | [Facade019B](https://ambientcg.com/a/Facade019B) | ambientCG · CC0 | ao, color, emission, metalness, normal_dx, normal_gl, roughness | Same as 019A with lit interiors (dusk/night variant). |
| 5 | [Facade018A](https://ambientcg.com/a/Facade018A) | ambientCG · CC0 | ao, color, emission, metalness, normal_dx, normal_gl, roughness | Brick building with punched dark windows; older downtown or apartments. |

<details><summary>Exact 1k URLs</summary>

- **Facade006**: zip `https://ambientcg.com/get?file=Facade006_1K-JPG.zip` with members color=`Facade006_1K-JPG_Color.jpg`, height=`Facade006_1K-JPG_Displacement.jpg`, metalness=`Facade006_1K-JPG_Metalness.jpg`, normal_dx=`Facade006_1K-JPG_NormalDX.jpg`, normal_gl=`Facade006_1K-JPG_NormalGL.jpg`, roughness=`Facade006_1K-JPG_Roughness.jpg`
- **Facade001**: zip `https://ambientcg.com/get?file=Facade001_1K-JPG.zip` with members color=`Facade001_1K-JPG_Color.jpg`, height=`Facade001_1K-JPG_Displacement.jpg`, metalness=`Facade001_1K-JPG_Metalness.jpg`, normal_dx=`Facade001_1K-JPG_NormalDX.jpg`, normal_gl=`Facade001_1K-JPG_NormalGL.jpg`, roughness=`Facade001_1K-JPG_Roughness.jpg`
- **Facade019A**: zip `https://ambientcg.com/get?file=Facade019A_1K-JPG.zip` with members ao=`Facade019A_1K-JPG_AmbientOcclusion.jpg`, color=`Facade019A_1K-JPG_Color.jpg`, height=`Facade019A_1K-JPG_Displacement.jpg`, emission=`Facade019A_1K-JPG_Emission.jpg`, metalness=`Facade019A_1K-JPG_Metalness.jpg`, normal_dx=`Facade019A_1K-JPG_NormalDX.jpg`, normal_gl=`Facade019A_1K-JPG_NormalGL.jpg`, roughness=`Facade019A_1K-JPG_Roughness.jpg`
- **Facade019B**: zip `https://ambientcg.com/get?file=Facade019B_1K-JPG.zip` with members ao=`Facade019B_1K-JPG_AmbientOcclusion.jpg`, color=`Facade019B_1K-JPG_Color.jpg`, height=`Facade019B_1K-JPG_Displacement.jpg`, emission=`Facade019B_1K-JPG_Emission.jpg`, metalness=`Facade019B_1K-JPG_Metalness.jpg`, normal_dx=`Facade019B_1K-JPG_NormalDX.jpg`, normal_gl=`Facade019B_1K-JPG_NormalGL.jpg`, roughness=`Facade019B_1K-JPG_Roughness.jpg`
- **Facade018A**: zip `https://ambientcg.com/get?file=Facade018A_1K-JPG.zip` with members ao=`Facade018A_1K-JPG_AmbientOcclusion.jpg`, color=`Facade018A_1K-JPG_Color.jpg`, height=`Facade018A_1K-JPG_Displacement.jpg`, emission=`Facade018A_1K-JPG_Emission.jpg`, metalness=`Facade018A_1K-JPG_Metalness.jpg`, normal_dx=`Facade018A_1K-JPG_NormalDX.jpg`, normal_gl=`Facade018A_1K-JPG_NormalGL.jpg`, roughness=`Facade018A_1K-JPG_Roughness.jpg`

</details>

### `facade_night_windows`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Facade009](https://ambientcg.com/a/Facade009) | ambientCG · CC0 | color, emission, metalness, normal_dx, normal_gl, roughness | PRIMARY night windows. Black facade with scattered lit offices; ships an Emission map (usable as a Roblox emissive mask). |
| 2 | [Facade013](https://ambientcg.com/a/Facade013) | ambientCG · CC0 | color, emission, normal_dx, normal_gl, roughness | Skyscraper at night: dark grid with warm lit floors. |
| 3 | [Facade002](https://ambientcg.com/a/Facade002) | ambientCG · CC0 | color, emission, metalness, normal_dx, normal_gl, roughness | Dark glass grid with large bright lit window blocks; strong night skyline read. |

<details><summary>Exact 1k URLs</summary>

- **Facade009**: zip `https://ambientcg.com/get?file=Facade009_1K-JPG.zip` with members color=`Facade009_1K-JPG_Color.jpg`, height=`Facade009_1K-JPG_Displacement.jpg`, emission=`Facade009_1K-JPG_Emission.jpg`, metalness=`Facade009_1K-JPG_Metalness.jpg`, normal_dx=`Facade009_1K-JPG_NormalDX.jpg`, normal_gl=`Facade009_1K-JPG_NormalGL.jpg`, roughness=`Facade009_1K-JPG_Roughness.jpg`
- **Facade013**: zip `https://ambientcg.com/get?file=Facade013_1K-JPG.zip` with members color=`Facade013_1K-JPG_Color.jpg`, height=`Facade013_1K-JPG_Displacement.jpg`, emission=`Facade013_1K-JPG_Emission.jpg`, normal_dx=`Facade013_1K-JPG_NormalDX.jpg`, normal_gl=`Facade013_1K-JPG_NormalGL.jpg`, roughness=`Facade013_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Facade002**: zip `https://ambientcg.com/get?file=Facade002_1K-JPG.zip` with members color=`Facade002_1K-JPG_Color.jpg`, height=`Facade002_1K-JPG_Displacement.jpg`, emission=`Facade002_1K-JPG_Emission.jpg`, metalness=`Facade002_1K-JPG_Metalness.jpg`, normal_dx=`Facade002_1K-JPG_NormalDX.jpg`, normal_gl=`Facade002_1K-JPG_NormalGL.jpg`, roughness=`Facade002_1K-JPG_Roughness.jpg`

</details>

### `roof_tiles`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [RoofingTiles006](https://ambientcg.com/a/RoofingTiles006) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY roof. Clean terracotta barrel/S tiles; Spanish/Mission style for LA and Miami houses. |
| 2 | [RoofingTiles014A](https://ambientcg.com/a/RoofingTiles014A) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, opacity, roughness | Smoother terracotta interlocking tiles (ships Opacity, ignore). |
| 3 | [clay_roof_tiles_02](https://polyhaven.com/a/clay_roof_tiles_02) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Vivid orange clay tiles with dark gaps; Mediterranean villas. |

<details><summary>Exact 1k URLs</summary>

- **RoofingTiles006**: zip `https://ambientcg.com/get?file=RoofingTiles006_1K-JPG.zip` with members ao=`RoofingTiles006_1K-JPG_AmbientOcclusion.jpg`, color=`RoofingTiles006_1K-JPG_Color.jpg`, height=`RoofingTiles006_1K-JPG_Displacement.jpg`, normal_dx=`RoofingTiles006_1K-JPG_NormalDX.jpg`, normal_gl=`RoofingTiles006_1K-JPG_NormalGL.jpg`, roughness=`RoofingTiles006_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **RoofingTiles014A**: zip `https://ambientcg.com/get?file=RoofingTiles014A_1K-JPG.zip` with members ao=`RoofingTiles014A_1K-JPG_AmbientOcclusion.jpg`, color=`RoofingTiles014A_1K-JPG_Color.jpg`, height=`RoofingTiles014A_1K-JPG_Displacement.jpg`, normal_dx=`RoofingTiles014A_1K-JPG_NormalDX.jpg`, normal_gl=`RoofingTiles014A_1K-JPG_NormalGL.jpg`, opacity=`RoofingTiles014A_1K-JPG_Opacity.jpg`, roughness=`RoofingTiles014A_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **clay_roof_tiles_02**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clay_roof_tiles_02/clay_roof_tiles_02_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clay_roof_tiles_02/clay_roof_tiles_02_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clay_roof_tiles_02/clay_roof_tiles_02_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clay_roof_tiles_02/clay_roof_tiles_02_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clay_roof_tiles_02/clay_roof_tiles_02_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/clay_roof_tiles_02/clay_roof_tiles_02_arm_1k.jpg  (B channel)

</details>

### `gravel_roof`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Gravel023](https://ambientcg.com/a/Gravel023) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY flat-roof ballast. Light grey/white pebbles; the classic downtown flat roof seen from a helicopter. |
| 2 | [Rocks006](https://ambientcg.com/a/Rocks006) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Darker mixed grey crushed gravel; rail ballast or construction sites. |
| 3 | [Gravel043](https://ambientcg.com/a/Gravel043) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Fine dark granular gravel, almost tar-and-chip; roofs or dirt lots. |

<details><summary>Exact 1k URLs</summary>

- **Gravel023**: zip `https://ambientcg.com/get?file=Gravel023_1K-JPG.zip` with members ao=`Gravel023_1K-JPG_AmbientOcclusion.jpg`, color=`Gravel023_1K-JPG_Color.jpg`, height=`Gravel023_1K-JPG_Displacement.jpg`, normal_dx=`Gravel023_1K-JPG_NormalDX.jpg`, normal_gl=`Gravel023_1K-JPG_NormalGL.jpg`, roughness=`Gravel023_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Rocks006**: zip `https://ambientcg.com/get?file=Rocks006_1K-JPG.zip` with members ao=`Rocks006_1K-JPG_AmbientOcclusion.jpg`, color=`Rocks006_1K-JPG_Color.jpg`, height=`Rocks006_1K-JPG_Displacement.jpg`, normal_dx=`Rocks006_1K-JPG_NormalDX.jpg`, normal_gl=`Rocks006_1K-JPG_NormalGL.jpg`, roughness=`Rocks006_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Gravel043**: zip `https://ambientcg.com/get?file=Gravel043_1K-JPG.zip` with members ao=`Gravel043_1K-JPG_AmbientOcclusion.jpg`, color=`Gravel043_1K-JPG_Color.jpg`, height=`Gravel043_1K-JPG_Displacement.jpg`, normal_dx=`Gravel043_1K-JPG_NormalDX.jpg`, normal_gl=`Gravel043_1K-JPG_NormalGL.jpg`, roughness=`Gravel043_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `corrugated_metal`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [corrugated_iron](https://polyhaven.com/a/corrugated_iron) | Poly Haven · CC0 | ao, color, metalness, normal_gl, roughness | PRIMARY corrugated metal. Light galvanised corrugated sheet; for warehouses and sheds (metalness in arm.B). |
| 2 | [CorrugatedSteel005](https://ambientcg.com/a/CorrugatedSteel005) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, roughness | Weathered galvanised corrugated steel with dark streaks. |
| 3 | [worn_corrugated_iron](https://polyhaven.com/a/worn_corrugated_iron) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Grey corrugated sheet with rust pitting. |

<details><summary>Exact 1k URLs</summary>

- **corrugated_iron**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/corrugated_iron/corrugated_iron_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/corrugated_iron/corrugated_iron_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/corrugated_iron/corrugated_iron_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/corrugated_iron/corrugated_iron_metal_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/corrugated_iron/corrugated_iron_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/corrugated_iron/corrugated_iron_rough_1k.jpg
- **CorrugatedSteel005**: zip `https://ambientcg.com/get?file=CorrugatedSteel005_1K-JPG.zip` with members ao=`CorrugatedSteel005_1K-JPG_AmbientOcclusion.jpg`, color=`CorrugatedSteel005_1K-JPG_Color.jpg`, height=`CorrugatedSteel005_1K-JPG_Displacement.jpg`, metalness=`CorrugatedSteel005_1K-JPG_Metalness.jpg`, normal_dx=`CorrugatedSteel005_1K-JPG_NormalDX.jpg`, normal_gl=`CorrugatedSteel005_1K-JPG_NormalGL.jpg`, roughness=`CorrugatedSteel005_1K-JPG_Roughness.jpg`
- **worn_corrugated_iron**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/worn_corrugated_iron/worn_corrugated_iron_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/worn_corrugated_iron/worn_corrugated_iron_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/worn_corrugated_iron/worn_corrugated_iron_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/worn_corrugated_iron/worn_corrugated_iron_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/worn_corrugated_iron/worn_corrugated_iron_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/worn_corrugated_iron/worn_corrugated_iron_arm_1k.jpg  (B channel)

</details>

### `container_metal`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [container_side](https://polyhaven.com/a/container_side) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY container. Green painted shipping-container corrugation (no Metal map; arm.B holds metalness). |
| 2 | [CorrugatedSteel002](https://ambientcg.com/a/CorrugatedSteel002) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, roughness | Red/pink painted corrugated panel with screws; container or tintable shed. |
| 3 | [CorrugatedSteel001](https://ambientcg.com/a/CorrugatedSteel001) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, roughness | Cyan painted corrugated panel; container colour variety. |

<details><summary>Exact 1k URLs</summary>

- **container_side**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/container_side/container_side_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/container_side/container_side_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/container_side/container_side_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/container_side/container_side_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/container_side/container_side_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/container_side/container_side_arm_1k.jpg  (B channel)
- **CorrugatedSteel002**: zip `https://ambientcg.com/get?file=CorrugatedSteel002_1K-JPG.zip` with members ao=`CorrugatedSteel002_1K-JPG_AmbientOcclusion.jpg`, color=`CorrugatedSteel002_1K-JPG_Color.jpg`, height=`CorrugatedSteel002_1K-JPG_Displacement.jpg`, metalness=`CorrugatedSteel002_1K-JPG_Metalness.jpg`, normal_dx=`CorrugatedSteel002_1K-JPG_NormalDX.jpg`, normal_gl=`CorrugatedSteel002_1K-JPG_NormalGL.jpg`, roughness=`CorrugatedSteel002_1K-JPG_Roughness.jpg`
- **CorrugatedSteel001**: zip `https://ambientcg.com/get?file=CorrugatedSteel001_1K-JPG.zip` with members ao=`CorrugatedSteel001_1K-JPG_AmbientOcclusion.jpg`, color=`CorrugatedSteel001_1K-JPG_Color.jpg`, height=`CorrugatedSteel001_1K-JPG_Displacement.jpg`, metalness=`CorrugatedSteel001_1K-JPG_Metalness.jpg`, normal_dx=`CorrugatedSteel001_1K-JPG_NormalDX.jpg`, normal_gl=`CorrugatedSteel001_1K-JPG_NormalGL.jpg`, roughness=`CorrugatedSteel001_1K-JPG_Roughness.jpg`

</details>

### `rusty_metal`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [rusty_metal_02](https://polyhaven.com/a/rusty_metal_02) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY rust. Galvanised grey with orange rust bloom; industrial props and port. |
| 2 | [Metal053C](https://ambientcg.com/a/Metal053C) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, roughness | Heavily rusted steel with paint remnants. |
| 3 | [rusty_metal_04](https://polyhaven.com/a/rusty_metal_04) | Poly Haven · CC0 | ao, color, metalness, normal_gl, roughness | Dark brown rust over chipped paint (has Metal map). |

<details><summary>Exact 1k URLs</summary>

- **rusty_metal_02**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_02/rusty_metal_02_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_02/rusty_metal_02_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_02/rusty_metal_02_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_02/rusty_metal_02_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_02/rusty_metal_02_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_02/rusty_metal_02_arm_1k.jpg  (B channel)
- **Metal053C**: zip `https://ambientcg.com/get?file=Metal053C_1K-JPG.zip` with members color=`Metal053C_1K-JPG_Color.jpg`, height=`Metal053C_1K-JPG_Displacement.jpg`, metalness=`Metal053C_1K-JPG_Metalness.jpg`, normal_dx=`Metal053C_1K-JPG_NormalDX.jpg`, normal_gl=`Metal053C_1K-JPG_NormalGL.jpg`, roughness=`Metal053C_1K-JPG_Roughness.jpg`
- **rusty_metal_04**:
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_04/rusty_metal_04_ao_1k.jpg
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_04/rusty_metal_04_diff_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_04/rusty_metal_04_metal_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_04/rusty_metal_04_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_04/rusty_metal_04_nor_gl_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rusty_metal_04/rusty_metal_04_rough_1k.jpg

</details>

### `diamond_plate`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [DiamondPlate008C](https://ambientcg.com/a/DiamondPlate008C) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, roughness | Clean steel diamond-tread plate; truck beds, ramps and loading docks. |
| 2 | [metal_plate](https://polyhaven.com/a/metal_plate) | Poly Haven · CC0 | ao, color, metalness, normal_gl, roughness | Dark weathered checker plate. |

<details><summary>Exact 1k URLs</summary>

- **DiamondPlate008C**: zip `https://ambientcg.com/get?file=DiamondPlate008C_1K-JPG.zip` with members ao=`DiamondPlate008C_1K-JPG_AmbientOcclusion.jpg`, color=`DiamondPlate008C_1K-JPG_Color.jpg`, height=`DiamondPlate008C_1K-JPG_Displacement.jpg`, metalness=`DiamondPlate008C_1K-JPG_Metalness.jpg`, normal_dx=`DiamondPlate008C_1K-JPG_NormalDX.jpg`, normal_gl=`DiamondPlate008C_1K-JPG_NormalGL.jpg`, roughness=`DiamondPlate008C_1K-JPG_Roughness.jpg`
- **metal_plate**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/metal_plate/metal_plate_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/metal_plate/metal_plate_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/metal_plate/metal_plate_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/metal_plate/metal_plate_metal_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/metal_plate/metal_plate_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/metal_plate/metal_plate_rough_1k.jpg

</details>

### `hazard_painted_metal`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [PaintedMetal016](https://ambientcg.com/a/PaintedMetal016) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, roughness | Yellow/black hazard stripes over rust; port and construction. |
| 2 | [PaintedMetal004](https://ambientcg.com/a/PaintedMetal004) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, opacity, roughness | Scratched red painted metal; fire equipment and signs. |

<details><summary>Exact 1k URLs</summary>

- **PaintedMetal016**: zip `https://ambientcg.com/get?file=PaintedMetal016_1K-JPG.zip` with members ao=`PaintedMetal016_1K-JPG_AmbientOcclusion.jpg`, color=`PaintedMetal016_1K-JPG_Color.jpg`, height=`PaintedMetal016_1K-JPG_Displacement.jpg`, metalness=`PaintedMetal016_1K-JPG_Metalness.jpg`, normal_dx=`PaintedMetal016_1K-JPG_NormalDX.jpg`, normal_gl=`PaintedMetal016_1K-JPG_NormalGL.jpg`, roughness=`PaintedMetal016_1K-JPG_Roughness.jpg`
- **PaintedMetal004**: zip `https://ambientcg.com/get?file=PaintedMetal004_1K-JPG.zip` with members color=`PaintedMetal004_1K-JPG_Color.jpg`, height=`PaintedMetal004_1K-JPG_Displacement.jpg`, metalness=`PaintedMetal004_1K-JPG_Metalness.jpg`, normal_dx=`PaintedMetal004_1K-JPG_NormalDX.jpg`, normal_gl=`PaintedMetal004_1K-JPG_NormalGL.jpg`, opacity=`PaintedMetal004_1K-JPG_Opacity.jpg`, roughness=`PaintedMetal004_1K-JPG_Roughness.jpg`

</details>

### `wood_planks`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [weathered_brown_planks](https://polyhaven.com/a/weathered_brown_planks) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY boardwalk. Weathered brown horizontal planks with gaps; pier and boardwalk deck. |
| 2 | [wood_planks_grey](https://polyhaven.com/a/wood_planks_grey) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Sun-bleached grey planks; old pier. |
| 3 | [Planks033A](https://ambientcg.com/a/Planks033A) | ambientCG · CC0 | ao, color, metalness, normal_dx, normal_gl, roughness | Light pine planks with nails; fences and shacks. |

<details><summary>Exact 1k URLs</summary>

- **weathered_brown_planks**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/weathered_brown_planks/weathered_brown_planks_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/weathered_brown_planks/weathered_brown_planks_nor_dx_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/weathered_brown_planks/weathered_brown_planks_rough_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/weathered_brown_planks/weathered_brown_planks_ao_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/weathered_brown_planks/weathered_brown_planks_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/weathered_brown_planks/weathered_brown_planks_arm_1k.jpg  (B channel)
- **wood_planks_grey**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_planks_grey/wood_planks_grey_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_planks_grey/wood_planks_grey_nor_dx_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_planks_grey/wood_planks_grey_rough_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_planks_grey/wood_planks_grey_ao_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_planks_grey/wood_planks_grey_nor_gl_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/wood_planks_grey/wood_planks_grey_arm_1k.jpg  (B channel)
- **Planks033A**: zip `https://ambientcg.com/get?file=Planks033A_1K-JPG.zip` with members ao=`Planks033A_1K-JPG_AmbientOcclusion.jpg`, color=`Planks033A_1K-JPG_Color.jpg`, height=`Planks033A_1K-JPG_Displacement.jpg`, metalness=`Planks033A_1K-JPG_Metalness.jpg`, normal_dx=`Planks033A_1K-JPG_NormalDX.jpg`, normal_gl=`Planks033A_1K-JPG_NormalGL.jpg`, roughness=`Planks033A_1K-JPG_Roughness.jpg`

</details>

### `grass`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Grass004](https://ambientcg.com/a/Grass004) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY lawn. Even green mown lawn with slight yellow flecks. |
| 2 | [Grass001](https://ambientcg.com/a/Grass001) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Darker denser grass; parks and golf. |
| 3 | [Grass005](https://ambientcg.com/a/Grass005) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Bright yellow-green short grass; manicured lawns and Vinewood hills estates. |

<details><summary>Exact 1k URLs</summary>

- **Grass004**: zip `https://ambientcg.com/get?file=Grass004_1K-JPG.zip` with members ao=`Grass004_1K-JPG_AmbientOcclusion.jpg`, color=`Grass004_1K-JPG_Color.jpg`, height=`Grass004_1K-JPG_Displacement.jpg`, normal_dx=`Grass004_1K-JPG_NormalDX.jpg`, normal_gl=`Grass004_1K-JPG_NormalGL.jpg`, roughness=`Grass004_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Grass001**: zip `https://ambientcg.com/get?file=Grass001_1K-JPG.zip` with members ao=`Grass001_1K-JPG_AmbientOcclusion.jpg`, color=`Grass001_1K-JPG_Color.jpg`, height=`Grass001_1K-JPG_Displacement.jpg`, normal_dx=`Grass001_1K-JPG_NormalDX.jpg`, normal_gl=`Grass001_1K-JPG_NormalGL.jpg`, roughness=`Grass001_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Grass005**: zip `https://ambientcg.com/get?file=Grass005_1K-JPG.zip` with members ao=`Grass005_1K-JPG_AmbientOcclusion.jpg`, color=`Grass005_1K-JPG_Color.jpg`, height=`Grass005_1K-JPG_Displacement.jpg`, normal_dx=`Grass005_1K-JPG_NormalDX.jpg`, normal_gl=`Grass005_1K-JPG_NormalGL.jpg`, roughness=`Grass005_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `grass_dry`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [withered_grass](https://polyhaven.com/a/withered_grass) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY dry. Beige dry grass and dirt; LA hills, desert edges and the Vinewood sign slope. |
| 2 | [sparse_grass](https://polyhaven.com/a/sparse_grass) | Poly Haven · CC0 | ao, color, normal_gl, opacity, roughness | Dark green-brown sparse grass with soil. |

<details><summary>Exact 1k URLs</summary>

- **withered_grass**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/withered_grass/withered_grass_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/withered_grass/withered_grass_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/withered_grass/withered_grass_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/withered_grass/withered_grass_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/withered_grass/withered_grass_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/withered_grass/withered_grass_arm_1k.jpg  (B channel)
- **sparse_grass**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/sparse_grass/sparse_grass_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/sparse_grass/sparse_grass_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/sparse_grass/sparse_grass_nor_gl_1k.jpg
  - opacity: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/sparse_grass/sparse_grass_mask_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/sparse_grass/sparse_grass_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/sparse_grass/sparse_grass_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/sparse_grass/sparse_grass_arm_1k.jpg  (B channel)

</details>

### `sand`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Ground055S](https://ambientcg.com/a/Ground055S) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | PRIMARY beach. Pale grey-beige wind-rippled sand (ripples in the normal map); Miami-style beach. |
| 2 | [aerial_beach_01](https://polyhaven.com/a/aerial_beach_01) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Grey-beige wavy beach sand from an aerial scan; large-scale tiling. |
| 3 | [Ground080](https://ambientcg.com/a/Ground080) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Warm yellow sand; desert or dunes. |

<details><summary>Exact 1k URLs</summary>

- **Ground055S**: zip `https://ambientcg.com/get?file=Ground055S_1K-JPG.zip` with members ao=`Ground055S_1K-JPG_AmbientOcclusion.jpg`, color=`Ground055S_1K-JPG_Color.jpg`, height=`Ground055S_1K-JPG_Displacement.jpg`, normal_dx=`Ground055S_1K-JPG_NormalDX.jpg`, normal_gl=`Ground055S_1K-JPG_NormalGL.jpg`, roughness=`Ground055S_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **aerial_beach_01**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/aerial_beach_01/aerial_beach_01_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/aerial_beach_01/aerial_beach_01_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/aerial_beach_01/aerial_beach_01_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/aerial_beach_01/aerial_beach_01_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/aerial_beach_01/aerial_beach_01_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/aerial_beach_01/aerial_beach_01_arm_1k.jpg  (B channel)
- **Ground080**: zip `https://ambientcg.com/get?file=Ground080_1K-JPG.zip` with members ao=`Ground080_1K-JPG_AmbientOcclusion.jpg`, color=`Ground080_1K-JPG_Color.jpg`, height=`Ground080_1K-JPG_Displacement.jpg`, normal_dx=`Ground080_1K-JPG_NormalDX.jpg`, normal_gl=`Ground080_1K-JPG_NormalGL.jpg`, roughness=`Ground080_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `rock_cliff`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [rock_face_03](https://polyhaven.com/a/rock_face_03) | Poly Haven · CC0 | ao, color, normal_gl, roughness | PRIMARY cliff. Brown/tan fractured rock face; Vinewood hills cuts and coastal cliffs. |
| 2 | [Rock029](https://ambientcg.com/a/Rock029) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Orange-red desert sandstone rock; desert highway loop. |
| 3 | [Rock030](https://ambientcg.com/a/Rock030) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Grey layered cliff rock with green lichen. |

<details><summary>Exact 1k URLs</summary>

- **rock_face_03**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rock_face_03/rock_face_03_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rock_face_03/rock_face_03_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rock_face_03/rock_face_03_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rock_face_03/rock_face_03_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rock_face_03/rock_face_03_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rock_face_03/rock_face_03_arm_1k.jpg  (B channel)
- **Rock029**: zip `https://ambientcg.com/get?file=Rock029_1K-JPG.zip` with members ao=`Rock029_1K-JPG_AmbientOcclusion.jpg`, color=`Rock029_1K-JPG_Color.jpg`, height=`Rock029_1K-JPG_Displacement.jpg`, normal_dx=`Rock029_1K-JPG_NormalDX.jpg`, normal_gl=`Rock029_1K-JPG_NormalGL.jpg`, roughness=`Rock029_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Rock030**: zip `https://ambientcg.com/get?file=Rock030_1K-JPG.zip` with members ao=`Rock030_1K-JPG_AmbientOcclusion.jpg`, color=`Rock030_1K-JPG_Color.jpg`, height=`Rock030_1K-JPG_Displacement.jpg`, normal_dx=`Rock030_1K-JPG_NormalDX.jpg`, normal_gl=`Rock030_1K-JPG_NormalGL.jpg`, roughness=`Rock030_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `marble_terrazzo`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Terrazzo005](https://ambientcg.com/a/Terrazzo005) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | PRIMARY plaza. White terrazzo with black/grey chips; Miami Art Deco lobbies, malls and the airport. |
| 2 | [Tiles040](https://ambientcg.com/a/Tiles040) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | White terrazzo-look square tiles with grout lines; plaza paving. |
| 3 | [Marble012](https://ambientcg.com/a/Marble012) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | Glossy grey-veined marble; bank and hotel lobbies. |
| 4 | [Travertine009](https://ambientcg.com/a/Travertine009) | ambientCG · CC0 | ao, color, normal_dx, normal_gl, roughness | Cream travertine with horizontal veins; upscale plazas and mansions. |

<details><summary>Exact 1k URLs</summary>

- **Terrazzo005**: zip `https://ambientcg.com/get?file=Terrazzo005_1K-JPG.zip` with members color=`Terrazzo005_1K-JPG_Color.jpg`, height=`Terrazzo005_1K-JPG_Displacement.jpg`, normal_dx=`Terrazzo005_1K-JPG_NormalDX.jpg`, normal_gl=`Terrazzo005_1K-JPG_NormalGL.jpg`, roughness=`Terrazzo005_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Tiles040**: zip `https://ambientcg.com/get?file=Tiles040_1K-JPG.zip` with members color=`Tiles040_1K-JPG_Color.jpg`, height=`Tiles040_1K-JPG_Displacement.jpg`, normal_dx=`Tiles040_1K-JPG_NormalDX.jpg`, normal_gl=`Tiles040_1K-JPG_NormalGL.jpg`, roughness=`Tiles040_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Marble012**: zip `https://ambientcg.com/get?file=Marble012_1K-JPG.zip` with members color=`Marble012_1K-JPG_Color.jpg`, height=`Marble012_1K-JPG_Displacement.jpg`, normal_dx=`Marble012_1K-JPG_NormalDX.jpg`, normal_gl=`Marble012_1K-JPG_NormalGL.jpg`, roughness=`Marble012_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **Travertine009**: zip `https://ambientcg.com/get?file=Travertine009_1K-JPG.zip` with members ao=`Travertine009_1K-JPG_AmbientOcclusion.jpg`, color=`Travertine009_1K-JPG_Color.jpg`, height=`Travertine009_1K-JPG_Displacement.jpg`, normal_dx=`Travertine009_1K-JPG_NormalDX.jpg`, normal_gl=`Travertine009_1K-JPG_NormalGL.jpg`, roughness=`Travertine009_1K-JPG_Roughness.jpg`; metalness: none (non-metal)

</details>

### `chainlink_alpha`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Fence003](https://ambientcg.com/a/Fence003) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, opacity, roughness | PRIMARY chain-link (RGBA). Galvanised diamond wire mesh with Opacity and Metalness. |
| 2 | [Fence006](https://ambientcg.com/a/Fence006) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, opacity, roughness | Darker or rustier chain-link mesh with opacity. |
| 3 | [Fence008A](https://ambientcg.com/a/Fence008A) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, opacity, roughness | Welded square wire grid with opacity; construction or security fencing. |

<details><summary>Exact 1k URLs</summary>

- **Fence003**: zip `https://ambientcg.com/get?file=Fence003_1K-JPG.zip` with members color=`Fence003_1K-JPG_Color.jpg`, height=`Fence003_1K-JPG_Displacement.jpg`, metalness=`Fence003_1K-JPG_Metalness.jpg`, normal_dx=`Fence003_1K-JPG_NormalDX.jpg`, normal_gl=`Fence003_1K-JPG_NormalGL.jpg`, opacity=`Fence003_1K-JPG_Opacity.jpg`, roughness=`Fence003_1K-JPG_Roughness.jpg`
- **Fence006**: zip `https://ambientcg.com/get?file=Fence006_1K-JPG.zip` with members color=`Fence006_1K-JPG_Color.jpg`, height=`Fence006_1K-JPG_Displacement.jpg`, metalness=`Fence006_1K-JPG_Metalness.jpg`, normal_dx=`Fence006_1K-JPG_NormalDX.jpg`, normal_gl=`Fence006_1K-JPG_NormalGL.jpg`, opacity=`Fence006_1K-JPG_Opacity.jpg`, roughness=`Fence006_1K-JPG_Roughness.jpg`
- **Fence008A**: zip `https://ambientcg.com/get?file=Fence008A_1K-JPG.zip` with members color=`Fence008A_1K-JPG_Color.jpg`, height=`Fence008A_1K-JPG_Displacement.jpg`, metalness=`Fence008A_1K-JPG_Metalness.jpg`, normal_dx=`Fence008A_1K-JPG_NormalDX.jpg`, normal_gl=`Fence008A_1K-JPG_NormalGL.jpg`, opacity=`Fence008A_1K-JPG_Opacity.jpg`, roughness=`Fence008A_1K-JPG_Roughness.jpg`

</details>

### `tire_rubber`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Rubber004](https://ambientcg.com/a/Rubber004) | ambientCG · CC0 | color, normal_dx, normal_gl, roughness | Fine dark rubber (gym-floor scan) used as the tire tread/sidewall base; no tire-specific CC0 tread found. |
| 2 | [rubber_tiles](https://polyhaven.com/a/rubber_tiles) | Poly Haven · CC0 | ao, color, normal_gl, roughness | Black rubber tiles; also usable as an EPDM flat-roof membrane. |

<details><summary>Exact 1k URLs</summary>

- **Rubber004**: zip `https://ambientcg.com/get?file=Rubber004_1K-JPG.zip` with members color=`Rubber004_1K-JPG_Color.jpg`, height=`Rubber004_1K-JPG_Displacement.jpg`, normal_dx=`Rubber004_1K-JPG_NormalDX.jpg`, normal_gl=`Rubber004_1K-JPG_NormalGL.jpg`, roughness=`Rubber004_1K-JPG_Roughness.jpg`; metalness: none (non-metal)
- **rubber_tiles**:
  - color: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rubber_tiles/rubber_tiles_diff_1k.jpg
  - normal_dx: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rubber_tiles/rubber_tiles_nor_dx_1k.jpg
  - normal_gl: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rubber_tiles/rubber_tiles_nor_gl_1k.jpg
  - ao: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rubber_tiles/rubber_tiles_ao_1k.jpg
  - roughness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rubber_tiles/rubber_tiles_rough_1k.jpg
  - metalness: https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/rubber_tiles/rubber_tiles_arm_1k.jpg  (B channel)

</details>

### `chrome`

| # | Asset | Source / license | Maps verified at 1k | Visual note |
|---|---|---|---|---|
| 1 ★ | [Metal049A](https://ambientcg.com/a/Metal049A) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, roughness | PRIMARY chrome. Near-white smooth metal (Metalness map is 1, roughness very low); bumpers, rims and trim. |
| 2 | [Metal032](https://ambientcg.com/a/Metal032) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, roughness | Smooth brushed light-blue steel; satin chrome or aluminium. |
| 3 | [Metal009](https://ambientcg.com/a/Metal009) | ambientCG · CC0 | color, metalness, normal_dx, normal_gl, roughness | Brushed steel with fine scratches; brushed aluminium wheels and fixtures. |

<details><summary>Exact 1k URLs</summary>

- **Metal049A**: zip `https://ambientcg.com/get?file=Metal049A_1K-JPG.zip` with members color=`Metal049A_1K-JPG_Color.jpg`, height=`Metal049A_1K-JPG_Displacement.jpg`, metalness=`Metal049A_1K-JPG_Metalness.jpg`, normal_dx=`Metal049A_1K-JPG_NormalDX.jpg`, normal_gl=`Metal049A_1K-JPG_NormalGL.jpg`, roughness=`Metal049A_1K-JPG_Roughness.jpg`
- **Metal032**: zip `https://ambientcg.com/get?file=Metal032_1K-JPG.zip` with members color=`Metal032_1K-JPG_Color.jpg`, height=`Metal032_1K-JPG_Displacement.jpg`, metalness=`Metal032_1K-JPG_Metalness.jpg`, normal_dx=`Metal032_1K-JPG_NormalDX.jpg`, normal_gl=`Metal032_1K-JPG_NormalGL.jpg`, roughness=`Metal032_1K-JPG_Roughness.jpg`
- **Metal009**: zip `https://ambientcg.com/get?file=Metal009_1K-JPG.zip` with members color=`Metal009_1K-JPG_Color.jpg`, height=`Metal009_1K-JPG_Displacement.jpg`, metalness=`Metal009_1K-JPG_Metalness.jpg`, normal_dx=`Metal009_1K-JPG_NormalDX.jpg`, normal_gl=`Metal009_1K-JPG_NormalGL.jpg`, roughness=`Metal009_1K-JPG_Roughness.jpg`

</details>

---

## 4. HDRIs (Poly Haven, CC0)

Look evidence: `img/cc0_hdri.jpg`. Each 1k `.hdr` was downloaded and decoded; the peak luminance (`max`) is printed on the sheet.

- The `*_puresky` HDRIs are sky only, with a mirrored lower hemisphere. That suits Roblox `Sky` cube faces.
- 2k and 8k URLs and `exr_1k` are in the manifest. Each entry also has a `tonemapped_jpg` URL (an 8k LDR JPG), which is the quickest input for cube-face slicing.

### `hdri_clear_day`

| # | HDRI | Note | 1k HDR | 4k HDR |
|---|---|---|---|---|
| 1 ★ | [kloofendal_48d_partly_cloudy_puresky](https://polyhaven.com/a/kloofendal_48d_partly_cloudy_puresky) | PRIMARY. Deep blue sky with scattered puffy cumulus and a mirrored lower half; the classic GTA V midday. Sun peak about 60k. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/kloofendal_48d_partly_cloudy_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/kloofendal_48d_partly_cloudy_puresky_4k.hdr |
| 2 | [kloofendal_43d_clear_puresky](https://polyhaven.com/a/kloofendal_43d_clear_puresky) | Clear hazy blue with a high sun and a bright horizon band; for haze-friendly midday. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/kloofendal_43d_clear_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/kloofendal_43d_clear_puresky_4k.hdr |
| 3 | [qwantani_noon_puresky](https://polyhaven.com/a/qwantani_noon_puresky) | Cloudless noon with a hard sun and strong shadows. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/qwantani_noon_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/qwantani_noon_puresky_4k.hdr |

### `hdri_golden_hour`

| # | HDRI | Note | 1k HDR | 4k HDR |
|---|---|---|---|---|
| 1 ★ | [kloppenheim_06_puresky](https://polyhaven.com/a/kloppenheim_06_puresky) | PRIMARY. Low sun behind scattered gold-lit clouds over a warm horizon. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/kloppenheim_06_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/kloppenheim_06_puresky_4k.hdr |
| 2 | [qwantani_sunset_puresky](https://polyhaven.com/a/qwantani_sunset_puresky) | Sun on the horizon with a warm gold band and a blue zenith; clean sky. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/qwantani_sunset_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/qwantani_sunset_puresky_4k.hdr |
| 3 | [belfast_sunset_puresky](https://polyhaven.com/a/belfast_sunset_puresky) | Moody sunset under a dark cloud deck and a bright rim; overcast-evening variant. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/belfast_sunset_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/belfast_sunset_puresky_4k.hdr |

### `hdri_blue_hour`

| # | HDRI | Note | 1k HDR | 4k HDR |
|---|---|---|---|---|
| 1 ★ | [qwantani_dusk_2_puresky](https://polyhaven.com/a/qwantani_dusk_2_puresky) | PRIMARY. Pink and lavender afterglow fading to blue, no sun disk; Vice-City dusk. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/qwantani_dusk_2_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/qwantani_dusk_2_puresky_4k.hdr |
| 2 | [qwantani_dusk_1_puresky](https://polyhaven.com/a/qwantani_dusk_1_puresky) | Cooler blue dusk with a single dark cloud bank. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/qwantani_dusk_1_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/qwantani_dusk_1_puresky_4k.hdr |
| 3 | [syferfontein_0d_clear_puresky](https://polyhaven.com/a/syferfontein_0d_clear_puresky) | Sun exactly at the horizon in a clear sky; transitional frame. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/syferfontein_0d_clear_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/syferfontein_0d_clear_puresky_4k.hdr |

### `hdri_night_city`

| # | HDRI | Note | 1k HDR | 4k HDR |
|---|---|---|---|---|
| 1 ★ | [kloppenheim_07_puresky](https://polyhaven.com/a/kloppenheim_07_puresky) | PRIMARY. Overcast night sky lit from below by artificial light (city-glow look); darken exposure in the skybox. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/kloppenheim_07_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/kloppenheim_07_puresky_4k.hdr |
| 2 | [kloppenheim_02_puresky](https://polyhaven.com/a/kloppenheim_02_puresky) | Clear starry night with a bright moon; desert or countryside nights. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/kloppenheim_02_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/kloppenheim_02_puresky_4k.hdr |
| 3 | [qwantani_night_puresky](https://polyhaven.com/a/qwantani_night_puresky) | Milky-way night with horizon light pollution; too rural for downtown. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/qwantani_night_puresky_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/qwantani_night_puresky_4k.hdr |

### `hdri_reference_ibl_only`

| # | HDRI | Note | 1k HDR | 4k HDR |
|---|---|---|---|---|
| 1 | [shanghai_bund](https://polyhaven.com/a/shanghai_bund) | Neon skyline promenade at night. NOT a skybox (it has ground and buildings); use as a lighting and colour reference. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/shanghai_bund_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/shanghai_bund_4k.hdr |
| 2 | [rooftop_night](https://polyhaven.com/a/rooftop_night) | Twilight parking rooftop with sodium lamps; a night lighting reference. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/rooftop_night_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/rooftop_night_4k.hdr |
| 3 | [sunset_jhbcentral](https://polyhaven.com/a/sunset_jhbcentral) | Downtown rooftops at a pink dusk; a GTA-like city mood reference. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/sunset_jhbcentral_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/sunset_jhbcentral_4k.hdr |
| 4 | [wide_street_01](https://polyhaven.com/a/wide_street_01) | Wide sunny city avenue; a daytime urban reference. | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/wide_street_01_1k.hdr | https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/4k/wide_street_01_4k.hdr |

---

## 5. Models: realistic cars, guns and street props

Look evidence:

- `img/cc0_cars_objaverse_a.jpg` and `img/cc0_cars_objaverse_b.jpg`;
- `img/cc0_guns_objaverse.jpg`;
- `img/cc0_props_objaverse.jpg`;
- `img/cc0_props_polyhaven.jpg`;
- `img/cc0_models_opengameart.jpg`;
- `img/cc0_palms_nobiax.jpg`.

Each preview tile shows two orthographic views, and the header line gives the triangle count, mesh-node count and number of wheel-named nodes. Some "side" views show the car end-on, because the model's long axis is Z.

**Triangle counts** come from the downloaded file: for Objaverse, the GLB, which can differ slightly from Sketchfab's listed face count.

**"Wheels separable"** was judged from the GLB node names:

- **yes:** individual wheel nodes, ready for spinning `MeshPart`s and constraints;
- **partial / no:** wheels are fused into the body, so separate them by loose parts in Blender before import.

**Attribution template** for CC-BY models, for the credits screen:
`"<Model name>" by <author> (https://sketchfab.com/3d-models/<uid>) — CC BY 4.0, modified (renamed, debadged, decimated).`

### `model_car_objaverse`: CC-BY-4.0 (attribution required)

| Verdict | Model (author) | Tris | Wheels separable | GLB URL | Note |
|---|---|---|---|---|---|
| TOP (police) | [80s Generic police car - Low poly model](https://sketchfab.com/3d-models/61766c1e6e1e4b2b803c174f33433a74) (DanielZhabotinsky) | 23,813 | yes: Wheel_FL/FR/RL/RR nodes, plus separate doors, hood and interior | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-024/61766c1e6e1e4b2b803c174f33433a74.glb | 80s full-size police sedan (LTD/Crown-Vic-like) with a light bar and spotlight; one 'Bodycolor' material, so it is paintable. Unbadged 'generic' design. |
| TOP (traffic) | [80s Generic midsize sedan - Low poly model](https://sketchfab.com/3d-models/e2678da920cc4be68dbc193727919ffb) (DanielZhabotinsky) | 22,168 | yes: per-wheel nodes, separate doors and hood | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-031/e2678da920cc4be68dbc193727919ffb.glb | 80s generic mid-size 4-door sedan; Bodycolor material; ideal traffic filler. |
| TOP (traffic) | ['80s Generic USA Station wagon - Low poly model](https://sketchfab.com/3d-models/aa0becb6e854422596cac6b21bf79787) (DanielZhabotinsky) | 23,581 | yes: per-wheel nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-124/aa0becb6e854422596cac6b21bf79787.glb | 80s generic US station wagon with roof rails; suburbs. |
| TOP (muscle) | [American Muscle '71 - Low poly model](https://sketchfab.com/3d-models/955edc733c6d44fabc0ad7c246a15896) (DanielZhabotinsky) | 26,326 | yes: per-wheel nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-071/955edc733c6d44fabc0ad7c246a15896.glb | '71 Firebird-style muscle coupe; uses KHR_materials_clearcoat (Roblox ignores it, the base PBR is still fine). |
| GOOD (taxi, retro) | [Old Taxicab - Low poly model](https://sketchfab.com/3d-models/9e8f92a215784f3d8aaaaeab1bef54c4) (DanielZhabotinsky) | 18,879 | yes: per-wheel nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-142/9e8f92a215784f3d8aaaaeab1bef54c4.glb | Checker-style yellow cab; NYC-retro rather than a modern LA taxi. |
| TOP (armored-truck event) | [Ford F700 Armored Truck](https://sketchfab.com/3d-models/26e809cce40e4359a3199649f12ef295) (DanielZhabotinsky) | 20,360 | yes: wheelRR/RL tire+rim nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-123/26e809cce40e4359a3199649f12ef295.glb | Ford F700 cash-in-transit armored truck; exactly the 5-minute armored-truck event vehicle. Remove the Ford name and badge. |
| GOOD (ambulance) | [Old Ambulance van - Low Poly model](https://sketchfab.com/3d-models/2856dd3c61f940909dced9a5c0379484) (DanielZhabotinsky) | 27,621 | yes: per-wheel nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-046/2856dd3c61f940909dced9a5c0379484.glb | Chevy-van ambulance with red/white livery and light bar; retro. |
| GOOD (modern coupe) | ['07 Generic Coupe - Low poly model](https://sketchfab.com/3d-models/22abe5284d4c4b55920b8462eb24a8c1) (DanielZhabotinsky) | 15,125 | yes: wheel_1..4 nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-128/22abe5284d4c4b55920b8462eb24a8c1.glb | 2007 generic 3-door coupe/hatch (Focus-like); one of the few modern shapes in the set. Exported in centimetres, so scale by 0.01. |
| GOOD (SUV) | [Generic SUV - Low poly model](https://sketchfab.com/3d-models/2866efdfa943484391ef8313768e074d) (DanielZhabotinsky) | 17,721 | partial: all 4 wheels are in one node, so split by loose parts | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-005/2866efdfa943484391ef8313768e074d.glb | Modern compact SUV (Duster-like), white, 17.7k tris; cm units. |
| GOOD (pickup) | [Generic 90s light pickup - Low poly model](https://sketchfab.com/3d-models/6c48c94be8974dc7a5932f697c0ba68f) (DanielZhabotinsky) | 22,502 | yes: per-wheel nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-089/6c48c94be8974dc7a5932f697c0ba68f.glb | 90s light pickup with roll bar. |
| TOP (traffic pack) | [Generic passenger car pack](https://sketchfab.com/3d-models/20f9af9b8a404d5cb022ac6fe87f21f5) (comrade1280) | 69,312 | yes: separate Wheel_* nodes for every car | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-102/20f9af9b8a404d5cb022ac6fe87f21f5.glb | One GLB with 10 generic modern civilian cars (compact, coupe, hatchback, minivan, off-road, pickup, SUV, sedan, sport, wagon), about 6-7k tris each, with separate glass and optics materials. The best single source for modern traffic variety. |
| TOP (service pack) | [Generic civil service vehicles pack](https://sketchfab.com/3d-models/8ff2a13f30914932a70c7950cfa58465) (comrade1280) | 92,707 | no: wheels are part of each body mesh, so split by loose parts in Blender | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-136/8ff2a13f30914932a70c7950cfa58465.glb | One GLB with 10 generic service vehicles (ambulance, city bus, fire truck, garbage truck, police sedan, road-service truck, school bus, taxi, tow truck, post van), about 9k tris each, with decals and optics textures. |
| GOOD (hero super, fictional) | [Fictional supercar - V12 Goblin](https://sketchfab.com/3d-models/0a20e49ad5774d778567cb5c3f345786) (ollitei) | 86,623 | yes: wheel, tire and brake nodes per corner | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-112/0a20e49ad5774d778567cb5c3f345786.glb | Fictional V12 supercar, so there is no trademark risk. 86.6k tris: decimate to the Roblox per-mesh cap. Its materials use the deprecated KHR_materials_pbrSpecularGlossiness and have no textures, so convert to metal/rough. Exported tiny (0.25 units). |
| GOOD (modern taxi) | [2001 Crown Victoria Taxi Game Prop](https://sketchfab.com/3d-models/2429a825ff1646568e8e6e1453f9c501) (haoliu95) | 33,866 | no: in the 'wheels_and_parts' node | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-006/2429a825ff1646568e8e6e1453f9c501.glb | 2001 Crown Victoria yellow cab game prop with textures; 34k tris. Rename and debadge. |
| GOOD (modern police) | [2001 Crown Victoria Police Interceptor Game Prop](https://sketchfab.com/3d-models/9f30d360cee343efb5a441978ddb57bd) (haoliu95) | 42,362 | no: merged | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-122/9f30d360cee343efb5a441978ddb57bd.glb | 2001 Crown Vic Police Interceptor, black/white; the iconic US cop car. 42k tris, so decimate. |
| OK (light police) | [Highway Patrol Cruiser](https://sketchfab.com/3d-models/3d85e608d2c847c58577074faa134cbc) (jeandiz) | 12,164 | likely: Circle.00x nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-072/3d85e608d2c847c58577074faa134cbc.glb | Highway-patrol Crown Vic, blue; only 12k tris; uses KHR_materials_transmission for glass. |
| SKIP | [(FREE) 1995 Fiat Punto GT](https://sketchfab.com/3d-models/48db6facb4b64e99b60f36b8c01185e1) (karolmiklas) | 35,164 | no | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-090/48db6facb4b64e99b60f36b8c01185e1.glb | 1995 Fiat Punto: high quality, but a real brand, spec-gloss materials with no textures in the GLB, and a European hatchback that is off-theme. |
| GOOD (van) | [Old Chevy van - Low poly model](https://sketchfab.com/3d-models/09d718c9cf72401b8534d265a06a803f) (DanielZhabotinsky) | 23,940 | yes: per-wheel nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-087/09d718c9cf72401b8534d265a06a803f.glb | Old Chevy G-series panel van; for heist, delivery or gang vehicles. |
| OK (municipal) | [Maintenance vehicles](https://sketchfab.com/3d-models/601a416ce706453e8230b3b4c837ce84) (ondrasaur) | 29,532 | no | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-116/601a416ce706453e8230b3b4c837ce84.glb | Five orange municipal trucks (garbage, street sweeper, dump, crane) in one GLB; textured. |
| OK (helicopter) | [Helicopter](https://sketchfab.com/3d-models/91366449ce6842f784748a914e29d641) (irs1182) | 27,470 | n/a: 3 objects (body plus rotors?) | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-152/91366449ce6842f784748a914e29d641.glb | Huey-style green helicopter, 27k tris, textured; recolour for police or news chopper. |
| OK (motorcycle) | [Motorcycle](https://sketchfab.com/3d-models/693e83d86e1e4e5b95e4314dbdd95d40) (Silas6) | 69,908 | 8 unnamed nodes | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-129/693e83d86e1e4e5b95e4314dbdd95d40.glb | Modern sport-touring bike, textured; 70k tris, so decimate. |

### `model_gun_objaverse`: CC-BY-4.0 (attribution required)

| Verdict | Model (author) | Tris | Wheels separable | GLB URL | Note |
|---|---|---|---|---|---|
| GOOD (pistol) | [Colt M1911](https://sketchfab.com/3d-models/26adfd631730494ab0fc80c806eada77) (FrenchBaguette) | 3,857 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-054/26adfd631730494ab0fc80c806eada77.glb | Colt M1911 with a suppressor and a separate round; 3.9k tris, 1 texture. |
| TOP (pistol) | [Heckler & Koch USP Pistol](https://sketchfab.com/3d-models/972e3643000246e8959a6df509557bcc) (Urpo) | 7,266 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-052/972e3643000246e8959a6df509557bcc.glb | HK USP polymer pistol, PBR, 7.3k tris; the GTA 'combat pistol' archetype. |
| TOP (rifle) | [AR-15 style rifle](https://sketchfab.com/3d-models/50d33435445e439c95e3b36e9d4bd798) (jeandiz) | 30,394 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-014/50d33435445e439c95e3b36e9d4bd798.glb | AR-15/M4 carbine with optic, PBR, 30k tris (decimate or drop the optic); the 'carbine rifle' archetype. |
| TOP (rifle) | [Low Poly AK-47](https://sketchfab.com/3d-models/384565b1779c450b90397232163e4e6d) (lokeig) | 17,392 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-093/384565b1779c450b90397232163e4e6d.glb | AK-47 with wood furniture, 17.4k tris, 65 parts (animatable); the 'assault rifle' archetype. |
| TOP (SMG) | [HK MP5 (9mm submachine gun)](https://sketchfab.com/3d-models/c503d96157614fb78b5953d49e643b78) (so_O) | 11,388 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-043/c503d96157614fb78b5953d49e643b78.glb | MP5 with red-dot sight, about 11k tris, 1 texture; the 'SMG' archetype. |
| GOOD (SMG) | [Low-Poly Mini Uzi](https://sketchfab.com/3d-models/4b585cdf292d4f0798ce40f0d5ff2507) (TastyTony) | 4,572 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-052/4b585cdf292d4f0798ce40f0d5ff2507.glb | Mini Uzi with folding stock, 4.6k tris, untextured materials; the 'micro SMG'. Exported in cm. |
| TOP (shotgun) | [Remington 870 Shotgun](https://sketchfab.com/3d-models/05a6a02909ee4fcfa5cde3d76cb067f0) (Urpo) | 7,044 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-029/05a6a02909ee4fcfa5cde3d76cb067f0.glb | Remington 870 pump, PBR, 7k tris; the 'pump shotgun'. |
| GOOD (shotgun) | [Double-barreled shotgun](https://sketchfab.com/3d-models/99734ee367dc4872b6183412c9d76a4c) (shedmon) | 5,040 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-111/99734ee367dc4872b6183412c9d76a4c.glb | Sawn-off double barrel with wood stock, 5k tris; the 'sawed-off'. Has absurd units, so rescale. |
| GOOD (sniper) | [Sniper rifle GameReady Free](https://sketchfab.com/3d-models/e520b234140049e7890db0b6c29d3925) (pashtetuser) | 15,257 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-009/e520b234140049e7890db0b6c29d3925.glb | Modern bolt sniper with a large scope, 15k tris, 42 parts. |
| TOP (melee) | [Baseball Bat – Pack 00](https://sketchfab.com/3d-models/ac2415a56d114bbf94e181cb7ce77be4) (cgunwale) | 2,148 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-041/ac2415a56d114bbf94e181cb7ce77be4.glb | Three baseball bats (wood, black, aluminium), 2.1k tris; the GTA melee staple. |
| GOOD (rifle alt) | [HK 416 A7 (free download)](https://sketchfab.com/3d-models/a16768f0ffa24737a4fe324a411cfbd9) (r4m) | 30,088 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-049/a16768f0ffa24737a4fe324a411cfbd9.glb | HK416 A7 with mag and rounds, PBR, 30k tris. |
| OK (machine pistol) | [Machine Pistol MAC-11](https://sketchfab.com/3d-models/59b6839f305f44c5a9bc5c2762e7be93) (kutejnikov) | 3,642 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-013/59b6839f305f44c5a9bc5c2762e7be93.glb | MAC-11, 3.6k tris; spec-gloss materials, renders untextured grey. |

### `model_prop_objaverse`: CC-BY-4.0 (attribution required)

| Verdict | Model (author) | Tris | Wheels separable | GLB URL | Note |
|---|---|---|---|---|---|
| OK (palm) | [Palm Tree tall](https://sketchfab.com/3d-models/557ea8d4527f47e8bbc657e2764b7cab) (pizzaguyty) | 1,964 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-081/557ea8d4527f47e8bbc657e2764b7cab.glb | Tall thin palm, 2k tris, alpha-card fronds (the preview shows the cards as solid). |
| GOOD (palm) | [Coconut Palm](https://sketchfab.com/3d-models/26e787f2ff2e4c0fb004c3b0210805a3) (evolveduk) | 11,997 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-004/26e787f2ff2e4c0fb004c3b0210805a3.glb | Coconut palm pair (Tree-It), 12k tris, alpha fronds; the Miami look. |
| OK (palm) | [Palm Trees](https://sketchfab.com/3d-models/20f8a8d5054b4191afb7cf3270dbd586) (ElectroNick) | 24,119 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-080/20f8a8d5054b4191afb7cf3270dbd586.glb | Curved palm cluster, 24k tris; huge units. |
| GOOD (prop) | [dumpster](https://sketchfab.com/3d-models/989ea7f01b924859b3484ee27103e8d9) (YJ_) | 11,193 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-047/989ea7f01b924859b3484ee27103e8d9.glb | Front-load dumpster pair (black and green), 11k tris, PBR; alleys. |
| OK (street light) | [Street Light](https://sketchfab.com/3d-models/2d44b333f56c4faaab1bd2007868cc37) (kloworks) | 608 | — | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-025/2d44b333f56c4faaab1bd2007868cc37.glb | Modern cobra-head style street light, 608 tris; the LA street light shape PH lacks. |

### `model_prop_polyhaven`: CC0

| Verdict | Model | Tris | glTF 1k URL | Note |
|---|---|---|---|---|
| GOOD | [fire_hydrant](https://polyhaven.com/a/fire_hydrant) | 86,316 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/fire_hydrant/fire_hydrant_1k.gltf | Red/orange hydrant set (several variants). 86k tris for the whole set, so pick one and decimate. |
| OFF-THEME | [street_lamp_01](https://polyhaven.com/a/street_lamp_01) | 30,610 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/street_lamp_01/street_lamp_01_1k.gltf | Victorian/European lantern post; old-town only, not LA. |
| OFF-THEME | [street_lamp_02](https://polyhaven.com/a/street_lamp_02) | 20,338 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/street_lamp_02/street_lamp_02_1k.gltf | European wall-bracket lantern. |
| GOOD | [metal_trash_can](https://polyhaven.com/a/metal_trash_can) | 13,960 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/metal_trash_can/metal_trash_can_1k.gltf | Galvanised trash cans (clean and dented) with lids, 14k tris. |
| TOP | [concrete_road_barrier](https://polyhaven.com/a/concrete_road_barrier) | 60,928 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/concrete_road_barrier/concrete_road_barrier_1k.gltf | Jersey barrier with scuffed paint, photoscan quality, 61k tris (decimate); freeway and roadblocks. |
| TOP | [modular_chainlink_fence](https://polyhaven.com/a/modular_chainlink_fence) | 89,232 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/modular_chainlink_fence/modular_chainlink_fence_1k.gltf | Modular chain-link fence kit (posts, panels, gate) with alpha; 89k tris across the kit. |
| GOOD | [modular_electricity_poles](https://polyhaven.com/a/modular_electricity_poles) | 200,610 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/modular_electricity_poles/modular_electricity_poles_1k.gltf | Wooden utility poles, crossarms and transformers kit (103 parts); LA suburbs and alleys. |
| GOOD | [utility_box_02](https://polyhaven.com/a/utility_box_02) | 6,268 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/utility_box_02/utility_box_02_1k.gltf | Green street utility cabinet, 6k tris. |
| GOOD | [water_manhole_cover](https://polyhaven.com/a/water_manhole_cover) | 6,301 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/water_manhole_cover/water_manhole_cover_1k.gltf | Cast manhole cover mesh, 6k tris. |
| OK | [modular_street_seating](https://polyhaven.com/a/modular_street_seating) | 25,156 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/modular_street_seating/modular_street_seating_1k.gltf | Modern wood and metal street bench kit. |
| GOOD | [security_camera_01](https://polyhaven.com/a/security_camera_01) | 13,571 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/security_camera_01/security_camera_01_1k.gltf | CCTV camera on a wall arm, 13.6k tris; for stores and banks (heist). |
| TOP | [rollershutter_door](https://polyhaven.com/a/rollershutter_door) | 1,104 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/rollershutter_door/rollershutter_door_1k.gltf | Roller shutter garage door, 1.1k tris; garages, storefronts and the chop shop. |
| GOOD | [old_tyre](https://polyhaven.com/a/old_tyre) | 2,880 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/old_tyre/old_tyre_1k.gltf | Worn car tyre, 2.9k tris; junkyard, or a reference for the tire texture. |
| OK | [rusted_wheel_rim_01](https://polyhaven.com/a/rusted_wheel_rim_01) | 16,440 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/rusted_wheel_rim_01/rusted_wheel_rim_01_1k.gltf | Rusted steel wheel rim, 16k tris; junkyard. |
| OK | [covered_car](https://polyhaven.com/a/covered_car) | 12,592 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/covered_car/covered_car_1k.gltf | Car under a tarp with 4 visible wheels, 12.6k tris; garage and lot set dressing. |
| GOOD | [service_pistol](https://polyhaven.com/a/service_pistol) | 27,548 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/service_pistol/service_pistol_1k.gltf | CC0 Walther-P38-style vintage pistol with magazines and a round (11 parts), 27.5k tris; the only CC0 handgun on PH. |
| OK | [bolt_action_rifle_7_62](https://polyhaven.com/a/bolt_action_rifle_7_62) | 19,985 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/bolt_action_rifle_7_62/bolt_action_rifle_7_62_1k.gltf | CC0 Mosin-style bolt-action rifle, 20k tris; a hunting-rifle archetype. |
| OK | [korean_public_payphone_01](https://polyhaven.com/a/korean_public_payphone_01) | 48,132 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/korean_public_payphone_01/korean_public_payphone_01_1k.gltf | Payphone, 48k tris; Korean design, so it needs a re-skin for a US look. |
| GOOD | [trashbag](https://polyhaven.com/a/trashbag) | 4,482 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/trashbag/trashbag_1k.gltf | Black garbage bag, 4.5k tris. |
| GOOD | [Barrel_01](https://polyhaven.com/a/Barrel_01) | 2,682 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/Barrel_01/Barrel_01_1k.gltf | Red oil drum, 2.7k tris. |
| GOOD | [wooden_picnic_table](https://polyhaven.com/a/wooden_picnic_table) | 10,210 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/wooden_picnic_table/wooden_picnic_table_1k.gltf | Park picnic table, 10k tris. |
| OK | [potted_plant_01](https://polyhaven.com/a/potted_plant_01) | 176,226 | https://dl.polyhaven.org/file/ph-assets/Models/gltf/1k/potted_plant_01/potted_plant_01_1k.gltf | Terracotta potted plant, 176k tris (heavy); for interiors. |

### `model_opengameart`

| Verdict | Model | License | Tris | Download | Verified | Note |
|---|---|---|---|---|---|---|
| GOOD | [Pistol (loafbrr_1)](https://opengameart.org/content/pistol-5) | CC0 | 2537 | https://opengameart.org/sites/default/files/pistolfbxgltftexturesblend_1.zip | downloaded and rendered; glTF with 8 separate parts (frame, slide, barrel, hammer, trigger, magazine) and 1k PBR textures | Modern 1911-style pistol; the moving parts make it ideal for reload and slide animation. Low-poly but clean. |
| OK | [High-poly AK-47 (Lamoot)](https://opengameart.org/content/high-poly-ak-47) | CC0 | 30730 | https://opengameart.org/sites/default/files/highpoly_ak47.obj | downloaded and rendered; untextured single mesh | Accurate CC0 AK silhouette; needs UVs and texturing, or use the Objaverse AK (textured) instead. |
| GOOD | [M4A1 Assault Rifle (nisu)](https://opengameart.org/content/m4a1-assault-rifle) | CC0 | ? | https://opengameart.org/sites/default/files/m4a1_0.zip | downloaded; FBX with Base Color, Metallic, Roughness, Normal and Height PNGs (not rendered: FBX) | CC0 PBR M4A1; the best CC0 (non-attribution) rifle found. |
| UNVERIFIED | [AKM (LonesomeDucky)](https://opengameart.org/content/akm) | CC0 | ? | https://opengameart.org/sites/default/files/akm54.blend | not downloaded (41 MB .blend) | Low-poly weathered AKM with PBR textures (from the page description). |
| UNVERIFIED | [Desert Eagle (SirDraco65)](https://opengameart.org/content/desert-eagle-0) | CC0 | ? | https://opengameart.org/sites/default/files/desert_eagle_0.zip | not downloaded (64 MB) | Textured and rigged FBX plus blend; a 'heavy pistol' archetype. |
| UNVERIFIED | [Bullpup Submachine Gun (Kutejnikov)](https://opengameart.org/content/bullpup-submachine-gun) | CC-BY-4.0 | 3555 | https://opengameart.org/sites/default/files/submachine_gun.7z | not downloaded (85 MB; 7z tool not installed) | 4k PBR textures (diffuse, spec, gloss, normal, AO). |
| UNVERIFIED | [low poly modern weapons (Casti_131)](https://opengameart.org/content/low-poly-modern-weapons) | CC-BY-3.0 | ? | https://opengameart.org/sites/default/files/low%20poly%20modern%20weapons.zip | not downloaded | One blend with about 20 guns (AUG, M16, M4, SCAR, Barrett, AK-103, MP5, Glock 18, M9, 1911, Deagle, G36C, AA-12, minigun); low-poly, untextured. |
| STYLIZED | [Ultimate Gun Pack (quaternius)](https://opengameart.org/content/low-poly-guns-pack) | CC0 | ? | https://opengameart.org/sites/default/files/ultimate_gun_pack_by_quaternius.zip | not downloaded | 40 stylized flat-colour guns; off-style for grounded realism (placeholder only). |
| REJECT | [Car VW Corradon (rohezal)](https://opengameart.org/content/car-vw-corradon) | CC0 | 2850 | https://opengameart.org/sites/default/files/car_0.zip | downloaded and rendered; crude 2011 boxy mesh | Too crude for the v2 bar. |
| STYLIZED/REJECT | [Car Kit (Kenney, mirrored on OGA)](https://opengameart.org/content/car-kit) | CC0 | 2304 | https://opengameart.org/sites/default/files/kenney_car-kit_3.1.zip | downloaded and rendered police.glb; separate wheel nodes | Cute toy-like stylized cars (sedan, police, taxi, ambulance, firetruck, garbage truck, van, SUV). Off-style: a kill-list risk for 'basic Roblox' look. |
| STYLIZED | [Free Low Poly Vehicles Pack (rgsdev)](https://opengameart.org/content/free-low-poly-vehicles-pack) | CC0 | ? | https://opengameart.org/sites/default/files/free_low_poly_vehicles_pack_by_rgsdev.zip | downloaded; FBX only (Sedan, Police Sedan/SUV/Sports, Ambulance, Bus, Firetruck, Hatchback, Limo, Muscle, Roadster, Monster Truck) | Separated wheels and flat-colour materials; low-poly stylized. |
| UNVERIFIED | [Mac Truck (Creomoto)](https://opengameart.org/content/mac-truck) | CC0 | 67428 | https://opengameart.org/sites/default/files/Mac.blend | not downloaded | Semi-truck tractor; 67k tris per the page. |
| UNVERIFIED | [3D Bus (ajanhallinta)](https://opengameart.org/content/3d-bus) | CC0 | 5669 | https://opengameart.org/sites/default/files/3DBus_by_ajanhallinta.zip | not downloaded | Coach bus, materials only. |
| TOP (palm) | [Free palm treeZ v3 (Yughues)](https://opengameart.org/content/free-palm-treez-v3) | CC0 | 940 | https://opengameart.org/sites/default/files/PACK%20V3_0.7z | downloaded, extracted (py7zr) and opened: 5 OBJ+FBX palms (straight, bend, dual, dual_bend, trio = 940/940/1880/1880/2820 tris), 2048 RGBA diffuse with alpha fronds, plus normal, specular and translucency TGA; readme confirms CC0 (Nobiax/Yughues) | Semi-realistic coconut palms with alpha-card fronds; the best verified CC0 palm (Miami look). Not a tall LA Washingtonia fan palm. |

### `model_objaverse_more_unverified`: found in metadata, not yet downloaded

| Model (author) | License | Faces | GLB URL |
|---|---|---|---|
| [80 American Sedan - Low poly model](https://sketchfab.com/3d-models/892b2684fb37442299bfad9222cf331c) (DanielZhabotinsky) | CC-BY-4.0 | 21,556 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-078/892b2684fb37442299bfad9222cf331c.glb |
| [88 American Sedan - Low poly model](https://sketchfab.com/3d-models/8509a7f82665442592627940b7a1cfab) (DanielZhabotinsky) | CC-BY-4.0 | 22,655 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-148/8509a7f82665442592627940b7a1cfab.glb |
| [Foxbody police sedan - Low poly model](https://sketchfab.com/3d-models/9eff77e9c5974c0d91418339eedccccd) (DanielZhabotinsky) | CC-BY-4.0 | 11,177 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-083/9eff77e9c5974c0d91418339eedccccd.glb |
| [60s Classic American SUV - Low poly model](https://sketchfab.com/3d-models/22015d1863d6455aa31cfd738b972c50) (DanielZhabotinsky) | CC-BY-4.0 | 29,184 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-110/22015d1863d6455aa31cfd738b972c50.glb |
| [British compact car - Low poly model](https://sketchfab.com/3d-models/f1e9c43c61bb492a9b15d84f9a16c0f7) (DanielZhabotinsky) | CC-BY-4.0 | 10,694 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-015/f1e9c43c61bb492a9b15d84f9a16c0f7.glb |
| [Old Ford Lifted Pickup - Low poly model](https://sketchfab.com/3d-models/aa216ce078814eb5b0e07906a8e9e072) (DanielZhabotinsky) | CC-BY-4.0 | 13,813 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-053/aa216ce078814eb5b0e07906a8e9e072.glb |
| [French delivery van](https://sketchfab.com/3d-models/a350a422d200485ea57778dc42139edc) (DanielZhabotinsky) | CC-BY-4.0 | 6,963 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-053/a350a422d200485ea57778dc42139edc.glb |
| [2001 CVPI Sheriff Game Prop](https://sketchfab.com/3d-models/219e25d6174745ae8d9c37f53aafea03) (haoliu95) | CC-BY-4.0 | 43,292 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-004/219e25d6174745ae8d9c37f53aafea03.glb |
| [Los Angeles Police Department car](https://sketchfab.com/3d-models/795fa0620bc44db8afcb06720a4dadd7) (jeandiz) | CC-BY-4.0 | 241,902 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-084/795fa0620bc44db8afcb06720a4dadd7.glb |
| [SWAT Vehicle](https://sketchfab.com/3d-models/adfc070519694b3dbf5001e6ee1c742a) (Jj.Mmhh) | CC-BY-4.0 | 28,400 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-075/adfc070519694b3dbf5001e6ee1c742a.glb |
| [Oldsmobile Cutlass Supreme Sedan '71](https://sketchfab.com/3d-models/78f76d386a4341b0b71745bdc50fd5ab) (barbo-autos) | CC-BY-4.0 | 70,258 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-080/78f76d386a4341b0b71745bdc50fd5ab.glb |
| [HUMMER H2](https://sketchfab.com/3d-models/5cd3ea8eb94c4f5597cc086b2df40e58) (better_peter) | CC-BY-4.0 | 66,885 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-053/5cd3ea8eb94c4f5597cc086b2df40e58.glb |
| [Range Rover Evoque](https://sketchfab.com/3d-models/e0bb09118ab84fe0a0530bd0df2fd74a) (minghau) | CC-BY-4.0 | 38,912 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-080/e0bb09118ab84fe0a0530bd0df2fd74a.glb |
| [1971 Buick Riviera Custom](https://sketchfab.com/3d-models/268d8b02b7e6424cb624ca3718b5cc27) (everhard) | CC-BY-4.0 | 155,747 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-020/268d8b02b7e6424cb624ca3718b5cc27.glb |
| [Breaking Bad RV - 1986 Fleetwood Bounder](https://sketchfab.com/3d-models/0a1703bd068546b2af34a5b5e5b0ceca) (jamiemcfarlane) | CC-BY-4.0 | 25,473 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-146/0a1703bd068546b2af34a5b5e5b0ceca.glb |
| [Bell UH-1 Iroquois (Huey)](https://sketchfab.com/3d-models/f3ca0e7bfcd5479d900e76438be0d76f) (helijah) | CC-BY-4.0 | 98,481 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-104/f3ca0e7bfcd5479d900e76438be0d76f.glb |
| [Harley Davidson Breakout](https://sketchfab.com/3d-models/7d446ec9135c4e35892714d117b37268) (FWSean) | CC-BY-4.0 | 41,313 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-150/7d446ec9135c4e35892714d117b37268.glb |
| [Makarov PM](https://sketchfab.com/3d-models/dbf03ce95c834cb7b07edba799dcd46a) (Bexxie) | CC-BY-4.0 | 22,199 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-046/dbf03ce95c834cb7b07edba799dcd46a.glb |
| [Desert Eagle](https://sketchfab.com/3d-models/cabde59f5cf24effaf80536e35d04e95) (ELIZION) | CC-BY-4.0 | 13,279 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-155/cabde59f5cf24effaf80536e35d04e95.glb |
| [Smith & Wesson 500 Magnum](https://sketchfab.com/3d-models/f7dbf63385644ab290b0f56428dcfde6) (FrenchBaguette) | CC-BY-4.0 | 11,901 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-153/f7dbf63385644ab290b0f56428dcfde6.glb |
| [M16 Assault Rifle](https://sketchfab.com/3d-models/339d0f7b21024387853dd926a5d51b50) (jeandiz) | CC-BY-4.0 | 21,688 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-152/339d0f7b21024387853dd926a5d51b50.glb |
| [AK-74M Assault Rifle](https://sketchfab.com/3d-models/9084c3bae8224d338103997bc3101480) (FJH) | CC-BY-4.0 | 17,595 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-075/9084c3bae8224d338103997bc3101480.glb |
| [Kriss Vector  (FREE MODEL)](https://sketchfab.com/3d-models/1b7df7e6c61544ac8d55201f953c32af) (javadbayat) | CC-BY-4.0 | 57,066 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-158/1b7df7e6c61544ac8d55201f953c32af.glb |
| [Modular P90 Tactical](https://sketchfab.com/3d-models/080897fc0366455884b1a916684313fe) (doomsentinel) | CC-BY-4.0 | 20,964 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-026/080897fc0366455884b1a916684313fe.glb |
| [MP5SD (Silenced MP5)](https://sketchfab.com/3d-models/2b96ccb2dc51496e93f41734663bcadf) (WillyG99) | CC-BY-4.0 | 12,085 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-017/2b96ccb2dc51496e93f41734663bcadf.glb |
| [Classic Shotgun - Remington M31](https://sketchfab.com/3d-models/9f64764395c54cc7a67fd8a29b9dbabf) (minghau) | CC-BY-4.0 | 9,214 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-139/9f64764395c54cc7a67fd8a29b9dbabf.glb |
| [Shotgun- Benelli M90 (XM1014)](https://sketchfab.com/3d-models/f4dcc609a4794a17bc1b53245e9a9744) (NayoSkumfuk) | CC-BY-4.0 | 11,476 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-065/f4dcc609a4794a17bc1b53245e9a9744.glb |
| [CheyTac M300 (McMillan stock)](https://sketchfab.com/3d-models/ef18b1cce6834df7804ea63aa61ce63a) (FrenchBaguette) | CC-BY-4.0 | 8,071 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-114/ef18b1cce6834df7804ea63aa61ce63a.glb |
| [Kar98k Free Model](https://sketchfab.com/3d-models/e88c90c8e203401fa28e8f4ef03e657f) (dsamuta) | CC-BY-4.0 | 10,699 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-102/e88c90c8e203401fa28e8f4ef03e657f.glb |
| [Special Sniper Rifle VSS Vintorez](https://sketchfab.com/3d-models/4d5d8c1b7b79429abfa4816f18330089) (ArmsMuseum) | CC0 | 35,960 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-083/4d5d8c1b7b79429abfa4816f18330089.glb |
| [Machete](https://sketchfab.com/3d-models/24eee9bdc1014708bcbe2e71e8a6272b) (shedmon) | CC-BY-4.0 | 2,878 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-066/24eee9bdc1014708bcbe2e71e8a6272b.glb |
| [M9 Bayonet knife](https://sketchfab.com/3d-models/eb61a59f65e449d2a2eabbaef76a4a43) (michaelkarel) | CC-BY-4.0 | 1,637 | https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-011/eb61a59f65e449d2a2eabbaef76a4a43.glb |
---

## 6. Recommended v1 kit (minimum set to replace the pastel look)

| Use | Asset(s) |
|---|---|
| Roads | `Road007` (avenue), `Road011A` (2-lane), `Road012A` (plain), `asphalt_02` (worn). Decals: `RoadLines019A` (atlas), `RoadLines020A` (crosswalk, desaturated to white), `ManholeCover009`, `AsphaltDamageSet001`, `TireTracks001` |
| Sidewalk / curb | `Tiles038` / `concrete_floor_worn_001` |
| Walls | `Plaster001` (tinted pastels), `beige_wall_001`, `red_brick`, `Bricks105`, `PaintedBricks004` (tinted), `concrete_brick_wall_001` (alleys), `Concrete034` / `Concrete008` |
| Towers | `Facade006` / `Facade001` by day; `Facade009` / `Facade013` lit at night, using their Emission maps as an emissive mask where Studio supports it |
| Roofs | `RoofingTiles006` (houses), `Gravel023` (flat roofs) |
| Port and industry | `corrugated_iron`, `container_side`, `CorrugatedSteel001`/`002` (tinted), `rusty_metal_02`, `DiamondPlate008C`, `PaintedMetal016` |
| Nature and beach | `Grass004`, `withered_grass` (hills), `Ground055S` (beach), `rock_face_03`, `weathered_brown_planks` (pier) |
| Plazas | `Terrazzo005`, `Marble012` |
| Fence | `Fence003` (alpha) |
| Car materials | `Metal049A` (chrome), `Rubber004` (tires) |
| Sky | `kloofendal_48d_partly_cloudy_puresky` (day), `kloppenheim_06_puresky` (golden), `qwantani_dusk_2_puresky` (blue hour), `kloppenheim_07_puresky` (night) |
| Vehicles | **Traffic and civilians:** comrade1280 passenger pack, DZ sedan/wagon/coupe/SUV/pickup/van. **Police:** DZ 80s police and haoliu95 CVPI. **Taxi:** haoliu95 Crown Vic taxi. **Ambulance, fire, bus, garbage, tow:** comrade1280 service pack. **Armored truck:** DZ F700. **Muscle:** DZ '71. **Super:** Goblin. **Moto:** Silas6. **Heli:** irs1182 |
| Weapons | USP, AK-47, AR-15, MP5, Mini Uzi, Remington 870, sawn-off, sniper, baseball bats (all Objaverse CC-BY); CC0 M4A1 and pistol as fallbacks |
| Props | Poly Haven `concrete_road_barrier`, `modular_chainlink_fence`, `modular_electricity_poles`, `fire_hydrant`, `metal_trash_can`, `utility_box_02`, `rollershutter_door`, `security_camera_01`, `trashbag`, `Barrel_01`; Objaverse dumpster and street light; Nobiax CC0 palms |

## 7. Reproduce or extend (container commands)

```bash
# Objaverse: metadata shard (160 total) and a GLB; anonymous over HTTPS
curl -L -o 000-024.json.gz https://huggingface.co/datasets/allenai/objaverse/resolve/main/metadata/000-024.json.gz
curl -L -o car.glb https://huggingface.co/datasets/allenai/objaverse/resolve/main/glbs/000-024/61766c1e6e1e4b2b803c174f33433a74.glb
# Poly Haven: per-map file URLs for any texture, HDRI or model
curl -s https://api.polyhaven.com/files/asphalt_02
# ambientCG: full catalogue (paged) and one 1k zip
curl -s "https://ambientcg.com/api/v2/full_json?type=Material&include=tagData,imageData&limit=1000&offset=0"
curl -L -o Road007.zip "https://ambientcg.com/get?file=Road007_1K-JPG.zip"
```

The scratchpad tools in `/tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/cc0/tools/` are:

| Tool | What it does |
|---|---|
| `glbinfo.py` | GLB/glTF stats and preview |
| `objinfo.py` | OBJ preview |
| `hdr.py` | RGBE decode and tonemap |
| `objv_filter.py`, `objv_q.py` | Objaverse search |
| `fetch.py` | texture download and verify |
| `build_manifest.py` | rebuilds `cc0_manifest.json` |

The downloaded sets themselves are under `scratchpad/cc0/dl/`:

| Path | Contents |
|---|---|
| `tex/` | 366 MB of textures |
| `objv_glb/` | 38 GLBs |
| `phm/` | 22 Poly Haven glTFs |
| `ogaf/` | OpenGameArt files |
| `hdri/` | 18 HDRs |

A `py7zr` venv is at `scratchpad/cc0/venv7z` for `.7z` archives.
