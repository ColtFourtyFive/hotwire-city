# Job 0008 report: minimap, GPS and VFX playtest (Play mode)

- **Studio:** 0.744.0.7441077, Hotwire City place 106226892419530.
- **Code:** `main` is at **`437cfe7`**.
  - Rojo 7.6.1 is connected and synced. `MinimapController` and `MapScreenController` are present under `StarterPlayerScripts.Client.Controllers`.
  - The client logged `ready with 18 controllers` and the server `booted with 24 systems`.
- **Run:** solo Play, 45 s wait. Play was stopped at the end. The place was not saved or published.
- **Errors (`console_start.txt` and `console_end.txt`):**
  - **No script errors or warnings from Minimap, MapScreen, VFX, Effects, WheelAnimator or VehicleClient.**
  - The only server warning and error came from my own test commands; see Notes.

## Shots

| Shot | What it shows |
|---|---|
| `radar_onfoot` | Round radar bottom-left, with N marker, `M` hint, district label "PALM SUBURBS", distance pill (117m), and a cyan GPS line out of the garage. |
| `radar_driving` | At 45 mph the radar **zooms out** (city blocks visible), and a **green GPS route** runs to the garage icon (57m). |
| `drift_smoke_skids` | Mid-drift at 39 mph, the "DRIFT! 0.4s +NITRO" banner. Tyre smoke is **faint/barely visible** from the chase camera, and **no skid marks are visible** in the shot. |
| `drift_attempt1_crash` | My first drift attempt ended in a crash into a parked AI cab. The camera **clips into the cab and the neighbouring car body**; see VFX/camera notes. |
| `nitro_flames` | Nitro active ("NITRO!", 35 mph): bright white-blue exhaust glow at bottom-centre, cyan light on the road, and the car body tinted lime by the nitro light. The chase camera faced the car's front, so the flame is mostly hidden. |
| `nitro_flames_rear_missed` | A camera-override attempt from behind. **Missed:** the car had stopped by the time the capture fired; see Notes. |
| `crash_sparks` | Taken just **after** a wall impact: 0 mph, health bar knocked down, **no sparks in frame**; capture latency, see Notes. |
| `map_full` | Full-screen map: "HOTWIRE CITY" title, help line, full legend (15 entries), district labels, zoom +/−, recenter, close, and a "DROP OFF · 222m" chip with the green route to the garage. |
| `map_waypoint` | Clicking a road set a waypoint: purple pin, purple route along the streets, "WAYPOINT · 467m" chip and a "CLEAR WAYPOINT" button. |
| `radar_waypoint_route` | After closing the map, the radar shows the **purple waypoint route** and pin, plus a "467m" pill with the waypoint icon. |
| `radar_wanted_attempt1_busted` | `/hc wanted 3`, then a 5 s wait. I was **BUSTED** within that time because the car was stuck, so I was moved to Police HQ and lost $640. |
| `radar_wanted` | `/hc wanted 3` again, then a 2 s wait: a **pulsing red rim around the radar**, a red search circle, 3 of 5 stars in the top bar, and a "Wanted level set to 3" toast. **No police blips yet**, since no unit had spawned within 2 s. |
| `offscreen_markers_overlap` | Extra evidence: screen-edge markers for home and hot drop sitting on top of the menu buttons. |

## Assessment

### Radar
- **Good:**
  - It is readable and clean, in the GTA style.
  - The heading arrow and the rotating N marker work.
  - It zooms out with speed.
  - District names update (Palm Suburbs, Midtown, Police HQ).
- **Smoothness:** it is driven by RenderStepped. With Studio unfocused, RenderStepped ran at 15 Hz in Play, so I couldn't judge smoothness at 60 fps from stills. I saw no visible stepping in the shots.
- **Placement:** bottom-left, clear of the speedometer and radio. However:
  - The **left menu column (STORE/INDEX/JOBS/REBIRTH/GEAR/DAILY/GIFTS)** sits right above it. When driving, **off-screen waypoint arrows land on top of those buttons**: in `offscreen_markers_overlap` the home marker covers DAILY/GEAR and the hot-drop marker covers SETTINGS. In `radar_waypoint_route` the waypoint marker sits half under the tutorial card.
  - The off-screen markers need a safe zone that excludes HUD panels.
