# Hotwire City V2: Loop Engineering Breakdown (LOOP_V2_ENGINEERING)

- **Status:** 2026-10-27. Implementation plan for `docs/v2/design/LOOP_V2.md` revision 2. Where this document and LOOP_V2 disagree on a rule or number, LOOP_V2 wins; on file ownership, order and acceptance gates, this document wins.
- **Binding inputs:** `docs/v2/research/00_LEAD_DIRECTION.md`, `docs/v2/research/original_brief.md`.
- **Sibling plans:** `docs/v2/research/gta_combat.md` §13 (combat files and phases C0–C3), `docs/v2/research/gta_ui_language.md` (HUD, phone, menus), `docs/v2/research/roblox_tech.md` §8 (StreamingEnabled), the world workstream (`docs/v2/world/`, `Config/WorldLayout`, `Util/WorldQuery`, `Util/RoadGraph`).
- **Repository facts this plan relies on** (checked 2026-10-27):
  - Systems boot from the `ORDER` lists in `src/server/init.server.luau` and `src/client/init.client.luau`. A listed module that doesn't exist yet only warns, and unlisted modules load last, so the lists can land before the modules.
  - Tests: `lune run tests/run.luau [filter]` runs every `tests/spec/*.spec.luau`; `boot.spec` loads every system and controller headlessly; `DataService._internals.setStore` swaps in a fake DataStore.
  - v1 money calls: `DataService.addCash` / `spendCash` appear in 11 server files (Rebirth, Monetization, Event, Rewards, Shop, Wanted, Garage, Admin, Theft, Dealership, plus DataService itself). v1 data fields (`cash`, `garage`, `exclusives`, `pendingCars`, `upgrades`, `mutation`) are read in about 16 server systems and 11 client controllers. **The data change is therefore a cutover, not an incremental edit** (§1.3).

---

## 0. How to read this

Every work package (**WP**) lists:
- **Owns:** the files it may create or edit. **Each file has exactly one owner in this whole plan** (§8 is the index). Nobody else edits it; they call its public API or file a request to its owner.
- **Depends on:** packages whose merged API it needs.
- **Delivers:** modules and behaviour, by LOOP_V2 section.
- **Remotes:** the ones it handles (server) or listens to (client). Every remote name is *declared* by WP0 only.
- **Data fields:** the persisted `PlayerData` fields it is the single writer of (§5 is the index).
- **Tests:** the spec files it owns and what they must assert.
- **Done when:** the acceptance gate.

`(N)` = new file, `(C)` = changed v1 file, `(D)` = deleted at the end of the package.

---

## 1. Ground rules

### 1.1 Ownership

1. **One owner per file.** Ownership does not move between packages. A package that needs a change in a file it doesn't own asks that file's owner, who makes it in their package.
2. **Shared contracts have one owner: WP0.** `Types.luau`, `Remotes.luau`, `Net.luau`, every `Config/*.luau` the loop touches, `Config/Flags.luau`, both boot `ORDER` lists and `default.project.json` belong to WP0. WP0 lands the full V2 contract up front (all types, all remote names, all config keys with LOOP_V2 Appendix A values), so later packages rarely need an amendment. Amendments after M0 go through the WP0 owner and are small, serialized commits.
3. **Single writer per persisted field** (§5). Other systems read freely and write only through the owner's API.
4. **Files outside the loop** (world, art, vehicle physics, audio) are not owned here. Where the loop needs something from them, it is listed as a cross-workstream request (§7).

### 1.2 Code rules (from SPEC §4, plus V2)

- `--!strict`, ModuleScripts with `init()` / `start()`, lazy requires for back-edges.
- Rule-heavy logic lives in **pure modules** under `src/shared/Util/` with table-driven specs; services are thin wrappers that gather context, call the rule, and apply the result.
- Every remote handler: `Net.on(name, handler, rate)`, `Net.is*` validation (including the new `Net.isShape` and `Net.isArrayOf`), re-derive everything from server state.
- Every flagged feature checks `Config/Flags` in `start()` **and** in each remote handler.
- Hot per-second fields use the quiet paths (LOOP_V2 §9.1): no `DataSnapshot` per tick.
- No yield inside any ownership swap (§3 WP3).

### 1.3 Branches and milestones

- All loop work lands on the integration branch **`v2/loop`**. `main` stays playable v1 until the M1 cutover merges.
- **M0 Contracts** (WP0, WP1): types, remotes, config, pure rules. Mergeable on its own; it changes no behaviour except the contract spec.
- **M1 Cutover** (WP2–WP12 stage a, WP13 stage a, WP15 stage a): every system moves to V2 data and the money API in one merge, with the launch-core loop working (steal → deliver → drive for S× → carjack → lay-low → repo or keep → insurance; garage, Mod Shop, dealership, prestige, rewards on V2). The gate is §2 M1.
- **M2 Combat economy** (WP13 stages b–c, WP10 stage b): gta_combat C0–C1 with the LOOP deltas.
- **M3 Crime, clock and contacts** (WP12 stage b, WP14, WP15 stage b).
- **M4 Social and meta, behind flags** (WP16, WP17, WP18).
- A package with "stage a / stage b" delivers its cutover slice for M1 and its features in a later milestone. It still owns the same files throughout.

### 1.4 Calendar against the Nov 19 launch (23 days)

| Dates | Milestone | Notes |
|---|---|---|
| Oct 28–30 | M0 | WP0 first (one day), then WP1 |
| Oct 31–Nov 8 | M1 | WP2–WP12 in parallel against the M0 contract; integration and two-client tests Nov 7–8 |
| Nov 1–11 | M2 | Combat workstream runs C0–C1 in parallel; merges after M1 |
| Nov 9–14 | M3 | First Stage A–B playtest Nov 13 (telemetry-only watchdog) |
| Nov 10–14 | M4 heist | WP16 targets launch with `HEIST_ENABLED`; if its gate isn't met by Nov 14 it ships dark |
| Nov 15–18 | Freeze | Bug fixes only; publish Nov 18 |
| After launch | M4 rest | WP17 (trading, races, serials) and WP18 (crews, season, live ops) ship behind flags in weeks 1–4, matching the brief's fast-follow tier |

---

## 2. Milestone gates

| Gate | Must be true |
|---|---|
| **M0** | `lune run tests/run.luau` green. `contracts.spec` and every WP1 spec green. Boot spec loads every existing module. No behaviour change on `v2/loop`. |
| **M1** | All specs green, **including `money_api.spec`** (no `addCash` / `spendCash` anywhere under `src/`) and `transfer.spec`. Studio, two clients: (1) new profile → Mission 1 path or fallback → deliver → collect → drive own car with `STREET ×3` and ticking wallet, 60 s of driving fires 0 `DataSnapshot`; (2) carjack (after rookie opt-out) → lay-low → repo; (3) carjack → window ends → keep → insurance in the victim's bank; (4) victim leaves mid-window → thief keeps, victim's next join shows the insurance; (5) thief leaves mid-window → victim keeps; (6) publish-style shutdown with an open theft → victim keeps, nobody fined. |
| **M2** | gta_combat C0–C1 acceptance, plus: WASTED at 2★ takes 14% of the wallet and impounds the driven car; surrender < BUSTED < WASTED on the same wallet; combat-log at 1★ applied at release; nothing applied on shutdown. |
| **M3** | Stage A–B playtest lands within ±50% of LOOP_V2 §7.4 (G at 30 min, first Rare, Rep at 30 min). Every robbable POI shows open/closed. Truck bag label equals the payout. Payout breakdowns itemise every multiplier. |
| **M4 (each)** | The package's own gate (in its section) with its flag on in a private server, and the flag-off build unchanged. |

---

## 3. Work packages

### WP0 · Contracts and config (M0)

