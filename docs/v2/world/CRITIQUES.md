# World v2 critiques (recovered; the revision pass was interrupted by a container restart)

Apply these in A1. Accept or reject each one explicitly, giving reasons, in WORLD_SPEC.md under '## Critique log'.


## critic:gameplay

I measured all of this against the live data using `WorldQuery.route` and Lune scripts in the scratchpad. I did not edit any repo files. The findings are ranked most severe first.

**1. Critical: Rust Flats Garage (plot 5) is across the street from a police station.**
- The plot 5 door at (2290, 995) is 51 studs from the HCPD Eastside entrance (`PoliceFoundry`, entrance (2300, 1046)). By road the distance is 0, because both use the same node.
- That station has 8 police spawn lanes facing the driveway. Every wanted delivery, raid getaway or "hide in your garage" at plot 5 drives straight into the police spawn.
- Armored runs A, C and D also pass this door at 143 studs.
- **Change:** move `PoliceFoundry` `at` from (2300, 1050) (`WorldLayout.luau:4007`) to about (3300, 500) on Smelter Rd. That puts it 1,111 road studs from plot 5, 1,898 from plot 4 and 2,723 from plot 3.

**2. Critical: route cost is distance only, so the GPS and police never use the freeway.**
- `WorldGen.arcs` sets `cost = e.length` (`WorldGen.luau:1007`). The migration doc tells the GPS, police and armored trucks to use `WorldQuery.route`.
- Two examples, timed at AI cruise speeds:

  | Trip | Shortest route (what route returns) | Time-weighted route |
  |---|---|---|
  | Garage 1 → 5 | 7,582 studs, 23 signals, 0 freeway, 135 s | 9,045 studs, 6,452 on freeway, 4 signals, 110 s |
  | Garage 8 → 3 | 5,692 studs, 18 signals, 108 s | 6,863 studs, 4.9k on freeway, 3 signals, 83 s |

- The travel table in WORLD_SPEC §2 was measured on these grid routes, and the core "escape up the on-ramp" idea never appears in the GPS.
- **Change:**
  - Set arc cost to `length / SPEED[class]`, plus 6 s for a signal and 3 s for a stop or all-way stop at the arrival node.
  - Use a heuristic of straight-line distance / 100 so it stays admissible.
  - Keep `length` for display, and redo §2 and the plot metrics in seconds.

**3. Critical for virality: 9 of the 12 stunt jumps are misplaced.** The tests only check that they are in bounds (spec lines 492–495). Positions are in `WorldLayout.luau:4461-4474`.
- **River Leap:** yaw 90 points west, away from the channel at x≈1950. It lands at (1710, 12, 380), 13 studs from an H1 on-ramp at Y≈31 and under the east deck.
  - Use yaw 270 with the lip at about (1875, 380), landing on Riverside Dr at about (2080, 380).
- **Boxcar Hop:** it jumps parallel to the 8 east–west tracks.
  - Use yaw 0 from about (2600, 1530) to (2600, 1170).
- **Unfinished Ramp:** the lip is inside a duplex lot and the landing is on a house. It is 122 studs from the ring, not at the interchange.
  - Author a real dead-end deck stub (layer 1, Y 40) leaving the H1 south-east corner eastbound. It should end at the channel's west lip (about x 1880, z 1350) and land on Riverside Dr.
- **Parking Deck:** the lip sits at Y 48 inside a 125-stud office tower lot.
  - Add a `parking_garage` POI (about 150 × 150, height 48) and put the lip on its roof edge.
- **Skyline Drop:** the flight line hits terrain (245 against a 243 lip) and then 35-tall mansion lots.
  - Move it to a Sunwood Canyon Road switchback, pointing down the roughly 37% fall line near x −1450.
  - The SUNWOOD sign top (Y≈314) is above every road, so a jump can't clear it. Add a dirt trail along the base of the letters for drive-through clips instead.
- **Mesa Launch:** the lip is on a butte top at Y 123, about 600 studs from the nearest road (Dustbowl Rd), and terrain rises ahead of it (124–127).
  - Add a dirt access track at 15% or less, or move the lip to a cut on Dustbowl Road.
- **Cove Cliff:** yaw 180 jumps inland and uphill (lip at 130, landing at 156).
  - Use yaw 0 from about (−2900, −3960) onto the Hidden Cove sand at about (−2900, −4110).
- **Hangar Roof:** the lip is at ground level, and the 220-stud flight is over flat apron.
  - Put the lip on the hangar roof, or drop the jump.
- **Pier Plunge:** it lands in the sea at Y −46, and VehicleService counts a car below SEA_LEVEL − 6 as lost.
  - Mark it `kind = "splash"` and return the car automatically.
- Only Container Stack, Dune Kicker and Speedway Tabletop work as authored.

**4. High: the jump distances ignore the project's gravity.**
- `landDist` is 160–300 studs at minSpeed 90–130, off a 6 × 30 kicker (an 11.3° ramp).
- `default.project.json:41` sets Gravity to 196.2. At that gravity, a car at 110 studs/s flies about 24 studs on flat ground, and no ramp angle gives more than about 62 (v²/g). At the 120–140 the realism doc suggests, it is still about 36.
- **Change:**
  - Add `Scale.GRAVITY`, shared with the vehicle wave.
  - Compute `landing` from a ballistic arc (lip height, ramp angle, minSpeed) instead of authoring it.
  - Prefer drop jumps, which get airtime from height: deck to street (28), parking deck (36), cliffs, the canyon.
- **Add a test:**
  - At minSpeed, the arc clears lots, terrain and decks.
  - It lands on a road or open lot within ±40 studs of the landing point.
  - The lip is within 25 studs of a road with a straight run-up of at least 200 studs, aligned within 15°.

