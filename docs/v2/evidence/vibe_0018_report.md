# Job 0018 report: v2 preview first look and the GTA vibe audit

- **Place:** opened from Roblox at version 33+, confirmed by its content: WorldLayout, MapLayout, BuildingService, CarBuilder and the 35-car `Shared.Config.Cars` are present. **Rojo was not connected. Not saved or published.**
- **Code lookups:** `origin/v2/preview` @ **`4b1df2d`**; `main` @ `c65f3e5`.
- **Boot:**
  - `[Server] Hotwire City booted with 29 systems`
  - `[Client] … ready with 27 controllers`
  - `[CarTemplates] 30 / 30 car templates ready`
  - `[MapBuilder] v2 world: 39692 parts (budget 42000), 4.1 s parts, 34362 terrain chunks in 39.1 s`

## TL;DR: the single biggest problem
**Every ground-level road, sidewalk and plaza in the city is buried under a sand-coloured terrain skin.**
- At 7 sampled sites the terrain surface is at **y = 13.59** while the `Road` parts top out at **12.0** and the `Sidewalk` parts at **12.6**:
  - Crown Blvd, a downtown intersection, the hospital, the gun store, the police HQ, the dealership, and Mission Ave.
  - At street level the whole city is **a sand desert with buildings standing in it**: no asphalt, no lane markings, no kerbs, no crosswalks.
- The road network exists, as shown on the radar, in the aerials and on the elevated freeway; you just can't see it from the street.
- **Owner:**
  - `src/server/Systems/World/Terrain.luau`. The design intent (its header) is "ground sits SINK (0.4) under the baked grade", with roads graded 0.9 under the road top.
  - In practice the ground surface ends up ~1.6 studs **above** grade.
  - **Likely cause:** 4-stud voxel quantisation (`Terrain.RES = 4`) in the flat-ground fast path (`uniform = flatY - Terrain.SINK`, lines ~319–345), written with `FillBlock` in `Terrain.write` (~507).
  - The flat column 11.6 isn't representable at RES 4, so the surface lands on the next voxel row.
- **Fix that alone and most street shots go from 1–2/10 to 4–5/10.** This is a terrain bug, not an art-direction problem.

## A. Tour at noon (`TimeOfDayLock` 13), with a GTA score per shot
How shots were taken:
- From the player camera, after a scripted teleport. For the "behind the player" framing the camera sat 12 studs back and 4 up.
- Aerials use explicit camera positions at client quality Level 21, then restored to Automatic.

