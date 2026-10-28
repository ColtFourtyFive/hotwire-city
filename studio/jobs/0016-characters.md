# Job 0016: GTA player characters and the on-foot feel (Play solo)

**Goal:** the first real-engine look at package C4a (branch `v2/characters`, merged by the integrator):

- **Characters:** every player spawns as a realistic GTA-style character (realistic body, dynamic head, skin tone,
  layered outfit, mocap walk), never the blocky Roblox avatar. Overhead Roblox names / health bars are gone.
- **Character creator:** opens on first join; Body / Face / Skin tone / Hair / Hair color / Outfit style / Outfit /
  Walk style rows, Randomize, Save, Skip; a dark lineup room with a height chart and an orbit camera.
- **On foot:** an over-the-shoulder camera (FOV 58, the character slightly left of centre), slight lag, no wall
  clipping, recentring behind you while running; the mouse turns the view without a held button (no cursor on foot);
  walk / jog / sprint with a stamina bar; a short heavy jump; fall damage with a brief ragdoll (lethal falls kill
  through armor; water landings are free).

Revision 2 (C4a fix pass) adds the steps marked **[fix]**: a quick open -> Back, hotkeys inside the creator, the
orbit limits and the height chart, the own-avatar wardrobe, mouse capture, an armored lethal fall, a water landing,
`/e dance`, a touch pass, name tags after a respawn, and an in-engine lineup capture.

The world, cars, traffic and police are other packages: judge only the characters, the creator and the on-foot feel.

Reference for the camera framing: `docs/v2/research/img_gta/ref_gtawiki_GTAV_screen.jpg` (GTA V on foot).

## Setup

1. Run `git pull --ff-only origin main`. Write the commit hash in the report.
2. Open the place with **File → Open from Roblox → Hotwire City**, run `rojo serve` and connect Rojo
   (**Plugins → Rojo → Connect**). Run only one Play session at a time.
3. In the Explorer, select **StarterPlayer** and check these properties (Rojo syncs them from `default.project.json`;
   if Rojo did not, set them by hand for this session only and say so in the report; never save the place):
   - `LoadCharacterAppearance` = **false**, `CharacterWalkSpeed` = 16, `CharacterUseJumpPower` = false,
     `CharacterJumpHeight` = 4.5, `EnableMouseLockOption` = false, `NameDisplayDistance` = 0,
     `HealthDisplayDistance` = 0, `CameraMaxZoomDistance` = 60.
4. Studio DataStores: if **Game Settings → Security → Enable Studio Access to API Services** is off, looks are kept in
   memory and the creator opens on **every** Play (that is expected here). Write down which mode you ran in.
5. Start a **Play** test (solo). Start a stopwatch when you press Play.

## Admin commands and keys

Type commands in chat (`/`), or run `game:GetService("ReplicatedStorage").Remotes.AdminCommand:FireServer("<cmd>")`
with `execute_luau` on the **Client**. Useful: `/hc tp spawnplaza`, `/hc god on|off`, `/hc weapon pistol`,
`/hc spawn hot_hatch`, `/hc wanted 0`.

- Creator: Up / Down choose a row, Left / Right change it, Enter selects (Randomize / Save / Skip), Backspace backs
  out. Drag with the mouse to turn round the character (up to 100° either side); `Z` toggles the face close-up.
- On foot: hold `Shift` to sprint, hold `Left Alt` to walk, `Space` jumps. `P` pause (SETTINGS tab), `B` phone, `M`
  map. Moving the mouse turns the camera on foot (no button needed).

## Steps

Take every shot with `screen_capture` from the player's own view. Do not override the camera unless a step says so.

1. **`creator_first`**: the creator should open by itself within a few seconds of spawning. Capture it as soon as it
   is up. Write down the stopwatch time. Expected: a dark concrete room with a height chart (feet) on the back wall,
   the character full body right of centre, the list menu top-left ("Character" / "Create your character"), and a
   small footer bottom-right (Zoom, Drag to rotate). No HUD.
