# Job 0006: Wave B playtest: GTA HUD + combat (Play solo, then 2 players if possible)

**Goal:** the first real-engine look at Wave B on `main`:

- **UI v2:** the GTA HUD (radar bottom-left with health / armour / ability bars under it, cash and stars top-right,
  help text top-left), the pause menu, the phone, the list menus, and the big messages (WASTED / BUSTED).
- **Combat v2:** guns with the over-the-shoulder camera, the weapon wheel, the FREEDOM ARMS gun shop, hit markers,
  police that shoot back at 3 stars, WASTED at the hospital, and BUSTED with surrender.

The world is still v1 (the v2 city is a later wave). Judge only the HUD, the menus and the combat.

**Integration points to watch.** This merge joined the two packages. These are the places where they meet:

- There is **one** set of health / armour bars, under the radar. A second set bottom-left is a bug.
- The **ammo** line ("12  48") sits under the cash and never covers the green / red +$ / -$ cash-change line.
- With a gun drawn, the **pause menu, phone and gun shop** free the mouse cursor, so their rows can be clicked.
- **WASTED** and **BUSTED** use one style: a black band across the middle, a lowercase heavy title, and a subtitle.

## Setup

1. Run `git pull --ff-only origin main`. Write the commit hash in the report.
2. Open the place with **File → Open from Roblox → Hotwire City**.
   - The published version predates Wave B, so this job needs the code from the checkout: run `rojo serve` and
     connect Rojo (**Plugins → Rojo → Connect**).
   - Rojo live-sync is known to disturb Lighting and MaterialService (jobs 0007, 0009). Ignore lighting in this job.
   - Run only **one** Play session at a time. A second session takes the DataService lock and kicks the first one.
3. Start a **Play** test (solo) and wait **45 s**.
4. Run `get_console_output` and save it as `console_start.txt`. Check for both of these lines:
   - `[Server] Hotwire City booted with 28 systems`
   - `[Client] <name> ready with 27 controllers`

   Flag every error or warning that mentions any of these: HUDController, MenuController, PhoneController,
   MinimapController, CombatHUD, CombatClient, WeaponClient, WeaponWheel, ShoulderCamera, ShotFxController,
   DeathScreenController, GunShopUI, WeaponService, DamageService, PoliceCombatService, Shard, Kit.

## Admin commands

Studio makes everyone an admin. Type commands in chat: press `/`, type the line, then press Enter. If chat input is
awkward through MCP, run this with `execute_luau` on the **Client** instead, putting the command after `/hc`:

```lua
game:GetService("ReplicatedStorage").Remotes.AdminCommand:FireServer("weapon all")
```

| Command | Effect |
|---|---|
| `/hc weapon all` | every weapon, with 4 spare magazines (`/hc weapon pistol` gives one) |
| `/hc ammo` | fill reserve ammo |
| `/hc armor 100` | full armour (the blue bar) |
| `/hc god on` / `/hc god off` | no damage / normal damage |
| `/hc rookie off` | end new-player protection (otherwise police hold fire at 3+ stars) |
| `/hc wanted <0-5>` (alias `/hc stars <n>`) | set wanted stars; police units come for you |
| `/hc spawn hot_hatch` | spawn a drivable car in front of you and seat you |
| `/hc cash 50000` | money for the gun shop |
| `/hc tp spawnplaza` | teleport (also `dealership`, `policehq`, `gearshop`, `chopshop`, `stuntpark`, `park`, `pier`, `garage`) |
| `/hc audit` | your ShotAudit score and the reasons for rejected shots |
| `/hc help` | the full list |

**Keys:**

- Guns: `1` pistols, `2` SMGs, `3` rifles, `4` shotguns, `5` melee (press again to cycle within a slot); `0` holsters.
- Hold `Tab` for the weapon wheel. Hold right mouse to aim, left mouse to fire, `R` to reload, `V` to swap shoulders.
- Hold `H` to surrender (at 1–2 stars, with police within 40 studs).
- `P` opens the pause menu (its first tab is the MAP), `B` the phone, and `Z` expands the radar for 6 s.
- On foot, `E` uses prompts. In a car, `F` exits.

## Steps (solo)

