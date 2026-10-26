## Files: src/server/Systems/DataService.luau, src/server/Systems/MonetizationService.luau, src/server/Systems/LeaderboardService.luau, src/server/Systems/AdminService.luau, tests/spec/data.spec.luau, docs/previews/leaderboard.png

### Public API
DataService (session-locked profiles; DataStore "HotwireCity_v1", key "p_<userId>"; stored record = {data, lock={jobId, session, time}?, savedAt})
- Spec API: get(player): PlayerData? (the live table) | isLoaded(player) | waitFor(player, timeout?=30): PlayerData? (yields) | addCash(player, amount, reason?): number? | spendCash(player, amount): boolean | markDirty(player) | buildSnapshot(player): Snapshot | saveNow(player): boolean (YIELDS, returns write success) | signals Loaded(player, data) and Releasing(player, data)
- Remotes: GetSnapshot (waits up to 20s for load), SetSetting(key, value) (music/sfx/hideHud/autoAccelerate, boolean only), TutorialDone().
- addCash: a negative amount removes cash (clamped at 0). A positive amount also adds to totalEarned, except when reason is "purchase", "refund" or "admin", so bought, refunded and dev cash never inflate the leaderboard.
- Sets these player attributes: Cash, Rebirths, and DataLoaded=true (extra).
- Extras: getSessionInfo(player) -> {isNew, previousLastOnline, joinedAt}. The live data.lastOnline keeps the previous session's value; only the saved copy is stamped with now. New players start with lastOnline = now, so they get no offline earnings.
- Extras: isMemoryMode(), getMode() ("pending"|"live"|"memory"), resetData(player) (resets in place and keeps receipts), SCHEMA_VERSION, RECEIPT_CAP.
- Test hooks: _template, _reconcile, _migrate, _sanitize, _prepare, _serialize, _unpackRecord, _lockState, _MIGRATIONS, _internals.

MonetizationService
- Spec API: hasPass(player, key) (false for id 0) | PassChanged(player, key) | registerProduct(key, handler(player) -> boolean) | productIdFor(key) | passIdFor(key)
- Has a built-in handler for every product key. Sets player attribute "VIP".
- Extras: getPasses(player), setPassOverride(player, key, value?) (session-only QA override, works even for id 0), deliverExclusives(player).
- Test hooks: _hasReceipt, _recordReceipt, _receiptAction, _cashAmount, _processReceipt, _processWhileLocked.

LeaderboardService
- Spec API: leaderstats Cash (NumberValue, floored) and Steals (IntValue) | GetLeaderboard(stat) remote -> {{name, userId, value}} | getTop(stat).
- Extras: attachBoard(part), _render(stat, list) (preview hook), _encode/_decode (log score encoding), _merge.

AdminService
- isAdmin(player) | run(player, text) -> (ok, message) | AdminCommand remote | TextChatCommand "/hc" (alias "/admin").
- Commands: help, cash, car, spawn, give, wanted, hotdrop, event, rebirth, reset, slots, pass, tp, tutorial, save.
- Test hooks: _parse, _parseAmount, _resolveCar, _resolveMutation, _resolveEvent.

### Contract deviations
- EventService: the spec defines activateServerLuck(player) but no way to force a Hot Drop, Rush Hour, Cash Rain or 2x Cash. AdminService tries these names in order and reports which one ran: forceHotDrop/startHotDrop/triggerHotDrop/spawnHotDrop, startRushHour/forceRushHour, startCashRain/forceCashRain, startDoubleCash/forceDoubleCash, then the generic startEvent/forceEvent/triggerEvent(name) with name = rushHour|cashRain|doubleCash|hotDrop. Ask the EventService owner to expose one of them, ideally startEvent(name).
- RebirthService: the spec has only the Rebirth remote. Admin 'rebirth' first tops cash up to rebirthCost, then tries rebirth/doRebirth/performRebirth/forceRebirth(player). If none exist it tells the admin to use the Rebirth menu.
- VehicleService.spawn opts: admin 'spawn' passes {ownerUserId = player.UserId} as opts (that shape is not in the spec), then calls VehicleService.seat(car, player).
- data.exclusives means cars that are owed but not yet delivered. A Diamond Dragster bought with a full garage is stored as exclusives['diamond_dragster'] (a second one as 'diamond_dragster#2') and delivered automatically within 5s of a slot freeing, or on the next join. Delivered keys are removed. The store UI must not read exclusives as 'owned'.
- data.retiredCars (not in Types.PlayerData): garage records whose carId no longer exists in Config/Cars are moved here during sanitize (capped at 20) instead of being deleted, so GarageService never sees an unknown carId.
- saveNow(player) yields: it waits out the ~6s per-key write cooldown and retries. Callers that do not need the result (e.g. TheftService.complete) should wrap it in task.spawn.
- maxSlots in the snapshot = Economy.MAX_SLOTS + PASS_EXTRA_SLOTS when the 'slots' pass is owned. sanitize clamps slotsUnlocked to [START_SLOTS, MAX_SLOTS + PASS_EXTRA_SLOTS].
- Leaderboard boards render on both the Front and Back faces of each LeaderboardBoard part unless the part has a string attribute 'Face' (an Enum.NormalId name). The totalEarned OrderedDataStore value is log-encoded, floor(log10(x+1)*1e12), and decoded for display.

### Known issues
- Nothing has run inside real Roblox: DataStore throttling, BindToClose timing, TextChatCommand.Triggered on the server and UserOwnsGamePassAsync were checked by reasoning and the fake store only. Do a live Studio test with API access enabled before release.
- The SPEC §11 command `stylua src` cannot work in this environment, because the installed stylua binaries lack Luau syntax and fail on every file with type annotations, foundation files included. Other slices should use the Luau-enabled build at /tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/stylua-luau/bin/stylua (StyLua 2.3.0 --features luau, matching rokit.toml), or install one the same way.
- If a profile ever contains data that makes prepare() throw, that player is kicked on every join rather than given defaults. This is deliberate (never overwrite real data); sanitize is defensive enough that it should not happen.
- When a player's lock is stolen because their old server looked dead, that old server's unsaved progress since its last autosave (at most about 120s) is discarded. This is the same trade-off ProfileStore makes.
- Leaderboard global reads are at most every 120s and per-player writes at most every 5 min plus on leave. Players in the server see their own live values merged in every 10s. In Studio memory mode the boards show 'THIS SERVER - live' only.
- The admin 'pass' override is session-only and allowed for any admin, live servers included. Remove it, or gate it with RunService:IsStudio(), if the creator does not want it in production.
- Admin 'reset' wipes the profile in place and calls GarageService.refresh. A car currently out on the road (slot state 'Driving') is handled by GarageService, which I have not verified.
- MonetizationService's built-in handlers (lock_10, clear_wanted, server_luck) return false, and the receipt stays NotProcessedYet so the player is never charged for nothing, if PlotService, WantedService or EventService are missing or error. diamond_dragster always grants: into a free slot if GarageService.storeCar succeeds, otherwise as an owed exclusive.

