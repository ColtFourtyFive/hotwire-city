# v1 → v2 world migration

v1 is built on a square grid:
- `Config/Map.luau` holds constants: 160-stud spacing, 40-wide roads, `Blocks`, `Plots`, `Garage`.
- `Util/MapLayout.luau` holds grid math.
- `MapBuilder` builds a toy city of about 9k parts from those two.

v2 is built on data:
- `Config/WorldLayout.luau` holds the island as data: an explicit multi-level road graph, districts, lots, POIs, plots, spawns, zones and routes.
- `Util/WorldQuery.luau` answers runtime questions about it.
- `Util/WorldGen.luau` holds the shared geometry and graph algorithms.

Design: `WORLD_SPEC.md`. Tests: `tests/spec/worldlayout.spec.luau`.

**Rules for migrating code**
1. **No grid math anywhere.** Remove every use of `GRID_SPACING`, `LINE_MIN/MAX`, `BLOCK_*`, `HALF_EXTENT`, `math.round(x / S)`, or "Manhattan" routing. Roads are curves at many angles and on several levels.
2. **Ask WorldQuery; don't recompute.**
   - Nearest road: `nearestRoadPoint` / `nearestLane`.
   - On a road: `isOnRoad`.
   - Districts: `districtAt`.
   - Lots: `parcelAt`.
   - Routing: `route`.
   - Signals: `signalState`.
3. **Plot-local geometry keeps its contract.** `WorldLayout.Plots[i].cframe` is the ground center of the garage footprint, with LookVector pointing out of the door. That is exactly v1's `plotOrigin(i)`, so every `Config/Map.Garage` local offset (slots, drop-off, collect pad, lock button, door) keeps working unchanged. The reserved footprint is 140 × 150 (v1's garage is 96 × 92 plus walls), which leaves a ~30-stud driveway apron in front.
4. **Heights are real.** The city grade is Y 12 (it was 0) and the sea is Y 0. Hills, decks (Y 40), flyovers (Y 66) and the channel floor (Y −6..−9) all exist. Never assume `ROAD_Y`; take Y from the edge points / `edgePoint`, or from `WorldLayout.heightAt`.

---

## 1. MapLayout function by function