2. **`creator_face`**: press Down to the **Hair** row. The camera should move in to a head close-up. Capture.
3. **`creator_outfits`**: go to **Outfit style** and press Right until it reads **Business**; wait 2 s for the body to
   change, capture. Then go to **Outfit** and press Right once; capture **`creator_outfit2`**.
4. **`creator_skin`**: on **Skin tone**, press Right 4 times (wait 1 s each). Capture.
5. **`creator_random_1`** … **`creator_random_3`**: select **Randomize** (Enter) three times, waiting 2 s and capturing
   after each.
6. **`creator_orbit`** **[fix]**: drag the mouse across the empty right half of the screen to turn the camera about
   90°. Capture. Then keep dragging the same way until it stops (the 100° limit) and capture
   **`creator_orbit_right`**; drag all the way the other way and capture **`creator_orbit_left`**. Expected: the camera
   stays inside the room at both limits (never behind or inside a wall; the character in frame), and the height chart
   on the back wall is readable (white lines, foot labels 1' to 7') whenever the wall is in view.
6b. **`creator_hotkeys`** **[fix]**: still in the creator, press `1`, `5`, `Tab`, `R`, `P`, `B` and `M` (one at a time,
   1 s apart), then hold the left mouse button and drag. Capture. Expected: nothing happens: no gun drawn, no weapon
   wheel, no pause menu, no phone, no map; the drag only turns the camera.
7. **`street_arrival`**: select **Skip**. Write down the stopwatch time when you are back on the street (it must be
   under 30 s from Play for a player who skips at once). Capture. Expected: the character in the street, wearing the
   look shown last in the creator, with a help line naming Pause > Settings > Wardrobe.
8. **`lineup_street`**: run **LINEUP** below on the **Server**. Eight realistic characters (the eight looks on
   `docs/v2/evidence/characters_lineup.jpg`, in order) appear in a row in front of you. Turn the camera to face them
   (move the mouse) and capture; then walk up to about 8 studs from them and capture **`lineup_close`**, and capture
   **`lineup_engine`** square-on from about 12 studs with all eight in frame: this in-engine lineup replaces the
   catalog-thumbnail sheet as the evidence of how the assembled looks read. Judge: realistic bodies and faces,
   believable clothes, no blocky or cartoon avatars, no floating or missing clothes.
9. **`cam_rest`**: stand still on a street, camera behind you, and capture. Expected: the character a little left of
   centre (over the right shoulder), roughly half the screen tall, a narrower FOV than default Roblox. Compare with
   the GTA V reference above and describe the difference in the report.
9b. **`mouse_look`** **[fix]**: without pressing any mouse button, move the mouse left and right. Expected: the camera
   turns with the mouse and no cursor is visible. Press `P`: the cursor appears and the menu works with the mouse;
   close it: the mouse is captured again. Report both.
10. **`sprint`**: hold `W` + `Shift` for 3 s and capture while running. Expected: faster than default, a slight FOV
    kick, and the third (yellow) bar under the radar draining. Keep sprinting until it runs dry (about 9 s) and
    report what happened (you drop to a jog; the bar refills after a short pause).
11. **`walk`**: hold `W` + `Left Alt` and capture. Expected: a slow walk.
12. **`cam_recenter`**: stand still, turn the camera 90° to the side, then hold `W` for 3 s without touching the mouse.
    Capture at the end. Expected: the camera swings round behind you while you run.
13. **`cam_wall`**: walk backwards (`S`) until your back is against a building wall, then turn the camera so the wall
    is between the camera and you. Capture. Expected: the camera pulls in front of the wall smoothly (no clipping
    through it, no popping).
14. **`jump`**: press `Space` and capture at the top of the jump. Expected: a short hop (about knee height), not the
    floaty Roblox jump. Report whether you could bunny-hop by holding Space.