| Shot | Coords (player) | Score | Why |
|---|---|---|---|
| `t01_spawn` | (spawn = garage interior, Palmera Garage plot 1) | **2** | A new player wakes up inside a **white tycoon box with hot-pink neon strips**: "1 PARKED / 2 EMPTY" slot signs in FredokaOne, cartoon "GOLD RUSH" / "HOT DROP SEASON" posters, a big red "LOCK GARAGE" button and an emoji income tag over the car. It reads as an obby or tycoon, not GTA. |
| `t02_downtown_street` | (-330, 16.6, -222) on Crown Blvd, facing +X | **2** | Decent tower models, but **you stand on sand** (buried road). Lollipop trees, a flat grey lamp pole, no cars, no people, no street furniture. |
| `t03_downtown_intersection` | (-215, 16.6, -205) facing (-150, -250) | **2** | Signals work (red and green lenses), but they sit on plain black poles in a sand lot. No road, crosswalks or traffic. |
| `t04_freeway` | (-470, 43, 1420) on the H1 ring, facing west | **5** | **The best street shot.** Real asphalt, lane dashes, a yellow edge line, concrete barriers, light poles and power lines. But it's empty (no traffic) and the barrier and deck are flat untextured grey. |
| `t05_beach` | (-5000, 8.9, -200) facing the sea | **4** | Good water and sky. The sand is fine. A large brown terrain **cliff step** runs along the shoreline like a wall. No pier, lifeguard tower, umbrellas or palms in view. |
| `t06_hills_houses` | (-2241, 54.9, -2376) on Hillcrest Dr | **4** | Brick row buildings with **candy-striped red, yellow and blue awnings**, a terracotta-roof house, grass hills. It reads like a cosy toy town. The road is a beige strip. |
| `t07_port_industrial` | (2880, 16.6, 1300) Rust Flats rail yard | **1** | Black bars lying on flat sand: no sleepers, ballast, rolling stock, warehouses or cranes. The first try, `t07a_rustflats_overpass` (1600, 43, 670), landed on a bare freeway overpass. |
| `t08_garage_plot` | (-4075, 16.6, -110) facing the garage | **1** | **The worst exterior:** a white shed with **hot-pink neon outline trim** on every edge, a cartoon "HOTWIRE CITY" lightning logo, an "illintent1's Garage 💰 $12/s 🚗1" sign in FredokaOne, neon "DROP-OFF" arrows, yellow pillars. It's on a sand lot next to a realistic v2 hotel. |
| `t09_dealership` | (-1754, 16.6, 926) facing Hotwire Motors | **2** | v1 dealership: a **hot-pink neon canopy**, cyan/pink turntable rings, "GOLD RUSH – you can't afford it" / "Steal the Deal!" cartoon posters, hot-pink flag caps, a striped hot-dog cart, and toy palms. `t09a_dealership_rooftop` is the first try, on a rooftop. |
| `t10_gunstore` | (2350, 16.6, -280) Lock & Load Foundry | **3** | A plain grey box with two blue window slabs and a black "LOCK & LOAD" fascia. Not cartoonish, just empty: no Ammu-Nation-style signage, glass, posters or lighting. On sand. |
| `t11_police_station` | (-620, 16.6, 350) HCPD HQ | **3** | Flat grey slab façade with a small navy "HCPD HEADQUARTERS" sign: no entrance, flag, cruisers or steps. On sand. |
| `t12_hospital` | (880, 16.6, -860) Mount Mercy | **3** | Same box, with a small red-lettered sign and one blue door panel. Flanked by good glass towers, but there's no ambulance bay or emergency signage. |
| `t13_overview_low_sw` | camera (-1400, 260, 1400) → downtown | **6** | **The best shot of the job.** A real skyline: varied towers, a gas station, a pool, palms, power lines, the freeway curving in. From up here the sand reads as dry LA lots. The "SUNWOOD" hillside sign is a nice Vinewood nod. |
| `t14_overview_high` | camera (0, 4200, 5200) | **6** | The island layout is convincing: ring freeway, downtown grid, suburb grid, port with containers, airport, mountain, and the channel bridge. Large areas read as untextured sand. |
| `t15_car_closeup` | `kronberg_k8` spawned at (-269, 16, -235); camera (-251, 18.5, -248) | **6** | **The car is genuinely good:** a realistic dark-red sedan with a proper grille, lights, rims, glass and plate. Ruined by the sand floor and the default Roblox head poking out of the roof. |
| `t16_driving` | driving east on Crown Blvd | **3** | The car and chase camera feel right, but it's driving on sand between buildings, with no traffic, lane lines or pedestrians. |

**Golden and night:**
- **`g02_downtown_street` (17.6): 3.** A warm brown grade over a brown sand street: muddy. The towers read fine.
- **`g13_overview_low_sw` (17.6): 3.** Most of the city is swallowed by a flat **grey haze wall** beyond ~600 studs; only 4 buildings are visible. The haze is far too heavy at golden hour from that camera. (The tour aerials were at quality Level 21; this one was at Automatic, which, per job 0011, cuts draw distance.)
- **`n02_downtown_street` (22.5): 4.**
  - Lit window strips and streetlights look nice, as does the car's headlight beams.
  - But the sky is **dark reddish-brown** (still unfixed since 0011), the ground is black sand, and the window glow is uniform neon-yellow slabs.
- **`n03_downtown_intersection`: 4.** The signals glow red and green correctly and the lit lobby windows read well; the palms are black silhouettes. It's dark but readable.
- **`n04_freeway`: 2.** Nearly pitch black. The streetlights are tiny dots that **cast no light on the deck**, and there's no visible sky or distant city glow.

## B. Neon and "Roblox-y" scan (`scan.txt`)
I ran the job's scan on the Server at noon. It covered 74,608 instances and took two background passes, because a single `execute_luau` timed out.

