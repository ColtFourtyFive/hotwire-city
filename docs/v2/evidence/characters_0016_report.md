# Job 0016 report: GTA player characters and the on-foot feel

## Setup
- **Code:** `main` @ **`68532b3`**.
- **Place:** opened from Roblox at **v35+**, confirmed in Edit:
  - AppearanceService and FootService are present;
  - the Look schedule includes `nightLate@0.00 … night@19.50`, night Ft `102872066736317`.
- **Rojo:** not connected. Never saved or published.
- **StarterPlayer (Edit):**
  - `CharacterWalkSpeed` 16, `CharacterJumpHeight` 4.5, `NameDisplayDistance` 0, `HealthDisplayDistance` 0, `CameraMaxZoomDistance` 60.
  - `LoadCharacterAppearance`, `CharacterUseJumpPower` and `EnableMouseLockOption` aren't scriptable from `execute_luau` (unread). Behaviour matches: the realistic look is applied, and the jump peaked at 4.56 studs.
  - Nothing was set by hand.
- **DataStore mode:** the owner reports **Studio API access ON**, so looks persist. The creator still opened on this first Play.
- **One solo Play.** The 2-player section was **skipped**: the MCP can only start solo Play, not Test → Clients and Servers.

**Test-method caveats:**
- **Simulated mouse movement doesn't turn the camera.**
  - In the creator, `user_mouse_input` drags left the camera CFrame unchanged.
  - On foot, with `MouseBehavior = LockCenter`, MCP `moveTo` sends no mouse delta.
  - So **`creator_orbit` and `mouse_look` couldn't be tested**. `cam_recenter` and `cam_wall` were driven by a scripted camera turn, which the foot camera reads as player look input.
- **Screenshot latency (~0.5–1 s)** missed the 1.4 s ragdoll pose. The ragdoll is confirmed from the Humanoid state log instead.

## Stopwatch
- **Creator up: ≤ 14 s from Play.** It was already open on the first check; captured at 14 s.
- **Street after leaving the creator: 98 s.** This is *not* the "skip at once" number: I spent ~80 s working through the creator rows first. I never selected Skip; I left by **Save look** (see below).
- **Never saw a blocky default avatar** on the first spawn: the creator was already up when I first looked. The blocky avatar appears only with "Use my Roblox avatar" On (by design) and on **v1 NPCs**, which are still blocky Roblox rigs (`lineup_close` background).

## Shots, seen vs expected

