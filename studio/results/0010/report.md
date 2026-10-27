# Job 0010 report: Creator Store scout, round 2 (15 categories, 75 assets)

- **Studio:** 0.744.0.7441077, Hotwire City place, **Edit mode only**. Play was never started, and the place was **not saved or published**.
- **Method:** the same as job 0003.
  - For each category, insert the top 4–5 realistic results into `Workspace.HCScout.<cat>`.
  - The layout script deletes all LuaSourceContainers (**174 scripts removed across 75 assets**), anchors parts, and lines the assets up on a concrete pad at x≈20000 with BillboardGui labels.
  - Shots per category: a closer lineup (≈1.2× lineup width; I re-shot from further back where it cropped) and two close-ups of the best picks.
  - Some assets came in facing ±X or away from the camera; I yawed those in place. Each section notes it.
- **In the lineups, +X is screen-left:** the first-listed asset sits at the right.
- **CLEANUP:** done and verified.
  - `workspace.HCScout` was destroyed; the Workspace is back to Camera, Baseplate, Terrain and SpawnLocation.
  - All `_G` helpers are cleared and the local JSON receiver is stopped.
- **Files:**
  - `scout.json`: one row per asset with category, assetId, name, creator, parts/meshParts/textures, scriptsRemoved, size, `verdict` (1–5) or `flag` (`duplicate`/`avoid`), and the note.
  - `raw/`: the layout dumps.
  - `<cat>.png`, `<cat>_close1.png` and `<cat>_close2.png`, plus extras named in each section.
  - `console.txt`: Studio Output via LogService.

## Top picks (5/5 and 4/5)

| Category | Use this |
|---|---|
| Broadleaf trees | Letaij `98950444096614`, `128707014921507` |
| Conifer / desert | Ponderosa `130515502281374` (5), desert pack `16420171681` |
| Hedges / grass | tall hedge `131155630187030` (scale down), overgrown grass `3123069623` |
| Palms | **California Palm `130498222865089` (5)**, the original upload |
| Traffic signs | **MUTCD stop sign `9777090830` (5)**, stop sign set `1759519597` (scale ×0.7) |
| Freeway signs | cantilever exit sign `125125263118068`, Arizona truss gantry `9335428697` (new decal) |
| Barriers / fences | **10-fence PBR pack `100583941159955` (5)**, jersey barrier `82454061017921` |
| Street utility | USPS mailbox `109766012790297`, wooden utility poles `15591157798` |
| Street furniture | cast-iron PBR bench `120611959432681`, bollard pack `115942669533764` |
| Retail | payphone booth `4900193185` (swap the Bell logo) |
| Billboards | **L-monopole catwalk billboard `11120580589` (5)**, light 2-board pack `13612217686` |
| Construction | tower crane `119266200526586` |
| Beach | **LA-County lifeguard tower `10969289501` (5)** |
| Rooftop | **Carrier RTUs `18336727555` / `18290346289` (5, but heavy: 319 and 762 parts)** |
| Garage | **two-post car lift `122655307130669` (5)**, tyre rack `10735214840` |

## Avoid
- **Re-uploads with extra scripts (backdoor pattern):**
  - `139707403949260` (a re-upload of `16050465137`).
  - `84675437585887` (palm).
  - `85561539493986` (exit sign; same decal as `130503679586961`, 5 scripts against 2).
- **Ripped IP:** `10551450435`, the "Left 4 Dead ice machine" ("All credits go to valve").
- **Not what the title says:** `6693814769` "construction Barricade" is a trailer plus 2 NPC rigs, with 10 scripts.
- **Trademarks to retexture before use:** the ESSO pump `8368863281`, the Bell logo on payphone `4900193185`, and the "Snap-on" name on `146685916`.

