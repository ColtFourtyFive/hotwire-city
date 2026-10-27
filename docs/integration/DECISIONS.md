# Fix-phase decisions & cross-group interfaces

These decisions resolve product and balance questions raised by the audit (`findings_all.json`). Every fix agent follows them.

## Design and balance (shared config is already updated)

1. **Street heat (pillar 1: every steal is a getaway).** `Rarity.Tiers[t].wantedChance` is new.
   - Uncommon now has `wantedOnSteal = 1`.
   - On a street steal, roll `rng < tier.wantedChance`. If it hits, add `math.max(1, tier.wantedOnSteal)` stars. Common uses 0.35; every other tier uses 1, so it always adds `wantedOnSteal`.
   - A player's first-ever steal adds 0 (unchanged).
   - Carjacking traffic adds `math.max(Police.Heat.carjack, tier.wantedOnSteal)`.
2. **Dealership heist.**
   - Steal heat is `math.min(5, math.max(Police.Heat.dealerSteal, tier.wantedOnSteal + 1))`.
   - Spray cost is `stars * math.max(Economy.SPRAY_COST_PER_STAR, incomePerSec * Economy.SPRAY_INCOME_SECONDS)`.
3. **Rebirth.**
   - Cost growth is ×2.75.
   - The player keeps their best `Economy.REBIRTH_KEEP_CARS` (= 2) cars by income. Exclusive (Robux) cars are always kept and never count toward that limit.
   - Uncollected garage cash is paid out (added to cash and totalEarned) before the reset. The reset then sets cash to STARTING_CASH, so the menu must say "cash resets".
   - Rebirth does **not** change luck. Remove every luck claim from UI and comments.
   - Perks: +50% income per rebirth and +10s laser-lock duration.
   - Register the Rebirth remote at rate 1/s. Net buckets now start with ≥1 token.
4. **Daily, codes, playtime.**
   - Daily rewards are `incomeMinutes` with floors (`min`), with car rewards on days 4 and 7.
   - Codes moved to the **server-only** `src/server/Config/Codes.luau` (ServerScriptService.Server.Config.Codes). They also use `incomeMinutes` + `min`.
   - Playtime gifts accumulate **per UTC day**, persisted in `data.playtime = { day, seconds, claimed = {[index]=true} }`. The claim must be checked server-side against seconds stored plus seconds this session. Add this to Types (via DataService defaults/reconcile).
5. **Theft bonuses (anti-farm).**
   - The recovery bonus pays only if the theft lasted ≥ `Economy.RECOVERY_MIN_SECONDS` **or** the car left the victim's garage interior.
   - Recovery and revenge each pay at most once per (victim, thief) pair per `Economy.BONUS_PAIR_COOLDOWN` (600s).
6. **The "bonk3"/defend contract** counts any bat or zapper hit that ejects a driver who is in a `Stolen` car, or in a `Loot` car while wanted ≥ 1.
7. **Diamond Dragster is a one-time purchase.** Refuse it (and never charge) if it is already owned in the garage or still owed in `exclusives`. The Store shows OWNED. **Clear Wanted** with 0 stars returns NotProcessedYet and the Store button is disabled at 0 stars. **Lockdown** stacks time (`max(existingEnd, now) + duration`).
8. **Garage lock re-arm** is proportional: `max(LOCK_REARM, 0.5 * lastDuration)`.
9. **Locking mid-theft.** Locking the garage while a thief drives a car stolen from this garage ejects the thief. The car stays inside and becomes "dropped", so the victim can recover it, and the thief is pushed out on foot. Intruders' own cars are moved with `VehicleService.teleport`, never a raw PivotTo.
10. **Streaming** stays disabled for v1 (8-player servers). Do the PERF fixes listed instead.
11. **Monetization ids are 0 until the owner creates the products.** Every pass or product with id 0 is hidden, including the garage pads 11–12 "+2 SLOTS PASS" label, which shows 🔒 MAX SLOTS instead. The group bonus is hidden when GROUP_ID is 0.
12. **AssetLibrary/hero-mesh consumption** (PERF-06, assetlibrary-unconsumed) is handled by the **art pass**, not now.

## Cross-group interfaces (implement exactly; other agents code against them)

**VehicleService** (group A1) adds or guarantees:
- `VehicleService.seat(car, player) -> (ok: boolean, reason: string?)`. It never throws, and **callers must check `ok`**.
- `VehicleService.teleport(car, cframe)` and `VehicleService.resetWatchdog(car)` handle intentional server moves.
- Drive-start tracking: `car.data.driveStartAt` / `car.data.driveStartPos` are set when a drive begins.
- `VehicleService.minTravelTime(car, targetPos: Vector3) -> number`
- `VehicleService.isTainted(car) -> boolean`. It returns true after any watchdog violation.
- Zone events (DeliveryAttempt / ChopAttempt / SprayAttempt) fire only for cars that pass the watchdog check that tick and are not tainted.
- `VehicleService.Wrecked: Signal(car)` fires **before** the driver is ejected.

**TheftService** (group A2):
- `TheftService.fail(car, reason)` may be called while the thief is still seated. It ends the theft first, and markDropped/recover ignore wrecked or destroyed cars.
- `TheftService.complete(car)` rejects with false when it ran too quickly, using `VehicleService.minTravelTime` from the slot to the thief's drop-off, or when the car is tainted.
- `TheftService.onThiefHit(attacker, thief)` must be called **before** any eject. CombatService (B1) changes its order to match.

**WantedService** (group B1):
- When busting a thief in a Stolen car, call `TheftService.fail(car, "busted")` before ejecting.
- Fire `Busted(lostCash: number, carLabel: string?)`. HUD (C1) shows "🚗 <car> IMPOUNDED" when carLabel is set.

**StateController** (group C1) passes `dropped` and `droppedEndsAt` through TheftState. HUD shows "GET BACK IN! 0:12" while dropped.

**RewardsService** (group B2): `RewardsService.progress(player, stat, amount)` stays the single entry point. Stat names are unchanged.

## Ownership (only edit your own files)

| Group | Files |
|---|---|
| A1 vehicle-core | server/Systems/VehicleService, StreetSpawnService, TrafficService; shared/Vehicle/VehicleController, CarBuilder (non-art fixes only); client/Controllers/VehicleClient, WheelAnimator |
| A2 theft-garage | server/Systems/TheftService, GarageService, PlotService, DealershipService; client/Controllers/GarageClient, DealershipClient |
| B1 law-combat | server/Systems/WantedService, PoliceService, CombatService, LightingService, MapBuilder (non-art fixes only); client/Controllers/CombatClient, EffectsController |
| B2 meta | server/Systems/DataService, MonetizationService, RebirthService, RewardsService, EventService, ShopService, AdminService, LeaderboardService; server/Config/*; shared/Net, shared/Util/*; client/Controllers/MenuController |
| C1 client-hud | client/Controllers/HUDController, NotificationController, TutorialController, WaypointController, StateController, EventsClient, SoundController; client/UI/* |
| (lead) | shared/Config/*, shared/Remotes, shared/Types, default.project.json, docs/*, AssetLibrary, Config/Assets |

Tests: each group may add or edit tests/spec files for its own modules.
