# Job 0001 report: first look (v1 baseline)

- **Studio version:** 0.744.0.7441077 (macOS)
- **Repo commit:** `e4b63ac` on `main`
- **Place:** Hotwire City, opened from Roblox. `game.PlaceId` = 106226892419530 and `game.GameId` = 10773288390. Studio's title is "illintent1's Place: 10272026_1".
- **Rojo:** 7.6.1. `rojo serve` is on localhost:34872 and the plugin is connected. Before connecting, `ReplicatedStorage` and `ServerScriptService` were empty. After connecting they held `Shared` and `Server`.
- **Play mode:** Play (solo, with a character). I waited about 45 s, then ran the steps.
- **Boot:** `[Server] Hotwire City booted with 24 systems` and `[Client] illintent1 ready with 15 controllers`. The game printed no script errors.

## Steps

1. Checked the place and Rojo; both are noted above.
2. Started Play and waited 45 s.
3. Captured the console. `get_console_output` truncates its result at the MCP length limit, so `console.txt` holds the matching lines copied verbatim from the Studio session log, which covers both captures.
4. Took the shots in this order:
   - `overview_high` and `downtown_street`.
   - `overview_low_sw` timed out on its first try, then worked on the retry.
   - `spawn_player_view`. The first try reused the previous override: after a `screen_capture` with a camera override, the client camera stayed at `Scriptable` at the override position. I set `CameraType` back to `Custom`, with the subject set to the Humanoid, and took the shot again. The final shot is the player's own third-person view.
5. Took the `garage` and `dealership` shots.
   - The player's plot is `Workspace.Plots.Plot1` (`OwnerUserId` = 11686693147). Its bounds centre is (-713.5, 18, -240) and its size is 111×36×98.
   - `Workspace.Dealership` is a Folder, not a Model. Its parts' centre is (79.8, 17.9, 80) and its size is 103×34×110.
   - Both buildings are about 100 studs across, so a camera 40 studs from the centre would sit inside them. I put each camera **40 studs out from the face nearest the street and 20 up**:
     - `garage`: (-618, 38, -240) looking at (-713.5, 18, -240).
     - `dealership`: (80, 38, 175) looking at (80, 18, 80).
6. Drove a parked car.
   - The nearest parked car was `Workspace.Vehicles.rustbucket`, 11.5 studs from spawn. There are 26 cars with `Kind = Parked`.
   - I walked to it with `character_navigation`, then held E for 4 s. `Humanoid.SeatPart` became `rustbucket.DriverSeat`, so **the hotwire worked**.
   - I held W for 4 s and took `driving` with W still held. The speedometer read 45 MPH.
7. Captured the console again; it is in `console.txt`.
8. Stopped play. I did not save or publish the place.

## Visual impression

- **Good:** At street level the city reads well. The downtown has the pink/blue neon look and palm trees, and the "HOTWIRE MOTORS" billboard and dealership canopy look polished. The HUD is clean and readable: cash pill, tutorial card, left menu column, and speedometer with the radio widget. The tutorial flows correctly from "Steal a car" to "Drive it home". The glowing target car and its beacon are easy to spot.
- **Day/night:** The cycle is fast. `downtown_street` is in full daylight, but about 1 min later every other shot is at night (`ClockTime` ≈ 19.9). So the shots are not lit the same way.
- **Broken or bad: `overview_high` shows no map at all.** From (0, 900, 900) the frame is a brown-orange haze, with only the HUD visible. Fog or Atmosphere hides the whole city from that height and distance. Any marketing or overview camera will hit this.
- **Bad:** At night, `overview_low_sw` looks flat and dark purple. Roads and blocks blend together, the far half of the map is empty dark ground, and the buildings look sparse and small for the area.
- **Bad:** The `garage` building is a plain white box with neon trim and a dark empty interior. It reads as a placeholder next to the dealership.
- **Bad:** The parked `rustbucket` model has rough, low-poly shading. Seen from behind while driving it looks muddy, and the character's hair clips through its roof in `spawn_player_view`.
- **UI clutter:** The tutorial card and the "HOT DROP" banner sit in the middle of the screen in every shot and cover a lot of the scene.
- **Asset loading:** About 170 "Asset content representation is being generated" warnings for 3D assets. These are mostly retries; the meshes did load. There are also 21 "Asset type does not match requested type" warnings (old `91xxxxxxxx` ids and others), a 404 on `Workspace.NPCs.Shopkeeper.Hat1.Handle.TextureId` (rbxassetid://81504106), and repeated "Wrap-deformer fetching meshes resulted in error" warnings, probably from NPC layered clothing.
- **DataStore:** In Studio, the DataStore returned 404 for `global/__studio_probe` and for `p_11686693147`. This is expected for a first-time player.