**5. High: with 8 players the map is empty between events.**
- The mainland is 85M square studs, 33 times v1's 1,600 × 1,600 world.
- I placed 8 players at random 4,000 times, once on parking spots and once along roads by length:

  | Placement | Median distance to nearest other player | Anyone within 1,024 (streaming radius) | Within 500 | Within 220 (police sight) |
  |---|---|---|---|---|
  | Parking spots | 1,152 | 43% | 14% | 2–3% |
  | Roads by length | 1,443 | 31% | 10% | 2–3% |

- **Keep the island size; scale is binding.** Instead:
  - Define an Active Core of about X −4,700..3,000, Z −2,400..2,600.
  - Require these inside it: all 8 garages, at least two-thirds of the normal Hot Drop pool (today 6 of 12), the start or end of every armored run, the bank, both dealerships, and at least 3 gun shops.
  - Add 2–3 Hot Drop zones in the core, for example the Iron Bay Arena lot and a lot under the ring by the Iron Bay Interchange.
  - Bake ETA fields: Dijkstra on the time-weighted graph from every Hot Drop zone and armored stop to all 624 nodes. EventService then picks the zone or run with the tightest ETA spread across active players, with at least 3 players within 45 s.
  - Show every player as a minimap blip from replicated attributes, since 57–69% of players have nobody else inside their streaming radius.

**6. High: Hot Drops are mostly uncontested.**
- `HOT_DROP_WARNING` is 20 s. Only Hotwire Plaza is within 60 s (at 100 studs/s) of all 8 garages.
- The pier, observatory, Cactus Junction, Speedway, Hidden Cove and port drops are within 60 s of 3 garages or fewer. The Speedway is up to 11,149 studs from a garage; the cove and port average 7.2–7.3k.
- The airport drop (−3000, 3000) and port drop (1200, 4000) sit inside restricted zones, so restricted-zone stars stack on the drop's own 3★.
- A player WASTED at the port, airport or Speedway drop respawns at a hospital 4.1–4.6k road studs away, so fights never restart.
- **Change:**
  - Normal pool: plaza, Gilded Mile, Echo Park, Foundry, Rail Yard and pier, plus the new core zones.
  - Move Speedway, cove, port and observatory to a "Long Haul" variant with a 60 s warning and higher rarity.
  - Set the warning to `max(20, 0.8 × median active-player ETA)`.
  - Respawn players killed at a drop 600–900 studs from it.

**7. High: car speeds don't fit real scale or the AI traffic.**
- At 0.28 m per stud, studs/s is roughly km/h.
- The starter Rustbucket tops out at 70 (about 44 mph). All 10 Common and Uncommon cars top out at 66–92, slower than AI freeway traffic (100) and highway traffic (88). `police_unit` does 118, faster than every car below Epic.
- The spec's "70 studs/s average" is the starter's top speed. At a realistic 0.7 × top it averages about 50, which gives:
  - a west–east crossing of 3.6 min;
  - a worst-case garage-to-garage drive (7,582 studs) of 2.5 min;
  - about 46 s, not 35 s, for the §8.1 drive to the dealership.
- The ring escape in §8.1 puts a 70-top car among 100-speed traffic and 118-speed police.
- **Change:**
  - Scale v2 top speeds up about 1.4–1.5×:

    | Class | Top speed (studs/s) |
    |---|---|
    | Starter | 100 |
    | Common | 95–110 |
    | Uncommon | 110–125 |
    | Rare | 125–145 |
    | Epic | 145–165 |
    | Legendary | 175–200 |
    | Mythic | 190–215 |
    | Police cruiser (1–2★) | 125 |
    | Police interceptor (3★+) | 150 |

  - AI cruise speeds: freeway 90, highway 85.
  - Recompute the travel table on time-weighted routes at 0.7 × top speed.

**8. High: some plots are much worse served than others.** All distances are by road:

| Plot | Problem |
|---|---|
| Sunwood (2) | Gun shop 5,005, spray 3,104, chop 8,232. Nearest garage 3,430. At least 2,011 from every armored route. |
| Palmera (1) | Chop 9,347 |
| Midtown (8) | Chop 7,616 |
| Rust Flats (5) | Dealership 5,754 |
| Southgate East (6) | Police 660, spray 597 |

- **Change:**
  - Add two chop shops: about (−1300, −2000) on Sunwood Blvd, and about (−2500, 2650) on Hangar Rd. The worst garage-to-chop distance drops from 9,347 to 4,523, and Sunwood's to 601.
  - Add a Lock & Load at about (−1200, −2150). The worst garage-to-gun-shop distance drops from 5,005 to 1,661.
  - Move Fresh Coat Sunwood from (−3300, −2200) to about (−1800, −2150). It is currently 560 studs from the hills police station; the new spot is 1,503 from plot 2.
  - Move `PoliceSouthgate` from (−300, 1950) to about (−650, 2750), which is about 1.7k from both Southgate garages.

**9. High: armored truck runs favour one plot and pass police stations.** The runs are defined at `WorldLayout.luau:5201-5220`.
- Runs A, C and D leave the depot at (2950, 2008) and pass plot 5 at 143 studs, so one owner gets 3 of 4 trucks. Plot 2 never gets one.
- Every run passes a police entrance: run B at 27 studs (Beach, on Palmera Dr), C at 101 (Southgate), A and D at 128 (Eastside), D at 142 (Sheriff). Any ambush brings police immediately.
- Run B does not start at the depot.
- **Change:**
  - Add these rules to data and tests:
    - Spawn the truck at least 1,000 studs from every player.
    - No stop within 400 studs, and no stretch of route within 250, of a police entrance, except the bank at the end.
    - Every garage is within 1,500 of at least one run, and no run passes within 600 of a garage door.
  - Add a run E from a new Coinstack Sunwood branch at about (−1500, −2150), down Harbor Ave to the bank.
  - Send run B through the beach grid (Breaker St) instead of along Palmera Dr.
  - Plan routes on the time-weighted graph, with one leg on the H1 and one under the ring.

