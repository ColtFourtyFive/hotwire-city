# Job 0004 report: realistic car deep-dive

> **Status: COMPLETE.** 61 assets were analyzed: 14 from the shortlist, 42 from the 16 new classes and 5 yiypoo1024 cars. That gives 61 JSONs and 115 shots; duplicates and the broken car have no shots. Studio is cleaned up: `HCCar`, `HCStage` and `HCCarFloor` are deleted, ClockTime is back to 16.5, and the Workspace is back to Terrain, Baseplate, SpawnLocation and Camera. The place was not saved and Play was never started.

## Method

- **Studio:** 0.744.0.7441077, Hotwire City place, Edit mode only. Play was never started, and the place was never saved.
- **Per car:** `insert_asset` into a staging folder, `Workspace.HCStage`. Then one call does four things: destroys the previous `Workspace.HCCar`, creates a fresh one holding only this car, sets `AssetId`, and runs **ANALYZE** exactly as written (stored once as `_G.HCAnalyzeBody`). Then the two `screen_capture` shots.
- **JSON:** `cars/<assetId>.json` is the unmodified ANALYZE output. Studio POSTs it to a local receiver on the operator's Mac, which writes the file directly. One exception: the Jaguar's `scriptsRemoved` was patched back to 24 because its JSON came from a second ANALYZE run.
- **Floor:** a temporary 400-stud asphalt part, `Workspace.HCCarFloor`, sits under the car at (30000, 0, 30000) so the shots have a ground and a shadow. It is removed at the end.
- **Lighting:** ANALYZE sets `Lighting.ClockTime = 14.5`; the original value (16.5) is restored at the end.
- **Camera orientation:** `cam34`/`camRear` follow the bounding box's long axis, which has no fixed sign. For some cars `_front.png` shows the rear and `_rear.png` the front; each verdict says so.
- **Brands:** almost every realistic car carries **real manufacturer badges**, which need removing or replacing before shipping.