**The job's grouping (by top-level child of `workspace`) gives 5 groups, and isn't actionable:**
```
10698  Workspace.Map   [Neon=2035, bigSmoothPlastic=7323, loudColor=1256, cartoonFont=42, loudText=34, emoji: 💰 TOP EARNERS 💰, 🚗 TOP THIEVES 🚗, 🥇×2, 🥈×2, 🥉×2]
 1935  Workspace.Plots [Neon=424, bigSmoothPlastic=344, cartoonFont=624, loudColor=280, loudText=80, exclaim "#2 • Join to claim!"…"#8", "Step on the pad!"×8, emoji…]
 (+ Dealership, Vehicles, NPCs: small)
```
So I re-grouped **by part name across all cells and plots**, which maps 1:1 to a `Kit.part` / `neon()` / `deco()` call in code. The top 25 groups with their owning scripts:

| # | Hits | Group (name) | Why | Colour | Owning script (v2/preview) |
|---|---|---|---|---|---|
| 1 | 1706 | `Map.Cells.*.SignalLens` | Neon 867, loud 839 | (255,52,40) red | `World/Signals.luau:108`. **Legit**: lit traffic-light lenses. Keep, but use dim, non-neon lenses for the off-state. |
| 2 | 1008 | `Map.Cells.*.StopBar` | bigSmoothPlastic | (228,228,222) | `World/Roads.luau:736`. Fine (white stop lines); just buried under the terrain. |
| 3 | 856 | `Map.Skeleton.Skeleton` | bigSmoothPlastic | white | `World/Skeleton.luau:69/83`. Invisible collision slabs (`Kit.style("invisible")`); a false positive. |
| 4 | 409 | `Map.Cells.*.StopSign` | loud | (178,36,32) | `World/Signals.luau:142`. Legit red. |
| 5 | 330 | `Map.Cells.*.Wire` | bigSmoothPlastic | black | `World/Streetscape.luau:203`. Power lines; fine. |
| 6 | 192 | `Plots.Plot*.PadGui/Icon` | **FredokaOne ×96, emoji ×96** | — | `PlotService.luau` (`FONT = FredokaOne`, :130). Pad lock icons. |
| 7 | 160 | `Plots.Plot*.Emitter` | Neon, loud | (255,30,50) | `PlotService.luau:1324` |
| 8 | 152 | `Plots.Plot*.SignGui/Status` | **FredokaOne ×104**, loud text ×48 | — | `PlotService.luau` (pad signs "EMPTY / PARKED / UNLOCK $1.5K") |
| 9 | 120 | `Plots.Plot*.Pilaster` | bigSmoothPlastic | (206,198,180) | `PlotService.luau:951/955` |
| 10 | 96 ×3 | `Plots.Plot*.PadGui/Number`, `SignGui/Number`, `PadGui/Price` | **FredokaOne** | — | `PlotService.luau` |
| 11 | 60 | `Plots.Plot*.WallStrip` | **Neon, hot pink** | **(255,52,140)** | `PlotService.luau:911-912` `neon(building, "WallStrip", …, accent)` |
| 12 | 48 | `Plots.Plot*.TrimStrip` | **Neon, hot pink** | (255,52,140) | `PlotService.luau:923-924` |
| 13 | 48 | `Plots.Plot*.Parapet` | **loud hot pink** | (255,52,140) | `PlotService.luau:1002-1003` `deco(…, accent)` |
| 14 | 48 | `Plots.Plot*.SignTrim` | **Neon, hot pink** | (255,52,140) | `PlotService.luau:1382-1383` |
| 15 | 48 | `Plots.Plot*.SignGui/Title` | FredokaOne, **emoji**, loud text | — | `PlotService.luau` (CollectSign "💰 …") |
| 16 | 46 | `Map.Cells.*.Billboard` | bigSmoothPlastic + **cartoon ads** | — | Tagged in `MapBuilder.luau:55`, ads applied by `MapDresser.luau:128/265` (`adFor`) |
| 17 | 40 | `Map.POIs.HotwirePlaza/Value` + `/Rank` | **FredokaOne**, loud text, **emoji 🥇🥈🥉💰🚗** | Primary (255,52,140) | `LeaderboardService.luau:59` (`Primary = 255,52,140`), `:67` (`FONT_DISPLAY = FredokaOne`) |
| 18 | 36 | `Plots.Plot*.Mural/Label` | FredokaOne, loud text | — | `PlotService.luau:1438/1451` |
| 19 | 32+32 | `Plots.Plot*.DropoffEdge`, `Chevron` | Neon | (255,200,40) yellow | `PlotService.luau:1155-1156`; client `TutorialController.luau:564`, `WaypointController.luau:400` |
| 20 | 32+16 | `Plots.Plot*.BannerGui/Icon`, `/Text` | FredokaOne, **emoji** | — | `PlotService.luau:1106` |
| 21 | 24 ×5 | `WindowSill`, `AisleLine`, `DrivewayLine`, `CornerPillar`, `LightBar` | Neon, hot pink | (255,52,140) | `PlotService.luau:946 / 1049 / 849 / 928 / 1029` |
| 22 | 21 | `Map.Cells.*.GantrySign` | bigSmoothPlastic | (20,92,52) green | `World/Freeways.luau:290`: blank green slabs with no text |
| 23 | 16 ×6 | `Plots.Plot*.Gate` / `Beam1..5` / `LockButton` / `StatusLight` / `CollectPad` | Neon red / green | (255,30,50), (70,235,110) | `PlotService.luau:1340-1358` (laser gate) |
| 24 | 20 | `Dealership.Dressing` (`PlanterTrim`, `FlagCap`, `RoofBannerBase`) | **Neon, hot pink** | (255,52,140) | `DealershipService.luau:66` (`PINK = 255,52,140`), `:730 / :771 / :804`; FredokaOne at `:377` |
| 25 | 16 | `Map.POIs.Dealership` (Canopy) | bigSmoothPlastic, 1 Neon | — | `DealershipService.luau` / POI builder |