- **Owns:**
  - `src/shared/Types.luau` (C): the full LOOP_V2 §9.1 schema, including gta_combat §13.2 fields (`weapons`, `armor`, `medkits`, `combat`). v1-only types (`SlotRecord`, `MutationId`) are kept until M1 merges, then removed in a follow-up commit by this owner.
  - `src/shared/Remotes.luau` (C): every remote in LOOP_V2 §9.6 and gta_combat §13.2, plus a new `Unreliable` list (`MapBlips`, `ShotFx`, `PoliceShotFx`). Retired: `BuyUpgrade` and `BuyTool` (replaced by `BuySkill`, and by `BuyWeapon` and the gadget purchases from gta_combat). All other v1 remotes stay.
  - `src/shared/Net.luau` (C): `Net.isShape(v, spec)`, `Net.isArrayOf(v, fn, max)`, `Net.isUnit(v)`, creation of `UnreliableRemoteEvent`s, `Net.fireClientUnreliable`, `Net.fireNearUnreliable`.
  - `src/shared/Config/Flags.luau` (N), `Theft.luau` (N), `Crime.luau` (N), `Progression.luau` (N), `Upgrades.luau` (N), `Paint.luau` (N), `Districts.luau` (N; economy table + world-area → district id map, polygons come from `Config/WorldLayout`), `LiveOps.luau` (N), `Onboarding.luau` (N).
  - `src/shared/Config/Economy.luau` (C), `Rarity.luau` (C: `Finishes`, `Traits`; `Mutations` kept until M1, then removed), `Police.luau` (C: `Heat` + `HeatFloor` + gta_combat keys), `Monetization.luau` (C: LOOP_V2 §8 catalog).
  - `src/server/init.server.luau` (C), `src/client/init.client.luau` (C): full V2 `ORDER` lists (LOOP_V2 §9.5).
  - `default.project.json` (C): the `StarterCharacterScripts` mapping gta_combat §13.2 asks for.
  - `tests/spec/contracts.spec.luau` (N), `tests/spec/boot.spec.luau` (C, unchanged unless the harness needs new stubs).
- **Depends on:** nothing.
- **Remotes:** declares all; handles none.
- **Data fields:** none (defines the shapes).
- **Tests (`contracts.spec`):** remote names unique across all lists; `Net.isShape` rejects unknown and missing keys; `Net.isArrayOf` rejects sparse arrays and arrays over `max`; every `INSURANCE_RATES` value < `SELL_FRACTION`; `PLAYTIME_REWARDS` contains no Epic-or-better car; `HeatFloor` values ≤ `MAX_STARS`; `DEALER_REP` strictly increasing by rarity; every flag is a boolean; every LOOP_V2 Appendix A key exists with its value.
- **Done when:** M0 gate; the v1 game still boots on `v2/loop` (the new types compile beside the old ones).
- **Size:** M.

### WP1 · Pure rules (M0)

- **Owns:** `src/shared/Util/EconomyMath.luau` (C), `Rolls.luau` (C), `CarStats.luau` (N), `Payout.luau` (N), `TheftRules.luau` (N), `StreetGate.luau` (N), `Progression.luau` (N); specs `tests/spec/shared.spec.luau` (C), `carstats.spec.luau` (N), `payout.spec.luau` (N), `theftrules.spec.luau` (N), `streetgate.spec.luau` (N), `progression.spec.luau` (N).
- **Depends on:** WP0.
- **Delivers:**
  - `EconomyMath`: `carIncome`, `carValue`, `sellValue`, `chopValue` (loot and player cars), `insurance`, `G`, `garageMult` (LOOP_V2 §0.4, §2.6).
  - `Rolls`: `rarity(source, luck, rng, districtLuck?)` with luck < 1, `finish`, `trait`, `trunk`, probabilities for "1 in X" (§2.5, §2.5.1). Keeps a v1 `mutation` shim until M1 merges.
  - `CarStats.compute(def, record) -> {topSpeed, accel, grip, nitroTank, damageMult, tireMode}` (§2.4).
  - `Payout`: `crime(ctx) -> (amount, breakdown)` with soft caps, `truckBag`, `heistShares(crew, bags) ` (equal split, objectives, clamp, events after), `bounty`, `mostWanted` (claimer clamp), `wantedLoss(wallet, stars, loaded, byPlayer, surrendered)` returning `{loss, bounty, bag, destroyed}` (§3.1, §3.6, §3.7, §3.12, §4.3–4.4), `prestigeCost(n, G)`.
  - `TheftRules`: `ownerProtection(ctx) -> reason?`, `canKeep(ctx) -> (ok, reason)`, `countsAsLoss(carValue, bestValue)`, `insurancePayout(ctx)`, `rollLedger(ledger, now)`, `rollHour(hourly, now)`, `prunePairs(pairs, now)`, `revengePays(offenceCost, G)` (§2.7–2.8).
  - `StreetGate.new()`, `StreetGate.tick(state, sample, now) -> (paying, mult, xp, events)` over a 60-sample ring buffer: the six gates, fresh-road minutes (edge ids from `RoadGraph.nearestPoint`), stunt events, decay, 30 s out-of-car hold, caps (10 / 5 / 1.5 / 1), hot-ride thresholds (§2.2).
  - `Progression`: `xpToNext`, `repToNext`, `repFromTotal`, level caps (§2.3, §6.1).