**10. Medium–high: there is no roadblock data, and the channel is a trap.**
- The channel's south ramp runs from z 1599 up to 1239. Past it, the drivable channel continues 1,100 studs south to the flood gate (z 2699) as a dead-end trench 18–21 studs deep.
- The 4.4k-stud channel has only 2 ramps, so one spike strip at the exit ends any channel chase.
- Iron Bay has only 2 links: the Harbor Ave bridge and the H2.
- **Change:**
  - Add a ramp at the south end (west bank, z≈2600, by Normandie St and Kingsley Dr) and one mid-channel (east bank by Crown Blvd, z≈−250), so ramps alternate sides about every 1.1k.
  - Add `WorldLayout.Roadblocks`: anchors (edge, s, CFrame, lanes, bypass) about every 600 studs on avenue, boulevard, highway and freeway straights at least 120 studs from a junction.
  - Also include the bridge ends, diamond ramp terminals, both interchanges, the H9 canyon pass and the Coast Highway at Northpoint. Mark the port bridges `trap = true`.
  - Have police at 3★+ place blocks 400–900 studs ahead on the suspect's predicted route.
  - Make the Harbor lift bridge a clock event: raised for 25 s every ~4 min, with a timed gap jump. That is a ready-made clip moment.

**11. Medium: the heist has nowhere to end.**
- There is no drop-off, fence or car-swap data.
- HCPD HQ, about 620 studs from the vault, has 4 spawn lanes where every other station has 8.
- **Change:**
  - Add `HeistDropoffs`, one per planned exit (road distance from the bank):
    - North: Hidden Cove at about (−2700, −3800), 6,068.
    - East: Rail Yard at about (2900, 1350), 4,761. This exit depends on the channel ramps in item 10.
    - South: the south shore at about (−1500, 2850), 3,934.
  - Add 3–4 `CarSwap` spots in parking garages or lots under the ring.
  - Give HQ 8–12 lanes with exits onto two different streets.

**12. Medium: the first-5-minutes walkthrough is the best case.**
- It uses Palmera, which is 2,322 studs from a dealership. A new player in Rust Flats is 5,754 from a dealership and across the street from a police station. Foundry is 4,802.
- Both dealerships are in west Midtown, and the cheapest street-car tier ("beater") exists only in Rust Flats.
- **Change:**
  - Give first-session players the free plot with the best onboarding score: dealership ≤ 3k, gun shop ≤ 1.5k, police ≥ 800 (today plots 1, 8 and 2 qualify).
  - Add an east used-car lot at about (2600, 300). Plots 3, 4 and 5 drop to 1,914, 1,088 and 1,001.
  - Hot Drops come every 360–540 s, so the walkthrough's 3:30 drop isn't guaranteed. Schedule a first drop near the newest player at about 3:30.

**13. Medium: the parking tiers are top-heavy.**
- Of 7,385 spots: sports 3,842 (52%), muscle 1,659, sedan 1,413, beater 404 (5.5%), hyper 53, super 14.
- If tier drives the rarity roll, the soft progression collapses because the whole core is sports-tier, and the hills fantasy has only 14 super spots.
- **Change:**
  - Make Midtown and the Foundry sedan-tier, except Gilded Mile, Crown and Palmera Dr frontages, which stay sports.
  - Alternate Southgate between beater and sedan.
  - Add driveway spots on the 74 hills lots (about 150 super spots) and hangar-interior hyper spots.
  - Target roughly beater 25 / sedan 30 / muscle 20 / sports 20 / super 3 / hyper 1–2 percent.

**14. Medium: restricted zones overlap activities.**
- The Airport Drag race runs on the runway (z 3330, x −5150..−2780), entirely inside HCI Airside (1★ on entry, 3★ after 10 s). Racers finish wanted.
- The airport Hot Drop is also inside HCI Airside. The port Hot Drop and the Container Stack jump are inside the port's restricted zone.
- **Change:** add `exempt = { "race_airport" }` (or an activity flag) to HCI Airside (`WorldLayout.luau:4522`). Tag in-zone drops and jumps with an explicit `heat` value instead of letting stars stack by accident.

**15. Medium: none of these gameplay rules is tested.** Add `worldlayout.spec` checks for:
- every plot at least 1,000 road studs from any police entrance;
- service radii per garage: gun ≤ 2k, spray 1–3k, chop ≤ 4.5k, dealership ≤ 4k;
- the ballistic jump test from item 4;
- in the normal Hot Drop pool, each zone within 60 s (at 100 studs/s) of at least 5 garages;
- armored routes clear of police stations and garages;
- no channel dead end longer than 300 studs;
- no race, Hot Drop or jump inside a restricted zone without an explicit flag;
- route cost in seconds.

The analysis scripts are in `/tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/` (`b.luau` through `k.luau`), and the raw output is in `crit2.txt` there.


## critic:gta

**Verdict:** the plan is a solid, readable city layout, but it won't read as GTA yet. From typical cameras it misses the four things that make Los Santos recognisable at a glance: a skyline with real tall towers, a terrain backdrop behind it, freeways that lead somewhere, and palm-lined streets. All figures below come from `build/world_layout.json`, with lots treated as solid boxes for the line-of-sight checks.