| Shot | Seen | Verdict |
|---|---|---|
| `creator_first` | A dark concrete room, a mugshot height chart (feet, 1'–7') on the back wall, the character full-body right of centre, the list menu top-left ("Character" / "CREATE YOUR CHARACTER 1/11"), and the footer bottom-right (Zoom Z / Drag to rotate). No HUD. Default look: bald, pinstripe Business coat. | ✅ as specified |
| `creator_face` | On **Hair** the camera moves in to a head close-up. | ✅ |
| `creator_outfits` / `creator_outfit2` | Business pinstripe coat, then **Blazer and tie**. The clothes change correctly. | ✅ |
| `creator_skin` | Porcelain → **Olive** after 4 × Right; the tone is applied evenly to the face and hands. | ✅ |
| `creator_random_1..3` | Biker (black leather jacket and jeans); Workwear (red flannel and work boots, "Surfer" hair); Beach (red aloha shirt and shorts). Varied, coherent outfits. Taken in the Wardrobe (see the note below). | ✅ |
| `creator_orbit` | A mouse drag via the MCP didn't turn the camera (CFrame unchanged before and after). | ⚠️ **untestable through the MCP** |
| `creator_hotkeys` | `1`, `5`, `Tab`, `R`, `P`, `B`, `M`, then a left-drag: no gun (`EquippedWeapon` empty), no wheel, pause, phone or map. Only `HC_List` / `HC_Creator*` GUIs are enabled. | ✅ |
| `street_arrival` (+ `street_after_save_look_first_run`) | In the street wearing the last creator look. Help line: "Change your look any time: Pause > Settings > Wardrobe." | ✅ (left by Save look, not Skip) |
| `lineup_street` / `lineup_engine` / `lineup_close` | All 8 looks rendered with no missing or floating clothes (see the honest verdict below). | ✅ assembled; ⚠️ style |
| `cam_rest` | FOV **58**. The character is 1.25 studs left of centre (over the right shoulder), ~1/3 of the screen tall, camera ~11.8 studs back. Mouse `LockCenter`, cursor hidden. | ✅ (see the GTA comparison) |
| `mouse_look` | Cursor hidden and mouse captured on foot (`LockCenter`, `MouseIconEnabled=false`); in `P` the cursor appears (`Default`) and menu clicks work (Settings tab clicks). Turning by mouse can't be driven through the MCP. | ✅ capture/release; ⚠️ turning untestable |
| `sprint` | Speed **16 → 24**, FOV kick **58 → 64**. Stamina drains 1.0 → 0 in **~7.2 s** (not ~9), then drops to a jog (16) and the FOV eases back. Refill starts after **~1 s**. The yellow bar under the radar drains visibly. *(I held S, not W, so the shot shows the character running toward the camera.)* | ✅ |
| `walk` | `Left Alt` + `W`: speed **10**. | ✅ |
| `cam_recenter` | After a 96° scripted turn, holding a direction for 3 s brought the camera back to −3.8° (it swung round behind the running character). | ✅ |
| `cam_wall` | A temporary 30 × 20 wall placed 4 studs behind the player: the camera pulled in from 11.8 to **5.6 studs** and sat on the player side (no clipping). | ✅ |
| `jump` | Peak **4.56 studs** (JumpHeight 4.5): a short hop. **Holding Space for 3 s gave 0 extra jumps**, so no bunny-hop. | ✅ |
| `fall_ragdoll` | DROP30 #1: HP **100 → 88** (−12), states `Freefall > Landed > Running > Physics (1.10 → 2.52 s) > Running`, i.e. **~1.4 s ragdoll**. DROP30 #2: **88 → 79** (−9). The screenshots missed the pose (latency). | ⚠️ ragdoll ✅, damage low (expected ~20) |
| `fall_lethal` / `fall_wasted` / `respawn_look` | `/hc armor 100`, then DROP80 twice. **No WASTED.** #1: HP 79 → 79. #2: armour **100 → 88**, HP 79. A lethal fall is absorbed like a ~12-damage hit. | ❌ **FAIL** |
| `fall_water` | The v1 pier has no terrain water within 60 studs (`fall_water_pier_no_water`). I found the shore at (−890, −890). DROPWATER over water at (−902, −2, −894): **HP 79 → 79, armour 88 → 88**, states `Freefall > Landed > Running`. No damage and no ragdoll. The water is shallow (~2 studs), so no swim. | ✅ no damage |
| `emote_chat` | `/e dance` typed in chat: no dance (the Animator only plays the idle track). Whether the "/e dance" message was hidden from the chat log couldn't be confirmed (chat not visible in the capture; LegacyChatService). | ✅ no emote; ? chat echo |
| `settings_character` | SETTINGS: GAME (Music, SFX, Streamer, Auto-accelerate, Speed readout), **CHARACTER (Wardrobe, Use my Roblox avatar Off)**, MORE. | ✅ |
| `own_avatar` / `own_avatar_off` | On: the blocky bacon-hair Roblox avatar, running with the **realistic run animation**. Off: the realistic look returns. | ✅ |
| `own_avatar_wardrobe` / `own_avatar_back` / `own_avatar_saved` | With On, the Wardrobe shows the realistic look (not the Roblox avatar); Backspace brings the Roblox avatar back; Wardrobe → **Save look** leaves in the realistic look with `HC_LookOwn=false` (Off). The On/Off-within-a-second toggle was **not run**. | ✅ (toggle race not tested) |
| `wardrobe` / `wardrobe_cancelled` | Wardrobe subtitle "WARDROBE", **no Skip row** (10 rows, ending in Randomize / Save look). Hair → Curly Fade, then Backspace: back in the street with the **old hair** (Short and Sleek); the look key is unchanged. | ✅ |
| `wardrobe_quick_back` | Three runs: **#1 Backspace ~0.3 s after opening was ignored**; still in the creator room (17,140 studs away), no fall or death. A second Backspace returned to **exactly the same spot (0.0 studs), alive**. **#2 and #3 (Backspace ~0.6 s after opening): same spot, alive, first press.** | ⚠️ a very early Back is swallowed (no harm) |
| `aim_still_works` | Pistol drawn, RMB: tight over-the-shoulder aim, dot crosshair, ammo "12 59". On release the FOV returns to **58**, CameraType Custom. | ✅ |
| `car_cam` / `car_exit` | `spawn hot_hatch` wedged the car against a plaza palm. The chase camera faced the car's front; FOV 70. **`F` didn't exit, ×3** (Seated stayed true); a scripted car move was rewound (anti-teleport). Forcing `Sit=false`: FOV **70 → 58** within 0.25 s. | ⚠️ exit blocked (likely no exit room by the tree); FOV restore ✅ |

