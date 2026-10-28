# De-Robloxify audit (C4b polish)

**Goal (owner, binding):** nothing in the experience may read as "cartoonish standard Roblox". It should feel like stepping into GTA V. This file lists everything that still reads Roblox after Wave B, says why, names the GTA target and the owning package, and gives its status. The lead routes the open rows.

**How it was made.**
- A walk through the code on `v2/polish` (= `main` 0c80e93 + C4b), including scans for emoji, `!`, FredokaOne / Gotham, hot pink (255,52,140) / cyan (0,214,255), Neon, "studs" in player text, `Kit.pop` / Back easing, CoreGui and engine defaults.
- The real-engine evidence: `evidence/wave_b_0006_sheet.jpg` + report (Wave B playtest), `evidence/vibe_0018_sheet.jpg` + report + `vibe_0018_scan.txt` (v2 preview, place v33), `evidence/v1_real_engine/`.
- A read of the sibling branches as they stand today (`v2/vibe`, `v2/world`, `v2/vehicles`, `v2/loop`, `v2/loop-client`), so a row another package has already fixed is marked as such instead of routed twice.

**Status key.**
- **FIXED (C4b)**: fixed on `v2/polish` (this package).
- **FIXED (branch)**: fixed on another package's branch, not yet on `main`. Verify after the merge.
- **ROUTED**: open; the owner package is named. P0 = content safety or the first 10 seconds; P1 = in nearly every shot; P2 = seen often; P3 = polish.
- **LIMIT**: the platform does not allow it; what we do instead is stated.

**Owner packages.** polish (C4b), characters (C4a), world (A1, `v2/world`), buildings (A3), vehicles (A4), vibe (C5, `v2/vibe`), traffic (C2a), peds (C2b), audio (C3), loop (C1, `v2/loop` + `v2/loop-client`), look-night, props, cinematic (C6a), monetization (`tools/monetization`, the live Roblox catalog).

---

## 1. Platform chrome and engine defaults