1. **Skyline composition: a flat carpet with one spike.**
   - Downtown's 312 lots have a median height of 120 studs (about 10 floors). Only 4 lots reach 400 or more (569, 492, 466, 407), plus Pinnacle Tower at 760.
   - The realism-gap doc's target is one landmark of 700–900 plus 6–10 towers of 350–600.
   - Tower footprints are about 100×110 studs (28×31 m), which reads as pencils.
   - The beach is a uniform 8–12-storey band: 26 lots over 100 studs spread evenly from Z −2,245 to 1,586.
   - **Change:**
     - Within 650 studs of (150, −300), build Pinnacle (760), 3 towers at 560–650, 8 at 380–520 and about 20 at 220–350.
     - Merge lots so towers stand on footprints of at least 160×160, on a 40–70-stud podium with the tower set back 10–20.
     - Add a `crown` field per tower (spire, slant, stepped, helipad, lit band, flat with machinery), varied across the top 12.
     - Add two secondary clusters:
       - Palmera north of the pier (X −4,350..−3,850, Z −2,000..−1,150): 5–7 condo towers of 220–360.
       - Gilded Mile × Crown at about (−1,960, −300): grow the existing 212 hotel into 5 towers of 260–380.
     - Keep the beach south of the pier low, 24–70 studs of deco.

2. **The island is nearly flat, with no backdrop mountain.**
   - The highest point is 284 studs (80 m) at (−1,320, −3,048). 79% of the land is below Y 50. Pinnacle Tower is 2.7× the highest hill, so the hills will read as a berm.
   - **Change:**
     - Add a summit ridge to `inlandHeight`: about +300 over X −2,300..700, peaking at Z ≈ −3,550. It should decay to 0 by Z −3,300 (so Skyline Drive and the Observatory keep their grades) and by Z −3,900 (so the Coast Highway shelf is untouched).
     - Add a Chiliad-style peak of 900–1,000 studs at about (4,200, −3,350), base radius about 1,300, ridged noise, rock above Y 400.
     - Keep the Mesa Reservoir as the peak's south-west foot lake. Move the WindFarm landmark (4,300, −3,400) to the east shoulder at about (5,300, −2,900), and the Quarry to the flank.
     - Add one dirt switchback road to the summit.
     - **Verify in the engine** that terrain beyond `StreamingTargetRadius` 1,024 still renders. If it doesn't, the hills and mountain need persistent low-poly MeshPart silhouettes, or the backdrop disappears beyond 1 km.

3. **The SUNWOOD sign is hidden and faces the wrong way.**
   - Its base is at Y 204 on the mid-slope, below the city roofline. Out of 9 sample points across the letters, none is visible from:
     - Hotwire Plaza or HCPD HQ;
     - Echo Park;
     - the boardwalk or the Foundry;
     - Liberty Avenue at Crown or at Mission;
     - the Gilded Mile;
     - the H1 south deck.
   - Only the west end of the H1 north deck sees all 9; the pier end sees 3 and the H1 west deck 4.
   - Yaw +8 gives a LookVector of (−0.14, −0.99), which points north, away from the city. That contradicts the landmark's own note and the module's convention that LookVector is the front.
   - **Change:**
     - Move it onto the new ridge at about (−150, −3,450), on Liberty Avenue's axis and above the Observatory, with base ≥ 450 and yaw ≈ 185 (LookVector ≈ (0.09, 0, 0.996)).
     - Tested: a base at 520 gives 9/9 from the pier and both H1 decks, and 5/9 from Echo Park and Liberty at Crown.
     - Add a test that requires at least 5/9 visibility from named vista points.

4. **There is no streetscape data: no palms, utility poles or billboards.**
   - These are the strongest Los Santos cues at street level, and `WorldLayout` has no placement data for them.
   - **Change:** add `WorldLayout.Streetscape` with per-edge rules:
     - **Palms:** Washingtonia fan palms 65–100 tall every 35–45 studs on Palmera Drive, the Gilded Mile, Sunwood Boulevard, Liberty Avenue, Crown Boulevard west of X −1,240, and the Airport Boulevard median. That is about 1,500 MeshParts.
     - **Trees and lamps:** street trees every 60 studs downtown and in Midtown; cobra-head lamps every 110–160 studs per side.
     - **Utility poles:** 45 tall with Beam wires, every 120–150 studs on one side, in Southgate, Rust Flats, the Foundry and Cactus Junction, and along the Coast Highway.
     - **Billboards:** about 100 slots (CFrame + size) facing the H1 decks within 150 studs at eye height 46–80, on the Sunwood Boulevard strip, and on Crown and Gilded Mile corners.

5. **The freeway system is a closed racetrack.**
   - The H1 is the only real freeway. The H2 spur is about 2.1k studs and the H9 about 1.3k (corridor length). Nothing runs out to the desert, the airport or the beach.
   - **Change:** add three arms.
     - **West:** a spur from the ring's west leg at Z ≈ −950 to Palmera Drive (−4,450, −950), ending at grade at a signal facing the pier, like the I-10 at Santa Monica.
     - **East (desert freeway):** from the ring's east leg at Z ≈ 250, on a viaduct over the river, Riverside Drive and Foundry Avenue. It reaches grade by X ≈ 3,400, then runs as a 2+2 divided road past Cactus Junction to meet the Coast Highway near (5,650, 0).
     - **Airport connector:** from the south-west corner (−3,650, 1,350) to Terminal Drive (−4,100, 2,400), with a departures-level flyover.
   - Estimated cost: about +700 parts.

