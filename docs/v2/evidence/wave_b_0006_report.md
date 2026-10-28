# Job 0006 report: Wave B playtest (GTA HUD + combat)

## Setup
- **Code:** `main` is at **`6015e40`**.
- **Place version:** per the lead's instruction, the place was opened with **File → Open from Roblox at version 32+**, which already contains Wave B. **Rojo was NOT connected**; `rojo serve` is stopped. I confirmed the content in Edit: WeaponService, DamageService, PoliceCombatService, HUDController, WeaponWheel, GunShopUI, DeathScreenController and MaterialOverrides are present. `LightingStyle` is Realistic, with one each of Sky, Atmosphere, Bloom, ColorCorrection and SunRays, and 22 MaterialVariants. **Lighting looks correct**; nothing broken.
- **Play:** solo, one session only. Not saved or published, and no moderation UI appeared.
- **Boot lines** (`console_start.txt`): both are present.
  - `[Server] Hotwire City booted with 28 systems`
  - `[Client] illintent1 ready with 27 controllers`
- **Input:** keys were sent with MCP `user_keyboard_input`.
  - Mouse clicks on UI were made by **instance path**. Pixel coordinates don't work because screenshots are scaled ≈1.56× against the game viewport; see Phone.
  - Admin commands were sent through `Remotes.AdminCommand:FireServer`.

## ❌ Bugs found (most important first)
1. **Phone apps can't open, on every app that uses `phone:page()`.**
   - Clicking JOBS logs `Players.illintent1.PlayerScripts.Client.Controllers.PhoneController:591: attempt to call a Instance value` (stack: `function openApp`, called from line 894).
   - Clicking CODES logs the same error at **:673**.
   - **Root cause in the code:** `src/client/UI/Phone.luau:310` sets `self.page = page`, a ScrollingFrame. That **shadows the method `function Phone:page(title, build)`** at line 463, so every `phone:page("…", …)` in PhoneController calls an Instance.
   - Affected apps: Contacts, Jobs, Daily, Gifts, Codes. Settings, Map, Prestige and Camera route elsewhere and should work.
   - **Fix:** rename the field, e.g. `self.pageFrame`, and update its users: `:456` `self.page.Visible`, `:468`, `:473`, `:475`, `:476`.
2. **WASTED and BUSTED have no black band.** Both show only a large lowercase title (red "wasted", blue "busted") over a desaturated, vignetted picture. The spec's "black band across the middle" isn't visible in either.
   - BUSTED has a subtitle (`Bail  -$3,600`); **WASTED has none.**
3. **The gun-shop rows don't respond to mouse clicks.**
   - The cursor is free (`MouseBehavior=Default`, `MouseIconEnabled=true`).
   - A left click on `HC_GunShop.Menu.Rows.Row8` (Med Kit, a TextButton) didn't change the selection or buy anything (`gun_shop_click_noop.png`).
   - The **keyboard works**: arrows move, and Enter bought the Med Kit (−$400, "You carry 1"; `gun_shop_buy.png`).
   - The same click method worked on the pause-menu tabs, so this looks specific to the shop.
4. **A possible double bail charge.**
   - Cash went **$64,886 → $57,686 (−$7,200)** across step 10 (car) and step 11 (bust), but the BUSTED screen showed `Bail -$3,600`.
   - After I left the car, wanted had already gone from 2 to 0 with officers nearby, so I was probably arrested once off-camera before my deliberate surrender.
   - No server log line records busts or bail, so I can't confirm. **Suggest logging busts and bail.**

## HUD at rest (`hud_rest_desktop`, `radar_expanded`)
- **Layout:**
  - Square radar bottom-left with **one** set of three thin bars under it: green health, blue armour, yellow ability.
  - **No second set of bars** anywhere ✅.
  - Cash `$21,486` top-right in white with a black outline; no stars at 0.
  - Help text top-left on a dark panel; objective line ("Steal a car.") bottom-centre; a small phone and notification badge right of the radar.
