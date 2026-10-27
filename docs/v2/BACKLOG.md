# v2 backlog: verified issues waiting for an owner

Each item says where it came from. Fix them after the Wave B merge, because Wave B owns most of these files.

| # | Source | Issue | Fix direction | Owner after merge |
|---|---|---|---|---|
| 1 | job 0008 | The off-screen waypoint markers overlap the left menu buttons and the tutorial card | Mostly fixed by UI v2, which deletes the left column and the cards. Re-check the edge-marker safe areas against the v2 HUD layout | UI |
| 2 | job 0008 | The radar distance pill shows route distance while the edge markers show straight-line distance, so the numbers disagree | Use route distance everywhere a waypoint has a route; mark straight-line distance with "~" | UI / Minimap |
| 3 | job 0008 | Drift smoke is faint, and no skid marks were visible | Raise the drift smoke preset's opacity and rate. Debug the skid Trail: attachment placement, width, transparency, Enabled toggling while sliding. Verify in a stationary drift test | VFX / Vehicles v2 |
| 4 | job 0008 | The chase camera clips into car bodies on crashes | Add occlusion handling to the camera: pull in or fade when the camera is inside the car's bounding box | Vehicles v2 / camera |
| 5 | job 0008 | `SoundController` calls `ContentProvider:PreloadAsync` with id strings, logging "Invalid image" noise; the font JSON files do the same | Preload `Sound` and `Font` instances, not strings | Audio |
| 6 | job 0008 | Several Workspace models share the name `yellow_cab` | Give vehicle models unique names (append VehicleId) so debugging and selection are unambiguous | Vehicles v2 |
| 7 | job 0001 | `NPCOutfits` uses hair 62234425, whose texture 404s | Replace it with a realistic hair (see `gta_assets`) | Life / NPCs |
| 8 | job 0001 | v1 `Config/Assets.Images` are Decal ids ("Asset type does not match" warnings) | Replace them in v2 with Image uploads | Look / UI |
| 9 | roblox_tech | `LightingService` writes the deprecated `Lighting.Technology` | Fixed by Wave A2 (look) | Look |
| 10 | roblox_tech | v1 NPCService uses the deprecated `CreateHumanoidModelFromDescription` | Use the `…Async` version | Life / NPCs |
| 11 | job 0010 (partial) | The street-dressing pass needs the scout picks. Vegetation: broadleaf trees 98950444096614 and 128707014921507, Ponderosa pine 130515502281374, desert pack 16420171681, California fan palm 130498222865089, hedge 131155630187030 (scaled down), grass 3123069623. Signs: MUTCD stop sign 9777090830, speed limit sign 388944325. **Avoid** these backdoor re-uploads: 139707403949260, 84675437585887. There are no US one-way or street-name signs on the store, so build them in-house (Blender, plus CityArt text). | Run a dressing pass after A1 merges, adding categories 5–14 from 0010 when they arrive | World / dressing |
| 12 | job 0010 (partial 2) | More dressing picks: freeway cantilever exit sign 125125263118068; truss gantry 9335428697 (replace its joke sign decal); PBR fence pack 100583941159955 (includes an LA privacy fence); jersey barrier 82454061017921; USPS-style mailbox 109766012790297 (swap the logo); wooden utility poles 15591157798; cast-iron bench 120611959432681; bollard pack 115942669533764; payphone 4900193185 (swap the Bell decal); gas pump 8368863281 (retexture away from ESSO). **Gaps** for sourcing round 2 or Blender: planters, US parking meter, city litter bin, utility cabinet, ice machine, ATM. **Avoid** the L4D ice machine (a Valve rip). Some store descriptions falsely say 'No scripts', so always strip scripts. | Dressing pass after A1 merges | World / dressing |