15. **`fall_ragdoll`**: run `/hc god off`, then run **DROP30** below on the **Server**. Capture about 0.5 s after you
    land. Expected: the body ragdolls for about 1.5 s, then stands up; health drops by about 20. Report the HP.
16. **`fall_lethal`** **[fix]**: run `/hc armor 100`, then **DROP80** on the **Server**. Expected: WASTED even with
    full armor. Capture **`fall_wasted`**. After the respawn the look must be the same (capture **`respawn_look`**).
16b. **`fall_water`** **[fix]**: run `/hc god off`, stand on a pier or quay edge above open water, and run **DROPWATER**
    below on the **Server** (it drops you 40 studs over the water next to you). Expected: you splash in and swim; no
    damage, no ragdoll. Report the HP before and after.
16c. **`emote_chat`** **[fix]**: type `/e dance` in chat and press Enter, then `/e wave`. Capture. Expected: nothing
    plays, and no "/e dance" message appears in the chat.
17. **`settings_character`**: press `P`, open the **SETTINGS** tab and scroll to the **Character** section (Wardrobe,
    Use my Roblox avatar). Capture.
18. **`own_avatar`**: switch **Use my Roblox avatar** to On, close the menu, wait 3 s and capture. Expected: your own
    Roblox avatar, still walking with the realistic animations (walk forward while capturing). Switch it back Off and
    capture **`own_avatar_off`** (the realistic look returns).
18b. **`own_avatar_wardrobe`** **[fix]**: switch **Use my Roblox avatar** On again, then select **Wardrobe**. Capture
    in the studio: the lineup room shows the realistic look the rows describe (not your Roblox avatar). Press
    **Backspace**: your Roblox avatar comes back (capture **`own_avatar_back`**). Open **Wardrobe** once more and
    select **Save look** without changing anything: you leave in the realistic look and the setting reads **Off**
    (capture **`own_avatar_saved`**). Also toggle the setting On and straight back Off within a second: it must end Off
    (body and row).
19. **`wardrobe`**: in SETTINGS select **Wardrobe**. The creator opens (no Skip row, subtitle "Wardrobe"). Change the
    hair, then press **Backspace**: you return to the street with the **old** hair. Capture **`wardrobe_cancelled`**.
19b. **`wardrobe_quick_back`** **[fix]**: note where you stand, open **Wardrobe** and press **Backspace** as soon as the
    room is up (well under a second). Expected: you are back on the same spot, alive, within about a second; you never
    fall from the sky or die. Capture **`wardrobe_quick_back`** 3 s later. Repeat it three times and report each.
20. **`aim_still_works`**: run `/hc weapon pistol`, press `1`, hold right mouse to aim and capture. The combat shoulder
    camera must work as before. Release; the camera should ease back to the on-foot camera (no snap). Press `0`.
21. **`car_cam`**: run `/hc spawn hot_hatch` and drive 3 s; capture (the chase cam has room to zoom out). Press `F` to
    exit and capture **`car_exit`** 1 s later (back to the on-foot camera, FOV restored).
22. Run `get_console_output` and save it as `console.txt`. Flag every error or warning that mentions
    AppearanceService, FootService, FootCamera, FootMovement, NameTags, CharacterCreator, ApplyDescription or
    HumanoidDescription. Stop Play.

## Touch pass [fix] (Studio device emulator, a phone in landscape)

Start a new Play with **Test → Device** set to a phone (landscape). Capture **`touch_unarmed`** on foot (a round
SPRINT button left of the jump button), then `/hc weapon pistol`, tap the weapon button to draw it and capture
**`touch_gun`**; press `5` on the keyboard (fists) or pick a bat if you own one and capture **`touch_melee`**. Expected:
whenever FIRE / HIT / STUN is on screen, SPRINT sits above it and never covers it. Tap SPRINT while walking: you sprint
until you stop or run dry.

## 2 players (only if Studio allows it)