**By subtree:**
- `Map.Buildings` (all v2 building models): **Neon 1164, loud 0, emoji 0, cartoon 0.** The Neon there is lit windows, not pink.
- `Vehicles` and `Effects`: **0**.
- **So the v2 world itself is clean. The pink and cartoon all comes from four v1-era systems:**
  - **PlotService** (garages): `PlotService.ACCENTS[1] = Color3.fromRGB(255, 52, 140) -- hot pink` (:69-70), plus `FONT = FredokaOne` (:130).
  - **DealershipService**: `PINK` (:66), FredokaOne (:377).
  - **LeaderboardService**: `Primary` pink (:59), FredokaOne (:67), emoji medals.
  - **MapDresser**: cartoon billboard ads.

**Kill-list shots:**
- `k01_garage_exterior_neon` (PlotService exterior)
- `k02_garage_pads_fredoka` (PlotService interior pads)
- `k03_dealership_canopy` (DealershipService)
- `k04_plaza_leaderboards` (LeaderboardService; the boards render as **black panels with yellow neon frames** at noon, front unreadable)
- `k05_billboard_ads` (MapDresser: "COUCH CRUISER" cartoon ad)

The other five "worst" groups are covered by tour shots rather than separate `k` files:
- buried roads → `t02` / `t03` / `t16`
- empty civic boxes → `t10` / `t11` / `t12`
- rail yard → `t07`
- garage spawn interior → `t01`
- night freeway → `n04`

**I took 5 dedicated `k` shots, not the 10 asked for.**

## C. The first 10 seconds
- **`u01_loading`:** a clean black screen with "HOTWIRE *City*" bottom-left, a TIP line, LOADING 68% and an orange progress bar. **Good, GTA-like.**
- **`u02_first_frame` / `u03_first_objective`:** spawned **inside the garage** (see `t01`). The first things you read:
  - "Walk up to the car and hold E to hotwire it."
  - a toast "A playtime gift is ready! Tap GIFTS to open it. (x3)"
  - a red "LOCK GARAGE" button
  - "Steal a car." at the bottom
  - **The game's first frame is the most "Roblox tycoon" thing in it.**
