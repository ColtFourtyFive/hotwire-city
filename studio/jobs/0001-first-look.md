# Job 0001: first look at the real game (v1 baseline)

Goal: get the first real-engine evidence of how v1 looks and runs. It is the baseline for the v2 rebuild.

1. Check that Rojo is connected and that the place is Hotwire City, opened from Roblox. Write both in the report.
2. Start a **Play** test (solo, with a character) using `start_stop_play`. Wait **45 seconds** so the server can build the map and load the 3D asset library.
3. Run `get_console_output` and save it to `console.txt`.
4. Take these shots with `screen_capture`, using its camera position and look-at options. Coordinates are in studs; the map is centred on (0, 0, 0) and the ring road sits at ±800.

   | Name | Camera position | Look at |
   |---|---|---|
   | `overview_high` | (0, 900, 900) | (0, 0, 0) |
   | `overview_low_sw` | (-700, 180, -700) | (0, 20, 0) |
   | `downtown_street` | (60, 12, 160) | (60, 40, 0) |
   | `spawn_player_view` | no camera override: the player's own view | — |

5. Find the player's garage (the model in `Workspace.Plots` whose `OwnerUserId` attribute equals the player's UserId) and the dealership (`Workspace.Dealership`) with `search_game_tree` or `inspect_instance`. Take a shot of each from about 40 studs away and 20 up, looking at its centre: `garage`, `dealership`.
6. Walk to the nearest parked car using `character_navigation`. Parked cars are models in `Workspace.Vehicles` whose `Kind` attribute is `Parked`. Hold **E** for 4 seconds with `user_keyboard_input` to hotwire it. Then hold **W** for 4 seconds and take the shot `driving`.
7. Run `get_console_output` again and append it to `console.txt`.
8. Stop play mode.
9. In `report.md`, give your honest visual impression in 5–10 lines: what looks good, what looks bad, and anything that is broken, missing or invisible.
