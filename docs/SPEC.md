# Hotwire City — Game & Engineering Spec (v1)

> **Pitch:** *Steal cars. Outrun the cops. Stack cash.* An open-world cartoon car-heist game. Every car you steal has to be **driven home** while police (and other players) chase you down. Parked cars in your garage print money every second. Rare cars, mutations, server-wide Hot Drops, and other players' garages full of loot keep you hooked.

This document is the **contract** every system is built against. If code and spec disagree, fix one of them in the same change.

---

## 1. Design pillars

1. **Every steal is a getaway.** The Steal-a-Brainrot collect loop, except you *drive* the loot home through a chase. This is the differentiator.
2. **Driving must feel amazing.** Arcade physics: instant acceleration, big drifts, nitro, ramps, no flipping-and-stuck. If driving is not fun nothing else matters.
3. **Moments worth clipping.** Hot Drops, a 5-star chase, a mythic car rolling past in traffic, getting your Secret car stolen 2 meters from your door, revenge.
4. **Mild-rated cartoon crime.** No blood, no death, no realistic guns. Bonk Bat, Zapper, Spike Strips. Getting caught = **BUSTED → impound**.
5. **Fair theft.** Offline garages can't be robbed, newbies (<3 cars) can't be robbed, victims get a 25s cooldown, timed laser lock, victims get alarms + revenge bonuses, and a dropped car is never deleted — it goes home.
6. **Mobile first.** Big buttons, auto-accelerate option, no reading required, icons over text.
7. **28-day retention.** Offline earnings, daily streak, daily contracts, playtime gifts, Car Index completion bonuses, rebirths.

## 2. Core loop (first 60 seconds)

1. Spawn **inside your own garage** with a free **Rustbucket** already earning $3/s. Collect pad glows.
2. Tutorial arrow → nearest street car. Hold **E** to hotwire (0.8s). First steal: no wanted level.
3. Arrow → your garage. Drive into the **DROP-OFF** zone → car is parked in a slot, income goes up, confetti.
4. Step on **COLLECT** → cash. Arrow → Dealership / upgrades. Rare cars visible in traffic with rarity tags.
5. From here: steal better cars (wanted stars rise with rarity), buy from the Dealership, raid other garages, defend yours, claim Hot Drops, rebirth.

## 3. World (see `Config/Map.luau` + `Util/MapLayout.luau`)

- Island city, square grid: road centerlines every **160** studs from **-800..800** on both axes; roads **40** wide (one lane each direction, lane center **8** studs right of centerline; right-hand traffic). Blocks are raised **0.6** (curb).
- **8 garage plots** on the outer ring of blocks, each facing the inner road. Plot-local frame: `MapLayout.plotOrigin(i)`; local **-Z** is out the front door.
- **POIs** (block coordinates in `Config/Map.Blocks`): Spawn Plaza, Dealership, Police HQ, Gear Shop, 2× Spray Shop, Chop Shop, Stunt Park, Park, Pier. Downtown skyscrapers near center. Sand beach ring 820–900, ocean beyond, invisible walls at 960.
- Max players per server = **8** (one per plot). Set in Game Settings when publishing.

### Workspace layout (created at runtime)

| Path | Created by | Contents |
|---|---|---|
| `Workspace.Map` | MapBuilder | static city (roads, blocks, buildings, props, POI buildings) |
| `Workspace.Plots.Plot<i>` | PlotService | garage building i (Model) + `Display` folder of parked display cars |
| `Workspace.Vehicles` | VehicleService | every drivable car model (player, stolen, street, traffic, police, hot drop) |
| `Workspace.Dealership` | DealershipService | showroom display cars |
| `Workspace.Effects` | anyone (server) | transient server effects (spike strips, beacons, cash bags) |