### Verification
- selene on all 4 files: 0 errors, 0 warnings.
- stylua: both stylua binaries on PATH (2.6.0) were built without Luau syntax, and they also fail to parse the foundation's Types.luau. I built StyLua 2.3.0 with the luau feature at /tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/stylua-luau/bin/stylua (the version pinned in rokit.toml) and formatted all 5 files with it. `--check` is clean.
- rojo build -o /tmp/claude-0/build-*.rbxlx: succeeds.
- lune run tests/run.luau: 71 passed, 0 failed (25 of them in data.spec.luau).
- data.spec covers the pure pipeline: SPEC §5 template; reconcile (non-destructive, no free starter car merged into existing garages, wrong types replaced); migrate (stamps the version, never downgrades); sanitize (NaN/inf/negatives, bad mutations, unknown cars moved to retiredCars, slot-key normalization, upgrade clamps, receipt cap, future lastOnline, malformed contracts, deep inf scrub); JSON-safe serialize; legacy record unpacking; all lockState branches.
- data.spec also drives the real claim/save code against a fake DataStore that simulates the JSON round trip:
  - claim, then save keeps the lock, release clears it, reclaim sees the saved data, and the old session is refused, marked lost and kicked without overwriting the new owner;
  - a live foreign lock gets 6 retries and is then stolen with the stored data kept;
  - a stale lock and a legacy bare profile are both claimed on the first try;
  - transient errors are retried; persistent errors return 'failed' with no default data handed out and the stored data untouched;
  - a player who left is never claimed; save retries work; memory mode never touches the store.
- The ProcessReceipt path is tested end to end through DataService:
  - a purchase grants once and is acknowledged only after the save;
  - redelivering a confirmed receipt grants nothing and writes nothing;
  - a failed save returns NotProcessedYet and keeps the grant plus receipt in memory, still with no double grant;
  - once the store recovers, the redelivery confirms the save and is acknowledged;
  - an unknown product, a refusing handler or unloaded data returns NotProcessedYet and records nothing.
- Also tested: income-scaled cash amounts, pass/product id helpers, built-in handlers registered for every product key, log score encoding (monotonic, round-trips, fits a double-safe int), the leaderboard merge, the board SurfaceGui building on a Part in the harness (catches invalid properties), and admin parsing/resolution.
- Leaderboard visual: I dumped the SurfaceGui tree from the harness, laid it out with a PIL renderer and inspected the PNG. That caught a real bug: UIGradient multiplies BackgroundColor3, which turned the board body near-black and the headers oversaturated. Fixed with a white base color; medals and a tinted top 3 were also added. Final preview: /home/user/HotwireCity/docs/previews/leaderboard.png.
- Re-read all files end to end. That found and fixed: RaycastParams created at module top (now lazy), HttpService GUID now has a fallback, and a deliverExclusives concurrency race (per-player guard plus pcall).

---
## Files: src/server/Systems/PlotService.luau, src/server/Systems/GarageService.luau, src/client/Controllers/GarageClient.luau, tests/spec/garage.spec.luau, docs/previews/garage.png, docs/previews/garage_interior.png, docs/previews/garage_locked.png