## Verdicts
- **11881862706 Jaguar XKR-S GT (DominicF1Fan) — 5/5 looks.** Superb mesh: accurate body, black hood stripes, rear wing, detailed wheels, full dashboard interior. 9.2×5.2×19.1 studs (correct car scale). Wheels cleanly grouped as `Wheels.FL/FR/RL/RR` (2.7-stud dia.); `DriveSeat`; ~30 light meshes. Paint = `0989cf SmoothPlastic` (bright blue, 3rd-largest group; the largest is black trim). **Real Jaguar badges/lettering** front & rear. Note: model's LookVector points backwards, so `_front.png` shows the rear and `_rear.png` the front.
- **14746413121 2005 Nissan Patrol (children3295) — 4/5.** Convincing Y61 Patrol: chrome grille, spare-wheel cover, roof rails, alloys. 18.7×6.9×8.3 studs (correct). 4 wheel candidates, 6 seats, 31 scripts removed (old chassis). Black paint, glass reads dark. **Nissan badge + "PATROL" spare cover lettering**; plate decal. Slightly low-detail interior.
- **117276253886376 2011 Kia Sorento EX (yiypoo1024) — 4/5.** Clean, believable modern crossover; correct proportions, roof rails, alloy wheels, chrome trim. 10.1×7.6×20.7 studs (a touch tall). 24 wheel candidates (wheels split into several meshes each), **no seats** (static prop; needs our own seat). White paint, flat-ish body shading; no visible interior through tinted glass. Small Kia grille badge. Orientation correct (front shot = front).
- **73893179863762 2005 Nissan Murano (yiypoo1024) — 4/5.** Very faithful 1st-gen Murano: chrome grille, swoopy tail lights, roof rails, visible interior seats, twin exhausts. Light model: only 24 parts / 16 MeshParts. 9×6.4×16.6 studs (correct). 4 clean wheel candidates, 4 seats, 16 scripts removed. **Nissan badges** front/rear. Orientation correct.
- **89890547548224 Ford F-150 XLT SuperCrew (NameNotRick925) — 5/5 looks.** Excellent 12th-gen F-150: chrome grille & bumpers, step bars, detailed bed, visible interior seats. 10.6×8×24.2 studs (correct full-size truck). 16 wheel candidates, 5 seats, 27 scripts removed. Red paint. **Ford oval badges** front and tailgate. Orientation correct.
- **126180570128588 "2022 Toyota Tundra" (FusionLigh_t997732) — 4/5.** Actually a 2022 Tundra shape rebadged with a fictional **"VELLFIRE" grille lettering** (internal model name "2022 Vellfire Prairie") — good for us: no real brand badge. Modern LED light signatures, sunroof, step bars, deep bed. 22.2×7.3×9.5 studs (correct). 12 wheel candidates, **no seats** (prop), only 1 script. Cream paint, simple shading, no interior detail. Model's long axis is X.
- **113053967699143 "Realistic Police Car Cop City Pursuit RP" (KingJames_the67) — 2/5.** **Correction to 0003:** this is NOT the Explorer-style SUV; it is a blocky black part-built sedan (185 plain parts, 0 MeshParts) with bar lightbar, "POLICE" text and an **Ohio State Highway Patrol hood decal** (real agency livery). 14×9.3×27 studs — oversized. 0 wheel candidates by name, 5 seats, 13 scripts removed. Looks like a 2010-era build; not GTA-grade. The Explorer SUV seen in the 0003 lineup is actually **16390639371** (deep-dived below).
- **16390639371 Police Interceptor Utility (reachin4stars) — 5/5 looks.** Excellent 2020 Ford Explorer PIU: push bar, lightbar, antenna, spotlight, full "CITY OF CLIFTON POLICE" livery with unit number. 8.9×6.4×19 studs (correct). 4 clean wheel candidates, 4 seats, **114 scripts removed** (heavy ELS/chassis). Top-level model oddly named "T488". **Ford oval badges + real-looking city livery** (Clifton, NJ) — replace livery for our city. Orientation correct. (Added to this job: the real Explorer from 0003, see correction above.)
- **103123587729335 French police hatch (StarNeon5292) — 4/5.** Peugeot 308-style "POLICE NATIONALE" car: good proportions, visible interior + steering wheel, lightbar. **Stray grey antenna/flat part sticks out of the roof at an angle** (needs deleting). 10.2×8.9×18.9 studs (bounds inflated by that stray part). 28 wheel candidates, 3 seats, 5 scripts removed; internal name "LeoRosa44's Car". **Real French national-police livery** — wrong country for a US city; useful only as a body after repaint. Orientation flipped (front.png = rear).
- **131180706902259 Box truck (ElijahStar9036) — 4/5 looks, but 1/5 for our rig.** Very realistic Isuzu NPR-style box truck with PBR-ish weathered box, open roll-up door and lift gate. However it is a **single baked MeshPart** (3 parts total, "TruckProp"): wheels are part of the body mesh, so they **cannot spin separately**; no seats. 9.1×12.2×25.5 studs (correct). Good as a parked prop only. No visible brand badges. Orientation flipped.
- **97965573521866 "Mercedes sedan" (nov4_gg2010) — 5/5 looks.** Actually a **Mercedes-AMG GLE 53 Coupé** (SUV-coupé, not a sedan): Panamericana grille, LED headlights, panoramic roof, quad exhausts, visible interior. 17.9×6.1×9 studs (correct). 4 clean wheel candidates, 4 seats, 25 scripts removed. **Large Mercedes star badges + "GLE 53" lettering.** Orientation correct.
- **132078381973405 2010 Toyota Prius (Xz_SilvervBCelestial) — 5/5 looks.** Spot-on 3rd-gen Prius: correct silhouette, split rear glass, antenna, California plates, visible interior. 7.4×5.9×16 studs (correct compact scale). 4 clean wheel candidates, 1 seat, 3 scripts removed, 6 textures. **Toyota badges** front/rear + real-format CA plates. Perfect GTA "Dilettante" stand-in. Orientation flipped.
- **3204824887 Chrysler ME412 (VloneDerrick) — 4/5.** Accurate ME Four-Twelve concept-supercar shape, detailed wheels and lights, quad exhausts. Body has a strong **chrome/reflective look** (reads as silver-blue liquid metal; needs a paint override). Only 30 parts (16 MeshParts) — very cheap. 19.3×5.1×10.1 studs (correct). 4 clean wheel candidates, 2 seats, 64 scripts removed (old A-Chassis). Small Chrysler wing badge. Concept car → effectively unbranded in-game. Orientation correct.
- **951086064 2009 Nissan Maxima (turbo_isaac) — 3/5.** Correct 7th-gen Maxima shape, but the paint has **blotchy baked-in lighting/reflection artifacts** (white smears on lower panels) that look wrong in daylight. 18×5.5×8.3 studs (correct). 16 wheel candidates, 4 seats, **71 scripts removed** (A-Chassis). **Nissan badges.** Orientation flipped.

### B. New searches

