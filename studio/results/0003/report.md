# Job 0003 report: Creator Store realism scout

> **Status: COMPLETE.** All 18 categories are scouted (72 assets). CLEANUP ran and `Workspace.HCScout` is gone; the Workspace is back to Terrain, Baseplate, SpawnLocation and Camera. The place was not saved.

- **Studio:** 0.744.0.7441077, Hotwire City place, Edit mode only. Play was never started while `HCScout` existed, and the place was never saved.
- **Search:** `search_asset` with scope `creator_store`, `assetType=Model`, `priceFilter=free`, 8–12 results per query.
  - I tried `verifiedCreatorsOnly=true` on the first category. It returned the same keyword-spam listings, so I didn't use it again.
  - There is no "sort by votes" option.
  - Results are dominated by keyword-stuffed "Realistic … RP" uploads. I skipped anything plainly cartoony or old, plus a PAYDAY 2 ripped model, which is someone else's IP.
- **Sanitising:**
  - Studio's `insert_asset` already sets `Sandboxed=true` on every script it inserts.
  - Then SANITIZE+LAYOUT deleted all `LuaSourceContainer`s and anchored every part.
  - For brevity I put the SANITIZE+LAYOUT body unchanged into a `_G.HCScoutLayout(CAT, CAT_INDEX)` function and called it once per category.
- **Shots:** `<category>.png` uses the `camPos`/`camLook` returned by the layout. The `#n assetId` BillboardGui labels do **not** render in Edit-mode `screen_capture`. Assets appear in insertion order from **right to left** (the camera looks down +Z, so +X is screen-left).
- **Metadata:** in `scout.json`.

## Verdicts (1 = toy, 5 = GTA-grade)