## Gaps: build in-house
- **Signs:** US one-way and street-name blades, a Caltrans-style multi-panel overhead sign.
- **Street furniture:** planters, a city litter bin, a US single-head parking meter, a ground utility or signal cabinet.
- **Construction:** Type III striped barricades and A-frames.
- **Beach:** pier railing and boardwalk lamps.
- **Garage:** a workbench and garage shelving.
- Also missing: an ice machine and an ATM that works. The only non-emoji ATM, `129016349900455`, renders untextured white at 3× size, probably because its textures are archived (see Console).

## Other findings
- **Store "No scripts" descriptions are wrong.** At least 10 assets whose auto-description says "No scripts" had scripts:
  - 2 scripts each: `125125263118068`, `72836863954838`, `71204529991089`, `120611959432681`, `136386088614829`.
  - 4 scripts: `82002680152727`. 6 scripts: `79571080572612`. 8 scripts: `119266200526586`.
  - Never trust the description; always run the sanitise step.
- **Script-heavy but legitimate:** the Carrier RTUs have 28 and 57 scripts (fan, sound and economiser logic), all stripped here.
- **Scale outliers:**
  - Traffic cone `83471113389608` (1 stud, needs ×2.3).
  - Snap-on cabinet (×0.5).
  - Tall hedge (scale down).
  - Stop sign set (×0.7).

## Console (`console.txt`, 57 lines)
- **2 errors**, both harmless: `Failed to parse TexturePack` in a SurfaceAppearance of the PBR bush `87442220098670` and the tyre rack `10735214840`. These are asset-side, and the meshes still render.
- **Archived textures:** `rbxassetid://7177387461` and `7177402591` "Requested asset is archived", logged at 21:13:39 while the retail props were inserted. These are almost certainly the ATM's textures.
- **Pre-existing place noise, unrelated to this job:**
  - 43 "Asset type does not match" warnings from v1 asset IDs.
  - `81504106` not found (Shopkeeper hat).
  - `4542793421` not authorised.
  - Rojo `Could not swap instances Lighting` and a Rojo precommit-hook warning.

## Verdicts by category
### 0 veg_trees_broadleaf
- **4/5** `98950444096614` (PBR) Realistic Oak Trees Pack (Letaij) — 6 trees, 15 MeshParts, 21 textures (PBR leaves/bark), varied young oaks; best variety. Pack bounds 97×44×129 — split into singles. *(close1)*
- **4/5** `128707014921507` Realistic Oak Tree (Letaij) — mature 24-stud oak, dense dark canopy, textured bark, nice shadow. Only 3 parts. *(close2)*
- **3/5** `16050465137` Realistic street tree (Lydnexx) — slim 32-stud street tree with a tree-pit grate; lighter canopy, fine for sidewalks.
- **❌ avoid** `139707403949260` "Realistic Street Tree Park City…" (deleted account) — **identical geometry to 16050465137 + 8 scripts** (backdoor re-upload pattern).
- **3/5** `96364607340216` Realistic Tree Optimized (Zetureta502) — small 16-stud dark tree, 2 parts; filler.

### 1 veg_trees_conifer_desert
*(Searched pine, cypress, and cactus / Joshua tree / desert. "Cypress" only returned identical swamp bald-cypress packs from four spam accounts, so I skipped it. No Joshua tree turned up.)*
- **5/5** `130515502281374` Ponderosa Pine Tree Pack (Letaij) — about 12 PBR conifers with realistic needles and bark, varied heights. Excellent for hillsides and the outskirts. *(close1)*
- **4/5** `16420171681` desert pack (Axlender579) — tall saguaros, agave, yucca, prickly pear, tumbleweed and a red boulder. Textured meshes that read like real Mojave scrub. *(close2)*
- **4/5** `113109119460825` [PBR] Red Cedar Pine Tree (Letaij) — one 39-stud conifer with 80 texture objects (heavy).
- **3/5** `107812886550854` PBR Desert Plants prefab — a cactus garden on a sand slab, with 4 scripts removed. Nice plants, but it comes as a diorama.
- **2/5** `73454171742334` Big Realistic Pine tree (StoneSymmetry) — 90 studs tall, sparse, with **exposed roots floating above the ground** and its pivot offset. Needs fixing.