#### muscle car
- **1535662448 "1978 Charger (Sapphire County)" (jediboy48) — 4/5.** Actually a **1968 Dodge Charger R/T** (internal name): correct coke-bottle body, hidden-headlight grille, twin round tail lights, custom wheels. Paint has a pink→red gradient sheen (odd but repaintable). 22.6×5.9×9.3 studs (correct). 8 wheel candidates, 3 seats, 49 scripts removed. Small Dodge script badges. Orientation correct.
- **4464423273 "Camaro Z28" (Elrold100) — 4/5 as a body shell.** 1969 Camaro **body only: no wheels, no interior, no seats, 0 scripts**, 14 MeshParts. Accurate shape, chrome bumpers, glowing tail lights, smooth single-colour paint (`0989cf`-like blue) → **ideal for our "cosmetic body + our own wheels" rig** (wheel arches are empty). 9.3×5.3×22.6 studs (correct). No visible badges. Orientation correct.
- **16219472699 "Classic Mustang" (NotSoFamousBurger) — 5/5 looks.** Superb 1969 Mustang Mach 1 / "Boss" fastback: hood scoop, triple tail lights, Magnum 500 wheels, visible interior. 19.5×5.6×9.1 studs (correct). 12 wheel candidates, 2 seats, 17 scripts removed, 6 textures. **Running-horse grille emblem + "MUSTANG" rear lettering.** Orientation correct. Best muscle car found.

#### supercar / hypercar
*(Only 2 of the 6 results are actual cars — the rest are "car spawner" hangout kits and a whole dealership map.)*
- **2954088185 Koenigsegg Regera bodykit (brutalfrog71) — 4/5.** Recognisable Regera with widebody kit, big rear wing, centre exhaust, black 5-spoke wheels. Flat pale-blue paint with no reflections looks a bit clay-like; opaque black glass, no interior. 20.7×4.6×10.4 studs (correct). 12 wheel candidates, 1 seat, 49 scripts removed. Small Koenigsegg nose badge. Orientation correct.
- **116049719671074 2021 Koenigsegg Jesko (haydenuHand777) — 5/5 looks.** Superb Jesko: huge swan-neck wing, carbon aero, detailed open cockpit interior, red calipers. **Neon-yellow accent strips** (aftermarket-style underglow bits) — removable. 9.3×5×18.1 studs (correct). 24 wheel candidates, 1 seat, 19 scripts removed. Koenigsegg shield badges. Orientation correct. Best hypercar found.

#### hatchback
*(Only 2 plausible hatchbacks; the other results were SUVs or untitled builds — the yiypoo1024 Pontiac Torrent that appeared here is covered in the creator section.)*
- **8302262160 Hungarian Seat León (Superroblox4387) — 3/5.** Correct 3rd-gen León Mk3 shape and alloys, but **saturated purple-blue glass**, a slightly lumpy body (visible panel seams/creases) and a white wheel-arch artifact on the front-left. 8.6×6.1×18.2 studs (correct). 4 clean wheel candidates, 4 seats, 39 scripts removed. **SEAT badges, "LEON" lettering, Hungarian plates.** Orientation correct.
- **5039284025 "Daily Driver" (iilikethecolorredii) — 5/5 looks.** A **Hyundai Veloster N**: tuned with spoiler, diffuser, white multi-spoke wheels, visible interior; great orange paint. 9.1×6×18.2 studs (correct). 8 wheel candidates, 4 seats, 55 scripts removed (A-Chassis, top-level "a-chassis"). **Hyundai + "N" badges**, NJ-style plate. Orientation flipped. Best hatchback found.

#### coupe
- **15039920309 2010 Edy Sport Coupe (ki7rill) — 4/5.** The Roblox "Good Ol' car" made realistic: generic, **unbranded** sporty coupe (Infiniti-ish), mesh grille, visible interior seats, twin exhausts, 16 textures. Dark matte two-tone paint. 8.7×5.5×17.1 studs (correct). 14 wheel candidates, 4 seats, 21 scripts removed. **No real brand badges** — a big plus. Orientation correct.
- **86338034228651 Mercedes W215 CL (Mirosyaplayer) — 3/5 looks, 1/5 for our rig.** Recognisable CL500 coupe with baked photo texture (PS2-era game-rip look; texture stretches on bumpers). **Single MeshPart** (1 part, 0 scripts) — wheels are baked into the body, can't spin; no seats. 19×5.6×6.7 studs (narrow). **Mercedes star badges.** Prop only. Orientation correct.
- **448250824 2004 Lexus SC430 (9ive) — 2/5.** Recognisable SC430 silhouette but built from **759 faceted wedge parts** (0 MeshParts) — visibly polygonal surfaces, opaque black glass, no interior. Heavy part count for the look. 16.5×5.2×8.9 studs (correct). 4 clean wheel candidates, 4 seats, 17 scripts removed. Lexus badges. Orientation flipped. Not GTA-grade.