- **Distances disagree:**
  - The radar pill shows **route distance**, while the screen-edge markers show what looks like **straight-line distance**. Examples: 176m vs 121m, 265m vs 197m, 407m vs 287m.
  - This is defensible, but confusing next to each other. Either label one of them, or use the same metric.

### GPS route
- **Correct.** The green garage route and the purple waypoint route both follow the road grid, take sensible turns, and redraw after the waypoint is set.
- The radar and the full map agree.
- The waypoint replaces the drop-off route while it is set, which is expected.

### Full-screen map
- **Very usable and polished:** a clear legend, district labels, icons for every POI type, zoom, recenter and clear-waypoint controls, and a help line.
- Clicking snapped the waypoint to the nearest road.
- **Note:** the MCP mouse click landed about one block south of my target. That matches the 58 px top-bar inset, so it is a test-harness coordinate offset, not a game bug.
- `M` toggles the map closed, and the controls respond.

### VFX
- **Nitro:**
  - The bright exhaust glow, cyan ground light and car tint read as energetic.
  - From the chase camera (in front in this case) the flame itself is mostly hidden behind the car.
  - Lime-tinting the whole body looks a little arcade rather than realistic.
- **Drift:**
  - The drift is detected, and the banner and nitro charge work.
  - Tyre smoke is very subtle from the default camera, and I saw no skid marks.
  - That may be because each capture takes 10–15 s of game time, so the shot lands after the drift. It could also mean the effects are too faint.
  - **Recommend:** check skid marks with a dedicated stationary test (handbrake donut, then capture).
- **Crash sparks:** not captured, for the same latency reason. The emitters exist and are wired: the client has `VFX_Sparks`, `VFX_ImpactStar`, `VFX_Flash`, `VFX_Shockwave`, `VFX_Backfire`, `VFX_NitroFlame`/`NitroCore`/`NitroJet`, `VFX_TireSmoke` and `VFX_Dust`.
- **Camera clipping:** in a crash the chase camera clips into car bodies (`drift_attempt1_crash`). Consider camera occlusion/pop-in against vehicles.
- **Cash burst:** not exercised; no step triggered it.

### Runtime errors
- **None from game scripts.**
- **Log noise to fix (harmless):**
  - `SoundController.start()` passes sound ID **strings** to `ContentProvider:PreloadAsync`, which treats them as images. Result: `Asset (Image) "rbxasset://sounds/impact_water.mp3" load failed: Invalid image or texture` (same for `impact_explosion_03.mp3`). **Fix:** preload `Sound` instances, or filter to image IDs.
  - The same pattern appears for `rbxasset://fonts/families/Montserrat.json` and `Inconsolata.json`, probably from the loading-screen preload list.
- **An old error still present:** `Workspace.NPCs.Shopkeeper.Hat1.Handle.TextureId` (rbxassetid://81504106) returns 404. This was also seen in job 0001.

## Notes (test-method caveats)

- **Capture latency:**
  - Each `screen_capture` took about 10–15 s of game time (the event timer moved 1:17 → 1:02 between two shots).
  - So short effects (drift smoke, sparks, nitro from a rear override) are hard to catch. The car usually crashed in the gap.
  - Several attempts are kept as `*_missed` and `*_attempt1_*`.
- **Driving:**
  - The v1 streets are dense, and the AI cabs park in lanes. I crashed several times; one crash was into an AI `yellow_cab`.
  - I tried to reposition the car through the client; the server watchdog correctly **rewound** it (`[VehicleService] watchdog teleport ... -> rewind`).
  - The `AssistantCommand:4: attempt to index nil with 'model'` error is from my own test command (`require` of VehicleService from the plugin context returns a separate instance with no car state). It is not a game error.
  - **Several Workspace models share the name `yellow_cab`.** Name lookups pick an arbitrary one, so tools should look cars up by `OwnerUserId` or seat occupant.
- **Nitro:** the tank (2.5 s) only refills while not boosting, at 0.12 per second (~8 s). I had held Shift by accident for one cycle.
