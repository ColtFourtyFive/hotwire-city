# GTA vibe routing: job 0018 kill list to owning packages (binding)

**Source:** Studio job 0018 on place v33, which is branch `v2/preview` = main + v2/world + v2/buildings + v2/vehicles.
- `docs/v2/evidence/vibe_0018_report.md` holds the top-20 table, the scan and the GTA V targets.
- `vibe_0018_sheet.jpg` is the contact sheet; `vibe_0018_scan.txt` is the raw scan.

**The owner's verdict:** the players, maps, buildings, surroundings and UX "don't feel like GTA at all". Every package below must close its rows and say so in its final report.

**The v2 world itself is clean.** The 1,164 Neon parts in `Map.Buildings` are lit windows; there is no pink, no cartoon font and no emoji. Every pink, FredokaOne and emoji hit comes from four v1-era systems:
- PlotService;
- DealershipService;
- LeaderboardService;
- MapDresser ads.

| # | Vibe breaker (0018 rank) | Owner package | Concrete target (GTA V) |
|---|---|---|---|
| 1 | Roads and sidewalks buried under sand terrain (#1) | **world** | **FIXED** by the lead in `v2/world` fe0523c (`Terrain.ENGINE_LIFT`: the engine surfaces terrain RES/2 above the written occupancy, measured by an engine probe). The world package re-verifies in its preview and evidence. |
| 2 | Player spawns inside the neon tycoon garage (#2) | **vibe** (PlotService) + **world** (`MapLayout.spawnCFrame`) | First spawn on a street at the downtown spawn point (WorldLayout). The garage becomes a dim, grimy concrete safehouse garage with fluorescent tubes. |
| 3 | Hot-pink neon outline trim on garage exteriors (#3, scan rows 11–14, 21) | **vibe** | Muted stucco or brick, a painted sign and a steel roll-up door. Remove `ACCENTS[1]` pink and every `neon()`/`deco()` outline. |
| 4 | Blocky default avatar, default camera, default jump (#4) | **characters** | Realistic bodies, the creator, the GTA foot camera, a heavier jump |
| 5 | FredokaOne on world signs (#5, rows 6, 8, 10, 15, 18, 20) | **vibe** (Plot, Dealership); **polish** (Leaderboard) | Condensed sans (Oswald or Montserrat), stencilled bay numbers |
| 6 | Pink dealership canopy and cyan/pink turntable rings (#6, rows 24–25) | **vibe** | A glass showroom with white tile, chrome and spot-lit cars |
| 7 | The world is empty: no traffic, pedestrians or parked cars (#7) | **life** (traffic + peds) | Constant ambient traffic, pedestrians, and parked cars along the kerbs |
| 8 | Cartoon billboard ads ("COUCH CRUISER", "GOLD RUSH", "HOT DROP SEASON") (#8, row 16) | **vibe** (`MapDresser.adFor` content + Plot posters). The world owns the billboard structures only. | Photographic parody ads from the CityArt pack, with no cartoons |
| 9 | Emoji in world text (#9) | **vibe** (Plot); **polish** (Leaderboard) | No emoji in the world; numbers live in the HUD or phone |
| 10 | HOT DROP panel and event pills pinned centre-top in every shot (#10) | **polish** | A small blip plus a brief subtitle and a feed line, never persistent mid-screen |
| 11 | Empty civic boxes: gun store, police HQ and hospital are grey slabs (#11) | **vibe** (shopfront and precinct dressing) + **buildings** (POI templates) | An Ammu-Nation-style storefront with window posters; a precinct with steps, flags and cruisers; a hospital with an ambulance bay |
| 12 | **[sky merged to main: `v2/look-night` f764725, pending Studio job 0012; freeway lamps still with world]** Night sky reddish-brown; freeway pitch black with lamps that light nothing (#12) | **look-night** (sky and grade) + **world** (Freeways lamps: real light pools) | A blue-black sky with city glow; sodium-orange pools of light on the deck |
| 13 | **[merged to main: golden preset retuned, pending Studio job 0012]** Golden-hour haze wall from the low aerial (#13) | **look-night** (Look golden density / haze) | A warm, clear long view |
| 14 | Rail yard and port are bare (#14) | **world** (rail sleepers and ballast; port dressing using the v2/props-setpieces cranes, containers and ship) | Freight cars, containers, cranes, warehouses, chain-link |
| 15 | Lollipop sphere trees (#15) | **world** (Streetscape tree kit) + **props** (v2/props vegetation) | Real street trees (palms, plane trees, jacaranda) with alpha leaves |
| 16 | Candy-striped awnings and toy-town brick rows in the hills (#16) | **buildings** | Muted canvas awnings and hillside mansions with gates and hedges |
| 17 | Roblox topbar, chat bubbles, floating name tags (#17) | **polish** (CoreGui, TextChatService bubbles) + **characters** (`NameDisplayDistance`) | No platform chrome; no overhead names |
| 18 | Garage laser gate, glowing collect pad, red "LOCK GARAGE" button (#18) | **vibe** (PlotService visuals) + **polish** (GarageClient button styling) | A roll-up door opened with a remote; the collect pad as a subtle floor marker |
| 19 | Blank green freeway gantry signs (#19) | **world** (Freeways) | Exit signs with route shields, distances and arrows (our place names) |
| 20 | Esc opens the Roblox menu, not the game pause (#20) | **polish** | Roblox reserves Esc. Make P and M obvious (help text on the first pause), and open the game's pause MAP whenever the Roblox menu closes after being opened in the first minute. Document the limit. |
| 21 | Brown terrain cliff step along the beach shoreline (t05) | **world** (Terrain shore blend) | A gentle beach slope into the water |
| 22 | Slow GPS route (up to 48 ms) on the v2 road graph | **world** (RoadGraph performance) | A route in under 4 ms; cache it and use A* with a heuristic |
| 23 | 17× TexturePack upload 429 on the first boot | (engine; watch it) | Note only |

**Protect** (D4 of the report):
- the island layout and skyline;
- the v2 cars;
- the freeway deck;
- the water and sky;
- the signals;
- the HUD;
- the loading screen;
- the pause MAP;
- night windows downtown.