#### convertible
- **136245297270332 "monza sp1" (roblox679576) — 3/5 (shape 5/5, unusable as-is).** A very detailed **Ferrari Monza SP1** mesh (389 MeshParts, full cockpit) — but **untextured grey (clay) and ~25× oversized: 218.9×116.1×465.4 studs**, sitting on its own flat base plate. Would need rescale + full material pass. 29 wheel candidates, 8 seat-named parts, 0 scripts. The far camera (from the huge bounds) sits in the haze; shots are as returned by ANALYZE. Prancing-horse badge.
- **14966756602 Volattolo Stradagna [Convertible] (HectorBrantts) — 5/5 looks.** A **fictional brand** grand-tourer convertible (Maserati/Ferrari-ish) — exactly GTA's approach: full tan leather interior with steering wheel, chrome wheels, quad exhausts, diffuser, CA-style plates. 21×5.9×9.3 studs (correct). 34 wheel candidates, 4 seats, **91 scripts removed**, **532 textures** (heavy). **No real brand badges.** Orientation correct. Best convertible — top pick for unbranded realism.
- **182994215 Honda S2000 (autorun) — 2/5.** 2010-era part-built S2000 (579 wedge parts, 0 MeshParts): blocky, faceted, red sport seats, twin exhausts, blank plates. Bounds 14.9×5×16.1 — nearly square because extra wheel/chassis parts widen X, so ANALYZE's cameras land almost **dead-rear / dead-front** rather than 3/4. 44 wheel candidates, 1 seat, 1 script. Not GTA-grade.