### 2 veg_bushes_hedges_grass
- **4/5** `131155630187030` Tall Bush Hedge (deleted account) — dense, believable leafy hedge in PBR (6 textures). At 36 studs it is **far too tall for a hedge**; scale it to about 6–8 studs and tile it. 2 scripts removed. *(close1)*
- **4/5** `3123069623` Overgrown grass (HWO2FATRAXY) — 117 individual grass-clump MeshParts, realistic blades. Great for verges and empty lots. Heavy, so use a few clumps. *(close2)*
- **3/5** `87442220098670` PBR Bush (deleted account) — small, neat, round 6-stud shrub. Fine for front yards. 2 scripts removed.
- **3/5** `122221569536497` Bushes (Cruttch5700) — a flat, dark, low shrub mass (24×3×28) in a single mesh. Reads as a ground-cover patch. 2 scripts removed.
- **2/5** `4822789822` Flower container (RainbowPink_2) — a small raised stone planter with toy-like flowers.
- *Searching "flower bed" returned only 2009–2020 brick-built gardens. No realistic flower bed found.*

### 3 veg_palms_fan
- **5/5** `130498222865089` California Palm Tree (RewqNeveraH, credited as "made by @REWQ") — a true **Washingtonia fan palm**: 85-stud slender trunk with frond-boot bark texture, fan-leaf crown and a dry tan frond skirt. The LA street palm we need. 6 MeshParts, 2 scripts removed. Use this original. *(close1)*
- *(dup)* `138103637698436` California Palm Tree (RobloxComedy4Fun) — the same mesh re-uploaded, same 2 scripts. Use the original.
- **❌ avoid** `84675437585887` Palm Tree California Tropical Beach (EllaPrism68575) — the same mesh again, but with **4 scripts against the original's 2** (backdoor pattern).
- **2/5** `5296155885` PalmNormal1 (BigBoys_999) — a 76-stud date/coconut-style palm with **semi-transparent, low-poly fronds**; looks dated. *(close2, left)*
- **3/5** `132940973497273` Mexican Palm (NovaMiner30713) — a 17-stud young fan palm. Nice as a yard or planter palm, but too small for streets. 3 scripts removed.
- **Lineup verdict:** one excellent palm (130498222865089), but every result is the same mesh. Rotate and scale instances for variety.

### 4 signs_traffic
*Four of five came in facing away from or edge-on to the camera. I rotated them in place (`PivotTo`, yaw only) before the final lineup. `signs_traffic_prerotate.png` is the shot from before that.*
- **5/5** `9777090830` Stop Sign "MUTCD compliant" (Signmaker123456789): a real-size 2.5-stud octagon MeshPart on a thin 9.5-stud galvanised pole made of unions; crisp, correct US face. Best pick. Its front faces +Z, so rotate per corner. *(close1)*
- **4/5** `9767885480` Stop Sign (Signmaker123456789): the same creator and size, 2 parts plus decals. Good, but plainer than the MUTCD one.
- **4/5** `1759519597` Realistic Stop Sign Set (Vandicoup): **two** stop signs in one model, an older (darker, bevelled) and a newer (bright) style. They are about 1.5× real size (≈4-stud faces). Good legibility from a car, so scale them about 0.7. *(close2)*
- **3/5** `388944325` Speed Limit Signs (Scuave): a clean, legible US R2-1 "SPEED LIMIT 35" sign on a square post, at a plausible size. It is fixed at 35: the face is a single decal (`146148332`), so other speeds need new decals.
- *(dup)* `4115946048` "limite de vitesse 35": the **same decal (`146148332`) and the same 4-part model** as 388944325. Use the original.
- *I found no good US one-way or street-name sign. Search returned Malaysian street signs (`6930707141`, `127130611158664`) and joke or work-zone items. Street-name blades are trivial to build in-house as a part plus a SurfaceGui.*