- **`u04_pause`:**
  - **`Esc` opens Roblox's own system menu, not the game's** (`GuiService.MenuIsOpen`; it isn't visible in captures, see `u04a_esc_roblox_menu_hidden`).
  - **`P`** opens the game's pause menu: an excellent GTA-V-style MAP tab with district labels, POI icons and a legend.
  - A new player pressing Esc gets the Roblox menu.
- **`u05_phone` (`B`):** the "Fone" phone bottom-right with 9 app tiles. GTA-like enough, but the tiles are bubbly rounded iOS-style icons with red notification badges.
- **Roblox-isms I measured** (`StarterGui` / Humanoid on the client):
  - **The Roblox topbar is enabled** (GuiInset 58 px).
  - **Chat is enabled**, with **bubble chat on**.
  - **Name tags show:** `DisplayDistanceType = Viewer`, `NameDisplayDistance = 100`. An NPC "Halden Wren" floats over a car in the garage.
  - The **default R15 blocky avatar** (bacon hair) is visible in every shot, with the **default jump** (JumpPower 50).
  - The **default Roblox follow camera** (`CameraType = Custom`, FOV 70, `UserChoice` mode).
  - The player list is off, along with health, backpack and emotes ✅.

## D1. Top 20 GTA-vibe breakers (most damaging first)

| # | What | Where | Owner | What GTA V shows instead |
|---|---|---|---|---|
| 1 | **Every street and sidewalk buried under sand-coloured terrain** | `t02`, `t03`, `t09`–`t12`, `t16`; terrain at 13.59 vs Road 12.0 / Sidewalk 12.6 | `World/Terrain.luau` flat fast path (SINK at RES 4) | Dark asphalt with worn lane paint, kerbs, crosswalks, manholes, tar snakes |
| 2 | **The player spawns inside a neon-pink tycoon garage** | `t01`, `u02` | `PlotService` (interior build, pads, posters) | You spawn on a street or at your safehouse: a dim, grimy concrete garage with fluorescent tubes |
| 3 | **Hot-pink neon outline trim on garage exteriors** (WallStrip, TrimStrip, SignTrim, Parapet, CornerPillar, WindowSill, AisleLine, DrivewayLine, DriveOutRing, SignLogoTrim) | `k01`, `t08`; `Plots.Plot*.Building.*` | `PlotService.luau:69-70` `ACCENTS` (hot pink) via `neon()` / `deco()` at :849–1425 | Muted stucco or brick body, a painted sign, a steel roll-up door, maybe one small red neon "GARAGE" sign |
| 4 | **The default blocky Roblox avatar** (R15, bacon hair) | every shot | (the characters package) | A realistic human with a GTA-style third-person camera |
| 5 | **FredokaOne "bubble" font on world signs** (pads, signs, murals, banners, leaderboards, dealership) | `k02`, `k04`, `t01` | `PlotService.luau:130`, `LeaderboardService.luau:67`, `DealershipService.luau:377` | Condensed sans signage (like the HUD's), stencilled bay numbers |
| 6 | **The neon-pink dealership canopy and cyan/pink turntable rings** | `k03`, `t09`; `Workspace.Dealership.Dressing.*` | `DealershipService.luau:66` `PINK`, :730/:771/:804 | Premium Deluxe Motorsport: glass showroom, white tiles, chrome, spot-lit cars |
| 7 | **The world is empty**: no traffic, pedestrians or parked cars on v2 streets | `t02`–`t07`, `t16` | (traffic/NPC systems not wired to v2 roads) | Constant ambient traffic and pedestrians |
| 8 | **Cartoon billboard ads** ("COUCH CRUISER", "GOLD RUSH – you can't afford it", "HOT DROP SEASON") | `k05`, `t01`, `t09` | `MapDresser.luau:128/265` (`adFor`); the posters in PlotService | Parody ads in a photographic style (Pisswasser, Sprunk, Vinewood) |
| 9 | **Emoji in world text** (💰 $12/s, 🚗, 🥇🥈🥉, "💰 TOP EARNERS 💰") | `t08`, `k01`, plaza leaderboards | `PlotService` SignGui / BannerGui, `LeaderboardService` | No emoji in-world. Numbers live in the HUD or phone. |
| 10 | **Big orange "HOT DROP · CLAIM IT!" panel and event pills** (RUSH HOUR / CASH RAIN / 2X CASH) **pinned centre-top in every shot** | all tour shots | `EventsClient` / HotDrop UI (client) | GTA shows random events as a small blip plus a brief subtitle; nothing persistent mid-screen |
| 11 | **Empty civic boxes:** gun store, police HQ and hospital are flat grey slabs with one small sign | `t10`, `t11`, `t12` | BuildingService / POI templates for gun, police and hospital kinds | Ammu-Nation storefront with window posters; Mission Row PD with steps, flags and cruisers; Pillbox with an ambulance bay |
| 12 | **Night sky reddish-brown; freeway pitch black, lights don't light the deck** | `n02`, `n04` | `LightingService` night sky / grade; `Freeways` lamps (no light, or too weak) | Deep blue-black sky with city-glow haze; sodium-orange pools of light on the road |
| 13 | **Golden-hour haze wall** swallows the city from the low aerial | `g13` | `Look` golden density 0.18 + draw distance at Automatic quality | Warm, clear long views with gentle aerial perspective |
| 14 | **Rail yard and port are bare** (black bars on sand) | `t07` | `World` rails (no sleepers or ballast), no port dressing | Freight cars, containers, cranes, warehouses, chain-link |
| 15 | **Lollipop sphere trees** everywhere downtown | `t02`, `t03`, `t16`, `n02` | `World/Streetscape` tree kit | Real street trees (London plane, palm, jacaranda) with alpha leaves |
| 16 | **Candy-striped awnings and toy-town brick rows** in the hills | `t06` | BuildingService `hills_mansion` / `commercial` kit | Hillside mansions with gated driveways and hedges |
| 17 | **The Roblox topbar, chat bubbles and floating name tags** | `u02`, `t01` ("Halden Wren") | `StarterGui` / `Players` settings (client bootstrap) | No platform chrome in view; no overhead names |
| 18 | **Garage laser gate, glowing green collect pad, red "LOCK GARAGE" button** | `t01`, `u02` | `PlotService.luau:1340-1358`; GarageClient | A roll-up door you open with a remote |
| 19 | **Blank green freeway gantry signs** (no text) | `Map.Cells.*.GantrySign` | `World/Freeways.luau:290` | Real exit signs with route shields, distances and arrows |
| 20 | **`Esc` opens the Roblox menu, not the game pause menu** | `u04a` | input binding (`P` only) | Esc = pause/map |

## D2. The scan table
See the 25 rows in section B above. `scan.txt` has the raw output from both passes.

## D3. Errors (`console_start.txt`)
- **Server:** no script errors from game code.
  - **17× `Failed to upload TexturePack (… HTTP StatusCode: 429 … "RESOURCE_EXHAUSTED", "Rate limit exceeded for TexturePack uploads…")`** at 23:11:21, on both Server and Client. These are engine SurfaceAppearance uploads being rate-limited (probably the new car and building PBR); none occurred on the second boot.
  - ~110 `Asset content representation is being generated` warnings across ~67 ids (assets still processing).
  - One `HTTP 502`.
  - The pre-existing v1 "Asset type does not match" ids.
- **Client:** `[MinimapController] slow GPS route` warnings, from 8.1 up to **48.2 ms**.
- Nothing names MapBuilder, World, BuildingService, AssetLibrary, CarBuilder, Vehicle, MapLayout, PlotService, Dealership or Leaderboard.
- **Mine, not the game's:**
  - `GetBoundingBox is not a valid member of Folder "Workspace.Dealership"` (my probe).
  - Two `[VehicleService] watchdog teleport … -> rewind`, from teleporting while seated. That's correct anti-cheat behaviour.

## D4. What already works: protect it
- **The v2 island layout and skyline** (`t13`, `t14`): ring freeway, a believable downtown with varied glass and stone towers, suburbs, port, airport, mountain, and the "SUNWOOD" hillside sign. Downtown building models have **no pink or cartoon at all**.
- **The realistic cars** (`t15`, `t16`): the Kronberg K8 looks properly GTA. 30/30 templates built.
- **The elevated freeway deck** (`t04`): asphalt, markings and barriers. The one place the road reads right.
- **The water, shoreline and sky** (`t05`).
- **Traffic signals:** working red, amber and green phases, which glow correctly at night.
- **The HUD:** square radar, thin bars, white cash, district name in script; the loading screen; and the **pause MAP**, which is the most GTA-like screen in the game.
- **Night windows and streetlamps downtown** (`n02`) read well apart from the sky.

## Files
- **Tour shots:** `t01`–`t16` (plus first tries `t07a`, `t09a`), `g02`, `g13`, `n02`–`n04`.
- **Kill-list shots:** `k01`–`k05`.
- **UX shots:** `u01`–`u05` (and `u04a`).
- **Logs:** `console_start.txt` (includes the tour and section C notes) and `scan.txt`.