#### luxury sedan
- **14115238067 "TD2 Mercedes-Benz S-Klasse" (terran4629) — 4/5 cars, but it's a scene.** Not one car: a **dressing pack** with 2+ sedans side by side (one marked "( Drivable)"), a pine-tree clump and a ground slab, 107.7×69.1×467.9 studs overall. The sedans themselves are good **fictional-looking** luxury saloons (Lincoln/Maybach-ish grille, generic badge), visible tan interiors, clean white paint, ~18 studs long. ANALYZE's cameras for 468-stud bounds sit in the haze, so **both shots were framed by hand** on the front pair: front (29935,9,30250)→(29956,2.5,30222), rear (29978,9,30195)→same. 36 wheel candidates (multiple cars), 6 seats, 33 scripts removed, 147 textures. Extract one sedan before use.
- **11229830669 "1999 Mazda 626 decor" (Ernest_Olegovych) — 2/5.** Actually reads as a Lexus GS-style black sedan; **single low-poly MeshPart with a blurry baked photo texture** (game-rip look, smeared windows). 6×5×16 studs (a little narrow). No separable wheels, no seats, 0 scripts — background prop at best.
- **108455212286316 2016 Buick Enclave (deleted account) — 3/5.** (Search returned it for "luxury sedan"; it's a crossover.) Good shape, sunroof, waterfall grille, black alloys, but the white paint has a **dirty/weathered baked texture** (grey smudges everywhere) — reads as a beater. 22.4×8.9×11 studs (correct). 4 clean wheel candidates, 4 seats, 32 scripts removed, 13 textures. Buick tri-shield badges. Orientation flipped.

*(Luxury-sedan class verdict: no clean GTA-grade luxury saloon on the free store; best usable sedan bodies are inside the S-Klasse pack 14115238067.)*

#### motorcycle / sport bike
- **10655506812 2008 Honda CBR1000RR Fireblade (itsurboi_rocky) — 5/5 looks.** Excellent superbike: fairings, visible engine/frame, brake discs, under-seat exhaust, tinted screen. Green paint. 8.3×5.9×4.3 studs (bounding box includes kickstand/side parts; ~8 long is right). 17 wheel candidates, 1 seat, 28 scripts removed. **Honda wing + "CBR" fairing lettering.** Orientation flipped.
- **15104621740 "CoD MW2CR Honda CBR 600 RR" (ALEXMACAU123HANDq) — 4/5 looks, IP risk.** A **ripped Call of Duty: MW2 Remastered asset** (per its name): photoreal textures (4), dirty white fairing, plate "91436", kickstand. Only 4 MeshParts, 0 scripts. 7.7×4.9×7.9 studs (bounds near-square → ANALYZE cameras land dead-front/dead-rear). 1 wheel candidate, no seat. **Third-party game rip — do not ship.**
- **3106453266 "Leaked YZF 600" (nessetruquesomos2) — 4/5.** Actually a **Yamaha YZF-R1** in the Fiat-Yamaha MotoGP livery (internal "R1 da fiat"): detailed frame, swingarm, under-tail twin exhausts, paddock stand. 2.4×4.3×7.4 studs (correct). 6 wheel candidates, 1 seat, 23 scripts removed. **Heavy real sponsor branding (FIAT, Yamaha)** — needs a livery swap. Orientation flipped. Name says "Leaked" → provenance questionable.

#### city bus
*("realistic city bus" returned only bus stops; re-searched as "transit bus vehicle".)*
- **108530812148091 "B-1 Urban Transit RP Bundle Vehicle City Bus" — n/a (not a vehicle).** Turned out to be a **Thai bus-stop sign** ("บ-1 Stop", 3 parts, 3.5×7.7×0.5). JSON saved; **no screenshots taken** (nothing to review).
- **92681966699882 Urbanmove MAZ G bendy bus (Deutschebahnee) — 3/5.** Articulated city bus (59.5 studs long, 8.2 tall — correct), white/blue livery, modelled interior seats and yellow poles, doors. Mostly plain parts (693 parts, 2 MeshParts) — boxy at close range. 16 wheel candidates, 19 seats, 52 scripts removed. Includes a **purple spawn pad + "MAZ By Deutschebahnee" credit label** part (delete). Usable as a background bus.
- **101096217347341 Indonesian "Jetbus 3+" coach (deleted account) — 4/5 looks, wrong type.** Detailed Adiputro Jetbus **intercity coach** (not a city bus): bug-eye mirrors, LED strips, 24 modelled seats, 165 MeshParts. 13×16.2×52.4 studs (tall — bounds include mirrors). 4 wheel candidates, **115 scripts removed**. Asian-market look; fine as a tour coach. Orientation correct.

*(City-bus class verdict: no GTA-grade US transit bus on the free store; the MAZ bendy is the only true city bus.)*

#### ambulance
- **72885213582530 "Ambulance (Mesh)" (itzEmberNation19) — 4/5 looks, 1/5 for rig, IP risk.** Photoreal weathered Type-III box ambulance with open rear/side doors, star-of-life, "AMBULANCE PARAMEDIC" — almost certainly the **Left 4 Dead ambulance** (same as the "[Left 4 Dead] Ambulance" result). **Single MeshPart** (wheels baked), no seats, 6 scripts removed. 11×8.7×24.9 studs (correct). Prop only; don't ship (game rip).
- **440172126 "Ambulance [FREE]" (DaliuagTeam) — 1/5.** Blocky 2016-era part-built van with "AMBULANCE" text decals and flat red blocks for lights. 14×8.7×21 studs, 97 parts, 0 MeshParts, 4 seats, 18 scripts removed. Not usable.
- *(Third result "Realistic Ambulance" 36891059 is a 2007 brick build and "[Left 4 Dead] Ambulance" 15571667425 duplicates the L4D rip above — skipped. Ambulance class verdict: **no shippable realistic ambulance**; commission or model one.)*

#### fire truck
- **130400317438495 Fire Truck (deleted account) — 4/5.** Convincing Freightliner Business Class–style 6×4 fire engine (tanker/rescue body): roof monitor, lockers, white stripes, detailed grille and wheels. Clean 18-MeshPart build (one mesh per component), 9.8×12×34.6 studs (correct). 4 wheel candidates (separate wheel meshes — good for our rig), no seats, 2 scripts removed. No visible brand badge. (Same mesh also uploaded as 88510772704190.) Orientation flipped. Best fire truck.
- **97675679051639 "[FREE] Fire Truck" (Madis0nLi0n5722, "made by @REWQ") — duplicate.** ANALYZE output is **byte-for-byte the same geometry** as 130400317438495 (18 parts, 9.8×12×34.6, same cameras) → same mesh re-uploaded (3rd copy with 88510772704190). JSON saved; shots skipped as they would be identical.
- **11688323025 "New Blueprint City Engine" (WVUPick) — 5/5 looks.** Superb US custom-cab pumper (Pierce-style): "Blueprint City" / "Fire & Rescue" / E-4 livery (fictional city — good), hose bed, ladders, diamond-plate, lightbar, pump panel, interior with gear. 766 parts (142 MeshParts), 182 textures, 29.7×10×13.6 studs bounds (length on X). 22 wheel candidates, 5 seats, 68 scripts removed. Best GTA-style fire engine; rebrand "Blueprint City" to ours. Orientation flipped.

#### SWAT van / armored truck
- **4732920221 SWAT Van (NorthAmericaOperator) — 2/5.** Blocky part-built black box truck with "SWAT" stencils, neon lightbars and a ram/ladder rack. 211 parts, 0 MeshParts, 26.8×11.7×12.4 studs (length on X), 6 seats, 6 scripts removed. Reads as Roblox-classic, not GTA.
- **11155605490 "MeshPart swat car very good" (kaikomarkus) — 5/5 looks, 1/5 for rig.** Photoreal **Lenco BearCat-style armored truck**: gun ports, push bumper, roof rails, "S.W.A.T." + shield decals baked into the texture. Almost certainly a game rip (GTA-V-like look). **Single MeshPart** (wheels baked), 0 scripts, no seats. 29.5×11.9×12.5 studs (correct). Great parked prop; provenance unknown — avoid shipping.
- **6590911334 "Armored Van" (ruger94) — 4/5.** A **2016 Ford Transit high-roof** (internal name) with push bar and **bronze/brown armour plating** on the sides, window louvre shutters. Good mesh body (102 MeshParts), detailed front, tow hitch. Some lights are left on (neon/pink glow spill on ground). 20.1×8.8×8.7 studs (correct). 4 clean wheel candidates, 1 seat, **90 scripts removed**. **Ford oval badges.** Orientation flipped. Best SWAT/armored option that has separable wheels.

#### tow truck
- **4908467941 "Wrecker F-250 XLT" (Koquains) — 5/5 looks.** Actually a **Chevy Silverado 3500 crew-cab wrecker** (despite the name): diamond-plate body, wheel-lift boom, dolly wheels, lightbar, company door decal. 312 parts (35 MeshParts), 12.2×9.2×26.1 studs (correct). 30 wheel candidates, 5 seats, **109 scripts removed**. **Chevy bowtie badge.** Orientation correct. Best tow truck.
- **3584156538 "Wrecker 2012 Siveeeradooooo" (blue_wolfpack1) — duplicate.** Same model as 4908467941 (identical internal name "NTA | Wrecker F-250 XLT", 312 parts, 109 scripts, same bounds) → re-upload. JSON saved; shots skipped.
- **5651733172 "1997 Tow truck" (fadesteeles) — 3/5.** Freightliner FL70-style medium-duty wrecker: boom, wheel-lift, lightbar, chrome wheels; all-white, mostly plain parts (683 parts, 42 MeshParts). Decent silhouette, flat look. 32.5×11.1×11.8 studs (length on X). 16 wheel candidates, 1 seat, 61 scripts removed. Freightliner grille badge. Orientation correct.

#### limousine
- **13086837324 "Movie Limo" (TornadoBoy1two) — 4/5.** Cadillac DTS stretch limo: correct grille, tail lights, long window line, sunroof. Black paint has a **noisy/crinkled texture** (looks slightly rough up close). A separate **blue spawn/sign part** sits beside the car (bounds 34.4×6.4×18.3 include it; delete). 48 parts (16 MeshParts), 4 clean wheel candidates, 6 seats, 28 scripts removed. **Cadillac crest.** Orientation flipped.
- **4232019061 2007 Lincoln Town Car Limousine Lowrider (NARSCATT) — 5/5 looks.** Excellent stretch Town Car, slammed on **chrome wire wheels** (lowrider style), blue interior LED strips, glossy black paint, chrome trim. 187 parts (75 MeshParts), 9.4×5.3×32.7 studs (correct). 11 wheel candidates, **10 seats**, 16 scripts removed. Lincoln star badge. Orientation correct. Best limo — **also counts for the lowrider class**.
- **12651678223 "Police Limo" (roblocraft1432) — 4/5.** Town Car stretch limo with push bar, two lightbars and rear strobes — a fun GTA-ish oddity. Clean body (83 MeshParts), 33×6.1×9.2 studs (correct). 4 clean wheel candidates, 9 seats, 16 scripts removed. Lincoln badge. Orientation flipped.

#### lowrider
*(Results were mostly 2008-era brick builds and a "Fortnite Lowrider" rip; the best lowrider found is the Lincoln Town Car limo-lowrider 4232019061 above. Adding one more candidate below.)*
- **13791818186 "Impala 64 SS (Lowrider)" (Powering_BaconYT) — 5/5 looks.** The Folder holds **two '64 Impala SS lowriders** (one posed mid-hydraulic-hop, one parked): candy-purple paint, gold/chrome wire wheels, chrome trim, full interiors — pure GTA San Andreas vibe. 403 parts (205 MeshParts), bounds 34.7×15.1×20.9 because of the two cars (each ~20 long). One car has a **pink underglow light** left on. 17 wheel candidates, 4 seats, 31 scripts removed. Chevy badges. Extract one car. Best dedicated lowrider.

#### garbage truck
- **9186961939 "Waste Management Garbage Truck" (TrashManHugo) — 5/5 looks, IP risk.** Mack TerraPro rear-loader with tri-axle, compactor tailgate, ladders, reflective stripes — superb. Description admits it's **a copy of a Hum3D model** (paid 3D-model store) → **licensing risk**, and it carries the **real "WM" Waste Management logo**. 252 parts (251 MeshParts), 0 scripts, no seats. 28.4×10.7×8.6 studs (correct). 26 wheel candidates. Orientation flipped.
- **5245087628 "Garbage Truck Realistic" (chips611) — 4/5 looks.** Weathered white Autocar-style **front-loader** with raised forks, photoreal grimy textures — very GTA (looks like a game rip; GTA V's Trashmaster-adjacent). 21 MeshParts, **no named wheels / no seats / 0 scripts** — wheels are fused meshes, not separable. 9.7×15.5×33.6 studs (correct; forks raise height). No brand logo. Good prop.

*(Third candidate 9180335501 "Garbage Truck" is the same uploader's Hum3D copy as above — skipped.)*

#### police sedan (Crown Victoria / Charger)
- **12444544835 1998 Crown Victoria P71 LAPD (LosAngelesP_D) — 5/5 looks.** Exactly the GTA "Police Cruiser": black-and-white LAPD livery, MX7000 lightbar, roof number "00", push-free classic look, interior with cage. 200 parts (173 MeshParts), 16 textures, 8.9×6.3×20.7 studs (correct). 14 wheel candidates, 5 seats, 65 scripts removed. **Real LAPD seal/"to protect and serve" livery + Ford badges** — reskin for our city. Orientation correct. Best police sedan.
- **11511132434 "2016 Charger Police Car" (SkanskvarnAccount) — 0/5 (broken).** Only the **lightbar/neon light-strip parts load** (top-level "Lightbar", 28 parts, 11 MeshParts) — the car body is missing (unloaded/removed mesh assets). Front shot kept as evidence of the empty result; rear skipped.
- **18853303033 2011 Crown Victoria Police Interceptor (Kai_TheCoolGuy122) — 5/5 looks, best for us.** Clean **slick-top, livery-free white P7B** (spotlight, steel wheels, push-bar-less) — a blank canvas for our own police/taxi/civilian paints. 164 parts (123 MeshParts), 20.9×5.9×8.7 studs (correct; length on X). 12 wheel candidates, 4 seats, 37 scripts removed. Ford ovals only. Orientation flipped.

### C. Creator yiypoo1024
*(`search_asset` has no creator filter, and searching the name only returns spam that mentions it. Instead I searched by model names typical of their catalogue and picked results whose `creatorName` = yiypoo1024. Shortlist cars from them already covered: Sorento 117276253886376, Murano 73893179863762; Mariner 138255866612822 was a 3-part 2/5 in 0003.)*
- **15374723303 "2008 Pontiac Torrent" (yiypoo1024) — 2/5.** Low-poly faceted crossover in flat saturated blue (internal name "2008 Pontiac Outlook"), only 3 MeshParts — much cruder than their Sorento/Murano. Bounds 19.1×7.9×22.7 are nearly square (an extra chassis part), so ANALYZE's cameras came out **side-on** rather than 3/4. 8 wheel candidates (Goodyear-lettered tyres), 5 seats, 14 scripts removed.
- **104259035462682 "2006 Pontiac Grand Prix" (yiypoo1024) — 2/5.** A **photogrammetry scan** (single MeshPart with baked ground patch under it): real-world texture detail, but the **roof/glass is missing/melted** (scan holes) and the car sits on a scanned slab of pavement. 17.2×4.7×7.5 studs. No wheels/seats/scripts. Interesting as a wreck prop only.
- **83151379176711 "2007 Pontiac Montana" (yiypoo1024) — 2/5.** Another **photogrammetry scan** on a scanned pavement slab: realistic paint and wheels, but **holes in roof/rear glass**, melted upper body. Also **under-scaled: 13.8×4.8×5.8 studs** for a minivan (~30% small). Single MeshPart, no wheels/seats/scripts. Wreck/abandoned-car prop only.
- **70649312292255 "2009 Pontiac Vibe" (yiypoo1024) — 2/5.** Photogrammetry scan again (same style): very real texture/wheels, **torn roof and windshield holes**, scanned ground slab. 9.4×7.4×19.4 studs (correct scale this time). Single MeshPart, no wheels/seats/scripts. Wreck prop only. Pontiac badge.
- **83139935191956 "1998 Hyundai Elantra" (yiypoo1024) — 2/5.** A **Sketchfab photogrammetry import** (top-level "Sketchfab_Scene", 6 MeshParts, 6 textures): realistic scuffed paint, two-tone panels — actually reads as a ~2004 Elantra XD. **Badly under-scaled: 5.2×1.7×2.2 studs** (needs ~3.5× scale-up). No wheels/seats/scripts. Texas-style plate.

**yiypoo1024 verdict:** their realistic catalogue is **mixed**. The Sorento (4/5) and Murano (4/5) are clean, proper car models. The rest of what turned up are **photogrammetry scans** (Grand Prix, Montana, Vibe, Elantra): real textures but holes, baked ground slabs and wrong scale, so wreck props only. The Torrent is low-poly. Not a reliable "realistic creator" after all.

## Summary for the lead

**Top picks for the cosmetic-body rig (5/5 looks, separable wheels, sane scale):**

| Role | Asset | Notes |
|---|---|---|
| Sports | 11881862706 Jaguar XKR-S GT | cleanest structure: `Wheels.FL/FR/RL/RR`, `DriveSeat`, blue paint group `0989cf` |
| Hypercar | 116049719671074 Koenigsegg Jesko | detailed cockpit; strip neon-yellow accents |
| Muscle | 16219472699 Classic Mustang ('69 fastback) | |
| Muscle (body shell) | 4464423273 Camaro Z28 | **body only, no wheels/scripts** — ideal for our own wheels |
| Hatch | 5039284025 Veloster N ("Daily Driver") | |
| Compact | 132078381973405 Prius | |
| SUV | 97965573521866 Mercedes-AMG GLE 53 Coupé | |
| Truck | 89890547548224 Ford F-150 SuperCrew | |
| Convertible | 14966756602 Volattolo Stradagna | **fictional brand**; 532 textures (heavy) |
| Coupe (unbranded) | 15039920309 Edy Sport Coupe | no real badges |
| Police SUV | 16390639371 Explorer PIU | real "Clifton" livery → reskin |
| Police sedan | 18853303033 2011 Crown Vic (**blank white slick-top**) / 12444544835 1998 LAPD P71 | |
| Limo / lowrider | 4232019061 Lincoln Town Car limo-lowrider; 13791818186 '64 Impala pair | |
| Tow | 4908467941 Silverado wrecker | |
| Fire | 11688323025 "Blueprint City" pumper (fictional livery); 130400317438495 18-mesh 6×4 | |
| Motorbike | 10655506812 Honda CBR1000RR | |
| Armored | 6590911334 Transit armored van (separable wheels) | |

**Avoid / props only:**
- Single-mesh bodies with baked wheels: box truck 131180706902259, W215 86338034228651, Mazda626 11229830669, L4D ambulance 72885213582530, BearCat 11155605490, front-loader 5245087628, yiypoo scans.
- Game/IP rips: CoD CBR600 15104621740, L4D ambulance, WM garbage truck 9186961939 (a Hum3D copy).
- Broken: 2016 Charger 11511132434 (lights only).
- Duplicates: 97675679051639 (copy of 130400317438495) and 3584156538 (copy of 4908467941).
- Oversized or scene packs: Monza SP1 136245297270332 (25×, clay); S-Klasse 14115238067 (multi-car scene).

**Gaps with no shippable free asset:** ambulance, US city bus and luxury sedan. Plan to model these.

**Branding:** almost every good model carries **real badges or liveries** (Ford, Chevy, Nissan, Mercedes, Jaguar, Koenigsegg, LAPD, Ohio SHP, WM, FIAT). The rig should hide or retexture badge meshes. The cleanest canvases are the Stradagna, the Edy coupe, the 2011 Crown Vic, the Blueprint pumper and the Camaro shell.

**Structure notes for the rig:**
- `wheelCandidates` is reliable when a model groups its wheels (Jaguar, Murano, Explorer, Maxima, Prius, GLE). It overcounts when each wheel is split into rim, tyre and hub meshes (Sorento 24, Stradagna 34, S2000 44).
- 0 candidates means the wheels are fused into the body (single-mesh models) or the model has no wheels (the Camaro shell).
- `colorGroupsByArea[1]` is often dark trim or glass, not paint. Pick the paint group as the largest non-black SmoothPlastic/Metal entry.
- Orientation varies by model (~half are flipped), so normalise using the seat or `DriveSeat` direction, not `LookVector`.