Use **Test → Clients and Servers** with 2 players. On Player1, capture **`nametag_near`** with Player2 about 15 studs
away (a small white name above the head, no Roblox name / health bar), and **`nametag_far`** at about 50 studs (no
name). Then on Player1 run `/hc weapon pistol`, press `1`, and capture **`nametag_combat`** (no names while a gun is
drawn). **[fix]** Holster (`0`), reset Player1's character (Roblox menu → Reset Character), and once Player1 has
respawned capture **`nametag_after_respawn`** with Player2 about 15 studs away: the name must still be there. Skip
this section if the MCP cannot drive two clients, and say so.

## Snippets (Server, `execute_luau`)

**LINEUP** (the eight looks on `docs/v2/evidence/characters_lineup.jpg`, in order):

```lua
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local LookCodec = require(RS.Shared.Appearance.LookCodec)
local DescriptionSpec = require(RS.Shared.Appearance.DescriptionSpec)
local AS = require(game:GetService("ServerScriptService").Server.Systems.AppearanceService)
local KEYS = {
	"3.8.2.5.2.2.4.3", "10.6.9.2.3.1.3.1", "6.6.6.10.3.4.2.1", "12.10.7.12.1.3.1.1",
	"1.3.1.4.2.5.1.2", "9.2.8.1.3.3.3.1", "4.4.5.9.3.1.4.4", "11.1.10.3.1.5.2.1",
}
local p = Players:GetPlayers()[1]
local base = p.Character.HumanoidRootPart.CFrame * CFrame.new(-10.5, 0, -14)
local folder = workspace:FindFirstChild("C4aLineup") or Instance.new("Folder")
folder.Name = "C4aLineup"
folder.Parent = workspace
folder:ClearAllChildren()
for i, key in KEYS do
	local desc = AS.toDescription(DescriptionSpec.build(LookCodec.parseKey(key), 0))
	local m = Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R15)
	m.Name = "Look" .. i
	m:PivotTo(base * CFrame.new((i - 1) * 3, 0, 0) * CFrame.Angles(0, math.pi, 0))
	m.Parent = folder
end
```

Remove it afterwards with `workspace.C4aLineup:Destroy()`.

**DROP30** / **DROP80** (a 30-stud fall: about 9 m, ragdoll + damage; 80 studs: lethal):

```lua
local c = game:GetService("Players"):GetPlayers()[1].Character
c:PivotTo(c:GetPivot() + Vector3.new(0, 30, 0)) -- 80 for DROP80
```

**DROPWATER** (40 studs above the nearest open water within 60 studs; prints where it went or that none was found):

```lua
local c = game:GetService("Players"):GetPlayers()[1].Character
local at = c:GetPivot().Position
local best
for dx = -60, 60, 8 do
	for dz = -60, 60, 8 do
		local hit = workspace:Raycast(at + Vector3.new(dx, 40, dz), Vector3.new(0, -120, 0))
		if hit and hit.Material == Enum.Material.Water and (not best or Vector3.new(dx, 0, dz).Magnitude < best.Magnitude) then
			best = Vector3.new(dx, 0, dz)
		end
	end
end
if best then
	local hit = workspace:Raycast(at + best + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0))
	c:PivotTo(CFrame.new(hit.Position + Vector3.new(0, 40, 0)))
	print("DROPWATER over water at", hit.Position)
else
	print("DROPWATER: no open water within 60 studs; move to the shore and run it again")
end
```

## Report

For each shot: what you saw versus the expected text. Also: both stopwatch times (creator up; street after Skip), the
DataStore mode, whether the body was ever visible as a blocky default avatar (even for a frame), the HP after DROP30,
the HP before / after DROPWATER, the three quick-Back results, and the camera comparison with GTA V. Flag every
`[AppearanceService] ... missing garments / hair / shoes` warning in the console (a look that dropped a fallback
level). Never save or publish the place.