6. **The H1's profile and shape are monotonous.**
   - All 976 deck points sit at Y 40, and the four corners are identical 600-radius curves.
   - **Change:**
     - Put the north leg in a 26-deep cut along the hill foot, with streets bridging over (like Hollywood's 101).
     - Shift the east leg about 250 east onto the Rust River's west bank, on single-column bents.
     - Use unequal corner radii (NE about 1,100, SW about 450) and skew the south leg 5–7°.
     - Widen the south and east legs to 4+4.
     - Replace the Iron Bay trumpet, whose loop and flyover sit on downtown blocks at X 680..1,231, Z 928..1,350, with a directional interchange with flyovers at Y 66 and 92: an LA four-level stack silhouette.

7. **Downtown blocks are a small, uniform checkerboard.**
   - Streets run every 300–320 studs both ways, so blocks are about 220×220 curb to curb and each splits into 4 near-identical lots. The target is 360 × 430–700.
   - Downtown has 86 signalized junctions.
   - **Change:**
     - Set the N–S streets (with Harbor and Liberty) to {−1,100, −650, −150, 300, 750, 1,200}, and the E–W streets (with Crown and Mission) to about {−1,450, −900, −300, 200, 680, 1,150}.
     - Add an `alley` class: 18 wide, no AI traffic, mid-block, also in Midtown and the Foundry. Alleys are the chase shortcuts GTA is known for.
     - This cuts roughly 35 signals and junction boxes.

8. **Downtown is one style everywhere, with a hard seam at Midtown.**
   - All 312 lots use `glass_towers`. Every district polygon is an axis-aligned rectangle, so at X = −1,240 the style switches abruptly from 30–220 stucco to 70–640 glass.
   - **Change:** add sub-zones.
     - Financial Core (X −500..900, Z −1,000..300): glass.
     - Old Town (X −1,240..−500): brick and terracotta at 60–180, cornices, theater marquees.
     - Civic Center (X −600..300, Z 300..900): a stepped City Hall tower about 380 tall with a pyramid top, and a one-block park square of about 300×300.
     - Warehouse edge (X 1,000..1,590, Z 500..1,290): 24–80, surface lots, murals.
   - Use 400-stud blend bands at district borders.

9. **No garage door frames the skyline in the first frame.**
   - From each garage door, Pinnacle Tower is 56–173° off the door heading (none within 45°), and the sign is at least 64° off.
   - **Change:** choose frontages so the doors face the core:
     - Pinnacle Garage → west (Pinnacle about 15° off);
     - Foundry → west (11°);
     - Rust Flats → west (35°);
     - Southgate East → north (2°);
     - Southgate West → north-east;
     - Midtown → east (11°);
     - Sunwood → south (about 25°, looking down over the city).
   - Keep Palmera facing the ocean.
   - Add a test: door-to-Pinnacle angle ≤ 40° for plots 2–8.

10. **Five lots pierce elevated decks.** These would render as buildings stabbing through freeways:
    - an office tower with its top at Y 85 under the H1 mainline (Y 40) at (265, −1,673);
    - an office tower (top 91) under the H1 off-ramp at Y 32, at (−401, −1,671);
    - a parking garage (top 83) under the H9 flyover at Y 66, at (−2,532, −1,608);
    - a villa (top 43) under the H9 ramp at Y 40, at (−2,457, −2,237);
    - a warehouse (top 48) under the H1 off-ramp at Y 29, at (1,773, 861).
    - **Change:** in lot rejection, test against the XZ footprints of elevated edges (+8 margin), and reject the lot or cap its top at deck − 16. Add the same check to the tests.

11. **The west coast is straight and the airport is an empty slab.**
    - The waterline stays within X −5,070..−5,130 from Z −1,800 to 1,000, with a perpendicular pier. The airport is about 7.7% of the land with 16 lots and one 2,370-stud runway (663 m).
    - **Change:**
      - Push the coast out at both ends to make a crescent bay: a north headland at about (−5,500, −2,050) and a south breakwater at (−5,450, 1,700).
      - Angle the pier about 10°.
      - Add a marina basin with 4 jetties at X −5,450..−4,600, Z 1,750..2,600.
      - Optionally add canals at Z 1,000..1,600 in the beach grid.
      - Reclaim the south-west coast about 400–500 studs (for example (−5,300, 3,850) → (−5,850, 4,350)) for a second parallel runway about 3,000 long, a 900×250 terminal with a two-level drop-off, and parking structures.

12. **The Coast Highway never touches the coast.**
    - Its median distance from the shoreline is 348 studs, and only 3% of it is within 250.
    - **Change:**
      - Run the north stretch (X −2,200..600) 60–120 from the cliff edge, with guardrails and 3 pull-outs.
      - Drop to beach level at the beach segments (2,150, −4,700) and (6,050, −2,200), with a small beach hamlet at about (5,750, −2,200).
      - Add a rock cut or short tunnel at the north-east cape (5,050, −4,250).

13. **Red Mesa is blobs behind a hard seam.**
    - It is 24% of the land with 10 lots. The `MESAS` are radial domes (radius 180–320), which read as craters on the plan. Sand starts right where the Foundry grid stops at X 3,300.
    - **Change:**
      - Replace the domes with oriented ellipses (aspect 2.5–4, NE–SW), with terraced caps and talus slopes.
      - Add a 2,000-long escarpment at X ≈ 5,200, Z −1,600..400.
      - Turn X 3,300..4,000 into a transition band: an oil field of about 20 pumpjacks replacing the (3,600, −1,550) mesa, a trailer park, and a substation with pylons.
      - Add a walled state prison of about 900×700 with guard towers at about (4,500, 1,400) on Dustbowl Road, which also serves the brief's jailbreak mode.

14. **Sunwood Hills is sparse.**
    - 74 lots cover 16.7% of the land. The north side of Sunwood Boulevard (its "Sunset Boulevard") is 8 mansions and 2 villas with 30–50 setbacks.
    - **Change:**
      - Raise to about 200 hill lots on the south face (frontage 90–150, setback 12–25, stilt houses on downhill frontages), with oak and chaparral scatter.
      - Make Sunwood Boulevard X −2,400..−600 a "Strip" frontage: 0–6 setback, clubs, a theater landmark, rooftop billboards.
      - Add a hilltop museum (a Getty analog) on a pad at about (−3,300, −2,950) above the H9 pass, and a golf club of about 1,000×600 near (−4,000, −2,500).

15. **The Rust River is a ruler-straight ditch.**
    - It runs at X ≈ 1,955 for 5,000 studs and is 124 wide.
    - **Change:**
      - Bend it through about (1,820, −900), (2,100, 400) and (2,150, 1,600), with Riverside Drive following.
      - Widen the reach south of Z 1,000 to 180–200 with a low-flow trough.
      - Make the Crown crossing a lit concrete arch viaduct (a 6th Street Bridge parody) and the Mission crossing a steel truss.

Files:
- /home/user/HotwireCity/src/shared/Config/WorldLayout.luau
- /home/user/HotwireCity/docs/v2/world/WORLD_SPEC.md
- /home/user/HotwireCity/build/world_layout.json
- Line-of-sight scripts: /tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/los.py, los2.py, los3.py and los4.py in the same folder


## critic:tech

I checked the world against Roblox mobile limits with StreamingEnabled on. The tests pass, but it has blocking problems in junction control, routing, ramp geometry, boot cost and streaming. I measured every number below by running the real `WorldLayout` and `WorldQuery` under Lune from probe scripts in the scratchpad. I did not edit any project files.

1. **[P0] Diamond ramp terminals have no traffic control.**
   - **Evidence:** 17 junctions at street level (Y 12) are classed `merge`, so traffic does not stop at them. Examples on Liberty: (−150, −1874), (−150, 1275), (−150, 1424). On Mission: (1575, 650), (1724, 650). On Harbor: (−1100, 1275). On Airport Blvd: (−2700, 1275).
   - **Cause:** `WorldLayout.luau:3192` sets `ground = false` whenever any approach has a nonzero layer, and diamond ramps are layer 1. Line 3207 then picks `merge`. WORLD_SPEC §5.2 and §5.5 say these terminals are signals.
   - **Change:** decide "ground" from the node's height (`|node.Y − gradeAt| < 3`) or from its non-ramp approaches. Make every node where a ramp meets a layer-0 road a signal with 3 phases: avenue through, a protected left onto the on-ramp, and the off-ramp.
   - **Test to add:** any node with a ramp approach and a layer-0 non-ramp approach must have control `signal`.

2. **[P0] Routing finds the shortest distance, not the fastest time, so it never uses the freeway.**
   - **Cause:** `WorldGen.luau:1007/1009` sets every arc's cost to `e.length`.
   - **Evidence:** Palmera Garage → Rust Flats Garage is 7,582 studs with 0 studs on freeway or ramps. Airport → Pinnacle Garage is 8,112 studs with 0 on the freeway. GPS, police, armored trucks, the garage-to-garage distances and the WORLD_SPEC §2 travel times are all surface-street figures.
   - **Change:** cost = `length / speed`, plus about 4 s per signal node and 2 s per stop. Heuristic = straight-line distance / 100, which stays admissible. Keep a `shortest` option for anything that needs pure distance.
   - **Follow-up:** recompute §2 and §6.1, and add a test that Palmera → Rust Flats is at least 50% freeway.

3. **[P0] `WorldQuery.route` polylines cut through buildings.**
   - **Cause 1:** line 398–403 starts at the projected point `pa`, then skips `list[1]`, the start node itself. The first leg is a diagonal chord to the second vertex of the first path edge.
   - **Cause 2:** `nearestNodeOn` (line 365) picks the nearer end of a two-way edge regardless of travel direction. That forces U-turns, and the choice flips as a unit passes the middle of a block.
   - **Evidence:** in 39 of 217 random routes, the first leg crosses a building lot. Example: from (−1195, 1994) on Jamestown Rd to (−1100, 1751), a 261-stud diagonal. Police following the line with pure pursuit would drive into buildings.
   - **Change:** add virtual source and target nodes on the projected edge, with arcs to node a (cost s) and node b (cost L − s) that respect one-ways and the unit's heading. Emit the edge's own vertices from s to the node.
   - **Police cost:** run one reverse Dijkstra from the suspect each second (624 nodes, about 1 ms) and give every unit its next hop from it, instead of one A* per unit. Today A* averages 0.5 ms and peaks at 2.1 ms per call.
   - **Test to add:** every polyline sample lies within `width/2` of some edge.

4. **[P0] Ramps cut into the freeway deck.**
   - **Cause:** `diamond()` and `trumpet()` attach ramps at the carriageway centerline, which is the middle lane, and `easedRamp` starts descending at s = 0 (lines 1321, 1342).
   - **Evidence:** 32 ramps are 6–12.5 studs below the deck while still inside the carriageway's footprint. The worst is the H1 off-ramp at (−3575, 27, 866): 12.5 studs down, with 0.6 studs of lateral clearance. Typical cases are 6 studs at (107, 34, 1411), (−407, 34, 1288) and (1588, 34, 68). With a 3-stud deck slab, the ramp slabs sit inside the main deck.
   - **Change:**
     - (a) Land ramps on an auxiliary lane: offset = carriageway offset + 1.5 × LANE, and set `lanesF` to 4 for about 250 studs before a diverge or after a merge.
     - (b) Hold the ramp at `DECK_Y` until its edge is at least 4 studs clear of the deck edge and barrier, then ease down. A 28-stud drop at 8% needs about 350 studs after that point, so raise `Ld` from 420 to about 560 where spacing allows (`WorldLayout.luau:1278`).
     - (c) Export `gore = {edge, s0, s1}` for each ramp so the builder knows where to cut the barriers.
   - **Test to add:** wherever a ramp overlaps a freeway it shares a node with, `|dy| ≤ 0.5`.

5. **[P0] The gaps between ramps on H1 are too short to drive.**
   - **Evidence:** the distance from an on-ramp merge to the next off-ramp diverge, where traffic must cross lanes, is under 200 studs in seven places:

     | Gap | Location | Ramps involved |
     |---|---|---|
     | 60 studs, both carriageways | East leg, (1623, 170) and (1676, 230) | Crown and Mission diamonds, 900 apart |
     | 110 studs | South leg, (190, 1376) | Liberty south to the Iron Bay trumpet |
     | 170 studs, both carriageways | West leg, (−3676, 70) and (−3623, 240) | Crown and Mission west |
     | 190 studs, both carriageways | South leg, (−490, 1323) and (−680, 1376) | Liberty and Harbor |

   - **Impact:** that is 0.6–1.9 s at 100 studs/s. Kinematic AI cannot merge and change lanes in that time.
   - **Change:** either make the Mission east and west diamonds half-diamonds (drop the conflicting movements), or join each on-ramp to the next off-ramp with a continuous fourth lane. Aim for at least 600 studs between ramp gores.

6. **[P1] 38 junctions overlap a neighbouring junction, and one edge doubles back on itself.**
   - **Evidence:** 38 edges are shorter than the sum of their end junctions' radii (ra + rb). Most are pairs of signals that sit closer than their own junction radius:
     - Harbor Ave at x = −1100, where the −11° Midtown grid meets downtown: signal pairs 4, 16, 29, 39 and 53 studs apart.
     - Sunwood Blvd: 19–24 studs at (−499, −2120), (800, −2136) and (1420, −2086).
     - Liberty: 8 studs at (−150, −2142).
     - Grove St: 3 and 4 studs (all-way stop pairs).
     - 9th St: 10 studs at (800, 960).
   - **Impact:** stop lines fall inside the neighbouring junction, and two unsynchronised signals deadlock traffic.
   - **Change:** in the graph compile, merge nodes closer than `max(ra, rb)`, or snap generated grid ends to an existing node within 60 studs before `planarize`.
   - **Related defect:** Avalon Blvd has a vertex that turns 163.6° at (−2042, 1464), giving a minimum street radius of 4 studs.
   - **Tests to add:** edges between controlled nodes are at least ra + rb + 25.5 studs long; no vertex inside an edge turns more than 60°.

7. **[P1] Generating terrain at boot would take minutes.**
   - **Evidence:** `heightAt` costs about 43 µs per call in Lune. One call per 4-stud column over 11,620 × 8,920 studs is 6.5M calls, about 276 s, before any `WriteVoxels`. Filling solid down to −64 is about 161M voxels, plus 17M water voxels.
   - **Conflict:** PLAN.md locks "terrain runtime-generated in phase 1".
   - **Change:** bake the terrain into the place now, using Luau Execution with `SavePlaceAsync`. If it must be generated at runtime:
     - `FillBlock` the flat Y-12 basin and the ocean as a few large boxes;
     - `WriteVoxels` only where `|gradeAt − 12| > 0.5`;
     - keep a 16-stud shell under the surface;
     - clamp the seabed at −24 beyond 300 studs from shore;
     - carve terrain to road Y − 2 under road slabs so smooth terrain cannot poke through.

8. **[P1] Clients must never run the generator, and the planned boot hash check cannot work.**
   - **Problem:** `WorldQuery` requires `WorldLayout`, which builds the whole world when first required: 2.1–2.6 s and about 23 MB of Lua heap in Lune. The MapLayout shim would route GarageClient, HUD, Waypoint, Tutorial, Events, Minimap and MapScreen through it.
   - **Hash check:** MIGRATION §5's "baked hash matches its own source hash" is impossible at runtime, because game scripts cannot read `Script.Source`.
   - **Change:** split the data three ways:
     - `Config/WorldData` (server and client): roads, intersections, POIs, plots, districts. Store polylines as an int32 `buffer` at 0.1-stud precision; 7,180 points is about 86 KB.
     - A server-only module: parcels, the 7,385 parking spots stored as `{edge, side, s}`, and routes.
     - The generator itself in `tools/`, not `src/`.
   - **Where to check the hash:** the bake tool writes the hash and a Lune test verifies it. Nothing checks it at boot.
   - **Determinism test:** today's fingerprint is a weighted sum of positions. It cannot see edge or parcel order, `oneWay`, lanes, control, phases or parking edge references. Hash the serialized baked output instead. The JSON export is already 1.0 MB without the full parking list.

9. **[P1] The streaming plan depends on mechanisms that don't exist at runtime.**
   - **LOD:** `Model.LevelOfDetail` (StreamingMesh or SLIM) can only be set by plugins or Open Cloud, and needs saved, cloud-transcoded models (`roblox_tech.md` §7). A world built at boot therefore cannot keep the skyline or the SUNWOOD sign visible beyond the streaming radius.
   - **Persistence:** "keep the deck the player is on persistent" is not an engine feature. Persistent means always loaded, for every player.
   - **Fall-through risk:** at 190 studs/s with a 256-stud minimum radius, a client-owned car reaches an unloaded deck in 1.3 s.
   - **Change:**
     - (a) A Persistent collision skeleton: invisible long collision parts for every elevated edge, bridge and the channel floor, about 62.6k studs / 200 ≈ 320 parts. Visual road parts get `CanQuery = false`.
     - (b) `StreamingIntegrityMode = PauseOutsideLoadedArea`, `MinRadius` 384, and a server call to `RequestStreamAroundAsync(pos + vel × 2.5)` each second for players above 120 studs/s.
     - (c) A Persistent low-poly skyline of about 70 parts: the 55 towers of 20+ floors, Pinnacle Tower, the sign, the wheel and the cranes.
     - Move "bake MapBuilder output into the place" to phase 1. Lune's `@lune/roblox` can write the `.rbxm` offline.

10. **[P1] The part budget doesn't measure what limits a phone.**
    - **Road share:** roads take 25.5k of the 55k (47%), at 5 parts per segment: asphalt, 2 curbs and 2 sidewalks. Downtown alone is 14.3k.
    - **Towers:** a tower gets 34 parts, which is a plain box, v1's toy look.
    - **Per streaming circle:** the worst 1,024-stud circle, centred at (320, 1088), holds only about 6.1k parts, 114 building models and 707 parking spots.
    - **Missing:** parked and traffic cars, pedestrians, draw calls and triangles.
    - **Change:**
      - (a) 3 parts per road segment (the sidewalk slab doubles as the curb) and merge collinear segments. That frees about 10k parts for facades.
      - (b) Budget per 1,024-stud circle: ≤ 20k instances, ≤ 600 draw calls, ≤ 600k triangles, about 40 parked and 25 traffic cars per player.
      - (c) Part ceilings per building use; for example, a tower ≤ 120 parts or one kit mesh set.
      - (d) At most about 12 unique building meshes per district style, so instancing holds.
      - Add the per-circle check to `tools/world/stats.luau` and CI.

11. **[P1] The freeway builder hits structural conflicts it cannot resolve.**
    - **Pier gaps:** no legal pier site for 385 studs under the H2 trumpet flyover, which runs along 9th and 10th Street at (714, 994–1300). Same for 250 studs under the H9 loop along Romaine and Highland St at (−2682, −1486). The "cut streets that run under a deck" rule does not cover flyovers.
    - **Ramps over sidewalks:** diamond ramps hang over the sidewalks of streets running beside them:
      - 9.6 studs above Rosewood Ave at (−3575, −188);
      - 5.2 above Beverly St at (−3575, −448);
      - 6.7 above Grand St at (−248, 1424).
    - **Crowded terminal:** the Airport Blvd terminal at (−2700, 1275) sits 21 studs from Lindo St.
    - **Change:** extend the parallel-street cut to every ramp and flyover footprint below grade + 26. Reshape the H2 and H9 trumpets so a pier site exists at least every 120 studs.
    - **Tests to add:** clearance measured on footprints, not centerlines (≥ 14 studs between edges with no shared node); unsupported span ≤ 150 studs except on `bridge` edges.

12. **[P2] Lane geometry isn't ready for kinematic traffic.**
    - **Lane jumps:** `laneCFrame` offsets from each segment's direction, so lanes jump at polyline corners. 352 corners jump more than 1 stud on the outer lane; the boulevard outer lane is 26.8 studs off the centerline.
    - **Freeway lanes:** `laneOffset` (`WorldQuery.luau:269`) ignores the uneven shoulders (8 outside, 4 inside), so AI lanes sit 2 studs off the painted lanes.
    - **Left turns:** 42 two-phase signals have 3-lane approaches with unprotected left turns.
    - **Change:**
      - Bake mitred lane polylines per (edge, direction, lane) with `polyOffset`.
      - Bake lane connectors per approach: `{fromEdge, fromLane, toEdge, toLane}` with Bézier curves. Let signal phases reference connectors so protected lefts become possible.
      - Add `(shoulderOut − shoulderIn) / 2` to freeway lane offsets.

13. **[P2] Sunwood Garage sits on a 60-stud slope.**
    - **Evidence:** terrain inside its 140 × 150 footprint ranges from Y 33.2 to 93.9, with the floor at 40.7. The other 7 plots are flat. Plot placement checks only roads and water.
    - **v1 mismatches:** v2 puts `plot.cframe.Y` at street level, but v1's `plotOrigin` was at curb top (+0.6). The Midtown garage faces 169° and the two Southgate garages face about −87° and 95°; v1's garages were assumed to face cardinal directions.
    - **Change:** add a flatten pad for each plot to `TerrainZones` (footprint plus a 40-stud apron, blend 120), or move Sunwood Garage south of Sunwood Blvd. Set plot Y to street + `CURB_HEIGHT`.
    - **Test to add:** terrain relief ≤ 2 studs inside every plot and POI footprint.

14. **[P2] The MapLayout shim would let broken callers compile and misbehave silently.**
    - **Scope:** 42 sites do grid math such as `math.round(p / S)`, `LINE_*` or `BLOCK_*`: PoliceService 12, MapBuilder 11, NPCService 7, TrafficService 6, RoadGraph 4, PlotService 1, StreetSpawn 1.
    - **Examples:**
      - `PoliceService._orientedLane` rounds lane positions onto the old grid;
      - `groundUnder` returns `ROAD_Y` = 0 although the city now sits at Y 12;
      - traffic is pinned to `ROAD_Y + yOffset`.
    - **Change:** the shim keeps only the plot-local helpers (`plotOrigin`, `plotToWorld`, slots, zones, `isInBox`, `plotAt`, `plotCount`). Grid functions throw, and the grid constants in `Config/Map` become nil, so remaining callers fail in tests. Migrate Police, Traffic, NPC and StreetSpawn in the same wave as the shim. The minimap workflow's `Config/Minimap` also requires MapLayout, so coordinate with them.

15. **[P2] Spawn data starves the rare-car progression and mislabels the ring.**
    - **Car tiers:** parking spots per tier are sports 3,842, muscle 1,659, sedan 1,413, beater 404, hyper 53 and super 14. The Hills have 14 spots, the port 0 and Red Mesa 4.
    - **Ring districts:** about 11.8k studs of H1 ring edges fall back to district `mesa` (heat 1).
    - **Police HQ:** HCPD HQ, next to the bank heist, has 4 police spawn lanes against 8 at each precinct.
    - **Change:**
      - Add `Spawns.offstreet` with tiers: about 120 super spots on Hills mansion driveways, about 30 hyper on the hangar apron and about 30 hyper in the port yards.
      - Tag freeway edges with their corridor's district polygon instead of the fallback.
      - Give PoliceHQ 12 spawn lanes.
      - Test minimums: at least 100 super and 60 hyper spots.

The probe scripts are in `/tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/wa/`. Run them from `/home/user/HotwireCity` with `lune run <script>`.
- `an2.luau`: ramp vs deck, overlapping junctions, short ramp gaps, pier gaps, plot slopes
- `bench.luau`: routing speed and freeway share
- `rbug.luau`: route lines through lots
- `ovl.luau`: ramps over unconnected streets
- `hbench.luau`: terrain height cost
- `dens.luau` and `dist.luau`: part counts per circle and per district
- `lane.luau`: lane jumps and curve radii
- `mg.luau`: uncontrolled ramp terminals
- `tier.luau`: spawn counts by tier