### Public API
PlotService (server, ORDER #5):
- buildGarageModel(index): Model. Pure and harness-safe. It produces Model "Plot<i>" with these direct children:
  - Pad1..Pad12. Each pad has SurfaceGui "PadGui" (Top face) with Root containing Number, Lock (Icon/Price), and a child Part "Sign" with SurfaceGui "SignGui" (Root containing Number/Status). Pad attributes: Slot, Locked, Price, PassOnly, NextUnlock, State (Empty/Parked/Driving/BeingStolen). Tag "GaragePad".
  - Dropoff: invisible box, no collide/query/touch, exactly at plotDropoffZone.
  - DropoffMark, DropoffSign.
  - CollectPad: neon green, CanTouch.
  - CollectSign: SignGui with Root containing Title/Amount.
  - LockButton: red neon, CanTouch.
  - LockSign: SignGui with Root containing Title/Status.
  - Gate: neon Part across the door (DOOR_WIDTH x DOOR_HEIGHT), starts CanCollide=false, Transparency=1. Children: Beam1..Beam5 and SurfaceGuis "CountdownGui"/"CountdownGuiBack" (Box containing Time).
  - StatusLight: green when open, red when locked.
  - Sign at Garage.SIGN, with SurfaceGui "SignGui" containing TextLabels "OwnerName" and "Stats".
  - Display (Folder).
  - OwnerSpawn: invisible, faces out the door.
  - Building (Folder of decor).
  - Model attributes: PlotIndex, Accent, OwnerUserId (0 = vacant), OwnerName, Locked, LockEndsAt and LockReadyAt (both on Workspace:GetServerTimeNow() timing). Tag "Plot".
- Spec API: getPlot(player): PlotInfo?, getPlotIndex(player), getOwner(index), isLocked(index), lockFor(index, seconds), plotAt(pos), getPlotModel(index), getDisplayFolder(index). Signals PlotAssigned(player, index) and PlotReleased(player, index). Remotes handled: GoHome (1/s) and LockGarage (2/s).
- Extra helpers: tryLock(player, fromTouch?) -> boolean, lockDurationFor(player), lockSecondsLeft(index), isInside(player, index), ownerSpawnCFrame(index), getPlotsFolder(), accentFor(index).
- Constants: ACCENTS (8 colors), FLOOR_LIFT=0.05, PAD_THICKNESS=0.2, PAD_TOP=0.25 (display cars rest at slotWorld + PAD_TOP + RideHeight), LOCK_REARM=15, GO_HOME_COOLDOWN=20.
- Pure helpers for tests: _lockDuration(level, rebirths) = upgradeValue("lock", level) + 10*rebirths, and _drivewayOffset(n).
- Runtime: init builds all 8 plots into Workspace.Plots. Joining assigns the lowest free plot, sets player attribute PlotIndex, and writes "<DisplayName>'s Garage" on the sign. The sign's Stats line shows "$X/s" and the car count, refreshed every 2s. Every CharacterAdded uses task.defer + WaitForChild("HumanoidRootPart") and pivots the character to OwnerSpawn.
- Lock: triggered by stepping on LockButton or the LockGarage remote, and only while inside your own garage. While locked, the gate is visible and collidable, the countdown shows on the gate and LockSign, and every 0.5s non-owners inside are pivoted to spread spots on the driveway. If they are in a vehicle seat, the car (tag Vehicle) is pivoted instead and its velocity zeroed. On expiry the owner gets a Notify.

GarageService (server, ORDER #7):
- Spec API: storeCar(player, carId, mutation) -> (true, slot) | (false, "full" | "nodata" | "badcar"), freeSlots, ownedCount, removeSlot(player, slot): SlotRecord?, setSlotState, getSlotState, restoreSlot, refresh, incomePerSec(player, noEvents?), multiplier, slotSnapshots.
- Remotes: UnlockSlot, SellCar(slot), DriveCar(slot).
- Handlers connected in init: VehicleService DeliveryAttempt, ChopAttempt, ReturnedHome and Destroyed (Destroyed covers wrecked owned cars). Also PlotService PlotAssigned/PlotReleased, DataService.Loaded, MonetizationService.PassChanged, and the CollectPad.Touched of every plot.
- Extra public functions: maxSlots(player), capacity(player), discover(player, carId) -> isNew, collect(player) -> amount, sell(player, slot), drive(player, slot), unlockNextSlot(player).
- Test hooks: _inject(name, mod) (test only), _onDelivery, _onChop, _onReturnedHome.
- Pure helpers: _capacity(slotsUnlocked, hasPass), _maxSlots(hasPass), _firstFreeSlot(garage, cap), _padInfo(slot, slotsUnlocked, hasPass), _accrue(garage, states, mult, dt), _requiredHold(base, mult), _baseStealHold(carId).
- Display cars: built with CarBuilder.build(id, mut, {forDisplay=true}), every part anchored, chassis collides. Tag "DisplayCar"; attributes PlotIndex, Slot, CarId, Mutation, Rarity, OwnerUserId, Uncollected (floored), Income.
- Prompts in the Chassis:
  - DrivePrompt: E, no hold.
  - SellPrompt: F, 1s hold, "Sell $X", UIOffset (0,84).
  - StealPrompt: only if the car is stealable. E, hold = hotwireTime x THEFT_HOLD_MULTIPLIER, attribute BaseHold. The server records PromptButtonHoldBegan and rejects a trigger that comes in under 0.9 x base x holdMultiplier.
- Plot model attributes set here: CarCount, Uncollected (total), IncomePerSec. The player attribute IncomePerSec is also set here.

GarageClient (client):
- init() and start() only; no public API. Builds a ScreenGui "GarageHUD" (HUD layer + 1) holding a bottom-centre LockButton.
- Creates a local ProximityPrompt "UnlockPrompt" on the next locked pad of your own garage. On a pass-only pad it prompts the +2 Slots pass purchase, but only if the pass id is not 0.
- Billboards are named "GarageTag" and parented to the display chassis. The collect pad gets a local PointLight "LocalGlow" and a BillboardGui "CollectTag".

### Contract deviations
- Lock re-arm (not in the spec): when a lock expires the button stays disabled for PlotService.LOCK_REARM = 15s. Without it an AFK owner could re-lock forever and theft would be impossible. The Lockdown product (lockFor) bypasses it. Plot attribute LockReadyAt drives the client's '⏳ LOCK IN Ns' state.
- An owned car only parks at the drop-off once it has actually left the garage (car.data.leftGarage, checked every 0.25s). Otherwise driving out through the drop-off zone at DRIVE_OUT_SPAWN would immediately re-park it. Owned cars with no slot left are stored via storeCar.
- Locked/Price/PassOnly/NextUnlock/State are set as SERVER attributes on every pad, so all viewers see consistent lock and STOLEN!/OUT states; GarageClient renders them per viewer (the owner sees prices and an 'UNLOCK $X' highlight, others see the lock). Pass-only pads are slots 11-12 when the +2 pass isn't owned. With the pass, the first two pads past the cash slots are usable and the price index follows slotsUnlocked+1.
- data.stats.steals is incremented on successful Loot delivery and on Stolen delivery when TheftService.complete returns true, or returns nil and the car model was destroyed. The 'steal' contract stat is NOT counted here; only deliverRare/deliverEpic are, as decided.
- If a Stolen car is delivered to the VICTIM's own drop-off, I call TheftService.recover(car, victim) when it exists, otherwise TheftService.fail(car, 'recovered'). TheftService should expose recover or accept that reason.
- storeCar does NOT mark cars discovered (dealership and other callers do it after storing). GarageService.discover(player, carId) is provided, and Loot delivery uses it.
- Selling is refused for your last car and for Exclusive-rarity cars. The seller also receives that slot's uncollected cash.
- The DriveCar remote requires the player to be inside their own garage, or within 40 studs of the slot, so it can't be used as a 'teleport home in a car' escape. It calls VehicleService.spawn(carId, mutation, groundCFrame, 'Owned', {ownerUserId, owner, slot}), then sets car.ownerUserId and car.data.slot itself in case VehicleService ignores opts.
- The GarageService.incomePerSec signature gains an optional second parameter, noEvents, for offline earnings (base income without event multipliers).
- PlotInfo is exported from PlotService (index, model, display, origin, owner, lockedUntil, lockReadyAt). It is the live internal table, so treat it as read-only.
- Cross-system access uses a lazy pcall-require getter in both services (VehicleService/DataService included), so a missing or broken slice degrades features instead of preventing load. Signals are still connected in init().
- Garage floor/pads are FLOOR_LIFT (0.05) above CURB_TOP to avoid z-fighting with MapBuilder's lot slab, so display cars rest at slotWorld + PAD_TOP (0.25) + RideHeight. The floor slab and driveway extend below road level, and a wedge curb ramp (in the plot model) pokes 4 studs onto the road edge in front of the driveway.

### Known issues
- SurfaceGui orientation on Top faces is unverified (no Studio here). Pads, DropoffMark and CollectPad are rotated 180° so that, if Roblox maps gui-up to the part's -Z on Top faces, floor text reads from the aisle or door. If it is the other way, floor numbers appear upside down. All critical info is duplicated on vertical, unambiguous signs: the bay signs on the walls, the hanging DROP-OFF sign, CollectSign and LockSign.
- VehicleService, TheftService, RewardsService and EventService had not landed when I finished. Calls follow the spec: spawn/seat/eject/destroy/getDriving, the DeliveryAttempt/ChopAttempt/ReturnedHome/Destroyed signals, beginTheft/complete/fail/recover, progress/friendsInServer/isInGroup, getIncomeMultiplier. All are pcall-guarded but untested against the real implementations. Integration should check: VehicleService.spawn opts, TheftService.complete's return value, and whether theft.victim is a Player or a userId (both handled).
- Display-car prompt and billboard code can't run in the Lune harness (no instance events), so buildDisplay and GarageClient were only reviewed by reading, not executed. A playtest is needed for prompt visibility, the HoldDuration scaling, billboard placement (StudsOffset = extents.Y - RideHeight + 2.6) and the lock button position: bottom-centre at y = -112 to clear the tool hotbar, hidden while driving.
- DataService.buildSnapshot computes maxSlots itself, ignoring the physical cap. That's harmless today (10+2 = 12 = physical) but GarageService.maxSlots(player) exists if they want to use it.
- MapBuilder (not yet present) must keep the sidewalk in front of each plot's driveway free (|local X| < 20, local Z from -64 to -44) and shouldn't build anything at curb height on plot blocks. My floor and driveway sit 0.05 above CURB_TOP.
- Laser-lock push-out also moves a thief who is mid-theft (driving the Stolen car out) to the driveway, per spec. Design-wise that helps the thief escape; the team may prefer to keep thieves with cars inside, or to let TheftService block locking during an active theft.
- Income accrues uncapped while online; fractions under $1 are dropped on collect. Snapshots are pushed every 3 income ticks, while billboards and the HUD use attributes that update every tick.

### Verification
- selene, run on all 4 of my files: 0 errors, 0 warnings.
- stylua: files formatted; stylua --check is clean.
- rojo build -o /tmp/claude-0/build-*.rbxlx: succeeded.
- lune run tests/run.luau: 146 passed, 0 failed across the whole suite. That includes 16 garage tests, plus the other slice's boot spec, which loads PlotService, GarageService and GarageClient in client mode.
- The garage spec covers:
  - Every named part, gui and attribute on all 8 plots.
  - Pads at MapLayout.slotWorld XZ, at the right Y and footprint, with no overlaps and none in the drop-off.
  - Gate centred in the front wall, DOOR_WIDTH wide, covering door height down to the floor, starting non-collide and invisible, with beams. No collidable part blocks the doorway.
  - Dropoff/CollectPad/LockButton/OwnerSpawn/Sign positions match Config.Map.Garage; OwnerSpawn faces the door and lies inside the plot.
  - Every part anchored and inside the lot; at most 260 parts per garage (about 183 actual).
  - The 8 plot accents are distinct; push-out spots are outside the interior.
  - Pure-helper math: lock duration, capacity/maxSlots/firstFreeSlot, padInfo prices/next-unlock/pass pads, income accrual (Parked only), hold timing.
  - A full GarageService flow against injected fake DataService, PlotService, Monetization, Rewards, Event and VehicleService plus stubbed Net: store, full, BeingStolen and restore, pad attributes, collect (floor and contract), snapshots, sell (with uncollected), unlock (too poor, then paid), Loot delivery (steals, discover, rare/epic contracts, EventFeed, no double count), full-garage delivery, owned car parking only after leaving, chop (loot only), removeSlot, the IncomePerSec attribute.
- Rendered with tools/dump.luau + render.py and checked visually. Saved: docs/previews/garage.png (iso/iso2/top), docs/previews/garage_interior.png (roofless cutaway with 11 real CarBuilder display cars placed exactly as buildDisplay does), docs/previews/garage_locked.png (front view with the laser gate locked).
- Re-read all three source files end to end. Fixes from that pass: a guard against handling a player twice on join, an owner-only client gate override (avoids races between replicated properties and attributes), and .CFrame.Position instead of .Position for harness compatibility.

---
## Files: src/server/Systems/TheftService.luau, src/server/Systems/DealershipService.luau, src/client/Controllers/DealershipClient.luau, tests/spec/theft.spec.luau, docs/previews/dealership.png

### Public API
TheftService (server; ORDER after PoliceService. It lazily loads every other system by name through pcall'd require, the same pattern GarageService uses):
- beginTheft(thief, victim, slot): boolean. GarageService calls this after it has validated the StealPrompt hold. It runs every check through _canSteal and sends the thief a Notify with the reason when one fails. On success it sets the slot to BeingStolen (GarageService.setSlotState), then calls VehicleService.spawn(carId, mutation, slotWorld*PAD_TOP, "Stolen", {ownerUserId=victim.UserId, victim, thief, slot}) so the car faces the aisle. It sets car.data.theft = {id, victim, victimUserId, slot, carId, mutation, startedAt, thief}, calls VehicleService.seat, WantedService.addHeat(Heat.playerTheft, "theft") and RewardsService.progress("steal"). It then fires CarStolenAlert(active=true) to the victim, and TheftState plus Waypoint("theft", drop-off, "DROP OFF") to the thief. It also fires a GlassBreak sound near the slot and an EventFeed line to everyone, and starts the victim's cooldown. If spawn or seat fails, the slot is handed back.
- complete(car): boolean. GarageService routes Stolen deliveries here. The transfer is atomic and has no yields. It checks the thief has a free slot (rate-limited Notify if not) and that the victim's record still matches. Then: GarageService.removeSlot(victim) -> GarageService.storeCar(thief), with rollback if the store fails. The victim gets the record's uncollected cash (DataService.addCash, reason "uncollected"). It increments thief stats.playerSteals and victim stats.timesRobbed, calls discover, and fires progress playerSteal plus deliverRare/deliverEpic. Both players are marked dirty and saved via task.spawn(DataService.saveNow). It plays the BigSteal effect ("ROBBED!") at the thief's new slot, posts an EventFeed line, and sends an Announce "HEIST!" for Legendary+. Alerts and waypoints are cleared and the car is destroyed. Returns true only when the car changed hands. GarageService increments stats.steals itself.
- fail(car | theftRecord, reason): boolean. Idempotent. Destroys the car (eject + VehicleService.destroy), then calls GarageService.restoreSlot exactly once; it skips the restore when the victim left (the record never left their data). Each side gets a reason-specific Notify. Reasons used: timeout, busted, wrecked, thief_left, victim_left, dropped, lost, error.
- recover(car, player?): boolean. Victim only. Called by the instant RecoverPrompt, or by GarageService when the victim drives the car into their own drop-off. Restores the slot, pays a RECOVERY_BONUS_SECONDS-of-income bonus (minimum $100), plays confetti and posts an EventFeed line.
- isBeingStolen(victim, slot): boolean. getActiveTheft(thief): Theft? (the record has .victim, .thief, .car, .slot, .carId, .mutation, .dropped, .endsAt ...).
- onThiefHit(attacker, target). Records the knockout time (used for the drop timer and an EventFeed line). Pays a revenge bonus of REVENGE_BONUS_SECONDS of income (minimum $100) in two cases, each paid once: the attacker is the victim of the target's active theft (once per theft), or the target robbed the attacker within the last 300s (once per robbery). Shows Notify "REVENGE!" and an EventFeed line.
- Extras: getTheftForCar(car), getActiveThefts(), cooldownLeft(victim), signals TheftStarted(theft) and TheftEnded(theft, outcome).
- Test hooks: _setHooks, _reset, _tick(now), _onDriverChanged, _onDestroyed, _onPlayerRemoving, _takeover, _canTakeover.
- Pure helpers: _canSteal(state) -> (ok, code, message), _cooldownLeft, _dropTimeout, _bonus, _takeoverDeadline, _failText.
- Model attributes on the stolen car: Kind="Stolen", TheftActive, TheftVictimUserId, TheftThiefUserId, TheftEndsAt (server time), Dropped, DroppedEndsAt.
- TheftState payload: {active, endsAt (Workspace:GetServerTimeNow based), carId, mutation, targetPlot, victimName, dropped, droppedEndsAt}.
- Dropped cars:
  - RecoverPrompt is TheftService's own prompt: hold 0.3, attribute OnlyUserId = victim.
  - The takeover prompt comes from VehicleService.addStealPrompt (actionText "Hotwire", hold 1.5, canSteal = not the victim + free slot + not driving, onStolen = the new player becomes the thief). It carries attribute HideForUserId = victim. If addStealPrompt is missing, TheftService creates its own "StealPrompt" and validates the hold itself.

DealershipService (server):
- 8 pads come from MapLayout.dealerPads(). Floor height is found by raycasting against Workspace.Map at init. It builds Workspace.Dealership containing Turntable1..8: dark cylinder discs with neon Rim<i> children and attributes PadIndex, Empty, Status ("sold" / "stolen" / ""), RestockAt (server time), CarId, TopY. It also builds the RestockSign model: Board with SurfaceGui "Display" > "Background" > Title / Countdown / Subtitle, on posts behind the back row at center + (0, 0, 41). The server updates the countdown text, and the subtitle shows a luck banner when EventService.getLuck() > 1.
- Restock: the whole floor every 240s, plus a single pad 30s after a sale or theft (or at the global restock if that comes first). Rolls use Rolls.car("dealer", EventService.getLuck()) and Rolls.mutation(1) with DealershipService._rng = Random.new(), avoid duplicate cars, and guarantee at least one Common per full restock.
- Display cars: CarBuilder.build(id, mutation, {forDisplay=true}). Only the chassis is anchored; the other parts stay welded to it, and any part not welded is anchored as a safety net. Tagged "DealerCar" with attributes CarId, Mutation, Rarity, Price, Income, PadIndex, RestockAt (server time), StealHold.
- Prompts in the chassis:
  - BuyPrompt: "Buy $X", hold 0.5, E / ButtonX. Flow: spend first -> storeCar -> refund ("refund") on failure; then discover, progress dealerBuy, markDirty, and saveNow for purchases of $50K or more.
  - StealPrompt: "Steal", hold = hotwireTime × DEALER_STEAL_HOLD_MULTIPLIER, F / ButtonY, attributes BaseHold and BaseHoldDuration. The server checks the hold time × the player's hotwire multiplier × 0.9. Flow: display destroyed -> VehicleService.spawn(..., "Loot", {source="dealer"}) -> seat -> addHeat(dealerSteal) -> progress steal; EventFeed line, plus BigSteal "HEIST!" for Legendary+.
- Hype on restock: Mythic/Secret get an Announce ("A SECRET Rubber Ducky just hit the Dealership!"), an EventFeed line, and a 45s Waypoint "dealer_rare<i>" for everyone. Legendary+ and Rainbow/Galaxy Epic+ get an EventFeed line.
- Extras: getStock(), secondsToRestock(), forceRestock(announce?), buildShowroom(parent, floorYs?) -> (turntables, board), buildSign(parent, baseCf), buildDisplay(carId, mutation, topCf) -> Model?.
- Pure helpers: _price (catalog price × mutation multiplier), _stealHold, _padRestockAt, _nextGlobal, _countdown, _rollStock, _hype, _setHooks.

DealershipClient (client):
- Spins each DealerCar locally around its pad (0.5 rad/s, within 260 studs). It sets chassis.CFrame when only the chassis is anchored, otherwise falls back to PivotTo.
- Billboards scale with distance (studs-based size): rarity pill, mutation label (rainbow gradient for Rainbow), name, price (green if affordable from the Cash attribute, red with a lock otherwise), +$/s, and "NEW STOCK IN m:ss" from RestockAt.
- Empty turntables show "SOLD! / STOLEN! / RESTOCKING" plus "NEW CAR IN m:ss".
- Epic+ cars get a pulsing neon ground ring and a PointLight in the rarity color. Legendary+ add sparkles; Secret cycles hue.
- StealPrompt.HoldDuration is scaled locally by the HoldMultiplier player attribute.
- Generic prompt-audience filter: any prompt under Workspace.Vehicles (or any shown prompt) with OnlyUserId or HideForUserId is disabled locally for the players who shouldn't see it.
- Pure helpers: _countdownText, _scaledHold, _audienceVisible, _displayColor.

### Contract deviations
- VehicleService does not exist yet, so all VehicleService calls are written against SPEC §6 and guarded with pcall. Assumptions: Car has .model, .chassis, .seat, .driver, .data and .kind. DriverChanged(car, newDriver, oldDriver) and Destroyed(car, reason) are VehicleService signals. addStealPrompt may or may not return the ProximityPrompt; when it doesn't, I find it by diffing the chassis descendants before and after the call. The canSteal callback returns (bool, string?). The theft heartbeat re-sets car.kind = "Stolen" each tick in case VehicleService's steal-prompt path converts the car to Loot.
- The Recover prompt is my own ProximityPrompt rather than a second VehicleService.addStealPrompt call. The spec says addStealPrompt makes "one ProximityPrompt in the chassis", so a second call might replace the takeover prompt. Recover is server-validated (victim only, hold, distance). The takeover prompt does use addStealPrompt.
- Which player sees which prompt is enforced client-side through the attributes OnlyUserId and HideForUserId, and the filter lives in DealershipClient because no TheftClient file is in my slice. The server re-checks every trigger, so this is cosmetic only.
- Victim waypoint: NotificationController already tracks the thief and the dropped car live on the client under waypoint id "stolen_car". TheftService therefore does not push victim positions and only clears that id when the theft ends; pushing positions would fight the client tracker. While a car is dropped the thief gets Waypoint("theft", car position, "GET BACK IN!"); otherwise they get the drop-off.
- Stricter than the spec on fairness: a victim can only have one car being stolen at a time ("They're already being robbed!"). The 25s cooldown is applied both when a theft starts and when it ends; the spec only says the cooldown starts at begin.
- Dropped-car timer uses two lengths. DROPPED_CAR_TIMEOUT (20s) applies when the thief was knocked out (stunned, dead, left the game, or hit within the last 3s). THEFT_ABANDON_LIMIT (12s) applies when the thief simply hopped out. The original thief can get back in through the Hotwire prompt, because they are "not the victim".
- A hijacker who takes over a theft gets at least 60s to deliver. The victim's CarStolenAlert is re-sent with the hijacker's name.
- Dealer price is catalog price × mutation multiplier. Without this, buying a Diamond, Rainbow or Galaxy car and selling it back (SELL_FRACTION × multiplier) would make a profit. The spec doesn't state the dealer price formula.
- Rewards contract progress "steal" is counted when the steal happens (player theft start and dealer steal), because no other system counts it. deliverRare and deliverEpic are also counted when a player theft completes; GarageService only counts those for Loot deliveries.
- Dealer display cars anchor only the chassis, with the other parts welded to it, so the client can spin a whole car with one CFrame write. GarageService's display cars anchor every part. As a safety net, any part whose AssemblyRootPart isn't the chassis after parenting is anchored, and the client then falls back to PivotTo.
- HoldMultiplier player attribute: nothing sets it server-side yet. Server validation computes the multiplier from the hotwire upgrade and the Master Thief pass (taking the min with the attribute when present), exactly as GarageService does. On the client, with no attribute set, the multiplier defaults to 1, which only makes the displayed hold longer.

### Known issues
- The VehicleService integration is untested because that module hasn't landed. Re-check that DriverChanged and Destroyed fire with (car, ...) and that addStealPrompt's canSteal/onStolen callback shapes match. If VehicleService changes car.kind after onStolen, the 0.5s heartbeat corrects it, so a takeover delivered within that half second could be treated as Loot.
- PlotService.pushOut (not my file) drags a car seated in a locked garage out to the driveway. If a victim locks their garage while a thief is still inside driving the stolen car, the lock helps the thief escape instead of trapping them. Suggested fix in PlotService: for cars with Kind="Stolen" whose TheftVictimUserId is the plot owner, eject the driver instead of moving the car.
- Dealer display safety pass: if AssemblyRootPart isn't computed yet right after parenting, every non-chassis part gets anchored. Nothing breaks: the client falls back to Model:PivotTo, which is slower, and WheelAnimator's wheel-weld edits wouldn't apply to dealer cars.
- The client billboards, ground glow and sign SurfaceGui can't be rendered headlessly, so only the 3D geometry was previewed. The billboard layout is studs-based (11x6.6) and still needs an in-Studio look.
- Sign placement assumes MapBuilder's showroom leaves space 41 studs behind the center and at least 19 studs of headroom. MapBuilder hasn't landed yet. If its back wall or roof is closer, adjust DealershipService.SIGN_OFFSET or SIGN_BOTTOM.
- Spinning dealer cars are client-local and keep their collision. On long cars (limo) the sweep can gently nudge a player standing on the turntable edge.
- Every global restock posts "NEW STOCK at the Dealership!" to the EventFeed, once every 4 minutes. Trim this if the feed feels busy.

### Verification
- selene on all 4 files: 0 errors, 0 warnings.
- stylua --check on all 4 files: clean.
- `lune run tests/run.luau`: 198 passed, 0 failed (24 of these are in tests/spec/theft.spec.luau). They cover:
  - _canSteal: every reason code, which check wins when several fail, and the message texts ("Garage locked!", "Your garage is full!", "Too new to rob (protected)", "try again in 12s").
  - A full theft lifecycle against mocked Garage/Data/Plot/Vehicle/Wanted/Rewards services: start; complete transfers exactly one car with its mutation; the victim keeps the uncollected cash; stats are updated and both players saved; no double transfer.
  - Fail and wreck restore the slot exactly once. A full thief garage blocks delivery and keeps the theft running. Only the current driver can deliver. Failed spawns hand the slot back.
  - Thief leaving restores the car; victim leaving keeps the record in their data.
  - Dropped cars: recover pays the bonus, timeout tows the car home, the two drop timers, the thief getting back in, and a hijack takeover.
  - Revenge pays once per theft and once per robbery. One theft per victim at a time, then the cooldown.
  - Dealership: price and steal hold (buy then sell is never profitable), restock timing (30s per pad vs the 240s global restock), countdown formatting, stock rolls (always a Common, mostly unique cars, retries avoid taken cars), hype levels, showroom and display builders built inside the test harness.
  - DealershipClient pure helpers.
- `rojo build`: succeeded.
- Rendered the showroom (8 turntables with neon rims, sample cars including Mythic and Secret, the countdown sign) with a scratch dump script plus tools/render.py. I looked at the iso, iso2, top and front views. Cars face the street, the sign stands behind the back row above car height, and the turntables line up with the pads. Saved to /home/user/HotwireCity/docs/previews/dealership.png.
- Re-read all files end to end and fixed: PrimaryPart is now always set in buildDisplay; the car is destroyed before the slot is restored so the rebuilt display never overlaps it; the tick handles a victim who went offline; mutation comparison is nil-safe; the takeover prompt lookup scans descendants; the victim waypoint no longer conflicts with NotificationController.

---
## Files: src/server/Systems/EventService.luau, src/server/Systems/RewardsService.luau, src/server/Systems/RebirthService.luau, src/server/Systems/ShopService.luau, src/client/Controllers/EventsClient.luau, tests/spec/rewards.spec.luau, docs/previews/hotdrop_events.png

### Public API
EventService (server). All client timestamps (startsAt/endsAt) are Workspace:GetServerTimeNow() seconds.
- getLuck(): number. Server Luck x2 times Rush Hour x2.5, never below 1.
- getIncomeMultiplier(): number. Returns 2 while 2x Cash is on.
- getTrafficMultiplier(): number. Returns 1.8 during Rush Hour.
- activateServerLuck(player?): boolean. Stacks 15 min onto any remaining time, Announces "🍀 <name> boosted SERVER LUCK!", never yields (safe inside ProcessReceipt).
- startEvent(name, player?): (boolean, string). Accepts "hotdrop"/"cashrain"/"rushhour"/"doublecash"/"luck" plus aliases ("hotDrop", "2x cash", "serverLuck", ...).
- Extras: startHotDrop(), startCashRain(), startRushHour(), startDoubleCash(), with force* aliases (AdminService probes these names); isActive(name), getState(), getHotDropState().
- Signals: Changed(state), HotDropClaimed(player, car).
- Remotes: EventState {rushHour?, doubleCash?, serverLuck?, cashRain?, hotDrop?}, values = endsAt; hotDrop is present only while the car is live. HotDropState: countdown {active=false, startsAt, position, carId, mutation}; live {active=true, position, carId, mutation, startsAt, endsAt}; ended {active=false}.
- Test helpers: _luck, _incomeMultiplier, _trafficMultiplier, _stack, _bagValue, _rollHotDrop, _pickDropIndex, _eventState, _resolveEvent, _buildBeacon(groundCF, color, text) -> Model (parts Pillar/Core/Ring/RingInner/Chevron/Glow/Label), _buildBag(pos) -> Part "CashBag", _inject.

RewardsService (server)
- progress(player, stat, amount?). amount defaults to 1; NaN, negative or zero is ignored. Completed contracts auto-claim: cash = max(500, reward seconds × income), plus Notify, Sound and CashBurst.
- isInGroup(player): boolean, cached; GroupId 0 → false.
- friendsInServer(player): number, cached and recomputed on join/leave.
- getDailyView(player) -> {streak, canClaim, nextDay}; getPlaytimeView(player) -> {claimed: {[string]: true}, sessionSeconds}; getContractsView(player) -> {day, list}. All three match the Types.Snapshot shapes.
- Remotes: ClaimDaily(), ClaimPlaytime(index), RedeemCode(code).
- Extras: claimDaily(player), claimPlaytime(player, index), redeemCode(player, code), grant(player, reward, reason) -> label, hasOpenContract(player, stat).
- Test helpers: _dailyClaim, _dailyView, _canClaimPlaytime, _normalizeCode, _rollContracts(userId, day), _contractReward, _incomeMinutesReward, _carFallbackCash, _offlineAmount, _applyProgress, _inject.

RebirthService (server)
- Rebirth remote.
- rebirth(player): (boolean, reason?). Public because AdminService calls it.
- canRebirth(player): (ok, cost, reason?).
- Test helpers: _canAfford, _rebirthMultiplier, _formatMultiplier, _plan(garage), _applyReset(data, capacity), _addPendingExclusive, _inject.

ShopService (server)
- Adds a "Gear Shop" ProximityPrompt to every part tagged GearShopCounter; triggering it fires OpenUI("GearShop") to that player.
- Remotes: BuyUpgrade(upgradeId), BuyTool(toolId); after BuyTool it calls CombatService.giveTools (lazy).
- Extras: buyUpgrade(player, id), buyTool(player, id), _upgradeQuote, _toolQuote, _inject.

EventsClient (client)
- init() and start(): builds the "EventsHUD" ScreenGui (pill row plus Hot Drop banner).
- Uses StateController.HotDropChanged/EventStateChanged when present, otherwise Net.listen.
- Sets the waypoint via WaypointController.set("hotdrop", position, color, "HOT DROP: <NAME>"); falls back to a local Beam.
- Helpers: pillText(name, secondsLeft), hotDropPhase(state, t), rarityColor(carId), carText(carId, mutation), waypointLabel(carId), Pills table.

### Contract deviations
- VehicleService.setKind is not in SPEC §6, but the task says to 'setKind Loot' on claim. EventService calls VehicleService.setKind(car, 'Loot') if it exists; otherwise it sets car.kind = 'Loot' and the model attribute Kind directly. The VehicleService owner should add setKind so its internal state stays consistent.
- The SPEC does not say what addStealPrompt returns. If it returns the prompt Instance, EventService destroys it on claim; otherwise any ProximityPrompt with attribute HotDropClaim=true is removed. If VehicleService does not remove its own steal prompt after onStolen, a leftover 'CLAIM HOT DROP' prompt can stay on the claimed car. It is harmless because canSteal rejects once the kind is not HotDrop. If addStealPrompt is missing or errors, EventService adds its own fallback prompt, which checks the hold time server-side.
- Nothing reports the contract stats 'steal', 'playerSteal', 'driftSeconds' or 'topSpeedHit' through progress() (GarageService increments stats.steals but never calls progress('steal')). RewardsService fills the gap: steal/playerSteal come from changes in data.stats.steals/playerSteals; drift seconds come from the chassis' sideways speed above Vehicle.DRIFT_SLIP_SPEED at 25+ studs/s; top speed counts when speed reaches topSpeed × 1.18, which needs nitro. Both are only sampled while such a contract is open. The first explicit progress() call for any of these stats switches its fallback off, so nothing is counted twice.
- Contract seed is Random.new(userId*7 + day), per the task text (SPEC §6 says userId + day). The roll also guarantees the 3 contracts track different stats (e.g. never steal5 and steal12 on the same day).
- Rebirth keeps the single best car (by income) plus every Robux-bought Exclusive car; the SPEC says only the best car. Exclusives that don't fit the reset capacity go to data.exclusives in MonetizationService's key format, so they roll in when a slot frees. Rebirth is also refused while any garage car is Driving or BeingStolen.
- Scheduling choices: the first auto event uses a shorter delay than the Config/Events intervals (hotDrop 150–240s, cashRain 300–480s, rushHour 240–420s, doubleCash 600–1200s). After that the config intervals apply. Auto events start at least 20s apart, and none fire within 60s of the first player joining an empty server.
- EventState includes hotDrop = endsAt only while the dropped car is live. The countdown is in HotDropState.startsAt. HotDropState countdown payloads also include carId and mutation (Remotes.luau allows them) so clients can show which car is coming.
- Server re-sends EventState and HotDropState to each player 6s after PlayerAdded and 2s after DataService.Loaded, because the first push can race client listeners.
- ShopService waits 30s for a part tagged GearShopCounter (MapBuilder now tags it). If none appears, it places a fallback counter at MapLayout.gearShopCounter() in Workspace.Effects and removes it if the real counter shows up later.
- RewardsService.progress no longer requires player to be a Player Instance (only non-nil); it is a server-internal API called by trusted systems and the tests use table fakes.
- Hot drop claim is refused while the player is driving or Stunned. Players with a full garage can still claim; GarageService then shows its 'Garage full' message at delivery.
- Offline earnings use DataService.getSessionInfo().previousLastOnline and isNew (DataService extras), falling back to data.lastOnline. The VIP rate replaces the base rate (it does not also apply the 2x VIP cash multiplier).

### Known issues
- VehicleService does not exist in the tree yet. The whole hot-drop runtime path (spawn → anchored drop-in → addStealPrompt → claim → seat) is written against SPEC §6 and has not run against the real VehicleService; it degrades with warnings if functions are missing.
- No Luau type checker (luau-lsp/luau-analyze) is installed, so --!strict typing is unchecked; only selene and the Lune runtime tests ran.
- Client GUI cannot be rendered headlessly, so the EventsHUD pill row (top-center, 78 design px from the top) and the Hot Drop banner were not seen. They may overlap HUDController's cash counter, which does not exist yet; adjust Position in EventsClient.buildUI once the HUD lands.
- The hot drop drop-in animation moves the anchored car with PivotTo on the server every Heartbeat for about 0.9s. This is a replicated one-off per drop, acceptable but not free.
- Collecting a cash bag by driving through it relies on the car model having attribute VehicleId and a DriverSeat (per the SPEC CarBuilder/VehicleService contract). On foot, Touched plus a 0.2s proximity poll (5.5 studs) handles pickup.
- WaypointController clears 'hotdrop' whenever HotDropState is not active, which includes the countdown. EventsClient re-sets it every 0.25s during the countdown, so the countdown waypoint can flicker for one tick on state pushes.
- Daily/Playtime/Codes/Contracts/Rebirth/Gear Shop UIs live in MenuController (not built yet); until then the remotes can only be exercised via AdminService or tests. ShopService fires OpenUI('GearShop'), which needs a MenuController listener.
- Referral rewards the inviter once per unique invitee, so alt accounts could farm Epic cars. Consider a per-inviter daily cap.
- Playtime gift timers are per session and restart on rejoin, as the spec intends.

### Verification
Commands were run from /home/user/HotwireCity.
- selene on all 5 source files: 0 errors, 0 warnings.
- stylua --check on all 5 source files plus the spec: clean.
- rojo build -o /tmp/claude-0/build-*.rbxlx: built successfully.
- lune run tests/run.luau: 243 passed, 0 failed. Per file: boot 28, carbuilder 18, clientcore 12, combat 16, data 24, garage 16, maplayout 8, police 26, rewards 44, shared 9, theft 24, vehicle 18.

tests/spec/rewards.spec.luau (44 tests) covers:
- Daily streak math: first claim, continue, reset after a missed day, 7-day wrap, double-claim and clock-skew refusal, and the view shape.
- Contracts: same roll for the same user and day; 3 unique ids with distinct stats across 40 users × 11 days; rolls vary between days; progress, auto-claim and no double pay; junk progress ignored.
- Playtime validation: early, on time, already claimed, bad indices (0, 1.5, "1", NaN, inf, table).
- Code normalization: case and whitespace insensitive; junk rejected.
- Offline earnings: under 60s skipped, base and VIP rates, 6h cap, rebirth multiplier, NaN and negative elapsed.
- Rebirth: best car kept, ties go to the lowest slot, empty garage falls back to the starter car, exclusives kept with overflow pending, affordability, multiplier label.
- Shop quotes.
- Event multipliers, luck stacking, bag value, event-name aliases, EventState filtering.
- Hot drop: 300 rolls are all Legendary or better, real and non-exclusive, with the mutation boost visible; drop points never repeat and skip blocked points.
- Beacon and bag geometry; EventsClient pure helpers in client mode.
- Flow tests with injected fake DataService, GarageService, Monetization and Plot services and a stubbed Net: claimDaily (cash, incomeMinutes, day-7 car, car→cash fallback when the garage is full), redeemCode, contract auto-claim, playtime, rebirth through GarageService and its refusals, shop purchases and their refusals.

Geometry was dumped from a scratchpad Lune script and rendered with tools/render.py, then checked visually. Two fixes came from that: the beam now starts 16 studs up so the landed car is visible, and the bag was reshaped into a tied money sack. Final preview: /home/user/HotwireCity/docs/previews/hotdrop_events.png.

Integration checks against the now-present WaypointController (set/clear/has signatures), NotificationController (Announce, OfflineEarnings, Notify kinds incl. 'money'), MapBuilder (GearShopCounter tag), AdminService (function names it probes), MonetizationService (activateServerLuck, exclusives key format) and CombatService.giveTools all match.