**Note on the first creator run:** the menu count was **11** rows (with Skip) on first join and **10** in the Wardrobe (no Skip). My Enter at "10/11" was on **Save look**, not Randomize, so I left the first-run creator early. The Randomize shots were then taken in the Wardrobe, which has the same rows apart from Skip. **Skip was never pressed**, so the "under 30 s if you skip at once" check wasn't measured.

## Honest verdict: the characters vs GTA V
- **The clothes are the strong point.** Suit and tie, denim jacket, hi-vis vests, leather and biker jackets, a hoodie, flannel and work boots: believable streetwear with correct layering. Nothing was missing or floating in 8 + 6 looks.
- **The bodies and faces are not GTA.** Every look uses a stylised Roblox "realistic-lite" body:
  - an **oversized head** (about 1/5–1/6 of body height, vs ~1/7.5 in GTA), **large cartoon eyes** with heavy brows, short legs, and big hands and shoes;
  - from street distance they read as **Roblox "Rthro-lite" avatars**, not as GTA V pedestrians.
- Compared with the old blocky avatar it's a big step up, but **side by side with GTA V the proportions and faces are the giveaway**.
- **Score: 4/10** for "realistic GTA character" (7/10 for clothing, 3/10 for body and face).

**Camera vs GTA V on foot:**
- **Similar:** the over-the-right-shoulder offset, the narrower FOV (58), the slight lag, recentring while running, and wall pull-in.
- **Different:**
  - GTA's default on-foot camera sits **closer and lower** (the character is about half the screen tall, and the horizon is near the shoulder line); ours sits ~12 studs back, so the character is ~1/3 of the screen.
  - GTA frames the character a little further left.

## Bugs and findings, by priority
1. **❌ A lethal fall doesn't kill (or even hurt much).**
   - **What happened:**
     - DROP80 with full armour cost only 12 armour; DROP30 does 9–12 HP (expected ~20).
     - Server-side state on DROP80: `Landed` reported at **y = 27 above ground with vy = −144**, still moving at −157 the next sample.
   - **Likely cause:**
     - `FootService._sample` takes the impact from `prevVy` (one Heartbeat before the stop) on the **server's replicated copy of a client-owned character**.
     - The smoothed velocity under-reports the real impact (~177 studs/s for 80 studs) as ~70, giving ~12 damage, which armour absorbs.
   - **Suggest:** track the **peak downward speed** (or the height lost) during the airborne phase and use that at landing.
2. **⚠️ MinimapController GPS spam while the creator is open:**
   - `[MinimapController] slow GPS route` **about once a second** for the whole creator session (04:07–04:11, 04:19–04:22), mostly 8–25 ms with spikes of **101.7, 117.1, 126.7 and 329.7 ms**.
   - The character is parked in the creator room at (−12000, 2400, −12000), far off the road graph, so routing from there is expensive.
   - **Suggest:** pause GPS while `HC_Creator` is set.
3. **⚠️ A very early Backspace in the Wardrobe (≤ 0.3 s) is ignored.** It's harmless (no fall or death), but the player has to press again.
4. **⚠️ Car exit with `F` failed ×3** with the car wedged against a palm. It may be by design (no exit space), but nothing told the player why. **Suggest:** an "exit blocked" hint, or exit through the other door.
5. **Sprint duration ~7.2 s, not ~9 s** (tuning note).

## Console (`console.txt`)
- **Server:** no errors or warnings mentioning AppearanceService, FootService, FootCamera, FootMovement, NameTags, CharacterCreator, ApplyDescription or HumanoidDescription. **No `[AppearanceService] … missing garments / hair / shoes`** warnings: no look dropped a fallback level.
- **Client:** no errors. ~370 `[MinimapController] slow GPS route` warnings (see bug 2). Nothing from the flagged systems.

## Not run
- The **2-player section** (MCP limitation).
- The **touch pass** (Studio device emulator not drivable through the MCP).
- **`creator_orbit` and `mouse_look` turning** (MCP mouse can't send deltas).
- The **avatar toggle race** (On/Off within 1 s).
- **Skip timing.**