- **Remotes / data fields:** none.
- **Tests:** one table row per LOOP_V2 §2.8 rule in `theftrules.spec` (each rule alone refuses, the first failing rule's reason is returned, exceptions for 3★ and REVENGE, counted-loss threshold at exactly 20%, low-Rep day cap, counterparty 72 h edge). `streetgate.spec`: idle cruise tops at ×4.5; a lapped loop stalls the time ramp; stunts cap at +1.5 per minute and +3 total; decay timing; 30 s hold; protected ×5; daily limit to ×1 with XP continuing; every gate (displacement, speed, road, zone, input, pause) stops payment. `payout.spec`: the §3.2 Stage C examples, the §3.7 crew-of-4 and solo examples, Golden Truck after clamp, Most Wanted G 50 vs G 40K example ($70K), wanted-loss ordering surrender < BUSTED < WASTED for 1–5★, soft cap ×0.25. `carstats.spec`: stage effects and the armor top-speed penalty. `shared.spec`: v1 cases updated to finishes.
- **Done when:** M0 gate.
- **Size:** L (the most valuable package to get right first).

### WP2 · Data core (M1)

- **Owns:** `src/server/Systems/DataService.luau` (C); `tests/spec/data.spec.luau` (C: DataService parts only; its Admin, Leaderboard and Monetization sections are deleted here and re-homed by WP3, WP8 and WP9); `tests/spec/money_api.spec.luau` (N).
- **Depends on:** WP0, WP1.
- **Delivers (LOOP_V2 §9.3, §9.5, §10.3):**
  - Store `HotwireCity_v2`, `SCHEMA_VERSION = 1`, `MIGRATIONS = {}`; `makeTemplate(userId)` (GUID starter car); `prepare(raw, now, userId)`; sanitize v2; `NO_MERGE` for `cars`, `owedCars`, `insured`, `pairs`, `retiredCars`.
  - **Forward-version guard** in `claimAsync`: stored `version > SCHEMA_VERSION` → transform returns nil, kick "Server updating, please rejoin".
  - Money API: `addWallet(p, n, reason, quiet?)`, `addBank`, `spend` (wallet then bank), `takeWallet`, `transferWallet`, `resetMoney(p, bank)` (prestige). **Delete `addCash` and `spendCash`.** `totalEarned` excludes the v1 `NON_EARNING_REASONS` plus deposits and transfers.
  - Generic counters: `incStat(p, key, n)`, `ledgerAdd(p, key, n) -> newValue`, `ledgerGet`, `hourAdd`, `pairMark(p, kind, otherUserId)`, `pairReady(p, kind, otherUserId, window)`; all roll through `TheftRules`.
  - `isShuttingDown()`; signal `Released(userId, savedOk)` after the final write; `Releasing(player, data)` documented as "mutate `data` directly".
  - `syncAttributes`: `Wallet`, `Bank`, `G`; snapshot builder for the V2 `Snapshot` (asks CarService, GarageService, RepService, RewardsService, TheftService lazily).
- **Remotes:** `GetSnapshot` (handles), `SetSetting`, `TutorialDone` (handles); `DataSnapshot` (fires).
- **Data fields (writer):** `version`, `wallet`, `bank`, `totalEarned`, `stats` (through `incStat`), `ledger`, `hourly`, `pairs`, `settings`, `tutorialDone`, `lastOnline`.
- **Tests:** `data.spec`: template twice through `prepare` is a no-op; a `version = 2` record is refused by the claim transform on the fake store; sanitize rows of LOOP_V2 §9.3 (place collisions → owed with `place = nil`, `owedCars` never truncated, unknown car → `retiredCars` with the full record); the worst-case profile (35 cars, full indexes, full ledgers) serializes under 100 KB; quiet `addWallet` never queues a snapshot (60 calls → 0 `DataSnapshot`); `Releasing` handlers see `data` while `loaded = false`. `money_api.spec`: scans every `src/**/*.luau` and fails on `addCash` or `spendCash` (this is the M1 gate, red until the cutover is complete).
- **Done when:** its specs green; `money_api.spec` green at M1.
- **Size:** M.

### WP3 · Cars, Rep, telemetry, districts, admin (M1)

- **Owns:** `src/server/Systems/CarService.luau` (N), `RepService.luau` (N), `EconomyTelemetry.luau` (N), `DistrictService.luau` (N), `AdminService.luau` (C); specs `carservice.spec.luau` (N), `transfer.spec.luau` (N), `rep.spec.luau` (N), `telemetry.spec.luau` (N), `admin.spec.luau` (N, re-homed from `data.spec`).
- **Depends on:** WP0, WP1, WP2.
- **Delivers:**
  - **CarService:** `mint(p, carId, opts)` (GUID uid, finish, trait, origin, `noInsurance` and 14-day lock for reward origins), `get`, `move`, `remove`, `deliverOwed`, `addDriveProgress(p, uid, studs, xp)` (quiet; fires `CarProgress`), `applyUpgrade`, `applyPaint`, `impoundInData(data, uid, now)` (for `Releasing` handlers), `recordInsurance(data, uid, amount, now)`, and **`transfer(fromP, toP, uid, kind, opts)`** exactly as LOOP_V2 §10.3: no-yield swap, `xferSeq`, `lastTransfer`, locks, `inbound`, giver-first saves, `inbound` clear on `saveNow(giver) == true` or on `DataService.Released(giverId, true)`, **insurance clawback** when an arriving uid is in the receiver's `insured`, and the on-load `inbound` resolution (`GetAsync` on the giver's key, drop the copy if the giver still has it). Logs the full record JSON on every transfer.
  - **RepService:** RP, levels, `has(p, unlockId)`, unlock notifications (`RepProgress`), the **starter latch** (`rep ≥ 8 and protection.activeSeconds ≥ 7,200`, or `TheftService.KeptOrChopped(thief)`), `Rep` attribute.
  - **EconomyTelemetry:** `log(p, flow, amount, sku, txType)` with one "Cash" currency and `endingBalance = wallet + bank`; no deposit events; `logDrive` (per drive, ≤ 1 per 60 s); anomaly scoring (LOOP_V2 §7.5.9); funnels.
  - **DistrictService:** `at(pos)`, `payoutMult`, `luck`, `policeFactor`, `responseDelay`, `District` attribute; reads areas from `Util/WorldQuery`.
  - **AdminService:** `/hc wallet|bank|rep|carlevel|upgrade|finish|audit|freeze|retire|restore` now (truck, heist, mostwanted, liveops subcommands are thin calls added by their owners' APIs; AdminService wires them as lazy calls). `restore` re-inserts a logged record into `owedCars` with a fresh `xferSeq`.
- **Remotes:** fires `CarProgress`, `RepProgress`, `Reveal` (via GarageService call). Handles `AdminCommand`.
- **Data fields (writer):** `cars` (structure, place, status, locks, `inbound`, `xferSeq`, `frozen`, progress through its API), `owedCars`, `discovered`, `finishIndex`, `insured`, `retiredCars`, `rep`, `repXp`, `protection.starterDone`.
- **Tests:** `transfer.spec` (two loaded fake profiles on `DataService._internals.setStore`): happy path clears `inbound`; giver save fails → receiver keeps `inbound`, can't sell/trade it; receiver reloads while the giver's stored profile still has the uid → copy dropped and logged; giver's stored profile lacks it → `inbound` cleared; no yield inside the swap (a coroutine check); clawback fires once and only inside 7 days; `xferSeq` increments. `carservice.spec`: 1,000 mints → unique GUIDs; owed delivery order; `impoundInData` and `recordInsurance` on a raw table. `rep.spec`: curve values from LOOP_V2 §6.1; latch never flips back. `telemetry.spec`: 60 street ticks → ≤ 1 analytics event; deposits not logged.
- **Done when:** specs green; M1 Studio checks (3)–(5) pass.
- **Size:** L.

### WP4 · Vehicles, spawns and movement (M1)

- **Owns:** `src/server/Systems/VehicleService.luau` (C), `StreetSpawnService.luau` (C), `TrafficService.luau` (C), `CharacterWatchdog.luau` (N); `src/client/Controllers/VehicleClient.luau` (C), `HotwireClient.luau` (N); specs `vehicleservice.spec.luau` (C), `watchdog.spec.luau` (N), `hotwire.spec.luau` (N).
- **Depends on:** WP0, WP1, WP3.
- **Delivers:**
  - **Stage a (M1):** `spawnFromRecord(record, cframe, kind)` writing `TopSpeed`, `Accel`, `Grip`, `NitroTank`, `DamageMult`, `TireMode`, `Finish`, `Bound`, `Level`, `Serial` attributes; VehicleClient reads them (never the local snapshot or `Config/Cars` for stats); per-car nitro and armor; the watchdog uses `TopSpeed`; **`tainted` (permanent) vs `pausedUntil` (income and XP)**; drive samples for StreetIncomeService (position, speed, input change, slip, wheel contact, nearby-car distances for near-misses, RoadGraph edge id); `addCarjackPrompt(car, opts)` with the normal and **fast-jack** conditions (2+ flat tires, HP < 30%, or < 2 studs/s for 1.5 s after a collision); hotwire **hold-and-release**: server-side `PromptButtonHoldBegan` / `PromptButtonHoldEnded`, per-hold green window sent by `HotwireWindow`, CLEAN on in-window release; StreetSpawnService and TrafficService move from `mutation` to `finish`, keep `trait` server-side (`car.data.trait`, never an attribute), district luck from DistrictService; **CharacterWatchdog** (taint only, exemptions, 3-in-5 s, `MoveGraceUntil`, telemetry-only under `WATCHDOG_ENFORCE = false`).
  - **Stage b (M3):** `TrafficService.scriptedStop(plotIndex)` for Mission 1 (a traffic car that stops at the plot's signal and offers JACK); the bullet-damage, wheel-hit and occupant-shielding entries gta_combat §13.2 asks of VehicleService and the holster-on-enter in VehicleClient (requested by WP13).
- **Remotes:** fires `HotwireWindow`; listens `VehicleFxState` (v1). Prompts need no remotes.
- **Data fields:** none persisted (car progress goes through WP3).
- **Tests:** `vehicleservice.spec`: attributes match `CarStats` for an upgraded record; a stolen upgraded car keeps its owner's stats; one violation sets `pausedUntil` but not `tainted`, a teleport delivery sets `tainted` permanently; fast-jack conditions. `hotwire.spec`: release inside the window (with ping slack) → CLEAN; outside → nothing; full hold → normal; never CLEAN on raids or carjacks. `watchdog.spec`: knockback, eject, cab teleport and hospital respawn with `MoveGraceUntil` never taint; 2 violations don't taint, 3 in 5 s do; enforce flag off → logs only.
- **Done when:** specs green; Studio: an upgraded car stolen by a second client drives with the upgraded top speed.
- **Size:** L.

### WP5 · Garage, street casino and banking (M1)

- **Owns:** `src/server/Systems/GarageService.luau` (C), `PlotService.luau` (C), `StreetIncomeService.luau` (N), `BankingService.luau` (N); `src/client/Controllers/GarageClient.luau` (C), `StreetHUD.luau` (N), `RevealController.luau` (N); specs `garage.spec.luau` (C), `plot.spec.luau` (C), `streetincome.spec.luau` (N), `banking.spec.luau` (N).
- **Depends on:** WP1, WP2, WP3, WP4, WP11 (blip API; lazy).
- **Delivers:**
  - **GarageService:** pads by uid, vault bays, the **lay-low pad**, display cars from records, `DriveCar(uid)`, `SellCar(uid)` (sell lock, `inbound`, frozen checks), `MoveCar`, `UnlockSlot`, collect pad (to bank), garage income on the **quiet** path, delivery: reveal (`Reveal`) and **trunk** (`Rolls.trunk`; magazine/armor/med-kit rolls call WP13 APIs when present, else pay cash), Mechanic (`CallMechanic`), `resetForPrestige(p)`. Chop handling moves to WP6.
  - **PlotService:** vault bays, lay-low pad, alarm and door levels (bought through WP9), garage safe zone, garage likes, **Go Home 10 s channel** (blocked while wanted, In Combat, LOADED or carrying loot), hospital respawn hook (gta_combat), `MoveGraceUntil` on every teleport it performs.
  - **StreetIncomeService:** one `StreetGate` per driver; quiet wallet ticks; `addDriveProgress`; `StuntEvent`; hot-ride heat (`WantedService.addHeat(p, 1, "flash")`) and the ×6 blip (BlipService); daily street seconds (`ledgerAdd("streetSeconds")`); protected cap from `TheftRules.ownerProtection` (via TheftService API); `StreetMult`, `StreetCap` attributes; per-drive telemetry.
  - **BankingService:** garage auto-deposit at 0★, ATM deposit (5%), `Loaded` attribute and LOADED blip, cash bags (`dropBag`, pickup validation, killer priority, 30 s expiry), and the **leave-time economy `Releasing` handler** in LOOP_V2 §10.3.6 order (shutdown → no penalty; combat-log loss via `Payout.wantedLoss` and `CarService.impoundInData`; LOADED leave fee; wallet → bank).
  - **Client:** GarageClient on uids; StreetHUD (S×, ramp bar, stunt popups, PROTECTED · ×5 MAX, daily limit label, LOADED, rookie pill and opt-out button); RevealController (reveal card, "street odds" wording for scripted cars, trunk line).
- **Remotes:** handles `DriveCar`, `SellCar`, `MoveCar`, `UnlockSlot`, `CallMechanic`, `GoHome`, `LockGarage` (v1); fires `Reveal`, `StuntEvent`, `CashPopup` (v1).
- **Data fields (writer):** `cars[uid].uncollected` (accrual and collect), `slotsUnlocked`, `likes`.
- **Tests:** `streetincome.spec`: service-level with a fake car: 60 ticks → wallet grows, 0 snapshots, 1 telemetry event; protected owner capped at 5; daily limit; flash heat interval at ×5 and ×8. `banking.spec`: leave-handler table (shutdown, 2★, In Combat + LOADED, LOADED at 0★ outside, LOADED inside own garage, plain) on a raw `data`; ATM fee; bag priority. `garage.spec` / `plot.spec`: v1 cases ported to uids; vault cars never raidable; Go Home blocked cases.
- **Done when:** specs green; M1 Studio check (1).
- **Size:** L.

### WP6 · Theft and chop (M1)

- **Owns:** `src/server/Systems/TheftService.luau` (C), `ChopShopService.luau` (N); specs `theft.spec.luau` (C: dealership parts re-homed to WP9), `theftflow.spec.luau` (N), `chop.spec.luau` (N), `leftovers.spec.luau` (C: v1 fix-phase cases are ported into `theftflow.spec`, `hud.spec` and `garage.spec` by their owners on request, then this file is **deleted**) (D).
- **Depends on:** WP1, WP2, WP3, WP4, WP5, WP11.
- **Delivers:**
  - Garage raid and **carjack** of `Owned` cars, both ending on the thief's lay-low pad; `keepable` decided by `TheftRules.canKeep` at begin and **re-checked at the final transfer**; `Stolen` vs `Joyride` kinds; `ProtectedReason` and `Shaken` attributes; spill only for LOADED victims (BankingService); 180 s carjack immunity; REVENGE marks with `offenceCost` (`RevengeState`); interceptor, revenge and repo rewards with their day caps and pairs; Tracker levels and Kill Switch (`KillSwitch`); stolen-car pulses and Tracker GPS through BlipService with per-viewer filters.
  - **Lay-low** (LOOP_V2 §2.7.4): record stays with the victim (runtime `LayLow`); repo cancels; window end → `CarService.transfer(victim, thief, uid, "theft")`, insurance via `TheftRules.insurancePayout` + `CarService.recordInsurance`; ledger and Shaken through `countsAsLoss`; `stats.thiefPoints` (+2 from the Crown holder).
  - `Releasing` handlers: victim leaving during delivery or the window **finalises** the transfer inside the victim's `data`; thief leaving cancels; shutdown resolves for the victim. No `PlayerRemoving` economy.
  - **ChopShopService:** loot chop (v1 rules moved from GarageService), the order board (3 orders per pulse, first 3 fills), player-car chop at loot `chopValue` with day cap, pair and hold rules, $0 between friends, counts as a loss, car to the victim's impound (JailService API, lazy).
  - Signals `TheftStarted`, `TheftEnded(theft, outcome)`, `KeptOrChopped(thief)` (RepService latch).
- **Remotes:** handles `KillSwitch`; fires `CarStolenAlert`, `TheftState`, `RevengeState`, `Waypoint` (v1).
- **Data fields (writer):** `protection.lastLossAt`; ledger keys `losses`, `insuranceClaims`, `playerCarChops`, `interceptors`, `revengePaid`, `repoPaid` (through WP2's ledger API).
- **Tests:** `theftflow.spec` against mocked systems: carjack → lay-low → repo (no data moved); carjack → window end → kept + insurance + 7-day locks + plate reset; victim leaves mid-window → finalised in `data` with insurance in the same table; thief leaves → cancelled; shutdown → victim keeps, no penalties; joyride when protected; re-check at window end refuses a keep that became illegal (e.g. victim reached the day cap through another thief). `chop.spec`: player-car chop pay, cap, friends → $0, counts as a loss. `theft.spec`: v1 lifecycle invariants (a car is never lost or duplicated) on uids.
- **Done when:** specs green; M1 Studio checks (2)–(6).
- **Size:** L.

### WP7 · Client core, HUD and phone (M1)

Delivered with the UI workstream (gta_ui_language §5); this package is the loop-facing slice.

- **Owns:** `src/client/Controllers/StateController.luau` (C), `HUDController.luau` (C), `MenuController.luau` (C), `NotificationController.luau` (C), `EffectsController.luau` (C), `WaypointController.luau` (C), `PhoneController.luau` (N), `PayoutLine.luau` (N); `src/shared/Util/Format.luau` (C); specs `hud.spec.luau` (C), `menus.spec.luau` (C), `clientcore.spec.luau` (C: its EventsClient cases re-homed to WP12).
- **Depends on:** WP0 (snapshot types); integrates WP5's StreetHUD.
- **Delivers:** V2 snapshot reading (wallet, bank, cars by uid, protection, limits); WALLET big and BANK small top-right; `PayoutBreakdown` line under the cash delta with the 3★+ wanted pulse; `CarStolenAlert` with `keepable`; MISSING / IMPOUNDED / IN REPAIR pad states; the pause-menu and garage list views on uids; `PhoneController.registerApp(id, builder)` so feature packages add apps (Jobs, Hot spots, Contacts, Store) **without editing PhoneController**.
- **Remotes:** listens `DataSnapshot`, `PayoutBreakdown`, `Notify`, `EventFeed`, `CarStolenAlert`, `Busted`, `Waypoint`.
- **Data fields:** none.
- **Tests:** `hud.spec`: wallet/bank formatting, breakdown line formatting (omits ×1, "(limit reached: reduced)"), pad state mapping. `menus.spec`: V2 rows (per-car upgrades, playtime tiles on active seconds). `clientcore.spec`: v1 helpers on the V2 snapshot.
- **Done when:** specs green; the HUD shows wallet, bank and payout lines in the M1 Studio run.
- **Size:** M.

### WP8 · Rewards, prestige and leaderboards (M1)

- **Owns:** `src/server/Systems/RewardsService.luau` (C), `RebirthService.luau` (C), `LeaderboardService.luau` (C), `src/server/Config/Codes.luau` (C); specs `rewards.spec.luau` (C: EventService and ShopService cases re-homed to WP12 and WP13), `prestige.spec.luau` (N), `leaderboard.spec.luau` (N, re-homed from `data.spec`).
- **Depends on:** WP1, WP2, WP3.
- **Delivers:** rewards to the **bank**; V2 `PLAYTIME_REWARDS` on **active seconds** (`playtime.activeSeconds`, and lifetime `protection.activeSeconds` for the starter latch); reward cars through `CarService.mint` with `noInsurance` and the 14-day lock; referral inviter cap 1; daily streak **pauses**; contracts with the new stats; weekly contracts. Prestige: `Payout.prestigeCost`, keep 3 chosen (`Rebirth(keepUids)`), bound kept, `GarageService.resetForPrestige`, `DataService.resetMoney`. Leaderboards: §5.6 boards and weekly keys; **Server Crown** (net worth, 3+ players, 5% hysteresis, `ServerCrown` attribute, Crown blip through BlipService, feed card).
- **Remotes:** handles `ClaimDaily`, `ClaimPlaytime`, `RedeemCode`, `RerollContract`, `Rebirth`, `GetLeaderboard`; fires `OfflineEarnings` (v1).
- **Data fields (writer):** `daily`, `contracts`, `weekly`, `codes`, `playtime`, `protection.activeSeconds`, `referralRewarded`, `rebirths`; ledger key `referralsPaid`.
- **Tests:** `rewards.spec`: active-second counting (idle player accrues 0), V2 gift table, streak pause, reward-origin flags. `prestige.spec`: cost = max(ladder, 10,800 s × G); keeps 3 + bound; vault counts toward 3; blocked with a car in a lay-low window. `leaderboard.spec`: v1 encoding cases; Crown hysteresis and the 3-player minimum.
- **Done when:** specs green.
- **Size:** M.

### WP9 · Commerce: monetization, dealership and Mod Shop (M1)

- **Owns:** `src/server/Systems/MonetizationService.luau` (C), `DealershipService.luau` (C), `ModShopService.luau` (N); `src/client/Controllers/DealershipClient.luau` (C), `ModShopClient.luau` (N); specs `dealership.spec.luau` (C), `modshop.spec.luau` (N), `monetization.spec.luau` (N, re-homed from `data.spec`).
- **Depends on:** WP1, WP2, WP3.
- **Delivers:** the LOOP_V2 §8 catalog; `giftedPasses`; bound-car grants into `owedCars`; refusal rules (Lockdown during a theft, Lose the Cops limits); **Double It** (last eligible payout remembered 30 s, `min(share, 300 s × G)`, once per day, refused under event multipliers). Dealership: restock on the pulse (EventClock when present, else its own 300 s timer), CarRecords through `CarService.mint`, **`DEALER_REP` purchase gates**, hero stand. ModShopService: per-car tracks with level gates and `upgradeSpend` (§2.4), garage security (§2.7.3), Hotwire Kit (`BuySkill`), paint with vouchers and the palette, plates (filtered).
- **Remotes:** handles `ModShopBuy`, `BuySecurity`, `BuySkill`, `ApplyPaint` (`Net.isShape`), `SetPlate`.
- **Data fields (writer):** `receipts`, `giftedPasses`, `security`, `skills`, `vouchers`; car `upgrades`, `upgradeSpend`, `paint` through `CarService.applyUpgrade/applyPaint`.
- **Tests:** `modshop.spec`: price formula, level gates, Common cap stops Engine at stage 4, 60% of spend into value, palette rejection, voucher use. `dealership.spec`: Rep gates refuse buying but not stealing. `monetization.spec`: receipt idempotency (v1), Double It cap and refusal cases.
- **Done when:** specs green.
- **Size:** M.

### WP10 · Wanted, police and jail (M1 port, M2 features; combat workstream)

Owned by the combat workstream because gta_combat C1 rewrites the same files; the loop deltas below are part of its scope.

- **Owns:** `src/server/Systems/WantedService.luau` (C), `PoliceService.luau` (C), `JailService.luau` (N); specs `police.spec.luau` (C), `jail.spec.luau` (N).
- **Depends on:** WP1, WP2, WP3, WP4.
- **Delivers:**
  - **Stage a (M1):** money port (`spend`, `takeWallet`); BUSTED wallet loss `0.07 × stars` (surrender halves) through `Payout.wantedLoss`; impound to JailService (120 s free, fee, break-out +2★) and repair (60 s); `raiseTo(p, n, reason)` + `HeatFloor`; evade bonus with the persisted hourly soft cap; Lawyer (`CallLawyer`); district police factors and response delays; `tutorialChase` (scripted 2★, units that can't bust or shoot).
  - **Stage b (M2):** gta_combat C1 evade model; 5★ Most Wanted trigger, survival payout (2 per day, `isSeen` history), and the hand-off to DamageService for claims.
- **Remotes:** handles `RetrieveImpound`, `RushRepair`, `CallLawyer`, `Surrender` (gta_combat); fires `Busted`.
- **Data fields (writer):** ledger keys `survivalPaid`; hourly key `evadesPaid`.
- **Tests:** `police.spec`: `raiseTo` never lowers and never stacks; store at 0★ ends at 2★, pawn at 0★ at 3★ (not 5★); bust loss by stars; evade soft cap after 6 per rolling hour survives a simulated rejoin. `jail.spec`: impound and repair timers and fees.
- **Done when:** stage a specs green at M1; M2 gate.
- **Size:** M (stage a) + gta_combat C1.

### WP11 · Blips and map (M1)

- **Owns:** `src/server/Systems/BlipService.luau` (N); `src/client/Controllers/MinimapController.luau` (C), `MapScreenController.luau` (C); `src/shared/Config/Minimap.luau` (C); specs `minimap.spec.luau` (C), `blips.spec.luau` (N).
- **Depends on:** WP0.
- **Delivers:** `BlipService.set(id, kind, getPos, filter)` / `clear(id)`; per-viewer filtering; 2 Hz `MapBlips` on the unreliable channel, ≤ 40 entries, ≈ 10 KB/s per server; kinds `loaded`, `hotride`, `stolen`, `tracker`, `mostWanted`, `bag`, `truck`, `party`, `revenge`, `crown`. Minimap and full map render `MapBlips` (no Workspace scans for far objects) and `CrimeState` icons (lit / grey with countdown).
- **Remotes:** fires `MapBlips`; listens `MapBlips`, `CrimeState`.
- **Data fields:** none.
- **Tests:** `blips.spec`: Tracker GPS only to the victim and party; revenge only to the holder; cap at 40 by priority (Most Wanted and own party first); payload size estimate under 10 KB/s for 8 viewers. `minimap.spec`: v1 math plus blip-kind rendering from a payload.
- **Done when:** specs green; Studio: a LOADED player on the far side of the map shows on another client's minimap with streaming on.
- **Size:** M.

### WP12 · Server clock, events and the armored truck (M1 port, M3 features)

- **Owns:** `src/server/Systems/EventService.luau` (C), `EventClock.luau` (N), `ArmoredTruckService.luau` (N); `src/client/Controllers/EventsClient.luau` (C), `TruckClient.luau` (N); specs `events.spec.luau` (N, re-homed from `rewards.spec`), `eventclock.spec.luau` (N), `truck.spec.luau` (N).
- **Depends on:** WP2, WP3 (stage a); WP4, WP5, WP10, WP11, WP13 (stage b).
- **Delivers:**
  - **Stage a (M1):** Cash Rain to the **wallet** (`addWallet`, not the bank); `mutation` → `finish`; Hot Drop interval {600, 900}; Hot Drop cars through `CarService.mint` on delivery.
  - **Stage b (M3):** EventClock (300 s pulse, 1,800 s big pulse with a 600 s window, `PulseState`, signals `Pulse` and `BigPulse`); dealership restock and order-board refresh on `Pulse`. ArmoredTruckService: route, HP and tires, guards (NPCService API), crack with `raiseTo(3)`, 4 bags (server parts), carrier slow-down, bag blips, delivery pay through `Payout.truckBag` with **event multiplier after the clamp**, 12 full-pay bags per rolling hour then ×0.25, rookie confirm prompt. TruckClient shows each viewer's own bag value from `TruckState.bagBase` and its own `G`.
- **Remotes:** fires `EventState`, `HotDropState` (v1), `PulseState`, `TruckState`.
- **Data fields (writer):** hourly key `truckBags`.
- **Tests:** `events.spec`: Cash Rain lands in the wallet. `eventclock.spec`: pulse schedule and window. `truck.spec`: bag value clamp, Golden ×5 after clamp, soft cap, label equals payout for low and high G.
- **Done when:** stage a at M1; stage b at M3 (truck run end to end with 3 clients).
- **Size:** S (a) + L (b).

### WP13 · Combat (combat workstream: gta_combat C0–C3 plus loop deltas) (M1 port, M2 features)

- **Owns:** every file gta_combat §13.1 adds (`WeaponService`, `DamageService`, `HitboxHistory`, `PoliceCombatService`, `Config/Weapons`, `Config/Animations`, `Shared/Combat/*`, `WeaponClient`, `ShoulderCamera`, `WeaponWheel`, `CombatHUD`, `DeathScreenController`, `ShotFxController`, `GunShopUI`, their specs) and these changed files: `src/server/Systems/CombatService.luau`, `NPCService.luau`, `ShopService.luau`, `src/client/Controllers/CombatClient.luau`, `SoundController.luau`, `src/shared/Config/Sounds.luau`, `tests/spec/combat.spec.luau`, `tests/spec/npc.spec.luau` (C), plus `tests/spec/shop.spec.luau` (N, re-homed from `rewards.spec`) and `tests/spec/combateconomy.spec.luau` (N).
- **Depends on:** WP0, WP2 (stage a); WP4, WP5, WP6, WP10 (stage b).
- **Delivers:**
  - **Stage a (M1):** ShopService and CombatService on the V2 money API and V2 `tools` / `weapons` shapes.
  - **Stage b (M2), loop deltas D1–D14:** weapon Rep gates (AR 10, Carbine 14); hospital bill from both pools; **WASTED wallet loss** (`Payout.wantedLoss`: wanted share, bounty first, LOADED bag second via `BankingService.dropBag`, rest destroyed) and impound of the driven car when wanted; Most Wanted claims with the claimer clamp; street bounty; party friendly-fire off (PartyService API, lazy); rookie 600 s with `RookieOptOut` and the HUD pill data; Passive limits (D8); Menace payout halving; `TheftService.onThiefDowned` for drops and interceptor rewards; REVENGE trigger on downs; trunk-loot grants `grantMagazine`, `grantArmor`, `grantMedkit` for WP5; `MoveGraceUntil` on knockback and ragdoll.
  - **Stage c (M3+):** gta_combat C2–C3.
- **Remotes:** gta_combat §13.2 list, `RookieOptOut`, `SetPassive`; fires `Wasted` with the loop fields.
- **Data fields (writer):** `weapons`, `tools`, `armor`, `medkits`, `combat`; ledger key `mostWantedClaims`.
- **Tests:** gta_combat §13.1 specs; `combateconomy.spec`: WASTED loss table for 0–5★ × LOADED × killer kind; bounty paid before the bag; rookies free of the hospital bill; Most Wanted claim refused for friends.
- **Done when:** M2 gate.
- **Size:** per gta_combat (XL); loop deltas M.

### WP14 · Crime sandbox (M3)

- **Owns:** `src/server/Systems/RobberyService.luau` (N); `src/client/Controllers/HotSpotsApp.luau` (N); specs `robbery.spec.luau` (N).
- **Depends on:** WP1, WP5, WP10, WP11, WP13.
- **Delivers:** stores, gas stations and the pawn shop (gun check, fill, Brave clerk, floors), ATM hack (server-seeded mini-game, `MiniGameInput`), the jewelry store, NPC and player mugging, `PayoutBreakdown` on every payout, **`CrimeState`** (full on join, deltas after), and the Phone › Jobs › Hot spots app (registered through `PhoneController.registerApp`).
- **Remotes:** handles `MiniGameInput`; fires `CrimeState`, `PayoutBreakdown`.
- **Data fields (writer):** `stats.robberies` (through `incStat`).
- **Tests:** `robbery.spec`: Stage C examples from LOOP_V2 §3.2; heat floors per POI; per-store and per-player cooldowns; mini-game rejects late and wrong steps; mug immunity 120 s; `CrimeState` reopen times.
- **Done when:** specs green; M3 gate items for POIs and breakdowns.
- **Size:** L.

### WP15 · Contacts: onboarding and phone jobs (M1 port, M3 features)

- **Owns:** `src/server/Systems/OnboardingService.luau` (N), `JobsService.luau` (N); `src/client/Controllers/MissionController.luau` (N), `TutorialController.luau` (C, then D); specs `onboarding.spec.luau` (N), `jobs.spec.luau` (N).
- **Depends on:** WP4 (stage b), WP6, WP7, WP10, WP12 (stage b), WP14.
- **Delivers:**
  - **Stage a (M1):** TutorialController reads the V2 snapshot (cars by uid) so the v1 tutorial still runs until stage b.
  - **Stage b (M3):** Missions 1–4 from `Config/Onboarding` (scripted JACK at the plot's signal with the v1 newbie-car fallback, guaranteed Gold Common with `scripted = true` on the reveal, scripted 2★ chase, blue-car chop order, gun gift, store, casino at ~8 min), `MissionState` and MISSION PASSED shards, help-text gating (wallet help at the first LOADED or at rookie end), the starter-pack offer beat. Phone jobs (§3.10) with checkpoints, `minTravelTime`, 20 full-pay per day then ×0.25. **TutorialController is deleted** once MissionController covers its beats.
- **Remotes:** handles `JobAccept`, `JobAbandon`; fires `MissionState`.
- **Data fields (writer):** `onboarding`; ledger key `jobsPaid`.
- **Tests:** `onboarding.spec`: mission state machine and fallbacks; flags set once; wallet help gating. `jobs.spec`: soft cap; checkpoint order and travel time.
- **Done when:** M3 gate; a fresh profile reaches MISSION PASSED ×4 in under 10 minutes in Studio.
- **Size:** M.

### WP16 · Party and heist (M4; `HEIST_ENABLED` targeted for launch)

- **Owns:** `src/server/Systems/PartyService.luau` (N), `HeistService.luau` (N); `src/client/Controllers/PartyClient.luau` (N), `HeistClient.luau` (N), `QuickChatWheel.luau` (N); specs `party.spec.luau` (N), `heist.spec.luau` (N).
- **Depends on:** WP5, WP11, WP12 (stage b), WP13, WP14.
- **Delivers:** parties (invites, waypoint, friendly-fire flag for DamageService, party mult, `PartyId`, Invite friend through `SocialService:PromptGameInvite` on the client); quick chat and emotes. Heist per LOOP_V2 §3.7: gate (leader Rep 10, members Rep 3, rookies with prompt, crew 1–4), 60 s lobby, roles, stages with `raiseTo(3)` and `raiseTo(4)`, 2 bags per member, `Payout.heistShares` (equal split, objectives to completers, clamp, events after, overflow destroyed), kit refund only after the drill, window reopen after an early fail, AFK rule.
- **Remotes:** handles `PartyInvite`, `PartyRespond`, `PartyLeave`, `PartyKick`, `MapPing`, `QuickChat`, `Emote`, `HeistStart`, `HeistReady`, `HeistLeave`, `HeistRole`; fires `PartyState`, `QuickChatRelay`, `HeistState`, `Invite`.
- **Data fields:** stats `heists` (through `incStat`).
- **Tests:** `heist.spec`: solo and crew-of-4 Stage C examples; clamp on a G 50 member; kit refund and reopen cases; AFK member gets no share; one heist per window. `party.spec`: invite expiry, max 4.
- **Done when:** a 4-player heist and a solo heist end to end in Studio with the flag on; flag off → no heist UI and the bank POI shows closed.
- **Size:** L.

### WP17 · Trading, races and serials (M4, after launch)

- **Owns:** `src/server/Systems/TradeService.luau` (N), `RaceService.luau` (N), `SerialService.luau` (N); `src/client/Controllers/TradeClient.luau` (N), `RaceClient.luau` (N); specs `trade.spec.luau` (N), `race.spec.luau` (N), `serial.spec.luau` (N).
- **Depends on:** WP3 (transfer), WP4, WP9 (values), WP11.
- **Delivers:** trade sessions with Ready reset, uneven warning, **net-out cap**, eligibility (account age, playtime, `IsPaidItemTradingAllowed`), swap through `CarService.transfer` (§10.3.4), `HC_TradeLog_v1`; races, house prizes with soft cap and hard pair cap, time trials; pink slips (flag, trade eligibility, 7-day pair cooldown, net-out); SerialService mint (`HC_Serials_v1`), registry `{ownerUserId, uid, xferSeq}`, load-time verify with repair or **freeze and flag**.
- **Remotes:** handles `TradeRequest`, `TradeRespond`, `TradeOffer` (`Net.isArrayOf`), `TradeReady`, `TradeConfirm`, `TradeCancel`, `RaceChallenge`, `RaceRespond`; fires `TradeState`, `RaceState`, `Invite`.
- **Data fields (writer):** ledger keys `tradeNetOut`, `pinkSlipLosses`, `raceWinsPaid`; stats `racesWon`, `pinkSlipsWon`.
- **Tests:** `trade.spec`: offer change resets Ready; net-out refusal; counterparty lock recorded; swap atomic on the fake store with both `inbound` paths. `serial.spec`: registry newer/older/different-uid cases → repair / freeze / freeze; never retires. `race.spec`: checkpoints, taint disqualifies, caps.
- **Done when:** trade dupe tests green; flags on in a private server.
- **Size:** L.

### WP18 · Crews, season and live ops (M4, after launch)

- **Owns:** `src/server/Systems/CrewService.luau` (N), `SeasonService.luau` (N), `LiveOpsService.luau` (N); `src/client/Controllers/PhotoModeController.luau` (N); specs `crew.spec.luau` (N), `season.spec.luau` (N), `liveops.spec.luau` (N).
- **Depends on:** WP8, WP12.
- **Delivers:** crews (`HC_Crews_v1` roster wins over `PlayerData.crew`, name and tag claims in `HC_CrewNames_v1`, ranks, weekly crew RP and contract); Street Pass (tiers, claims, honest dates); LiveOps (weekend rotation, Admin Abuse via MessagingService `HC_LiveOps`, `HC_LiveConfig_v1` read every 5 min with clamps, **flags can only be turned off** at runtime, weather requests to LightingService); photo mode.
- **Remotes:** handles `CrewCreate`, `CrewInvite`, `CrewRespond`, `CrewLeave`, `CrewKick`, `CrewPromote`, `ClaimSeasonTier`; fires `CrewState`, `LiveOpsState`.
- **Data fields (writer):** `crew`, `season`.
- **Tests:** `crew.spec`: duplicate name refused; roster wins on join. `liveops.spec`: clamps (multipliers 1–5, durations ≤ 3 h), flag kill-switch only turns off. `season.spec`: tier math, no paid skips.
- **Done when:** flags on in a private server.
- **Size:** L.

---

## 4. Dependency order

```
M0   WP0 ──► WP1
              │
M1            ├──► WP2 ──► WP3 ──► WP4 ──► WP5 ──► WP6
              │            │       │
              │            ├──► WP8, WP9, WP10a, WP12a, WP13a, WP15a
              └──► WP11 (needs only WP0)      WP7 (needs only WP0; integrates WP5's HUD)
                         ── M1 gate: all of the above merged together ──
M2   WP13b ◄── WP4, WP5, WP6, WP10a          WP10b ◄── WP13b
M3   WP12b ◄── WP4, WP5, WP10, WP11, WP13b   WP14 ◄── WP10, WP11, WP13b   WP15b ◄── WP4b, WP6, WP12b, WP14
M4   WP16 ◄── WP12b, WP13b, WP14   WP17 ◄── WP3, WP9, WP11   WP18 ◄── WP8, WP12b
```

**Critical path to launch:** WP0 → WP1 → WP2 → WP3 → WP4 → WP5 → WP6 → M1 gate → WP13b (M2) → WP14 → WP15b (M3). WP7, WP8, WP9, WP11 and WP12a run in parallel inside M1 and are not on the critical path unless they slip past Nov 8.

---

## 5. Persisted fields: single writer

| `PlayerData` field | Writer (package · module) | Everyone else |
|---|---|---|
| `version`, `wallet`, `bank`, `totalEarned`, `settings`, `tutorialDone`, `lastOnline` | WP2 · DataService (money API) | Call the money API |
| `stats.*` | WP2 · DataService `incStat` | Call `incStat` |
| `ledger`, `hourly`, `pairs` | WP2 · DataService `ledgerAdd` / `hourAdd` / `pairMark` | Call the API with their own keys (key owners below) |
| `cars` (structure, place, status, locks, `inbound`, `xferSeq`, `frozen`, `lastTransfer`), `owedCars`, `discovered`, `finishIndex`, `insured`, `retiredCars` | WP3 · CarService | `CarService` API; `Releasing` handlers use `impoundInData` / `recordInsurance` |
| `cars[uid].xp`, `level`, `mileage` | WP3 · CarService `addDriveProgress` (called by WP5) | — |
| `cars[uid].upgrades`, `upgradeSpend`, `paint` | WP3 · CarService `applyUpgrade` / `applyPaint` (called by WP9) | — |
| `cars[uid].uncollected` | WP5 · GarageService | — |
| `rep`, `repXp`, `protection.starterDone` | WP3 · RepService | — |
| `protection.activeSeconds`, `playtime`, `daily`, `contracts`, `weekly`, `codes`, `referralRewarded`, `rebirths` | WP8 · RewardsService / RebirthService | — |
| `protection.lastLossAt` | WP6 · TheftService | — |
| `slotsUnlocked`, `likes` | WP5 · GarageService / PlotService | `GarageService.resetForPrestige` |
| `receipts`, `giftedPasses`, `security`, `skills`, `vouchers` | WP9 · MonetizationService / ModShopService | `ModShopService.grantVoucher` (trunk) |
| `weapons`, `tools`, `armor`, `medkits`, `combat` | WP13 · WeaponService / DamageService / ShopService | `grantMagazine`, `grantArmor`, `grantMedkit` |
| `onboarding` | WP15 · OnboardingService | — |
| `crew`, `season` | WP18 · CrewService / SeasonService | — |

**Ledger key owners:** `losses`, `insuranceClaims`, `playerCarChops`, `interceptors`, `revengePaid`, `repoPaid` → WP6; `survivalPaid` → WP10; `mostWantedClaims` → WP13; `jobsPaid` → WP15; `raceWinsPaid`, `pinkSlipLosses`, `tradeNetOut` → WP17; `doubleIt` → WP9; `streetSeconds` → WP5; `referralsPaid` → WP8. **Hourly:** `evadesPaid` → WP10; `truckBags` → WP12.

---

## 6. DataStores

Budget per server at 8 players: 60 + 10 × 8 = 140 writes per minute and the same for reads (Roblox standard limits); the loop below uses well under half.

| Store | Key pattern | Writer | Reads per join | Writes per minute at 8 players | Source of truth |
|---|---|---|---|---|---|
| `HotwireCity_v2` | `p_<userId>` | WP2 DataService (`UpdateAsync` claim, autosave 120 s, leave, `saveNow` after transfers) | 1 claim + rare `GetAsync` of a giver's key for an `inbound` car | ≈ 4 autosaves + transfers (≤ 2 each) + leaves | The profile |
| `HC_LimitedRegistry_v1` | `<carId>#<serial>` | WP17 SerialService | 1 per serial car owned | Per serial transfer (rare) | The record's `xferSeq` when newer; otherwise the registry |
| `HC_Serials_v1` | `<carId>` | WP17 SerialService | 0 | Per limited mint (event-only) | Next serial counter |
| `HC_Crews_v1` | `<crewId>` | WP18 CrewService | 1 if in a crew | Roster change + weekly RP flush every 5 min | **The roster** (over `PlayerData.crew`) |
| `HC_CrewNames_v1` | `n_<lower(name)>`, `t_<lower(tag)>` | WP18 CrewService | 0 | On create or rename | Name and tag claim |
| `HC_TradeLog_v1` | `<tradeId>` | WP17 TradeService | 0 | Per trade | Audit only |
| `HC_LiveConfig_v1` | `current` | Ops (AdminService command or Studio) | 1 per server every 5 min | 0 from servers | Live multipliers and flag kill-switches |
| OrderedDataStores `LB_netWorth_v1` (+ weekly), `LB_mostWanted_v1`, `LB_thefts_v1`, `LB_likes_v1`, `LB_race_<route>_v1`, `LB_crewRep_v1`, v1 `totalEarned`, `steals` | userId / crewId (weekly keys with an ISO-week suffix) | WP8 LeaderboardService (WP17 races, WP18 crews) | 0 per join; board refresh every 60 s per server | On leave + every 5 min if changed | The boards |

Removed from revision 1: `HC_Mail_v1`, `HC_Escrow_v1` (no V2.0 flow writes across servers, LOOP_V2 §10.3). The v1 store `HotwireCity_v1` is never read.

---

## 7. Cross-workstream requests

| To | Request | Needed by |
|---|---|---|
| World (`Config/WorldLayout`, `Util/WorldQuery`, `Util/RoadGraph`, MapBuilder) | District areas for `DistrictService.at(pos)` (LOOP_V2 §6.2 mapping); POIs: stores, gas stations, ATMs, pawn, jewelry, bank back door, impound lot, Police HQ cell, hospitals, Docks safe house, race starts; a traffic signal within 150 studs of each garage plot; `RoadGraph.nearestPoint` edge ids on the V2 road graph (fresh-road rule) | WP3, WP4, WP12b, WP14, WP15b |
| Garage art / PlotService model | Vault bay and lay-low pad positions in the garage model | WP5 |
| Vehicles (`Config/Cars`, CarBuilder) | `limitedCap`, `class`, `bound` hero flag; the re-tuned Diamond Dragster | WP3, WP9, WP17 |
| Lighting (`LightingService`) | `setWeather(state, seconds)` and `WeatherChanged` signal | WP18 |
| UI (`gta_ui_language`) | Theme tokens and shard component for MISSION PASSED, payout line style, phone app frame | WP7, WP15 |
| Combat (gta_combat) | Drop the 1→2 migration from its §13.2 plan (LOOP_V2 D13); fields ship in WP0's template | WP0, WP2 |

---

## 8. File ownership index

Every loop-touched file appears once.

| File | WP |
|---|---|
| `src/shared/Types.luau`, `Remotes.luau`, `Net.luau` | WP0 |
| `src/shared/Config/{Flags,Economy,Rarity,Police,Monetization,Theft,Crime,Progression,Upgrades,Paint,Districts,LiveOps,Onboarding}.luau` | WP0 |
| `src/server/init.server.luau`, `src/client/init.client.luau`, `default.project.json` | WP0 |
| `src/shared/Util/{EconomyMath,Rolls,CarStats,Payout,TheftRules,StreetGate,Progression}.luau` | WP1 |
| `src/shared/Util/Format.luau` | WP7 |
| `src/shared/Config/Minimap.luau` | WP11 |
| `src/shared/Config/{Weapons,Animations,Sounds}.luau`, `src/shared/Combat/*` | WP13 |
| `Systems/DataService` | WP2 |
| `Systems/{CarService,RepService,EconomyTelemetry,DistrictService,AdminService}` | WP3 |
| `Systems/{VehicleService,StreetSpawnService,TrafficService,CharacterWatchdog}` | WP4 |
| `Systems/{GarageService,PlotService,StreetIncomeService,BankingService}` | WP5 |
| `Systems/{TheftService,ChopShopService}` | WP6 |
| `Systems/{RewardsService,RebirthService,LeaderboardService}`, `src/server/Config/Codes.luau` | WP8 |
| `Systems/{MonetizationService,DealershipService,ModShopService}` | WP9 |
| `Systems/{WantedService,PoliceService,JailService}` | WP10 |
| `Systems/BlipService` | WP11 |
| `Systems/{EventService,EventClock,ArmoredTruckService}` | WP12 |
| `Systems/{WeaponService,DamageService,HitboxHistory,PoliceCombatService,CombatService,NPCService,ShopService}` | WP13 |
| `Systems/RobberyService` | WP14 |
| `Systems/{OnboardingService,JobsService}` | WP15 |
| `Systems/{PartyService,HeistService}` | WP16 |
| `Systems/{TradeService,RaceService,SerialService}` | WP17 |
| `Systems/{CrewService,SeasonService,LiveOpsService}` | WP18 |
| `Controllers/{VehicleClient,HotwireClient}` | WP4 |
| `Controllers/{GarageClient,StreetHUD,RevealController}` | WP5 |
| `Controllers/{StateController,HUDController,MenuController,NotificationController,EffectsController,WaypointController,PhoneController,PayoutLine}` | WP7 |
| `Controllers/{DealershipClient,ModShopClient}` | WP9 |
| `Controllers/{MinimapController,MapScreenController}` | WP11 |
| `Controllers/{EventsClient,TruckClient}` | WP12 |
| `Controllers/{CombatClient,SoundController,WeaponClient,ShoulderCamera,WeaponWheel,CombatHUD,DeathScreenController,ShotFxController,GunShopUI}` | WP13 |
| `Controllers/HotSpotsApp` | WP14 |
| `Controllers/{MissionController,TutorialController}` | WP15 |
| `Controllers/{PartyClient,HeistClient,QuickChatWheel}` | WP16 |
| `Controllers/{TradeClient,RaceClient}` | WP17 |
| `Controllers/PhotoModeController` | WP18 |
| `tests/spec/{contracts,boot}` | WP0 |
| `tests/spec/{shared,carstats,payout,theftrules,streetgate,progression}` | WP1 |
| `tests/spec/{data,money_api}` | WP2 |
| `tests/spec/{carservice,transfer,rep,telemetry,admin}` | WP3 |
| `tests/spec/{vehicleservice,watchdog,hotwire}` | WP4 |
| `tests/spec/{garage,plot,streetincome,banking}` | WP5 |
| `tests/spec/{theft,theftflow,chop,leftovers}` | WP6 |
| `tests/spec/{hud,menus,clientcore}` | WP7 |
| `tests/spec/{rewards,prestige,leaderboard}` | WP8 |
| `tests/spec/{dealership,modshop,monetization}` | WP9 |
| `tests/spec/{police,jail}` | WP10 |
| `tests/spec/{minimap,blips}` | WP11 |
| `tests/spec/{events,eventclock,truck}` | WP12 |
| `tests/spec/{combat,npc,shop,combateconomy}` + gta_combat §13.1 specs | WP13 |
| `tests/spec/robbery` | WP14 |
| `tests/spec/{onboarding,jobs}` | WP15 |
| `tests/spec/{party,heist}` | WP16 |
| `tests/spec/{trade,race,serial}` | WP17 |
| `tests/spec/{crew,season,liveops}` | WP18 |

**Not owned by the loop** (consumed only): `MapBuilder`, `MapDresser`, `AssetLibrary`, `LightingService`, `VehicleFxService`, `Config/{Cars,Vehicle,Map,WorldLayout,Assets,VFX}`, `Util/{MapLayout,RoadGraph,WorldGen,WorldQuery,Signal,Trove}`, `src/shared/Vehicle/*`, `Controllers/{AssetClient,WheelAnimator,VFXLibrary}`, and the specs `map`, `mapdress`, `maplayout`, `roadgraph`, `worldlayout`, `carbuilder`, `carbuilder_shell`, `assets_shell`, `vehicle`, `vfx`, `ap4`, `garage_dressing`.

---

## 9. Remote ownership (handler side)

| Remote | Handled by | | Remote | Fired by |
|---|---|---|---|---|
| `DriveCar`, `SellCar`, `MoveCar`, `UnlockSlot`, `CallMechanic`, `GoHome`, `LockGarage` | WP5 | | `DataSnapshot` | WP2 |
| `ModShopBuy`, `BuySecurity`, `BuySkill`, `ApplyPaint`, `SetPlate` | WP9 | | `CarProgress`, `RepProgress` | WP3 |
| `RetrieveImpound`, `RushRepair`, `CallLawyer`, `Surrender` | WP10 | | `Reveal`, `StuntEvent` | WP5 |
| `KillSwitch` | WP6 | | `HotwireWindow` | WP4 |
| `MiniGameInput` | WP14 | | `PayoutBreakdown` | the paying package (WP5, WP10, WP12, WP13, WP14, WP16) through `Payout` |
| `RookieOptOut`, `SetPassive`, combat remotes | WP13 | | `CarStolenAlert`, `TheftState`, `RevengeState` | WP6 |
| `ClaimDaily`, `ClaimPlaytime`, `RedeemCode`, `RerollContract`, `Rebirth`, `GetLeaderboard` | WP8 | | `MapBlips` | WP11 |
| `JobAccept`, `JobAbandon` | WP15 | | `CrimeState` | WP14 |
| `PartyInvite`, `PartyRespond`, `PartyLeave`, `PartyKick`, `MapPing`, `QuickChat`, `Emote`, `HeistStart`, `HeistReady`, `HeistLeave`, `HeistRole` | WP16 | | `PulseState`, `TruckState`, `EventState`, `HotDropState` | WP12 |
| `TradeRequest`, `TradeRespond`, `TradeOffer`, `TradeReady`, `TradeConfirm`, `TradeCancel`, `RaceChallenge`, `RaceRespond` | WP17 | | `MissionState` | WP15 |
| `CrewCreate`, `CrewInvite`, `CrewRespond`, `CrewLeave`, `CrewKick`, `CrewPromote`, `ClaimSeasonTier` | WP18 | | `Busted` | WP10 |
| `GetSnapshot`, `SetSetting`, `TutorialDone` | WP2 | | `Wasted` | WP13 |
| `AdminCommand` | WP3 | | `PartyState`, `HeistState`, `QuickChatRelay`, `Invite` (party) | WP16 |
| `LendCar` (V2.1) | WP5 | | `TradeState`, `RaceState`, `Invite` (trade, race) | WP17 |
| | | | `CrewState`, `LiveOpsState`, `Invite` (crew) | WP18 |
