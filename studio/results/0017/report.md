# Job 0017 report: C4b polish re-check

## Setup
- **Code:** `main` @ **`68532b3`** (same checkout as job 0016).
- **Place:** opened from Roblox at **v35+** (the same open session as job 0016; Look schedule and AppearanceService confirmed in Edit there).
- **Rojo:** not connected. Never saved or published.
- **Map:** still v1 (wave A not merged). World looks are not scored here.
- One Play session for the whole job; Play stopped at the end. `_G` helpers removed, `TimeOfDayLock` cleared.

## Bugs 1–5

| Bug | Result | Shots |
|---|---|---|
| 1 Phone apps | **PASS.** Contacts, Jobs, Daily, Gifts and Codes all open. No `attempt to call a Instance value`. | `d1_contacts`, `d1_jobs`, `d1_daily`, `d1_gifts`, `d1_codes` |
| 2 Shard | **PASS, day and night.** Semi-transparent black band 1081×135 px at y 212 in a 1081-wide client (≈19.5 % height, centred ≈48.8 %). WASTED: lowercase red "wasted", subtitle "Taken to Seaview General". BUSTED: lowercase blue "busted", "Bail -$N" with the money in red. The world goes grey behind it. At night the band edges are visible and the world is dark grey, not black. | `g1_wasted`, `g1_wasted_night`, `g2_wasted_after`, `g3_busted`, `g3_busted_night`, `g4_busted_after` |
| 3 Gun shop | **PASS.** One click = one $400 purchase. `P` closes the shop; the pause menu opens and cash is unchanged. Chat: see the nits below (unverified). | `f1_gun_shop`, `f2_gun_shop_click`, `f3_shop_under_pause` |
| 4 UI focus | **PASS.** A click that misses the phone, the photo viewfinder, the pause menu or a shop list fired nothing and didn't aim. | `d2_phone_click_world`, `d3_photo_click_world`, `e1_pause_click`, `e2_list_click` |
| 5 Bail | **PASS.** One arrest = one `[Bust]` line = one bail of 10 % of cash. Before the first bust there were 0 `[Bust]` lines. The cash drop matches the bail every time, and the toast matches ("Released from Police HQ. Bail -$15,378"). | `console_bust.txt` |

`[Bust]` lines (server console):
```
[Bust] id=1 user=11686693147 reason=police stars=2 peak=2 cash=153789->138411 bail=15378 mult=1 car=- sinceLast=-
[Bust] id=2 user=11686693147 reason=police stars=2 peak=2 cash=138411->124570 bail=13841 mult=1 car=- sinceLast=35.1
[Bust] id=3 user=11686693147 reason=police stars=2 peak=2 cash=124570->112113 bail=12457 mult=1 car=- sinceLast=39.0
[Bust] id=4 user=11686693147 reason=police stars=2 peak=2 cash=112113->100902 bail=11211 mult=1 car=Hot_Hatch sinceLast=42.7
```
- Busts 1–3: `/hc rookie off`, then `/hc wanted 2`, standing still.
  - The officer walked up and arrested me within about 11–13 s each time, before I pressed `H`.
  - Surrender with `H` was **not exercised**. My `H` key call failed on a tool-schema error, and the officer arrested me anyway.
- Bust 4 (G23, the job 0006 scenario): `spawn hot_hatch`, `wanted 2`, drive 5 s, brake.
  - The arrest happened while I was still in the car (`car=Hot_Hatch`), before my exit.
  - There was exactly one line and one charge.

## Prompts
- **Keyboard: no grey Roblox prompt bubble anywhere.** Prompts render as top-left GTA help text with the orange hold rule.
  - Car: `c1_prompt_car`, then `c2_prompt_hold`.
  - Garage: `c4_prompt_garage`.
- Hold-to-hotwire, drive, garage (sell/store) and the shop prompt all worked from the keyboard.
- `c3_prompt_gone_still_seated`: the prompt cleared on entering the car.
- **Regression: `F` does not exit the car.**
  - In `VehicleClient.exit()`, `humanoid.Jump = true` is reset to false in the same frame (HC_Exit is bound at priority 3050).
  - I had to exit with `hum.Sit = false` in tests.
  - This also showed up in job 0016.
- `c1_prompt_car_walked_wrong_way`: my first capture, taken after I walked the wrong way. It's kept for the record; `c1_prompt_car` is the real one.
- **No `[PromptStyle]` lines** in either console.

## Touch and streamer mode
- **Touch (step 10): BLOCKED.** The Studio MCP can't emulate a touch device, so I couldn't test either the engine bubbles or the GTA touch buttons.
- **Streamer mode (10b): FAIL.** With the HUD off, **no prompt bubble showed** (`c7_prompt_streamer`), and `PromptShown` never fired. `E` still hotwired the car.

## Night shard (G)
- `g1_wasted_night` and `g3_busted_night` both **meet the pass line**.
  - Band edges are clearly visible.
  - The text is readable.
  - The world behind is dark grey, with the police sign glow still visible.
  - Taken with `TimeOfDayLock` 0, clock ≈ 0.