### 5 signs_freeway
*The two full-width gantries span Z, so their sign faces point along ±X. In the lineup you see them obliquely from behind. `close1` is taken from +X; `signs_freeway_arizona_endon.png` is a mis-framed end-on attempt, kept as evidence.*
- **4/5** `125125263118068` Overhead Highway Sign (Content Deleted - 158552482): a single-post cantilever with a crisp green guide sign ("8 / Downtown / Santin Hills", "EXIT 1" tab) and 4 lights. It is 25×30 studs, well proportioned. The best ready-to-use freeway sign; swap the decal text for our destinations. **2 scripts removed, despite the "No scripts" description.** *(close2)*
- **4/5** `9335428697` Arizona Gantry (triggerlancy): a full-span box-truss gantry (79 studs, 48 high, 241 parts) on concrete footings. The structure looks properly real-world, but the **sign panel is a joke placeholder** ("This gantry is mostly used in Arizona…"), so replace the decal. The part count is high, so use it only at a few hero spots. *(close1)*
- **3/5** `669203168` US Highway Sign Gantry (CountryRoadgeek): a tubular arch-style gantry (88 studs) with a **blank grey sign panel**. The arch shape reads more European or light-rail than LA freeway. Usable as a frame.
- **2/5** `130503679586961` Highway Exit Sign (Content Deleted - 158552482): a small 4.8×10 roadside "EXIT" plate on two posts with a SurfaceGui "XX" label (decal `459953180`). Simple, low detail. 2 scripts removed.
- **❌ avoid** `85561539493986` "🚦 Exit Sign Highway…" (FallenzGFlashC185425): the **same decal (`459953180`) and the same 3-part model** as 130503679586961, but with **5 scripts against 2**. An emoji-title re-upload; backdoor pattern.
- **Lineup verdict:** use 125125263118068 for exit and guide signs, and 9335428697 as the hero gantry with our own decals. Nothing on the Store has real LA-style (Caltrans) multi-panel overheads; build those from the Arizona truss plus our own green panels.

### 6 barriers_fences
*`18660725012` came in spanning Z, so I yawed it 90° in place. The lineup is about 190 studs wide, so the items look small in it; judge from the close-ups.*
- **5/5** `100583941159955` Free 10 Wooden Fences – Realistic (TheAngelGaming1): ten distinct PBR mesh fences in one pack:
  - ranch rail, cross-buck, solid board-on-board privacy, stockade, white scalloped picket, lattice, low garden border and an arched garden gate.
  - Clean materials and believable proportions (≈6 studs high). No scripts, MIT-style licence text.
  - **The best suburban fence source**: the privacy board fence is exactly the LA backyard look. *(close1)*
- **4/5** `82454061017921` Concrete Jersey Barrier (0WowlionPro): one MeshPart, 15×3×2, correct K-rail profile with a flared base and a clean concrete look. Use it for freeway medians and construction. *(close2, right)*
- **3/5** `72836863954838` Highway Railing (Norefalu70): a 39-stud W-beam guardrail on posts. It is **a single part with a texture**, so the rail is flat and the posts are painted on. It reads fine at driving speed but looks flat up close. **2 scripts removed despite the "No scripts" description.** *(close2, left)*
- **3/5** `71204529991089` PS1 Chainlink Fence (Droksha9852): an 11×8 panel with a transparent chain-link texture and round posts. It reads correctly as chain-link (the "PS1" style is only in the texture resolution). Tile it for lots and freeway edges. **2 scripts removed despite the "No scripts" description.** *(close2, centre)*
- **2/5** `18660725012` Realistic Wooden Fence (High Quality) (PulsarCrow): six uneven planks with a **washed-out, almost white wood texture** across 78 textures, cartoonish. *(`barriers_fences_woodhq`)*
- *There are many "🚧 Guardrail…" emoji-title results; I skipped them as SEO re-uploads. Barbed-wire and metal picket fences were also available but are not LA-street relevant.*

