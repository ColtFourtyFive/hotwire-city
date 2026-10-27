# Job 0009: The v2 look on the real place (version 29), first "after" shots

Team Create is now **off**, and the lead uploaded `main` as Saved **version 29**. It contains:
- 22 PBR MaterialVariants that override Asphalt, Pavement, Concrete, Brick, Plaster and others;
- the HDRI day Sky;
- LightingService v2.

Rojo live-sync could not deliver these, so the place must be reopened. The world is still v1, so judge **only** materials, sky, atmosphere and lighting.

## Steps

1. Close the current place without saving. Run **File → Open from Roblox → Hotwire City**, and confirm it loads version 29 or later. Reconnect Rojo to `rojo serve`; `git pull` first.
2. Inspect, read-only, with `inspect_instance` and `execute_luau` (Edit), and write the results in the report:
   - `MaterialService`: number of children (expect 22) and `MaterialService.AsphaltName` (expect `HC_Asphalt` or similar).
   - `Lighting`: `LightingStyle` (expect Realistic) and `PrioritizeLightingQuality`. A lead probe on a headless server read **Soft**; we need the value a real Studio session sees.
   - `Lighting` children: expect exactly one each of Sky, Atmosphere, Bloom, ColorCorrection and SunRays.
3. Start a **Play** test (solo) and wait 45 s.
4. Run each lock below with `execute_luau` on the **Server** datamodel. For each one, wait 5 s, then capture `downtown_street`, `spawn_player_view` and `overview_low_sw` with the same camera positions as job 0001:

   | Lock | Code | Shot prefix |
   |---|---|---|
   | Midday | `workspace:SetAttribute("TimeOfDayLock", 13)` | `noon_` |
   | Golden hour | `workspace:SetAttribute("TimeOfDayLock", 17.6)` | `golden_` |
   | Night | `workspace:SetAttribute("TimeOfDayLock", 22.5)` | `night_` |

   If the attribute name differs, read `src/server/Systems/LightingService.luau` for the real override name.
5. Take two close-ups at noon:
   - `noon_asphalt_close`: the road surface from 6 studs away. Does the PBR asphalt show?
   - `noon_brick_close`: a brick wall from 10 studs away.
6. Run `get_console_output` and save it as `console.txt`. Stop play.
7. In `report.md`, compare against job 0001 shot by shot. Do materials, sky and lighting read as more realistic or GTA-like? Is anything worse? Are any parts too dark or too saturated, given the v1 colours under the new materials? Is anything broken?

Do not save or publish.