Assets are listed in insertion order (#1–#4), which in the shots runs from right to left.

### cars_sedan
The camera is pulled far back because #2 is a whole diorama.
- **3/5:** #1 `97965573521866` Mercedes sedan (nov4_gg2010). A clean modern sedan shape with 107 MeshParts, but small: 17×6×9 studs, below GTA street scale.
- **2/5:** #2 `116549755605901` EFT French sedan (Swift_Hawk217). The car itself has PBR textures and looks decent. However, the model is a **scene** (Russian flag billboard, pine trees, ground), 73×45×151 studs, and would need the car extracted.
- **3/5:** #3 `132078381973405` Prius (Xz_SilvervBCelestial). A believable silhouette with 12 textures and 90 MeshParts.
- **3/5:** #4 `951086064` 2009 Nissan Maxima (turbo_isaac). Good proportions, untextured MeshParts, and 71 scripts removed (an old A-Chassis).

### cars_sports
- **4/5:** #1 `11881862706` Jaguar (DominicF1Fan). The best sports car here: 212 MeshParts, a crisp body and wheels, and good proportions.
- **2/5:** #2 `140417184564372` "Realistic Sports Car Racer". A single MeshPart with no textures. It looks like a white blob from range.
- **2/5:** #3 `87717693644018` "Brookhaven Luxury GT". In the lineup it is a boxy 80s sedan, not a GT, and the listing is misleading.
- **3/5:** #4 `3204824887` Chrysler ME412 (VloneDerrick). A decent supercar shape, with flat untextured parts.

### cars_suv
- **2/5:** #1 `138255866612822` 2008 Mercury Mariner (yiypoo1024). Only 3 parts and undersized (5×5×12).
- **4/5:** #2 `14746413121` 2005 Nissan Patrol (children3295). A very convincing boxy SUV, with 98 MeshParts and textures.
- **4/5:** #3 `117276253886376` 2011 Kia Sorento (yiypoo1024). It has 32 textures, a clean modern crossover shape and correct scale.
- **4/5:** #4 `73893179863762` 2005 Nissan Murano (yiypoo1024). It has 20 textures, a good silhouette and taillights.
- Creator **yiypoo1024** is consistently the most realistic car uploader found so far: 1998 Elantra, Mariner, Sorento, Murano.

### cars_police
- **4/5:** #1 `16390639371` Realistic Police Car (reachin4stars). **The Explorer-style police interceptor SUV**, with a good livery. 237 parts, with 114 scripts removed (a heavy chassis or ELS). *(Corrected in job 0004: the first version of this report swapped the descriptions of #1 and #3.)*
- **4/5:** #2 `103123587729335` "Police Car Decoration Detailed" (StarNeon5292). A Peugeot-style French police hatchback with a clean livery. It is static decor, which suits parked props.
- **2/5:** #3 `113053967699143` Police Car Cop City Pursuit (KingJames_the67). A blocky black sedan built from plain parts, with an Ohio State Highway Patrol hood decal. Oversized at 27 studs long. *(Corrected in job 0004.)*
- **1/5:** #4 `73440173280832` "Police Car Siren Vehicle". The Folder contains **one 4×4×2 part**, a pink blob. It is unusable.

### cars_truck
- **4/5:** #1 `89890547548224` Ford F-150 XLT Supercrew (NameNotRick925). 32 textures, a red crew cab, and correct scale. It is the best truck.
- **3/5:** #2 `10141791793` 2020 GMC 2500 AT4. 299 parts with 63 scripts removed. It is a black heavy-duty truck with odd green accent lights.
- **3/5:** #3 `8271014113` Silverado Crawler (SubXero_X). A lifted crawler on huge tyres. It has **600 Texture objects**, which is heavy, and is a niche look.
- **4/5:** #4 `126180570128588` 2022 Toyota Tundra. A clean modern crew cab in beige.

### cars_taxi_van
- **3/5:** #1 `94301391128632` and #2 `112789212430129` taxis. These are **the same mesh** re-uploaded by two accounts: a Crown-Vic-style yellow cab in 2 MeshParts.
- **4/5:** #3 `131180706902259` Box truck (ElijahStar9036). A convincing Isuzu-style box truck, 12 studs tall.
- **3/5:** #4 `71284840505836` Panel van (Gutzow). A recognisable 80s panel van, plain white.

### guns_pistol
Guns are tiny next to the 900-stud floor, so the layout camera sits about 55 studs back and they are only a few pixels wide.
- **3/5:** #1 `7949754821` "4K realistic pistols, revolvers" (908KS_RKO). A **crate of about 130 gun meshes**, not one pistol. Worth opening as a mesh library, but its 9×2×12 bounds are mostly the box.
- **1/5:** #2 `12700880104` "Working Pistol". A 1×0×0-stud sliver that is barely visible.
- **2/5:** #3 `15030367967` Realistic Pistol (SparksammyOfficial). A single small mesh with no texture.
- **3/5:** #4 `78033796632460` "realistic guns mesh pack Pistol Giver". The mesh is actually an **M4 carbine**, not a pistol, though it is a decent mesh.
- Pistols are the weakest category. Plan to model or commission them.

### guns_rifle
- **4/5:** #1 `86516814029259` AK47 PBR (Quicfli1351). Inserted as an Accessory with a SurfaceAppearance, giving wood furniture and a convincing silhouette. The best rifle.
- **3/5:** #2 `9214294514` Realistic Assault Rifle [NEW] (PolyLowDeveloper). An M16-style rifle, clean but untextured; see `guns_rifle_close.png`.
- **3/5:** #3 `93079579364423` AKM prop. 6 MeshParts in black, correct proportions.
- **4/5:** #4 `82824254324474` FPS modern rifle (f0xhd09). Has 6 textures and rails and optics, and reads as a modern AR. It is slightly oversized at 6 studs long.

### guns_shotgun_smg
- **4/5:** #1 `126959125460533` ACS Remington 870 (ProSparklySkater80). Inserted as a Folder. A convincing pump shotgun with 16 MeshParts; see `guns_shotgun_smg_close.png`.
- **3/5:** #2 `6734344458` Double-barrel shotgun (908KS_RKO). A long side-by-side with wood stock.
- **1/5:** #3 `112572154856350` "UZI SMG". A **359×201-stud neon-purple Uzi statue** with a vaporwave palm logo, and the reason `guns_shotgun_smg.png` is framed so wide. Not a weapon asset.
- **3/5:** #4 `71752855928467` P90 (Xz_H0ll0wjMR0gueuMOr). 16 textures and 37 MeshParts. It is lost in the wide shot, but its metadata looks like a real model.

### props_streetlight
- **4/5:** #1 `12117717385` Realistic Street Light (WovenZane). A tall US cobra-head with 95 MeshParts and 9 textures, and it casts a light cone. The best of the set.
- **3/5:** #2 `15078039735` realistic street light 2. A simple 3-part cobra-head that fits well with the lab's lamp scale.
- **3/5:** #3 `4049898662` Realistic Double Street Light (Infinite_Tungsten). A Y-shaped twin-arm highway light made of plain parts.
- **4/5:** #4 `95891415099137` Electricity poles with street light (landonpanda123). Wooden utility poles with sagging wires and insulators, good for suburbs. It is 74 studs long because it is a two-pole span.

### props_trafficlight
- **4/5:** #1 `4477106901` (WORKING) Realistic Traffic Light (baxzzi). A US mast arm with left-turn arrow heads, a pedestrian head and a street lamp. The description says it follows a real blueprint. The best of the set.
- **2/5:** #2 `96197445871164` Realistic Traffic Light (Robloxian_Dude07). A pole-top cluster of oversized glowing neon lenses that reads as a toy.
- **4/5:** #3 `13752790025` Realistic Traffic Light (skelewizz). A US mast arm with a cobra-head lamp. Clean, and only 13 parts.
- **2/5:** #4 `13522889670` Traffic light camera (CityRoads). Just the 6-stud camera pole; useful for intersection dressing only.

### props_palm
- **4/5:** #1 `99808919561383` Realistic Palm Trees (3DThunderbolt). A **10-tree pack** with 660 MeshParts and dense, convincing fronds that read as tropical coconut palms. Heavy: 791 parts for the pack.
- **3/5:** #2 `10562894034` Palm Tree (Natalie_Clabo). 3 parts at 51 studs, a nice fan of fronds.
- **3/5:** #3 `471214939` Realistic Palm Tree (Narrakin). A single mesh with darker, bushier fronds.
- **4/5:** #4 `8626962700` realistic palm tree (VilmosSzapary). 67 MeshParts with textures, and a slender LA-style trunk that matches GTA V's Vinewood look best.

### props_street_small
I picked one each of hydrant, bus stop, dumpster and bin, because no single search covers all five terms.
- **3/5:** #1 `13452054366` Realistic Fire Hydrant (EarlyDev). A yellow 3-stud hydrant, a single textured mesh.
- **4/5:** #2 `93408078240744` Realistic bus stop (robloxkingjn3). A glass shelter with an ad panel and 39 textures, the most GTA-like prop so far.
- **4/5:** #3 `114651969370411` Realistic Dumpster. A green commercial dumpster, 7 meshes at correct scale.
- **3/5:** #4 `78541661129914` Enhanced Realistic Trash Can (shobdrik599). A small grey bin.

### props_port
- **3/5:** #1 `16269867210` "realistic, dynamic Shipping container" (Rezkiy Productions). A dark ribbed 40-ft box built from 118 plain parts.
- **4/5:** #2 `120215648673966` Blue shipping container (brotherffa_24876). It has corrugated sides, door bars and 8 textures. The best container; it ships standing on its end at 15×11×38, so it needs rotating.
- **3/5:** #3 `1735022636` Red shipping container (closed). A classic red ribbed container made of 115 parts.
- **2/5:** #4 `13788653470` Crane (simonlietuva). A 49-stud stylised pedestal crane with orange trim, more sci-fi than port. **There are no real gantry or STS port cranes on the free store**; a "realistic port crane" search returns toys and boats.

### bld_apartment
The layout camera sits past the floor edge, so the bottom of the shot is the void.
- **3/5:** #1 `126414463808776` Realistic Hood Apartment (deleted account). A 3-storey stucco walk-up with fire escape; 210 parts.
- **2/5:** #2 `75934961104200` "Apartment Buildings City Town Modern" (Rigovota51). This is **#3 re-uploaded**: same 816 parts and size, plus **8 scripts** the original does not have. That is a typical backdoor pattern, so avoid this id.
- **2/5:** #3 `324146132` Zilcosi "Realistic Apartment Buildings". Plain 4-storey pink/grey brick blocks, 2015 style.
- **3/5:** #4 `325256508` Zilcosi apartment with billboards. Brick with windows and a roof unit; the best of the four, but dated.
- No apartment here reaches GTA level. Buildings are better made in-house, in Blender, than taken from the free store.

### bld_skyscraper
See `bld_skyscraper_close.png`, because the layout camera is 900 studs out.
- **4/5:** #1 `8744438793` Realistic Modern Skyscraper (Unit Box Games). A 565-stud stepped tower with antenna, glass grid and lobby colonnade; 1,421 parts. The best skyline piece.
- **3/5:** #2 `16063517134` Realistic Skyscraper (DripWxter). A single 294-stud MeshPart with a podium and blue glass grid. Efficient, but untextured.
- **2/5:** #3 `76401662964478` "Skyscraper City Textures Photo". **The same mesh as #2** re-uploaded, plus 2 scripts. Avoid.
- **2/5:** #4 `117935217942431` "Realistic Skyscrapers" (etipufhu). A **miniature** 42×36×45 cluster of textured towers, roughly a diorama. One texture failed to load.

### bld_shop
See also `bld_shop_close.png`.
- **3/5:** #1 `110999525319105` Gas station (Skystorm9385). A canopy, pumps and store with 120 textures, but plain-looking from range.
- **4/5:** #2 `112405946562554` Modern Gas Station RP (SkyPrimal200361). It arrived as a **StyleLink root** holding models. It has an orange-neon canopy, 6 branded pumps and 540 textures, and looks the most like a GTA "Xero/Globe Oil" station. Heavy at 1,247 parts.
- **3/5:** #3 `324139280` Zilcosi gas station. A white "ELECTRIC" canopy with chargers; clean but simple.
- **2/5:** #4 `80061545177500` Convenience store (deleted account). The exterior is a plain stucco box; its value is the interior shelves. 12 scripts were removed.

### vehicles_air_sea
- **3/5:** #1 `79230898972214` and #2 `118889544532956` "Brookhaven Heli". **Every helicopter result is the same Brookhaven heli** re-uploaded by spam accounts: a Bell-206-style police heli on a helipad, 45 parts, 7–8 scripts each. Acceptable as a prop; no better free heli turned up.
- **4/5:** #3 `139438945638936` Working Boat (Voltbe0854). A 102-stud white flybridge cruiser with railings. Convincing, and good for a marina.
- **1/5:** #4 `87556970` Speed Boat (ObscureGlock). It shows as a floating dark wedge, and its bounds come from an offset part. 2010-era.

## Summary for the lead

- **Use:**
  - Cars: Jaguar `11881862706`; yiypoo1024's SUVs `117276253886376` and `73893179863762`; Nissan Patrol `14746413121`; F-150 `89890547548224`; Tundra `126180570128588`; Explorer police `16390639371` (corrected from `113053967699143` in job 0004); box truck `131180706902259`.
  - Guns: AK47 PBR `86516814029259`; Remington 870 `126959125460533`.
  - Street: streetlight `12117717385`; traffic light `4477106901` and `13752790025`; palm `8626962700` and pack `99808919561383`; bus stop `93408078240744`; dumpster `114651969370411`.
  - Port: blue container `120215648673966`.
  - Buildings: skyscraper `8744438793`; gas station `112405946562554`.
  - Boat: cruiser `139438945638936`.
- **Avoid these re-uploads with extra scripts:** `75934961104200` and `76401662964478`. The same mesh under two ids also occurs for the taxis and helicopters; prefer the original uploader.
- **Gaps:** pistols, port cranes, apartments and helicopters have no GTA-grade free option. Plan in-house modelling for these.
- **Console:** see `console.txt`. It shows only image-load failures from inserted assets (a few textures 403/404). No script errors; all scripts were deleted before anything could run.