### 7 street_utility
*The lineup cuts off the mailbox at the right edge; it is shown in close1.*
- **4/5** `109766012790297` USPS mailbox with a chute (Xz_Hunt3r3zAquarzS0n): a correct blue USPS collection box on legs with the eagle logo decals and the right curved-top shape. Real size (2×4×2). **3 scripts removed**: the title-SEO creator name and the scripts are a backdoor-risk pattern, so keep the stripped copy only. *(close1)*
- **4/5** `15591157798` telephone pole pack (DerpyRosegaard): three wooden utility poles, 24 studs, all MeshParts, with crossarms, insulators, step bolts and one with a pole-top transformer can. A very good LA-alley and suburb match. No scripts.
- **2/5** `3052779367` newspaper box (BanElectricVehicles): a plain red block with a small sticker; reads like a box, not a vending rack. *(`street_utility_newsbox`)*
- **2/5** `11339404249` Parking Meter (oceanicwavss): a grey block pay-station with a blue "P" panel, European style. **Not a US single-head meter.** Other results were 2014-era or emoji SEO.
- **2/5** `129781204415363` Manhole Cover (trokr341): a 6×6 square frame with an orange-rust cross-hatch cover. Too colourful and saturated, and it sits above grade. Better as a decal on the road. *(close2)*
- *No ground-level electrical or utility cabinet found: "electrical utility box" returns poles and power lines. A green transformer pad or grey signal cabinet is an easy in-house build.*

### 8 street_furniture
*Both benches came in spanning Z, so I yawed them 90°. The bollard pack arrived as a Folder; I wrapped it in a Model for the layout. The first lineup (`street_furniture_tooclose`) cropped both ends, so I re-shot it from further back.*
- **4/5** `120611959432681` Realistic Bench (Content Deleted - 158552482): one PBR MeshPart, a classic cast-iron-end park bench with warm wood slats, real size (6.8 long). Reads very well. **2 scripts removed despite the "No scripts" description.** *(close1, right)*
- **4/5** `115942669533764` Bollard Pack V1 (sirnolag): 11 PBR MeshPart bollards, 7 industrial (yellow pipe, hazard-striped, base-plate) and 4 city (white or grey with dark caps). The yellow pipe bollards are exactly what LA gas stations and lots use. The pieces ship packed tightly together, so lay them out yourself. *(close2, left)*
- **3/5** `17672221759` Realistic Park Bench (1Evynia): a single union, simple slatted bench on black legs. Decent, flatter shading than the mesh one. *(close1, left)*
- **3/5** `104284725918712` Trash Cans (XZ_WraithvDFrostbite): two rusty, dented galvanised alley cans with lids. Good for alleys, but **not a city public bin**. **3 scripts removed.** *(close2, right)*
- **3/5** `16963566733` PBR Bike Rack (EnvirobIox): a single MeshPart, a blue powder-coated grid rack, believable size. No scripts.
- *There is no realistic street planter: the "concrete planter" search returns military bastions and junk. The best paid bench, `74128359748221` "Realistic Park Bench [PBR]" at $2.99, was not inserted (paid). No city-style public litter bin found; the search returned towers and junk.*

