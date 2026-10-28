# Platform scout: more legally usable assets that raise the GTA bar (2026-10-27)

Binding context: `00_LEAD_DIRECTION.md` (grounded GTA V realism, guns with no gore, Moderate 13+). This note **adds** to `cc0_assets.md`, `gta_assets.md`, `gta_combat.md` §12, `sourcing/PICKS.md`, `evidence/scout_0003/0010_report.md` and `evidence/cars_0004_report.md`. Every ID below was checked against the IDs already in `docs/v2`, `src/shared/Config` and `assets/curation`. The two repeats are marked *(already in repo)*.

## How to read this

**Link shorthands**

| Prefix | Full link |
|---|---|
| `sf:<uid>` | `https://sketchfab.com/3d-models/<uid>` |
| `ph:<id>` | `https://polyhaven.com/a/<id>` |
| `acg:<id>` | `https://ambientcg.com/view?id=<id>` |
| `rbx:<id>` | `https://create.roblox.com/store/asset/<id>` (models, audio, plugins, fonts) |
| `cat:<id>` | `https://www.roblox.com/catalog/<id>` (emotes) |
| `bun:<id>` | `https://www.roblox.com/bundles/<id>` (animation packs) |
| `wally:<scope/name@ver>` | `https://wally.run/package/<scope>/<name>` |

**Verified** column: what was actually checked in this container.

| Code | Meaning |
|---|---|
| **DL+R** | File downloaded to scratch and rendered offline. GLBs went through `tools/glb_preview.py`. |
| **DL** | File downloaded and parsed. rbxm via Lune `rbxm_inspect.luau`; audio decoded with `ffprobe` (duration given); zip unpacked. |
| **URL** | API confirmed availability without a full download: Sketchfab issued a signed GLB link, Poly Haven or ambientCG answered HEAD 200, or a Sonniss zip directory was read by range request. |
| **T** | Thumbnail or preview viewed (contact sheets in `img_scout/`). |
| **meta** | Metadata only (name, creator, duration, votes). Audition before use. |

**Q** is a 1–5 realism and quality verdict against GTA V (5 = would not look out of place in GTA V at Roblox scale).

**Effort**:
- **S**: under 2 h, data-only (an ID in a Config table or a load by ID).
- **M**: half a day to a day (decimate, retexture or debadge, upload).
- **L**: two days or more (a new pipeline step or a lot of cleanup).

**Pipelines named in the "fit" column**

| Name | Steps |
|---|---|
| **props** | GLB → `tools/decimate_glb.py` / `optimize_kit.py` budgets → `tools/upload_hero.py <key> <glb> … --manifest assets/kit/props.json --role <role>` → `tools/gen_assets_config.py` → `Config/Assets.Props[role]` (`source="owned"`) → `AssetLibrary` |
| **store** | Add the ID to `Config/Assets` with `source="store"` (or to `STORE_EXTRAS` in `gen_assets_config.py`) → `AssetLibrary` → `AssetService:LoadAssetAsync`; scripts are stripped. Third-party IDs need "Allow Loading Third Party Assets". |
| **carpipe** | `python3 -I tools/blender/carpipe/build_car.py --in <glb> --name <id>` → CarBuilder v2 body, wheels and paint. CC-BY attribution goes in `assets/ATTRIBUTION.md`. |
| **buildkit / look** | Texture into `tools/blender/buildkit` (`fetch_assets.py`, `gen_textures.py`) or `assets/materials` → `tools/look/gen_project.py` → MaterialVariants in `default.project.json` and `Config/Look`. |
| **Sounds** | A key in `src/shared/Config/Sounds.luau`: the `radio(id, station, title)` helper for stations, `gun()` layers, `start`/`stop` PlaybackRegion. Licensed Roblox audio needs no upload. Sonniss audio must be uploaded as the owner's Audio. |
| **Animations** | `src/shared/Config/Animations.luau`. Only Roblox-owned or owner-published animation IDs play. |
| **VFX** | `tools/vfx` → `upload.py` → `gen_luau.py` → `Config/VFX.Textures` and presets. |
| **UI** | `Config/UIAssets`, Theme.Fonts and the minimap sprite sheets (`tools/minimap`, `tools/ui`). |

Contact sheets in `docs/v2/research/img_scout/`:
- `scout_sketchfab_picks.jpg` (49 Sketchfab picks)
- `scout_sketchfab_glb_renders.jpg` (12 GLBs rendered offline)
- `scout_polyhaven_props.jpg` (40)
- `scout_roblox_official_packs.jpg`
- `scout_creatorstore_picks.jpg` (21)
- `scout_ambientcg_textures.jpg` (32)
- `scout_vfx_unity_flipbooks.jpg`
- `scout_roblox_emotes.jpg` (27 + 5 packs)
- `scout_audio_waveforms.jpg`
- `scout_icons_gameicons_tabler.jpg`
- `scout_cc0_photos_openverse.jpg`

**Totals verified in this pass: about 330 candidates.**

| Source | Checked | Outcome |
|---|---|---|
| Sketchfab | 49 | License re-read and a GLB URL issued; 12 downloaded and rendered |
| Poly Haven | 40 | HEAD 200 on glTF 1k |
| ambientCG | 32 | HEAD 200 on the 1K zip |
| Roblox-owned or licensed assets, unauthenticated asset delivery v2 | 117 | Downloaded and decoded |
| Third-party Creator Store, Open Cloud delivery | 23 | 21 parsed |
| Emotes | 27 | Mapped to Roblox-owned animation IDs |
| Wally packages | 10 | Downloaded |
| Unity Labs flipbooks | 7 | Downloaded |
| Sonniss GDC 2019 | 8 parts, about 1,500 files | Listed; 3 files extracted |
| game-icons | 48 | Rendered |
| Openverse photos | 36 | Viewed |

---

## TOP 25 ADOPT NOW (ranked by impact on looking and feeling like GTA)