## Nits
- **Help text:** shown, then gone in the later capture (`b1_help_shown`, `b2_help_faded`). I didn't time the fade to the second.
  - The copy renders a raw `&amp;`: "Upgrades &amp; Tools" and "Lock &amp; Load". Either RichText is off on that label or the text is double-escaped.
  - `/hc tutorial` replays the hints only after a rejoin.
- **Event rows: PASS on position and copy.**
  - Quiet sentence-case rows directly above the radar: "Hot drop lands in · 170 m · Legendary Midnight…", "Rush hour", "Double cash". No emoji, no "CLAIM IT!", and the distance comes first (`h1_event_rows`).
  - Nothing sits over the crosshair (`h2_crosshair_clear`, Kessler P9 hip-fire dot at centre).
  - No feed line contained "!" or an emoji.
- **Event notes:**
  - For a moment, `HC_HUD` had visible Body labels reading `doubleCash started via EventService.startDoubleCash` and `hotDrop started via EventService.forceHotDrop`. These were gone 2 s later and never appeared in a shot. They may be admin-only debug toasts, but they look like dev text that could reach players.
  - **Sound:** not verifiable. I can't hear Studio audio. The only playing sounds were the engine loops and the city ambience, and both of their ids (`80317022777602`, `9112758500`) are among the 64 `ContentId … Asset type does not match requested type` failures in the client log.
- **Vehicle name: PASS on timing.**
  - "Hot Hatch" in script appears bottom-right 0.06 s after spawn-in (`i1_vehicle_name`), and has faded (TextTransparency 1) 5 s later (`i2_vehicle_name_gone`).
  - No brand line was visible to its left, and there was no district line to compare against on this map.
- **Gun store name:** "Lock & Load" in the menu header (`f1_gun_shop`). The help text shows it as "Lock &amp; Load" (see above).
- **Player-facing copy:** "Spawned hot_hatch - drive it home to keep it." exposes the internal car id. It comes from the admin `spawn` command, so it's probably admin-only.

## CoreGui and Esc
- **A1 (`a1_first_frame`):**
  - No Roblox player list.
  - No chat window visible.
  - No name over my own head.
  - The garage car has a world billboard (name, rarity pill, $/s income).
- **A2 (`a2_esc_bridge`): PASS.** Esc → Roblox menu → Esc opened our pause menu on MAP.
- **A2b (`a2b_esc_out_of_pause`): PASS.** Leaving our pause menu via Esc didn't reopen it.
- **A3 (`a3_esc_hint`):** the Esc hint was **not visible** when I captured it.
- **Chat:** after I closed the gear-shop list, the chat Frame stayed invisible. Unverified whether it should come back.

## Leaderboards (J)
- **Boards present:** `SpawnPlaza.LeaderboardEarned` ("RICH LIST") and `LeaderboardSteals` ("MOST WANTED"). `j1_leaderboard` shows RICH LIST.
- **Board face PASS:** matte black, thin orange rule, condensed title, ranks 01–10, no emoji.
- **FAIL on "no neon frame":** a separate Neon part sits behind each board and makes a bright yellow / pink glowing frame.
  - `LeaderboardEarnedGlow` (25.4×16.4×0.5, colour 255,205,50) and `LeaderboardStealsGlow` (colour 255,52,140).
  - These are probably v1 map parts, so possibly wave A's to remove.

## Errors and warnings (Setup step 5 list)
- None mention PromptStyle, CoreGuiSetup, UIFocus, HelpText, Shard, PhoneController, GunShopUI, NotificationController, EventsClient, DeathScreenController, WantedService or LeaderboardService.
- No `[Shard] keystone band art` warning.
- **Other warnings:**
  - `[MinimapController] slow GPS route` 15× on the client (5.6–54.5 ms).
  - `[ShopService] no part tagged GunStoreCounter; placing fallback FREEDOM ARMS counters (MapLayout)`.
  - `[AssetLibrary] Props/flower_bed unavailable; using procedural fallback`.
  - `[VehicleService] ejecting unauthorized occupant illintent1 from car 43 (Loot)`.
  - 64 `ContentId … Asset type does not match requested type`.
  - 2× `rbxassetid://4542793421 … User is not authorized`.
  - 1× `88812082275800 … HTTP 502`.
- Full lists are in `console_end.txt`.

## GTA V verdict
**The HUD and its menus now mostly read as GTA V:** the shard, the help text, the event rows, the vehicle name and the boards' faces. What still reads as a kids' game:
- the neon-ringed garage interior and its posters (`a1_first_frame`);
- the car billboards with a rarity pill and $/s income (`a1_first_frame`);
- the giant cartoon money-bag props in Spawn Plaza (`h1_event_rows`);
- the neon glow frames behind the leaderboards (`j1_leaderboard`);
- blocky v1 NPCs, e.g. the officer in `g3_busted` (characters package);
- the Roblox avatar thumbnail in the pause profile (`e1_pause_click`).

DONE