`Workspace.StreamingEnabled = false` (v1, 8-player servers; revisit with Atomic car models if mobile memory is an issue). `Workspace.SignalBehavior = Deferred` (Roblox's default for new places — event handlers run deferred; never assume an instance still exists inside a handler without checking `.Parent`). Map budget: **≤ 9,000 parts**. Use few large parts; neon window strips not per-window parts.

## 4. Architecture

Rojo layout:

```
src/shared  -> ReplicatedStorage.Shared        (Config/*, Util/*, Vehicle/*, Net, Remotes, Types)
src/server  -> ServerScriptService.Server       (init.server.luau + Systems/*)
src/client  -> StarterPlayerScripts.Client      (init.client.luau + Controllers/* + UI/*)
src/first   -> ReplicatedFirst.Loading          (LoadingScreen.client.luau)
```

- **Exactly one Script and one LocalScript**, plus the ReplicatedFirst loading screen (ReplicatedFirst needs its own LocalScript). Everything else is a ModuleScript returning a table with optional `init()` and `start()`.
- Boot order is the `ORDER` list in each entry point. `init()` must not yield (except MapBuilder which may take ~1s); long loops go in `start()` (each runs in its own thread). `PlayerAdded` handling goes in `start()` **and must also loop over `Players:GetPlayers()`** for players who joined before start ran.
- Systems talk via **direct `require` + public functions + Signals** (`Shared/Util/Signal`). To avoid require cycles, a system that needs a "later" system calls it lazily: `local GarageService = require(script.Parent.GarageService)` *inside the function body*, never at the module top, when the dependency points "backwards" in ORDER. The dependency table in §6 marks which edges are lazy.
- Remotes are declared only in `Shared/Remotes.luau` and used only through `Shared/Net.luau`. Every client→server handler validates **every** argument (`Net.isInt`, `Net.isString`, `typeof`), re-derives everything from server state, and never trusts client-claimed prices, positions, or ownership.
- Use `--!strict` at the top of every file. Prefer clarity over clever types; when the type checker would fight you, use `any` locally rather than writing wrong code.
- **No external packages**. Standard Roblox services only.
- Clean up per-player state on `PlayerRemoving`; per-car state when a car is destroyed (use `Shared/Util/Trove`).
- No `wait()`, `spawn()`, `delay()` (use `task.*`). No `BodyVelocity/BodyGyro/BodyPosition` (use `LinearVelocity`, `AlignPosition`, `AlignOrientation`, `VectorForce`, `ApplyImpulse`).

## 5. Data model

`Types.PlayerData` (persisted, DataStore `HotwireCity_v1`, key `p_<userId>`), `Types.Snapshot` (sent to owning client on any change, debounced 0.1s). Garage slots are keyed by **string** slot number (`"1"`..`"12"`) to keep JSON non-sparse.

Defaults for a new player: cash `Economy.STARTING_CASH`, `slotsUnlocked = Economy.START_SLOTS`, `garage = { ["1"] = { carId = Economy.STARTER_CAR, mutation = "None", uncollected = 0 } }`, discovered = { starter = true }, upgrades all 0, tools `{ bat = true }`, settings `{ music = true, sfx = true, hideHud = false, autoAccelerate = false }`, contracts `{ day = 0, list = {} }`.

**Player attributes** (server sets, clients read for cheap HUD updates): `Cash` (number), `Wanted` (0-5), `IncomePerSec` (number), `Rebirths` (number), `PlotIndex` (number), `Driving` (bool), `Stunned` (bool).

## 6. Server systems — public APIs

Each system lives in `src/server/Systems/<Name>.luau`. Only the functions/signals listed are public; everything else is local. "(lazy)" = require inside the function to avoid cycles.

### MapBuilder
- `init()` builds `Workspace.Map` synchronously from `Config/Map` + `MapLayout`: ground/base slab, asphalt roads + lane markings + crosswalks, raised blocks with sidewalks, buildings (downtown skyscrapers, mid-rise, shops, houses near edges), street lights (PointLight, only every other one has a light for perf), palm trees, beach + Terrain water (`Workspace.Terrain:FillBlock`), boundary walls (invisible, `CanCollide=true`), Stunt Park (ramps, a half-pipe, a big jump over a pool), POI buildings with signs (Dealership showroom floor + roof + 8 pad markings at `MapLayout.dealerPads()`, Police HQ, Gear Shop with counter part at `MapLayout.gearShopCounter()`, Spray Shops around `MapLayout.sprayZones()`, Chop Shop around `MapLayout.chopZone()`), spawn plaza with fountain + `SpawnLocation` at `MapLayout.spawnCFrame()`, 2 leaderboard boards at the plaza (Parts tagged `LeaderboardBoard` with attribute `Stat` = `"totalEarned"` / `"steals"`).
- Plot blocks are left **empty** (flat lot) — PlotService builds garages.
- Everything anchored. Road parts tagged `Road`. Use `Enum.Material` + color for style; SurfaceGui text for signs.
- `MapBuilder.getMapFolder(): Folder`

### LightingService
- Sets Lighting (Future, Atmosphere, Sky, Bloom, ColorCorrection, SunRays), runs a day/night cycle (12 min day, 4 min night; dusk/dawn quick). Street lights' `PointLight.Enabled` toggled at night (server, by tag `StreetLight`). Exposes `isNight(): boolean`, `NightChanged: Signal(isNight)`.

### DataService
- Session-locked UpdateAsync load with retries + backoff, autosave every 120s, save on leave, `game:BindToClose` flush, schema `version` + migration function, Studio fallback (if API access disabled → in-memory data + one warning).
- Remotes `SetSetting(key, value)` (only keys in `Types.Settings`, boolean values) and `TutorialDone()`.
- `get(player): PlayerData?` (live table, mutate only on server), `isLoaded(player): boolean`, `waitFor(player, timeout?): PlayerData?`
- `addCash(player, amount, reason: string)` (also adds to `totalEarned` when amount > 0), `spendCash(player, amount): boolean`
- `markDirty(player)` → debounced snapshot push (calls `buildSnapshot`) + save flag.
- `buildSnapshot(player): Snapshot` — asks GarageService (lazy) for slot states/income, MonetizationService for passes, RewardsService (lazy) for daily/playtime/contracts view.
- `saveNow(player)` (used after theft transfers).
- Signals: `Loaded(player, data)`, `Releasing(player, data)`.
- Remote: `GetSnapshot` handler.

### MonetizationService
- Gamepass ownership cache (`UserOwnsGamePassAsync` with pcall on join + `PromptGamePassPurchaseFinished`), `hasPass(player, key): boolean` (false for id 0), `PassChanged: Signal(player, key)`.
- Single `MarketplaceService.ProcessReceipt`; idempotent via `data.receipts` (keep last 50); returns `NotProcessedYet` if data not loaded. `registerProduct(key, handler: (player) -> boolean)`. Built-in handlers: `cash_small`, `cash_big` (income-scaled, min amounts), `lock_10` (PlotService lazy), `clear_wanted` (WantedService lazy), `server_luck` (EventService lazy), `diamond_dragster` (GarageService lazy; grants exclusive car; if garage full, stores in `exclusives` and grants when a slot frees — simplest: always allowed to exceed? No: grant into first free slot, else keep in `exclusives` and show notify).
- `productIdFor(key)`, `passIdFor(key)` helpers.

### PlotService
- `init()` builds all 8 garage buildings (`Workspace.Plots.Plot<i>`): floor, walls with a front door opening, roof with skylights, neon trim, owner sign (SurfaceGui/BillboardGui) at `Garage.SIGN`, slot pads at `MapLayout.slotLocal(1..12)` (Part named `Pad<i>` with SurfaceGui showing slot number / lock price), **DROP-OFF** zone floor marking + invisible non-collide region part `Dropoff`, **COLLECT** pad (`CollectPad`, neon green, Touched), **LOCK** button pad (`LockButton`, red), laser gate part `Gate` across the door (CanCollide=false, Transparency=1 when unlocked; red neon + CanCollide=true when locked), a `Display` folder.
- Assigns a free plot on join (sets attribute `PlotIndex`, sign text "<DisplayName>'s Garage"), frees it on leave. Moves the character to `Garage.OWNER_SPAWN` on every `CharacterAdded`.
- `GoHome` remote: on foot, not wanted, not stunned, 20s cooldown → pivot character to `OWNER_SPAWN`.
- Lock: owner steps on LockButton or fires `LockGarage` remote while inside their own garage → locked for `upgradeValue("lock", level)` seconds (lockdown product → 600s). Gate shows countdown (SurfaceGui). While locked, non-owners inside the interior are pushed out (character pivoted to the driveway outside the door) every 0.5s. The **owner** passes through because GarageClient sets the gate `CanCollide=false` locally for the owner.
- `getPlot(player): PlotInfo?`, `getPlotIndex(player): number?`, `getOwner(index): Player?`, `isLocked(index): boolean`, `lockFor(index, seconds)`, `plotAt(position): number?` (wraps MapLayout), `getPlotModel(index): Model?`, `getDisplayFolder(index): Folder?`
- Signals: `PlotAssigned(player, index)`, `PlotReleased(player, index)`.

### VehicleService (core of driving)
- Owns every drivable car. `spawn(carId, mutation, groundCFrame, kind, opts?) -> Car` builds via `CarBuilder.build`, positions so wheels rest on the ground at `groundCFrame` (`model:PivotTo(groundCFrame * CFrame.new(0, model:GetAttribute("RideHeight") + 0.3, 0))`), parents to `Workspace.Vehicles`, tags `Vehicle`, sets attributes (`VehicleId`, `CarId`, `Mutation`, `Kind`, `Rarity`, `OwnerUserId`, `Health`).
- `type Car = { id: number, model: Model, chassis: BasePart, seat: VehicleSeat, carId: string, mutation: MutationId, kind: VehicleKind, ownerUserId: number?, driver: Player?, health: number, lastDriverAt: number, data: {[string]: any} }` (`data` = per-system scratch: e.g. `data.theft`, `data.slot`).
- **Parked & Dealership & HotDrop** cars are anchored (`chassis.Anchored = true`) until stolen. Traffic cars are server-driven (see TrafficService) until carjacked.
- `addStealPrompt(car, opts: { actionText, holdDuration, objectText?, canSteal: (player) -> (boolean, string?), onStolen: (player) -> () })` — one `ProximityPrompt` in the chassis (`RequiresLineOfSight=false`, `MaxActivationDistance=12`). Hold duration is pre-multiplied by the player's hotwire upgrade and Master Thief pass **server-side in `onStolen` validation**: because hold duration is per-prompt (shared), VehicleService keeps the base duration on the prompt and **clients locally scale `HoldDuration`** for display; the server records `PromptButtonHoldBegan` time per player and rejects `Triggered` if `now - began < required * 0.9`.
- Seats are `Disabled=true` by default (no touch-to-sit, ever). `seat(car, player)` — unanchors, `seat.Disabled=false`, `chassis:SetNetworkOwner(player)`, `seat:Sit(humanoid)`, attributes `DriverUserId`, player attribute `Driving=true`. On Occupant → nil: `seat.Disabled=true`, `SetNetworkOwner(nil)` (server simulates it settling), and after `PARK_ANCHOR_AFTER` seconds at rest the chassis is anchored.
- `eject(car)` — destroys the seat's `SeatWeld` (server-authoritative exit), nudges the character out to the side.
- Detects driver enter/exit via `seat:GetPropertyChangedSignal("Occupant")`. Rejects anyone sitting who is not allowed (for Owned cars: owner only; Stolen: the thief or the victim (recovery); Police: nobody) by ejecting.
- Abandon rules (checked every 1s): Owned car without driver for `OWNED_RETURN_AFTER` → `ReturnedHome` (GarageService restores slot). Loot car without driver for `ABANDON_DESPAWN` and no player within `NEAR_PLAYER_RADIUS` → destroy. Stolen cars → TheftService handles (signal).
- **Zones** (checked every 0.2s for each driven car using MapLayout boxes): driver's **own** plot drop-off → `DeliveryAttempt:Fire(player, car)`; chop zone → `ChopAttempt:Fire(player, car)`; spray zones → `SprayAttempt:Fire(player, car)`.
- Damage: every 0.1s per driven car sample `AssemblyLinearVelocity`; sudden drop greater than `CRASH_DAMAGE_THRESHOLD` → damage scaled by armor upgrade. Health 0 → `wreck(car)`: cartoon smoke puff + `Effect("CarWreck")`, eject, destroy after 2s. `damage(car, amount, sourcePlayer?)`.
- `get(id)`, `fromModel(model)`, `getDriving(player): Car?`, `destroy(car, reason)`, `all(): {Car}`
- Signals: `Spawned(car)`, `DriverChanged(car, newDriver: Player?, oldDriver: Player?)`, `Destroyed(car, reason)`, `DeliveryAttempt(player, car)`, `ChopAttempt(player, car)`, `SprayAttempt(player, car)`, `ReturnedHome(car)`, `Stolen(player, car, previousKind)`.
- Anti-cheat watchdog every 0.5s per player-driven car: horizontal speed ≤ `topSpeed × SPEED_CAP_MULT × NITRO_SPEED_MULT × SPEED_CAP_GRACE`, displacement since last tick ≤ `cap × dt + WATCHDOG_TELEPORT_SLACK`. On violation: `SetNetworkOwner(nil)` for `WATCHDOG_REVOKE_SECONDS`, `PivotTo` last valid CFrame, zero velocity, then give ownership back. Lag-tolerant; log, never kick.

### GarageService
- Income tick every `Economy.INCOME_TICK`: for each loaded player, each `Parked` slot accrues `carIncome * playerMultiplier` into `slot.uncollected`. Updates `IncomePerSec` attribute. Snapshot at most every 1s from the tick (cheap).
- Display: for each occupied slot in `Parked` state, builds a display car (`CarBuilder.build`, anchored, `CanCollide` true for chassis only) at `MapLayout.slotWorld(plot, slot)` in the plot's `Display` folder, tag `DisplayCar`, attributes `PlotIndex`, `Slot`, `CarId`, `Mutation`, `OwnerUserId`. BillboardGui above it: name, rarity color, mutation label, `$X/s`, uncollected `$Y` (updated each tick via attribute `Uncollected` that the client billboard reads — the billboard text is built client-side by GarageClient).
- Prompts on each display car: `DrivePrompt` ("Drive", owner), `SellPrompt` ("Sell $X", owner, KeyCode F, hold 1s), `StealPrompt` ("Steal", others; HoldDuration = rarity hotwireTime × THEFT_HOLD_MULTIPLIER). GarageClient hides prompts that don't apply locally; **the server re-checks**.
- Collect pad touched by the owner → sum all `uncollected`, `addCash`, CashPopup, sound, contract stat `collectCash`.
- `storeCar(player, carId, mutation): (boolean, number|string)` (slot index or reason "full"), `freeSlots(player): number`, `ownedCount(player): number`, `removeSlot(player, slot): SlotRecord?`, `setSlotState(player, slot, state)`, `getSlotState(player, slot)`, `restoreSlot(player, slot)` (→ Parked + display), `refresh(player)`, `incomePerSec(player): number`, `multiplier(player): number`, `slotSnapshots(player): {[string]: SlotSnapshot}`.
- Remotes: `UnlockSlot`, `SellCar(slot)`, `DriveCar(slot)` (spawns Owned car at `DRIVE_OUT_SPAWN` via VehicleService, sets slot `Driving`, seats owner).
- Handles `VehicleService.DeliveryAttempt`: Owned car → back to its slot (Parked). Loot/HotDrop-claimed/dealer-stolen → `storeCar` (if full: Notify "Garage full! Sell a car or chop it at the Chop Shop" and do nothing); success → destroy car, discover, stats `steals += 1`, contracts, confetti `Effect`, `EventFeed` for Epic+. Stolen → `TheftService.complete(car)` (lazy).
- Handles `ChopAttempt`: only Loot cars (not Owned, not Stolen-from-player) → cash `chopValue`, destroy, contract `chop`.
- Handles `VehicleService.ReturnedHome`.

### TheftService (player → player)
- `beginTheft(thief, victim, slot)` from the display car's `StealPrompt`. Validates: victim online & loaded, victim plot not locked, thief ≠ victim, thief has a free slot, victim has ≥ `NEWBIE_PROTECTION_CARS` cars, car `stealable`, victim not in theft cooldown, thief inside victim's garage interior, thief not already driving. Then: slot → `BeingStolen` (display removed), spawn car kind `Stolen` at the slot pad facing the aisle, `car.data.theft = { victim, slot, carId, mutation, startedAt, thief }`, seat thief, Wanted `+playerTheft`, `CarStolenAlert` to victim (active=true), `TheftState` to thief, `Waypoint` home for thief, EventFeed "🚨 X is stealing Y's <car>!", victim cooldown starts.
- Drop: if the thief leaves the seat (ejected by bat/zapper, exits, dies, busted), the car stays in place as **dropped** for `DROPPED_CAR_TIMEOUT`: the **victim** gets a `Recover` prompt (instant: returns car home, bonus `RECOVERY_BONUS_SECONDS` of income); **other players** (not the victim) get a short Hotwire prompt to take over the theft (they become the thief). Timeout → returns home.
- `complete(car)` (on thief's delivery): atomically remove victim slot, add to thief (`storeCar`), victim keeps its uncollected cash (paid out to victim), stats, `saveNow` both, EventFeed "💰 X stole Y's <car>!", alerts off, victim gets `Waypoint` cleared.
- `fail(car, reason)` returns car home (restoreSlot) and clears UI. Triggered by: time limit, victim leaving (car vanishes, thief notified), car wrecked, thief leaving the server.
- `isBeingStolen(victim, slot)`, `getActiveTheft(thief)`.
- Revenge: CombatService calls `TheftService.onThiefHit(attacker, thief)`; if attacker is the victim of that theft → `REVENGE_BONUS_SECONDS` of income + Notify "REVENGE!".

### DealershipService
- 8 showroom pads (`MapLayout.dealerPads()`); restock all every 240s (+ a single sold pad restocks after 30s). Rolls with `Rolls.car("dealer", luck)` + `Rolls.mutation(1)`; luck from `EventService.getLuck()` (lazy).
- Display cars: anchored, parented `Workspace.Dealership`, attributes as GarageService display + `Price`, tag `DealerCar`. Client spins turntables (DealershipClient).
- Prompts: `BuyPrompt` ("Buy $X", hold 0.5) → spend + `storeCar` (refund if storeCar fails), Notify, discover, contract `dealerBuy`; `StealPrompt` ("Steal", hold = hotwireTime × DEALER_STEAL_HOLD_MULTIPLIER) → convert to a Loot car via VehicleService (spawn drivable at pad, seat thief), wanted +`dealerSteal` (2★).
- Announce Mythic/Secret stock to everyone (`Announce` + `EventFeed`). Restock board countdown (SurfaceGui on a sign part in the showroom).

### StreetSpawnService
- Keeps ~40 parked cars (scaled by player count: 24 + 2 per player, max 44) on random free `MapLayout.parkingSpots()` (spot is free if no car within 12 studs). Kind `Parked`, anchored, rarity rolled with `Rolls.car("street", luck)` and `Rolls.mutation(1)`.
- Steal prompt: "Hotwire", hold = rarity hotwireTime. On steal: kind → `Loot`, unanchor, seat player, wanted + `rarity.wantedOnSteal` (except first-ever steal: 0), announce Legendary+ in EventFeed. Rarity tag BillboardGui on Rare+ (built client-side by EffectsController from attributes).
- **Guarantee**: within 15s of a player's first join (tutorial not done), ensure a Common parked car exists within ~120 studs of their garage door.

### TrafficService
- ~18 AI cars (+50% during Rush Hour) driving lanes using `MapLayout.laneCFrame`. Movement: chassis **unanchored**, server network owner, `AlignPosition` + `AlignOrientation` (attachment mode, MaxForce/MaxTorque high, Responsiveness ~25) targeting a point advanced along the lane at 30–45 studs/s; turn randomly at intersections (left/right/straight; never U-turn; smooth by targeting the intersection center then the new lane). Stop if another car is within 14 studs ahead in the same lane (simple spacing). NPC driver dummy (simple R6-ish block figure) in the driver seat visual.
- Carjack prompt "Carjack" (hold = rarity hotwireTime × 0.9): remove align constraints, NPC flies out (comic ragdoll, removed after 3s), kind → `Loot`, seat player, wanted + `Heat.carjack` (1★).
- If a player car rams a traffic car hard, release that traffic car to physics (kind `Parked`-like abandoned loot, despawns per abandon rules).
- Despawn & respawn traffic far from all players to keep density near players (spawn on lanes 150–450 studs from a random player).

### WantedService
- Stars 0–5 per player (attribute `Wanted`). `addHeat(player, stars, reason)`, `getStars(player)`, `clear(player, reason)`, `bust(player)`. Decay per `Config/Police` (timer reset while any police unit is within SIGHT_RANGE).
- Spray: on `VehicleService.SprayAttempt` with stars > 0 → charge `SPRAY_COST_PER_STAR × stars` (if affordable; else Notify), clear, repaint car random color (client sees), repair health. Contract `escape` / `escape3` when stars drop to 0 by decay or spray (track peak stars of the chase).
- Busted: lose `min(cash × 10%, income × 600s)`, eject, if driving a Stolen car → TheftService.fail (lazy); Loot car destroyed; teleport to `MapLayout.bustedReleaseCFrame()`; `Busted` remote; stats; stars cleared.
- Signals: `Changed(player, stars, old)`, `Busted(player)`.

### PoliceService
- Spawns police units (`CarBuilder` style `police` via `VehicleService.spawn(..., "Police")` using `Cars.Police`) at `MapLayout.policeSpawns()` or `MapLayout.nearestLane` ~200 studs from the suspect, count by `UNITS_PER_STAR`, capped globally. Units drive with `VehicleController` **on the server** (network owner nil) with AI input. **Routing on the grid**: if the suspect is within 150 studs with line of sight → pure pursuit to `targetPos + targetVel × clamp(dist/60, 0.3, 1.5)`; otherwise drive lane-to-lane via intersections (Manhattan route: follow the current road to the intersection that reduces distance, turn, repeat) so cops don't plough into buildings. Controls: `steer = clamp(signedYawAngle/35°, -1, 1)`, throttle 1, brake when |angle| > 70° and speed > 40, unstuck: speed < 3 for 2s → reverse with opposite steer for 1.2s. Siren lights flash client-side (EffectsController, by tag `Police`).
- Bust check every 0.25s: suspect within BUST_RADIUS of a unit and (on foot, or car speed < BUST_SPEED) accumulates time; ≥ BUST_TIME → `WantedService.bust`. Leaving the radius decays the timer. Busted progress is sent to the suspect via player attribute `BustProgress` (0..1) for a HUD ring.
- 4+ stars: helicopter (anchored model moved smoothly via `AlignPosition` above the suspect with a spotlight `SpotLight` + beam), purely visual + keeps "seen".
- Despawn all units of a suspect when stars → 0 (drive away / fade). Units that fall far behind teleport closer (`RESPAWN_IF_FARTHER`).
- Ramming a police car: `copHit` heat (rate-limited).

### CombatService
- Tools are `Tool` instances created on the server into the player's Backpack on spawn for each owned tool (`data.tools`), handle part built from parts (no meshes). Activation is detected **client-side** and sent as `ToolAction(toolId, aim)`; server validates ownership, equipped, cooldown (pass `taser` halves Zapper cooldown), range (`BAT_RANGE` from root to target root, `TASER_RANGE` along aim ray with server raycast), not stunned.
- **Bonk Bat**: hits nearest player in a 9-stud cone → `Knockback` remote to victim (victim client applies velocity + `PlatformStand` stun), if victim is driving → `VehicleService.eject`. Stun `BAT_STUN`.
- **Zapper**: server raycast along aim (from character head) → first player hit → stun `TASER_STUN`, eject from car, `Effect("Zap", {from, to})` lightning beam for everyone.
- **Spike Strip**: drops a strip part behind the player's car (must be driving) in `Workspace.Effects`; any other car whose chassis touches it gets attribute `TiresPopped = os.clock()+SPIKES_POP_TIME` (VehicleController reads → top speed × `SPIKES_SLOW`). Removed after `SPIKES_DURATION`.
- Assault heat: hitting a player outside your own garage adds `assault` heat unless the victim is currently stealing from you / wanted.
- Calls `TheftService.onThiefHit(attacker, victim)` (lazy) on any successful hit; contract `defend` if the hit ejected the driver of a `Stolen` car, or of a `Loot` car whose driver is wanted (≥1★), whoever the attacker is (`countsAsThiefBonk`).
- Stunned state: player attribute `Stunned=true` for the duration (client disables controls).

### VehicleFxService
- Relays a driver's cosmetic nitro/horn state. `VehicleFx(boost, honk)` (client → server) is validated: booleans, sender is the live driver, rate-limited, horn cooldown, boost-edge debounce, boost capped at the largest legal tank unless the Infinite Nitro pass is owned. It is broadcast as `VehicleFxState(vehicleId, boost, honk)` to players in range except the sender, with a keep-alive while boosting. Purely cosmetic: it never touches physics.

### EventService
- Hot Drop: every `HOT_DROP_INTERVAL`: announce countdown (`Announce` + `HotDropState` with startsAt), then spawn a car (`Rolls.carOfRarity(weighted HOT_DROP_RARITY, "any")`, mutation boosted) at a random `MapLayout.hotDropCFrames()` with a giant beacon beam (neon cylinder 300 tall, `Workspace.Effects`), kind `HotDrop`, steal prompt hold `HOT_DROP_HOLD`. Claim → becomes Loot for the claimer, wanted +`hotDrop`, EventFeed, Waypoint cleared for all, contract `hotDrop`, stats. Expires after lifetime.
- Cash Rain: bags (small part with BillboardGui 💰) fall around the plaza; touch = cash (`CASH_RAIN_BAG_SECONDS` of the toucher's income, min $250); each bag once.
- Rush Hour: `getTrafficMultiplier()` & luck boost. 2x Cash: `getIncomeMultiplier()` = 2 while active.
- Server Luck product: `activateServerLuck(player)` → luck ×2 for 15 min (stacks duration), Announce "<name> boosted SERVER LUCK!".
- `getLuck(): number` (product × rush hour, ≥ 1), `getIncomeMultiplier(): number`, `getTrafficMultiplier(): number`, `EventState` remote broadcast (active events + endsAt) on change and to new players.

### RewardsService
- **Offline earnings** on load: `min(now - lastOnline, CAP) × incomePerSec(base, no events) × rate` (VIP rate) → added as cash after 3s, `OfflineEarnings` remote.
- **Daily streak** (7-day cycle; missing a day resets): `ClaimDaily` remote; rewards per `Economy.DAILY_REWARDS` (`incomeMinutes` = minutes of current income, min $500; `car` = random car of rarity → storeCar or cash fallback).
- **Playtime gifts** (session-based, not persisted): `ClaimPlaytime(index)`.
- **Codes**: `RedeemCode(code)` → case-insensitive, once per account.
- **Contracts**: 3 per UTC day (`Economy.Contracts`, deterministic per player+day via `Random.new(userId + day)`), `progress(player, stat, amount)` public function used by every system; auto-claimed on completion with Notify + cash (`reward` seconds of income, min $500).
- **Group & friends bonus** inputs for the multiplier: `isInGroup(player)` (cached `IsInGroup`), `friendsInServer(player)` (cached `IsFriendsWith`, recomputed on join/leave).
- **Referral**: on join, `player:GetJoinData().ReferredByPlayerId` → if nonzero and not rewarded yet → both get a random `REFERRAL_REWARD_RARITY` car (inviter only if in this server), `referralRewarded = true`.
- `getDailyView(player)`, `getPlaytimeView(player)`, `getContractsView(player)` for snapshots.

### ShopService
- Creates the Gear Shop `ProximityPrompt` ("Gear Shop", on the counter part MapBuilder tags `GearShopCounter`, found via `CollectionService:GetTagged`) → `OpenUI("GearShop")` to that player.
- Remotes `BuyUpgrade(upgradeId)` (validate id, level < max, price via `EconomyMath.upgradePrice`, spend) and `BuyTool(toolId)` (validate, not owned, price, spend, then `CombatService.giveTools(player)` (lazy) so it appears immediately). Notify + `Sound` on success; Notify error on failure.

### RebirthService
- `Rebirth` remote: requires cash ≥ `rebirthCost(rebirths)`. Resets cash to STARTING_CASH, garage to just the single best car (by income) the player owns, `slotsUnlocked` to START_SLOTS, upgrades kept, tools kept; `rebirths += 1`. Announce to server + confetti. Lock duration +10s per rebirth (PlotService reads rebirths).

### LeaderboardService
- `leaderstats` folder: `Cash` (IntValue, short-formatted string not possible → use NumberValue), `Steals`. Global boards via OrderedDataStore (`totalEarned`, `steals`) refreshed every 120s, writes on save (pcall, budget-aware). Renders top 10 onto `LeaderboardBoard` parts (SurfaceGui). `GetLeaderboard` remote.

### AdminService
- Admins = `game.CreatorId` (user), group owner if group game, `RunService:IsStudio()` everyone. `AdminCommand(text)`: `cash <n>`, `car <id> [mutation]`, `wanted <n>`, `hotdrop`, `event <name>`, `reset` (wipe own data), `rebirth`. Also chat via `TextChatService` command (`/hc ...`) if simple. Never available to non-admins (server check every call).

## 7. Client controllers

Each lives in `src/client/Controllers/<Name>.luau` with `init()`/`start()`. UI built only via `client/UI/Kit.luau` + `Theme.luau`.

| Controller | Responsibility |
|---|---|
| **StateController** | Holds the latest `Snapshot` (`GetSnapshot` on start + `DataSnapshot` remote). `get(): Snapshot?`, `Changed: Signal(snapshot, previous)`, `onReady(fn)`. Also tracks `EventState`, `HotDropState`, `TheftState` with their own signals. |
| **SoundController** | `play(key, position?)` for UI/world sounds from `Config/Sounds` (classic `Sound` objects; world sounds parented to an attachment at the position), `Sound` remote, engine loop per nearby car (≤ 6 closest, `PlaybackSpeed = 0.7 + 1.1 × speed/topSpeed`), police sirens on tag `Police`, city ambience loop (respects settings). Preload with `ContentProvider:PreloadAsync`. |
| **NotificationController** | Toast stack (top-right), `Announce` banner (center, big, animated), `EventFeed` (left, fades), `CashPopup` floating text, `OfflineEarnings` modal ("While you were away…"), `CarStolenAlert` (red flashing border + siren + "YOUR <car> IS BEING STOLEN!" + arrow via Waypoint). Public `toast(kind, text)`. |
| **HUDController** | Cash counter (tweening, top-center) + `+$X/s`, wanted stars (top-right, flash when changing), left side menu buttons (Shop, Store, Index, Daily, Contracts, Rebirth, Settings) opening `MenuController`, "Go Home" button, Hot Drop / event timers bar, BUSTED overlay (`Busted` remote: big stamp, lost cash), theft delivery timer. Respects `settings.hideHud` (hide all except vehicle controls). |
| **MenuController** | All menus as `Kit.window`s: **Gear Shop** (upgrades + tools, opened by `OpenUI("GearShop")`), **Store** (Robux passes/products via `MarketplaceService:PromptGamePassPurchase/PromptProductPurchase`; hide id 0 items; no fake urgency), **Car Index** (grid of every car, silhouette until discovered, ViewportFrame preview via `CarBuilder.build` for discovered, rarity completion bonus), **Daily** (7-day streak track + claim), **Playtime gifts**, **Contracts** (3 dailies with progress bars), **Rebirth** (cost, what you keep, multiplier preview), **Codes**, **Settings** (music, sfx, hide HUD, auto-accelerate). `open(name)`, `close(name)`, `toggle(name)`. |
| **VehicleClient** | When the local player's humanoid sits in a `Vehicle`-tagged car's `DriverSeat`: runs `VehicleController` on Heartbeat with input from `VehicleSeat.ThrottleFloat/SteerFloat` (keyboard/gamepad/thumbstick all work) + handbrake (Space / ButtonX / mobile button), nitro (Shift / ButtonR2... / mobile button), horn (H), auto-accelerate setting. Mobile buttons (big, right side): Nitro, Drift, Horn, Exit. Speedometer + nitro bar + health bar. Camera: FOV kick with speed + nitro, slight shake on crash. Drift smoke & nitro flame local effects; nitro on/off and horn presses go to the server as `VehicleFx` so nearby players see the flames and hear the horn. Car radio (◀ ▶ next to the speedometer, R/T keys). `Driving` UI only while driving. Exit = **F** / **ButtonA** (not E, the steal prompts' hold key; Jumping is disabled while seated). |
| **WheelAnimator** | For every `Vehicle`-tagged car within 250 studs: spin wheels by chassis velocity, steer front wheels visually from yaw rate, suspension bob via raycast — purely cosmetic, client-local weld C0 edits. Rainbow mutation hue cycling for `Mutation="Rainbow"` cars and `DisplayCar`/`DealerCar`. |
| **GarageClient** | Local gate collision for own plot (CanCollide=false locally when owner). Prompt visibility (owner: Drive/Sell/Unlock; others: Steal). Billboards over display cars (name, rarity color, mutation, `$X/s`, uncollected). Collect pad glow when uncollected > 0. Lock button UI countdown. |
| **DealershipClient** | Spinning turntables + price/rarity billboards for `DealerCar`s, restock timer. |
| **WaypointController** | `Waypoint` remote → 3D beam/arrow from character to target + screen-edge arrow when off-screen + distance label. Auto waypoints: own garage while driving deliverable Loot/Stolen car; Hot Drop location while active. |
| **CombatClient** | Tool activation → `ToolAction(toolId, aim)` (aim = mouse hit / touch tap / camera center). Swing/zap/spike local effects. `Knockback` remote → apply to own `HumanoidRootPart` (`AssemblyLinearVelocity`), `PlatformStand` for stun, then restore. Disable movement while `Stunned`. |
| **EffectsController** | `Effect` remote router: CarWreck (cartoon smoke + "KAPOW"), Confetti, Zap beam, CashBurst, BigSteal. Rarity tags (BillboardGui) on Rare+ street/traffic/hot-drop cars within 150 studs. Police siren light flashing (tag `Police`). |
| **EventsClient** | Hot Drop countdown banner + beacon waypoint, Cash Rain banner, Rush Hour / 2x Cash / Server Luck pills on HUD. |
| **TutorialController** | Icon-driven onboarding for new players (`tutorialDone=false`): steal a car → deliver → collect → visit dealership. Big arrows/waypoints, minimal text; skippable; `TutorialDone` remote at end. |

## 8. Shared vehicle modules (`src/shared/Vehicle`)

### CarBuilder
- `CarBuilder.build(carId: string, mutation: MutationId, opts: { forDisplay: boolean? }?) -> Model` (also accepts `Cars.Police` via `CarBuilder.buildDef(def, mutation, opts)`).
- Model structure (strict contract other code depends on):
  - `PrimaryPart = Chassis`: invisible box (`Transparency=1`), the **only collidable** body part, sized to the car's lower body, `CustomPhysicalProperties` density tuned so `AssemblyMass` ≈ 900–3000 by size. Pivot = chassis center.
  - Attachments in Chassis: `WheelFL`, `WheelFR`, `WheelRL`, `WheelRR` at wheel hub centers in the built pose (wheels resting on the ground plane).
  - Visual wheel parts `Wheel_FL` … (cylinders, `CanCollide=false`, `Massless=true`) welded with `Weld` named `WheelWeld_FL` … (Part0=Chassis) so WheelAnimator can edit C0.
  - `DriverSeat` (`VehicleSeat`, `CanTouch=false`, `MaxSpeed=0`, `Torque=0`, `HeadsUpDisplay=false`, `Transparency=1` if inside body), welded.
  - Body parts: `CanCollide=false`, `CanQuery=false`, `CanTouch=false`, `Massless=true`, welded to Chassis (`WeldConstraint`). Paintable parts have attribute `Paint="primary"` or `"accent"`. Glass parts `Paint="glass"`. Lights: parts named `Headlight` (SpotLight child, disabled by default) / `Taillight`, police `SirenRed`/`SirenBlue`.
  - Two small invisible collidable `Ball` bump-stops under the axles (so a non-simulated car rests on its wheels' height instead of its belly).
  - Model attributes: `RideHeight` (pivot height above ground in the built pose), `WheelRadius`, `Length`, `Width`, `Style`.
- `CarBuilder.applyMutation(model, mutation)` (color/material/sparkles; Rainbow handled client-side by WheelAnimator).
- Styles: every `CarStyle` in `Config/Cars.luau` must have a distinct, recognizable silhouette (wedges for hoods/windshields, cylinders for wheels, neon lights). Meme cars (hotdog, duck, couch, toilet) must be instantly readable and funny. Hover car: no visible wheels (keep invisible wheel attachments). Tank: treads + turret.
- Performance: ≤ 40 parts per car.
- **v2 mesh cars (wave A4).** A def with `vehicle` (Config/Vehicles) is built by `Shared/Vehicle/MeshCar` from its uploaded Model (`Shared/Vehicle/CarTemplates`, loaded by VehicleService at start) on the same contract: wheels are MeshParts `Wheel_FL..` on `WheelWeld_FL..`, `Headlight` / `Taillight` are invisible anchors (Beam SpotLight; BrakeGlow / ReverseGlow PointLights), lightbar lenses are `SirenRed` / `SirenBlue` MeshParts, the Body MeshPart is `Paint="primary"` (Color = paint, TextureID = overlay or livery image). Model attributes add `MeshCar`, `Vehicle`, `Brand`, `RigVersion`. Without a ready template the procedural car is built with `MeshPending` and `CarBuilder.applyMesh` converts it in place later (same Model / Chassis / seat). See `docs/v2/early/vehicles/README.md`.

### VehicleController
- `VehicleController.new(model: Model, def: CarDef, opts: { isServer: boolean }) -> Controller`
- `controller:setInput({ throttle: number, steer: number, handbrake: boolean, nitro: boolean })`
- `controller:step(dt)` (call from `RunService.PreSimulation`, dt clamped to `MAX_DT`) — implements the force model documented at the top of `Config/Vehicle.luau`:
  - Creates (once, in `new`) per-wheel `VectorForce`s on the wheel attachments (`RelativeTo=World`, `ApplyAtCenterOfMass=false`), a center `VectorForce` "Drive" (`ApplyAtCenterOfMass=true`, `RelativeTo=World`) on a `DriveAttachment`, and an `AlignOrientation` "Upright" (`OneAttachment`, `PrimaryAxisParallel` world up). Destroyed in `destroy()`.
  - Suspension: ray from each wheel attachment down `L = SUSPENSION_REST + WheelRadius` (one cached `RaycastParams` excluding the car, all characters, and `Workspace.Vehicles` display-only parts as needed). `a = clamp(K·comp + C·compVel, 0, 4g)`; force `M·a` along hit normal. Also positions visual wheel welds on the client (or leave to WheelAnimator).
  - Drive/brake/reverse/rolling/drag, lateral grip (handbrake → rear grip drop = drift), downforce: summed into Drive.Force. Only when ≥2 wheels grounded, scaled by grounded fraction.
  - Steering: write yaw rate directly into `AssemblyAngularVelocity` (sign: SteerFloat +1 = right turn = negative Y rotation).
  - Upright AlignOrientation enabled only when airborne or tilted; auto-flip after `AUTO_FLIP_AFTER`.
  - Nitro (tank seconds from upgrade/pass; refill), `TiresPopped` attribute (os.clock deadline → top speed × `SPIKES_SLOW`), `SpeedMultiplier` attribute hook.
  - Exposes `controller.speed`, `controller.forwardSpeed`, `controller.grounded` (0..4), `controller.nitro` (0..1), `controller.drifting`, `controller.wheelCompression[1..4]`.
  - Unoccupied: `controller:setInput` zeros + suspension still runs where a controller exists (server keeps controllers only for police and for cars settling after exit).
- `controller:destroy()`
- Must work on the client (network owner) and on the server (police AI). All tuning from `Config/Vehicle.luau` + `CarDef`.

## 9. Monetization (honest, non-P2W)

Passes: VIP (2× cash), +2 Garage Slots, Master Thief (40% faster hotwire), Infinite Nitro, Zapper Pass. Products: Stack/Briefcase of Cash (income-scaled), Server Luck ×2 (15 min, everyone benefits, buyer announced), Lockdown (10 min lock), Lose the Cops, Diamond Dragster (exclusive unstealable). **No paid random items. No fake urgency. No admin powers for sale.** Store UI hides products whose id is 0.

## 10. Headless tooling (Lune) — use it

- `lune run tests/run.luau [filter]` runs `tests/spec/*.spec.luau` against the real source via `tests/harness.luau` (emulates the Rojo `script` tree; Roblox datatypes from `@lune/roblox`; shims for `Model:PivotTo/GetPivot/GetExtentsSize`, `Random`, `TweenInfo`, `CollectionService`, `RunService`, `Players`, `TweenService`, Terrain fills (recorded no-ops)). No physics, no events firing, no `task.wait` progression you can rely on, no DataStores.
- `lune run tools/dump.luau car <id|all|police> [mutation] out.json`, `... map out.json`, `... plot <i> out.json` then `python3 tools/render.py out.json out.png [--views iso,iso2,top,side] [--size 600]` renders a preview PNG you can look at with the Read tool. **Builders must be harness-compatible:**
  - `CarBuilder.build/buildDef` — pure instance construction (Instance.new, properties, attributes, tags, WeldConstraint/Weld, Attachments). No services other than those shimmed.
  - `MapBuilder.build(parent: Instance): Folder` — builds and returns the `Map` folder; `MapBuilder.init()` just calls `build(Workspace)` then sets up the things that need the live engine.
  - `PlotService.buildGarageModel(index: number): Model` — builds one garage model (unparented or parented by caller) with no player state.
- Geometry conventions: `WedgePart`'s sloped face faces local **-Z (Front) and up**; its tall vertical face is at **+Z (Back)**. Cylinder `Part.Shape = Cylinder` axis is local **X**. A car's forward is its pivot's **LookVector (-Z)**.

## 11. Quality bar / definition of done per system

- Selene clean (`selene src`), StyLua formatted (`stylua src`).
- No yields in `init()` (except MapBuilder build).
- Every remote handler validates args and is rate limited (Net does rate limiting).
- No per-frame `Instance.new` in hot loops; reuse RaycastParams; cache lookups.
- Clean up connections on player leave / car destroy.
- Mobile tested mentally: every action reachable by touch.
