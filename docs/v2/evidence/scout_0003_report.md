# Job 0003 report: Creator Store realism scout

> **Status: PARTIAL.** Categories 0–5 (cars) are done. The other categories follow in later pushes. `DONE` will be written only at the end.

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
- **3/5:** #1 `16390639371` Realistic Police Car (reachin4stars). 237 parts, with **114 scripts removed** (a heavy chassis or ELS). It has a black-and-white livery and a lightbar, but its proportions are chunky.
- **4/5:** #2 `103123587729335` "Police Car Decoration Detailed" (StarNeon5292). A Peugeot-style French police hatchback with a clean livery. It is static decor, which suits parked props.
- **4/5:** #3 `113053967699143` Police Car Cop City Pursuit (KingJames_the67). An Explorer-style police interceptor SUV, with 23 textures and a good livery. It is slightly oversized at 27 studs long.
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
