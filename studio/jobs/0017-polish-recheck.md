# Job 0017: C4b polish re-check (job 0006 bugs 1–5, the nits, and the de-Robloxify fixes)

**Goal:** re-test, in the real engine, every bug and nit job 0006 routed to C4b polish, plus the new GTA-style interaction prompts. This job is about the **UI and the bust path only**.
- The world, characters, cars and police looks belong to other packages: score them in job 0018 and its successors, not here.
- `docs/v2/DEROBLOX_AUDIT.md` lists what C4b fixed and what it routed elsewhere.

**What changed (branch `v2/polish`, merged by the lead):**

| # | Fix | What you should see |
|---|---|---|
| Bug 1 | Phone apps | Contacts, Jobs, Daily, Gifts and Codes open. No `attempt to call a Instance value`. |
| Bug 2 | Shard | WASTED and BUSTED always show the black band across the middle (19.5 % of the screen height, centred at 48.8 %), **also at night**: the world turns grey, not black, behind it. WASTED always has a subtitle. Money is in red. |
| Bug 3 | Gun shop | Rows take a mouse click; one click = one purchase. The chat window steps aside while the shop is open. Opening the pause menu (`P` / `M`) closes the shop, and no click on the pause menu ever buys. |
| Bug 4 | UI focus | With the phone, the phone camera's viewfinder, the pause menu, a shop list or the gun shop open, a click that misses the menu never fires or aims the gun. |
| Bug 5 | Bail | One arrest = one bail charge. Every bust prints one `[Bust] id=… cash=a->b bail=…` line to the **server** console. (Job 0006's -$7,200 was two separate arrests, not a double charge; the line tells arrests apart.) |
| Nit | Help text | Shows for about 8 s, then fades. It comes back only for a new hint. A hint pushed aside by a prompt returns only for the seconds it had left. |
| Nit | Events | Quiet rows at the feed position above the radar: sentence case, no emoji, no "CLAIM IT!". Nothing over the crosshair. The hot drop's distance comes first. Touch: timed events are timer bars top-centre. |
| Nit | Vehicle name | On entering a car, bottom-right, on the top line of the location block: the model large in script, the brand small to its left. It never overlaps the district line. Gone after about 3 s. |
| Nit | Gun store name | The menu header, the prompt and the "step up" error all read "Lock & Load" (the name on the building). |
| De-Robloxify | Prompts | Keyboard and gamepad: no grey Roblox prompt bubbles. Prompts become GTA help text top-left ("**Halden Wren** / Hold [E] to hotwire."), with a thin orange rule that fills while you hold. Touch and streamer mode keep the engine's bubbles (by design, until step 10 passes). |
| De-Robloxify | CoreGui | No player list. No chat bubbles over heads. The chat window sits left-middle. Esc in the first minute: closing the Roblox menu opens our pause MAP, but never when Esc was pressed to leave our pause menu. |
| De-Robloxify | Feed | No "!" and no emoji in feed lines. Server events make the feed blip, not an air horn. |
| De-Robloxify | Leaderboards | Matte black "RICH LIST" / "MOST WANTED" boards: no neon, no emoji, no bubble font. |

**Reference mockups** (same layout numbers as the game):
- `docs/v2/early/ui/shard_wasted_*.png` and `shard_busted_*.png`;
- `docs/v2/early/ui/event_feed_*.png`;
- `docs/v2/early/ui/prompt_help_*.png`.

## Setup

1. Run `git pull --ff-only origin main` and write the commit hash in the report.
2. Close the current place without saving. Open **File → Open from Roblox → Hotwire City**, at the version the lead names when it announces this job.
   - **Confirm the content in Edit:** `StarterPlayer.StarterPlayerScripts.Client.UI` must contain `PromptStyle`, `UIFocus` and `CoreGuiSetup`.
   - If they are missing, the published place predates the merge. Then run `rojo serve` and connect Rojo from `main`. Rojo disturbs Lighting (jobs 0007, 0009): ignore lighting in this job.
3. Never save or publish. Run only **one** Play session at a time.
4. Start a **Play** test (solo) and wait **60 s** (the v2 world builds in chunks).
5. Run `get_console_output` and save it as `console_start.txt`.
   - Copy the two boot lines (`[Server] Hotwire City booted with …`, `[Client] … ready with …`).
   - Flag every error and warning that mentions PromptStyle, CoreGuiSetup, UIFocus, HelpText, Shard, PhoneController, GunShopUI, NotificationController, EventsClient, DeathScreenController, WantedService or LeaderboardService.
   - The keystone band sprite is switched off (`Shard.KEYSTONE_ART = false`), so no `[Shard] keystone band art` warning should appear.

**Admin commands:** the same as job 0006. Use chat `/hc …`, or this with `execute_luau` on the **Client**:

```lua
game:GetService("ReplicatedStorage").Remotes.AdminCommand:FireServer("weapon all")
```

Useful here:
- `cash <n>`, `weapon all`, `god on|off`, `rookie off`, `wanted <0-5>`;
- `spawn <carId>`, `car <carId>`, `tp <poi>`;
- `event <rushhour|cashrain|doublecash|luck>`, `hotdrop`.

Click UI by **instance path** (screenshots are scaled ~1.56× against the viewport; job 0006).

## Steps

Take every shot with `screen_capture` from the player's own view.

### A. First minute: CoreGui and Esc

1. **`a1_first_frame`**: capture at once.
   - Report whether a Roblox player list is visible, where the chat window sits, and whether any name floats over a head.
   - Overhead player names belong to the characters package; just note them.
2. **`a2_esc_bridge`**: within the first 60 s of the session, press `Esc` (the Roblox menu opens), then press `Esc` again to close it. Capture 1 s later.
   - Expected: our pause menu is open on the **MAP** tab.
   - **`a2b_esc_out_of_pause`** (review fix): with the pause menu still open (still inside the first 60 s), press `Esc` (the Roblox menu opens over it and our pause menu closes), then `Esc` again to close the Roblox menu. Capture 1 s later.
   - Expected: **no** pause menu: the game is back to normal play. Before the fix this re-opened the pause MAP every time. If the 60 s ran out first, write "window passed" and redo A2 on a fresh Play.
3. After **60 s**, press `Esc` and close the Roblox menu again. Capture **`a3_esc_hint`**.
   - Expected: no pause menu, and the help box top-left reads "Esc opens the Roblox menu. Press [P] to pause the game, [M] for the map." It fades after about 8 s.

### B. Help text timing (nit)

4. Run `/hc tutorial` (it replays the tutorial). Capture **`b1_help_shown`** while the first hint is up.
5. Wait **10 s** without pressing anything and capture **`b2_help_faded`**.
   - Expected: the help box is gone. It must not come back by itself; wait 20 s more to make sure.
   - Write down whether it returned and when (for example on a new tutorial step).

### C. Interaction prompts as GTA help text (new)

6. Run `/hc tp spawnplaza`, then walk (don't teleport) up to any parked street car until its prompt is in range.
   - Capture **`c1_prompt_car`**.
   - Expected: **no grey Roblox bubble** over the car. The top-left help box reads "<car name>" in bold, then "Hold [E] to hotwire."
   - If a tutorial hint was showing, it is pushed back and returns when you walk away.
7. Hold `E`. Capture **`c2_prompt_hold`** about halfway through.
   - Expected: a thin orange rule under the text fills.
   - Keep holding until the hotwire completes. Report: did it complete, and did the rule reset?
8. Walk away from the car. Capture **`c3_prompt_gone`**: the help box clears (or returns to the tutorial hint for only the seconds it had left; it never starts a fresh 8 s).
9. Run `/hc car hot_hatch`. Go into your garage (`/hc tp garage`) and stand by that car. Capture **`c4_prompt_garage`**.
   - Expected: one box with the car name, "Press [E] to drive." and "Hold [F] to sell for $X."
10. **Touch check (mandatory).** Touch keeps the engine's tappable bubbles for now (`PromptStyle.TOUCH_ENABLED = false`). This step decides whether the GTA touch buttons can be switched on.
    - Pick a phone in Studio's device emulator (Test → Device), restart Play and walk up to a car. Capture **`c5_prompt_touch_default`**.
      - Expected: the engine's own bubble with its tap target. Tapping and holding it hotwires. No help text.
    - Then, in Edit before the next Play, set `PromptStyle.TOUCH_ENABLED = true` in `StarterPlayer.StarterPlayerScripts.Client.UI.PromptStyle` (Rojo source: `src/client/UI/PromptStyle.luau`). Restart Play on the phone and walk up to a car. Capture **`c6_prompt_touch_gta`**.
      - Expected: no bubble, the help text top-left, and a flat black round **HOTWIRE** button above the MAP / PHONE buttons. Tapping and holding it hotwires.
      - Report pass or fail plainly: the lead switches `TOUCH_ENABLED` on only on a pass. Revert the edit afterwards (never save).
    - If the emulator can't be driven through the MCP, run this step on a real phone with the published test place, or write "blocked". Touch then stays on the engine's bubbles.
10b. **Streamer mode check.** In Pause > SETTINGS, switch the HUD off (streamer mode) and walk up to a car. Capture **`c7_prompt_streamer`**.
    - Expected: the HUD is gone and the engine's grey bubble shows over the car (the prompts must not vanish with the help box). Hold `E`: the hotwire works.
    - Switch the HUD back on next to the car. Expected: within a moment the bubble is replaced by the help text.
11. **Failure check:** in the console, search for `[PromptStyle]`. "falling back to the default prompts" means the new prompts gave up. Quote any such line exactly.

### D. Phone apps (bug 1)

12. Run `/hc weapon all`, press `1` (pistol) and keep it drawn. Press `B` to open the phone.
    - Click each app by instance path: **Contacts, Jobs, Daily, Gifts, Codes**. After each, capture **`d1_<app>`** and go back (Backspace or the back soft key).
    - Expected: every app shows its page.
    - Quote any `PhoneController` error exactly.
13. **`d2_phone_click_world`** (bug 4): with the phone still open and the pistol drawn, note the ammo count. Then left-click a point of the 3D world well away from the handset (use `user_mouse_input` at screen position (400, 300)). Capture.
    - Expected: **no shot**. The ammo is unchanged and there is no star.
    - Also hold right mouse for 1 s: the camera must not go to the aim view.
    - Close the phone (`B`). Fire once into the air: firing works again.

13b. **`d3_photo_click_world`** (review fix): open the phone's **Camera** app (the viewfinder with Exit / Take photo). With the pistol drawn, left-click the world at (400, 300), away from both buttons. Capture.
    - Expected: **no shot**; the ammo is unchanged. Leave with Exit.

### E. Pause menu and list menus (bug 4)

14. Pistol drawn. Press `P`. Left-click the world area at (400, 300), then close with `P`. Capture **`e1_pause_click`** before closing.
    - Expected: no shot fired; the ammo is unchanged.
15. Run `/hc tp gearshop` and press `E` on the counter prompt (the gear shop list menu opens). Left-click the world to the right of the list. Capture **`e2_list_click`**.
    - Expected: no shot.
    - Also check that the chat window is hidden while the list is open and comes back after you close it.

### F. Gun shop (bug 3 + store name)

16. Run **GUNSHOP** from job 0006 (Server), press `E` on the prompt, and capture **`f1_gun_shop`**.
    - Expected: the header reads **Lock & Load**, and the prompt help text reads "Press [E] to browse." (no grey bubble).
17. Note your cash. Left-click a row by instance path, for example `HC_GunShop.Menu.Rows.Row8` (Med Kit), or the Ammunition / Body Armor category and then a row.
    - Capture **`f2_gun_shop_click`**.
    - Expected: the click selects or buys **exactly once**. Report the cash before and after: one price, not two.
18. With the shop open, left-click the world beside the menu. Expected: no shot.
18b. **`f3_shop_under_pause`** (review fix). With the shop open, note your cash and press `P`.
    - Expected: the pause menu opens and the gun shop **closes**.
    - Left-click the pause menu's tabs and its left list column, where the shop rows were (for example screen positions (200, 130) and (150, 250)). Capture before closing.
    - Close the pause menu and note your cash. Expected: **unchanged**, with no purchase toast.
    - Close the shop with Backspace if it is still open.

### G. WASTED and BUSTED (bug 2) and bail (bug 5)

Job 0006's shard shots were night scenes, almost black around the title. Bug 2 is proven only if the band reads at night, so steps 19 and 21 are taken **twice**: once by day and once at night. For the night pass, run `game.Lighting.ClockTime = 0` with `execute_luau` on the **Server**. If LightingService resets it, wait for in-game night instead.

19. Run `/hc wanted 0`, `/hc god off` and `/hc cash 64886`. Run **KILL** (job 0006) on the Server.
    - Capture **`g1_wasted`** 2–3 s later, and **`g1_wasted_night`** on the night pass.
    - Expected: the black band across the middle, a lowercase red "wasted", and a subtitle under it: "Taken to the hospital", or "Hospital bill -$X" with the amount in red.
    - **Pass line (both passes): the band's top and bottom edges are visible against the scene.** The grade turns the world grey, not black.
    - Compare with `docs/v2/early/ui/shard_wasted_desktop.png`.
20. After the respawn, capture **`g2_wasted_after`**: a normal picture and HUD.
21. **Bust log check.**
    - Run `get_console_output` and note how many `[Bust]` lines exist so far: expect **0**. A death at 0 stars is not a bust.
    - Run `/hc rookie off`, `/hc wanted 2`. Stand still until an officer is within about 40 studs, then hold `H` (surrender).
    - Capture **`g3_busted`** about 2 s after the arrest starts, and **`g3_busted_night`** on the night pass.
    - Expected: the band, a lowercase blue "busted", and "Bail -$X" with the amount in red, plus "<car> impounded" if you had a car out.
    - **Pass line (both passes): the band's edges are visible against the scene.**
    - Report whether the surrender went through, or whether an officer arrested you first (full bail, `reason=police`) before the 1 s hold completed. This is routed to combat in the audit, row 7.4.
22. After the release, capture **`g4_busted_after`**.
    - Run `get_console_output` and save it as `console_bust.txt`. Copy every `[Bust]` line into the report.
    - Expected: **exactly one** new `[Bust] id=… reason=surrender …` line, and its `cash=a->b` difference equals its `bail=`.
    - Also compare the HUD cash before the arrest with the cash after the release: it dropped by exactly the bail shown on the BUSTED screen.
23. **Re-run the 0006 scenario:**
    - `/hc spawn hot_hatch`, `/hc wanted 2`, drive 5 s, press `F` to exit;
    - let the police arrest you (don't surrender), then copy the new `[Bust]` lines.
    - Expected: one line per arrest, and no arrest charged twice.
    - If two lines appear for what looked like one arrest, quote both: their `sinceLast=` field shows the seconds between them.

### H. Event rows and the feed (nits)

24. Run `/hc tp spawnplaza`, then `/hc event rushhour`, `/hc event doublecash` and `/hc hotdrop`. Wait 3 s and capture **`h1_event_rows`**.
    - Expected: quiet translucent rows stacked **above the radar** (the GTA feed position):
      - "Hot drop lands in 0:2x" with a second grey line that starts with the distance **in m or km**, then the rarity and the car (a long name is cut at its end, never the distance);
      - "Rush hour 1:xx";
      - "Double cash x:xx".
    - Expected: **nothing** in the middle or top-centre of the screen, no emoji, no "CLAIM IT!".
    - Compare with `docs/v2/early/ui/event_feed_desktop.png`.
25. Listen when each event starts and report the sound: the expected sound is the feed's short blip, not an air horn or a car horn.
26. Draw the pistol and aim (hold right mouse). Capture **`h2_crosshair_clear`**: nothing from the events covers the crosshair.
27. Read every feed line that appeared since the start (`h1`, or the console if lines were logged). Quote any that still contains "!" or an emoji.
27b. **Touch.** If step 10's phone emulator works, repeat step 24 on the phone and capture **`h3_event_touch`**.
    - Expected: "RUSH HOUR 1:xx" and "DOUBLE CASH x:xx" as timer bars **top-centre**, under the radio line.
    - The left column under the help box holds at most two entries: the hot drop row and one feed card. Nothing reaches the thumbstick.

### I. Vehicle name (nit)

28. Run `/hc spawn hot_hatch`. Capture **`i1_vehicle_name`** within 1 s of being seated.
    - Expected, bottom-right, on the location block's top line: the brand small, then the model large in the script face to its right. The district / street lines sit below it and never overlap it, even when you drive into a new district while the name is up.
29. Capture **`i2_vehicle_name_gone`** 5 s later. Expected: the name has faded out. Press `F` to exit.

### J. Leaderboards

30. If `CollectionService:GetTagged("LeaderboardBoard")` is not empty (Server `execute_luau`), teleport in front of one board (5 studs, facing it) and capture **`j1_leaderboard`**.
    - Expected: a matte black board with a thin orange rule, "RICH LIST" or "MOST WANTED" in a condensed font, ranks "01"–"10", no emoji, no neon frame.
    - If the list is empty, write "no boards in this world".

### Finish

31. Run `get_console_output` and save it as `console_end.txt`. Stop Play.

## Report (`report.md`)

- The commit hash, the place version, and whether Rojo was used.
- **Bugs 1–5:** pass or fail each one, with the shot names. Quote every `[Bust]` line.
- **Prompts:** did any grey Roblox prompt bubble appear anywhere on keyboard? Did hold-to-hotwire, drive, sell and the shop prompt all work from the keyboard? Quote any `[PromptStyle]` line.
- **Touch (step 10):** pass, fail or blocked, for both the engine bubbles and the GTA touch buttons (`TOUCH_ENABLED = true`). **Streamer mode (step 10b):** did the bubbles show with the HUD off?
- **Night shard (G):** do `g1_wasted_night` and `g3_busted_night` meet the pass line (band edges visible)?
- **Nits:** help text timing, event rows (position, copy, sound), vehicle name, gun store name.
- **CoreGui / Esc:** what you saw in A1–A3.
- **Errors:** every error and warning from Setup step 5's list, quoted exactly.
- One line: does the HUD and its menus now read as GTA V? List anything that still reads as "kids' game", with the shot name.

Never save or publish the place.