Take every shot with `screen_capture` from the player's own view. Don't override the camera unless a step says so.

1. **`hud_rest_desktop`**
   - Run `/hc tp spawnplaza`, stand still for 10 s (until the help text fades), then capture.
   - Expected: the radar bottom-left with three thin bars under it; cash top-right; no stars; nothing in the centre.
2. **`radar_expanded`**: press `Z` and capture within 2 s. The radar should be twice the size, with the bars still
   under it.
3. **`weapon_wheel`**
   - Run `/hc weapon all`, `/hc armor 100` and `/hc cash 50000`.
   - Hold `Tab` and capture while it is held. Release `Tab`.
4. **`aim_shoulder`**: press `1` (Kessler P9). Hold right mouse for 2 s and capture while aiming. Expected: the camera
   is over the right shoulder, there is a small dot crosshair, and the ammo shows top-right under the cash.
5. **`cash_delta_with_ammo`**: with the pistol still drawn, run `/hc cash 1000` and capture within 1 s. The green
   `+$1,000` line must not overlap the ammo line.
6. **`phone_gun_drawn`**
   - With the pistol drawn and not aiming, press `B`. Capture.
   - Then click one app tile with the mouse (`user_mouse_input`) and capture **`phone_app`**.
   - Report whether the cursor was visible and whether the click worked. Press `B` to close.
7. **`pause_menu`**
   - With the pistol drawn, press `P`. Capture. It opens on the MAP tab, or on the tab used last.
   - Click the next tab header with the mouse and capture **`pause_tab2`**.
   - Report whether the click worked. Press `P` to close.
8. **`gun_shop`**
   - Run **GUNSHOP** below with `execute_luau` on the **Server**. It moves you to the FREEDOM ARMS counter.
   - Press `E` on the "Browse" prompt, or run **OPENSHOP** below on the Server. Capture.
   - Move down two rows with the arrow keys and capture **`gun_shop_row`**.
   - Buy something cheap, such as ammo or light armour (Enter or a click). Report what happened.
   - Close the shop (Backspace).
9. **`shoot_cop`**
   - Run `/hc tp spawnplaza`, then `/hc god on`, `/hc rookie off` and `/hc wanted 3`. Wait up to 30 s for police
     (cars, then officers on foot in `Workspace.NPCs`, named `Officer`).
   - Press `3` (Carbine). Aim at an officer and fire short bursts.
   - Capture **`shoot_cop`** while firing. Look for the tracers, the hit marker (a small x on the crosshair) and the
     ammo count dropping.
   - Capture **`police_fire`** while officers shoot back. Look for the red damage arcs around the crosshair; the bars
     under the radar should not drop because god mode is on.
10. **`driving_stars`**
    - Run `/hc wanted 0`. Wait 5 s.
    - Run `/hc spawn hot_hatch`, then `/hc wanted 2`.
    - Drive with `W` for 4 s and capture. Expected: no gun HUD, the radar zoomed out, stars top-right, and the car
      name / street lines bottom-right.
    - Press `F` to exit.
11. **`busted`**
    - Stay at 2 stars and stand still on foot. Wait until an officer is within about 40 studs. Desktop has no on-screen
      hint; the SURRENDER button exists only on touch.
    - Hold `H` for 1.5 s, or just stand still until the "BEING ARRESTED" bar under the stars fills.
    - Capture **`busted`** about 2 s after the arrest starts (the band appears at 1.2 s; the screen goes black at
      4.4 s). If you missed it, repeat with `/hc wanted 1`.
    - After the release (about 6 s), capture **`busted_after`**. Expect a feed line ("Released from Police HQ…") and no
      grey or black screen left over.
12. **`wasted`**
    - Run `/hc wanted 0` and `/hc god off`.
    - Run **KILL** below on the **Server**. Capture **`wasted`** 2–3 s later (the band appears at 1.2 s; the screen
      goes black at 4.4 s).
    - After the respawn at the hospital, capture **`wasted_after`**. Expect a "Treated at…" feed line and a normal
      picture: no grey grade, no black curtain.
13. Run `get_console_output` and save it as `console_end.txt`. Stop Play.