### 9 retail_props
- **4/5** `4900193185` Phone booth (payphone) (Robloxisforbab1e5): an open-front booth with a "Phone" Bell-logo header, a lit ring light, a detailed Elcotel-style payphone mesh and a diamond-plate floor. Real size (3×7×3). Very usable. **The Bell logo is a real trademark**, so swap the decal. *(close1)*
- **3/5** `8368863281` Realistic Gas Pump (FaIseData): a 118-part pump with a nozzle, hose and pump number. Good silhouette and real size, but **branded ESSO with German "Waschstraße" decals**. That is a real trademark and the wrong locale, so retexture before use. *(close2)*
- **3/5** `9554118875` realistic vending machine (yhealle8): a black glass-front snack machine, 2 MeshParts, real size. Plain but believable. It came in facing ±X, so only the side is visible in the lineup.
- **❌ avoid** `10551450435` "Left 4 Dead ice machine" (pizzafriday17): the shape and "ICE" lettering read right, but **the description says "All credits go to valve"**. It is a ripped Valve game asset, so it is an IP risk.
- **1/5** `129016349900455` Cash ATM (RobloxModellls): a single MeshPart that renders **untextured white at 7×18×9**, about 3× real size. Unusable as-is. *All other ATM results were 💰-emoji SEO re-uploads, so I skipped them.*
- *No ice machine found apart from the ripped L4D one.*

### 10 billboards_frames
*In the lineup the camera stood just past the pad edge, so the lower third is the grey void. Left to right the boards are: the pack (two boards), the two-sided board, the K9 board, the High_Definiti0n catwalk board, then the Karl board.*
- **5/5** `11120580589` Realistic Billboard (High_Definiti0n): a full-size **L-shaped monopole billboard**, 112 studs high, 285 parts. It has a perforated catwalk with railing, a truss arm, a cylindrical beam, a ladder up the column and a blank white face. It reads exactly like an LA freeway-side billboard. Apply our ad decals to the face. *(close1)*
- **4/5** `13612217686` Billboard Pack (U5Studios): two MeshPart monopole "V" boards with catwalks and light rails, blank faces. Lighter on parts (56 MeshParts total) than the 285-part one, so the better choice for repeated roadside boards. It arrived as a Folder; I wrapped it in a Model for the layout. *(close2)*
- **3/5** `2980976799` Billboard (Identified_K9): a blank 66-stud board on a lattice tower with a catwalk. Fine as a background filler.
- **3/5** `4827295690` Billboard, two-sided (inp888): a small 32-stud board with a different image decal on each face (a night-club shot). It is the only one with art, but the art is not ours.
- **2/5** `5529328916` Realistic Billboard (xvcvc1): a small, blank, thin-framed panel on a single pole; looks unfinished.
- *There is no dedicated rooftop billboard frame: "rooftop billboard frame" returned unrelated items. The pack's boards can be placed on roofs without the column.*

### 11 construction
- **4/5** `119266200526586` Tower Crane (Lesomaku610): a 203-stud yellow lattice tower crane with an operator cab, counter-jib, hook and a hanging I-beam on a base slab. It reads well on a skyline (the jib points at the camera in the lineup). **8 scripts removed despite the "No scripts" description.** 250 parts. *(lineup)*
- **3/5** `107131356944164` Scaffolding (Wish Game): a 16×15 two-bay steel tube frame with cross-bracing and a wood deck. Tiles well. No scripts. *(close1, left)*
- **3/5** `83471113389608` Traffic Cone (ShreddCPhoenixT): a clean orange MeshPart cone, but **only 1 stud tall** (real ≈2.3 studs), so scale it ×2.3. **3 scripts removed.** *(close2, right)*
- **2/5** `136386088614829` Road Barricade (Content Deleted - 158552482): renders as a **stone-textured trapezoid block**, not a striped barricade. **2 scripts removed despite the "No scripts" description.** *(close2, left)*
- **❌ avoid** `6693814769` construction Barricade "xxl" (TheCarsAll): actually a flatbed trailer with an arrow board plus **two Roblox NPC worker rigs**. **10 scripts removed.** Blocky, and the NPCs are unwanted. *(close1, centre)*
- *No US Type III striped barricade or A-frame sawhorse found. Both are simple in-house builds with striped decals.*

