# Job 0008: Minimap, GPS and VFX playtest (Play mode)

**Goal:** a real-engine check of the new client systems on `main`: the GTA-style radar with GPS and the full-screen map (`MinimapController` and `MapScreenController`), and the VFX library (smoke, skid marks, nitro flames, backfire, sparks, cash bursts).

The world is still v1. Judge only these systems.

## Steps

1. Run `git pull --ff-only origin main`. Confirm Rojo is connected and synced, and write the commit hash in the report.
2. Start a **Play** test (solo). Wait 45 s.
3. Run `get_console_output` and save it as `console_start.txt`. Flag every error or warning that mentions Minimap, MapScreen, VFX, Effects, WheelAnimator or VehicleClient.
4. Take a shot **`radar_onfoot`** of the player view with the radar visible.
5. Get in a car:
   - walk to the nearest parked car in `Workspace.Vehicles` (attribute `Kind` = `Parked`);
   - hold E for 4 s to hotwire it.

   Then:
   1. Drive with W for 3 s, then take **`radar_driving`**. The radar should zoom out with speed, and a GPS route to your garage should be drawn.
   2. Hold W+A+Space for 2 s to drift, and take **`drift_smoke_skids`** mid-drift. Look for tyre smoke and skid marks.
   3. Hold Shift for nitro and take **`nitro_flames`**. If the camera is in front of the car, use `screen_capture` with a camera behind it to show the exhaust flames.
   4. Drive into a wall at speed, and take **`crash_sparks`** right at the impact.
4. Press **M** to open the full-screen map, and take **`map_full`**.
   1. Click somewhere on a road away from the player to set a waypoint, and take **`map_waypoint`**.
   2. Close the map (M or Esc). Take **`radar_waypoint_route`**: the radar should show the purple waypoint route.
5. Run the admin command `/hc wanted 3` in chat. Wait 5 s, then take **`radar_wanted`**. Police blips and the wanted flash should be visible.
6. Run `get_console_output` again and save it as `console_end.txt`. Stop play.
7. In `report.md`:
   - **Radar:** is it smooth when turning the camera, readable, and correctly placed? Does it overlap any other HUD element?
   - **GPS route:** is it correct?
   - **Full-screen map:** is it usable?
   - **VFX:** does each effect look premium and realistic, or cartoony?
   - **Errors:** list every runtime error.

Never save or publish.