## Steps (2 players, if Studio allows it)

1. Go to **Test → Clients and Servers**, choose **2 players**, and press **Start**.
   - If the MCP can't drive two client windows, skip this section and say so in the report.
   - Optional: set **File → Studio Settings → Network → Incoming Replication Lag** to `0.2` first, to simulate 200 ms of
     latency (gta_combat §13.3). Write down whether you did.
2. On **both** clients, run `/hc rookie off` and `/hc tp spawnplaza`, and wait 6 s (spawn protection).
   - On Player1, run `/hc weapon all`.
   - Garages, gun stores and hospitals are safe zones; the plaza is not.
3. Player1 draws the pistol (`1`), aims at Player2 and fires.
   - On Player1, capture **`pvp_hit`**: the hit marker.
   - On Player2, capture **`pvp_victim`**: the damage arc and the health bar dropping.
   - Keep firing until Player2 is downed, then capture **`pvp_wasted`** on Player2.
4. **Bad-origin check.**
   - On Player1, with the pistol drawn, run **BADSHOT** below with `execute_luau` on Player1's **Client**.
   - Then run `/hc audit` and copy the reply (a toast or the console) into the report. Expect a rejection reason
     such as `origin`. The reply comes as an on-screen notification.
5. Save the server and both clients' console output as `console_2p.txt`. Stop the test.

## Report (`report.md`)

- The commit hash, and whether Rojo synced cleanly.
- **HUD at rest:** what overlaps what, if anything? How many sets of health bars are there? Do the radar, cash, stars
  and help text read as GTA V, or as a kids' game?
- **Combat:** shoulder camera feel, crosshair, ammo, hit markers, damage arcs, tracers. Did the police shoot back at 3
  stars? Any rubber-banding?
- **Cursor:** with a gun drawn, could you click in the phone, in the pause menu and in the gun shop?
- **WASTED / BUSTED:** do they look like GTA (band, title, grade, fade)? Did anything get stuck after the respawn or
  release (a grey picture, a black screen, no HUD)?
- **2 players:** did the hits register? What did `/hc audit` say?
- **Errors:** every runtime error and warning from the lists in Setup step 4, quoted exactly.

Never save or publish the place.

## GUNSHOP (Server)

```lua
-- move player 1 in front of the nearest FREEDOM ARMS counter (a part holding the "GunShopPrompt" ProximityPrompt)
local p = game:GetService("Players"):GetPlayers()[1]
local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
local best, bestD = nil, math.huge
for _, d in workspace:GetDescendants() do
	if d:IsA("ProximityPrompt") and d.Name == "GunShopPrompt" and d.Parent:IsA("BasePart") then
		local dist = root and (d.Parent.Position - root.Position).Magnitude or 0
		if dist < bestD then
			best, bestD = d.Parent, dist
		end
	end
end
assert(best, "no GunShopPrompt in the workspace")
local stand = best.Position + best.CFrame.LookVector * 5
p.Character:PivotTo(CFrame.lookAt(stand + Vector3.new(0, 2, 0), best.Position))
return "at " .. best:GetFullName()
```

## OPENSHOP (Server)

```lua
-- the same thing the counter prompt does: ask player 1's client to open the gun shop
local p = game:GetService("Players"):GetPlayers()[1]
game:GetService("ReplicatedStorage").Remotes.OpenUI:FireClient(p, "GunShop")
```

## KILL (Server)

```lua
local p = game:GetService("Players"):GetPlayers()[1]
local hum = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
if hum then
	hum.Health = 0
end
```

## BADSHOT (Client, Player1)

```lua
-- one pistol shot whose muzzle claims to be 60 studs from the head: the server must reject it (ShotAudit "origin")
local lp = game:GetService("Players").LocalPlayer
local head = lp.Character and lp.Character:FindFirstChild("Head")
assert(head, "no character")
local look = workspace.CurrentCamera.CFrame.LookVector
game:GetService("ReplicatedStorage").Remotes.WeaponFire:FireServer({
	{ w = "pistol", t = workspace:GetServerTimeNow(), o = head.Position + Vector3.new(0, 0, 60), d = look, s = 12345, a = true, h = {} },
})
return "sent"
```