| # | What | Link(s) | Licence | What it improves | How it fits | Effort |
|---|---|---|---|---|---|---|
| 1 | **Roblox "Modern City" Modular Building Kit + Modern City Materials** | `rbx:13168370735` kit (11 prefab buildings A–K, 4 modular wall styles, fire escapes, AC units, awnings, balconies, window lights; 3,025 MeshParts, 2,165 SurfaceAppearances, 8 scripts) and `rbx:13168345645` (8 MaterialVariants) | Roblox-owned (user 1), free | Instant photoreal-PBR downtown blocks with fire escapes and lit windows. This is the density and realism the v1 screenshots lacked, with zero licence risk. | **store**: load per prefab (`PrefabBuildings/<A..K>`) into the A3 building slots as downtown filler between buildkit towers, and strip the 8 scripts. The materials go to **look**: the Roblox image IDs are listed in §2.3, so no upload is needed. Budget: use only 3–5 prefabs per streamed chunk. | M |
| 2 | **Per-class engine RPM loops from the Sonniss GDC 2019 bundle (Pole Position recordings)** | Part 4 `https://ftpmirror.your.org/pub/misc/sonniss2019/` (Challenger Hellcat 2015, Pontiac GTO 1967 with "steady RPMs" on-board takes, Lamborghini Huracan, Ferrari F40 LM, AMG GT R, RX-7, Jeep SRT8, Dodge A100 van, MAN Lion's Coach bus, Ford Probe, Polonez police car). Part 3: AMC Javelin, Aston DB9, Agusta A109 heli. Part 5: Yamaha RS Venture bike, Volvo FM10 truck. | Sonniss GDC licence (read from the bundle's `License.pdf`): royalty-free, commercial, no attribution, games allowed; do not resell the raw sounds | Closes the "no licensed per-class RPM loops" gap from `gta_assets` §5.1. Muscle, super, SUV, van, bus, truck, bike and heli each get their own engine. | **Sounds**: pull single WAVs by HTTP range (the scratch `zipget.py` approach; no 26 GB download) → `ffmpeg` trim and loop to OGG → upload as the owner's Audio (Open Cloud `assetType: Audio`; add to `tools/rbxcloud.upload`) → `Engine_<class>_{idle,low,mid,high}` keys crossfaded by RPM in `SoundController`. | L |
| 3 | **27 Roblox-owned emote animations for pedestrian life** | Emotes `cat:4940597758` Cower, `cat:3576823880` Point2, `cat:5230661597` Bored, `cat:5915779043` Applaud, `cat:3934984583` Get Out, `cat:3994129128` Fishing, `cat:3994130516` Bodybuilder and 20 more (§4.1). Inner Animation IDs, e.g. Cower = 4940563117. | The inner Animation assets are owned by **Roblox (user 1)**, checked in the economy API, so they play in any experience without buying the emote | Peds cower in robberies, point at crimes, get bored at bus stops, applaud, fish off the pier, lift weights on "Muscle Beach", and shopkeepers shoo you out. This is the GTA ambient-life layer. | **Animations**: add `ped_cower`, `ped_point` … with the inner IDs, then `Animator:LoadAnimation` from the C2 NPC state machine. No upload. | S |
| 4 | **Unity Labs photoreal VFX flipbooks** | `https://unity.com/blog/engine-platform/free-vfx-image-sequences-flipbooks` (28 sets, e.g. `…/assets01/Explosion02HD/Explosion02HD-flipbooks.zip`) | **CC0** | Replaces our procedural smoke and fire with real simulated explosions, fireballs, flames and smoke puffs: car explosions, molotovs, burning wrecks, tyre smoke. | **VFX**: repack 5×5, 16×4 and 8×8 sheets to Roblox `Grid4x4`/`Grid8x8` at ≤1024² (and straight alpha for the RGBA sets) in `tools/vfx` → `upload.py` → `Config/VFX.Textures` (`explosion_hd`, `fireball`, `flame`, `smoke_wispy`, `smoke_disc`). | M |
| 5 | **US siren suite completion (PSE)** | `rbx:9119165419` Siren Yelp 2 (23.7 s, verified 0.3 s sweep period), `rbx:9120491058` Warble Tone (36 s, 0.12 s period: phaser/priority), `rbx:9119162409` Siren Blat 2 (air-horn blip), `rbx:9119163896` Siren Start And Long Away (39 s), `rbx:9117773448` Police Radio 2 (116 s scanner bed) | Roblox-licensed partner audio (Pro Sound Effects), public | GTA cop cars cycle wail → yelp → phaser and blip the horn. Today we only have Wail 1/2. | **Sounds**: `SirenYelp`, `SirenPhaser`, `SirenBlat`, `SirenAway`, `PoliceScannerBed`, with the existing `rollOff` pattern. | S |
| 6 | **Wanted-level and heist score (APM)** | `rbx:1837463238` Heist Time, `rbx:1841825918` The Robbery (d), `rbx:9045939292` Code Heist, `rbx:9038506583` Diamond Heist (b) (gangster nu-jazz), `rbx:1847683499` Running Faster A, `rbx:1846876207` The Shootout (b), `rbx:1842577632` Police Chase (173 s), `rbx:1842305147` Police Car Chase | Roblox-licensed music (APM). On-platform use only (see Risks). | GTA-style dynamic mission and chase music: tension on bank entry, a driving cue at 3★ and above. | **Sounds**: `Music_Heist_*` and `Music_Chase_*`, faded by WantedService and HeistService state. | S–M |
| 7 | **Five new radio stations** | West Coast: `rbx:1836515424` West Coast Thing 1 (262 s), `rbx:1842771788` G Funkin, `rbx:1836142605` Woah, `rbx:1836142077` Feel Me Now. Latin: `rbx:9048582508` Cumbia Tribal A, `rbx:1837304783` Salsa en la Calle, `rbx:118459083995905` RITMO CRIMINAL (DistroKid reggaeton). Rock: `rbx:1836381174` Classic Rock 1. Synthwave: `rbx:140486290054589` Insert Coin, `rbx:121013346303842` Electronic Palm Shadows (DistroKid). Talk/news beds: `rbx:1836072687` Confident News Bed, `rbx:9046700616` Breaking News Theme. Night drive: `rbx:9044545570` Night Run. | Roblox-licensed (APM, DistroKid) | GTA's radio identity: LA hip-hop, East Los latin, classic rock, 80s synth and talk/news, next to the existing BASS DROP / CHILL / FUNKY / HEIST HOP / NEON stations. | **Sounds**: one `radio(id, "<STATION>", "<title>")` line each; SoundController already queues by station. | S |
| 8 | **Wet and puddle MaterialVariants from Roblox's own realism showcases** | `rbx:10841357434` Duvall Drive MVs (Concrete Wet, Flagstone/Gravel/Mud Puddle, Brushed Stainless, Wood Floor …) and `rbx:13168345645` Modern City MVs (CarPaint_A, Sidewalk_A, Plaster_A, PaintedBrick, four Concrete variants) | Roblox-owned | Rain-soaked concrete, puddled pavements and a proper metallic **car-paint** variant for the night-reflection look in the lead direction. | **look**: put the Roblox-owned map IDs (§2.3) straight into the `assets/materials` manifest → `gen_project.py` → `default.project.json`. No upload. The shared puddle roughness map `9781671574` can also be paired with our own asphalt colour. | S–M |
| 9 | **Wet asphalt, grime streaks and new US-usable road markings (ambientCG)** | `acg:Asphalt024C` (cracked wet), `acg:Asphalt025B` (clean wet), `acg:Asphalt033`, `acg:AsphaltDamageSet002`, `acg:Leaking012B/014B/016A/019A` (facade water streaks), `acg:RoadLines032B` (bike), `030B` (turn arrow), `034A` (car symbol), `022A`/`026C` (hatching), `019B` (marking atlas) | **CC0** | Night-wet streets and stained facades are the two biggest "not Roblox" texture cues. The markings fill bike-lane, arrow and hatch gaps. | **buildkit / look**: wet variants as `HC_AsphaltWet` MaterialVariants (swapped by weather). Leaking as building-trim decals in `gen_textures.py`. RoadLines as alpha masks tinted white or yellow in MapBuilder decals (they ship painted yellow). | M |
| 10 | **Rain** | `rbx:2166863728` buildthomas Rain module (occlusion under roofs, splashes on moving parts, mobile-tested). Audio: `rbx:9112858174` Rainstorm Heavy Downpour (61 s), `rbx:9118033647` Rain On Vehicle Roof Interior (67 s), `rbx:9120015808` Thunder And Rain, plus Sonniss "RAIN CITY" and "2496 Rain in the City" | Module: **Apache-2.0** (the source header says "licensed under the APLv2"). Audio: PSE (licensed) and Sonniss. | GTA weather: rain plus the wet MVs (#8 and #9) give the wet-night look; in-car rain on the roof is a classic GTA cue. | Vendor the module (copy from the rbxm via Lune) into `src/shared/Vendor/Rain` with the Apache notice. Weather state in LightingService; **Sounds** keys `Amb_Rain`, `Amb_RainInCar`. | M |
| 11 | **Suburb and mansion dressing (Roblox Duvall Drive)** | `rbx:10840661513` Landscaping (1,803 MeshParts: bushes, flower beds, ivy, planters, potted plants, porch fences, shed, fire pit), `rbx:10840642581` House Props, `rbx:10847897579` House Furniture | Roblox-owned | Realistic front yards and mansion interiors for the Vinewood-style hills. It also fills the **planters** gap. | **store** per subfolder. Strip scripts: Furniture has 101 (lights and toggles) and Landscaping has 4. Delete the `RobloxBillboard` models. | M |
| 12 | **US Type III barricades, crowd fence and water barrier** | `sf:32fd7c8c35854920b9557d1aa71af3fe` Construction Barricades (Type III "Road Closed", flagger sign, cone; 6.8k), `sf:2a09091d4e7b4539abe03f6a50762409` Fence Barricade 03 (steel bike-rack crowd barrier, 2.1k), `sf:44ca683ca25d46bb8a17584d1528101a` water-filled Barrier | CC-BY 4.0 (rollthebryce, rocz3d, mvrc.art) | Police roadblocks, crime-scene cordons and roadworks. Closes the BACKLOG #13 "build in-house: Type III barricades". | **props**: roles `police_barricade`, `road_barrier`, `construction_barrier` (replacing the current owned and store entries); attribution. | S–M |
| 13 | **Bank-heist set** | `sf:627c684249a848f99f84b6941caddc49` round armoured vault door (48.6k, decimate to about 10k), `ph:security_camera_01` and `_02` (rigged), `ph:metal_office_desk`, `ph:fire_alarm`. Audio: `rbx:9113085114` Alarm Bell On Hard Surface (27 s), `rbx:9113948784` Counting Money, `rbx:9113726156` Cash Counting | Vault: CC-BY (tasha.kosaykina). Poly Haven: CC0. Audio: PSE. | The bank heist is the viral pillar: a real vault door, CCTV and an alarm bell. | **props** (`bank_vault_door`, `cctv_cam`, `office_desk`); **Sounds** (`Heist_AlarmBell`, `Cash_Count`) | M |
| 14 | **Convenience-store robbery set** | `sf:4e4ccc3074f0474bbfa23611c46a4029` and `sf:4f22309bf38e4941a3ea2237ac886acb` Rendevr store shelves (retexture the real brands), `ph:CashRegister_01`, `ph:WetFloorSign_01`, `sf:0793898c1984478d9ed7dec22630c74e` ICE merchandiser (gap), `sf:a46268e7c6ad4950bf5b346ce3981568` ATM (gap). Audio: `rbx:9119643158` Store Entry Bell 3, `rbx:9113728625` Cash Register 1 | CC-BY, CC0 and PSE | GTA's 24/7 robbery loop: door chime, register, shelves, the ice box out front and an ATM. | buildkit `retail` interior + **props** roles (`store_shelf_*`, `cash_register`, `ice_box`, `atm`) + **Sounds**. Brand retexture in Blender before upload. | M |
| 15 | **Garage-interior set** (garage = bank, the core loop) | `ph:steel_frame_shelves_01` and `_03`, `ph:worn_metal_rack`, `ph:metal_tool_chest`, `ph:tool_cart`, `ph:bench_vice_01`, `ph:industrial_storage_cart`, `ph:caged_hanging_light`, `ph:mounted_fluorescent_lights`; `sf:03fbf71d72fd4ddc9e9ad555290564ea` red tool-wall workbench; `sf:4a669b8a8a1d4ea0b9ec41b97ad34353` metal shelving. Audio: `rbx:9117705808` impact wrench, `rbx:9114852843` hydraulic lift, `rbx:9119525650` aerosol hiss, `rbx:9119207863` sliding metal door | CC0, CC-BY and PSE | Closes the BACKLOG #13 workbench and garage-shelving gaps with photoreal pieces, and makes upgrade and respray moments sound right. | **props**: the `garage_shelf`, `tool_chest` and `workbench` roles already exist, so swap their IDs. **Sounds**: `Garage_*`. | M |
| 16 | **Street-furniture gap closers** | `sf:c5d23e21daef4fc2a62704149f5f9af6` green city litter basket, `sf:fe4057b211414cc5b84c16515608c1a9` and `sf:c0f5e3e1c8a64ab3b64d4b077bd09210` US double and single parking meters (scans), `sf:c509b70991704415beae507869cedeb4` traffic-signal controller cabinet (scan), `sf:8975781045254725850af6ef43dfeca5` newspaper boxes (decimate from 209k), `ph:exterior_aircon_unit`, `ph:modular_airduct_rectangular_01` (rooftops) | CC-BY and CC0 | Closes BACKLOG #12: city litter bin, US parking meter, utility cabinet. Adds rooftop clutter. | **props**: roles `trash_can`, `parking_meter`, `utility_cabinet`, `newspaper_box`, `roof_ac`. Fix the meter pivot (offset 4.6 m in the GLB). | M |
| 17 | **City ambience layers (PSE)** | `rbx:9113864890` and `rbx:9113864886` Commercial Aircraft (76 s / 53 s: planes overhead), `rbx:9119677305` Surf on Zuma Beach, `rbx:9118858002` Seagulls, `rbx:9112828518` Marina Ambience, `rbx:9112767169` Crowd Walla, `rbx:9114012460` Crowd Panic, `rbx:9119664988` Subway Train, `rbx:9112761348` Construction Presence, `rbx:9117072474` Neon buzz | Roblox-licensed (PSE) | A district-specific soundscape (beach, marina, downtown, construction), with panic walla when shots fire. | **Sounds**: `Amb_<zone>` keys, cross-faded by district and crime events. | S |
| 18 | **Vehicle-class gap fillers** | `sf:9828f80360c644d6981bd6c6cee3fb57` 2010 Lincoln Town Car (28k): luxury sedan, and a stretch base for a limo. `sf:27a6b95f768d415282e2f5de48ba6d99` US pumper Firetruck (26.5k; GLB 48 MB because of 4K textures). `rbx:3142595440` "Newer Madison Metro" US low-floor transit bus (95 MeshParts, 556 Parts, 59 scripts). | CC-BY (Velrifea, OzerGokmen); Creator Store free | `cars_0004` said no shippable free US city bus or luxury sedan existed; these fill both, plus a better fire truck. | **carpipe** for the two GLBs (debadge Lincoln; stretch in Blender for the limo). The bus goes **store** body-only (strip all scripts) with the Creator Store car-map loader. | M–L |
| 19 | **Theft and hotwire foley** | `rbx:9125657723` Mercedes 280SL Failed Starts (hotwire attempt), `rbx:9125346576` Chevy pickup rough start, `rbx:9125616884` keys handling, `rbx:9113018391` Charger gear shifter, `rbx:9119913393` Taillight Break, `rbx:9113631735` Bullet Glass 2, `rbx:9114403908` Ferrari 308 fast pass-bys | Roblox-licensed (PSE) | Makes "steal → escape" feel physical: cranking that fails, then catches. | **Sounds**: `Theft_Crank`, `Theft_Catch`, `Car_Shift`, `Car_TaillightBreak`. | S |
| 20 | **Police and news helicopter upgrade** | Audio: Sonniss Part 3 "Pole Position – Agusta A109" (turbine idle, take-off, fly-away) and "Black Hawk UH-60M". Model: `sf:90bf99ba20f948a9838623311bd83da3` Bell UH-1N Twin Huey (red and white rescue, 111k, decimate) | Sonniss; CC-BY (helijah) | The existing heli audio is Huey blade-chop, and `gta_assets` notes PSE has no turbine police heli. A109 is the right modern turbine sound. | **Sounds** (upload, as #2); **props** or store heli model (`police_helicopter` role exists). | M |
| 21 | **Airport kit** | `sf:259de41be0c7410e86b7e79be33d6b3a` Boeing 737 (28k, repaint), `sf:2747cad8b4c64122abe992c9ad1e8bd1` 737 MAX (13k), `sf:c9c7a5d09850485bbe198c793078c50f` "Miljet" fictional bizjet, `sf:7ae8444bb5044376a04ee7bb0664ff39` baggage cart; Sonniss Part 2 "Matt Script – Airplanes & Airports – Walla & Ambience" | CC-BY; Sonniss | The Airport is the final district gate in the lead direction. Parked jets and terminal walla sell it. | **props** (static planes are parked set dressing); **Sounds** `Amb_Airport`. Strip airline liveries. | M |
| 22 | **Port kit** | `sf:401069fccf814da7a4f9ce5a51487548` ship-to-shore crane (9.8k, low-poly; the GLB is about 1,200 units long, a decimetre-scale export, so normalise it), `sf:f237d79d2a934a7589b9d9f1bdc42638` photoreal container-stack scan, `sf:aaa41cca946b4a08bc08cf692b7757be` container ship (189k, decimate), `ph:hand_truck`, `ph:lifebuoy`; Sonniss Part 6 "Tone Glow – Inland Port" (container terminal, crane spreader, alarms) | CC-BY, CC0 and Sonniss | Lead direction: "a port with cranes and containers". Adds the STS gantry crane gap and the terminal soundscape. | **props** + **Sounds** `Amb_Port` | M |
| 23 | **Pedestrian walk-style variety** | `bun:48` Elder (Roblox), `bun:83` Stylish (Roblox), `bun:4294795` adidas aura (adidas) | Catalog avatar animations: NPCs can wear them through HumanoidDescription without owning them (same rule `gta_assets` §3.2 uses) | Old people shuffle, fashionable walkers in the business district. Breaks the "everyone walks the same" tell. | `NPCOutfits` / HumanoidDescription `WalkAnimation` etc. (asset IDs in §4.2). | S |
| 24 | **Minimap blips and HUD/phone icons** | game-icons.net (4,180 SVGs: police-car, helicopter, pistol-gun, uzi, ak47, money-stack, car-key, bank, handcuffs, spray, shop, wanted-reward …; archive `https://game-icons.net/archives/ffffff/transparent/game-icons.net.svg.zip`); Tabler Icons (`npm @tabler/icons@3.50.0`) | game-icons: **CC BY 3.0** (credit the authors: delapouite, lorc, skoll, sbed …). Tabler: **MIT**. | A ready, consistent silhouette set for the ~40-cell blip sheet in `gta_ui_language` §6, so we are not drawing from zero. | **UI**: render SVG → 32 px white cells (headless Chromium works here) → blip sheet in `tools/minimap` → `Config/UIAssets`. Credits entry. | S–M |
| 25 | **In-world signage fonts** | `rbx:12187372847` **Barlow** (Roblox-owned; designed from California highway signs, plates and transit), `rbx:12187376357` Sedgwick Ave Display (graffiti), `rbx:12187374098` Monoton (neon tube lettering) | Roblox-owned font families (OFL originals) | Street-name blades, freeway guide signs (BACKLOG #11 "build in-house") and gang tags and neon storefronts in `CityArt` read as LA instead of Roblox defaults. | `Config/CityArt` SurfaceGui text via `Font.fromId(...)` (preload like the HUD store fonts). | S |

Just outside the top 25:
- The **code shortlist** (§7): Streamable, Shake/Spring, `t`, Cmdr, PartCache, SimplePath.
- **CMU mocap or Mixamo**, for the hands-up and phone clips that no Roblox emote covers (§4.3).
- **Container and boat dressing** (§1.2).

---

## 1. 3D: props, vehicles, interiors, airport and port

### 1.1 Roblox-owned packs (zero licence risk; load by ID)

| Item | Source | Licence | Verified | Q | Fills / improves | Fit | Effort |
|---|---|---|---|---|---|---|---|
| Modular Building Kit – Modern City | `rbx:13168370735` | Roblox-owned | DL (3.36 MB rbxm: 3,025 MeshPart, 2,165 SurfaceAppearance, 19 SpotLight, 8 Script), T | 4 | Downtown and midtown blocks, fire escapes, AC, awnings, window lights | store, per prefab | M |
| Modern City Materials Pack | `rbx:13168345645` | Roblox-owned | DL (8 MaterialVariants, map IDs in §2.3) | 4 | Car paint, sidewalk, plaster, painted brick, concrete | look | S |
| Realistic Material Variants – Duvall Drive | `rbx:10841357434` | Roblox-owned | DL (17 MVs) | 5 | Wet concrete, puddles, flagstone, granite, wood floors | look | S |
| Landscaping Pack – Duvall Drive | `rbx:10840661513` | Roblox-owned | DL (1,803 MeshPart, 1,541 SA, 4 Script), T | 5 | Suburb and mansion yards; planters (BACKLOG gap) | store | M |
| House Props Pack – Duvall Drive | `rbx:10840642581` | Roblox-owned | DL (514 MeshPart, 299 SA), T | 4 | Mansion and house interiors (kitchen, books, art) | store | M |
| House Furniture Pack – Duvall Drive | `rbx:10847897579` | Roblox-owned | DL (833 MeshPart, 518 SA, **101 scripts**), T | 4 | Safehouse and mansion furniture and lights | store (strip scripts) | M |
| City Props / Road / Building Pack (2021) | `rbx:6370681139`, `rbx:6432233485`, `rbx:6418277837` | Roblox-owned | T, meta | 3 | Low-poly 2021 kit, transmission tower. Filler only. | store | S |
| Synty City Pack (Roblox upload) | `rbx:6933556508` | Roblox-owned | T, meta | 2 | **Reject**: stylized, on the kill list | — | — |
| Light Utility Vehicle | `rbx:6418221666` | Roblox-owned | T, meta | 3 | Endorsed jeep (16 scripts) | — | — |

### 1.2 Sketchfab (CC-BY 4.0 unless noted)

All 49 were re-checked through `api.sketchfab.com/v3/models/{uid}` (licence `by`) and `/download`, which issued a signed GLB URL. Add each one that ships to `assets/ATTRIBUTION.md`.

| Item (author) | Link | Faces / GLB | Verified | Q | Fills / improves | Fit | Effort |
|---|---|---|---|---|---|---|---|
| Construction Barricades (rollthebryce) | `sf:32fd7c8c35854920b9557d1aa71af3fe` | 6.8k / 16.9 MB | DL+R | 5 | **Type III barricade**, flagger sign, cone | props | S |
| Fence Barricade 03 (rocz3d) | `sf:2a09091d4e7b4539abe03f6a50762409` | 2.1k / 1.2 MB | DL+R | 4 | Police crowd cordon | props | S |
| Barrier, water-filled (mvrc.art) | `sf:44ca683ca25d46bb8a17584d1528101a` | 2.0k | URL, T | 4 | Roadworks lane closure | props | S |
| Parking Meter Scan, double (evan4129) | `sf:fe4057b211414cc5b84c16515608c1a9` | 2.7k | DL+R | 5 | **US parking meter** (fix pivot: GLB offset 4.6 m) | props | S |
| Parking Meter Scan, single (evan4129) | `sf:c0f5e3e1c8a64ab3b64d4b077bd09210` | 3.5k | URL, T | 5 | US parking meter | props | S |
| Parking Meter (ArcherSterling) | `sf:a1932b57521c4aa1b0148d1e6ad6b7aa` | 34.9k | URL, T | 4 | Alternative (heavy) | props | S |
| ATM Machine (local.yany) | `sf:a46268e7c6ad4950bf5b346ce3981568` | 2.5k / 0.3 MB | DL+R | 4 | **ATM** | props | S |
| ATM Machine (oscarherry3d) | `sf:22ca75eb5e0d4ee0a02c5b5100a55006` | 4.7k / 12.3 MB | URL, T | 4 | ATM (dirtier) | props | S |
| ATM Machine Model (Murk) | `sf:efd5d7593cf44a51b5af435f8e77caa2` | 0.5k | URL, T | 3 | ATM wall unit; strip card logos | props | S |
| Ice machine, low poly (derfmode) | `sf:0793898c1984478d9ed7dec22630c74e` | 0.4k | DL+R | 4 | **Gas-station ICE merchandiser** | props | S |
| Water Tower (Chamodp) | `sf:500cfe0cf4a74350bb49c5736b692339` | 1.7k | DL+R | 4 | **Rooftop water tank** (NYC style) | props | S |
| Wooden Water Tower (BytesCrafter) | `sf:ce4de11b50164c3abf65de2d6c51b872` | 1.0k | URL, T | 3 | Alternative | props | S |
| Rooftop Architectural Elements (mauther) | `sf:64126417cac04b4e9450a5cd7dc45f9b` | 1.0k | URL, T | 3 | Rooftop tank, bulkhead (papercraft look) | props | S |
| Workbench, red tool wall (need4speed) | `sf:03fbf71d72fd4ddc9e9ad555290564ea` | 3.1k / 0.5 MB | URL, T | 4 | **Workbench** | props | S |
| Garage Desk (fdgasd7) | `sf:c260327b93114d56933bdd9e3b0454b7` | 50.7k / 27 MB | URL, T | 4 | Hero workbench with pegboard (decimate) | props | M |
| Metal Storage Cabinet (jimbogies) | `sf:4d49691a269745cabe0e1d5c1c3bef9b` | 9.0k | URL, T | 4 | **Garage shelving** | props | S |
| Rusty Metal Shelving (jimbogies) | `sf:f1f8aa79e3ea4d93b5f05eeaf95bf6aa` | 16.3k | URL, T | 4 | Garage and warehouse shelving | props | S |
| Metal Shelving Unit (jimbogies) | `sf:4a669b8a8a1d4ea0b9ec41b97ad34353` | 9.0k | URL, T | 4 | Garage shelving | props | S |
| Green City Trash Can (Raffey) | `sf:c5d23e21daef4fc2a62704149f5f9af6` | 5.1k | DL+R | 5 | **City litter bin** | props | S |
| Trash Can ×4 wheelie bins (longtail) | `sf:f61aeec14ff441abb0f6add5485a2e90` | 3.9k | URL, T | 4 | Suburb curbside bins | props | S |
| Trash can with bags (LiliumLetifer) | `sf:e63f57d1f72140e4b37c25880677449d` | 7.9k | URL, T | 4 | Alley clutter | props | S |
| Newspaper boxes (keithito) | `sf:8975781045254725850af6ef43dfeca5` | 209k / 6.5 MB | URL, T | 4 | Photoreal newspaper boxes (decimate about 20×) | props | M |
| Rusty Old Newspaper Vending (chrisg4919) | `sf:29cca5a8e99e438c8fb644d1aea3587e` | 0.9k | URL, T | 3 | Cheap alternative | props | S |
| Traffic Signal Control Cabinet scan (Guay0) | `sf:c509b70991704415beae507869cedeb4` | 5.8k | DL+R | 5 | **Utility or signal cabinet** | props | S |
| Brick Planter box (mizorri93) | `sf:2b9819444f98491d932cc07022a26f8d` | 36 tris | URL, T | 3 | Planter (weak; prefer Duvall) | props | S |
| Ship To Shore Crane (JakeBradley) | `sf:401069fccf814da7a4f9ce5a51487548` | 9.8k / 0.7 MB | DL+R | 3 | **Port gantry crane** (GLB about 1,200 units long; normalise; low-poly) | props | M |
| Port crane "Sokol" (Domender) | `sf:4964eaa7634e47c9bac4c2a74fa91c20` | 14.4k | URL, T | 3 | Luffing harbour crane | props | M |
| Container Ship (RM02) | `sf:aaa41cca946b4a08bc08cf692b7757be` | 189k / 21 MB | URL, T | 4 | Docked ship backdrop (decimate) | props | M |
| Container scan No. 8 (Dystopia) | `sf:f237d79d2a934a7589b9d9f1bdc42638` | 109k / 10 MB | URL, T | 4 | Photoreal container stack | props | M |
| Firetruck (OzerGokmen) | `sf:27a6b95f768d415282e2f5de48ba6d99` | 26.5k / 48.5 MB | URL, T | 4 | **US fire truck** (`cars_0004` fire class) | carpipe | M |
| [FREE] 2010 Lincoln Town Car (Velrifea) | `sf:9828f80360c644d6981bd6c6cee3fb57` | 28.3k / 1.4 MB | DL+R | 4 | **Luxury sedan**; **limo** stretch base (debadge) | carpipe | M |
| Bank vault, armored door (tasha.kosaykina) | `sf:627c684249a848f99f84b6941caddc49` | 48.6k / 5.7 MB | DL+R | 5 | **Bank vault** hero door | props | M |
| Bank Vault Door (commonspence) | `sf:66ed0c4af0284ed09363a4c35ee7ba3d` | 26.6k | URL, T | 4 | Alternative vault | props | M |
| Vault door (ArtOfOrlando) | `sf:b7f9cf66195546668d74c2d9d5cfb2b4` | 3.2k | URL, T | 4 | Low-poly vault (wall-mounted) | props | S |
| Supermarket Drinks Shelf (Rendevr) | `sf:4f22309bf38e4941a3ea2237ac886acb` | 106k | URL, T | 4 | **Store shelves** (real brands: retexture) | props | M |
| Supermarket Potato Chips Shelf (Rendevr) | `sf:4e4ccc3074f0474bbfa23611c46a4029` | 41k | URL, T | 4 | Store shelves (brands) | props | M |
| Boeing737 (manilov.ap) | `sf:259de41be0c7410e86b7e79be33d6b3a` | 28.5k | URL, T | 4 | Airport apron airliner (strip Lufthansa livery) | props | M |
| 737 MAX (sofyankurniawan) | `sf:2747cad8b4c64122abe992c9ad1e8bd1` | 13.3k | URL, T | 4 | Airliner (strip Lion Air livery) | props | M |
| Miljet (dannzjs) | `sf:c9c7a5d09850485bbe198c793078c50f` | 34.1k | URL, T | 4 | Fictional private jet (no brand) | props | S |
| Embraer Phenom 300 with interior (mixmamo.studio) | `sf:ece5ca34e7074113b9ab7c33734e2d5d` | 79k | URL, T | 4 | Bizjet with cabin (heavy) | props | M |
| private jet with inside (a2e) | `sf:9dd87793b8f2435bbe0cdc6fca5d69da` | 5.7k | URL, T | 3 | Cheap jet | props | S |
| Airport baggage cart (menX1151) | `sf:7ae8444bb5044376a04ee7bb0664ff39` | 2.0k | DL+R | 4 | Apron dressing | props | S |
| Bell UH-1N Twin Huey (helijah) | `sf:90bf99ba20f948a9838623311bd83da3` | 111k | URL, T | 4 | Rescue or news heli (decimate) | props / store | M |
| Bell Huey (duanesmind) | `sf:755d8518a06e41b19752c1b54c0da588` | 2.0k | URL, T | 3 | Background heli | props | S |
| Speedboat (vrpspu) | `sf:9916bd4433024202ab84e43426fc2139` | 86.6k / 21 MB | URL, T | 4 | Marina speedboat | props | M |
| Riva Aquarama (AntonKovalev) | `sf:9d5716a2ab6645b9a1452f1d6b0372ef` | 4.5k | URL, T | 4 | Classic runabout (rename; real brand) | props | S |
| UNDERPOLY Free Jet-Ski + Trailer | `sf:c9e324b0a9284904b4a442080fc2a6ef` | 29k | URL, T | 4 | Beach jet-skis | props | S |
| Kawasaki 310X Jet Ski (XOIAL) | `sf:37a2348f02da472d98310fd5621307c6` | 8.2k | URL, T | 4 | Jet-ski (debadge) | props | S |
| Simple Wooden Pier (jungle_jim) | `sf:5bf117cb734a46559d10971c3098165c` | 6.3k | URL, T | 3 | Small dock. The boardwalk pier stays in-house. | props | S |

### 1.3 Poly Haven (CC0): 40 checked, all glTF 1k HEAD 200, T (`scout_polyhaven_props.jpg`)

None of these were in the earlier docs. Q is 5 for all: photoreal scans. Most are 3–30k tris, so decimate to the props budget.

| Group | IDs (`ph:<id>`) | Fills / improves | Fit | Effort |
|---|---|---|---|---|
| Garage shelving and workbench (BACKLOG #13) | `steel_frame_shelves_01` (4.3k), `steel_frame_shelves_03` (8.4k), `worn_metal_rack` (6.4k), `metal_tool_chest` (14.6k), `tool_cart` (29k), `bench_vice_01` (2.9k), `industrial_storage_cart` (19k), `overhead_crane` (90k, decimate) | Garage interiors | props (`garage_shelf`, `tool_chest`, `workbench`) | M |
| Garage and industrial lighting | `caged_hanging_light`, `mounted_fluorescent_lights`, `hanging_industrial_lamp`, `security_light` | Practical lights for garages, alleys and loading docks | props + PointLight | S |
| Planters (BACKLOG gap) | `planter_box_01` (8.1k), `planter_box_03` (13k) | Wooden planters for storefronts and decks | props | S |
| Store and bank interiors | `CashRegister_01`, `WetFloorSign_01` (228 tris), `security_camera_01`, `security_camera_02` (rigged), `fire_alarm`, `metal_office_desk`, `korean_fire_extinguisher_01` (Korean label: retexture) | Robbery and heist sets | props | S–M |
| Rooftops and facades | `exterior_aircon_unit`, `modular_airduct_rectangular_01`, `modular_pipes`, `modular_electric_cables`, `modular_metal_gutter` | Rooftop and alley clutter for buildkit | buildkit (bake into the `deco` set) or props | M |
| Gas station and port | `propane_tank`, `small_lpg_tank`, `portable_generator`, `hand_truck`, `lifebuoy`, `modular_wooden_pier` (85k; old-wood style) | Propane cage, dock dressing | props | S–M |
| Heist tools and props | `crowbar_01`, `bolt_cutters_01`, `sledgehammer_01`, `spray_paint_bottles_02`, `Megaphone_01` (police), `boombox`, `large_iron_gate` (mansion gate), `concrete_road_barrier_02` | Heist and robbery handhelds, police megaphone, mansion gates | props / weapon models | S–M |

### 1.4 Creator Store, third-party (load by ID with **store**; scripts stripped)

Downloaded with the Open Cloud key (`asset-delivery-api`) and parsed with Lune. Thumbnails are in `scout_creatorstore_picks.jpg`.

| Item | ID | Contents | Verified | Q | Fills | Effort |
|---|---|---|---|---|---|---|
| Road Closed Barricade (keven_cito) | `rbx:8686872395` | 4 MeshPart, 24 Texture, 0 scripts (16k tris; rusty, with sandbags) | DL, T | 4 | Type III barricade (alternative) | S |
| Road Closed Barricade (vVixV3, 2010) | `rbx:36240728` | 8 Parts + decals | DL, T | 3 | Clean Type III | S |
| Iowa Road Closed Barricade | `rbx:152769712` | 8 Parts + decals | DL, T | 3 | Type III | S |
| "Newer Madison Metro" transit bus (inthasack) | `rbx:3142595440` | 95 MeshPart, 556 Part, **59 scripts** | DL, T | 4 | **US city bus** (gap in `cars_0004`) | M |
| New York City bus (kennybest1234) | `rbx:9838306707` | 345k tris, 84 scripts, "I ❤ NY" MTA livery | DL, T | 4 | Bus (heavy; repaint the trademark) | M |
| limousine (JeffersonP) | `rbx:4893597123` | 67 MeshPart, 35 scripts | DL, T | 4 | Stretch limo | M |
| Lincoln Town Car limo-lowrider | `rbx:4232019061` *(already in repo, `cars_0004`)* | 75 MeshPart | DL | 5 | Limo | — |
| fire engine, ladder (iL_ACC) | `rbx:3453243574` | 352 Unions, 66 scripts, 172k | DL, T | 3 | Ladder truck (heavy) | M |
| parking meters (morinanks) | `rbx:983242136` | 4 MeshPart + 78 Parts | DL, T | 4 | US double meter | S |
| Parking Meter (TwistedEllxs) | `rbx:5589555462` | 1 Union | DL, T | 3 | Single meter | S |
| Ice machine "ICE!" (AvApiizz) | `rbx:187762397` | 11 Parts + 6 decals | DL, T | 3 | Ice merchandiser (part-built) | S |
| display case (Aid_Dough) | `rbx:9009062399` | 11 Parts | DL, T | 3 | **Jewelry case** shell (glass + wood) | S |
| ATM Machine (dangerous11190) | `rbx:18370416157` | 3 MeshPart + 52 Parts | DL, T | 3 | ATM (untextured) | S |

**New avoid list** (2026-10 spam wave):
- Account "Content Deleted – 158552482" uploaded dozens of keyword-stuffed copies with 2–8 scripts each: barricades `73455052353621`, `70946617385091`, `116751080294006`, `71736641387219`, `126975059330776`; fire `100468005342635`, `74280540964046`; rain `95976768292935`, `124764577770908`; ragdoll `86912806517743` (7 scripts); oceans `103467034377379`, `112000896549179`. This is the same backdoor pattern `scout_0010` flagged.
- Also avoid the "AUS siren" uploads (`505001544`, `652597333`): their descriptions credit GTA 5 mods.

---

## 2. Textures, decals and images

### 2.1 ambientCG (CC0)

All 32 checked had HEAD 200 on the 1K-JPG zip; thumbnails are in `scout_ambientcg_textures.jpg`. These IDs are **not** in `cc0_assets.md`.

| Items (`acg:<id>`) | Q | Fills / improves | Fit | Effort |
|---|---|---|---|---|
| `Asphalt024C` (cracked **wet**), `Asphalt025B` (clean **wet**) | 5 | Wet-street weather variants. Lead direction: "wet-street reflections at night". | look: `HC_AsphaltWet*` MV, swapped by weather | S |
| `Asphalt033` (2026, charcoal granular), `Asphalt026B` (cracked, damaged) | 5 | Fresher arterial asphalt and a worn side-street | look | S |
| `AsphaltDamageSet002` (scuff atlas) | 5 | Tyre scuffs and patch decals on top of the existing pothole atlas | MapBuilder decals | S |
| `Leaking012B`, `Leaking014B`, `Leaking016A`, `Leaking019A` | 5 | Water and rust streaks under windows and AC units. This is the "grime" the realism gap calls for. | buildkit `gen_textures.py` grime layer, or Decals | M |
| `RoadLines032B` (bike), `RoadLines030B` (turn arrow), `RoadLines034A` (car symbol), `RoadLines022A`/`026C` (hatching, edge), `RoadLines028C` (dashed), `RoadLines019B` (atlas) | 4 | Markings missing from `road_markings_decal`. They ship yellow, so use the alpha and tint white or yellow per MUTCD. | MapBuilder decals | S |
| `ManholeCover011` (square, US utility), `ManholeCover010` | 4 | More cover variety | decals | S |
| `Metal021`, `Metal024` (rust leaks on steel) | 5 | Dumpsters, containers, industrial | look | S |
| `PavingStones115B` (wet puddles), `Ground050` (mud puddle), `Ground059` (wet beach sand) | 4 | Puddle and wet variants | look / terrain | S |
| `Facade018B`, `Facade020A` (skyscraper grids) | 4 | Distant skyline facades | buildkit tower LOD | S |
| `Bricks104`, `Bricks101` (modern red), `Concrete047B` (drainage slab), `CorrugatedSteel009` | 5 | Newer, sharper wall materials | look / buildkit | S |
| `Leather009` (tufted black), `Carpet004`, `Fabric029` (dirty carpet) | 4 | Car interiors, casino and bank lobby, safehouse | carpipe interior atlas / look | S |

### 2.2 Photos for billboards, posters and loading-art plates

GTA uses **painted** key art, so photos are plates and references to paint over, not finished art.

| Item | Source | Licence | Verified | Q | Use |
|---|---|---|---|---|---|
| Palm silhouettes at sunset (4 images, 1920–7360 px) | Openverse → rawpixel (`images.rawpixel.com/editor_1024/…`, 1024 px downloadable) | CC0 (rawpixel public-domain set) | T, URL | 4 | Loading-screen sky plates, billboard backgrounds |
| Desert highway set (6 images, up to 8192 px) | Openverse → StockSnap (e.g. "Desert Road" 6720×4237; `stocksnap.io/photo/…`) | CC0 (StockSnap) | T | 4 | Countryside-loop loading art |
| Night skyline / light trails (4) | Openverse → rawpixel + StockSnap "Cityscape Skyline" | CC0 | T | 4 | Night loading art plate |
| Neon / parking-garage night (2) | StockSnap "Parkinggarage Entry", rawpixel "cafe neon sign" | CC0 | T | 3 | Mood references for neon signage |
| Unsplash / Pexels / Pixabay (search by hand) | unsplash.com/license, pixabay.com/service/license-summary | Free commercial use, no attribution; no selling unaltered copies; Pixabay bans commercial use of recognisable brands; no model or property releases | Licence pages read (WebFetch) | — | Plates only; avoid people and logos |

The Wikimedia-sourced Openverse hits (e.g. CC0 aerials of the 110/105 freeway interchange) are a good fit, but `commons.wikimedia.org` answered **429** here, so they could not be downloaded.

### 2.3 Roblox-owned MaterialVariant maps (copy the IDs, no upload)

Extracted from `rbx:10841357434` and `rbx:13168345645` with a Lune dump. These images are Roblox-owned, so `default.project.json` can reference them directly.

| MV (base) | Color | Normal | Roughness | Metalness | StudsPerTile |
|---|---|---|---|---|---|
| Concrete Wet MV (Concrete) | 8785389518 | 8785388974 | 10696235306 | 8785389135 | 10 |
| Flagstone / Gravel / Mud **Puddle** MV | 9809148719 / 9812112815 / 9725395505 | none | **9781671574** (shared puddle mask) | 9781989836 | 8 / 6 / 8 |
| CarPaint_A (Metal) | 10961354729 | 12404989068 | 12404995267 | 12434205681 | 2 |
| Sidewalk_A (Concrete) | 11163338992 | 11163318474 | 11163318234 | none | 22.5 |
| Plaster_A (Concrete) | 10960894634 | 10960879839 | 10960879369 | none | 10 |
| PaintedBrick (Brick) | 11306286615 | 10967950030 | 10967950866 | none | 5 |

There are 17 more in the same two packs: Brushed Stainless, Granite, Fabric, Mulch, Pebbles, Wallpaper, 3 wood floors and 4 concrete types.

---

## 3. Audio

**Rules.**
- PSE (Pro Sound Effects, user 7462895450), APM (user 7462718749), DistroKid (user 7135127272) and the Roblox UI SFX are **Roblox-licensed public audio**. Use them by ID with no upload.
- Licensed music is **on-platform only**. The DevForum quotes the Terms: no export or download, no "streaming service or music library" inside an experience, and up to 250 distinct tracks per experience. **Do not put licensed tracks in YouTube or TikTok marketing captures.** Curated stations are fine; a free-pick jukebox is not. (The `en.help.roblox.com` page answered 403 here, so confirm against the live Terms.)
- Every ID below was **downloaded** through the unauthenticated `assetdelivery.roblox.com/v2` and decoded (duration from `ffprobe`) unless marked meta. Waveforms are in `scout_audio_waveforms.jpg`.

### 3.1 Music: mission score and radio (APM / DistroKid)

| Use | IDs (duration) | Q | Fit |
|---|---|---|---|
| Heist cues | 1837463238 Heist Time (163 s), 1841825918 The Robbery (d) (139 s), 9045939292 Code Heist (108 s), 9038506583 Diamond Heist (b) (130 s) | 4 | `Music_Heist_*` |
| Chase and wanted cues | 1847683499 Running Faster A (139 s), 1846876207 The Shootout (b) (80 s), 1842577632 Police Chase (173 s), 1842305147 Police Car Chase (138 s) | 4 | `Music_Chase_*` by stars |
| Radio "WEST COAST" (new) | 1836515424 West Coast Thing 1 (262 s), 1842771788 G Funkin (157 s), 1836142605 Woah (194 s), 1836142077 Feel Me Now (267 s) | 4 | `radio()` |
| Radio "EAST LOS / LATINO" (new) | 9048582508 Cumbia Tribal A (156 s), 1837304783 Salsa en la Calle (139 s), 118459083995905 RITMO CRIMINAL (DistroKid, 147 s) | 4 | `radio()` |
| Radio "ROCK" (new) | 1836381174 Classic Rock 1 (200 s); meta: 1842945769 Hell In A Hand Basket, 1838415858 Nite Owl | 3 | `radio()` |
| Radio "SYNTH 80s" (extends NEON FM) | 140486290054589 Insert Coin (199 s), 121013346303842 Electronic Palm Shadows (164 s) | 4 | `radio()` |
| Talk and news beds | 1836072687 Confident News Bed (124 s), 9046700616 Breaking News Theme (117 s) | 3 | News-break stingers, phone hold music |
| Night drive | 9044545570 Night Run (DnB, "suggested for driving", 183 s) | 4 | `radio()` |

Talk radio needs **voice content**. Nothing licensed exists, so record our own parody DJ and ad reads with our own voice talent.

### 3.2 SFX: new PSE picks (not in `gta_assets` §5 or `gta_combat` §12.4)

| Role | IDs (duration) | Q | Fit key |
|---|---|---|---|
| Siren yelp | 9119165419 Siren Yelp 2 (23.7 s; 0.3 s sweep measured) | 5 | `SirenYelp` |
| Siren phaser/priority | 9120491058 Warble Tone HF Switching 1 (36 s; 0.12 s period, 1.3–2.3 kHz) | 4 | `SirenPhaser` |
| Horn blat and whoops | 9119162409 Siren Blat 2 (1.3 s); 9119164699, 9119164838, 9119164823, 9119164820 Siren Variety 12–15 (1–3.5 s) | 4 | `SirenBlat`, `SirenWhoop*` |
| Siren receding | 9119163896 Siren Start And Long Away (39 s); 9112737486 Accident Scene 1 (36 s) | 4 | `SirenAway`, `Amb_Accident` |
| Hotwire and theft | 9125657723 Mercedes 280SL Failed Starts (3.6 s); 9125346576 Chevy Pickup Rough Start (3.9 s); 9125616884 Keys Handling (0.5 s); 9113018391 Charger Gear Shifter (1.9 s) | 5 | `Theft_*`, `Car_Shift` |
| Tyres and pass-bys | 9126159066 Skidding Maneuvers (30.7 s); 9119186021 Skids on Pavement (37 s); 9114403908 Ferrari 308 Pass Bys Fast (27 s); 9114818075 Honda CBR600 (13 s); 9114239231 Electric Car Pass By (5.7 s) | 4 | `Car_*` |
| Damage | 9119913393 Taillight Break 2 (2.7 s); 9113631735 Bullet Glass 2 (0.7 s) | 4 | `Car_TaillightBreak`, `Impact_Glass` |
| Planes overhead | 9113864890 Commercial Aircraft 1 (76 s), 9113864886 Commercial Aircraft 2 (53 s) | 5 | `Amb_Plane` |
| Beach, marina, port | 9119677305 Surf, Zuma Beach 4 (40 s); 9118858002 Seagulls 1 (36 s); 9112828518 Marina Ambience 4 (88 s); 9114406660 Ferry Boat Horn (14 s); 9112798882 Jet Skis Surges (56 s) | 5 | `Amb_Beach`, `Amb_Marina` |
| Crowd | 9112767169 Crowd Walla 1 (36 s); 9114012460 Crowd Panic 1 (26 s) | 4 | `Amb_Crowd`, `Crowd_Panic` |
| City layers | 9119664988 Subway Train 1 (36 s); 9112761348 Construction Presence (36 s); 9117072474 Neon Zaps Buzz (5 s) | 4 | `Amb_*` |
| Weather | 9112858174 Rainstorm Heavy Downpour (61 s); 9118033647 Rain On Vehicle Roof Interior (67 s); 9120015808 Thunder And Rain (13 s) | 5 | `Amb_Rain*` |
| Police radio beds | 9117773448 Police Radio 2 (116 s); 9125774208 Line Feed Voices Static (41 s) | 4 | `PoliceScannerBed` |
| Robbery and heist | 9119643158 Store Entry Bell 3 (3.8 s); 9125491062 Door Bell Two-Tone (23.5 s); 9113728625 Cash Register 1 (1.1 s); 9113948784 Counting Money 3 (3.9 s); 9113726156 Cash Counting (4 s); 9113085114 Alarm Bell Hard Surface (27 s); 9125557781 Fire Alarm Buzzer (13 s); 9114764161 Handcuff Movement 14 (6.2 s) | 5 | `Store_*`, `Heist_*`, `Busted_Cuffs` |
| Guns (extra) | 9119299387 S&W .38 Revolver 2 (2.6 s, phase-2 revolver); meta: 9114701324 Gunfire Machine Gun 1 (25 s), 9118168943 Ricochet Metal 4 | 4 | `gun()` |
| Garage and spray | 9117705808 Pneumatic Impact Wrench (6.7 s); 9114852843 Hydraulic Pallet Lift (5.5 s); 9119522706 Spray Paint 2 (2.6 s); 9119525650 Aerosol Hiss Constant (14 s); 9119207863 Sliding Metal Door (8.4 s) | 5 | `Garage_*`, `Spray_*` |
| Phone | 9117305259 Phone Ring Electronic (5.8 s) | 4 | `Phone_Ring` |
| Meta only (audition) | 9125389955 AH-1 Cobra approach (45 s); 9114370190 Dog Barking (52 s); 9113475819 Body Fall Master 28; 9112780193 Fireplace Burning (car-fire loop); 9113342511 Basketball Playing (50 s); 9120557629 Water Fountain; 9125390321 Bicycle Bell; 9113678359 Camera Shutter | 3–4 | — |

Roblox UI SFX (Roblox-owned, downloaded):
- 10066968815 RBLX UI Select 02, 10128760939 Select 01, 10066914500 Back, 15675059323 Bright Click, 15675012262 Whoosh 04.
- Meta only: 10066947742 Purchase, 15675046931 Sweep, 15675085146 Indicator.
- 15675032796 Small Click is *(already in repo)* as `Click`.

Neutral clicks suit the GTA menu.

**Audioscape** (group 34159607) holds only 76 files. The families not already in `gta_combat` are AS_gun_shot (pistol), AS_silenced_pistol_shot/foley and WINCHESTER_SHOT. They need authentication to download (401), so treat them as meta and audition in Studio.

### 3.3 Sonniss #GameAudioGDC 2019 (the main new unlock)

**Where.** The mirror `ftpmirror.your.org/pub/misc/sonniss2019/` is reachable; `sonniss.com` and `downloads.sonniss.com` answer 403. It has 8 zip parts, 26 GB in total.
- The central directories of all 8 parts were listed by HTTP range request (`zipdir.py`, about 1,500 files).
- Single files were range-extracted without downloading the parts: `Dodge_Challenger_Hellcat_t8_Onbrd_Start_Slow_Drive…wav` (25.3 s, 96 kHz/24-bit), `Coins_In_Sack…wav`, and `License.pdf` (read).

**Licence (from `License.pdf`).** Worldwide, royalty-free, unlimited projects, commercial use without attribution, games included. You may not sell the sounds as-is.

**Upload.** Audio we upload is private to the owner by default, which is consistent with the licence.

| Library (part) | Use | Q | Fit |
|---|---|---|---|
| Pole Position: Dodge Challenger Hellcat 2015, Pontiac GTO 1967 (on-board "steady RPMs"), AMC Javelin 1968 (p3) | Muscle-class engine loops | 5 | Sounds (upload) |
| Pole Position: Lamborghini Huracan 2014, Ferrari F40 LM 1991, Mercedes AMG GT R 2018, Mazda RX-7 1990 | Super and sports engines | 5 | Sounds |
| Pole Position: Jeep SRT8 2014, Ford Probe 1995, Peugeot 307 SW, Toyota C-HR (p5); Soundholder VW Golf V / BMW F12 640D (p6); SoundBits Mercedes E53 AMG (p5); Andrew Vailcross BMW E46 (p1) | SUV, compact and sedan engines | 4 | Sounds |
| Pole Position: Dodge A100 1965 van, MAN Lion's Coach 2015, Volvo FM10 2003 truck (p5), FSO Polonez police car | Van, bus, truck, cop-car engines | 4 | Sounds |
| Pole Position: Yamaha RS Venture 2006 (p5); Airborne Sound: Victory Vegas Motorcycle (p1) | Motorcycles | 4 | Sounds |
| Pole Position: Agusta A109, Black Hawk UH-60M (p3) | Police and news heli turbines | 5 | Sounds |
| Airborne Sound: Vehicles Car SFX Elements, Race Cars, Motorsports 1, Vehicles Aviation, Freight / Transit Trains, Ferry (p1) | Car foley, planes, trains | 4 | Sounds |
| 2496SoundEffects: Ambisonic City, Surround In the City, Rain in the City, Coastal Ambience and Beaches (p7) | City, rain and beach beds | 5 | Sounds |
| West Wolf: Pedestrian Streets, Construction Ambiences, Slush and Wet Streets, Protesting People (p7) | Downtown walla, wet tyres | 4 | Sounds |
| Tone Glow Libraries: Inland Port (p6: container terminal, crane spreader, alarms, rail yard) | Port ambience | 5 | Sounds |
| Matt Script: Airplanes and Airports, Walla and Ambience (p2) | Airport terminal | 5 | Sounds |
| Coll Anderson: Music Drive Bys (p2) | Cars passing with radios playing (a GTA detail) | 5 | Sounds |
| Studio 23: Ultimate Footstep Collection (p6); Red Libraries: Bodyfall (p5); Rock The Speakerbox: Melee (p5) | Footsteps by surface, ragdoll falls, melee | 4 | Sounds |
| Shapeforms: The Mint, Coins and Money (p5) | Cash pickups and robberies | 4 | Sounds |
| Sound Ex Machina: RAIN CITY (p5); Pole Position: Thunder and Rain (p5) | Rain | 5 | Sounds |
| Pole Position: Barking Dog (p3); Bart Kamski: Dogs (p1) | Suburban dogs | 4 | Sounds |
| Apple Hill Studios: Military Radio Voices (p1) | SWAT radio chatter | 3 | Sounds |
| InspectorJ: UI Mechanical (p2); L.A. Sounds: Game and UI Interface (p2); 3maze: UI FX (p1) | Phone and menu UI | 3 | Sounds |

### 3.4 Other audio sources tested

| Source | Licence | Result |
|---|---|---|
| OpenGameArt "Different steps on wood, stone, leaves, gravel and mud" (`opengameart.org/content/different-steps-on-wood-stone-leaves-gravel-and-mud`) | CC0 | Downloaded zip, 77 KB. Q2: thin. |
| OpenGameArt "51 UI sound effects" (`…/51-ui-sound-effects-buttons-switches-and-clicks`) | CC0 | Downloaded, 1.4 MB. Q3. |
| Freesound CC0 (indexed by `api.openverse.org/v1/audio`) | CC0 | Metadata reachable, but `freesound.org` and `cdn.freesound.org` answer **403**. Not usable from here. |
| Pixabay sound effects | Pixabay Content License (commercial, no attribution) | 403 here; licence read via WebFetch |

---

## 4. Animation

### 4.1 Roblox-owned emote animations

Owner `Roblox/24` comes from `economy.roblox.com/v2/assets/{animId}/details`. Each emote was downloaded and its inner `Animation` read. Poses are in `scout_roblox_emotes.jpg`.

Load the **inner** ID with `Animator:LoadAnimation`. These are Roblox-owned, so no purchase or upload is needed. They are R15 Rthro-proportioned, so verify blending on Base Body NPCs.

| Emote (catalog ID) | Inner Animation ID | GTA use |
|---|---|---|
| Cower `cat:4940597758` | 4940563117 | Robbery victims, gunfire reaction |
| Confused `cat:4940592718` | 4940561610 | Pedestrian reaction to a crash |
| Point2 `cat:3576823880` | 10714395441 | Witness points at a crime (triggers heat) |
| Get Out `cat:3934984583` | 10714345862 | Shopkeeper shoos the player out |
| Bored `cat:5230661597` | 10713992055 | Bus-stop idle |
| Applaud `cat:5915779043` | 10713966026 | Street performer crowd |
| Agree / Disagree `cat:4849487550` / `cat:4849495710` | 10713954623 / 10714065135 | Conversation pairs |
| Shrug `cat:3576968026` | 10714374484 | Conversation |
| Hello / High Wave `cat:3576686446` / `cat:5915776835` | 10714359093 / 10714362852 | Greeting, flag down a cab |
| Salute `cat:3360689775` | 10714389988 | Cops and military at stations |
| Tantrum `cat:5104374556` | 10714340558 | Car-jacked owner rage |
| Sad / Happy / Haha `cat:4849502101` / `cat:4849499887` / `cat:4102315500` | 10714392876 / 10714352626 / 10714350889 | Ambient mood |
| Celebrate `cat:3994127840` | 10714016223 | Mission passed or race win (player) |
| Beckon `cat:5230615437` | 10713984554 | Contact NPC "over here" |
| Fishing `cat:3994129128` | 10714101749 | Pier fishermen |
| Bodybuilder `cat:3994130516` | 10713990381 | Muscle Beach |
| Block Partier / Samba / Line Dance / Rock On / Keeping Time | 10713988674 / 10714386947 / 10714383856 / 10714403700 / 10714380563 | Beach party, club, buskers |
| Tilt / Stadium | 10714338461 / 10714356920 | Filler |

**Gaps that stay custom** (no Roblox emote covers them): hands-up surrender, phone call, smoking (not allowed anyway), car entry, aim and reload.

### 4.2 Walk-style packs (HumanoidDescription; no ownership needed for NPCs)

| Pack | Idle / Walk / Run asset IDs | Verified | Use |
|---|---|---|---|
| Elder `bun:48` (Roblox) | 892268340 / 892267099 / 892265784 | catalog details, T | Old pedestrians |
| Stylish `bun:83` (Roblox) | 619511648 / 619512767 / 619512153 | catalog details, T | Fashion and downtown walkers |
| Oldschool `bun:667` (Roblox) | 5319922112 / 5319909330 / 5319900634 | catalog details, T | Filler |
| adidas aura `bun:4294795` (adidas) | 73137983344853 / 75183215343859 / 123973978164540 | catalog details, T | Young and athletic pedestrians |
| Patrol `bun:181404455030157` / Confident `bun:122083128184296` (Synimation, UGC) | in the catalog bundle details | meta | Cops on foot, business people. Third-party UGC, so it can be delisted; keep fallbacks. |

### 4.3 Custom-clip pipeline (for the clips above that no emote covers)

| Item | Link | Licence | Verified | Pipeline cost |
|---|---|---|---|---|
| CMU Graphics Lab Motion Capture Database | `http://mocap.cs.cmu.edu/` (http only; https fails here) | FAQ: "may be copied, modified, or redistributed without permission" | Downloaded `02_01.amc` + `02.asf` | ASF/AMC → BVH (or community BVH conversions) → Blender retarget to R15 → Studio import → publish under the experience owner. About ½ day per clip until the rig mapping is solved once. |
| Mixamo (hands up, surrender, phone talk, cower, car entry) | `https://www.mixamo.com` | Adobe terms: royalty-free use in games; no redistribution of raw files | Homepage 200 only; downloads need an Adobe login (not tested) | The same retarget path. This is the best quality for the hands-up and phone clips the lead asks for. |
| RBXMonkey – Blender Animations (Studio plugin) | `rbx:16708835782` | Free plugin | meta (2,000 votes, 93%) | Imports Blender actions as KeyframeSequences |
| Blender rig exporter / animation importer (Den_S) | `rbx:716953901` | Free plugin | meta (2,000 votes, 83%) | Exports an R15 rig to Blender and imports animation back |

---

## 5. VFX

| Item | Source | Licence | Verified | Q | Improves | Fit | Effort |
|---|---|---|---|---|---|---|---|
| Explosion01 (5×5, 1024², RGBA) | `https://unity3d.com/files/labs/downloads/vfx/assets01/Explosion01/Explosion01-flipbooks.zip` | CC0 | DL, T | 5 | Car and grenade explosions | VFX | M |
| Explosion02HD (5×5, 2048²) | `…/Explosion02HD/Explosion02HD-flipbooks.zip` | CC0 | DL, T | 5 | Hero explosion (downscale to 1024) | VFX | M |
| Explosion01-light-nofire (5×5) | `…/Explosion01-light-nofire/…` | CC0 | DL, T | 5 | Dust and smoke burst (no flame) | VFX | S |
| FireBall01 (8×8, RGB additive) | `…/FireBall01/FireBall01-flipbooks.zip` | CC0 | DL, T | 5 | Muzzle-sized fireballs, molotov burst | VFX | S |
| Flame02 (16×4) | `…/Flame02/Flame02-flipbooks.zip` | CC0 | DL, T | 5 | Burning-car flames (repack 8×8) | VFX | S |
| WispySmoke01 (8×8) | `…/WispySmoke01/WispySmoke01-flipbooks.zip` | CC0 | DL, T | 5 | Engine smoke, smouldering wrecks | VFX | S |
| DiscSmoke01 (16×4), Cloud01 (8×8) | `…/DiscSmoke01/…`, `…/Cloud01/…` | CC0 | DL, T | 4 | Tyre smoke and drift clouds (BACKLOG #3), dust | VFX | S |
| 21 more Unity Labs sets (Explosion00/02, FireBall02–04, Flame03, SmallFlame01, WispySmoke02/03, CandleSmoke01, Cloud02–04) | `unity.com/blog/engine-platform/free-vfx-image-sequences-flipbooks` | CC0 | listed (WebFetch) | 4–5 | Variety | VFX | S |
| Creator Store "realistic" fire, smoke and explosion models (16 viewed) | e.g. `rbx:248756428`, `rbx:12136850996` | Creator Store | T | 2–3 | **No adoptable realistic VFX pack.** Results are spam copies or classic Fire objects. | — | — |

Roblox flipbooks take Grid 2×2, 4×4 or 8×8. Repack 5×5 to 4×4 (drop frames) and 16×4 to 8×8, and keep each texture at 1024² or below.

---

## 6. Fonts, icons and UI

| Item | Source | Licence | Verified | Q | Improves | Fit |
|---|---|---|---|---|---|---|
| Barlow | `rbx:12187372847` | Roblox-owned family (OFL font) | meta (toolbox FontFamily, creator Roblox) | 5 | Road and freeway signs, street-name blades. The design is based on California highway signage. | CityArt |
| Sedgwick Ave Display | `rbx:12187376357` | Roblox-owned | meta | 4 | Graffiti and gang tags, spray-shop decals | CityArt |
| Monoton | `rbx:12187374098` | Roblox-owned | meta | 4 | Neon-tube storefront and motel signs at night | CityArt |
| Playfair Display / Roboto Slab | `rbx:12187374765` / `rbx:12187368625` | Roblox-owned | meta | 4 | Jewelry and luxury storefronts; diner and retail signs | CityArt |
| Teko / Rajdhani / Antonio | `rbx:12187376174` / `rbx:12187375422` / `rbx:122516982241677` | Roblox-owned | meta | 3 | Already ruled redundant for the HUD (`gta_ui_language` §4). Usable for in-world signage only. | CityArt |
| game-icons.net (4,180 SVG) | `https://game-icons.net/archives/ffffff/transparent/game-icons.net.svg.zip` | **CC BY 3.0** (credit each author) | DL (4.2 MB zip), 48 rendered, T | 4 | Minimap blips, weapon-wheel placeholders, phone apps | UI (blip sheet) |
| Tabler Icons 3.50 | `npm @tabler/icons` (`cdn.jsdelivr.net/npm/@tabler/icons@3.19.0/icons/outline/*.svg`) | MIT | DL samples, T | 4 | Phone UI, menu glyphs | UI |
| Lucide / Material Symbols / Phosphor / Remix | `npm lucide-static` (ISC), `@material-symbols/svg-400` (Apache-2.0), `@phosphor-icons/core` (MIT), `remixicon` (Apache-2.0) | Permissive | npm metadata | 4 | Alternatives | UI |
| simple-icons | `npm simple-icons` | CC0 code, but every icon is a **real brand logo** | npm metadata | — | **Do not use** (trademarks) | — |
| UI click sets | §3.2 Roblox UI SFX; OGA 51 UI SFX; Sonniss UI packs | Roblox-owned, CC0, Sonniss | DL / listed | 3–4 | Menu clicks | Sounds |

---

## 7. Code and components (vendorable from here: `api.wally.run` downloads work; GitHub does not)

Fetched with `curl -H "Wally-Version: 0.3.2" https://api.wally.run/v1/package-contents/<scope>/<name>/<ver>` (zip).

The project has no Wally setup. Vendor by copying the files into `src/shared/Vendor/<Name>/` with the licence text, then exclude that directory from selene and stylua. Never take a dependency we cannot vendor.

| Item | Source | Licence | Verified | Adopt or learn | Fit and risk |
|---|---|---|---|---|---|
| ProfileStore (loleris) | `wally:lm-loleris/profilestore@1.0.3`; `rbx:109379033046155` (200 votes, 97%) | **Apache-2.0** (LICENSE in the zip) | DL both | **Consider** for the C1 data switchover (session locking, autosave) | v1 data code stays per the lead; only swap at WP2 if it simplifies migration |
| Streamable / Component / Trove / Signal / Timer / TableUtil (sleitnick RbxUtil) | `wally:sleitnick/streamable@1.2.4`, `component@2.4.8`, `trove@1.8.0`, `signal@2.0.3`, `timer@2.0.0`, `table-util@1.2.1` | MIT (wally.toml; no LICENSE file bundled, so add an MIT notice) | DL (trove), meta | **Adopt Streamable** for StreamingEnabled-safe waits (decision 1); Trove for cleanup | Small, dependency-free |
| Shake + Spring (sleitnick) | `wally:sleitnick/shake@1.1.0`, `spring@1.0.0` | MIT | DL (shake) | **Adopt**: camera shake for explosions, gunfire, crashes; spring camera | Game feel |
| Promise (evaera) / Janitor (howmanysmall) | `wally:evaera/promise@4.0.0`, `howmanysmall/janitor@1.18.3` | MIT (LICENSE in zip) | DL | Optional | Style fit only |
| t (runtime typechecker) | `wally:osyrisrblx/t@3.1.1` | MIT | meta | **Adopt** for remote-argument validation (decision 6 / `roblox-security`) | Tiny |
| Cmdr (evaera) | `wally:evaera/cmdr@1.13.1` | MIT | DL (86 files) | **Adopt** behind an admin gate for QA (wanted level, spawn car, time of day) | Gate server-side |
| Iris (debug ImGui) | `wally:michael-48/iris@2.3.1` | MIT | DL | Dev-only overlays (traffic AI, streaming) | Strip from prod |
| FastCast Redux + PartCache | `rbx:4453855787` (200 votes, 95%), `rbx:2904807375` | MIT according to the author's repo; no header in source; GitHub is blocked here, so **verify the licence** | DL (6 + 2 ModuleScripts) | Learn and adopt for **visual** tracer travel and pooled casings only. Hits stay server hitscan per `gta_combat` §10. | Vendor with notice once confirmed |
| SimplePath (Grayzcale) | `rbx:6744337775` (200 votes, 89%) | **MIT** (in source) | DL | Adopt for cops on foot and pedestrians fleeing off the RoadGraph | Wraps PathfindingService |
| Rain module (buildthomas) | `rbx:2166863728` | **Apache-2.0** (in source) | DL | Adopt (TOP #10) | Particles; mobile-tested by the author |
| Chickynoid | `wally:easy-games/chickynoid@0.1.5` | MIT | DL (28 files) | Learn: server-authoritative character movement (speed-hack resistance) | Too invasive to adopt now |
| jecs (ECS) | `wally:ukendio/jecs@0.11.0` | MIT (LICENSE) | DL | Learn for kinematic traffic and pedestrian crowds at scale | Architecture change |
| Roblox Character Controller Library ("AvatarAbilities") | `rbx:130621479779870` (Roblox, 2026-04) | Roblox-owned | DL (49 ModuleScripts: Running, Climbing, Swimming, Sitting, Crouching, NetworkOwnership) | Learn and watch: crouch and cover could come from it | New; API may move |
| R15 Constraint Ragdoll (caoqt) | `rbx:4708193709` | No licence stated | DL (1 module) | Learn only | Ragdoll for WASTED |
| A-Chassis 1.7.2 | `rbx:13999609938` (A-Chassis Official, 200 votes, 94%) | Open source (licence not visible here) | DL | Learn only (we keep the v1 raycast rig) | — |
| Dynamic Weather System | `rbx:12626706474` (80 votes, 89%) | Unstated (bundles a copy of the Rain module) | DL | Learn | — |
| Roblox Racing template (2024) | Studio templates; `devforum.roblox.com/t/new-studio-racing-template/2805745` | Roblox-provided | WebFetch | Learn: checkpoint visuals, attribute-tuned car | Camera swings on reverse (reported) |
| JONSWAP Ocean / FFT Phillips ocean | `devforum.roblox.com/t/jonswap-ocean-liquid/3661760` (MIT), `/t/fft-phillips-ocean/2950964` | MIT (stated) | WebFetch only; the code is on GitHub (blocked) | Later: EditableMesh waves for the beach | Seams and tiling unsolved (author) |

**Studio plugins for the operator.** All are free and checked by metadata.
- Brushtool 2.1 `rbx:2268520847`: scatter trees and props.
- Archimedes `rbx:144938633`: freeway ramp arcs.
- Stravant ResizeAlign `rbx:165534573`, GapFill `rbx:165687726`, Redupe `rbx:73064993918325`: lamp rows along curves.
- Part to Terrain `rbx:261634767`.
- MeshToTerrain V2 `rbx:13781503087`.
- Camera Spline (Dubit) `rbx:133167480075010`: marketing fly-throughs.
- Rojo `rbx:13916111004`.

---

## 8. Other quality raisers

| Item | Source | Licence | Verified | Improves |
|---|---|---|---|---|
| Puddle roughness map (shared by Roblox's puddle MVs) | Image `9781671574` (roughness) + `9781989836` (metal) | Roblox-owned | DL (from the MV pack) | Build an `HC_AsphaltPuddle` variant with our own asphalt colour |
| CarPaint_A MaterialVariant | maps in §2.3 | Roblox-owned | DL | A metallic flake paint for CarBuilder paint finishes (rarity "paint finish" pillar) |
| Roblox Clouds plus our Poly Haven sky set | built-in `Clouds`; `gta_assets` §6.2 | — | — | Already planned: drift clouds with the time of day |
| Openverse as an image and audio *search* | `api.openverse.org/v1/images?license=cc0,pdm` | Per item | Reachable | A licence-filtered search that works from this container |

---

## Risks and notes

1. **Open Cloud asset delivery hiccup.** At 21:52 UTC the key's `asset-delivery-api` calls returned `403 "User is moderated"` for every asset, including PSE audio. By about 22:40 the same calls returned 200. Watch for it if uploads or deliveries fail. `rbxdl.py` caches 403s as permanent, so delete those `meta.json` files before retrying.
2. **CC-BY bookkeeping.** Every Sketchfab item that ships goes into `assets/ATTRIBUTION.md` and the Credits screen. game-icons.net is also CC BY 3.0, per author.
3. **Brands to strip before upload:**
   - Lincoln (Town Car), Lufthansa and Lion Air liveries, Riva, Kawasaki.
   - Real product labels on the Rendevr shelves.
   - Visa and Mastercard on Murk's ATM.
   - MTA "I ❤ NY" on bus `9838306707`.
   - Korean text on the Poly Haven extinguisher.
4. **Heavy items.** Decimate these before upload:
   - Newspaper boxes 209k, container ship 189k, Bell UH-1N 111k, container scan 109k, Rendevr drinks shelf 106k.
   - The Firetruck GLB is 48 MB of textures.
   - Modern City prefabs are dense; budget them per chunk.
5. **Licensed music.** On-platform only, at most 250 tracks, and no jukebox-style "music library". Mute or replace it in marketing captures.
6. **Scripts on Creator Store items.** Strip them, as always:
   - Bus 3142595440: 59.
   - Fire engine 3453243574: 66.
   - Limo 4893597123: 35.
   - Duvall Furniture: 101.
   - Modern City kit: 8.

---

## SOURCES (every platform tested from this container, 2026-10-27)

| Platform | Reachable? | Licence summary | Used for |
|---|---|---|---|
| api.polyhaven.com, dl.polyhaven.org, cdn.polyhaven.com | Yes | CC0 | §1.3 props, thumbnails, glTF HEAD |
| ambientcg.com API + `/get` | Yes | CC0 | §2.1 |
| sharetextures.com | Yes | CC0 | Models are mostly small items (handles, food, stones); nothing new for urban gaps |
| texturecan.com, cgbookcase.com, 3dtextures.me | Yes (homepages 200) | CC0 | Not swept in depth (ambientCG and Poly Haven cover more) |
| freepbr.com | Yes | Free for commercial use, no redistribution (not CC0) | Not used |
| textures.com | Yes | Proprietary credits | Not used |
| huggingface.co (Objaverse) | Yes | Per-object (CC-BY/CC0 filter) | Covered by `cc0_assets.md`; the Sketchfab API supersedes it |
| api.sketchfab.com (token) | Yes; **429** on bursts | Filter `license=by,cc0` | §1.2: 49 models |
| apis.roblox.com toolbox-service v2 | Yes | Creator Store terms | All Creator Store searches. `userId=`, `groupId=`, `maxPriceCents=0`, `audioTypes=Music` and `includeOnlyVerifiedCreators` all work. `creatorType`/`creatorTargetId` are ignored on v2. |
| thumbnails.roblox.com (assets + `bundles/thumbnails`) | Yes | — | Every T |
| catalog.roblox.com (search + bundle details) | Yes | — | §4 |
| economy.roblox.com v2 asset details | Yes | — | Animation owner checks |
| assetdelivery.roblox.com/v2 (no auth) | Yes for Roblox-owned and licensed audio; **401** for third-party models | — | 117 downloads |
| apis.roblox.com asset-delivery-api (Open Cloud key) | Yes (transient 403 "User is moderated" once) | — | §1.4 third-party parses |
| api.wally.run | **Yes**: search, metadata, `package-contents` zip | Per package (MIT/Apache) | §7 vendoring path |
| registry.npmjs.org, cdn.jsdelivr.net, unpkg.com | Yes | Per package | Icon licences and samples |
| game-icons.net | Yes | CC BY 3.0 | §6 |
| opengameart.org | Yes | Per item | §3.4 |
| api.openverse.org (images + audio) | Yes | Per item, CC0/PDM filter | §2.2; audio search |
| images.rawpixel.com (editor_1024), cdn.stocksnap.io thumbnails | Yes | CC0 | §2.2 |
| rawpixel.com site | 403 | — | — |
| commons.wikimedia.org | **429** (rate-limited) | Per file | Blocked in practice |
| loc.gov (Highsmith public-domain archive) | Cloudflare challenge | Public domain | Blocked |
| unsplash.com | 401 to curl; WebFetch OK | Unsplash License | §2.2 |
| pexels.com | 403 | Pexels License | — |
| pixabay.com | 403 to curl; WebFetch OK | Pixabay Content License | §2.2 |
| freesound.org, cdn.freesound.org | **403** | CC0 / CC-BY per sound | Blocked (Openverse metadata only) |
| sonniss.com, downloads.sonniss.com, gdc.sonniss.com | 403 to curl; WebFetch OK | Sonniss GDC EULA | Licence; mirror list |
| ftpmirror.your.org/pub/misc/sonniss2019/ | **Yes** (range requests work) | Sonniss GDC EULA | §3.3 |
| hippolytus.feralhosting.com (Sonniss 2024 mirror) | Homepage 200; HEAD inconclusive | Sonniss GDC EULA | Not used |
| unity3d.com/files/labs (Unity Labs VFX) | Yes | CC0 | §5 |
| mocap.cs.cmu.edu | http 200 (https fails) | Free to copy, modify, redistribute | §4.3 |
| mixamo.com | Homepage 200; downloads need an Adobe login | Adobe terms | §4.3 (untested download) |
| devforum.roblox.com, create.roblox.com/docs | Yes (WebFetch) | — | §7 |
| en.help.roblox.com | 403 | — | Licensed-music terms unconfirmed |
| itch.io | Homepage 200; asset listings 403 or challenge | Per pack | Blocked in practice |
| api.si.edu (Smithsonian Open Access) | 403 | CC0 | Blocked |
| mixkit.co, bigsoundbank.com, gamesounds.xyz, incompetech.com, freemusicarchive.org | Yes (homepages 200) | Mixed (Mixkit free licence; BigSoundBank royalty-free; Incompetech CC-BY; FMA per track) | Not swept. Uploading third-party music to Roblox needs the rights, so prefer the licensed catalogue. |
| fab.com, turbosquid.com, zapsplat.com | 403 | — | — |
| cgtrader.com | Yes | Royalty-free or paid | Not swept |
| github.com, raw.githubusercontent.com, codeload.github.com | **Blocked** (400) | — | FastCast, A-Chassis and JONSWAP licences unverifiable |
| kenney.nl | Homepage 200, downloads blocked (per brief); stylized anyway | CC0 | — |
| poly.pizza | Blocked (per brief); not retested | — | — |
| nasa.gov, nps.gov, catalog.data.gov | Yes | US public domain | Not swept (possible PD plates) |
| publicdomainvectors.org | Yes | CC0-ish | Not swept |
| svgrepo.com | 429 | Mixed | — |