- **Help text didn't fade:** "Walk up to the car and hold E to hotwire it." stayed for the whole session, in every shot. It's a tutorial hint, but the job expected it to fade after ~10 s.
- **`Z`:** the radar doubles in size, with the bars still under it ✅.
- **Reads as GTA V?** Mostly yes: a clean thin font, square radar, white cash and minimal chrome. Event banners (HOT DROP, RUSH HOUR, CASH RAIN) are big orange and yellow pills mid-screen that cover the crosshair area at times (`phone_gun_drawn`, `gun_shop`). Those, and the v1 world, are what still read as "kids' game".

## Weapons and combat
- **Weapon wheel** (`weapon_wheel`): an 8-slot GTA-style wheel with a background blur. Pistols, SMGs, Rifles, Shotguns, Melee, Tools, Items and Special, with weapon silhouettes and ammo per slot (e.g. `12 / 24`) and "UNARMED" in the centre. **Very good.**
- **Shoulder aim** (`aim_shoulder`): the camera moves tight over the right shoulder, with a small dot crosshair. Ammo `12  24` shows top-right under the cash ✅.
- **Cash delta vs ammo** (`cash_delta_with_ammo`):
  - The green `+$1,000` appears between the cash and the ammo line, slightly overlapping the "GLOBAL – updates" leaderboard text behind it, but **not** the ammo ✅.
  - A grey feed line `+$1K cash -> $72.4K` also appears above the radar.
- **Shooting at police** (`shoot_cop`, `police_fire`):
  - With the Comrade carbine: an expanding 4-tick crosshair, muzzle smoke, tracer streaks, and ammo dropping 30 → 24 ✅.
  - **No hit marker was seen.** The shoulder camera reset the aim I had set by script, so my burst missed. Every officer was still at 100/100 HP. This is a test-method limit, not a game bug.
  - **The police shot back** (muzzle glow, `police_fire`).
  - Wanted escalated **3 → 5 stars** after I shot at the officers, GTA-style.
  - **No red damage arcs were visible.** God mode was on, so the HP and armour bars stayed full; with god mode on, the arcs may not fire at all.
  - No rubber-banding was seen.
- **Ammo HUD after the arrest:** while I was being arrested, the HUD read `30  0` while the wheel read `30 / 120`. It was a stale read during the weapon strip, not a reload bug.

## Cursor with a gun drawn
- **Phone (`B`): the cursor is free.** Clicking a tile highlights it, but no app opens (bug 1).
  - The click on the tile does **not** fire the gun (ammo stayed 11).
  - **But a click outside the phone fires the gun while the phone is open.** My first, mis-scaled click landed in the world: it fired a pistol round, earned 1 star, and an officer arrested me. That's the unplanned `busted_unplanned_after.png` and `phone_click_fired_gun.png`.
  - **Suggest:** block firing while the phone is open, as GTA does.
- **Pause menu (`P`): the cursor is free**, and clicking the JOBS tab header switched tabs ✅ (`pause_tab2`). It didn't fire the gun.
  - The menu is excellent GTA V style: tab strip, profile block, legend and detail panel.
  - Nit: the "Scroll to zoom · Drag to move" hint overlaps the map frame bottom-left.
- **Gun shop:** the cursor is free, but row clicks don't work (bug 3). The keyboard works.
  - The FREEDOM ARMS menu looks right (orange header, category list, prices, help footer).
  - The counter is a **fallback**: `[ShopService] no part tagged GunStoreCounter; placing fallback FREEDOM ARMS counters (MapLayout)`. It renders as a large plain black block by the road.

## Driving with stars (`driving_stars`)
- No gun HUD ✅; 2 stars top-right ✅; "Downtown" district label bottom-right in script font.
- **No car name** line was visible.
- The radar wasn't noticeably zoomed out: the car hit the gear-shop counter within the 4 s and had stopped, knocking over an NPC.
- The help text switched to "Follow the yellow route…", with a yellow GPS line ✅.