### 12 beach_pier
- **5/5** `10969289501` Lifeguard Tower (WeatherMan51): **an LA-County-style lifeguard tower**: a sky-blue cabin with wrap windows and an antenna on a raised deck, with a railed ramp, cross-braced stilts and footings. The Santa Monica / Venice look exactly. 83 parts, no scripts. *(close1)*
- **3/5** `9017391415` Beach chair and umbrella (mrtrolldos): two red/white umbrellas with striped blue and red loungers. Clean, believable, real size. 135 parts, no scripts. *(close2, left)*
- **3/5** `17739161260` Beach Umbrella (ImATeapot418): a single solid-red umbrella, simple and clean. *(close2, right)*
- **2/5** `13351773651` Lifeguard Tower (sodafont): a white lattice ladder-chair with a red pointed roof, European style. Not LA.
- **2/5** `82002680152727` Realistic Dock (Content Deleted - 158552482): a 62-stud brown plank jetty on posts. Lake-dock scale, not an ocean pier. **4 scripts removed despite the "No scripts" description.**
- *No pier railing or boardwalk lamp found: the "pier railing boardwalk" and "boardwalk lamp post" searches returned junk (bridges, a tank house, a Tokyo lamp). Use the job 0003 streetlights and build pier railings in-house.*

### 13 rooftop
- **5/5** `18336727555` Carrier 20 Ton Rooftop AC Unit (Teo7472): an accurate commercial RTU with 4 condenser fans, louvred panels and a curb base. Real size (20×6×21). **319 parts and 28 scripts removed** (fan, sound and economiser logic). Use the stripped copy, or merge it into fewer parts for mass placement. *(close1, left)*
- **5/5** `18290346289` Carrier 8.5 Ton RTU (Teo7472): the smaller sibling with 2 fans, a Carrier badge, coil guard, service panels and gas-heat flue. Excellent. **762 parts and 57 scripts removed**, which is very heavy, so it is a hero-roof prop only. A cheap LOD stand-in is needed for the skyline. *(close1, right)*
- **3/5** `14047509152` Roof Top Vents Pack (lowqualityqwerty): 7 MeshPart pieces of galvanised duct runs and boxes on stands. Clean and light (7 parts); good roof clutter. It arrived as a Folder; I wrapped it in a Model. *(close2, left)*
- **2/5** `7226259248` Roof Turbine Vent (zerg666): a tiny (2-stud) chrome whirlybird. Correct shape but low detail; fine as filler. *(close2, right)*
- **2/5** `74677240725658` "Roblox tv antenna set!" (NovaCore9JSparkt1493): a single white mesh that reads as a satellite dish blob. **3 scripts removed**, and the title is SEO spam.
- *No rooftop water tank found: the search returned whole buildings. The LA skyline doesn't need NYC-style wooden tanks anyway.*

### 14 garage_interior
*The car lift and the Snap-on cabinet came in spanning Z, so I yawed both 90°.*
- **5/5** `122655307130669` Car Lift (Skyflux1123): a realistic red **two-post lift**, 12 studs tall. MeshParts with a control box, hydraulic unit, swing arms with pads and a floor crossover. Exactly right for the player garage. **1 script removed** (probably the lift motion). *(close1)*
- **4/5** `10735214840` Tire Rack (Krisko_BGxd): a two-tier black/red X-braced rack with rows of street and off-road tyres (36 MeshParts). Very good garage dressing. No scripts. *(close2, left)*
- **3/5** `146685916` Snap-on tool box (cmt18): a classic red roll cabinet with 7 drawers and casters. It reads right but is **about 2× oversize (10 studs tall)**, so scale it ×0.5. **"Snap-on" is a trademark** (the model is unbranded in the render, but the name isn't). *(close2, right)*
- **3/5** `2109264797` Green Lizard Garage Mobile Tool Box: a bright green top-and-bottom tool chest on casters, real size. Fine, though the colour is loud.
- **2/5** `79571080572612` Garage Tool Box (Zephcr3423): a small dark-grey chest with an open lid. **6 scripts removed despite the "No scripts" description.**
- *No standalone workbench or garage shelving found: "garage workbench shelving" returned towers and parking garages. "Lowes Shelf" `239573185` is a store fixture, not checked.*