| v1 `MapLayout` | v1 contract | v1 callers | v2 replacement |
|---|---|---|---|
| `CURB_TOP` | `ROAD_Y + CURB_HEIGHT` | MapBuilder, NPCService | `roadY + WorldLayout.Scale.CURB_HEIGHT`, where `roadY` is the edge's Y at that point (`WorldQuery.edgePoint`). Sidewalk walkers use `WorldQuery.sidewalkCFrame(edge, side, s)`, which is already at curb-top height. |
| `lineCoord(line)` | Grid line → coordinate | (internal) | Gone. |
| `blockCenter(bx, bz)` | Center of a grid block | MapBuilder, NPCService | There are no blocks. Use **lots**: `WorldLayout.Parcels[i].cframe`, or `WorldQuery.parcelAt(pos)`. NPC "pick a nearby block" → pick a nearby edge with a sidewalk and walk its `sidewalkCFrame`. |
| `blockAt(pos)` | Block indices | NPCService | `WorldQuery.parcelAt(pos)` (the lot) or `WorldQuery.districtAt(pos)` (the area). |
| `isOnRoad(pos)` | Inside a grid road strip | PoliceService | `WorldQuery.isOnRoad(pos, margin?)`. Curb to curb, within 6 studs of that road's height, so a car under the freeway is on the street, not on the deck. Also returns the edge. |
| `plotCount()` | `#Map.Plots` (8) | Garage/Plot/StreetSpawn/Vehicle services, GarageClient, Waypoint | `WorldQuery.plotCount()` (8). |
| `plotOrigin(i)` | Block center, Look = out of the door | Plot/Garage/Police/StreetSpawn services, Tutorial | `WorldQuery.plot(i).cframe` (same semantics; Y = street level at the frontage). |
| `plotToWorld(i, offset)` | `plotOrigin(i) * CFrame.new(offset)` | Plot/Theft/StreetSpawn/Admin/Garage services, Tutorial | `WorldQuery.plot(i).cframe * CFrame.new(offset)`. |
| `slotLocal(slot)`, `slotWorld(i, slot)`, `maxPhysicalSlots()` | Garage slot pads | PlotService, Garage/Theft/Rewards services, GarageClient | Unchanged math on `plot(i).cframe`. These stay garage-owned: move them to a `Util/GarageLayout` that uses `Config/Map.Garage`, or a v2 `Config/Garage`. |
| `plotDropoffZone(i)`, `plotInteriorZone(i)` | Boxes in the plot frame | Theft/Vehicle/Plot services, Tutorial, Waypoint, GarageClient | Unchanged math on `plot(i).cframe`. |
| `isInBox(cf, size, pos)` | OBB test | Plot/Wanted/Vehicle services, Tutorial | Pure helper. Move it to `Util/GarageLayout`, or keep it in a thin MapLayout shim (§6). |
| `plotAt(pos)` | Plot whose garage interior contains pos | 9 callers (police safety, theft, combat, HUD…) | `WorldQuery.plotAt(pos)` tests the reserved footprint (pos.Y from −4 to +60). Where "inside the garage building" matters, keep v1's interior-box test on `plotInteriorZone`. |
| `roadCFrame(axis, line, along, dir)` | Centerline CFrame | (internal) | `WorldQuery.edgePoint(edge, s)` → (point, tangent). |
| `laneCFrame(axis, line, along, dir)` | Lane 8 right of center | PoliceService | `WorldQuery.laneCFrame(edge, lane, dir, s)`. Lane 1 is innermost; `laneCount(edge, dir)`; `dir` = +1 for a→b, −1 for b→a; `s` is always measured from node a. |
| `parkingSpots()` | ~120 grid curb spots | StreetSpawnService | `WorldLayout.Spawns.parking`: 7,385 `{ cframe, edge, district, tier }`. Spawn by `tier` (soft progression) and near players. |
| `poiCenter(name)` | Block center of a named POI | Event/Admin/NPC/Dealership services, Tutorial, EventsClient, MapBuilder | `WorldQuery.poi(id).cframe` (footprint center) or `.entrance` (curb point at the door). Name map below. |
| `spawnCFrame()` | Spawn plaza | MapBuilder | Players spawn in their garage (`plot.cframe * Garage.OWNER_SPAWN`). Fallback: `WorldLayout.Spawns.default` (Hotwire Plaza). |
| `dealerPads()` | 8 pads around the dealership center | DealershipService, MapBuilder | Local layout on `WorldQuery.poi("Dealership").cframe` (220 × 170). For example, two rows of four: `cf * CFrame.new(x, 0, z)` for x in {−75, −25, 25, 75} and z in {−35, 35}. Cars face the street (`cf.LookVector`). |
| `sprayZones()` | 2 drive-in boxes | Wanted/Vehicle services, MapBuilder, Waypoint | One per `WorldQuery.poisOfKind("spray")` (5): box `poi.cframe * CFrame.new(0, 13, -poi.size.Z/2 + 30)`, size `(poi.size.X - 20, 26, 50)`. That is the bay at the street side; local −Z faces the street. |
| `chopZone()` | 1 box | Vehicle/Garage services, MapBuilder | One per `poisOfKind("chop")` (2: Rusty's Chop Shop, Dockside Salvage). Same front-bay formula. |
| `gearShopCounter()` | Counter CFrame | ShopService, NPCService, MapBuilder | Gun shops: `poisOfKind("gunshop")` (4 Lock & Load). Counter at `poi.cframe * CFrame.new(0, 0, -poi.size.Z/2 + 12)` facing the door. |
| `policeSpawns()` | 4 lanes around the HQ | PoliceService | `WorldLayout.Spawns.police`: `{ cframe, station, edge }`, 4–8 per station across 8 stations. Respawn from the station nearest the suspect. |
| `bustedReleaseCFrame()` | HQ sidewalk | Wanted/Plot services | `WorldLayout.Spawns.bustedRelease` (HCPD HQ steps). |
| `hotDropCFrames()` | 10 points on roads | EventService | `WorldLayout.HotDrops` (12 zones). The landing point is `WorldQuery.nearestRoadPoint(zone.cframe.Position, { ignoreHeight = true })`, or anywhere inside the zone box (open lots and plazas). |
| `nearestLane(pos)` | Lane on the closest grid road | PoliceService | `WorldQuery.nearestLane(pos, heading?)`. Legal direction, outer lane, the direction nearest `heading`. |
| `roadSegments()` (optional hook) | RoadGraph source | RoadGraph | See §3. |

**v1 POI names → v2 ids**

| v1 `Map.Blocks` | v2 |
|---|---|
| `SpawnPlaza` | `HotwirePlaza` (`plaza`; cash rain, events) |
| `Dealership` | `Dealership` (Hotwire Motors) + `LuxuryDealer` |
| `PoliceHQ` | `PoliceHQ` (+ 7 precincts) |
| `GearShop` | `GunSouthgate`, `GunFoundry`, `GunBeach`, `GunCactus` (kind `gunshop`) |
| `SprayShopA/B` | `Spray*` (kind `spray`, 5) |
| `ChopShop` | `ChopShop` (+ `ChopPort`) |
| `StuntPark` | `WorldLayout.StuntJumps` (12) |
| `Park` | Echo Park: landmark `StadiumLights` + path `Echo Park Loop` |
| `Pier` | Landmark `PalmeraPier` + the drivable `Palmera Pier` road edge |

## 2. Config/Map constants

| v1 constant | Used by | v2 |
|---|---|---|
| `GRID_SPACING`, `LINE_MIN/MAX`, `BLOCK_MIN/MAX`, `HALF_EXTENT` | Traffic, Police, NPC, StreetSpawn, Plot, MapBuilder, RoadGraph | **Remove.** Use graph edges and lots. |
| `ROAD_WIDTH`, `LANE_OFFSET`, `PARK_OFFSET` | Traffic, Police, StreetSpawn, NPC | Per edge: `edge.width`, `WorldQuery.laneOffset(edge, lane, dir)`, `parkingCFrame(edge, side, s)`. |
| `ROAD_Y` | Traffic, Police | The edge's point Y (`edgePoint`). |
| `CURB_HEIGHT`, `SIDEWALK_WIDTH` | Plot, MapBuilder | `Scale.CURB_HEIGHT` (0.6); `edge.sidewalk` (10–14). |
| `WATER_LEVEL` (−2) | Police/Theft/Vehicle "lost car" | `WorldLayout.SEA_LEVEL` (0). Lost below `SEA_LEVEL - 6`; the void is below `Bounds.min.Y`. Note: the Rust River floor is at −9 but dry, so use `WorldQuery.isWater(pos)` before declaring a car sunk. |
| `SAND_EXTENT`, `WATER_EXTENT`, `BOUNDARY` | Police (lost target), MapBuilder | `WorldLayout.Bounds` (`playMinX…`) for walls. "In the sea" is `WorldQuery.isWater(pos)`. |
| `DOWNTOWN_RADIUS` | MapBuilder, RoadGraph | `districtAt(pos).id == "downtown"`; skyline falloff is in `District.peak`. |
| `Plots` | Admin, MapBuilder | `WorldLayout.Plots`. |
| `Blocks` | Admin, MapBuilder | `WorldLayout.POIs` (name map above). |
| `Garage` | Plot/Garage/Theft/StreetSpawn services, Tutorial | **Keep.** It is plot-local. Move it to a v2 `Config/Garage` when the garage interior is redone. |
| `HotDropPoints` | MapLayout | `WorldLayout.HotDrops`. |

## 3. Per-system notes

- **RoadGraph (GPS, police).**
  - **The problem.** v1's builder splits *segments* and keys nodes by `level`. It cannot express ramps that join two levels, which is why v2 carries an explicit node/edge graph.
  - **The fix.** Add `RoadGraph.fromWorld()`, which fills `GraphData` straight from `WorldLayout.Nodes` / `Edges`:
    - `nodes[i] = Nodes[i].pos`, `edges[k] = { a, b, length, width, class, oneWay, lanes = lanesF, level = layer, name }`;
    - adjacency from `oneWay`;
    - spatial hashes as today.
  - The A* and queries stay as they are. Until then, `WorldQuery.route(from, to, { traffic })` gives the same polyline.
  - **Class mapping for minimap colors:**

    | v2 classes | RoadGraph class |
    |---|---|
    | `freeway`, `ramp`, `highway` | `highway` |
    | `boulevard`, `avenue` | `avenue` |
    | `street`, `rural`, `pier`, `runway` | `street` |
    | `alley`, `dirt`, `service`, `channel` | `alley` |

- **TrafficService.**
  - Replace the grid lane state machine with an edge walker:
    - state `{ edge, dir, lane, s }`;
    - position from `laneCFrame`;
    - at `s` = edge length − intersection radius, choose an exit from `WorldQuery.outgoing(node)`, excluding the U-turn edge, weighted toward the same name or class;
    - drive a quarter arc between the two lanes' CFrames.
  - Stop at the stop line when `signalState(intersection, approachIndex, now) ~= "green"`. Approach index = `table.find` of the edge in `Intersections[id].approaches`.
  - Stop and yield at `stop` and `allway` junctions.
  - Spawn on `Spawns.traffic` edges, weighted, 150–450 studs from players.
  - Freeways: carriageways are one-way, 2–3 lanes; ramps feed them at merge nodes.
  - Keep the PERF-02 mover writes.
- **PoliceService.**
  - Delete `_roadAnchor`, `_roadLines`, `_nextWaypoint` and the Manhattan cost.
  - Out of sight: `WorldQuery.route(unitPos, suspectPos)` (all roads; cops do enter the channel and the pier), re-routed every ~1 s, and follow the polyline with the existing pure-pursuit controller.
  - In sight within 150: direct pursuit as today.
  - Respawn on `WorldQuery.nearestLane(nearSuspect, suspectVelocity)`, at least 200 away and out of view.
  - Spawn sets come from `Spawns.police` (nearest station).
  - The "suspect left the island" check: `WorldQuery.isWater(pos)`, or outside `Bounds`.
- **StreetSpawnService.**
  - `Spawns.parking` replaces `parkingSpots()`. Roll rarity from `spot.tier`, so district progression is preserved.
  - The newbie car goes on `plot.curbSpot` (the curb lane next to the driveway), then nearest spots from `Spawns.parking` within ~150 of `plot.door`.
- **NPCService.**
  - Pedestrians walk sidewalks: pick an edge with `sidewalk > 0` near the player, walk `sidewalkCFrame(edge, side, s)`, and at the end node continue on a neighbouring edge's sidewalk (turn at the junction radius). Cross only at `signal` / `allway` junctions.
  - Extra walk areas: `WorldLayout.Paths` (boardwalk, palm park, Echo Park, plaza).
  - Shopkeepers stand at the POI counters (gun shops, stores, the dealership).
  - `_clampToBlock` → keep fleeing NPCs off the asphalt with `isOnRoad`.
- **EventService.**
  - Hot Drops: pick from `WorldLayout.HotDrops` (12 zones).
  - Cash Rain: around `poi("HotwirePlaza")`.
  - The armored truck every ~5 min: pick from the `WorldLayout.Routes` entries with `kind == "armored"` (4 runs, 4.2k–6.9k studs) and drive `route.path` with the traffic walker at ~55 studs/s, stopping at `route.stops`.
  - Races: the `kind == "race"` entries. Checkpoints are `stops`, the line is `path`.
  - Restricted zones: `WorldLayout.RestrictedZones` adds heat on entry.
- **WantedService / VehicleService zones.**
  - Spray: `poisOfKind("spray")` bays.
  - Chop: `poisOfKind("chop")` bays.
  - Drop-off: the plot boxes, as before.
  - Busted release: `Spawns.bustedRelease`.
  - Hospitals: WASTED → `WorldQuery.nearestPOI(pos, "hospital")` + the matching `Spawns.hospital` CFrame; safe-zone protection from `WorldLayout.SafeZones`.
- **DealershipService.** Pads in the local frame of `poi("Dealership").cframe` (§1). The luxury dealer, `LuxuryDealer`, can host the expensive stock.
- **ShopService / CombatService.** Gun shops are the 4 `gunshop` POIs, and the prompt goes at each counter. Combat's "inside own garage" rule is unchanged (plot interior box).
- **AdminService.** `tp` targets: plot names, POI ids, landmark ids.
- **Tutorial, Waypoint, GarageClient, HUD, EventsClient.**
  - Plot math is unchanged, on `plot(i).cframe`.
  - The dealership arrow targets `poi("Dealership").entrance`.
  - The spray arrow targets the nearest `spray` POI by `WorldQuery.route` length.
  - Plaza references become `HotwirePlaza`.
- **Minimap and map screen.** These are owned by the minimap workflow. Have its exporter read `WorldLayout` directly: edges with class, width and layer; parcels; POIs; districts; water. That replaces dumping MapBuilder parts. `tools/world/export_layout.luau` already emits all of it as JSON.

## 4. What MapBuilder v2 must build

MapBuilder v2 is a pure *renderer of WorldLayout*. It reads nothing from `Config/Map`, and it never decides geometry on its own.

### 4.1 Terrain

- Write voxels from `WorldLayout.heightAt(x, z)` on a 4-stud grid, in chunks. Rough sizes: island 12k × 9k → about 3,000 × 2,200 columns, done as 64 × 64 regions with `Terrain:WriteVoxels`. Bake it in Studio once, then hash-check at boot (§5).
- Materials by `TerrainZones`, height and slope:

  | Where | Material |
  |---|---|
  | Basin under the city | Concrete or Asphalt |
  | Beach band | Sand |
  | Hills | Grass / LeafyGrass, with Rock on slopes over 35° |
  | Foothills and desert | Ground / Sandstone, with Sandstone mesas |
  | Channel | Concrete |
  | Quays | Concrete |

- Water: the ocean is everything below sea level outside the coast polygons (fill up to Y 0). The reservoir is at `Water[].level`. **No water in the Rust River** north of its flood gate at `Channel.gateZ`.
- Grade the terrain to the roads. Along each ground edge, flatten a corridor of `width/2 + sidewalk + 4` to the road Y, with 2:1 side slopes for the `fill` / cut. Under each lot, level a pad at `parcel.cframe.Y` (hills lots get terraces and retaining walls).

### 4.2 Roads

These are built per edge, along `points`. Every polyline segment is one asphalt slab. Corners are mitred, and joints use a small overlap or a wedge. Widths and offsets all come from the edge.

- **Surface.**
  - Asphalt over `width`, with an **asphalt MaterialVariant** (cracked, patched).
  - Medians when `median > 0`. Planted medians on boulevards: a 0.6 curb, grass, and palms every ~40 studs.
- **Markings** are textures or decals on the slab, never parts:

  | Marking | Where |
  |---|---|
  | Double yellow centerline | Two-way roads without a median |
  | Dashed white lane lines | Every `LANE` |
  | Solid white edge lines | Along parking lanes and road edges |
  | Parking bay ticks | Parking lanes |
  | Stop lines | At `stop`, `allway` and `signal` junctions |
  | Zebra crosswalks | At `signal` and `allway` |
  | Lane arrows | Before signals |
  | "ONLY" | One-way streets |

- **Curbs and sidewalks.** A 0.6-stud curb, then a sidewalk of `sidewalk` width in concrete-paver MaterialVariants. Add curb ramps at crosswalks, and driveway cuts at lot fronts, plot doors and POI entrances.
- **Intersections.**
  - An asphalt box of `radius` filling the node area, with corner fillets about 1.5 × the sidewalk.
  - At signals: a signal mast per approach. Heads read `WorldQuery.signalState` client-side and are meshes.
  - Stop signs at `stop` and `allway`.
- **Freeway decks** (`elevated`, `corridor` set).
  - One deck per corridor segment spanning both carriageways: deck 3 thick, Jersey barriers 3 tall on both outer edges and down the middle.
  - Ramps and flyovers get their own decks.
  - **Piers** every 80–100 studs, placed in the median or under the deck edge, and never inside a ground road's footprint. Query `WorldQuery.isOnRoad` at the pier base, and shift along the deck to clear.
  - Lights every 120 studs and overhead sign gantries before each ramp diverge.
  - Underside shadows matter: this is the GTA look.
- **Bridges** (`bridge = true`).
  - Street bridges over the Rust River are concrete girders with railings.
  - **Iron Bay Bridge** (H2) is cable-stayed with two pylons 160 tall.
  - **Harbor Bridge** is a low steel truss lift bridge.
  - The **Canyon Bridge** on Skyline Drive is an arch.
- **Channel.** Concrete floor `2 × floorHalfWidth` wide, sloped walls with a run of `wallRun`, a trickle strip down the middle, ramps (`Channel Ramp North/South`) cut into the walls, and a flood gate at `gateZ`.
- **Specials.**
  - **Pier**: wooden deck on piles, with rails, the arcade and the wheel at the end.
  - **Runway**: concrete, centerline, threshold bars and edge lights.
  - **Rail**: tracks along `Rails`; crossing gates at `LevelCrossings`.
- **Street furniture**, by district style:

  | Item | Spacing / placement |
  |---|---|
  | Lamps | Every 90 studs (downtown) / 120 (suburbs), alternating sides |
  | Trees and palms | Beach and boulevards |
  | Hydrants and trash cans | Near corners |
  | Bus stops | On avenues every ~600 studs |
  | Billboards | Highway and ring sides |

  Use meshes where possible, and spend parts only on what can't be a mesh.

### 4.3 Lots → buildings

For each `Parcel`, build within its `cframe` and `size`, with the front facing the street:

| `use` | Building |
|---|---|
| `office_tower`, `residential_tower`, `hotel` | Podium (1–3 floors of retail glass) + shaft (curtain wall or punched windows by `style`) + crown / rooftop machinery, to `size.Y`. Height in floors = `floors`. |
| `office_midrise`, `apartment`, `loft`, `beach_hotel`, `motel` | Facade kit from the Blender building kit, with district materials (`District.materials`) as **MaterialVariants**. |
| `house`, `duplex`, `mansion`, `villa`, `farmhouse` | Mesh kit with a yard: front lawn = setback, driveway, fences. Mansions get pools and hedges. |
| `retail`, `restaurant`, `corner_store`, `retail_strip`, `shop`, `diner`, `nightclub`, `gallery`, `brewery` | 1–3 storey shopfronts with awnings and signs (our brands). |
| `warehouse`, `factory`, `shed`, `hangar`, `barn` | Large boxes: corrugated metal, roof vents, loading docks facing the street. |
| `parking_garage` | Decks with ramps (the `sj_garage` stunt jump uses one). |
| `parking_lot`, `plaza`, `park`, `yard`, `container_yard` | Open: paving and stall markings, plaza paving with trees, grass with paths, container stacks. |

`seed` drives deterministic variety: window rhythm, color, rooftop clutter.

### 4.4 POIs and landmarks

- Every POI has a footprint (`cframe`, `size`), an `entrance` curb point and its `kind`. Build:
  - the kind's structure;
  - a branded sign (brand in `POI.brand`, e.g. "Lock & Load", "Fresh Coat", "QuikStop 24");
  - the interaction parts the system expects (counter, spray bay, chop bay, showroom pads).
- Landmarks are `WorldLayout.Landmarks`. Each has a CFrame, a size and a note. Highlights:
  - the 720-wide SUNWOOD sign, lit at night;
  - Pinnacle Tower (a POI with a lot);
  - the Palmera Wheel;
  - cranes and the container ship;
  - the lighthouse;
  - the wind farm;
  - the dam;
  - the Speedway;
  - the control tower.
- Garages are still built by `PlotService` on `Plots[i].cframe`.

### 4.5 Budget and streaming

- Target **≤ 60k parts before meshes**. The data estimate is about 55k (`WORLD_SPEC.md` §9).
- Set `Workspace.StreamingEnabled = true`:
  - `StreamingTargetRadius` 1,024, `StreamingMinRadius` 256;
  - buildings as `ModelStreamingMode = Atomic`;
  - towers, landmarks and the SUNWOOD sign with `LevelOfDetail = StreamingMesh`, so the skyline renders at any distance;
  - the road deck the local player is driving on kept persistent nearby (or prefetched with `RequestStreamAroundAsync` along `route`).
- Never parent the whole map to one model. Chunk it into 512-stud cells (`Map/Cells/x_z`) so streaming and LOD work.

## 5. Boot, determinism, baking

- `WorldLayout` is deterministic: the same output every run, in Roblox or Lune, guarded by a test. It uses no `Random`, only integer hashes.
- Building it takes about 3 s in Lune. Clients also need it, for the GPS, minimap and HUD, so ship a **baked** module:
  1. Add `tools/world/bake.luau`. It requires `WorldLayout` through the harness and writes `src/shared/Config/WorldLayoutBaked.luau`: plain arrays of numbers for edges, nodes, parcels and spawns, plus a content hash.
  2. Make `WorldLayout` return the baked tables when the baked hash matches its own source hash, and generate otherwise (Studio / tests).
- Add `--!native` to `WorldGen` and `WorldLayout` on the server if live generation is kept.

## 6. Suggested order

1. **Shim.** Rewrite `Util/MapLayout.luau` as a thin layer over WorldQuery, keeping the same names:
   - `plotOrigin` → `plot(i).cframe`;
   - `poiCenter` → POI map;
   - `parkingSpots` → `Spawns.parking` CFrames;
   - `isOnRoad`, `nearestLane`, `laneCFrame` take an edge-based overload.

   Every v1 caller keeps compiling while systems migrate one at a time. Retire `Config/Map` except `Garage`.
2. **MapBuilder v2 + terrain bake.** Without a world nothing else can be seen in Studio.
3. **TrafficService + RoadGraph.fromWorld + PoliceService routing.** These are the biggest grid dependencies.
4. **StreetSpawn, NPC, Events, Dealership, Shop, Wanted/Vehicle zones, Tutorial / Waypoint.**
5. **Delete the shim and the old specs.** `tests/spec/maplayout.spec.luau`, `map.spec.luau` and similar test the grid.