## WASTED / BUSTED
- **BUSTED** (`busted`): taken ~2 s into the arrest, after holding `H` with an officer 8 studs away.
  - Lowercase heavy blue "busted" and the subtitle `Bail  -$3,600`.
  - A desaturated, dark-vignetted grade, with the player outlined; a "Wanted level cleared." feed line.
  - **No black band** (bug 2).
- **After the release** (`busted_after`): a normal picture, HUD back, no grey or black left over ✅. The "Released from…" feed line had already faded by the capture; it was seen earlier, in `phone_app`: "Released from Police HQ. Bail -$3,600".
- **WASTED** (`wasted`): KILL run on the Server.
  - Lowercase heavy red "wasted", the same grade and vignette, and a "God mode off" feed line.
  - **No band and no subtitle** (bug 2).
- **After the respawn** (`wasted_after`): a normal picture and HUD; nothing stuck ✅.
  - No "Treated at…" line was visible at the capture (about 8 s later); it may have faded.
  - The respawn point was a street with apartments; I couldn't confirm it was the hospital.

## 2 players: **skipped**
The Studio MCP can only start a **solo** Play (`start_stop_play`). It can't start **Test → Clients and Servers** or drive two client windows, so the PvP hits, the BADSHOT check and `/hc audit` weren't run. Incoming Replication Lag was not changed.

## Brick re-check for backlog #17 (`brick_recheck.png`)
- v1 still has **0 parts** using `Enum.Material.Brick`, so I placed a temporary 24×14 Brick wall in front of the player, at noon (`TimeOfDayLock` 13).
- **It now renders the full HC_BrickRed bond**: red bricks, grey mortar and colour variation. **#17 is resolved:** it was the post-moderation asset regeneration.
- The wall and the lock were removed afterwards. `brick_recheck_wrongway.png` is a first capture from the player camera, which faced away from the wall.
- **"Asset content representation is being generated" lines** this session (Server and Client, 22:45:14):
  - `ContentId: rbxassetid://92326460960108 failed due to: Asset content representation is being generated`
  - `ContentId: rbxassetid://77373203636884 failed due to: Asset content representation is being generated`
  - Neither is a brick map id.

## Errors and warnings (Setup step 4 list)
- **PhoneController:**
  - `Players.illintent1.PlayerScripts.Client.Controllers.PhoneController:591: attempt to call a Instance value` (openApp, from line 894)
  - `…PhoneController:673: attempt to call a Instance value` (openApp, from line 894)
- **MinimapController:** `[MinimapController] slow GPS route: 11.1 ms`, `7.8 ms`, `10.6 ms`, `22.3 ms` (warnings).
- **Nothing** from HUDController, MenuController, CombatHUD, CombatClient, WeaponClient, WeaponWheel, ShoulderCamera, ShotFxController, DeathScreenController, GunShopUI, WeaponService, DamageService, PoliceCombatService, Shard or Kit.
- **Other:**
  - `[ShopService] no part tagged GunStoreCounter; placing fallback FREEDOM ARMS counters (MapLayout)`.
  - `[AssetLibrary] Props/flower_bed unavailable; using procedural fallback`.
  - Pre-existing "Asset type does not match" ids, `81504106` not found, and `4542793421` not authorised.
  - **No 403s and no "moderated" lines.**
- **Mine, not the game's:** `Visible is not a valid member of UIGradient …` (AssistantCommand).

## Files
- **Shots:** `hud_rest_desktop`, `radar_expanded` (`radar_expanded_keyfail`: my first key call failed), `weapon_wheel`, `aim_shoulder`, `cash_delta_with_ammo`, `phone_gun_drawn`, `phone_click_fired_gun`, `phone_app`, `pause_menu`, `pause_tab2`, `after_pause_close`, `gun_shop`, `gun_shop_row`, `gun_shop_click_noop`, `gun_shop_buy`, `shoot_cop`, `police_fire`, `busted_unplanned_after`, `driving_stars`, `busted`, `busted_after`, `wasted`, `wasted_after`, `brick_recheck`, `brick_recheck_wrongway`.
- **Console:** `console_start.txt`, `console_end.txt`.
