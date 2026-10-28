# Job 0018b: terrain-fix recheck (place v34+)

- **Place:** opened from Roblox at v34+ by the owner, **no Rojo, not saved or published.**
  - In Edit, `ServerScriptService.Server.Systems.World.Terrain` contains `Terrain.ENGINE_LIFT = Terrain.RES / 2`.
  - Solo Play; 90 s for the world build; noon lock.
- **Step 1:** on the Server, `require(game.ServerScriptService.Server.Systems.World.Terrain).ENGINE_LIFT` = **2** ✅ (RES 4, SINK 0.4).

## Step 2: terrain surface vs part tops (7 sites, the same as 0018)
Raycast against Terrain only, plus `GetPartBoundsInBox` at each site.

| Site | v33 terrain top | **v34 terrain top** | Part tops | Result |
|---|---|---|---|---|
| Crown Blvd (-300,-250) | 13.59 Ground | **12.00 Concrete** | Road 12.01, Median 12.61 | ✅ road visible |
| Downtown ix (-215,-205) | 13.59 | **12.00 Concrete** | Road 12.01, Sidewalk 12.61 | ✅ |
| Hospital front (880,-860) | 13.59 | **12.00 Concrete** | (no parts) | ✅ |
| Gun store (2350,-280) | 13.59 | **11.61 Ground** | Road 12.00 | ✅ |
| Police HQ (-620,350) | 13.59 | **12.00 Concrete** | Sidewalk 12.61 | ✅ |
| Dealership (-1754,926) | 13.59 | **11.61 Ground** | Road 12.01, Sidewalk 12.61 | ✅ |
| Mission Ave (1600,670) | 13.59 | **12.00 Concrete** | Road 12.01 | ✅ |

**The fix works:**
- Off-road ground now sits at **11.61**, exactly the intended 0.4 under grade.
- Nothing pokes through the sidewalks: 0.61 clearance.

**⚠️ One residual issue: road corridors.**
- Inside graded road corridors the terrain is at **12.00 (Concrete)**, only **0.01 under the Road top (12.01)**.
- A cross-section of Crown Blvd every 10 studs shows `gap 0.01` on every Road sample, and 0.61 under the sidewalk and median.
- The header says corridors should be graded **0.9 under the road top** (`ROAD_SINK`), so 11.1 was expected.
- So the corridor grading path doesn't apply `ENGINE_LIFT` the same way: it looks like it lands one quantum high, or ENGINE_LIFT is cancelled by the ROAD_SINK rounding.
- **Effect:** asphalt and terrain concrete are nearly coplanar.
  - From standing height the road reads fine.
  - Close up (`zfight_road_closeup.png`, a camera 2.5 studs above the lane) the asphalt shows **patchy lighter mottling**, consistent with terrain concrete z-fighting through.
  - A still can't prove flicker; check it in motion.
- **Suggested fix:** apply ENGINE_LIFT in the corridor branch (`Terrain.luau` ~L398–411, `- Terrain.ROAD_SINK`), so the corridor lands at ~11.1.

## Step 3: re-shoots at noon, scored against GTA V
| Shot | v33 | **v34** | Notes |
|---|---|---|---|
| `t02_downtown_street` (-330, 15, -222) | 2 | **4** | Real asphalt, lane dashes, a grass median, kerb and paved sidewalk; reads as a city avenue. Still lollipop trees, no traffic or people. A faint light smear on the asphalt in the foreground (possibly the z-fight). |
| `t03_downtown_intersection` (-215, 15.6, -205) | 2 | **5** | Zebra crosswalks, tiled sidewalk, grass medians, lane lines and working signals. The best ground-level shot so far. Empty. |
| `t11_police_station` (-620, 15.6, 350) | 3 | **3** | Road and sidewalk now visible, but the building is still a blank grey slab with a small sign. That's the building template, not terrain. |
| `t05_beach` (-5000, 8.7, -200) | 4 | **4** | Uncovered a **weathered wooden boardwalk** (was under sand). The brown terrain step / wall between the boardwalk and the sea is still there. |
| `t16_driving` (Crown Blvd, Kronberg K8) | 3 | **5** | Driving on asphalt through a crosswalk past signals reads like a city street. Still no traffic. The HOT DROP panel covers the middle of the screen. |
| `n04_freeway` (-470, 43, 1420, lock 22.5) | 2 | **2** | Unchanged: pitch black. The lamps are dots that don't light the deck; the sky is black. Lighting isn't touched by this fix. |

## Errors
- **Server:** 0 errors, 0 non-asset warnings; `booted with 29 systems`.
- **Client:** one `[MinimapController] slow GPS route: 5.1 ms`.
- No "being generated" lines were checked separately this run (asset warnings omitted).

## Files
- Shots: `t02`, `t03`, `t05`, `t11`, `t16`, `n04`, `zfight_road_closeup`.
- `console.txt`.