| # | Item | Where | Why it reads Roblox | GTA target | Owner | Status |
|---|---|---|---|---|---|---|
| 1.1 | Player list, health bar, emotes menu, self view | CoreGui | Roblox chrome in the top-right | Our stars / cash own the top-right; players under Pause > STATS | polish | **FIXED (C4b)** `UI/CoreGuiSetup.DISABLED` |
| 1.2 | Backpack hotbar | CoreGui | The most "Roblox" bar on screen | Weapon wheel (Tab) | polish | **FIXED (C4b)** off once a wheel controller exists; VehicleClient also hides it while driving |
| 1.3 | Bubble chat (white speech balloons over heads) | `TextChatService.BubbleChatConfiguration` | Classic Roblox social look (VIBE row 17) | GTA Online keeps chat in the window | polish | **FIXED (C4b)** `CoreGuiSetup.BUBBLE.Enabled = false` (flat black style kept for a later opt-in) |
| 1.4 | Chat window top-left over the help text | `ChatWindowConfiguration` | Default position and style | GTA Online's spot: left-middle, Montserrat on black 45 % | polish | **FIXED (C4b)**; it also steps aside while a left-side menu is up (job 0006 bug 3) |
| 1.5 | Roblox top bar (menu, chat, captures) | engine | Platform chrome | No chrome | polish | **LIMIT**: the top bar can't be removed safely (gta_ui_language §8). Everything we draw sits under `CoreUISafeInsets`. |
| 1.6 | Esc opens the Roblox system menu, not the game pause | engine | A GTA player's first Esc lands in Roblox's menu (VIBE row 20) | Esc = pause / map | polish | **LIMIT + FIXED (C4b)**: Roblox reserves Esc. When that menu closes in the first 60 s, our pause menu opens on MAP. The first later close posts a help line naming **P** (pause) and **M** (map) (`CoreGuiSetup.escAction`). |
| 1.7 | ProximityPrompt bubbles: a grey rounded key circle with outlined white text, floating over every car, counter and pad | engine default prompt UI | One of the most recognisable Roblox UI elements, on screen through the whole core loop | GTA help text, top-left: "**Halden Wren** / Hold [E] to hotwire." A thin orange rule fills while a hold is in progress. Touch: flat black circle buttons in the right-hand cluster. | polish | **FIXED (C4b)** `UI/PromptStyle` (every prompt is switched to `Style = Custom`; input stays the engine's; one-line kill switch `PromptStyle.ENABLED`; any error falls back to the default prompts). The operator re-tests it in job 0017. |
| 1.8 | Overhead name tags on players ("Viewer", 100 studs) | `Humanoid.DisplayDistanceType` / `NameDisplayDistance` | Floating Roblox names (VIBE row 17) | No overhead names (the radar blip carries identity) | characters | **ROUTED P1**: set `DisplayDistanceType = None` on player humanoids (NPCs already use `None`, `NPCService.luau:863`) |
| 1.9 | "Reset character" in the Esc menu | `SetCore("ResetButtonCallback")` | GTA has no suicide button | Keep for stuck players, never as a bail dodge | polish | **FIXED (pre-existing)**: HUDController allows reset only at 0 stars |
| 1.10 | Default mouse cursor in menus (white Roblox arrow) | engine | Roblox cursor on GTA menus | A small flat cursor (or none: the menus are keyboard / pad first) | polish (follow-up) | **ROUTED P3**: needs a cursor image upload (`UserInputService.MouseIcon`); integrator-only upload |
| 1.11 | Touch thumbstick and jump button | engine TouchGui | Roblox mobile controls | GTA has no mobile port; keep and lay the HUD around them (§7) | polish | **LIMIT**: kept. All our touch buttons are placed clear of them (HudLayout, PromptStyle specs). |
| 1.12 | Roblox's own loading screen before ours | engine | Platform splash | Our black loading screen (logo bottom-left, tip, progress) | polish | **LIMIT**: `ReplicatedFirst` removes it as early as the engine allows (`src/first/LoadingScreen`), which job 0018 rated "clean, GTA-like" |

## 2. Characters, camera and feel

| # | Item | Where | Why it reads Roblox | GTA target | Owner | Status |
|---|---|---|---|---|---|---|
| 2.1 | The player's own blocky avatar (bacon hair, yellow skin, classic face) | `StarterPlayer.LoadCharacterAppearance = true` (`default.project.json`) | The #1 Roblox tell in every 0006 and 0018 shot | Realistic base bodies (bundles 988–995, plus 337/572/573/722), catalog clothing, the character creator | characters | **ROUTED P0** (C4a) |
| 2.2 | Cartoon police and pedestrians (blocky R15, 2D shirts, classic faces) | `NPCService` | Toy cops in the 0006 shots | Realistic bodies, uniforms (gta_assets §3.4), mocap walk packs | peds | **ROUTED P1** (C2b) |
| 2.3 | Default Roblox animations (walk, idle, jump, fall) | the engine's `Animate` script | Roblox gait | Realistic mocap packs (gta_assets §3.2) | characters | **ROUTED P1** |
| 2.4 | Default jump (JumpPower 50, floaty) and walk speed 18 | `default.project.json` StarterPlayer | Roblox bunny-hop | GTA's short, heavy jump; walk ≈ 5 studs/s, run ≈ 21 | characters | **ROUTED P2** |
| 2.5 | Default follow camera (FOV 70, max zoom 90) | engine camera | Roblox orbit cam | GTA foot camera (FOV 55–60, shoulder offset; gta_realism_gap §2.14) | characters (foot), cinematic (car cam) | **ROUTED P1** |
| 2.6 | Death: the body drops stiff, no ragdoll | `DamageService.luau:1143` (`BreakJointsOnDeath = false`) | Roblox "oof" fall (no gore is correct) | GTA ragdoll fall, then WASTED | characters / combat | **ROUTED P2** |
| 2.7 | Gravity 196.2 studs/s² (≈ 5.6 g at 0.28 m/stud) | `default.project.json` Workspace | Snappy, toy-like jumps and crashes | 120–140 with retuned suspension (gta_realism_gap §2.14) | vehicles | **ROUTED P2** (a driving-feel decision) |
| 2.8 | Default character sounds (cartoon jump, Roblox death sound) | engine `RbxCharacterSounds` | Roblox audio identity | Footsteps per surface, no jump "boing" | audio | **ROUTED P2**: replace `RbxCharacterSounds` (a LocalScript of that name in StarterPlayerScripts) |

## 3. World-space signs, boards and objects

| # | Item | Where | Why it reads Roblox | GTA target | Owner | Status |
|---|---|---|---|---|---|---|
| 3.1 | Leaderboards "💰 TOP EARNERS 💰" / "🚗 TOP THIEVES 🚗": navy / pink / cyan neon cards, FredokaOne, emoji medals, gradients | `LeaderboardService` | A simulator lobby board (0006, k04) | A matte black street billboard: thin orange rule, Oswald title, Montserrat names, "01–10", lit by the world | polish | **FIXED (C4b)** "RICH LIST" / "MOST WANTED". **Placement ROUTED P2 (world):** the v2 plaza (`World/Places.luau`, `plaza`) still puts both boards in the spawn sightline. Move them to a building facade (an LED screen) or off the spawn axis. |
| 3.2 | Pink / cyan spawn pad and plaza rings | v1 `MapBuilder.luau:130-131` | Neon tycoon spawn (0006) | A street spawn on a sidewalk | world | **FIXED (branch)** `v2/world` (MapBuilder v2 plaza: fountain, no pad). Verify in the merged preview. |
| 3.3 | "HOTWIRE MOTORS" neon dealership, pink canopy, cyan / pink turntable rings, "GOLD RUSH" posters | `DealershipService.luau:66` (`PINK`), `:377` FredokaOne | Kill-list pink neon (VIBE rows 6, 8) | A glass showroom with white tile, chrome and spot-lit cars | vibe | **ROUTED P1** (C5 in progress on `v2/vibe`) |
| 3.4 | Garage: pink neon trim, FredokaOne pad signs, emoji income tag "💰 $12/s 🚗1", laser gate, glowing collect pad | `PlotService.luau:69-71, :130` | Tycoon box (VIBE rows 2, 3, 5, 9, 18) | A dim concrete safehouse garage, roll-up door, stencilled bay numbers | vibe | **ROUTED P0** (spawn view; C5 has PlotService on `v2/vibe`, already on Oswald) |
| 3.5 | Garage pad text in the client: "🔒 LOCKED", "🔓 UNLOCK $X", "🚨 STOLEN!", "🚗 OUT", "💰 $X", "Step on the pad!", "STEP HERE TO COLLECT"; cyan "friendly laser" tint | `GarageClient.luau:48, :149-177, :486, :639-649, :738-790` | Emoji and shouting in world text | Plain condensed labels, no emoji, no "!" | vibe (task 96) | **FIXED (branch)** `v2/vibe` f97bc78 ("Being stolen", "Step into the marker", a ghosted shutter). The LOCK button is **FIXED (C4b)**: a flat GTA instruction bar (`_lockView`), no 🔒, no "LOCK NOW!", no pulsing (VIBE row 18). The two edits touch different lines. |
| 3.6 | Dealership pad boards "SOLD! 💸", "STOLEN! 🚨", "🔒 $X", "✨ GOLD ✨" | `DealershipClient.luau:215, :252, :436-459` | Emoji and shouting in world text | Plain labels | vibe (task 96) | **FIXED (branch)** `v2/vibe` (verify after the merge) |
| 3.7 | Hot drop beacon: a giant neon pillar with "🔥 HOT DROP" in FredokaOne | `EventService.luau:340-370` (`_buildBeacon`) | A neon simulator beacon | GTA crate drop: a low corona, chevron, road flares, red flare smoke | vibe | **FIXED (branch)** `v2/vibe` rebuilds `_buildBeacon` as a GTA marker. C4b changed only its text (no emoji, sentence case); see Integration. |
| 3.8 | Gun store counter fallback: a bare black block by the road | `ShopService.makeCounter` | Placeholder geometry (0006) | A real shop counter | vibe (C4b nit, handed over) | **FIXED (branch)** `v2/vibe` `ShopService.makeCounter`: steel cabinet, wood top, kick plate, register; plus Lock & Load storefronts on the POI shells (`Dressing/Civic`). C4b wrote a counter model too and **withdrew it** so the two branches never conflict on the same function. |
| 3.8b | Two names for one gun store: menu "Freedom Arms", prompt "FREEDOM ARMS", building "LOCK & LOAD" | `GunShopUI.STORE_NAME`, `ShopService` (GUNS.object), v2 CityArt | Inconsistent branding reads unfinished | One name, the one on the building | polish (menu) + vibe (prompt) | **FIXED (C4b + branch)**: the menu header reads "Lock & Load" (C4b); `v2/vibe` renames the prompt object and the "step up to a counter" error. Lead: gta_combat §5's provisional "FREEDOM ARMS" is retired. |
| 3.9 | GEAR SHOP sign in FredokaOne | v1 `MapBuilder.luau:90` | Cartoon font | Condensed printed signage | world | **FIXED (branch)** `v2/world` replaces v1 MapBuilder |
| 3.10 | **"Lucky Seven Casino" landmark** with a neon "LUCKY SEVEN" marquee | `v2/world`: `World/Places.luau:649-668`, `Config/WorldData.luau:33025` (`id = "Casino"`); `v2/vibe` only recolours it | **Content safety**: `CONTENT_SAFETY.md` rule 5 bans gambling imagery (casino, slots, dice). It was also hot-pink neon. | A non-gambling landmark (a hotel or theatre with a plain marquee and our own name) | world (+ vibe) | **ROUTED P0**: rename and re-sign it before any upload or publish; drop "casino" from the minimap labels too |
| 3.11 | Police helicopter "POLICE" door lettering in FredokaOne | `PoliceService.luau:1794` | Cartoon font on a police vehicle | Condensed livery lettering | traffic (police vehicles) | **ROUTED P2**: a one-line font swap |
| 3.12 | CarBuilder cartoon text decals in FredokaOne | `shared/Vehicle/CarBuilder.luau:469` | Cartoon font on cars | Real-looking badges and plates (parody brands only) | vehicles | **ROUTED P2** (v1 procedural fallback; CarBuilder v2 mounts uploaded models) |
| 3.13 | Floating rarity pills over street cars ("EPIC • Phantom GT • $260/s", coloured glow, pulsing) | `EffectsController.luau:156` (`tagText`), `:1131` (`styleTag`) | Simulator loot labels; GTA shows nothing over parked cars | No world tag. Show the car name and rarity in the prompt help text on approach (the hook exists now: PromptStyle's object line), or at most a small, unglowing label within ~25 studs | vibe (look) + loop (design) | **PARTLY FIXED (branch)**: `v2/vibe` turns the glowing pill into a dark label with a thin rarity underline and drops the "✨". **ROUTED P1 (loop):** whether a floating tag should exist at all is a loop design call (how players spot valuable cars). |
| 3.14 | Comic words over the world: "KAPOW!", "BONK!", "ZAP!", "POP!", "BIG STEAL!" | `EffectsController` (`showComic`) | Kid-simulator copy | Effects, flashes and sounds only; GTA never writes sound effects on screen | vibe | **FIXED (branch)** `v2/vibe` deletes the comic billboard system. C4b's own gate was withdrawn to keep `EffectsController` conflict-free. |
| 3.15 | Confetti and coin bursts on hot drops, steals, cash rain; pink / cyan confetti palette | `Config/VFX.luau:227-228`; `EffectsController` (`Confetti`, `BigSteal`) | Celebration effects of a simulator | Dust, a crash, a blip; money as a small "+$" | vibe | **FIXED (branch)** `v2/vibe`: "no confetti, no coins, no sparkle stars" (banknotes, dust, sparks). Verify that the server's `"Confetti"` effect name maps to a grounded effect after the merge; `Config/VFX` still lists the pink / cyan confetti colours (**ROUTED P3**). |
| 3.16 | Cartoon billboard ads ("COUCH CRUISER", "GOLD RUSH") | `MapDresser.adFor` | Cartoon art | Photographic parody ads (CityArt pack) | vibe | **ROUTED P1** (VIBE row 8) |
| 3.17 | Neon "DROP-OFF" arrows and chevrons, yellow neon drop-off edges | `PlotService.luau:1155`; client `TutorialController.luau:564`, `WaypointController.luau:400` | Neon guide geometry | A GTA corona marker plus the GPS line | vibe (world) | **ROUTED P2** |

## 4. Fantasy and meme content

| # | Item | Where | Why it reads Roblox | GTA target | Owner | Status |
|---|---|---|---|---|---|---|
| 4.1 | "MYTHIC Hover Car", Mini Tank, Rocket Car, Rubber Ducky, Couch Cruiser, Toilet Turbo, Hotdog Wagon, Ice Cream Truck, Bigfoot | `Config/Cars.luau` (main) | Meme and fantasy vehicles as main content (kill list) | Realistic parody cars | vehicles | **FIXED (branch)** `v2/vehicles`: the catalog is realistic (Halden, Tamura, Rossetti, Kronberg, Ashcombe, Velacor) and v1 ids resolve through `Config/CarAliases` |
| 4.2 | "Diamond Dragster" Exclusive product name | `Config/Monetization.luau` (`diamond_dragster`), `MonetizationService.luau:459-485`, `tools/monetization/spec.json` | A meme name; v2 calls the car "Ashcombe Vireo Diamante" | One name everywhere | monetization | **ROUTED P2**: rename the **live** product, the config name and the notify copy together after `v2/vehicles` lands. C4b did not change the config alone: the Roblox purchase prompt would then name a different car. |
| 4.3 | Rarity tier colours: pink Mythic, neon purple Epic, cyan Exclusive, black Secret; mutation paints in neon purple and ice cyan | `Config/Rarity.luau` | Simulator rarity palette | GTA HUD hues as small labels (Theme.Rarity), real paint finishes | vibe | **FIXED (branch)** `v2/vibe` (Rarity tiers = gta_ui_language §3 hues; muted mutation paints). The HUD side (Theme.Rarity) was already GTA. |
| 4.4 | Mutation names "RAINBOW", "GALAXY", "DIAMOND" (ForceField / Glass materials) | `Config/Rarity.luau` `Mutations` | Fantasy finishes | Real finishes (metallic, pearl, matte, chrome) | loop | **ROUTED P2**: retired at the LOOP_V2 M1 cutover (`v2/loop` `Config/Paint` is already grounded: "Arctic White", "Gunmetal", …) |
| 4.5 | Secret-tier cars written in hot pink in the event feed | `TheftService.luau:250, :1570` (255,80,210) | Pink in the feed | `Theme.Rarity.Secret` (#F0F0F0) like the HUD | loop | **ROUTED P3** |
| 4.6 | "Laser Lock" upgrade name | `Config/Economy.luau` | Sci-fi gadget | "Garage Lock" | polish | **FIXED (C4b)** (display name only; the id stays). **ROUTED P3 (loop):** the v2 catalog text still says "+15 s laser lock" (`v2/loop` `Config/Monetization` VIP effect, `Config/Upgrades`). |
| 4.7 | "Zapper Pass" | `Config/Monetization.luau` | Toy gadget | "Stun Gun Pass" (the Kessler Stun Gun) | polish | **FIXED (C4b)** (the pass is retired and hidden: id 0) |
| 4.8 | Cash Rain event (money bags fall on the plaza) | `EventService` | A simulator lobby event; GTA has nothing like it | Keep as a mechanic for now, presented quietly | loop | **ROUTED P3**: a design call. C4b made its copy quiet ("Cash rain at the plaza", no "GO GO GO!"). |
| 4.9 | "Stunt Park", "Spawn Plaza" map labels; pink stunt blip, cyan dealership and player blips | `Config/Minimap.luau:153-198` | Simulator place names and neon blips | GTA place names; GTA blip colours | world (Config/Minimap) | **ROUTED P3**. The client already overrides the POI colours (`MinimapController.poiColor`). |

## 5. Copy (the game's voice)

| # | Item | Where | Why it reads Roblox | GTA target | Owner | Status |
|---|---|---|---|---|---|---|
| 5.1 | "HOT DROP – CLAIM IT!", "🔥 HOT DROP INCOMING!", "💰 CASH RAIN! GO GO GO!", "🚦 RUSH HOUR!", "💸 2X CASH!", "🍀 SERVER LUCK" | `EventService` announce / feed / prompts | Kid-simulator shouting and emoji | Sentence case feed copy: "Hot drop", "Rush hour", "Double cash" | polish | **FIXED (C4b)** |
| 5.2 | Event pills (HOT DROP / RUSH HOUR / CASH RAIN) mid-screen over the crosshair | `EventsClient` | Simulator banners (0006, VIBE row 10) | Quiet rows at the feed position, a blip, a brief subtitle | polish | **FIXED (C4b)** |
| 5.3 | Emoji in server toasts and feed lines | TheftService (41 lines), RewardsService (21), DealershipService (16), PlotService (14), GarageService (11), MonetizationService (10), VehicleService (5), TrafficService, StreetSpawnService, AdminService (1 each) | Emoji are on the kill list | No emoji | loop (Theft, Rewards, Garage, Monetization, Data), vibe (Plot, Dealership), vehicles (Vehicle), traffic (Traffic, StreetSpawn) | **FIXED at display (pre-existing)**: everything the HUD shows passes through `Kit.sanitize` (`RichText.stripEmoji`). **ROUTED P2**: remove them at the source when each owner next touches the file. |
| 5.4 | "!" everywhere in server copy: TheftService (52 strings), DealershipService (20), RewardsService (16), GarageService (16), MonetizationService (11), PlotService (7), VehicleService (7), DataService, TrafficService, StreetSpawnService (2 each) | same | Simulator shouting | Calm sentences | same owners | **FIXED at display (C4b)**: toasts, the event feed and announcements pass through `RichText.calm` ("!" → "."; contact texts keep their voice). **ROUTED P2**: rewrite at the source. |
| 5.5 | ALL-CAPS toasts ("YOUR CAR IS BEING STOLEN", "YOU GOT THE HOT DROP") | TheftService, RewardsService, … | Shouting | Sentence case; caps only for sender names and menu headers | same owners | **ROUTED P2**: not safe to fix at display (player and car names) |
| 5.6 | "Fires two barbed probes up to 60 studs" | `Config/Economy.luau` (Tools.taser) | "studs" is Roblox's unit | Metres (the HUD never says studs) | polish | **FIXED (C4b)** "up to 17 metres" |
| 5.7 | "419 studs away" on the hot drop pill | `EventsClient` | Roblox unit | "120 m" | polish | **FIXED (C4b)** `EventsClient.distanceText` |
| 5.8 | Loading tips: "Lock your garage with the laser gate", "Follow the gold marker", "Hold the HOTWIRE prompt" | `src/first/LoadingScreen.client.luau` | v1 objects that are leaving | Current objects | polish | **FIXED (C4b)** |
| 5.9 | Tutorial help text stuck on screen for the whole session | `TutorialController` | A tutorial card that never leaves (0006) | GTA help: ~8 s, re-shown only for a new hint | polish | **FIXED (C4b)** |
| 5.10 | WASTED / BUSTED without the black band; WASTED without a subtitle | `UI/Shard`, `DeathScreenController` | Not the GTA shard (0006 bug 2) | The 19.5 % band at 48.8 % H, a subtitle, bail / bill in red | polish | **FIXED (C4b)** |
| 5.11 | "thank you!" and emoji pass icons ("👑", "🅿️", "🔥", "🍀", "💎") | `Config/Monetization.luau` `icon`, `MonetizationService.luau:728` | Emoji | No icon glyphs | loop (WP9 switches to the v2 catalog, which has no icons) | **FIXED at display** (stripped by `Kit.sanitize`; never drawn as glyphs: the store rows don't render `icon`). **ROUTED P3**: drop the field at the cutover. |
| 5.12 | "[VIP]" chat prefix | `HUDController` (`vipChatPrefix`) | A Roblox status tag in chat | GTA Online has none (crew tags only) | loop | **ROUTED P3**: a monetization perk decision |

## 6. Sound

| # | Item | Where | Why it reads Roblox | GTA target | Owner | Status |
|---|---|---|---|---|---|---|
| 6.1 | Air horn / car horn / cash fanfare on every server event announcement | `EventService` announce(…, "AirHorn" / "Horn" / "CashDrop" / "CashBig") | Simulator stingers | The feed's single quiet blip | polish (client) + audio | **FIXED (C4b) on the client**: `NotificationController.announceSound` plays "Notify" for any announcement. **ROUTED P3 (audio):** remove the names at the source. |
| 6.2 | Cartoon SFX: `Bonk`, `Zap` (a pitched explosion), `Poof`, `Coin` | `Config/Sounds.luau:62-67` | Cartoon sound design | Real impacts, a taser crackle, no coins | audio | **ROUTED P2** (C3) |
| 6.3 | Confetti / coin bursts' sounds on hot drops | `EventService` (`Confetti`, `CashBurst`) | Festive | Crash, dust, siren in the distance | vibe + audio | **ROUTED P3** |

## 7. Physics and feel (summary; details in gta_realism_gap)

| # | Item | Owner | Status |
|---|---|---|---|
| 7.1 | Arcade raycast chassis: kept as the invisible rig under realistic bodies (PLAN decision 5); needs body roll, weight transfer and crash feedback to read GTA | vehicles | **ROUTED P2** |
| 7.2 | Ambient traffic and pedestrians missing on v2 streets (the city reads empty) | traffic, peds | **ROUTED P1** (VIBE row 7) |
| 7.3 | Juice animations: `Kit.pop` on the optional speed readout (nitro, damage) and the touch NITRO / HORN / RADIO buttons | `VehicleClient.luau:1186, 1275, 1286, 1671, 1768, 1797` | polish | **ROUTED P3 (polish follow-up)**: harmless; the readout is off by default (GTA has no speedometer). Left alone so the cinematic / vehicles merges into VehicleClient stay clean. |

---

## What C4b changed for this audit (all on `v2/polish`)

- **CoreGui:** `UI/CoreGuiSetup` (rows 1.1–1.6).
- **Prompts:** `UI/PromptStyle` + `HelpText` hold rule + `HUDController.helpProgress` (row 1.7).
- **Leaderboards:** `LeaderboardService` restyle (row 3.1).
- **Lock bar:** `GarageClient._lockView` (row 3.5, the button only).
- **One gun-store name:** `GunShopUI.STORE_NAME = "Lock & Load"` (row 3.8b).
- **Copy:**
  - `ShopService` purchase toasts (no "!", "level" instead of "Lv.", no ⬆️);
  - `EventService` feed and announce copy (5.1);
  - `EventsClient` rows (5.2, 5.7);
  - `RichText.calm` in `NotificationController` (5.4);
  - Economy / Monetization display names (4.6, 4.7, 5.6);
  - loading tips (5.8);
  - tutorial help timing (5.9);
  - the shard (5.10).
- **Sound:** `NotificationController.announceSound` (6.1).
- **Specs:** `tests/spec/polish.spec.luau`.

## Not Roblox-y any more (protect)

- The HUD: square radar, thin bars, white cash, help box, feed and location lines.
- The pause MAP, the weapon wheel, the loading screen, the GTA list menus.
- The shard band, now that it is always drawn.

All of these are verified in jobs 0006 and 0018; keep them as they are.
