# Hotwire City V2: Loop, Systems and Economy Design (LOOP_V2)

- **Status:** V2 design baseline, **revision 2**, 2026-10-27. Written by the lead game designer for the V2 build waves (task #9). Revision 2 applies the economy, fun and engineering critiques; every point is accepted, modified or rejected with a reason in the **Critique log** at the end of this document.
- **Implementation breakdown:** `docs/v2/design/LOOP_V2_ENGINEERING.md` (work packages, file ownership, remotes, data fields, tests). Where the two disagree on a number or rule, this document wins; on file ownership and build order, the engineering document wins.
- **Binding inputs:** `docs/v2/research/00_LEAD_DIRECTION.md` and `docs/v2/research/original_brief.md`. If this document conflicts with them, they win.
- **Built on:** v1 code and contracts: `docs/SPEC.md`, `docs/integration/DECISIONS.md`, `src/server/Systems/*`, `src/shared/Config/*`, `src/shared/Types.luau`.
- **Sibling documents:**
  - `docs/v2/research/gta_combat.md` owns weapon stats, the damage model, police combat AI and shot netcode. This document owns the economy and progression layer on top (§4.0 lists the deltas).
  - `docs/v2/research/gta_ui_language.md` owns HUD, phone and menu presentation.
  - `docs/v2/world/` owns geography (so far only `plan*.png`; the gameplay layer shows 8 garage plots, traffic signals, Hot Drop spots, stunt jumps, armored routes and race routes). Anything here that needs a map position is marked **[world]**.
- **Constraints:** max 8 players per server, one garage plot each. Mobile first. Moderate 13+: guns, no blood, WASTED and BUSTED.

**Conventions**
- **`G` (reference income)** is a player's garage potential in $/s, defined in §0.4. Almost every payout is written as `base + N s × G`. That keeps each activity relevant at every stage, and the base makes it matter in minute one. This is the v1 "incomeMinutes" idea, generalised.
- Names in `code` such as `Economy.SLOT_PRICES` are existing v1 config values. "v1 → v2" marks a change.
- All money is in-game cash ($). Robux is written R$.

---

## 0. Summary

### 0.1 The game in one paragraph

You spawn in your own garage in a sun-baked coastal city.
- **Steal and park.** Steal a car off the street, outrun the cops and park it at home, where it earns money every second. **The garage is a bank.**
- **Drive for the multiplier.** Take one of your cars out and it earns **3× to 10×** as much while you drive it. The money goes into your **wallet**, and anyone can take a wallet or a car. **The street is a casino.**
- **Build up your cars.** Every car has its own level, upgrades, paint, finish and mileage, and whoever steals it keeps all of that, subject to fair-play protections.
- **Stack cash.** Rob stores, ATMs and people. Every 5 minutes the server rushes an armored truck; every 30 minutes a crew of up to 4 (or one brave solo player) runs a bank heist. Wanted stars multiply payouts up to 3×, and at 5★ the whole server hunts you for a bounty.
- **Spend it.** Buy guns, upgrade cars, push into richer districts, prestige, race for pink slips, trade, flex.
- **Lose and come back.** When you lose a car you get insurance, a 5-minute window to take it back, and a revenge mark on the thief.

### 0.2 Design laws (every system must obey these)
1. **One verb first.** Minute one is steal → escape → park. Each other system unlocks on the schedule in §1.3–1.5, and every system feeds the car loop rather than sitting beside it. (Brief §3.1; the Grow a Garden 2 warning.)
2. **Every dollar has a risk position.**
   - **Bank** is safe.
   - **Wallet** is at risk.
   - A **parked car** is safe while the garage is locked or the car is in the vault.
   - A **driven car** is at risk. A driven car that a thief could not keep (bound, or its owner is protected) earns at most **×5** on the street (§2.8). Protection and the full casino rate never stack.
   - Dying while wanted costs at least as much as being busted, and leaving the server never costs less than staying (§4.3, §10.3).
   - Every source in §7.2 says where its money lands.
3. **Loss is never total.**
   - Insurance, a repo window, vault bays, daily loss caps and a revenge mark.
   - Nobody can lose their last 2 cars.
   - The bank can never be taken by another player.
4. **No reward for murder.** Killing a non-wanted, non-LOADED player pays nothing (gta_combat §8). PvP money only comes from mugging, LOADED wallets, thefts, bounties, and revenge on a player who wronged you first. In each case the target opted into the risk.
5. **The server decides everything.** Money, damage, ownership, positions used for payouts, and timers are all server-side (§10).
6. **Designed for 8.** Every event works with 1 to 8 players in one server.
7. **Mobile first.** Every interaction is a ProximityPrompt hold or one big button. No action needs more than 2 taps. Aim assist on touch and gamepad.
8. **Honest monetization.** Robux buys speed, convenience and style. It never buys power over another player (§8).
9. **Show the rules.** Every multiplier on a payout is itemised on screen (§3.1), every protection that stops a theft is named on the prompt (§2.8), and every robbable spot shows whether it is open (§3.13). A hidden rule reads as a bug to a 12-year-old.
10. **Caps soften, they don't zero.** Repeatable PvE sources drop to ×0.25 after their cap instead of paying $0. Hard caps stay only on minted PvP-adjacent sources (§10.2).

### 0.3 Decisions this document makes (open questions from the brief, §3.13)

| Question | Decision |
|---|---|
| PvP model | Open PvP everywhere except safe zones, with **10-minute** rookie protection (the brief's number; delta D12 against gta_combat's 30), Passive mode, Menace and bounties (gta_combat §8). Car theft has its own, longer protections (§2.8). |
| Player cops at launch | **No.** AI police only in V2.0. Revisit in V2.x. |
| Crew betrayal | **Off.** Heist splits are **equal** and enforced by the server; there is no leader-set split. Players outside the crew can still steal dropped bags, so the drama comes from rivals. |
| Solo play | Every activity works solo, including a reduced solo bank heist (§3.7). Crews earn more per heist through the party bonus, not through exclusive access. |
| Player data | **Fresh DataStore `HotwireCity_v2`, no v1 migration.** v1 never shipped to players (first real-engine run was in Studio on 2026-10-27; every product id is 0), so no profile needs carrying over (§9.3). |
| Shared crew garage | **No shared ownership** in V2.0, to avoid scams and ownership bugs. V2.1 adds "Car Keys" lending inside a party (§5.3). |
| Cash wagers on races | **Off.** Policy risk: cash can be bought with Robux. House-funded prizes only. Pink slips ship behind `RACE_PINK_SLIPS_ENABLED`, pending policy sign-off (§5.4). |
| Cash in trades | **No.** Trades are cars only (§5.5). |
| Player-placed bounties | **No in V2.0**, agreeing with gta_combat §14(e). Bounties come only from stars. |
| Rebirth naming | Renamed **Prestige** (UI note §5.15 flagged this). Data keeps `rebirths`. |
| Meme cars | Hidden collectibles only, never core content (lead direction). §2.10. |
| Title | Out of scope; Hotwire City stays. |

### 0.4 Glossary and core formulas

| Term | Definition |
|---|---|
| **Wallet** | Cash on hand. Crime payouts and street income land here. Can be mugged, dropped while LOADED, confiscated on BUSTED. Shown big in the top-right. |
| **Bank** | Safe cash. Garage collections, offline earnings, deposits, contract rewards, insurance, Robux cash. No other player can take it. Shown small under the wallet. |
| **Spend order** | Purchases and fees take from the wallet first, then the bank. |
| **G** | `G = max(G_MIN, Σ carIncome(c) over owned cars with place slot or vault) × (1 + REBIRTH_INCOME_BONUS × rebirths)`, with `G_MIN = 5` and `REBIRTH_INCOME_BONUS = 0.5` (v1). It counts parked, driven, impounded and in-repair cars, so taking your best car out does not shrink your crime payouts. It excludes passes, events, friends, group and index bonuses. |
| **carIncome(c)** | `Cars[c.carId].income × Finish[c.finish].mult × (1 + 0.03 × (c.level − 1)) × Trait[c.trait].incomeMult` |
| **Garage income** | `carIncome × garageMult`, where `garageMult` is v1 `EconomyMath.playerMultiplier` (rebirth, friends, group, index, 2× Garage Cash pass, 2× Cash event). Only parked cars earn it. |
| **S× (street multiplier)** | §2.2. From ×3 to ×10 while driving an owned car; at most ×5 on a protected drive. |
| **Protected drive** | A drive in a car that a thief could not keep right now: a bound car, or any car while its owner has starter protection, the last-2-cars floor, the daily loss shield or Shaken (§2.8). S× is capped at ×5 and the HUD reads "PROTECTED · ×5 MAX". |
| **wantedMult** | By stars 0–5: `{1.0, 1.2, 1.5, 2.0, 2.5, 3.0}` |
| **Wanted loss** | `WANTED_LOSS_PER_STAR × stars` = 7% of the wallet per star. Taken on BUSTED (halved on surrender), on WASTED while wanted, and on combat-logging (§4.3–4.4). |
| **LOADED** | `wallet ≥ max(5,000, 300 s × G)`. While LOADED you show on every minimap, cannot take a cab home, drop 20% of your wallet if a player WASTES you, and pay a 10% fee if you leave the server before banking (§10.3). |
| **Pulse / Big Pulse** | The server clock. Every 300 s: armored truck, order-board refresh and dealership restock. Every 1,800 s: the bank-heist window (open 600 s). |
| **Vault bay** | An unstealable parking bay inside the garage (§2.1). |
| **Lay-low bay** | A pad outside the thief's garage door where a stolen player car waits 300 s. **The car record stays in the victim's profile until the window ends**; then it transfers once. During the window the car can be **repo'd** (§2.7.4). |
| **Bound car** | A car bought with Robux or from a pass, the starter pack or a season. It cannot be kept by a thief, traded or staked, and it earns at most ×5 on the street (§2.8). |
| **Server Crown** | The richest player in a server of 3 or more (§5.8). A status target; it mints nothing. |
| **Rep / RP** | Account level 1–100 and its XP (§6.1). |
| **Car level / XP** | Per-car progression (§2.3). |
| **Finish / Trait** | A car's rolled rarity layer, replacing v1 "mutation" (§2.5). |

---

## 1. Loops

### 1.1 The 30-second loop (unchanged spine from v1)

```
find a car -> HOTWIRE (hold, release in the green) or JACK a driver -> stars + siren -> ESCAPE (break LOS, evade timer) -> GARAGE drop-off
      ^                                                                                                 |
      |                                         park = income every second (bank)                       |
      +-------- or take an owned car out: STREET xN income into the wallet (casino) <-------------------+
```

The loop adds three decision points that v1 lacked:
1. **Park or drive?** A parked car earns ×1 and is safe. Driving it earns ×3–×10 and exposes it to carjacking. Driving *well* (near-misses, drifts, jumps) climbs the multiplier fastest, and a hot multiplier puts your car on everyone's map.
2. **Bank now or push on?** The wallet grows with every crime and every second of driving. LOADED makes you visible to the whole server.
3. **Lie low or push the stars?** wantedMult raises payouts up to 3×, and police lethality and the 5★ server hunt rise with it.

### 1.2 The money axis

| Where money comes from | Lands in | Who can take it | How it becomes safe |
|---|---|---|---|
| Parked cars (garage income) | Slot `uncollected` | Nobody. A thief gets the car, but its uncollected cash is paid to the victim first (v1 rule). | Collect pad → bank (Auto-Collect pass: every 60 s) |
| Offline earnings, contracts, daily rewards, insurance, Robux cash | Bank | Nobody | Already safe |
| Street income from driving an owned car | Wallet | Muggers, LOADED drop, BUSTED | Deposit |
| Robberies, heists, truck, chop, jobs, bounties, trunk cash | Wallet | Same | Deposit |
| **Deposit** | Wallet → bank | — | Enter your own garage at 0★: automatic and free. Or use an ATM at 0★: 2 s hold, 5% fee. Leaving the server at 0★ also banks the wallet: free, or minus 10% if you are LOADED and outside your garage (§10.3). |

### 1.3 First 5 minutes (second by second)

New players are protected by rookie protection (10 min, §2.8; HUD pill "ROOKIE 7:42 · tap to fight players") and starter theft protection (§2.8). Help text appears in the GTA top-left box (UI §5.5); there are no centre cards.

**Framing.** Onboarding is a chain of numbered **contact missions** sent by text from "Dex" (a fixer contact in the phone). Each mission has exactly one objective line (bottom-centre), one GPS target, and ends with a **MISSION PASSED** shard and its reward. Only one new concept is taught per mission (Law 1). Flags live in `onboarding` (§9.1).

| Time | Beat | What the player sees and does | Systems | Emotion |
|---|---|---|---|---|
| 0:00 | Spawn at home | The garage door rolls up. The owner sign reads "<Name>'s Garage". A Rustbucket on pad 1 ticks $3/s (`Economy.STARTER_CAR`). Help: "Cars in your garage earn money." Text from Dex: **Mission 1: "Get me a ride."** | PlotService, GarageService, OnboardingService | Ownership |
| 0:05 | One target | GPS to the traffic signal outside the garage [world: every plot has a signal within 150 studs on the gameplay plan]. A scripted traffic car pulls up and stops at the red light. A big **JACK** button (keyboard F, gamepad Y) appears when you're within 8 studs. Fallback when the scripted car can't spawn: the v1 parked newbie car within 120 studs and a hotwire. | TrafficService `scriptedStop`, StreetSpawnService | Clarity |
| 0:10 | **Jack** | Hold JACK 0.6 s. The NPC driver is thrown out and ragdolls (`NPCService.ejectComic`, realistic animation), shouting. You're in. | TrafficService carjack, NPCService | Power, the GTA moment |
| 0:12 | Siren | **Scripted 2★** (`WantedService.tutorialChase`). Two tutorial cruisers that cannot bust or shoot, a cosmetic police heli flyover with searchlight, and one pursuer scripted to clip traffic and crash with sparks. | WantedService, PoliceService `tutorial` units | Adrenaline |
| 0:15–0:45 | Escape | The search circle shrinks each time you break line of sight; it collapses fast enough that **"LOST THEM"** lands in 40 s or less. Evade bonus paid. | WantedService (gta_combat §9.4) | Relief |
| 0:50 | Deliver | Drive into the drop-off. The car parks on pad 2. It is a Common with a **guaranteed Gold finish**, so income goes from $3/s to $13/s. Reveal card: "GOLD · street odds 1 in 21" (the true street odds of a Gold Common, computed as in §2.5; the card never claims this roll was random). Trunk roll (§2.5.1). **MISSION PASSED.** | GarageService, RevealController | Reward |
| 1:00 | Rep 2 | Shard: "REP 2" | RepService | Growth |
| 1:10 | Collect | Walk over the Collect pad: cash goes to the bank, with a cash delta top-right | GarageService | Ownership |
| 1:20 | **Mission 2: "Bring me any blue car."** | This is the first chop-shop order, pulled forward. GPS to a parked blue car. **Hotwire:** hold the prompt; a bar fills, and releasing while it is in the green band makes a **CLEAN** steal (faster, no witness roll). Holding to the end also works. Deliver to the Chop Shop. MISSION PASSED (order ×1.5). | VehicleService prompt, HotwireClient, ChopShopService | Skill |
| 2:00+ | Car level | Silent: the car's XP bar fills on the HUD. No feed line until LV 5. | StreetIncomeService | Attachment (quiet) |
| 3:00 | **Mission 3: "The corner store owes me."** | Text from Dex: "Got you a piece." **Kessler P9 plus 2 magazines granted** (brief: free pistol in minutes 4–6). GPS to the nearest Kwik Stop. | onboarding flag `gun_gift` | Power |
| 3:30 | Stick-up | Aim at the clerk, or the HOLD UP prompt. The register fills over 8 s; 1★, then 2★. The payout line itemises the multiplier: "$3,090 · ×1.5 WANTED 2★" (§3.1). | RobberyService | Thrill |
| 4:00 | Getaway | A real 2★ chase. Cops only shoot if you are armed and firing (gta_combat §9.1). | PoliceService | Risk |
| 4:45 | Home | Enter your garage at 0★: the wallet auto-deposits with a WALLET → BANK delta. **No wallet help text yet** (it comes with the first LOADED moment or when rookie protection ends). MISSION PASSED. | BankingService | Safety |
| ~5:00 | Shared clock | Feed card: "ARMORED TRUCK leaving the depot in 0:30", shown at the next server pulse | EventClock | Anticipation |

### 1.4 First 30 minutes

| Minute | Beat / unlock | Hook |
|---|---|---|
| 5–8 | Mod Shop opens (Rep 2). Engine stage 1 on the Rustbucket costs $100, and the first paint job is free. | First per-car investment |
| ~8 | **Mission 4: "The casino."** Help: "Drive your own car: it earns ×3 on the street. Near-misses, drifts and jumps push it higher." Take the Gold Common out. The HUD shows **WALLET +$30/s, STREET ×3.0** and the multiplier ticks up on the first near-miss. | Greed |
| 8–10 | One-time Starter Pack offer in the phone (§8.3). Dismissible and never shown again. | Moment of desire |
| 5–10 | First armored truck. A rookie who grabs a bag sees a prompt: "Taking event loot ends your Rookie Protection." | Shared server moment |
| ~10 | **Rookie protection ends** (600 s), usually alongside the first truck. Shard: "PROTECTION OFF: other players can now rob you." Help, now and only now: "Wallet = at risk. Bank = safe. Your garage banks it for free." Your *cars* stay protected much longer (starter protection, §2.8). | Stakes |
| 8–12 | Slot 5 ($1,500, `Economy.SLOT_PRICES[5]`). The chop order board in the phone's Jobs app (already met in Mission 2). | Goal gradient |
| 10–15 | Rep 5: **Vault bay 1** unlocks. Help: "Your cars can't be kept by thieves until Rep 8 and 2 hours of play. Park your best one in the Vault before then." | Loss aversion |
| 10–15 | Party invite prompt when a friend is in the server, plus **Invite friend** (`SocialService:PromptGameInvite`) in the party panel. Quick-chat wheel unlocks. | Co-play |
| 15 | Playtime gift: an Uncommon car (reward-origin, trade-locked 14 days). | Surprise |
| 12–18 | First Rare car (street or dealership, $7–11K). A server feed card shows someone's Legendary reveal. | Envy and social proof |
| 15–25 | First LOADED moment: the wallet crosses `max(5,000, 300 s × G)` and a $ blip appears on everyone's map. If the wallet help hasn't shown yet, it shows now. | Greed vs risk |
| 25–30 | Big-pulse countdown in the feed: "Bank heist window opens in 4:00 (leader Rep 10, crew 1–4)". The heist lobby has an **Invite friend** button. | Next-session hook |

### 1.5 Day 1 (60–180 minutes over 2–3 sessions)

- **Rep 10 (about 1 h):**
  - Comrade AR and Pump shotgun; custom plates and underglow.
  - Leading a bank heist, trading (once account and playtime gates pass), pawn shop, Epic cars at the dealership.
  - First Prestige becomes possible at `max($750K, 10,800 s × G)` (§6.3), typically reached in session 2–3.
- **About 2 h of play (Rep 8+):** starter protection ends; your cars can now be kept by thieves (§2.8).
- **Garage:** 6–8 cars, the first Epic, and a favourite car at level 10, which unlocks Engine stage 3.
- **First theft arc:** a carjack, either way.
  - The victim gets a REVENGE mark, the repo window and, if the car is kept, an insurance cheque.
  - The thief has to defend the lay-low bay for 5 minutes. This is the clip.
- **First bank heist,** solo or with a party, in roles: driver, hacker, gunman and lookout.
- **Exit hook:** "Your garage earns about $X while you're away (6 h cap)" (v1 `OFFLINE_RATE 0.3`, `OFFLINE_CAP_HOURS 6`), plus "Heist window in 12:00".

### 1.6 Day 7 (8–16 hours total)

- **Rep 25–32:**
  - The Beachfront and Hills districts are comfortable; Legendary (Rep 18) and Mythic (Rep 25) cars at the dealership.
  - Carbine (Rep 14) and marksman (Rep 22) unlocked.
  - Vault bay 2 at Rep 25.
- **Cars:**
  - Legendary and first Mythic cars, with a favourite car at level 15–25.
  - First Chameleon or Galaxy finish, and a limited serial-numbered car to chase.
- **Prestige 2–4.** Each adds +50% income.
- **Social:**
  - Pink slips (Rep 15).
  - A regular crew, crew weekly contract, the Saturday Admin Abuse hour.
  - Season pass tier about 12–18 of 50.
- **Status goals:** the Most Wanted board (longest at 5★), Best Garage (likes), Top Thief, Richest, and wearing the **Server Crown** (§5.8).

### 1.7 The session (target 15–25 min) and the server clock

1. **Join.** An email with offline earnings (bank), the daily objective and contracts in Pause › JOBS.
2. **Collect** the garage. Check the order board and the pulse timer in the phone's Jobs app.
3. **Choose a plan** (the map shows which stores, ATMs and the jewelry store are open, §3.13):
   - drive a car hard to level it (XP plus wallet; stunts climb the multiplier);
   - chain robberies for the wanted multiplier;
   - fill a chop order;
   - roam a richer district for spawns;
   - hunt the Server Crown or a LOADED blip.
4. **Every 5-minute pulse:** the armored truck scramble.
5. **Every 30-minute big pulse:** the heist window (party).
6. **Before leaving:** bank the wallet. LOADED makes you the target.
7. **Exit hooks:**
   - "Heist window in 12:00"
   - "Phantom GT is 340 XP from LV 15"
   - the offline-earnings estimate
   - the season tier progress bar

**Server clock** (server-relative, so every server is always mid-cycle):

| Interval | What fires | v1 basis |
|---|---|---|
| 300 s (±0) | **Pulse:** armored truck, order-board refresh, dealership full restock | `DealershipService.RESTOCK_INTERVAL` 240 → **300** |
| 600–900 s | Hot Drop (Legendary or better) | `Events.HOT_DROP_INTERVAL {360,540}` → **{600,900}** (brief: rare spawn every 10–15 min) |
| 1,800 s | **Big pulse:** bank-heist window, open for 600 s | new |
| 900 s cooldown | Jewelry store resets | new |
| v1 random | Cash Rain, Rush Hour, 2× Cash (5 min) | `Events.*` unchanged |
| v1 day/night (12 min day, 4 min night) | Night: street luck ×1.5 and +1 police unit per chase | `LightingService.isNight` |

### 1.8 Emotional beats map

| Beat | Created by | Peak moment (the clip) |
|---|---|---|
| **Greed vs risk** | The wallet ticking during STREET ×N; wantedMult; LOADED blip; truck bags slowing their carrier | "I had $2M in my wallet at 5★ and made it home with 3 HP" |
| **Revenge** | REVENGE mark, repo window, Tracker GPS, Interceptor reward, a server-wide chase on every theft | "He stole my LV 30 Chrome Phantom, so I chased him across the city and repo'd it from his lay-low bay" |
| **Flex** | "1 in X" reveals, finishes, serials ("#7 of 500"), plates, paint, garage showroom likes, leaderboards, photo mode | "1 in 69,000 Galaxy Night Raven" |
| **Scramble** | Truck every 5 min, Hot Drop, Most Wanted 5★ hunt | "Eight players, one truck" |
| **Belonging** | Party bonus, heist roles, crew tag, quick chat | "Our first bank heist, 4★ getaway" |
| **Mastery** | Hotwire timing, drifting XP, nitro lines, races | "Beat a hypercar in my LV 25 Bull Charger" |

---

## 2. Cars

### 2.1 Ownership model

Each car is a **CarRecord** (§9.1) with a permanent `uid` and a `place` (where it belongs) plus a `status`.

| Place / status | Where | Earns | Can be stolen | Ends when |
|---|---|---|---|---|
| `slot` + `ok`, parked | Garage pad 1–10 (+2 with the pass) | 100% garage income into `uncollected` | Garage raid, only while the lock is down and the owner is online (v1) and §2.8 allows it | Driven out, sold, or stolen |
| `vault` + `ok`, parked | Vault bay 1–3, a separate locked bay inside the garage | 100% garage income | **Never while parked** | Driven out or moved |
| Driving (runtime "Out") | Street, driven by the owner | Street income (S×) into the wallet. No garage income. | **Carjack** (§2.7) | Parked again, wrecked (→ repair), busted or WASTED while wanted (→ impound), or carjacked |
| Runtime "LayLow" (record still in the **victim's** profile, `place` unchanged) | The thief's lay-low pad (outside the thief's garage door) | 0 | Repo by the victim or the victim's party (victim online) | After `LAYLOW_SECONDS` (300) the record transfers once to the thief's reserved slot (§2.7.4) |
| `status = impounded` | Impound lot [world] | 0 | Break-out by the owner only | Pay `max(250, 3% value)`, wait **120 s** (free), or break out (+2★) |
| `status = repair` | Mechanic queue | 0 | No | **60 s** (free) or pay `max(100, 1% value)` |
| `owedCars` list (`place = nil`) | Not in the world | 0 | No | Delivered into the first free slot (replaces v1 `exclusives` and `pendingCars`). Never dropped; there is no cap. |

**Capacity** is `slotsUnlocked` (4 → 10, `Economy.START_SLOTS`/`MAX_SLOTS`, prices `Economy.SLOT_PRICES` unchanged) + 2 (pass, `PASS_EXTRA_SLOTS`) + vault bays.
- Vault bays: 1 at Rep 5, +1 at Rep 25, +1 from a pass; maximum 3.
- Impounded and in-repair cars keep their slot reserved. The pad shows IMPOUNDED or IN REPAIR.
- The lay-low bay is extra: 1 per garage, so a player can hold **at most one stolen car at a time**. This rate-limits theft by design. The thief must have a free slot when the theft starts; it is reserved until the window ends.

**Mechanic (phone):** delivers a parked car to the nearest road node within 60 studs of you in 30 s.
- Fee: `max(250, 5 s × G)`, free for VIP. Cooldown 60 s.
- Not available while wanted or LOADED.
- This is GTA's personal-vehicle service. It removes the walk home on mobile without letting you bank.

**Go Home (phone cab):** a 10 s channel, cancelled by damage.
- Blocked while wanted, In Combat (gta_combat §8), LOADED, or carrying event loot.
- This replaces the instant v1 `GoHome`, which would have been a free deposit.

### 2.2 Street income: the casino

While the owner drives their **own** car (`kind = "Owned"`, `status = ok`; bound cars too, at the lower cap), every second StreetIncomeService pays into the wallet:

```
streetIncome/s = carIncome(car) × (1 + 0.5 × rebirths) × S×
S×         = min(cap, S_BASE + ramp + S_PER_STAR × stars)        -- S_BASE 3, S_PER_STAR 1
ramp       = min(S_RAMP_MAX, timeRamp + actionRamp)              -- S_RAMP_MAX 3
timeRamp   = min(1.5, 0.25 × freshMinutes)
actionRamp = Σ stunt events (near-miss +0.25, drift ≥ 2 s +0.25, airtime ≥ 1 s +0.5), at most +1.5 per rolling 60 s
cap        = S_CAP 10
           | S_CAP_PROTECTED 5   on a protected drive (bound car, or an owner a thief could not keep from, §2.8)
           | S_PASSIVE 1.5       in Passive mode (fixed)
           | 1                   after STREET_FULL_SECONDS_PER_DAY = 10,800 paying seconds in the UTC day (XP continues)
```

- **Time ramp: fresh roads only.** A *fresh minute* is 60 s of paying ticks during which the car covered at least `S_RAMP_FRESH_STUDS = 1,200` studs of RoadGraph edges it has not driven in the last `S_RAMP_FRESH_WINDOW = 300` s. Lapping one block or one highway loop stalls the time ramp. Plain cruising tops out at **×4.5**.
- **Action ramp: driving like GTA.** Every event is sampled by the server from the car's own physics (§10.2), never reported by the client:
  - **Near-miss:** passing within 4 studs of a traffic or player car at ≥ 40 studs/s relative speed without contact; once per other car per 10 s.
  - **Drift:** slip above `Vehicle.DRIFT_SLIP_SPEED` for 2 s or more.
  - **Airtime:** no wheel contact for 1 s or more, then landing without wrecking.
  - Each event shows a small popup ("NEAR MISS +0.25"). A good driver reaches ×6 in about 2 minutes; a passive cruiser never passes ×4.5.
- **Decay.** Below 15 studs/s the ramp loses 0.5 every 30 s (the action part first). Sitting in traffic slowly cools you down.
- **Out of the car.** The ramp is held for `S_OUT_GRACE = 30` s, decaying at the same rate (a store hold-up costs about 0.25), then resets. It also resets when the car parks, on WASTED or BUSTED, and when the car is carjacked. A crime payout does **not** reset it: robbing a store mid-cruise is the GTA rhythm.
- **Ticks only while all of these hold:**
  - the car moved ≥ 150 studs net over the last 60 s;
  - its speed averaged ≥ 15 studs/s over the last 5 s;
  - it is within a road or drivable zone (RoadGraph);
  - it is outside safe zones and outside the owner's garage interior;
  - the driver changed throttle or steer input at least once in the last 45 s;
  - the car is not tainted and not paused by the VehicleService watchdog (`pausedUntil`, §10.1).
- **Hot ride** (replaces the Legendary-only flash heat; every rarity):
  - At **S× ≥ 6** the car appears on **every** minimap with a "×6.5" tag (`MapBlips` kind `hotride`, §9.6). A big multiplier is a big target.
  - At **S× ≥ 5**, every 180 s of continuous paying time adds +1★ ("Someone reported your ride"). At S× ≥ 8 the interval is 90 s.
- **HUD:** WALLET with a `+$X/s` delta, a small `STREET ×6.5` label and a thin ramp bar under it (top-right group, UI §5.4). On a protected drive the label reads `PROTECTED · ×5 MAX`; after the daily limit it reads `STREET ×1 · daily limit`.
- **Wallet ticks are quiet.** They update the `Wallet` and `StreetMult` attributes and never trigger a full data snapshot (§9.5).
- **Worked numbers:**
  - Gold Common at minute 8: $10 × 3 = $30/s.
  - Level 10 Epic Phantom GT at ×5.5: $260 × 1.27 × 5.5 = $1,816/s.
  - Level 30 Mythic with 2 prestiges at the ×10 cap (full ramp plus 4★, so heli sniper and spikes): $5,000 × 1.87 × 2 × 10 = $187K/s.
- **Why a daily limit:** 10,800 s is about 7 target sessions of non-stop driving. It never touches a normal player and only bounds an unattended autopilot (§10.2).

### 2.3 Per-car level and XP

| Item | Rule |
|---|---|
| XP from driving | **1 XP per 20 studs** driven by its owner on the street at ≥ 15 studs/s. Same gates as street income (not the fresh-road rule), but passive mode and drives past the daily street limit still earn XP. About 180 XP/min at 60 studs/s. Shown as a silent HUD bar; a feed line appears only at LV 5 and every 5 levels after. |
| Bonus XP for the car you're in | +40 per star evaded; +2/s drifting (`Vehicle.DRIFT_SLIP_SPEED`); +50 per crime payout while this car is your getaway (it is within 50 studs at payout and you drive it away within 30 s); race finish +150 (win +300); heist getaway +500; delivering a truck or heist bag in it +100 |
| XP to the next level | `xpToNext(L) = floor(80 × L^1.6)`. L1→2: 80 XP (about 27 s). L5: 1,050. L10: 3,185. Cumulative at the base 180 XP/min: L5 about 1.5K XP (8 min); L10 about 10.7K (about 60 min); L20 about 69K (about 6.4 h); L30 about 204K (about 19 h); L40 about 436K (about 40 h); L50 about 784K (about 72 h). Bonus XP shortens these by roughly 25%. |
| Level cap by rarity | Common 20, Uncommon 25, Rare 30, Epic 35, Legendary 40, Mythic 45, Secret 50, Exclusive 35 |
| Income | +3% per level: `1 + 0.03 × (L − 1)`. L10 ×1.27, L20 ×1.57, L50 ×2.47 |
| Value | +2% per level (§2.6) |
| Gating | Upgrade stages require car levels (§2.4) |
| Mileage | `mileage` += studs driven by any owner, shown in miles (1 mile = 5,700 studs). Flex stat; "Low Miles" trait; garage card shows "38,214 mi · 3 owners · stolen 2×". |

XP is **only** earned on the street. Parked cars never level, so the street stays the place where cars grow.

### 2.4 Upgrade tracks (per car, at the Mod Shop)

The Mod Shop is a GTA-style list menu (UI §5.13). Purchases go through a server-validated remote (§9.6) and are applied by `Shared/Util/CarStats.luau` (§9.4).

| Track | Stages | Effect per stage (index 0..max) | Price factors × `Cars.price` | Car level needed per stage |
|---|---|---|---|---|
| **Engine** | 0–5 | topSpeed +{0,3,6,9,12,15}%; accel +{0,5,10,15,20,25}% | {0.15, 0.30, 0.60, 1.00, 1.60} | {1, 5, 10, 20, 30} |
| **Turbo** | 0–3 | accel +{0,8,14,20}%; nitro refill +{0,10,20,30}% (`Vehicle.NITRO_REFILL_PER_SEC`) | {0.25, 0.60, 1.20} | {3, 12, 24} |
| **Handling** | 0–4 | grip +{0,.02,.04,.06,.08} (cap 0.98); `MAX_YAW_RATE` ×{1,1.05,1.10,1.15,1.20} | {0.15, 0.35, 0.75, 1.30} | {2, 8, 16, 25} |
| **Tires** | 0–3 | 1 Street: spike pop time −30%. 2 Run-flat: a shot or flat tire slows 20% instead of 35%. 3 Bulletproof: tires can't be shot, spike pop time −60%. | {0.25, 0.60, 1.20} | {3, 12, 24} |
| **Armor** | 0–5 | car damage ×{1, .85, .72, .60, .50, .40} (crash and bullets); topSpeed −{0,1,2,3,4,5}% | {0.15, 0.30, 0.60, 1.00, 1.60} | {1, 5, 10, 20, 30} |
| **Nitro** | 0–4 | tank {2.5, 3.5, 4.5, 6, 8} s (the v1 `Economy.Upgrades.nitro.values`, now per car) | {0.15, 0.35, 0.75, 1.30} | {2, 8, 16, 25} |
| **Tracker** | 0–3 | 0: alarm plus last-known ping every 20 s. 1: live GPS for owner and party while stolen. 2: also pings the thief to the whole server every 15 s, and Immobilizer ×1.5 raid hotwire time. 3: Kill Switch (owner stalls the engine for 4 s, once per theft), Immobilizer ×2.0, repo hold 1.5 s. | {0.25, 0.60, 1.20} | {3, 12, 24} |
| **Insurance** | 0–3 | payout {25, 32, 39, 45}% of value when the car is kept by a thief (§2.8). Always below the 50% sell value. | {0.25, 0.60, 1.20} | {3, 12, 24} |

- **Stage price:** `max(100 × stage, round(Cars.price × factor[stage]))`.
- **Cost to fully max a car:** about **20.6 × its price**. Examples: Legendary Gold Rush $300K → about $6.2M; Mythic Night Raven $1.5M → about $31M; Secret $20M → about $412M. This is the main late-game sink.
- **60% of upgrade spend adds to the car's value**, so the thief inherits it, which is why upgraded cars are worth stealing.
- **Old cars have a ceiling:** a Common's level cap of 20 stops Engine at stage 4. Rarity still matters.
- **v1 player-wide upgrades** (`Economy.Upgrades`):
  - `lock` becomes garage security (§2.7.3).
  - `hotwire` stays a player skill, the "Hotwire Kit", with the same values and prices.
  - `nitro` and `armor` become per-car tracks. Nothing is grandfathered: V2 starts on a fresh DataStore (§9.3).

### 2.5 Paint, finishes and traits

**Paint (cosmetic, chosen by the player, at the Paint Shop inside the Mod Shop).**
- **Options:**
  - primary and secondary colour from a 64-colour realistic palette (`Config/Paint`, never raw client colours, no pink or neon on the kill list);
  - type Gloss, Matte, Metallic or Pearl (Pearl adds an accent);
  - rims;
  - window tint 0–3;
  - plate text (filtered, 8 characters; Rep 10 or the Custom Plates pass);
  - underglow (Rep 10 or the Neon Kit pass).
- **Price per change:** `$250 + 2% × Cars.price`; the first paint job is free, and a **paint voucher** (trunk loot, §2.5.1) pays for one change.
- **Paint never changes income.**
- **Pay 'n' Spray** stays separate: it clears stars only while unseen, using the v1 cost `stars × max(SPRAY_COST_PER_STAR 250, SPRAY_INCOME_SECONDS 15 × G)`. V2 change: it keeps your paint job (v1 recoloured randomly).

**Finish (rolled once, fixed for the car's life, the collectible layer).** This replaces v1 `Rarity.Mutations`. The multipliers and weights are the v1 numbers, renamed for grounded GTA realism.

| Finish | Mult | Roll weight | Look (realistic, not ForceField) | Source | v1 equivalent |
|---|---|---|---|---|---|
| Stock | ×1 | 86 | Factory paint | Any | None |
| Gold | ×2 | 8 | Brushed gold metallic | Any | Gold |
| Chrome | ×3 | 3.8 | Mirror chrome, high reflectance | Any | Diamond |
| Chameleon | ×5 | 1.6 | Colour-shift pearlescent (hue by view angle, client) | Any | Rainbow |
| Galaxy | ×8 | 0.6 | Deep metal-flake with sparkle | Any | Galaxy |
| Storm | ×4 | 0 normally; replaces 10% of Stock rolls during Thunderstorm weather | Blue arc particles on the body | Weather event | new |
| Void | ×12 | 0; event or season only | Ultra-matte black with dark rim light | Live event | new |
| Glitch | ×15 | 0; Admin Abuse only | Flickering texture swap | Admin Abuse | new |

**Traits** (4% chance per minted street, traffic, dealer or Hot Drop car; independent of finish). The trait is rolled when the world car spawns but kept server-side (`car.data.trait`); it is **not** replicated as a model attribute, so the delivery reveal is a real surprise. The finish stays visible on the street because it is the paint.

| Trait | Effect |
|---|---|
| Turbo | Turbo stage 1 free on mint |
| Bulletproof | Tires stage 3 free on mint |
| Classic | Income ×1.10, value ×1.10 |
| Prototype (Legendary or better only) | Income ×1.20 |
| Low Miles | Value ×1.15, XP ×1.10 |

**"1 in X".** At mint, the server computes `oneInX = 1 / (P(rarity | source, district, luck) × P(finish | boost) × (trait and P(trait) or 1))` from the actual weights used (§6.2 district luck, EventService luck, `HOT_DROP_MUTATION_BOOST`). It is stored on the reveal payload, never on the record. Examples:

| Source | Car | P(rarity) | Odds alone | With finish |
|---|---|---|---|---|
| Downtown street spawn (luck 1.5) | Legendary | 0.98% | 1 in 102 | Galaxy: 1 in 17,000 |
| Port/Airport street spawn (luck 4.5) | Mythic | 0.24% | 1 in 414 | Galaxy: 1 in 69,000 |

Legendary and better reveals get a shard plus a server feed card (UI §5.15). A scripted car (the onboarding Gold Common) shows "street odds 1 in N", never "you rolled 1 in N".

#### 2.5.1 Delivery reveal and the trunk

Delivering a **street or traffic loot car** to your own garage opens the reveal card (rarity, finish, trait, "1 in X") and then pops the trunk. `Rolls.trunk(rng)`:

| Chance | Trunk content |
|---|---|
| 60% | Cash `50 + 10 s × G` into the wallet |
| 20% | One magazine for a gun you own (the equipped gun first; nothing if you own only melee, then cash instead) |
| 10% | Light armor (+50, capped at 100) or a med kit (capped at 3), whichever you have less of |
| 8% | A free paint voucher (`vouchers.paint += 1`, max 5) |
| 2% | A phone tip: the next Hot Drop location 60 s before it is announced |

- `server_luck`, district luck and live-ops multipliers never apply to the trunk.
- Trunk loot is bounded by the loop itself (each delivery needs a free slot), so it has no cap.
- Dealer, Hot Drop and player cars have no trunk roll.

### 2.6 Value, sell, chop and income formulas (`Shared/Util/EconomyMath`)

```
carIncome(c)  = def.income × finish.mult × (1 + 0.03 × (c.level − 1)) × trait.incomeMult
carValue(c)   = def.price × finish.mult × (1 + 0.02 × (c.level − 1)) × trait.valueMult
                + 0.6 × c.upgradeSpend
                then × (c.serial and (c.serial <= 10 and 1.5 or 1.2) or 1)
sellValue(c)  = floor(0.5 × carValue(c))                 -- Economy.SELL_FRACTION (v1 0.5)
chopValue(c)  = floor(0.35 × def.price × finish.mult)    -- Economy.CHOP_SHOP_FRACTION (v1); loot cars AND player cars:
                                                         -- no level, upgrade, trait or serial premium
insurance(c)  = floor(InsuranceRate[c.upgrades.insurance] × carValue(c))   -- {0.25, 0.32, 0.39, 0.45}
```

- Bound cars sell for 0 and can't be chopped. Exclusive cars use `def.price = 0`, so their value falls back to v1 `income × 120` for display only.
- A car with `sellLockUntil` in the future can't be sold (cars kept by theft: 7 days).
- A car with `inbound` set (a transfer not yet confirmed by the giver's save, §10.3) can't be sold, traded, staked or chopped.

### 2.7 Theft of owned cars

#### 2.7.1 Carjack on the street (new in V2; v1 blocked it with an owner-only seat)

1. **Target.** A player driving an `Owned` car outside safe zones. The driver must not be passive, rookie, spawn-protected, or within `CARJACK_VICTIM_IMMUNITY = 180` s of being carjacked (joyrides included); the thief must not be rookie or passive.
   - The prompt tells the thief what will happen before they commit: **"STEAL"** when the car can be kept, or **"JOYRIDE (protected: starter / shaken / day limit / last cars / bound / pair / outranked)"** when it can't, with a padlock icon on the car (§2.8, `ProtectedReason`).
2. **Stop the car.** Use spikes, tire shots, ramming or PIT, or down the driver.
   - The **CARJACK** prompt appears at the driver door when the car's speed is under `CARJACK_MAX_SPEED = 8` studs/s.
   - Hold time `CARJACK_HOLD = 0.8 s`. The driver sees a 0.4 s warning flash and can floor it to break the prompt.
   - **Disabled car (fast jack):** if the car has 2 or more flat tires, HP below 30%, or has stayed under 2 studs/s for 1.5 s after a collision, the hold is `CARJACK_HOLD_DISABLED = 0.4 s` with no warning and no throttle break. This is what makes carjacks land on mobile.
   - A stunned (taser) or downed driver's car can always be jacked (fast jack).
3. **Eject.** The victim is ejected and ragdolls for 1.5 s. **Only a LOADED victim spills 10% of their wallet** as cash pickups (`WALLET_SPILL_ON_CARJACK`, matching D5: only LOADED players drop cash). The car becomes kind `Stolen` (or `Joyride` if it can't be kept) with `car.data.theft = { victimUserId, uid, method = "carjack", keepable }`.
4. **Heat and spectacle.**
   - The thief gets **+2★** (`Police.Heat.carjackPlayer = 2`).
   - Server feed: "X carjacked Y's LV 23 Chrome Phantom GT".
   - The stolen car's icon pulses on **every** minimap every 15 s (always), or continuously with Tracker 2 or more.
   - The victim and their party get the live GPS (Tracker 1+) or the last-known ping every 20 s (Tracker 0).
5. **Deliver.** The thief has `CARJACK_DELIVERY_LIMIT = 180 s` to reach **their own drop-off**, which parks the car on the lay-low pad (§2.7.4).
   - Instead, they can chop it at the Chop Shop for the loot `chopValue` (§2.6: `0.35 × price × finish`, no level, upgrade or serial premium). That pay is minted and capped (§2.8) and is $0 between party members, crewmates or Roblox friends. The victim's car is not destroyed: it goes to their impound (free release after 120 s, or the fee). The chop **counts as a kept loss** for the victim's Shaken timer and daily cap, but pays no insurance because the car survives.
6. **Drop.** If the thief is downed, busted or ejected, or leaves the seat, the car is **dropped** (v1 `DROPPED_CAR_TIMEOUT 20` / `THEFT_ABANDON_LIMIT 12`).
   - The victim gets an instant Recover prompt.
   - Anyone else can take over the theft with a 1.5 s hotwire (v1 behaviour).
   - Whoever downs the thief while the car is in delivery gets the **Interceptor reward** `500 + 30 s × G` (minted; capped at 5 per day and once per pair per 30 min).

#### 2.7.2 Garage raid (v1 flow, extended)

Unchanged from v1:
- the victim must be online;
- the lock must be down;
- the raider must be inside the garage interior;
- the raider holds Steal for `rarity.hotwireTime × THEFT_HOLD_MULTIPLIER 1.4` × the car's Immobilizer factor (Tracker 2: ×1.5, Tracker 3: ×2.0) × the raider's Hotwire Kit factor;
- the car is driven out, then delivery within `THEFT_TIME_LIMIT = 150 s` to the thief's drop-off.

V2 changes:
- Delivery now ends in the lay-low bay, not in a slot.
- Vault bays are never raidable.
- Garage security (§2.7.3) adds breach time and earlier alarms.

#### 2.7.3 Garage security (per player, bought at the Mod Shop)

| Upgrade | Levels and effect | Prices |
|---|---|---|
| **Laser Lock** (v1 `Upgrades.lock`) | Lock duration {45, 60, 90, 120, **180**} s. Re-arm after `max(15, 0.5 × last duration)` (DECISIONS §8). +10 s per prestige (v1). | {2,500, 30,000, 350,000, **2,500,000**} |
| **Alarm** | 0: owner alerted when a hotwire starts (v1 IntruderAt). 1: alerted when a non-owner **enters**. 2: also highlights the intruder through walls for the owner and their party. | {20,000, 400,000} |
| **Reinforced Door** | While unlocked, a raider must hold BREACH at the door for {0, 3, 6} s. Level 2 breach adds +1★ to the raider. | {50,000, 1,000,000} |

#### 2.7.4 Lay-low window, repo and outcome

**Rule: the car record stays in the victim's profile until the theft is final, and moves exactly once, while both profiles are loaded in this server** (the v1 rule "the record never left their data", `TheftService` `onPlayerRemoving`). There is no `laylow` place, no escrow store and no mail return.

| Phase | Rule |
|---|---|
| **On delivery** | The car parks on the thief's lay-low pad, outside the door and visible, earning 0. The record stays in the **victim's** profile with runtime state `LayLow` (the victim's pad shows MISSING; the slot stays reserved). The victim's slot `uncollected` is paid to the victim's bank now (v1 rule). The thief's free slot stays reserved. |
| **During the 300 s** | **REPO:** the victim, or the victim's party while the victim is online in this server, holds 3 s (1.5 s with Tracker 3) to drive it away. Delivering it to the victim's drop-off cancels the theft; nothing moves in data. The thief can defend. |
| **Repo succeeds** | The car goes back to its slot. The victim gets a **Repo bonus** of 30 s × G (v1 `RECOVERY_BONUS_SECONDS`) plus 150 RP, at most `REPO_BONUS_PER_DAY = 3` paid repos per UTC day (RP capped the same way). No insurance; the theft doesn't count as a loss. |
| **Window ends** | `CarService.transfer(victim, thief, uid, "theft")` runs once (§10.3). The record lands in the thief's reserved slot. Ownership is final: `owners += 1`, `thefts += 1`, `acquiredAt = now`, `tradeLockUntil = now + 7 d`, `sellLockUntil = now + 7 d`, `lastTransfer = { from = victim, at = now, kind = "theft" }`, and **the plate resets** (it may contain the victim's name). Level, XP, upgrades, paint (except the plate), finish, trait, serial and mileage carry over. The victim's **insurance** is credited to their bank in the same step if §2.8 allows. |
| **Thief leaves, crashes, or the server shuts down** | The theft is cancelled: the victim keeps the car (it was always in their data). The lay-low car is despawned and the victim's slot restores. Combat-logging never secures a car. |
| **Victim leaves during delivery or the window** (not a shutdown) | The theft **finishes immediately** inside the victim's `DataService.Releasing` handler: the record is removed from the victim's `data` there (so it is gone from the victim's final save), insurance is credited to the victim's bank in that same final save, and the record is inserted into the thief's profile with `inbound` set until the victim's final save succeeds. Repo rights already end when the victim leaves, so gameplay is unchanged, and a rage-quit never saves a car. If the thief was still in the delivery phase, the in-world car converts to the thief's own `Owned` car where it stands. |
| **Server shutdown** (`DataService.isShuttingDown()`) | Every open theft and lay-low resolves in the **victim's** favour, and no combat-log penalty is applied (§10.3). |

**REVENGE mark** (distinct from gta_combat's anti-camp "revenge immunity"):
- **Triggered by:** stealing your car (any method, including a joyride), mugging you, or downing you while you were not wanted.
- **Effect:** the victim gets a red mark on the offender for `REVENGE_MARK_SECONDS = 900`. The mark records `offenceCost`: the car's value if it was kept or chopped, the cash mugged, or the hospital bill plus cash dropped.
- **Downing a marked player:**
  - pays `500 + 30 s × G` (v1 `REVENGE_BONUS_SECONDS` 20 → **30**; minted), only if `offenceCost ≥ max(1,000, 30 s × victimG)`. Below that, the mark still grants vigilante status but pays $0;
  - at most `REVENGE_BONUS_PER_DAY = 3` paid per UTC day, and once per pair per `BONUS_PAIR_COOLDOWN` 600 s;
  - adds no heat (vigilante rule) and no Menace;
  - shows "REVENGE" in the feed.

### 2.8 Keep-on-steal protections (fair play)

All rules below are evaluated by one pure function, `TheftRules.canKeep(ctx) -> (ok, reason)` (§9.4), with one table-driven test per row. The first failing rule's `reason` is what the thief's prompt and the victim's padlock show.

**Owner-wide protections** (no thief can keep any of your cars; while one applies, every drive you take is a protected drive capped at **×5**, `S_CAP_PROTECTED`; the player attribute `ProtectedReason` names it):

| Protection | Rule | Value (Config/Theft) | Why |
|---|---|---|---|
| **Starter protection** (`starter`) | Your cars can't be *kept* (carjack becomes a joyride; garage raids are refused) until **both** `rep ≥ 8` **and** `activePlaytime ≥ 7,200 s`. It is a **one-way latch** (`starterDone`); owning more or fewer cars never turns it back on. It also ends the moment you keep or chop another player's car. | `STARTER_REP = 8`, `STARTER_ACTIVE_SECONDS = 7200` | First two hours are safe; no farming it back |
| **Last cars** (`lastcars`) | A thief can't keep a car if the victim would be left with fewer than 2 non-bound cars | `MIN_CARS_KEPT = 2` | Never unplayable |
| **Shaken** (`shaken`) | After a **counted** loss, none of your cars can be kept for 10 min | `VICTIM_COOLDOWN = 600` | No chain-looting |
| **Daily loss cap** (`daycap`) | After `MAX_LOSSES_PER_DAY` counted losses in a UTC day (**1 while you are below Rep 15**, 3 after), your cars are protected until 00:00 UTC (shield icon on the garage sign) | `MAX_LOSSES_PER_DAY = 3`, `MAX_LOSSES_PER_DAY_LOW = 1`, `LOW_REP = 15` | Anti-quit |
| **Counted loss** | A kept or chopped car counts toward Shaken and the daily cap **only if its value is at least 20% of the victim's most valuable non-bound car**. Losing a junk car is still a loss; it just can't be used to buy a shield. | `LOSS_COUNT_MIN_VALUE_SHARE = 0.20` | Closes "lose 3 Rustbuckets to alts, then drive the hypercar at ×10" |

**Per-car and per-pair rules** (they don't cap S×, because another thief could still take the car):

| Protection | Rule | Value (Config/Theft) | Why |
|---|---|---|---|
| **Rookie protection** | The first 10 min of playtime: no PvP at all, either way (gta_combat §8, delta D12). It ends early if you deal player damage, mug, carjack or raid, buy a rifle, **pick up event loot** (with a confirm prompt), or opt out from the HUD pill. | `ROOKIE_SECONDS = 600` | First-minute bounce, without emptying launch servers of PvP |
| **Vault bays** | Parked vault cars can never be stolen. When driven, they are normal cars. | 1 (Rep 5), +1 (Rep 25), +1 (pass) | Endowment without stagnation |
| **Bound cars** (`bound`) | Carjack is a joyride only: the drop-off refuses the car, which returns home after 60 s abandoned or a 120 s timer, and it can't be chopped. Bound cars can't be traded or pink-slipped. Always a protected drive (×5). | `S_CAP_PROTECTED = 5` | Robux never buys street immunity at full reward |
| **Pair cooldown** (`pair`) | The same thief can keep a car from the same victim at most once per 60 min | `PAIR_COOLDOWN = 3600` | Anti-bullying |
| **Punch-down rule** (`outranked`) | If `thief.rep − victim.rep > max(6, floor(victim.rep / 2))`, the thief can joyride but not keep, and chop pays 0. Exceptions: the victim is at 3★ or more, or holds a REVENGE mark on the thief. | `PUNCH_DOWN_MIN_GAP = 6` | Veterans don't farm newcomers; the gap scales with the victim |
| **Counterparty rule** (`counterparty`) | A thief can't keep or chop a car they **traded or pink-slipped** to this victim within the last 72 h (`lastTransfer` on the record) | `COUNTERPARTY_LOCK = 259200` | No "trade it, then raid it back" |
| **Carjack immunity** | 180 s after any carjack of you (joyride included), you can't be carjacked again | `CARJACK_VICTIM_IMMUNITY = 180` | No pull-out loops |
| **Friends** | Thief and victim in the same party or crew, or Roblox friends: the car can be kept, but **no insurance and no chop pay** | — | Friends can't mint money from each other |
| **Offline** | Offline players can't be robbed (their plot and cars are not in the world; v1) | — | — |

**Payout rules:**

| Rule | Detail | Value (Config/Theft) | Why |
|---|---|---|---|
| **Insurance** | Credited to the victim's bank at the final transfer: `InsuranceRate[track] × value`, rates {25, 32, 39, 45}% (always below the 50% sell value). Only if the victim has held the car for at least 20 min, at most 3 claims per UTC day, the first claim per pair per 24 h, never between friends, and never for **reward-origin** cars (playtime, daily, referral, codes). | `INSURANCE_RATES`, `INSURANCE_MIN_HOLD = 1200`, `INSURANCE_CLAIMS_PER_DAY = 3` | Loss softening that alts can't farm |
| **Insurance clawback** | The payout is recorded in the victim's `insured[uid] = { amount, until = now + 7 d }`. If that uid returns to them by **any** route (trade, pink slip, theft, repo after transfer) before `until`, the amount is taken back from their bank (then wallet), shown as "Insurance repaid". | `INSURANCE_CLAWBACK_SECONDS = 604800` | Insure-then-recover loops pay nothing |
| **Player-car chop** | Pays the loot `chopValue` (§2.6), at most 3 per UTC day, with the pair rule and the 20-min hold rule. Counts as a kept loss for the victim. The car goes to the victim's impound. $0 between friends. | `PLAYER_CAR_CHOPS_PER_DAY = 3` | Quick-cash option that can't be farmed |
| **Repo window** | 300 s | `LAYLOW_SECONDS = 300` | Revenge arc instead of a rage-quit |
| **Theft locks** | A kept car is trade-locked and sell-locked for 7 days | `THEFT_TRADE_LOCK = 604800`, `THEFT_SELL_LOCK = 604800` | Stolen cars can't be laundered straight to cash or to a main |

**Visibility.** The victim-side `ProtectedReason` attribute (`starter` / `shaken` / `daycap` / `lastcars`, or nil) is replicated per player; per-car `Bound` is a model attribute. The client works out `pair`, `outranked` and `counterparty` from public `Rep`, `RevengeState` and the thief's own recent history, so the prompt can read "STEAL" or "JOYRIDE (protected: reason)" before the hold. The server re-checks everything at the final transfer.

**V2.1 Car Keys interaction.** A lent car earns **no garage income** while lent, and the borrower drives at the **owner's** S× cap, so a protected owner can't lend out a full-rate car.

### 2.9 Limited numbered cars

- **What they are.** Event, seasonal and Admin Abuse cars with a serial number (`#7 of 500`). Caps per car are 100, 250, 500 or 1,000 (`Cars[id].limitedCap`).
- **How they are minted.** `SerialService.mint(carId)` runs a DataStore `UpdateAsync` on `HC_Serials_v1/<carId>`. It returns the next serial, or nil when sold out.
- **Owner registry.** `HC_LimitedRegistry_v1/<carId>#<serial>` holds `{ ownerUserId, uid, xferSeq }`. The record carries the same `xferSeq`, which goes up by one on every transfer. The registry is written after each transfer (theft finalisation, trade, pink slip); that write may fail or be throttled on its own without harming the car.
- **How to get one** (never for Robux):
  - complete an event challenge, which unlocks the right to buy it with cash at the dealership during the event;
  - Admin Abuse drops;
  - season tier 50 on the free track, which is a Rare-band limited car.
- **Rules:**
  - Limited cars **can** be stolen and traded. "Someone stole my #7" is the clip.
  - Vault them to keep them safe.
  - Serials #1–10 get a gold plate frame and a ×1.5 value premium; the rest get ×1.2.
- **Dupe guard.** On profile load, every serial car is checked against the registry:
  - same uid and the record's `xferSeq` is **higher** than the registry's → the registry lagged; repair it;
  - same uid and equal → fine;
  - lower `xferSeq`, or a different uid holds the serial → the car is **frozen** (`frozen = "serial"`: it can be driven and parked but not traded, staked, sold or chopped) and flagged to `/hc audit`.
  - Nothing is ever retired automatically. An admin decides; `retiredCars` keeps the **full** `CarRecord`, so a wrong call can be undone.

### 2.10 Catalog direction (for the vehicles workstream)

- **Bands stay.** Keep the v1 income and price bands per rarity from `Config/Cars.luau`:
  - Common $3–7/s, $120–400
  - Uncommon $14–24/s, $1–2.4K
  - Rare $55–75/s, $7–11K
  - Epic $220–320/s, $40–65K
  - Legendary $900–1,300/s, $250–400K
  - Mythic $4–6K/s, $1.5–2.5M
  - Secret $20–40K/s, $10–30M

  New realistic parody cars slot into these bands, so every formula in this document holds.
- **Secret tier.** Becomes realistic prototypes: an armored limo, a concept hyper, a jet-engine land-speed car.
- **Meme cars** (hotdog, duck, couch, toilet) become hidden collectibles. Each has a 5% share of the Secret Hot Drop roll, and none are Index requirements.
- **Diamond Dragster** (`Exclusive`, 15,000/s, top speed 190) is **re-tuned before it is ever sold**: its id is 0 and it has never been sold. It becomes bound, with income in the Epic band ($300/s) and top speed capped at 160 (the Legendary band).

---

## 3. Crime sandbox

### 3.1 Payout formula (`Shared/Util/Payout.luau`, pure, unit-tested)

```
payout = floor( (base + secs × G) × districtMult × wantedMult[stars at payout] × partyMult × liveOpsMult × passiveMult )
partyMult   = 1 + 0.10 × (party members within 150 studs at payout), max 1.30
passiveMult = 0.5 while in Passive mode (PvE crimes only), else 1
liveOpsMult = e.g. 2 during "Double Crime Cash" weekends (§6.7)
```

- `stars at payout` includes stars the crime itself just added, so a robbery at 0★ pays ×1.5 (2★).
- **Clamps first, events last.** Where a payout has a per-player clamp (truck §3.6, heist §3.7, Most Wanted §3.12), the clamp applies to the base-and-wanted amount, and `liveOpsMult` and event multipliers (Golden Truck, Bounty Night) apply **after** it, so an advertised ×5 really is ×5.
- **Over a soft cap** (Law 10): the payout is multiplied by `CAP_SOFT_MULT = 0.25` and the breakdown adds "(limit reached: reduced)".
- Payouts land in the **wallet**.
- RP and car XP are granted at the same time.
- Every payout is logged to EconomyTelemetry (§7.5).

**Show the stack (Law 9).** Every §3.2 payout, truck bag, heist share, bounty and evade bonus fires `PayoutBreakdown { amount, base, mults = { {label, value} } }` to the earner. The HUD prints it under the cash delta, for example **"$12,400 · ×1.5 WANTED 2★ · ×1.25 DOWNTOWN · ×1.1 PARTY"**. Multipliers of exactly 1 are omitted. At 3★ and above the wanted chip pulses gold as the payout lands. That frame is the clip.

### 3.2 Activity table

| Activity | Rep | Duration | base | secs × G | Heat | Cooldown | RP |
|---|---|---|---|---|---|---|---|
| Street steal and deliver | 1 | 1–2 min | the car + trunk (§2.5.1) | — | rarity `wantedChance` / `wantedOnSteal` (v1), additive | — | 30 + 10 × rarity order |
| Chop a loot car | 1 | dwell 2 s (v1 `CHOP_DWELL`) | `chopValue` × order mult {1, 1.5, 2, 3} | — | — | — | 30 (order: 80) |
| Evade bonus | 1 | — | $100 per star | 15 per star | — | 6 paid per hour, then ×0.25 | 20 per star |
| NPC mugging | 1 | 1.5 s hold | $40 | 8 | +1★ at 50% | 120 s per ped; ×0.25 after 10 muggings in 10 min | 8 |
| Convenience store hold-up | 1 | 8 s fill | $500 | 120 | floor 1★ at start, floor 2★ at full | 300 s per store (server); 45 s per player | 80 |
| Gas station | 6 | 10 s fill | $800 | 150 | floor 2★ | 300 s per store | 100 |
| ATM hack | 6 (Hacking Device $2,500) | 6 s mini-game | $300 | 90 | floor 2★ | 600 s per ATM | 70 |
| Jewelry store | 8 | ~90 s | $800 per case × 8 | 30 per case × 8 | floor 3★ at the first smash | 900 s (server) | 250 |
| Pawn shop | 10 | 12 s fill | $1,500 | 200 | floor 3★ | 480 s per store | 140 |
| Phone jobs (§3.10) | 1–10 | 1–3 min | $300 | 60–120 | varies | per job; 20 paid per day, then ×0.25 | 60–120 |
| Armored truck bag | 3 | 2–4 min | §3.6 | §3.6 | floor 3★ on crack | 300 s pulse; 12 bags per hour, then ×0.25 | 200 per bag delivered |
| Bank heist | leader 10, members 3 | 8–10 min | §3.7 | §3.7 | floor 3★ → floor 4★ | 1,800 s big pulse | 800 + 100 per bag |
| Hot Drop | 1 | 2 min | Legendary-or-better car | — | +3★ (v1 `Heat.hotDrop`) | 600–900 s | 250 |
| Player mugging | 5 (off rookie) | 1.5 s hold | 25% of the victim's wallet (transfer) | — | +1★ (`mugPlayer`) | victim immune 120 s | 40 |
| Carjack and keep a player car | 5 | 2–5 min | the car (transfer) | — | +2★ (`carjackPlayer`) | §2.8 | 150 (raid 200) |

**Heat notation.** "floor N★" means `WantedService.raiseTo(player, N)`: stars become `max(current, N)`, so a robbery at 0★ ends at the listed level and never stacks to 5★ by itself. "+N★" means the additive `addHeat` (§3.11).

**Stage C examples** (G = $800/s, Downtown ×1.25):
- Convenience store: `(500 + 96,000) × 1.25 × 1.5` = **$181K**.
- ATM hack: `(300 + 72,000) × 1.25 × 1.5` = **$135K**.
- Jewelry store: `8 × (800 + 24,000) × 1.25 × 2.0` = **$496K**.

These match the "street pays 3–10× the garage" pillar: about $180K for roughly 60–90 s of work, against $48–72K of garage income over the same time. Starting the same store at 2★ (mid-chain) ends at 2★ and pays the same ×1.5; starting at 3★ pays ×2.0, because stars only ever add risk you already took.

### 3.3 Store robberies (convenience stores, gas stations, pawn shop)

- **Where.** POIs [world]: about 6 convenience stores, 3 gas stations and 1 pawn shop. The brand is our parody, e.g. "Kwik Stop", never "24/7".
- **Start.**
  - Equip any gun and aim at the clerk for 0.5 s within 15 studs, **or** hold the HOLD UP prompt on the counter with a gun equipped (the mobile path).
  - The server checks: the gun is equipped (WeaponService), the player is inside the store volume, the cooldowns, and that the player is not passive. Passive players can rob PvE stores at passiveMult 0.5.
- **Fill.**
  - The register fills linearly over the fill time while you stay within 12 studs.
  - The fill rate is ×0.5 while you don't aim at the clerk.
  - Leaving early pays the fraction filled.
  - Heat comes at start and at full, per the table.
- **Clerk variance.** There is a 10% chance the clerk is "Brave": he ducks and comes back up with a pump shotgun for one blast (25 damage). This creates story without frustration.
- **Payout** goes to the wallet at full fill (or on leaving early). `stats.robberies += 1`.

### 3.4 Mugging

- **NPC pedestrians.** Aim at them or hold MUG within 6 studs. The ped drops a wallet pickup worth `(40 + 8 s × G) × mults`. They then flee (gta_combat §9.5 pedestrian rules). Diminishing returns stop farming.
- **Players.** The target is on foot, outside safe zones, has no rookie, passive or spawn protection, and their wallet is above 0.
  - Hold MUG for 1.5 s within 4 studs, behind the target (more than 90° from their facing), or on a stunned or ragdolled target from any angle.
  - The target gets a 0.5 s "HANDS OFF" warning and breaks the hold by moving 6 studs or hitting the mugger.
  - Takes `MUG_RATE = 25%` of the victim's wallet. This is a pure transfer.
  - The victim gets a REVENGE mark and is immune to further mugging for 120 s.
- **LOADED drop.** A player **downed by another player while LOADED** drops 20% of their wallet as a cash bag. If they were also wanted, the drop comes out of their wanted loss rather than on top of it (§4.3).
  - The killer has priority for 3 s, then anyone can take it. It vanishes after 30 s, which is a sink.
  - Non-LOADED, non-wanted players drop nothing, matching gta_combat's "no kill-farming" rule.

### 3.5 ATMs and banking

- **ATMs.** About 10 [world]. Hold DEPOSIT for 2 s at 0★. `ATM_FEE = 5%`. ATMs are natural mugging hot spots: GTA culture, and a skill test for the depositor.
- **Garage deposit.** Entering your own garage interior at 0★ deposits the whole wallet automatically and free. While wanted, the garage is still a safe house (v1: cops wait outside, no bust). Stars decay inside, then you deposit.
- **No withdrawals.** Spending already uses the wallet, then the bank.
- **ATM hack (Rep 6).** Needs the Hacking Device ($2,500, permanent).
  - The mini-game is a 3-step pattern match over 6 s, mobile friendly.
  - The server drives the step timing. The client only sends `MiniGameInput(sessionId, step, value)`, and the server validates each step against its own seed.
  - Failing a step adds 1★ and 2 s.

### 3.6 Armored truck (every 300 s)

| Stage | Rule |
|---|---|
| Announce | At T−30 s, a feed card and phone text: "ARMORED TRUCK leaving <depot>", with the route drawn on the map. Route: depot → 3 bank stops on the RoadGraph, about 150 s at 35 studs/s. Needs at least 1 player at Rep 3 or more in the server. |
| Stop it | Truck: 2,000 HP and 4 tires at 150 HP each. It halts when 2 tires are flat, HP is below 30%, or it is pinned under 3 studs/s for 4 s (ramming or PIT). Two NPC guards step out: 60 HP, pistols, 2★-level accuracy (gta_combat PoliceAim). |
| Crack the doors | Hold CRACK at the rear doors for 8 s. Extra crackers speed it up: `8 / (1 + 0.5 × (n − 1))`. Everyone within 50 studs at crack time is raised to at least 3★. |
| Bags | 4 bags. A carrier holds 1 bag (2 with the Duffel at Rep 15) and is slowed 10% per bag. A $ blip shows on every map (`MapBlips` kind `bag`). Bags go in a car's trunk automatically when the carrier enters a car. A rookie may pick one up after a confirm prompt ("Taking event loot ends your Rookie Protection"). |
| Deliver | At your own garage drop-off, or a party member's garage while they are online. The bag pays into the wallet on delivery. Dropped on WASTED (lies 60 s); confiscated on BUSTED. |
| Bag value | Frozen at spawn: `bagBase = 2,000 + 120 s × medianG(server, excluding rookie or AFK players)`. At delivery: `pay = min(bagBase, 5,000 + 300 s × ownG) × wantedMult × partyMult × eventMult`. The clamp is a catch-up bounded by the deliverer's own scale; `eventMult` (Golden Truck ×5, live-ops) applies after it. |
| Bag label | Each client shows **its own** value: `min(bagBase, 5,000 + 300 × ownG) × current wantedMult × eventMult`, computed from the public `bagBase` (in `TruckState`) and its own `G` attribute. A low-G player sees "$31K", not the server median, so the payout matches the label. |
| Unstopped | The truck reaches the last bank and despawns. |
| Caps | 12 truck bags per player per hour at full pay, then ×0.25 (Law 10). Golden Truck (Admin Abuse): `eventMult = 5`, applied after the clamp. |

### 3.7 Bank heist (big pulse, solo or crew of up to 4)

Ships behind `Flags.HEIST_ENABLED` (brief §3.13 puts the heist in fast follow; the flag lets it land after launch without a rebuild).

**Gate:**
- The window opens every 1,800 s and stays open for **600 s**.
- One heist per window per server.
- The first eligible group to start claims it: the leader's party members within 30 studs of the bank's back door.
  - **Leader:** Rep 10 or more, not rookie, not passive.
  - **Members:** Rep 3 or more, not passive. A rookie may join after the same confirm prompt the truck uses ("Joining a heist ends your Rookie Protection").
  - **Crew size 1–4.** A solo player can run it.
- The lobby has an **Invite friend** button (`SocialService:PromptGameInvite`) and a 60 s countdown so a friend can join the party and reach the door.
- The leader pays the **Heist Kit**, `10,000 + 30 s × leaderG` (a sink).
  - **Refunded** if the crew fails after the drill finished (they really tried).
  - **Lost** if the crew wipes or abandons before the drill starts; then, if at least 180 s of the window remain, the window **reopens** for another group. A griefer can't burn a window for free.

**Roles** are picked in the lobby. Solo, one player holds all four. With 2 players the roles pair up as Hacker+Driver and Gunman+Lookout; with 3, as Driver, Hacker, and Gunman+Lookout.

| Role | Unique job | Objective bonus (+5% of the pot, paid to whoever completed it) |
|---|---|---|
| Driver | The getaway car spawns as theirs: their own car parked at the back alley, or a free Getaway Van (kind `Getaway`, not ownable). The getaway car gets +500 car XP. | Getaway under 180 s |
| Hacker | The only one who can do the keypad hack: a 3-round pattern, 8 s. A failure triggers the alarm early. | Hack first try |
| Gunman | Starts with +50 armor, free. Holds the lobby during the drill. | Nobody downed during the drill |
| Lookout | Sees police units and cameras on the minimap. One "Scanner" use delays the SWAT wave by 20 s. | Both cameras disabled before the drill |

**Stages** (target 8–10 min):
1. **Infiltrate** (≤ 60 s): hack the side door and disable 2 cameras (shoot them or hold 2 s).
2. **Vault** (about 90 s): the drill runs for 60 s.
   - Every ~15 s it overheats. Someone must hold COOL for 1 s within 4 s, or the drill pauses.
   - The silent alarm raises the crew to at least 3★ at drill start and at least 4★ at drill end (floors, so a heist crew is never pushed to 5★ by the heist alone).
3. **Loot** (≤ 45 s): **2 bags per crew member** (2, 4, 6 or 8), 4 s each to grab, at most 2 carried per player.
4. **Getaway** (2–4 min): a 4★ chase with the heli sniper (gta_combat §9.1).
   - Deliver to any crew member's garage drop-off, or the Docks safe house [world: Iron Bay on the gameplay plan].
   - Bags dropped by downed crew can be stolen by anyone. Rivals who deliver a heist bag get 50% of its value.
5. **Payout:**

   ```
   bagValue = 15,000 + 450 s × crewMedianG
   pot      = Σ delivered bagValue × wantedMult(carrier stars at delivery) × partyMult(crewSize)   -- partyMult 1.0 / 1.1 / 1.2 / 1.3
   share_i  = pot / crewSize + 0.05 × pot × objectivesCompletedBy_i
   share_i  = min(share_i, 60,000 + 3,600 s × memberG_i) × eventMult                           -- clamp first, events after (§3.1)
   ```

   - **Equal split only.** There is no leader-set split, so nobody can be talked into 15%. Objective bonuses go to whoever completed the objective.
   - **The split is enforced:** whoever carries the bag, every crew member is paid their share at delivery. Overflow above a member's clamp is destroyed (a sink), never redistributed.
   - **Stage C example, crew of 4 at G 800:** 8 bags × $375K × 2.5 (4★) × 1.3 = $9.75M pot; $2.44M each plus one objective each (+$488K) ≈ **$2.93M each**, just under the $2.94M clamp. That is about 61 min of garage income for about 9 min of play.
   - **Solo at G 800:** 2 bags × $375K × 2.5 = $1.875M, plus up to 4 objectives (+$375K) = **$2.25M**, for a harder run. The party bonus is why crews earn more per head.
   - The clamp only binds on a low-G member carried by a rich crew: at G 50 the clamp is $240K.
6. **Fail:** if every crew member is downed or busted with no bags delivered, the payout is 0. The kit is refunded if the drill had finished (see Gate).

### 3.8 Jewelry store (server cooldown 900 s)

- **The run.** 8 display cases, each smashed in 2 s with a melee weapon or one gunshot. The first smash gives 3★.
- **Payout.** Each case pays `(800 + 30 s × G) × districtMult × wantedMult` into the wallet when smashed. Any player can smash, so it's a scramble.
- **Gate.** Rep 8. Rookies and passive players are excluded.
- **Visibility.** Open or closed with a countdown on the map (§3.13).

### 3.9 Chop shop and order board

- Chopping a **loot** car (street, traffic, dealer-stolen) pays `chopValue × wantedMult` (v1 rules, the dwell, and refusing tainted cars).
- **Order board.** Refreshed on each pulse, shown in the phone's Jobs app and on a board at the Chop Shop.
  - 3 server-wide orders, each fillable by the first 3 deliveries.
  - Examples: "Any Muscle, Rare or better", "Blue Sedan", "Any Gold finish".
  - Order mults: easy ×1.5, medium ×2, hard ×3. An order adds +50 RP.
- **Player cars:** §2.7.1 (loot `chopValue` with no level or upgrade premium, capped, $0 between friends, the victim's car survives in impound and the chop counts as a loss).

### 3.10 Phone jobs (the brief's "small missions")

| Job | Loop | Payout | Notes |
|---|---|---|---|
| Repo | Steal a marked NPC car and deliver it to the lot | 300 + 90 s × G; 1★ | The tutorial's second mission |
| Delivery | Drive a package A → B under a par time | 300 + 60 s × G | No heat |
| Taxi | An NPC passenger with a chaotic request ("faster!", "take the beach road") | 300 + 60–120 s × G | Driving skill |
| Stunt jumps | Hit marked ramps (one-time 50 RP each, plus a daily repeat) | 200 + 30 s × G | Collection |
| Lose the cops | Start at 3★ and evade within 120 s | 300 + 120 s × G | Chase practice |

Jobs: 1–3 min each, 60 s cooldown between jobs, 20 full-pay jobs per day, then ×0.25 (Law 10). Onboarding missions 1–4 (§1.3) are scripted jobs from the same contact and don't count toward the 20.

### 3.11 Wanted multipliers and police escalation

- **Escalation** per star follows gta_combat §9.1: 1★ arrest only; 2★ fires only at armed suspects; 3★ lethal plus roadblocks; 4★ heli sniper and spikes; 5★ SWAT and relentless ramming. Evasion is the GTA search area with an all-at-once clear (gta_combat §9.4).
- **This document adds:**
  - **District police factor** (§6.2): `UNITS_PER_STAR {1,2,3,4,6}` × factor, rounded, still capped by `MAX_UNITS_GLOBAL 14`.
  - **Response delay** by district (spawn-to-pursuit): 8 / 6 / 5 / 5 / 4 / 3 s.
  - **Two kinds of heat.** v1 `WantedService.addHeat` is additive (stars += n). That is right for a crime that is *extra* on top of what you were already doing, and wrong for a robbery level: an additive store (1 + 2) would end at 3★, and a pawn job (3 + 3) at 5★ and a server-wide Most Wanted every time. So:
    - **`Config/Police.HeatFloor`** (new) is used through the new `WantedService.raiseTo(player, n, reason)`, which sets `stars = max(stars, n)` and refreshes the evade timer:

      | Key | Floor |
      |---|---|
      | `storeStart` | 1 |
      | `storeFull` | 2 |
      | `gasStation` | 2 |
      | `atmHack` | 2 |
      | `pawnShop` | 3 |
      | `jewelry` | 3 |
      | `truckCrack` | 3 |
      | `bankAlarm` | 3 |
      | `bankDrill` | 4 |

    - **`Config/Police.Heat`** stays additive, only for acts that escalate on top of anything else:

      | Key | +Stars |
      |---|---|
      | `carjackPlayer` | 2 |
      | `mugPlayer` | 1 |
      | `mugNpc` | 1 (50%) |
      | `flash` (hot ride, §2.2) | 1 |
      | `breach2` | 1 |
      | `impoundBreak` | 2 |
      | v1 keys (`carjack`, `dealerSteal`, `playerTheft`, `hotDrop`, `assault`, `copHit`) | unchanged |

    The combat heat keys belong to gta_combat §9.5 and stay additive.
- **wantedMult** `{1.0, 1.2, 1.5, 2.0, 2.5, 3.0}` applies to every §3.2 payout, to truck and heist deliveries, and to the street multiplier (+1 per star, §2.2).
- **The evade bonus** pays only on a true evade, not on a spray, Lawyer or Lose-the-Cops clear: `stars × (100 + 15 s × G)`.

### 3.12 Bounties and the Most Wanted hunt

1. **Street bounty** (gta_combat §8, zero-sum). Any player at 4★ or more carries `min(10% of wallet, stars × 20 s × G)`.
   - It is paid **from the target's wallet** to whoever downs them. Cops never claim it.
   - It pays once per (killer, target) pair per 30 min.
2. **Most Wanted (5★ server event, new).** On reaching 5★:
   - **Announcement:** a shard to all, "MOST WANTED: <name>". The target's position pings to every player every 20 s and is continuous within 300 studs.
   - **Police reward** (minted, the only minted bounty), paid on top of the street bounty to the player who downs the target:

     ```
     growth = min(3, 1 + 0.1 × floor(secondsAt5Star / 30))
     reward = min((2,500 + 60 s × targetG) × growth, 25,000 + 900 s × claimerG) × eventMult
     ```

     The second term is the claimer's own clamp (§7.5.1): a G 50 claimer who downs a G 40K target gets at most $70K, not $7.2M, and an alt can't pump value into a main. It needs 60 s or more at 5★. The claimer can't be in the target's party or crew, or on their Roblox friends list. Each claimer gets 3 rewards per UTC day, once per pair per 30 min. If the police get the target (BUSTED or downed by police), nobody claims.
   - **Survival:** a target who evades from 5★ earns `1,000 + 60 s × G × min(10, minutesAt5Star)` into the wallet, at most `SURVIVAL_PER_DAY = 2` paid survivals per UTC day, and `stats.longestFiveStar` updates the **Most Wanted** leaderboard (the board always updates).
3. **Player-placed bounties:** not in V2.0 (§0.3).

### 3.13 What's open to rob (the Jailbreak lesson)

Players must never drive across the city to find "on cooldown".
- **`CrimeState`** (server → client, sent on join and whenever a POI changes): `{ {poiId, kind, open, reopensAt?} }` for every store, gas station, ATM, the pawn shop, the jewelry store and the bank (heist window).
- **Map icons:** lit when open; grey with a countdown ring when closed, on the minimap and the full map.
- **Phone › Jobs › "Hot spots":** the 5 nearest open targets with distance and payout tier ($ to $$$$, from the §3.2 base and secs at the viewer's own G).
- Per-player cooldowns (the 45 s store cooldown) show only to that player.

---

## 4. Combat economy

### 4.0 Ownership and deltas against `gta_combat.md`

`gta_combat.md` owns: the weapon roster and stats (§4.1–4.2), damage model, health, armor and regen (§6), WASTED and BUSTED presentation (§7), PvP rules (§8), police combat (§9), netcode and anti-cheat (§10) and controls (§11). Its module names stand: WeaponService, DamageService, HitboxHistory, PoliceCombatService.

This document **adds or changes:**

| # | Topic | gta_combat says | LOOP_V2 decision | Reason |
|---|---|---|---|---|
| D1 | Weapon unlocks | Cash price only | **Cash price plus a Rep gate** (§4.1) | Progression pacing; Robux can't shortcut power |
| D2 | Cash pools | One "cash" | **Wallet and bank** (§0.4) | The casino pillar |
| D3 | Hospital bill | `min(5% cash, 120 s income)`, free for rookies | `min(5% × (wallet + bank), 120 s × G)`, wallet first, free for rookies | Same size, two pools |
| D4 | BUSTED cash | `min(10% cash, 600 s income)`, surrender halves | **7% of the wallet per star** (7% at 1★ … 35% at 5★), uncapped; surrender halves it; **bank untouched** | Only the wallet is at risk now; scaling with stars matches wantedMult, so a 1★ slip isn't a 5★ fine |
| D5 | Drops on death | Downed players drop nothing | Non-wanted, non-LOADED players drop nothing. **LOADED players downed by a player drop 20% of wallet.** **Wanted players who are WASTED lose the same 7% per star as BUSTED** (any cause), plus the hospital bill, and a driven car is impounded | Dying must never be the cheap way out of a bust: surrender < BUSTED < WASTED |
| D6 | Friendly fire | On for everyone; no crews | **Off within a party** (max 4) | Parties are a V2 pillar (§5) |
| D7 | Rookie end conditions | Damage, rifle purchase, opt-out | Also mugging, carjacking or raiding, and picking up event loot | Closes the shield-farming exploit |
| D8 | Passive mode | No PvP | Also: S× fixed at ×1.5, PvE crime payouts ×0.5, no event loot, no heists | The casino can't be bypassed |
| D9 | Bounties | Zero-sum at 4★ and up | Kept, **plus** the capped 5★ Most Wanted police reward (§3.12) | The brief requires a 5★ server bounty |
| D10 | Zapper Pass | Grandfathered | **Retired.** Its id is 0, so it was never sold, and it affected PvP. | Non-pay-to-win (§8.4) |
| D11 | Explosives | None in V2 | Same. Heist and truck use hold, drill and hack tools, not charges. | Agrees |
| D12 | Rookie protection | 30 min | **10 min** (`ROOKIE_SECONDS = 600`), with a HUD pill that lets the rookie opt out. Car-keeping protection is separate and lasts about 2 h (§2.8). | The brief's number; 30 min is longer than the target session and leaves launch servers with no PvP |
| D13 | Schema migration | §13.2: `SCHEMA_VERSION 2` with a 1→2 step (`tools.bat` → `weapons.bat`, P9 welcome gift) | **No migration step.** V2 uses a fresh store `HotwireCity_v2` at `SCHEMA_VERSION = 1` (§9.3); the combat fields are part of the template. The combat workstream should not add a migration. | v1 never shipped to players |
| D14 | Combat logging | Not specified | Leaving at 1★ or more, or In Combat while LOADED, applies the WASTED wallet loss at release; never on server shutdown (§10.3) | Leaving can't beat staying |

### 4.1 Weapon ladder (prices from gta_combat §5.2; Rep gates added)

| Weapon | Price | Rep | Ammo (gta_combat) | Role in the loop |
|---|---|---|---|---|
| Fists / Slugger Bat | free | 1 | — | Defence, ejecting thieves (v1 bat logic) |
| Knuckle Dusters | $500 | 1 | — | Impulse buy |
| Kessler P9 | $1,200 (**gifted** at minute 3) | 1 | $36 / 12 | Store hold-ups |
| Pry Bar | $750 | 2 | — | Melee |
| Kessler Stun Gun (taser gadget) | $15,000 (v1) | 3 | — | Non-lethal carjack and anti-thief tool |
| Stinger Strip (spikes gadget) | $6,000 (v1) | 4 | — | Stops cars for carjacks |
| Volk Micro SMG | $6,000 | 6 | $64 / 32 | First auto |
| Brandt Hand Cannon | $9,500 | 8 | $70 / 7 | |
| Coastline Pump | $15,000 | 10 | $80 / 8 | Truck guards |
| Volk "Comrade" AR | $55,000 | **10** | $120 / 30 | The poster gun; heists |
| Brandt Tactical SMG | $24,000 | 12 | $75 / 30 | |
| Coastline Carbine | $85,000 | **14** | $120 / 30 | |
| Volk Marksman | $250,000 | 22 | $250 / 10 | Long-range hunting at 5★ |
| Light armor (+50) / Heavy armor (+100) | $750 / $1,800 | 1 / 8 | — | Lost on WASTED or BUSTED |
| Med kit (+40 HP, carry 3) | $400 | 1 | — | |
| Hacking Device | $2,500 | 6 | — | ATM hack, heist keypad |
| Duffel (2 bags) | $50,000 | 15 | — | Truck and heist bag capacity |

- Fixed prices are a deliberate soft sink (gta_combat §5.2). The real late-game sinks are cars, upgrades and Prestige.
- **Ammo sustain:** downed officers drop one magazine (gta_combat).
- **BUSTED** removes 50% of reserve ammo and sets armor to 0 (gta_combat §7.3).

### 4.2 Health and armor

As in gta_combat §6:
- 100 HP and 100 armor; armor absorbs first.
- Regen to 50 only.
- The garage heals fully when you are not In Combat.
- Hospital respawn at 100 HP and 0 armor.

### 4.3 WASTED (economy side)

| Effect | Value |
|---|---|
| Respawn | Nearest hospital after 5 s, with 6 s spawn protection (gta_combat §7.2) |
| Hospital bill | `min(5% × (wallet + bank), 120 s × G)`, wallet first. Free for rookies and when there was no damage source. |
| Wallet | `loss = wallet × max(WANTED_LOSS_PER_STAR × stars, loadedShare)`, where `loadedShare = 0.20` if LOADED and downed by a player, else 0. Applied for **any** death at 1★ or more (police, player, fall), and for a LOADED player downed by a player at 0★. Paid out of `loss`, in order: the street bounty to the killer (4★+, §3.12), then the LOADED cash bag (up to 20% of the wallet); **the rest is destroyed** (a sink). At 0★ and not LOADED the wallet is untouched. |
| Stars | Cleared |
| Owned car being driven | **Wanted (1★+):** impounded, exactly as on BUSTED (§4.4). **Not wanted:** left in place; it returns home after `OWNED_RETURN_AFTER 20` s, and **it can be carjacked during those 20 s** (the PvP path to a car). A car wrecked by the killing blow goes to `repair` (60 s). |
| Event loot | Truck and heist bags drop for 60 s |
| Theft in progress | The car drops (v1 `onThiefHit` / dropped path) |
| Street income ramp | Reset |

**Why death is never cheaper than a bust.** At the same stars the order is always surrender (3.5%/★) < BUSTED (7%/★) < WASTED (7%/★ plus the hospital bill). Drawing a gun at 2★ to get shot no longer escapes the impound or the wallet loss.

### 4.4 BUSTED (economy side)

| Effect | Value |
|---|---|
| Wallet | **−7% per star** (`WANTED_LOSS_PER_STAR × stars`: 7% at 1★, 35% at 5★); surrender halves it. Destroyed (a sink). |
| Event loot | Confiscated (destroyed) |
| Ammo and armor | −50% reserve ammo; armor 0 |
| Owned car being driven | `status = impounded`. Release for `max(250, 3% value)`, **free after 120 s**, or BREAK OUT: hold 4 s at the impound lot, +2★, then drive it home. Losing your favourite car for 2 minutes stings; losing it for 10 made players log off. |
| Loot or stolen car | Gone (theft fails back to the victim: v1 `TheftService.fail(car, "busted")`) |
| Jail | `6 s × stars`, max 30 s, in a holding cell at Police HQ [world]. A party member can BREAK OUT (hold 5 s at the cell door, +2★ for them). Then release at HQ with an 8 s heat grace (v1). |
| Stats | `busted += 1` |

### 4.5 Safe zones, passive and rookie (economy side)

The safe-zone list is gta_combat §8: garages, gun stores, dealership, spray shops, hospital plaza and HQ release. This document adds the Mod Shop interior and the ATM radius (2 studs, deposit only, no protection).

**Passive limits** (D8):
- Can do: drive, race (no pink slips), shop, trade, phone jobs, store robberies at ×0.5.
- Cannot do: carry event loot, start or join heists, carjack, mug, raid.
- Street multiplier fixed at ×1.5.

### 4.6 PvP conduct

Menace, spawn protection, revenge immunity, "In Combat" and vigilante rules are as in gta_combat §8. Economy hooks:
- A Menace player gets the street bounty from 3★ (not 4★).
- A Menace player's crime payouts are ×0.5 while the Menace status lasts.
- Menace persists in `combat.menace` with decay (§9.1), so rejoining doesn't clear it.

---

## 5. Social

### 5.1 Party (session, up to 4)

- **Invite.** Through Phone › Contacts, or the player list in Pause › STATS. The target sees an `Invite` card with 30 s to accept. The party panel and the heist lobby also have **Invite friend**, which opens `SocialService:PromptGameInvite` so a friend outside the server can join (the referral reward, §7.2 S13, still applies once per account).
- **Benefits:**
  - friendly fire off;
  - teammate blips and name colour;
  - **shared waypoint** (anyone's map ping syncs to all members);
  - +10% per nearby member on PvE crime and event payouts (max +30%, §3.1);
  - heist crew = party;
  - party members may deliver bags to each other's garages;
  - repo rights on each other's stolen cars while the owner is online.
- **Voice.** Roblox spatial voice where the platform enables it (age-checked 13+). If `VoiceChatService` exposes the new Audio API in this place, add a **party radio**: AudioDeviceInput access lists limited to party members (V2.1, needs verification). There is no custom voice transport.
- **Chatless communication** (most players can't type; brief §2.2):
  - quick-chat wheel: Need backup / Cops! / Follow me / Truck incoming / Nice car! / Thanks / Go go go / Wait;
  - emote wheel;
  - map pings;
  - horn.

### 5.2 Crews (persistent)

| Item | Rule |
|---|---|
| Create | Rep 5, $25,000 (a sink). Name (filtered, 3–20 chars), tag (2–4 chars), emblem from 24 presets (no user images), crew colour from the realistic palette |
| Size | 20 members. Ranks Leader / Officer / Member |
| Storage | DataStore `HC_Crews_v1/<crewId>` (roster, tag, emblem, weekly crew RP). `PlayerData.crew = { id, rank, joinedAt }` is a cache: **the roster wins** on any disagreement, checked on join. Name and tag uniqueness use claim keys `HC_CrewNames_v1/n_<lower(name)>` and `t_<lower(tag)>` written with `UpdateAsync` (fail if taken) before the crew is created. Ships behind `Flags.CREWS_PERSISTENT_ENABLED`; parties work without it. |
| Benefits | Tag above your head and on the leaderboard, crew colour on map blips, **Crew weekly contract** (§6.6), Top Crew board (weekly RP) |
| Party relation | Crew members in the same server get a one-tap "Party up" |
| Turf | V2.x (brief "later") |

### 5.3 Crew garage (answer: no shared ownership in V2.0)

- **V2.1 "Car Keys":** an owner lends one parked car to a party member for the session.
  - The borrower can drive it and earns street income into their own wallet, at the **owner's** S× cap (a protected owner lends a ×5 car).
  - The car earns **no garage income while lent**, so one car can't pay garage and street at once.
  - Theft rules apply to the **owner's** protections.
  - The owner can revoke at any time: the car returns home after the borrower exits.
- **No shared title, no co-ownership:** those breed scam and dupe bugs.

### 5.4 Races and pink slips

- **Race meets** [world]: 3 start markers, one each Downtown, Beachfront and on the Highway loop.
- **Formats:** sprint (60–120 s), drag (half mile, 10–20 s), circuit (2–3 laps). 2–4 racers.
- **Owned cars only.** Bound cars can race (but not stake). Nitro uses the car's own tank. Every server-side checkpoint must be hit; a segment faster than `VehicleService.minTravelTime` or a tainted car is disqualified.
- **House prize.** Winner gets `500 + 20 s × G_winner` (wallet) + 150 RP + 300 car XP; others get 50 RP.
  - Paid only with 2 or more racers at Rep 5+. 10 full-pay wins per day, then ×0.25 (Law 10). The pair cap stays hard: 3 paid races per pair per day (it is the alt-farming guard).
  - Ships behind `Flags.RACES_ENABLED`.
  - No cash entry fees or wagers (§0.3).
- **Time trials** (solo): beating par pays `250 + 30 s × G` once per day per route; Fastest Racer board per route.
- **Pink slips** (flag `RACE_PINK_SLIPS_ENABLED`):

  | Rule | Value |
  |---|---|
  | Both racers | Rep 15 or more, **and every trading eligibility check** (§5.5: account age, playtime, `IsPaidItemTradingAllowed`, not in combat, not wanted). Pink slips are a trade with a race in front, so they can't bypass trade policy. |
  | Both cars | Non-bound, not trade-locked, not frozen, no `inbound`, not reward-origin within its 14-day lock |
  | Fair match | Values within ±30% and rarity order differs by at most 1 |
  | Consent | Two confirmations: a summary card with both cars' value, level, finish and serial, then a 5 s "THIS CAR WILL BE LOST" hold |
  | Daily cap | 2 pink-slip losses per day; a loss counts toward the loser's `TRADE_NET_OUT_PER_DAY` (§5.5) |
  | Pair cooldown | The same two players can stake against each other once per 7 days (`PINK_SLIP_PAIR_COOLDOWN = 604800`) |
  | Transfer | No lay-low window and no insurance (it was consensual). The won car is trade-locked for 72 h and records `lastTransfer` (the counterparty rule, §2.8). |
  | Policy | Skill-only outcome, no chance element. Legal and policy review before enabling. |

### 5.5 Trading (secure two-step)

| Step | Rule |
|---|---|
| Eligibility | Both players: Rep 10 or more, 2 h or more of playtime, `player.AccountAge ≥ 14` days, in the same server, `PolicyService:GetPolicyInfoForPlayerAsync().IsPaidItemTradingAllowed == true` (if false, trading is disabled for that player), not in combat, not wanted |
| Items | **Cars only**, up to 4 per side. No cash, no bound cars, nothing trade-locked (kept by theft: 7 days; traded or won: 72 h; reward-origin cars: 14 days), no frozen cars, no cars with `inbound` set, no impounded or lay-low cars |
| Window | Request → accept → both add cars. The server keeps the authoritative offer; `TradeState` mirrors it. |
| Anti-scam | Any change to either side **resets both Ready flags** and restarts the countdown. Each side's total value (§2.6) is shown. If one side gives more than 2× the other's value, a red "Uneven trade" warning appears and that side needs an extra 2 s hold. |
| Net-out cap | Per UTC day, the **net value a player gives away** (value given minus value received, summed over trades and pink-slip losses) may not exceed `TRADE_NET_OUT_PER_DAY = max(100,000, 1,800 s × giverG)`. A trade that would exceed it is refused with the remaining allowance shown. This bounds alt funnels and scams without blocking fair swaps. |
| Confirm | Both READY → a 10 s countdown showing the full item list → both CONFIRM. The server re-validates ownership, state and eligibility, **and that the offer is unchanged since the last Ready**, then swaps (§10.3). |
| After | The received cars are trade-locked for 72 h and record `lastTransfer` (so the giver can't raid them back for 72 h, §2.8). The serial registry is updated. The `HC_TradeLog_v1` entry is written. Cooldown 60 s between trades. Ships behind `Flags.TRADING_ENABLED`. |

### 5.6 Leaderboards (OrderedDataStores, v1 LeaderboardService pattern, log-encoded where needed)

| Board | Value | Store | Period |
|---|---|---|---|
| Richest | Net worth = bank + Σ car values | `LB_netWorth_v1` | All-time and weekly |
| Most Wanted | Longest continuous seconds at 5★ | `LB_mostWanted_v1` | Weekly and all-time |
| Top Thief | Player cars stolen and kept (a car kept from the Server Crown holder counts 2) | `LB_thefts_v1` | Weekly |
| Best Garage | Garage likes received | `LB_likes_v1` | Weekly |
| Fastest Racer | Best time per route | `LB_race_<route>_v1` | All-time |
| Top Crew | Crew RP this week | `LB_crewRep_v1` | Weekly |
| (v1) totalEarned, steals | — | existing | All-time |

Weekly boards use keys with an ISO-week suffix. Writes follow the v1 budget rules: on leave, plus every 5 min when changed.

### 5.7 Garage visits, likes, emotes and photo mode

- **Garage likes.** Garages are physical, so visitors walk in. A LIKE prompt on the owner sign gives 1 like per visitor per garage per UTC day (`likes.given`). The owner's like count shows on the sign. Feeds Best Garage.
- **Emotes.** An emote wheel with free emotes plus the Street Emotes pack (§8).

### 5.8 The Server Crown ("rob the richest", brief §3.11)

- **Who.** With 3 or more players in the server, the player with the highest **net worth** (bank + wallet + Σ car values) holds the `ServerCrown` attribute. Recomputed every 30 s and on join and leave; it changes hands only when the challenger leads by 5%, so it doesn't flicker.
- **Shown** as a crown on the nameplate, the garage sign and the map blip (`MapBlips` kind `crown`), with a feed card when it changes hands: "<Name> is the richest player in the city."
- **Effect.** Status only. A car kept from the crowned player counts double on Top Thief, and the feed names it ("stole from the Crown"). **It mints nothing** and changes no protection: starter, Shaken, the daily cap and the rest all apply as normal.
- **Photo mode.**
  - Phone › Camera freezes your character, hides the HUD, frees the camera within 30 studs, and offers 6 grounded filters.
  - Hooks: `CaptureService:CaptureScreenshot` then `PromptShareCapture`.
  - Garage photo preset: frames your 3 best cars.
  - Flexing in phone Messages: "Send to crew" posts a feed card to the crew.

---

## 6. Progression

### 6.1 Rep (account level 1–100)

- **Curve:** `repToNext(L) = floor(40 × L^1.45)`. Cumulative: Rep 2 = 40 RP; Rep 5 = 644; Rep 10 = 4,050 (~1 h); Rep 20 ≈ 23.6K (~6 h); Rep 30 ≈ 65K (~16–18 h at about 60 RP/min, faster with heists); Rep 50 ≈ 232K; Rep 100 ≈ 1.28M.
- **RP sources:** the RP column of §3.2, plus:
  - 1 RP per 100 studs cruised;
  - car level-up +20;
  - repo +150 (only on the 3 paid repos per day);
  - revenge down +50 (only on the 3 paid revenges per day);
  - Most Wanted claim +300;
  - 5★ survival +100 per minute;
  - races (§5.4);
  - daily contract +100, weekly +1,000.

| Rep | Unlocks |
|---|---|
| 1 | Garage (4 slots), bat, P9 (gift), light armor, med kits, convenience stores, NPC mugging, phone jobs, Industrial district comfort; dealership Common to Rare |
| 2 | Mod Shop: stage 1 of every track, paint; pry bar |
| 3 | Taser, armored truck bags, Tracker and Insurance tracks, **joining a bank heist crew** |
| 4 | Stinger strip |
| 5 | **Vault bay 1**, crew creation, player mugging and carjacking (after rookie protection), Suburbs comfort |
| 6 | Micro SMG, gas stations, ATM hack (Hacking Device) |
| 8 | Hand cannon, heavy armor, jewelry store; starter protection can end (with 2 h of active play, §2.8) |
| 10 | **Comrade AR**, Pump, **leading a bank heist**, **trading** (with its other gates), pawn shop, **Prestige I**, **underglow and custom plates** (or the passes earlier), **Epic cars at the dealership**, Downtown comfort |
| 12 | Tactical SMG |
| 14 | Carbine |
| 15 | **Pink slips**, Duffel; the low-Rep daily loss cap (1) rises to 3 |
| 18 | **Legendary cars at the dealership**, Beachfront comfort |
| 22 | Marksman |
| 25 | **Vault bay 2**, **Mythic cars at the dealership**, Hills comfort |
| 32 | Port/Airport comfort |
| 40 | **Secret cars at the dealership** |
| 40, 50, 60…100 | Cosmetic crests, plate frames, emotes |

**Dealership Rep gates** (`DEALER_REP = { Epic = 10, Legendary = 18, Mythic = 25, Secret = 40 }`) apply to **buying** only. Stealing from the street, the dealership floor or a Hot Drop stays open at any Rep, so an early Legendary is always earned on the street. Cumulative RP: Rep 10 ≈ 4K (about 1 h), Rep 18 ≈ 18K (about 5 h), Rep 25 ≈ 41K (about 11.5 h), Rep 40 ≈ 133K (about 37 h), which lands the first bought Epic, Legendary, Mythic and Secret on the §7.1 milestones.

### 6.2 Districts (soft gates)

Anyone can go anywhere. Richer districts spawn better cars, pay more and police harder.
- **Comfort Rep** is advice only: entering a district under it shows a top-left help line, "High police presence: recommended Rep 25."
- **Geometry** comes from [world]. `DistrictService` reads polygons from `Config/Districts` (filled in by the world team).
- **Street luck:**
  - `Rolls.rarity` currently clamps luck to ≥ 1. Change it to accept a separate `districtLuck` that may be below 1 (Industrial 0.6).
  - Secret street weight is 0 except at Port/Airport (`0.02`).

| District id | Theme (lead direction) | Comfort Rep | Street luck (rarity order ≥ 3) | Payout mult | Police unit factor | Response delay (s) |
|---|---|---|---|---|---|---|
| `industrial` | Junkyard, docks edge | 1 | 0.6 | 1.00 | 0.75 | 8 |
| `suburbs` | Driveways, houses | 5 | 1.0 | 1.10 | 1.00 | 6 |
| `downtown` | Towers, banks, stores | 10 | 1.5 | 1.25 | 1.25 | 5 |
| `beach` | Boardwalk, pier, showrooms | 18 | 2.0 | 1.40 | 1.25 | 5 |
| `hills` | Mansions, the sign | 25 | 3.0 | 1.60 | 1.50 | 4 |
| `port_airport` | Cranes, containers, runway | 32 | 4.5 (+Secret 0.02) | 1.80 | 1.75 | 3 |
| `highway` | Countryside or desert loop | 1 | 1.0 | 1.00 | 0.75 | 8 |

**Provisional mapping to the world plan** (`docs/v2/world/plan_gameplay.png`; the world team owns the final polygons): Rust Flats and The Foundry → `industrial`; Southgate → `suburbs`; Midtown and Pinnacle Heights → `downtown`; Palmera Beach → `beach`; Sunwood Hills → `hills`; Iron Bay and Hotwire International → `port_airport`; Cactus Junction, Red Mesa and the coast highway → `highway`.

### 6.3 Prestige (v1 Rebirth, renamed)

| Item | Rule |
|---|---|
| Cost | `max(750,000 × 2.75^n, PRESTIGE_COST_SECONDS × G)` with `PRESTIGE_COST_SECONDS = 10,800` (3 h of garage income). The fixed ladder (v1 `REBIRTH_BASE_COST`, `REBIRTH_COST_GROWTH`: 750K, 2.06M, 5.67M, 15.6M, 42.9M, 118M, 324M…) is the floor; the G term makes the cash a real sink at every stage instead of minutes of play. |
| Requirement | Rep ≥ 10 + 5n (10, 15, 20…). Every car parked (none out, impounded or in a lay-low window). No car missing. Not in combat. |
| Perks | +50% income per prestige (v1 `REBIRTH_INCOME_BONUS`, applies to G, so crime payouts scale too). +10 s laser lock (v1). Prestige crest I–X on the name plate. Prestige plate frame. One exclusive cosmetic paint per prestige tier. |
| Keeps | Rep and RP, weapons, armor and items, security upgrades, Hotwire Kit, cosmetics, discovered and finish Index, stats, crew, season, **bound cars**, and **3 other cars in total** (`PRESTIGE_KEEP_CARS = 3`) with all their levels and upgrades. Vault cars count toward the 3. The player picks on the confirm screen; the default is the 3 most valuable. |
| Resets | Wallet and bank to `STARTING_CASH` 150 (paid out to the bank first, v1 behaviour); `slotsUnlocked` to 4; every other car is **scrapped** (the confirm screen lists them by name) |
| Effect on G | Keeping 3 cars is roughly 55–70% of a typical 8–10-car garage's income. After Prestige I (×1.5 multiplier) G lands at about ×0.85–1.05 of before; after II (×1.33) and III (×1.25) it dips to about ×0.75–0.9, and recovers above the old level within about one session as slots refill. The prestige is a step back for a permanent step up, not an instant boost. |
| UI | Pause › STATS › Reputation / Prestige (UI §5.15) |

### 6.4 Collection Index and sets (v1 Index, extended)

- **Index.** Every car appears as a silhouette until discovered (v1). Completing a rarity gives +5% garage income (`Economy.INDEX_RARITY_BONUS`).
- **Finish Index.** `finishIndex[carId][finish] = true` once a car is owned in that finish.
- **Set bonuses** (+2% garage income each, additive, max +20%):
  - every Muscle;
  - every Super;
  - any 5 Gold;
  - any 3 Chrome;
  - any Chameleon;
  - any Galaxy;
  - "Full Fleet": one of every class.
- Limited cars leave permanent gaps when missed. Collector FOMO, honestly dated.

### 6.5 Season ("Street Pass")

| Item | Rule |
|---|---|
| Length | 8 weeks, with honest end dates shown from day 1. Rewards stay claimable for 14 days after the season ends. |
| Tiers | 50 tiers × 2,000 SXP |
| SXP sources | Daily contract 500 each (1,500/day); weekly 2,500 each (7,500/week); 100 per 10 min played (cap 600/day); truck bag 150; heist 500; race 100. A regular player (5 days a week) reaches about 10 tiers a week, so the pass completes in about 5 weeks. |
| Free track | Cash (income-seconds), paints, plate frames, emotes. **Tier 25: a Rare car** (normal, stealable). **Tier 50: a limited serial Rare-band car.** |
| Premium (499 R$) | Cosmetics only: wraps, rims, outfits, emotes, weapon tints, horn, and a **bound Epic-band car** at tier 50. No cash multipliers, no XP boosts, **no paid tier skips**. |
| Data | `season = { id, xp, premium, claimed }` |

### 6.6 Contracts

| Type | Count | Reset | Rewards |
|---|---|---|---|
| Daily (v1) | 3, from the pool, plus 1 free reroll (v1 `RerollContract`) | 00:00 UTC | v1 `reward` seconds of income (min $500) **to the bank** + 100 RP + 500 SXP |
| Weekly (new) | 3 | Monday 00:00 UTC | 3,600 s × G + 1,000 RP + 2,500 SXP |
| Crew weekly (new) | 1 shared, progress summed across members | Monday | 1,800 s × G each + crew RP |

New contract stats (`RewardsService.progress(player, stat, n)` stays the single entry point, DECISIONS):

| Stat | Example contract |
|---|---|
| `robStore` | Hold up 3 stores |
| `atmHack` | Hack 2 ATMs |
| `truckBag` | Deliver a truck bag |
| `heist` | Finish a bank heist |
| `streetMult` | Hit STREET ×8 |
| `cruiseMiles` | Cruise 10 miles in one car |
| `carLevel` | Level a car up 3 times |
| `mugPlayer` | Mug a player |
| `repo` | Repo a stolen car |
| `raceWin` | Win a street race |
| `jewelry` | Smash 6 jewelry cases |
| `fiveStar` | Survive 60 s at 5★ |
| `escapeHeli` | Evade with the heli overhead |
| `chopOrder` | Fill 2 chop orders |
| `bountyClaim` | Down a Most Wanted target |

The daily streak (v1) **pauses instead of resetting** (brief §2.6 retention widget). `RewardsService._dailyClaim`: a missed day keeps the streak index.

### 6.7 Live events calendar

| Cadence | When (UTC) | Event | Effect | Implementation |
|---|---|---|---|---|
| Server clock | §1.7 | Pulse, Big Pulse, Hot Drop, Jewelry | §3 | EventClock |
| Random (v1) | `Events.*` intervals | Cash Rain, Rush Hour, 2× Cash (5 min) | v1 | EventService |
| Weather | Every 20–40 min, 5 min long | Rain (grip −10%, street luck ×1.25), **Thunderstorm** (Storm finish rolls) | §2.5 | LiveOpsService + LightingService |
| Daily | 00:00 | Contracts, daily objective, ledger counters | §6.6 | RewardsService |
| Weekly | Mon 00:00 | Weekly contracts and boards reset | | |
| Weekend | Fri 18:00 – Mon 06:00 | Rotating modifier: **Double Crime Cash** (liveOpsMult 2), **Double Rep**, **Double Car XP**, **Rare Weekend** (street luck ×2, displayed odds update) | Announced on Thursday | LiveOpsService schedule |
| Saturday | 17:00–18:00 | **Admin Abuse hour**, run live by the owner or automatically. Rotation: Hypercar Rain (10 Legendary+ cargo drops over 10 min), Police Strike (no police for 10 min), Golden Truck (bag `eventMult` ×5, after the clamp), City Under Siege (everyone 3★, wantedMult +1 tier), Finish Fever (non-Stock finish weights ×10, odds shown), Glitch Drop (Glitch finish Hot Drops), Bounty Night (Most Wanted `eventMult` ×3, after the clamp) | MessagingService topic `HC_LiveOps` to all servers | LiveOpsService + AdminService |
| Saturday | 18:00 | Update drop: 3–5 cars + one finish, trait, weapon or activity | | |
| Monthly | First Saturday | Limited serial car event (#/500) | §2.9 | SerialService |
| Season | 8 weeks | Street Pass + city reskin | §6.5 | SeasonService |
| Launch | Nov 19, 2026 (GTA VI week) | "Free GTA your friends can play" week: Double Rep + a daily Hypercar Rain. Ships the launch core (brief §3.13); heist, trading, races, serials, persistent crews and the season can be switched on later through `Config/Flags` without a rebuild (§9.4). | | LiveOpsService |
| Holidays | Halloween, Thanksgiving–New Year | Reskins (night city, snow drifting), themed limited cars | | |

**Live config.** `HC_LiveConfig_v1/current` is a server-only JSON of multipliers and schedule overrides, read every 5 min and **clamped** to safe ranges (multipliers 1–5, durations ≤ 3 h). It lets an event run without a publish.

---

## 7. Economy model

### 7.1 Stage targets (G includes the prestige multiplier)

Active = actually playing: driving, crimes, events. The pillar target is active ≈ 3–5× passive.

| Stage | Playtime | Rep | Typical garage | G ($/s) | Passive $/h (G × 3,600) | **Active $/h target** | Mix: garage / street / crime / events | Main sinks at this stage |
|---|---|---|---|---|---|---|---|---|
| A Onboarding | 0–10 min | 1–4 | 2–4 Common | 5–25 | 18K–90K | **60K–300K** | 30 / 10 / 50 / 10 | Slot 5 ($1.5K), stage-1 upgrades ($100–300), ammo |
| B Early | 10–60 min | 5–10 | 4–6 Uncommon/Rare | 40–250 | 0.15–0.9M | **0.5–3.5M** | 30 / 15 / 40 / 15 | Slots 6–7 ($8K, $40K), Rares ($7–11K), Micro SMG, taser |
| C Day 1 | 1–3 h | 10–18 | 6–8 Rare/Epic, LV 5–15 | 300–1.5K | 1.1–5.4M | **4–20M** | 30 / 20 / 30 / 20 | Epics ($40–65K, dealer Rep 10), slot 8 ($200K), Epic upgrades (~$1M to max), Comrade, **Prestige I (`max($750K, 3 h × G)` ≈ $3–16M)** |
| D Days 2–3 | 3–8 h | 18–25 | 8 Epic/Legendary, LV 10–20 | 2K–8K | 7–29M | **25–100M** | 30 / 20 / 30 / 20 | Legendaries ($250–400K, dealer Rep 18), slot 9 ($1M), Legendary upgrades (~$6M to max), Prestige II–III (≈ 3 h × G: $22–86M) |
| E Day 7 | 8–16 h | 25–32 | 9–10 Legendary/Mythic; favourite at LV 15–25 | 10K–40K | 36–144M | **120–500M** | 30 / 25 / 25 / 20 | Mythics ($1.5–2.5M, dealer Rep 25), slot 10 ($5M), Mythic upgrades ($31–52M to max), Prestige IV (≈ $108–432M) |
| F Day 30 | 40 h+ | 45+ | Mythic/Secret, LV 25–45 | ≥150K | ≥0.5B | **≥2B** | 30 / 25 / 25 / 20 | Secret cars ($10–30M, dealer Rep 40) and upgrades ($206–618M each to max), Prestige V+ (≥ $1.6B) |

**Time-to targets** (playtests must hit these within ±50%):

| Milestone | Target |
|---|---|
| First Rare | about 12 min (a Rare playtime gift at 40 min is the floor) |
| First Epic | 60–90 min (dealer gate Rep 10; street or daily-streak day 7 earlier for the lucky) |
| First Legendary | day 2–3 (dealer gate Rep 18 ≈ 5 h), or a Hot Drop or street luck |
| First Mythic | day 5–7 (dealer gate Rep 25 ≈ 11.5 h) |
| First Secret | day 20 or later (dealer gate Rep 40 ≈ 37 h; Port/Airport street weight 0.02) |
| Prestige I | about 2–3 h |
| First car at LV 10 | about 60 min of driving it |
| Starter protection ends | about 2 h (Rep 8 and 7,200 active seconds) |

### 7.2 Sources, transfers and sinks (the spreadsheet)

Stage C reference: G = $800/s, Downtown (×1.25). "Per active hour" is a typical stage C player.

| # | Flow | Type | Formula | Lands in | Stage C example | Per active hour (C) | Owner |
|---|---|---|---|---|---|---|---|
| S1 | Garage income | Source | Σ carIncome × garageMult per second | Uncollected → bank | $800/s base | $2.9M | GarageService |
| S2 | Offline | Source | `min(away, 6 h) × base × 0.30` (VIP 0.60) | Bank | ≤ $5.2M per return | — | RewardsService |
| S3 | Street income | Source | carIncome × (1+0.5R) × S× (3–10; ≤5 protected; 1 after 3 h/day) | Wallet | LV 10 Epic: $330 × 5.5 = $1.8K/s | $1.5–2.5M (about 20 min of driving) | StreetIncomeService |
| S4 | Store hold-ups | Source | §3.2 | Wallet | $181K | $0.9–1.8M | RobberyService |
| S5 | ATM hack | Source | §3.2 | Wallet | $135K | $0.3–0.5M | RobberyService |
| S6 | NPC mugging | Source | §3.2, diminishing returns | Wallet | $9.6K | ~$0.1M | RobberyService |
| S7 | Jewelry store | Source | §3.8 | Wallet | $496K for all 8 cases | $0.2–0.5M | RobberyService |
| S8 | Chop (loot + orders) | Source | `chopValue × orderMult × wantedMult` | Wallet | Epic ×2 order: $35K | $0.1–0.2M | ChopShopService |
| S9 | Evade bonus | Source | `stars × (100 + 15 s × G)` | Wallet | 3★: $36.3K | $0.1–0.2M | WantedService |
| S10 | Truck bag | Source | §3.6 | Wallet | $98K × 2.0 = $196K | $0.4–1.2M | ArmoredTruckService |
| S11 | Bank heist share | Source | §3.7 | Wallet | $2.06M | $2–4M (if both windows are run) | HeistService |
| S12 | Phone jobs | Source | §3.10 | Wallet | $48–96K | $0.3–0.6M | JobsService |
| S13 | Contracts, daily, playtime, codes, referral | Source | Income-seconds with floors (`Economy.DAILY_REWARDS`, `Contracts`). **Playtime (V2):** 3 min 2 incomeMinutes (min $300) · 8 min 5 · 15 min Uncommon car · 25 min 10 · 40 min Rare car · 60 min 20 incomeMinutes; **active seconds only**. Reward-origin cars: trade-locked 14 days, never insured. Referral inviter cap 1 per day. | Bank | 300–1,800 s × G | ≈$1M/day | RewardsService |
| S14 | Race house prize | Source (soft cap) | `500 + 20 s × G` | Wallet | $16.5K | small | RaceService |
| S15 | Insurance | Source (capped, clawback) | 25–45% × value | Bank | Epic LV 10 (value $60K): $15–27K | rare | TheftService |
| S16 | Repo, recovery, revenge, interceptor | Source (capped) | 30 / 30 / 30 / 30 s × G (+$500 revenge or interceptor); repo and revenge 3 per day each | Wallet | $24–25K | rare | TheftService |
| S17 | Most Wanted police reward | Source (capped) | §3.12, clamped by the claimer's own G | Wallet | $50–150K | rare | DamageService |
| S18 | 5★ survival | Source (2 per day) | §3.12 | Wallet | $49K per minute at 5★ | rare | WantedService |
| S19 | Cash Rain, events | Source | v1 `CASH_RAIN_BAG_SECONDS` 20 s × G per bag | Wallet | $16K per bag | event | EventService |
| S20 | Robux cash | Source (paid) | 10 min, 1 h or 4 h of G (with floors); Double It `min(share, 300 s × G)` once a day | Bank | — | — | MonetizationService |
| S21 | Trunk loot | Source | 60% × (`50 + 10 s × G`), plus items (§2.5.1) | Wallet | $8K | $0.1–0.2M | GarageService (delivery) |
| A1 | Street steals, Hot Drops, dealer stock | Asset source | Cars | Garage | — | — | Street/Event/Dealer |
| T1 | Player mugging | Transfer | 25% of the victim's wallet | Wallet → wallet | — | — | RobberyService |
| T2 | LOADED drop | Transfer (sink if unclaimed) | 20% of the victim's wallet (out of the wanted loss if wanted) | Bag → wallet | — | — | DamageService |
| T3 | Carjack spill | Transfer (sink if unclaimed) | 10% of a **LOADED** victim's wallet | Pickups | — | — | TheftService |
| T4 | Street bounty | Transfer | `min(10% of wallet, stars × 20 s × G)` | Wallet → wallet | — | — | DamageService |
| T5 | Car theft | Asset transfer | Car record | Victim → thief | — | — | TheftService |
| T6 | Pink slip, trade | Asset transfer | Car record | — | — | — | Race/TradeService |
| K1 | Dealer cars | Sink | `Cars.price × finish.mult` (v1) | — | Epic $40–65K | $0.1–0.5M | DealershipService |
| K2 | Garage slots | Sink | `Economy.SLOT_PRICES` $1.5K→$5M | — | Slot 8 $200K | one-off | GarageService |
| K3 | Car upgrades | Sink | §2.4, ≈ 20.6 × price to max | — | Epic stages $7.5K–80K | **$0.5–2M** | ModShopService |
| K4 | Garage security | Sink | §2.7.3 | — | Lock 3: $350K | one-off | ModShopService |
| K5 | Paint, plates, rims | Sink | `$250 + 2% × price` | — | $1.3K | small | ModShopService |
| K6 | Weapons, ammo, armor, kits, tools | Sink | §4.1 | — | Comrade $55K | $20–80K | ShopService (gta_combat) |
| K7 | Hospital | Sink | `min(5% × (wallet + bank), 120 s × G)` | — | ≤ $96K | $50–150K | DamageService |
| K8 | BUSTED, WASTED while wanted, combat-log | Sink | 7% of wallet per star (halved on surrender; bounty and LOADED bag paid out of it on death) | — | 2★ bust on $200K: $28K | $0.1–0.4M | WantedService / DamageService |
| K9 | Impound and repair | Sink | `max(250, 3% value)` to skip 120 s / `max(100, 1% value)` to skip 60 s | — | $1.8K / $600 | small | JailService |
| K10 | Spray, Lawyer | Sink | Spray: `stars × max(250, 15 s × G)` (v1). Lawyer (phone, clears ≤2★ when unseen): `stars × max(500, 30 s × G)`, 10 min cooldown | — | 3★ spray: $36K | $50–100K | WantedService |
| K11 | ATM fee | Sink | 5% of the deposit | — | — | $20–60K | BankingService |
| K12 | Mechanic | Sink | `max(250, 5 s × G)` | — | $4K | small | GarageService |
| K13 | Heist kit | Sink | `10,000 + 30 s × leaderG` | — | $34K | per heist | HeistService |
| K14 | Crew creation | Sink | $25,000 | — | — | one-off | CrewService |
| K15 | Unclaimed drops | Sink | Cash bags vanish after 30 s, event bags after 60 s | — | — | — | — |
| K16 | Prestige | Sink (reset) | Wipes wallet and bank; cost `max(750K × 2.75^n, 10,800 s × G)` (§6.3) | — | $8.6M at G 800 | — | RebirthService |
| K17 | Leave fee | Sink | 10% of the wallet when leaving while LOADED at 0★ outside your garage | — | — | small | BankingService |
| K18 | Insurance clawback | Sink (reverses S15) | The paid amount, if the uid returns within 7 days | — | — | rare | CarService |
| K19 | Heist overflow | Sink | Share above a member's clamp is destroyed | — | — | rare | HeistService |

### 7.3 Price sheet (one place to look)

| Category | Prices |
|---|---|
| Garage slots 5–10 | $1,500 · $8,000 · $40,000 · $200,000 · $1,000,000 · $5,000,000 (v1) |
| Laser Lock 1–4 | $2,500 · $30,000 · $350,000 · $2,500,000 |
| Alarm 1–2 / Reinforced Door 1–2 | $20,000 · $400,000 / $50,000 · $1,000,000 |
| Hotwire Kit 1–4 | $1,200 · $12,000 · $120,000 · $1,200,000 (v1) |
| Car upgrade stage | `max(100 × stage, Cars.price × factor)` (§2.4) |
| Paint change | $250 + 2% of the car's price (first one free) |
| Weapons, ammo, armor | §4.1 (gta_combat §5.2) |
| Hacking Device / Duffel | $2,500 / $50,000 |
| Fees | Hospital `min(5%, 120 s × G)` · impound `max(250, 3% value)` (or free after 120 s) · repair `max(100, 1% value)` (or free after 60 s) · mechanic `max(250, 5 s × G)` · ATM 5% · spray (v1) · Lawyer `stars × max(500, 30 s × G)` · LOADED leave fee 10% |
| Heist kit / crew | `10,000 + 30 s × G` (refunded on a fail after the drill) / $25,000 |
| Prestige | `max(750,000 × 2.75^n, 10,800 s × G)` |

### 7.4 First 30 minutes, simulated (checks that the numbers hang together)

| Time | Action | Wallet | Bank | G |
|---|---|---|---|---|
| 0:00 | Spawn | 0 | 150 | 3 |
| 1:00 | Deliver a Common ($5/s). Evade 1★: `100 + 15 × 3` | 145 | 150 | 8 |
| 1:10 | Collect | 145 | ~330 | 8 |
| 1:20–3:00 | Cruise the Rustbucket at ×3–×3.5 | ~1,150 | 330 | 8 |
| 3:30 | Store hold-up: `(500 + 120 × 8) × 1.0 (industrial) × 1.5` | ~3,340 | 330 | 8 |
| 4:45 | Evade 2★ (+$440), deposit at the garage, collect | 0 | ~4,800 | 8 |
| 5–8 | Engine 1 ($100), slot 5 ($1,500), steal 3 more cars | 0 | ~4,000 | ~35 |
| ~10 | Truck bag: `min(2,000 + 120 × 400, 5,000 + 300 × 35 = 15,500) × 2.0` | 31,000 | 4,000 | 35 |
| 10–20 | 2 hold-ups (~$8K each), 2 evades, 3 min cruising a Bull Charger | ~60,000 | ~20,000 | ~60 |
| 20 | Deposit. Buy slot 6 ($8K), slot 7 ($40K), a Rare ($9K), Micro SMG ($6K) | 0 | ~17,000 | ~130 |
| 30 | — | — | — | **~130 (Stage B ✓)** |

Without the truck bag, G at 30 min is about 80–100. Still Stage B.

### 7.5 Inflation controls and telemetry

1. **Income-second scaling with floors and clamps.** Every source is `base + s × G`. Event payouts are clamped to the earner's own scale (truck, heist), so one rich server can't hand a newcomer millions.
2. **Exponential sink ladders tied to car price.** Upgrades (~20.6 × price to max), slots, security, and Prestige (×2.75 each), which wipes cash.
3. **Risk sinks.** BUSTED 35% of the wallet, unclaimed drops, ATM fees. Players who never bank lose money to the system.
4. **Transfers mint nothing.** Mugging, LOADED drops, street bounties, thefts, pink slips and trades. The only minted PvP-adjacent sources (insurance, player-car chop, Most Wanted reward, interceptor, revenge, repo) all have per-day and per-pair caps.
5. **No cash trading, no cash wagers.** No real-money cash market to inflate.
6. **Fixed-price soft sinks** (ammo, weapons) are accepted to be trivial late on (gta_combat §5.2).
7. **Telemetry (EconomyTelemetry).**
   - Every source and sink calls `AnalyticsService:LogEconomyEvent(player, flowType, "Cash", amount, endingBalance, transactionType, itemSku)`. `transactionType` uses `Enum.AnalyticsEconomyTransactionType` (Gameplay, Shop, IAP, TimedReward, Onboarding, ContextualPurchase) and the SKU is the §7.2 row id (S4, K3…).
   - Custom funnels: first steal, first deposit, first truck bag, Rep 5/10, first theft loss → still playing 10 min later (quit-after-loss rate).
8. **Anomaly flag.**
   - A player whose minted $/h exceeds 20 × G × 3,600 over a rolling 30 min, or whose wallet grows faster than any legal source allows, is logged to AdminService with a source breakdown. Never auto-kicked.
   - Admins review in `/hc audit <player>`.
9. **Weekly balance review:** the share of sources by stage, against §7.1's mix column. Tune through `HC_LiveConfig` multipliers and Config.

---

## 8. Monetization (honest, non-pay-to-win, Roblox-policy compliant)

### 8.1 Principles

- **Robux never buys:**
  - damage, armor above 100, weapons, or ammo advantages (gta_combat §5.3);
  - car performance beyond what cash and levels can reach;
  - immunity from other players while you earn the street multiplier;
  - pass-only access to any district or activity.
- **Sell at the moment of desire or loss, honestly.** Offers appear in the phone (Internet app) and as one quiet line in context. They never interrupt a chase or a menu with a modal.
- **No fake timers, no permanent "sales", no false reference prices, no near-miss visuals.** No paid random items at launch. If crates ever ship: show odds summing to 100% first, update displayed odds under any luck boost, and gate them with `PolicyService.ArePaidRandomItemsRestricted`.
- **No reward-for-watching feeds.** Rewarded video ads are allowed only if user-started, for the optional 2× offline-earnings button.
- **Prices fit Robux pack sizes** (80 / 400 / 800 / 1,700 / 4,500 / 10,000 R$).
- **All purchase grants go through the existing idempotent `ProcessReceipt`** (v1 MonetizationService receipt rules). Bought cash goes to the **bank** (it can never be mugged), and is excluded from the totalEarned and net-worth boards (v1 `NON_EARNING_REASONS`).

### 8.2 Game passes

| Key | Name | R$ | Effect | Why it is not pay-to-win |
|---|---|---|---|---|
| `cash2x` | 2× Garage Cash | 399 | Garage income (`garageMult`) and offline earnings ×2 | Passive income only. No effect on G, so crime, street, bounty, race and PvP payouts are unchanged. Progression speed, not power. |
| `vip` | VIP | 499 | Crown tag; VIP paint palette (12 colours) and plate frame; offline rate 60% (v1 `VIP_OFFLINE_RATE`); free Mechanic; +15 s laser lock | Status and convenience. The +15 s lock protects only parked cars. |
| `slots` | +2 Garage Slots | 299 | Slots 11–12 (v1) | Capacity |
| `vault` | +1 Vault Bay | 249 | A third vault bay (a second one is free at Rep 25) | Protects parked cars only. Driving still carries full risk. |
| `autocollect` | Auto-Collect | 199 | Garage cash goes to the bank every 60 s | Convenience |
| `neon` | Neon & Underglow Kit | 149 | Underglow and neon accents from Rep 1 (free at Rep 20) | Cosmetic |
| `plates` | Custom Plates | 99 | Custom plate text from Rep 1 (free at Rep 20) | Cosmetic |
| `horns` | Horn & Radio Pack | 99 | 10 horns, 2 extra radio stations | Cosmetic |
| `emotes` | Street Emotes | 149 | 8 emotes | Cosmetic |

**Gifting.** Each pass has a `gift_<key>` developer product (same price) that grants `giftedPasses[key]` to a chosen player in the server. Ownership checks are `hasPass(key) or giftedPasses[key]`.

### 8.3 Developer products

| Key | Name | R$ | Effect | Shown when |
|---|---|---|---|---|
| `cash_small` | Stack of Cash | 99 | 10 min × G, min $5,000 (v1 `cash_small`), to the bank | Phone store |
| `cash_big` | Briefcase | 399 | 1 h × G, min $50,000 (v1), to the bank | Phone store |
| `cash_huge` | Armored Case | 999 | 4 h × G, min $250,000, to the bank | Phone store |
| `starter_pack` | Starter Pack | 99 | One-time per account: a bound Rare "Stallion GT" with exclusive paint, $10,000 to the bank, 3 light armor, 48 P9 rounds | Once, 8–10 min into the first session (phone text), then only in the store |
| `lockdown` | Lockdown | 49 | Lock the garage for 10 min; stacks (v1 `lock_10`, DECISIONS §7). **V2: can't be bought while a theft from your garage is in progress, and never ejects a thief already driving out.** | When the Alarm fires (intruder entered) |
| `lose_cops` | Lose the Cops | 49 | Clears 1–4★. Not at 5★, not while carrying event loot, not with a street bounty, not as Menace. Refused at 0★ (v1). | Phone › Contacts › Lawyer (cash option beside it) |
| `impound_release` | Impound Release | 29 | Instantly releases one impounded car | Impound notice |
| `rush_repair` | Rush Repair | 19 | Instantly finishes one repair | Repair notice |
| `server_luck` | Server Luck ×2 | 199 | Street and dealer luck ×2 for **everyone** for 15 min, stacking duration; buyer announced; displayed odds update (v1) | Phone store |
| `make_it_rain` | Make It Rain | 149 | Triggers a server-wide Cash Rain (v1 mechanics); buyer announced | Phone store |
| `double_it` | Double It | 49 | Doubles the buyer's own share of the truck bag or heist payout just delivered (PvE only). Max 3 per UTC day. | On the payout shard, 10 s window, quiet button |
| `tint_gold` / `tint_platinum` | Weapon tints | 99 / 149 | Cosmetic gun tints (gta_combat §5.3; also $2M cash) | Gun store |
| `diamond_dragster` | Diamond Dragster | 799 | Bound hero car, re-tuned (§2.10): Epic-band income, Legendary-band performance, unstealable-to-keep, untradeable, excluded from pink slips | Dealership "Hero" stand |
| `street_pass` | Street Pass Premium | 499 | §6.5 premium track (a pass-type product per season) | Pause › STORE |

### 8.4 Retired v1 items (all had id 0, so none were ever sold)

| v1 item | Why it is retired |
|---|---|
| **Master Thief** (40% faster hotwire, `MASTER_THIEF_MULT`) | Speeds up stealing other players' cars: pay-to-win in PvP |
| **Infinite Nitro** | Decides races and chases |
| **Zapper Pass** | Combat cooldown advantage |
| **VIP "2× cash"** | Split into the `cash2x` pass (passive only) and a cosmetic `vip` |

### 8.5 Policy checklist

- **Moderate 13+.** Questionnaire per gta_combat §1.6.
- **Odds.** No paid random items at launch.
- **Trading.** `IsPaidItemTradingAllowed`. Robux cars are bound and untradeable regardless.
- **Pink slips.** Behind a flag until policy review (§5.4).
- **Text.** Plates, crew names and tags are filtered with `TextService:FilterStringAsync` and re-filtered per viewer with `GetNonChatStringForUserAsync` where shown.
- **Assets.** No GTA, Rockstar or real car brand names.
- **Referral rewards** use `ReferredByPlayerId` (v1).
- **No "free Robux" claims anywhere.**

---

## 9. Data model, migration and systems

### 9.1 `src/shared/Types.luau` (schema version 2)

The DataStore `HotwireCity_v1` and key `p_<userId>` **do not change**: the migration runs in place. Unchanged v1 types (`ContractState`, `NotifyKind`) stay as they are.

```lua
--!strict
-- Types.luau, schema version 2 (LOOP_V2 §9). Bump DataService.SCHEMA_VERSION to 2 with MIGRATIONS[1].

local Rarity = require(script.Parent.Config.Rarity)

export type RarityId = Rarity.RarityId
export type MutationId = Rarity.MutationId -- v1 only: kept for MIGRATIONS[1] and old tests
export type FinishId = "Stock" | "Gold" | "Chrome" | "Chameleon" | "Galaxy" | "Storm" | "Void" | "Glitch"
export type TraitId = "Turbo" | "Bulletproof" | "Classic" | "Prototype" | "LowMiles"

export type UpgradeTrack = "engine" | "turbo" | "handling" | "tires" | "armor" | "nitro" | "tracker" | "insurance"
export type CarUpgrades = {
	engine: number, -- 0..5
	turbo: number, -- 0..3
	handling: number, -- 0..4
	tires: number, -- 0..3
	armor: number, -- 0..5
	nitro: number, -- 0..4
	tracker: number, -- 0..3
	insurance: number, -- 0..3
}

export type PaintType = "Gloss" | "Matte" | "Metallic" | "Pearl"
export type PaintJob = {
	primary: string, -- Config/Paint palette id (never a raw client Color3)
	secondary: string,
	paintType: PaintType,
	pearl: string?, -- palette id (Pearl only)
	rims: string?, -- rim style id
	tint: number?, -- window tint 0..3
	underglow: string?, -- palette id (Rep 20 or Neon pass)
	plate: string?, -- filtered custom text (<= 8 chars); nil = generated plate
}

export type CarOrigin =
	"starter" | "street" | "traffic" | "dealer" | "hotdrop" | "theft" | "pinkslip" | "trade"
	| "reward" | "robux" | "season" | "event" | "migrated"
export type PlaceKind = "slot" | "vault" | "laylow"
export type CarPlace = { kind: PlaceKind, index: number } -- slot 1..12, vault 1..3, laylow 1
export type CarStatus = "ok" | "impounded" | "repair"

export type CarRecord = {
	uid: string, -- "<firstOwnerUserId>-<seq>": permanent identity, survives theft/trade/pink slip
	carId: string,
	finish: FinishId,
	trait: TraitId?,
	level: number, -- 1..Progression.CAR_LEVEL_CAP[rarity]
	xp: number, -- progress toward the next level
	upgrades: CarUpgrades,
	upgradeSpend: number, -- cash spent on upgrades (value formula, LOOP_V2 §2.6)
	paint: PaintJob,
	mileage: number, -- studs driven (UI miles = studs / 5700)
	serial: number?, -- limited edition number (#serial of Cars[carId].limitedCap)
	bound: boolean?, -- Robux/pass/starter/season: never kept by thieves, traded or staked
	origin: CarOrigin,
	acquiredAt: number, -- unix seconds, current owner
	firstOwner: number, -- userId
	owners: number, -- 1 = still with the original owner
	thefts: number, -- times stolen and kept
	uncollected: number, -- garage cash waiting at the Collect pad
	place: CarPlace,
	status: CarStatus,
	statusUntil: number?, -- unix: impound free-release time / repair done time
	tradeLockUntil: number?, -- unix
	laylow: { fromUserId: number, untilTime: number, insuredValue: number }?, -- only while place.kind == "laylow"
}

export type Stats = {
	steals: number, playerSteals: number, carjacks: number, repos: number, timesRobbed: number,
	busted: number, wasted: number, kills: number, hotDrops: number, robberies: number,
	trucks: number, heists: number, racesWon: number, pinkSlipsWon: number,
	bountiesClaimed: number, longestFiveStar: number, mileage: number,
}

export type TheftLedger = {
	day: number, -- UTC day the counters belong to
	losses: number, -- cars kept by thieves today
	insuranceClaims: number,
	playerCarChops: number, -- as the thief
	lastLossAt: number, -- unix (Shaken cooldown)
	pairs: { [string]: number }, -- tostring(otherUserId) -> unix of the last kept theft/claim between the pair; prune > 24 h
}

export type Security = { lock: number, alarm: number, door: number } -- lock 0..4 (v1 upgrades.lock), alarm 0..2, door 0..2

export type WeaponState = { ammo: number, tint: string? } -- reserve rounds (gta_combat §13.2); the magazine is runtime-only

export type CombatState = { -- gta_combat §13.2 + LOOP_V2 §4.6
	rookieSecondsLeft: number,
	passivePref: boolean,
	menace: number,
	menaceAt: number, -- unix of the last menace change (decay 1 per 10 min)
}

export type CrewRef = { id: string, rank: "Leader" | "Officer" | "Member", joinedAt: number }

export type SeasonState = { id: string, xp: number, premium: boolean, claimed: { [string]: boolean } } -- keys "f<tier>"/"p<tier>"

export type WeeklyState = { week: number, list: { { id: string, progress: number, claimed: boolean } } }

export type Settings = {
	music: boolean, sfx: boolean, hideHud: boolean, autoAccelerate: boolean, -- v1
	aimAssist: boolean, cameraShake: boolean, alwaysShowCash: boolean, radio: boolean, -- v2
}

-- Persisted player profile. Bump DataService schema version + add a migration when changing this.
export type PlayerData = {
	version: number, -- 2
	wallet: number, -- at risk (LOOP_V2 §0.4)
	bank: number, -- safe
	totalEarned: number,
	rep: number, -- 1..100
	repXp: number, -- toward the next Rep level
	rebirths: number, -- shown as Prestige
	slotsUnlocked: number, -- 4..10 (pass slots are derived)
	cars: { [string]: CarRecord }, -- uid -> record: every owned car incl. impounded / repair / laylow
	owedCars: { CarRecord }, -- waiting for a free slot (replaces v1 exclusives + pendingCars)
	nextCarSeq: number,
	discovered: { [string]: boolean },
	finishIndex: { [string]: { [string]: boolean } }, -- carId -> finish -> owned at least once
	security: Security,
	skills: { hotwire: number }, -- v1 upgrades.hotwire (Hotwire Kit)
	weapons: { [string]: WeaponState }, -- gta_combat ids: bat, pistol, microsmg, ...
	tools: { [string]: boolean }, -- gadgets kept from v1: taser, spikes (+ hackDevice, duffel)
	armor: number, -- 0..100, persisted like GTA
	medkits: number, -- 0..3
	combat: CombatState,
	stats: Stats,
	theft: TheftLedger,
	crew: CrewRef?,
	season: SeasonState,
	daily: { streak: number, lastClaimDay: number },
	contracts: ContractState,
	weekly: WeeklyState,
	codes: { [string]: boolean },
	receipts: { string },
	lastOnline: number,
	tutorialDone: boolean,
	onboarding: { [string]: boolean }, -- beat flags: "gun_gift", "first_bank", "starter_offer", ...
	settings: Settings,
	mailSeen: { string }, -- last 50 applied mail ids (idempotency)
	likes: { day: number, given: { [string]: boolean }, received: number },
	giftedPasses: { [string]: boolean },
	referralRewarded: boolean,
	referralsPaid: { day: number, count: number }?,
	playtime: { day: number, seconds: number, claimed: { [string]: boolean } },
	retiredCars: { { carId: string, finish: string, reason: string? } }?, -- sanitize-only (unknown ids, dupes)
}

-- Runtime-only car state for snapshots (never persisted).
export type CarRuntime = "Parked" | "Out" | "BeingStolen" | "LayLow" | "Missing" | "Impounded" | "Repair"

export type CarSnapshot = CarRecord & {
	runtime: CarRuntime,
	income: number, -- effective garage $/s (after garageMult)
	value: number, -- EconomyMath.carValue
	stats: { topSpeed: number, accel: number, grip: number, nitro: number, damageMult: number }, -- CarStats
}

export type Snapshot = {
	wallet: number, bank: number, totalEarned: number,
	rep: number, repXp: number, repToNext: number, rebirths: number,
	slotsUnlocked: number, maxSlots: number, vaultBays: number,
	cars: { [string]: CarSnapshot },
	owedCount: number,
	discovered: { [string]: boolean }, finishIndex: { [string]: { [string]: boolean } },
	security: Security, skills: { hotwire: number },
	weapons: { [string]: WeaponState }, tools: { [string]: boolean }, armor: number, medkits: number,
	stats: Stats,
	daily: { streak: number, canClaim: boolean, nextDay: number },
	playtime: { claimed: { [string]: boolean }, sessionSeconds: number },
	contracts: ContractState, weekly: WeeklyState, season: SeasonState,
	garageIncome: number, garageMult: number, G: number,
	passes: { [string]: boolean },
	plotIndex: number?,
	tutorialDone: boolean, onboarding: { [string]: boolean },
	settings: Settings,
	crew: CrewRef?,
	protection: { rookieSecondsLeft: number, starter: boolean, shakenUntil: number, dayCapped: boolean },
}

export type VehicleKind =
	"Parked" | "Traffic" | "Owned" | "Stolen" | "Loot" | "Dealership" | "HotDrop" | "Police"
	| "Joyride" -- a bound / protected car being driven by a non-owner (can't be delivered)
	| "Getaway" -- heist van (not ownable)
	| "Armored" -- armored truck event
	| "Swat" -- 5★ SWAT van
```

**Snapshot size.** Up to 15 cars × about 0.6 KB is about 9 KB, which is fine for `DataSnapshot`. Debounce stays at 0.1 s (v1). Street income and XP ticks go out as **attributes** (`Wallet`, `StreetMult`) and through `CarProgress`, not full snapshots.

### 9.2 Player attributes (server writes, clients read for the HUD)

| Attribute | Source |
|---|---|
| `Wallet`, `Bank` (replace v1 `Cash`) | DataService |
| `StreetMult` | StreetIncomeService |
| `Loaded` | BankingService |
| `Rep` | RepService |
| `Wanted` and v1 wanted attributes | WantedService |
| `Armor`, `InCombat`, `Protected`, `Passive`, `Rookie`, `Bounty`, `Menace` | DamageService (gta_combat) |
| `Shaken` (unix until) | TheftService |
| `District` | DistrictService |
| `PartyId` | PartyService |
| `CrewTag` | CrewService |
| `IncomePerSec`, `PlotIndex`, `Rebirths`, `Driving`, `Stunned`, `BustProgress` | v1, unchanged |

### 9.3 Migration v1 → v2 (DataService `MIGRATIONS[1]`)

**Plumbing changes.**
- `migrate(data)` becomes `migrate(data, ctx)` and `prepare(raw, now)` becomes `prepare(raw, now, userId)`. The migration needs `ctx.userId` for car uids.
- `makeTemplate()` becomes `makeTemplate(userId)`. The starter car is a `CarRecord` with uid `"<userId>-1"` and `nextCarSeq = 2`.
- `NO_MERGE` becomes `{ cars = true, owedCars = true }`: never merge template cars into an existing profile, the same lesson as v1 `garage`.

```lua
local MUTATION_TO_FINISH = { None = "Stock", Gold = "Gold", Diamond = "Chrome", Rainbow = "Chameleon", Galaxy = "Galaxy" }
local V1_ARMOR_TO_V2 = { [0] = 0, [1] = 2, [2] = 4, [3] = 5 } -- v1 values {1,.8,.6,.4} -> nearest v2 {1,.85,.72,.6,.5,.4}, rounded in the player's favour

MIGRATIONS[1] = function(d: any, ctx: { userId: number, now: number }): any
	local up = if typeof(d.upgrades) == "table" then d.upgrades else {}
	local function lvl(v: any, max: number): number
		return math.clamp(nonNegInt(v, 0), 0, max)
	end

	-- 1. money: everything a v1 player had was safe in their garage world -> bank
	d.bank = math.max(0, finite(d.cash, 0))
	d.wallet = 0
	d.cash = nil

	-- 2. player-wide upgrades -> security / skills / per-car tracks
	d.security = { lock = lvl(up.lock, 3), alarm = 0, door = 0 }
	d.skills = { hotwire = lvl(up.hotwire, 4) }
	local nitro, armor = lvl(up.nitro, 4), V1_ARMOR_TO_V2[lvl(up.armor, 3)]
	d.upgrades = nil

	-- 3. garage slots -> CarRecords (slot order, so uids are stable and readable)
	d.cars, d.owedCars, d.nextCarSeq = {}, {}, 1
	local function mint(carId: string, mutation: any, origin: string): any
		local uid = `{ctx.userId}-{d.nextCarSeq}`
		d.nextCarSeq += 1
		local def = Cars.get(carId)
		return {
			uid = uid, carId = carId,
			finish = MUTATION_TO_FINISH[mutation] or "Stock",
			level = 1, xp = 0,
			upgrades = { engine = 0, turbo = 0, handling = 0, tires = 0, armor = armor, nitro = nitro, tracker = 0, insurance = 0 },
			upgradeSpend = 0, -- grandfathered stages add no value (no free resale profit)
			paint = Paint.defaultFor(def), mileage = 0,
			bound = if def and def.rarity == "Exclusive" then true else nil,
			acquiredAt = ctx.now, firstOwner = ctx.userId, owners = 1, thefts = 0,
			origin = origin, -- "migrated" | "robux" | "reward"
			uncollected = 0, place = { kind = "slot", index = 0 }, status = "ok", -- owedCars ignore place until delivered
		}
	end
	local keys = {}
	for k in (if typeof(d.garage) == "table" then d.garage else {}) do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b) return (tonumber(a) or 99) < (tonumber(b) or 99) end)
	for _, k in keys do
		local rec, slot = d.garage[k], tonumber(k)
		if typeof(rec) == "table" and typeof(rec.carId) == "string" and slot then
			local car = mint(rec.carId, rec.mutation, "migrated")
			car.place.index = slot
			car.uncollected = math.max(0, finite(rec.uncollected, 0))
			d.cars[car.uid] = car
		end
	end
	d.garage = nil

	-- 4. owed cars: v1 exclusives (Robux, keys "id" or "id#n") + pendingCars (reward cars) -> owedCars
	for key in (if typeof(d.exclusives) == "table" then d.exclusives else {}) do
		local carId = string.match(key, "^([^#]+)")
		if carId and Cars.get(carId) then
			local car = mint(carId, "None", "robux")
			car.bound = true
			table.insert(d.owedCars, car)
		end
	end
	for _, p in (if typeof(d.pendingCars) == "table" then d.pendingCars else {}) do
		if typeof(p) == "table" and typeof(p.carId) == "string" and Cars.get(p.carId) then
			table.insert(d.owedCars, mint(p.carId, p.mutation, "reward"))
		end
	end
	d.exclusives, d.pendingCars = nil, nil

	-- 5. tools -> weapons (gta_combat §13.2): bat moves, taser/spikes stay tools; P9 welcome gift (+2 mags)
	local tools = if typeof(d.tools) == "table" then d.tools else {}
	d.weapons = { bat = { ammo = 0 }, pistol = { ammo = 24 } }
	d.tools = { taser = tools.taser == true or nil, spikes = tools.spikes == true or nil }
	d.onboarding = { gun_gift = true }

	-- 6. Rep from v1 history (never above Rep 15, so v2 unlocks still pace)
	local s = if typeof(d.stats) == "table" then d.stats else {}
	local xp = nonNegInt(s.steals, 0) * 50 + nonNegInt(s.playerSteals, 0) * 200 + nonNegInt(s.hotDrops, 0) * 300
	d.rep, d.repXp = Progression.repFromTotal(math.min(xp, Progression.REP_TOTAL[15]))

	-- 7. protection: v1 had no guns; give everyone a short grace to learn them
	d.combat = { rookieSecondsLeft = if d.tutorialDone == true then 600 else 1800, passivePref = false, menace = 0, menaceAt = 0 }

	-- everything else (theft, season, weekly, likes, mailSeen, giftedPasses, new stats, new settings)
	-- is filled by reconcile(makeTemplate(userId)) after migrate; sanitize enforces shapes.
	return d
end
```

**sanitize v2** (extends the v1 rules: finite, non-negative, clamped; unknown ids go to `retiredCars`, never deleted):

| Field | Rule |
|---|---|
| `wallet`, `bank` | Finite and ≥ 0 |
| `rep` | 1..100 |
| `repXp` | Below `repToNext(rep)`; carry over otherwise |
| `cars[uid]` | Valid `carId` (else → `retiredCars`). `finish` must be a known `FinishId` (else "Stock"). `level` in 1..cap. `xp` below `xpToNext`. Every upgrade clamped to its track max. `paint` ids must be in the palette (else defaults). `plate` ≤ 8 chars (re-filtered on display). `uid` must match the key. |
| Place collisions | Two cars in the same slot or vault index: the later `acquiredAt` moves to `owedCars`. A `slot` index above capacity → `owedCars`. |
| `laylow` | `laylow` with `untilTime` already past → finalise as a slot if one is free, else `owedCars`. **Exception:** if `ctx.now − untilTime > 1 day` and the profile was released mid-window, finalise anyway. |
| `owedCars` | Capped at 20 (oldest first) |
| `nextCarSeq` | > the highest seq among uids whose first owner is this user |
| `theft.pairs` | Prune entries older than 24 h. A new UTC day resets the counters. |
| `mailSeen` | Capped at 50 |
| `weapons` | Ids must be in `Config/Weapons`; ammo clamped to `reserveCap` |
| `armor` | 0..100 |
| `medkits` | 0..3 |

**Rolling-update safety.**
- Publish V2 with **"Shut down all servers"**, not a soft migration. A v1 server that loads a v2 profile would let the player play on v1 rules: v1 `reconcile` re-adds a template `garage` and `cash` and drops v2 progress made there.
- v1 `migrate` already keeps a newer `version`, and v1 `reconcile` never removes keys, so v2 data survives even if one does slip through.
- Tests (owned by the data workstream) assert:
  - a v1 profile with 6 cars, mutations, upgrades and exclusives migrates to v2 with identical total income (finish multipliers equal v1 mutation multipliers);
  - no car is lost;
  - uids are unique;
  - running `prepare` twice is a no-op.

### 9.4 Config and shared modules

| File | Status | Contents |
|---|---|---|
| `Config/Economy.luau` | Change | Wallet, bank and LOADED constants; ATM fee; fees (§7.3); `G_MIN`. Tools move to Weapons (gta_combat). Upgrades split per §2.4. |
| `Config/Rarity.luau` | Change | Add `Finishes` (§2.5) beside `Mutations` (kept for the migration). Add `Traits`. |
| `Config/Cars.luau` | Change | Optional `limitedCap`, `class` (sedan / sports / super… for orders and sets), `bound` hero flag. The vehicles workstream owns the actual list. |
| `Config/Upgrades.luau` | New | Tracks, stage effects, price factors, level gates (§2.4); security ladders (§2.7.3) |
| `Config/Progression.luau` | New | Rep curve and unlock table (§6.1), car XP curve and level caps (§2.3), XP sources, season tiers |
| `Config/Crime.luau` | New | §3.2 activity table, truck (§3.6), heist (§3.7), jewelry, jobs, wantedMult, party mult |
| `Config/Theft.luau` | New | §2.7–2.8 constants |
| `Config/Districts.luau` | New | §6.2 table + polygons [world] |
| `Config/Paint.luau` | New | Palette, paint types, rims, plate rules |
| `Config/LiveOps.luau` | New | Weekend rotation, Admin Abuse events, weather, clamps |
| `Config/Monetization.luau` | Change | §8 catalog |
| `Config/Police.luau` | Change | Heat keys (§3.11 + gta_combat §9.5), district factors |
| `Config/Weapons.luau` | New (gta_combat) | Plus a `rep` field per weapon (§4.1) |
| `Util/EconomyMath.luau` | Change | `carIncome`, `carValue`, `sellValue`, `chopValue`, `insurance`, `G`, `garageMult` (renamed `playerMultiplier`) |
| `Util/CarStats.luau` | New | Pure: effective `topSpeed / accel / grip / nitro / damageMult / tireMode` from `CarDef` + `CarRecord`. **VehicleController, the watchdog speed cap and police speed matching all read it.** |
| `Util/Payout.luau` | New | Pure: §3.1 formula, truck clamp, heist split, bounties |
| `Util/Progression.luau` | New | Pure: `xpToNext`, `repToNext`, `repFromTotal`, level caps |
| `Util/Rolls.luau` | Change | `rarity(source, luck, rng, districtLuck?)` allows districtLuck < 1; `finish(boost, rng, weather?)`; `trait(rarity, rng)`; returns probabilities for "1 in X" |

### 9.5 Systems: what changes and what is new

**Changed v1 systems:**

| System | Changes |
|---|---|
| **DataService** | Schema v2, `migrate(data, ctx)`, `makeTemplate(userId)`, sanitize v2. Money API: `addWallet(p, n, reason)`, `addBank(p, n, reason)`, `spend(p, n, reason): boolean` (wallet then bank), `takeWallet(p, fraction, reason): number`, `transferWallet(from, to, n, reason)`. `addCash` stays as an alias of `addBank` during the transition. Every call routes to EconomyTelemetry. `saveNow` unchanged. |
| **GarageService** | Physical garage only: pads, vault bays, lay-low pad, display cars, collect pad, drive out (`DriveCar(uid)`), Mechanic. Income uses `EconomyMath.carIncome(record)`. Chop moves to ChopShopService. |
| **TheftService** | Garage raid now ends in lay-low. **Carjack** of `Owned` cars, lay-low window, repo, insurance, §2.8 protections and ledger, interceptor and revenge rewards, mail returns. Signals: `TheftStarted`, `TheftEnded(theft, outcome: "kept" / "repo" / "dropped" / "failed" / "chopped")`. |
| **VehicleService** | `spawnFromRecord(record, cframe, kind)` with `CarStats`; per-car nitro and armor; bullet damage and tire pops (gta_combat §10.5); a CARJACK prompt on player-driven Owned cars; new kinds; the watchdog uses `CarStats.topSpeed`; drive samples (distance, speed, input) published to StreetIncomeService. |
| **WantedService** | Evade model (gta_combat), wantedMult, new heat keys, BUSTED economy (§4.4), evade bonus, 5★ Most Wanted trigger and survival payout, flash heat, Lawyer. |
| **PoliceService** | District factors, response delay. Combat goes in PoliceCombatService (gta_combat). |
| **CombatService** | Taser and spikes gadgets only (gta_combat §13.2) |
| **ShopService** | The gun store (gta_combat) + Rep gates + Hacking Device and Duffel |
| **RewardsService** | Rewards go to the bank; car rewards minted through CarService; weekly and crew contracts; new stats; streak pause; season XP hooks |
| **RebirthService** | Prestige rules (§6.3) |
| **MonetizationService** | §8 catalog, `giftedPasses`, bound-car grants into `owedCars`, refusal rules (lockdown during theft, lose_cops limits) |
| **EventService** | Hot Drop interval {600, 900}; Cash Rain, Rush Hour, 2× Cash and Server Luck unchanged; the clock moves to EventClock |
| **DealershipService** | Restock at the pulse (300 s); mints CarRecords; hero stand; limited sales during events |
| **StreetSpawnService** | District luck, finish, trait and "1 in X" metadata (car attributes `OneInX`, `Finish`, `Trait`) |
| **NPCService** | Muggable peds, clerks, truck guards, heist cameras and guards (gta_combat officer budget) |
| **LeaderboardService** | §5.6 boards |
| **AdminService** | `/hc wallet\|bank\|rep\|carlevel\|upgrade\|finish\|truck\|heist\|mostwanted\|liveops\|audit\|mail` (gated as v1) |
| **PlotService** | Vault bay, lay-low pad, alarm and door levels, garage safe zone, hospital respawn hook (gta_combat) |
| **LightingService** | Weather states for LiveOps |

**New systems** (`src/server/Systems/`; ProximityPrompts are server-validated with the `VehicleService.addStealPrompt` hold pattern):

| System | Responsibility | Public API (main) |
|---|---|---|
| **EconomyTelemetry** | `LogEconomyEvent` for every flow; anomaly scoring; funnels | `log(p, flow, amount, sku, txType)`, `flag(p, reason)` |
| **MailService** | Cross-server mailbox `HC_Mail_v1/<userId>` (UpdateAsync append; claim on load; dedupe with `mailSeen`) | `send(userId, item)`, applied in `DataService.Loaded` |
| **CarService** | Owns CarRecords: mint uid, place/move, remove, transfer between two loaded profiles, deliver owed cars, value and income queries | `mint(p, carId, opts)`, `transfer(fromP, toP, uid, reason)`, `move(p, uid, place)`, `get(p, uid)` |
| **RepService** | RP, levels, unlock checks | `addRP(p, n, reason)`, `has(p, unlockId)` |
| **DistrictService** | Point → district; mults | `at(pos)`, `payoutMult(pos)`, `luck(pos)` |
| **StreetIncomeService** | S×, wallet ticks, car XP, mileage, flash heat, LOADED refresh | `getMult(p)`, signal `CarLevelUp(p, uid, level)` |
| **ModShopService** | Upgrades, security, paint, plates | remotes in §9.6 |
| **BankingService** | ATMs, garage auto-deposit, LOADED marker, cash bags (drops and pickups) | `deposit(p, viaAtm)`, `dropBag(pos, amount, priorityUserId?)` |
| **RobberyService** | Stores, ATM hack, jewelry store, NPC and player mugging | prompts and MiniGame sessions |
| **ChopShopService** | Chop (from GarageService), order board | `orders()`, ChopAttempt handler |
| **EventClock** | Pulse and big pulse scheduler, `PulseState` broadcast | `nextPulse()`, signals `Pulse`, `BigPulse` |
| **ArmoredTruckService** | Truck AI route, guards, crack, bags | `TruckState` |
| **HeistService** | Lobby, roles, stages, bags, split | `HeistState` |
| **JailService** | Jail sentence, break-out, impound lot, repair queue | `RetrieveImpound`, `RushRepair` |
| **PartyService** | Session party, invites, waypoint, friendly-fire flag, party mult | `getParty(p)`, `sameParty(a, b)` |
| **CrewService** | Persistent crews (`HC_Crews_v1`), roster, tag, weekly RP | `getCrew(p)` |
| **RaceService** | Meets, races, house prizes, pink slips (flagged), time trials | `RaceState` |
| **TradeService** | Trade sessions, atomic swap (§10.4) | `TradeState` |
| **SerialService** | Limited minting and registry | `mint(carId)`, `verify(p)` |
| **SeasonService** | Street Pass | `addSXP(p, n)`, `ClaimSeasonTier` |
| **LiveOpsService** | Calendar, weekend modifiers, weather, Admin Abuse (MessagingService), live config | `mult(kind)`, `active()` |
| **JobsService** | Phone jobs | `JobAccept`, `JobAbandon` |
| (gta_combat) **WeaponService, DamageService, HitboxHistory, PoliceCombatService** | Combat | per gta_combat §13 |

**Boot `ORDER`** (inserted into `src/server/init.server.luau`):

```
MapBuilder, AssetLibrary, MapDresser, LightingService,
DataService, EconomyTelemetry, MailService, MonetizationService, RepService, DistrictService,
PlotService, VehicleService, CarService, GarageService, StreetIncomeService, BankingService,
WantedService, PoliceService, PoliceCombatService, TheftService, JailService,
DealershipService, StreetSpawnService, TrafficService, NPCService,
HitboxHistory, DamageService, WeaponService, CombatService,
EventService, EventClock, ArmoredTruckService, HeistService, RobberyService, ChopShopService, JobsService,
PartyService, CrewService, RaceService, TradeService, SerialService,
RewardsService, SeasonService, LiveOpsService, RebirthService, ShopService, ModShopService,
LeaderboardService, AdminService, VehicleFxService
```

Back-edges stay lazy requires (SPEC §4).

**Client controllers (new):**
- PhoneController (apps per UI §5.11), MapController (full map + GPS).
- WeaponClient, ShoulderCamera, WeaponWheel, CombatHUD, DeathScreenController (gta_combat).
- RevealController ("1 in X" reveal), StreetHUD (S× + ramp, LOADED).
- ModShopClient, TradeClient, RaceClient, HeistClient, TruckClient, PartyClient, QuickChatWheel, PhotoModeController, HotwireClient (timing bar).

### 9.6 Remotes (added to `Shared/Remotes.luau`)

All are validated with `Net.is*`, re-derived from server state, and rate-limited (per second). Most world interactions are **ProximityPrompts** handled server-side, so they need no remote: Hotwire, Carjack, Repo, Recover, Hold Up, Mug, Hack, Deposit, Crack, Cool drill, Grab bag, Smash case, Breach, Break out, Like garage, Race start.

**Client → server**

| Remote | Payload | Rate/s |
|---|---|---|
| `DriveCar` (changed) | `(uid: string)` | 1 |
| `SellCar` (changed) | `(uid: string)` | 2 |
| `MoveCar` | `(uid: string, kind: "slot" \| "vault", index: number)` | 2 |
| `CallMechanic` | `(uid: string)` | 0.5 |
| `ModShopBuy` | `(uid: string, track: UpgradeTrack)` | 4 |
| `BuySecurity` | `(kind: "lock" \| "alarm" \| "door")` | 2 |
| `ApplyPaint` | `(uid: string, paint: PaintJob)` (server validates every palette id) | 2 |
| `SetPlate` | `(uid: string, text: string)` | 0.5 |
| `RetrieveImpound` | `(uid: string)` | 1 |
| `RushRepair` | `(uid: string)` | 1 |
| `KillSwitch` | `(uid: string)` | 1 |
| `MiniGameInput` | `(sessionId: string, step: number, value: number)` | 10 |
| `SetPassive` | `(on: boolean)` (gta_combat) | 1 |
| `PartyInvite` / `PartyRespond` / `PartyLeave` / `PartyKick` | `(userId)` / `(inviteId, accept)` / `()` / `(userId)` | 1 / 2 / 1 / 1 |
| `MapPing` | `(pos: Vector3)` | 2 |
| `QuickChat` / `Emote` | `(callId: number)` / `(emoteId: string)` | 2 / 2 |
| `CrewCreate` / `CrewInvite` / `CrewRespond` / `CrewLeave` / `CrewKick` / `CrewPromote` | `(name, tag, emblemId)` / `(userId)` / `(inviteId, accept)` / `()` / `(userId)` / `(userId, rank)` | 0.2 / 1 / 1 / 0.2 / 1 / 1 |
| `HeistLobby` | `(action: "start" \| "ready" \| "leave" \| "role" \| "split", value: any)` | 2 |
| `RaceChallenge` / `RaceRespond` | `(userId, routeId, stakeUid: string?)` / `(challengeId, accept, stakeUid: string?)` | 0.5 / 1 |
| `TradeRequest` / `TradeRespond` / `TradeOffer` / `TradeReady` / `TradeConfirm` / `TradeCancel` | `(userId)` / `(tradeId, accept)` / `(tradeId, uids: {string})` / `(tradeId, ready)` / `(tradeId)` / `(tradeId)` | 0.5 / 1 / 3 / 2 / 1 / 1 |
| `ClaimSeasonTier` | `(tier: number, track: "f" \| "p")` | 2 |
| `JobAccept` / `JobAbandon` | `(jobId: string)` / `()` | 1 / 1 |
| `LendCar` (V2.1) | `(uid: string, userId: number?)` | 1 |
| Combat remotes | gta_combat §13.2 | per that doc |

**Server → client**

| Remote | Payload |
|---|---|
| `Busted` (changed) | `{ confiscated: number, surrendered: boolean, sentence: number, impoundedUid: string?, impoundFee: number?, bagsLost: number }` |
| `Wasted` (gta_combat) | Plus `{ hospitalFee: number, droppedCash: number }` |
| `CarStolenAlert` (changed) | `(thiefName, uid, carId, finish, active, method: "raid" \| "carjack", trackerLevel)` |
| `Reveal` | `{ carId, finish, trait?, oneInX: number, source: string, uid: string? }` |
| `CarProgress` | `(uid, level, xp, leveledUp: boolean)` on level-up, else every 5 s while driving |
| `RepProgress` | `(rep, repXp, toNext, unlocks: {string}?)` |
| `PulseState` | `{ nextTruck, nextBigPulse, heistOpenUntil?, nextHotDrop, nextRestock, orders: {Order} }` |
| `TruckState` | `{ phase, routeId, position?, bags: {{ id, value, carrierUserId? }} }` |
| `HeistState` | `{ phase, crew, roles, split, objectives, bags, endsAt }` |
| `BountyState` | `{ {userId, amount, kind: "street" \| "mostWanted", lastPing: Vector3?} }` |
| `RevengeState` | `{ {userId, untilTime, reason} }` |
| `Invite` | `{ kind: "party" \| "crew" \| "trade" \| "race", id, fromUserId, payload }` |
| `PartyState` / `CrewState` / `TradeState` / `RaceState` | Session views |
| `QuickChatRelay` | `(fromUserId, callId)` |
| `MailApplied` | `{ {id, kind, summary} }` |
| `LiveOpsState` | `{ modifiers: {[string]: number}, events: {...}, weather: string }` |

### 9.7 Build order (waves)

| Wave | Content | Done when |
|---|---|---|
| W1 Foundation | Types v2, migration, DataService money API, CarService, EconomyMath / CarStats / Payout / Progression, EconomyTelemetry, MailService, RepService | Lune specs green: migration preserves income, uids are unique, formulas match §2.6 and §3.1 |
| W2 Casino | StreetIncomeService, ModShopService, vault and lay-low pads, TheftService v2 (carjack, repo, insurance, protections), BankingService (wallet, ATM, LOADED) | A two-client test: carjack → lay-low → repo, and carjack → keep → insurance |
| W3 Combat | gta_combat C0–C1 + §4 economy hooks, JailService | WASTED and BUSTED economy verified |
| W4 Crime | RobberyService, ChopShopService, EventClock, ArmoredTruckService, Most Wanted, JobsService, DistrictService | Stage A–B playtest hits §7.4 within ±50% |
| W5 Crew | PartyService, HeistService, quick chat, jewelry store | 4-player heist end to end |
| W6 Meta | RaceService, TradeService, SerialService, CrewService, SeasonService, LiveOpsService, leaderboards, monetization catalog | Trade dupe tests, live-config clamp tests |

---

## 10. Anti-exploit requirements

### 10.1 Global rules (every new system)

1. **Clients send intent, never values.** Ids and uids only. Prices, payouts, values, levels, positions used for payouts, timers and ownership are re-derived on the server.
2. **Every remote** goes through `Net.on(name, handler, rate)` with `Net.is*` validation. Every ProximityPrompt trigger re-checks distance (≤ `MaxActivationDistance` + 2), line of sight where it matters, state, and the hold time (the `addStealPrompt` pattern: server-recorded `PromptButtonHoldBegan`, reject below 0.9× the required hold, no stale holds).
3. **Taint.**
   - Any car flagged by the VehicleService watchdog, and any character flagged by the new **CharacterWatchdog**, earns nothing until the taint clears 10 s after the last violation.
   - Tainted means: no street income, no XP, no deliveries, no bag pickups or deliveries, no payouts.
   - CharacterWatchdog rule: horizontal speed ≤ `WalkSpeed × 1.5 + 4` on foot, teleport displacement checks, and server rewind like the car watchdog.
4. **Minimum travel time.** Every "carry from A to B" payout (loot delivery, theft, truck and heist bags, races, jobs) uses `VehicleService.minTravelTime` or the on-foot equivalent from pickup to drop. Faster is refused.
5. **Atomic money.**
   - `spend()` happens before the grant, with a refund on grant failure (the v1 Dealership pattern).
   - Grants and their idempotency markers go in the same profile write (the v1 receipt pattern).
6. **Caps and cooldowns** in Config are enforced server-side with per-player and per-server state.
7. **Logging.** Every minted payout calls EconomyTelemetry with its row id. Anomalies are flagged, never auto-banned (gta_combat §10.7 philosophy).

### 10.2 Per money source

| Source | Exploit vector | Server rule |
|---|---|---|
| Street income (S3) | Speedhack, fly or teleport; AFK auto-drive; driving circles in a lot; safe-zone farming; passive farming | Watchdog taint pauses income. ≥ 150 studs net displacement per 60 s. Input-change check every 45 s (server reads `VehicleSeat.ThrottleFloat/SteerFloat`). Road-zone check (RoadGraph lane bounds + 12 studs). Off in safe zones and own garage. Passive ×1.5. S× computed only from server state (stars, cruise seconds). Mileage and XP use the same gates. |
| Car XP | XP farming in a loop | Same gates; XP is capped at 1.5× the base rate per minute of driving (bonuses can't stack beyond) |
| Hotwire timing bar (CLEAN steal) | Always hitting "perfect" | The server picks the sweet-spot window per hold and measures the tap against its own record of when the hold began (±120 ms plus half the ping). The worst case, always perfect, equals a 40% faster hold and never applies to garage raids or carjacks. Logged if the perfect rate stays above 90% over 20 steals. |
| Store hold-up (S4) | Remote spoof; robbing from outside; multi-store teleport chains | Prompt and aim checks server-side (gun equipped, within 15 studs, aim vector from HitboxHistory facing). Fill ticks server-side only while inside the store volume and within 12 studs. Per-store server cooldown 300 s, per-player 45 s. Taint voids the payout. |
| ATM hack (S5) | Auto-solve; spoofed success | The server owns the mini-game seed and step deadlines. The client sends one value per step; a wrong or late value fails the step. Minimum 6 s total. Per-ATM cooldown. |
| NPC mugging (S6) | Mass-farming peds | Per-ped cooldown 120 s; diminishing returns ×0.25 after 10 in 10 min; ped count bounded by the NPCService budget |
| Player mugging (T1) | Alt laundering, harassment | Pure transfer (no mint). 120 s victim immunity. Rookie, passive and safe-zone checks. REVENGE mark. Logged. |
| LOADED drop, carjack spill (T2, T3) | Kill-farming | Only LOADED victims drop (§3.4). Drops are server parts; pickup by Touched validated server-side (distance ≤ 6, alive, untainted). Killer priority 3 s. |
| Jewelry (S7) | Remote smashes | Melee or shot hit validated by WeaponService on the case part. Each case pays once. Server cooldown. |
| Chop (S8) | Chopping teleported or owned cars; order spam | v1: only Loot, untainted, `minTravelTime`, dwell. Orders: first 3 fills each, server-checked against car attributes. Player-car chop caps (§2.8). |
| Evade bonus (S9) | Self-heat farming (shoot in the air, evade) | Paid only if peak stars came from a crime **with a victim or target** (not `gunfire` alone), only on a true evade, at most 6 paid evades per hour |
| Truck bags (S10) | Server hopping; teleport delivery; alt median inflation | Bag value frozen at spawn from the **median** of eligible players, clamped by the deliverer's own G. 12 bags per player per hour. Bags are server-owned parts; carrier state is server-side. `minTravelTime` from crack point to drop-off. Rookies can't pick up. |
| Bank heist (S11) | AFK crew members; split abuse; alt median | Members must be within 300 studs of the vault at drill end **and** have done at least one interaction (hack, cool, grab, deliver, or a damage contribution) to get a share. Split stored at lobby lock and immutable after. Per-member clamp. One heist per window per server. |
| Phone jobs (S12) | Instant completion | Server checkpoints with `minTravelTime`; 20 paid per day |
| Contracts, daily, playtime (S13) | v1 handled | Stats come only from server events (`RewardsService.progress`); playtime is server-measured (v1) |
| Races (S14) | Alt races; teleport; nitro hacks | Server checkpoints, segment `minTravelTime`, taint disqualifies, VehicleFx nitro caps (v1), pair caps (3 per day), 10 paid wins per day |
| Insurance (S15) | Alts stealing each other's cars | 20 min hold before a car is insurable; 3 claims per day; the first per pair per 24 h; punch-down and starter rules; paid only after a 300 s lay-low window without a repo |
| Repo, recovery, revenge, interceptor (S16) | Staged thefts | v1 `BONUS_PAIR_COOLDOWN` 600 s per pair; recovery needs `RECOVERY_MIN_SECONDS` (v1); interceptor capped at 5 per day and per pair per 30 min |
| Most Wanted reward (S17) | Friend or alt gets 5★, buddy claims | 60 s or more at 5★; claimer not in the target's party, crew or Roblox friends (`IsFriendsWith`, cached); 3 per claimer per day; per pair per 30 min |
| 5★ survival (S18) | Hiding in an unreachable spot | Paid only if the target was seen by police at least once per 60 s at 5★ (`isSeen` history), and evaded outside safe zones and the own garage |
| Prestige | Prestige with cars hidden mid-theft | Requires every car parked, none missing or in lay-low, not in combat |
| Deposits | Depositing while chased | 0★ required. Garage deposit needs a server-side interior check. ATM 2 s hold. |
| Mechanic, Go Home | Instant escape or bank | Blocked while wanted, LOADED, In Combat, or carrying loot |
| Combat | Aimbot, damage spoof, rapid fire | gta_combat §10: hitscan validation pipeline, HitboxHistory rewind, server ammo, ShotAudit |

### 10.3 Ownership and transfer integrity

1. **Car identity.** A uid is permanent. Every transfer (`CarService.transfer`) removes the record from the source and inserts it into the destination in one server step. Both profiles must be loaded in this server, or the source is this server and the destination gets mail.
2. **Save ordering for transfers.** `saveNow(giver)` first, then `saveNow(receiver)` (run with `task.spawn`, since saveNow yields).
   - **A crash between the two** loses the car instead of duplicating it. To recover: before the transfer, write `HC_Escrow_v1/<transferId> = { uid, record, from, to, status = "pending" }`; after both saves, mark it "done".
   - **On load,** MailService scans the escrow index for this user (`HC_Escrow_v1/idx_<userId>`, a small list) and re-delivers any "pending" record whose uid is missing from both profiles. It never re-delivers if the uid exists anywhere it can check.
3. **Trades are two transfers** under one `tradeId`, run with the same escrow and ordering. Before the swap, the server re-validates both sides: ownership, `status = ok`, not lay-low, not trade-locked, not bound, eligibility, and **offer unchanged since the last Ready**.
4. **Serial cars** have an extra global registry check on every load (§2.9). Duplicates go to `retiredCars` with reason "dupe" and are flagged.
5. **Mail** items have a GUID. Apply-then-record in `mailSeen` happens in the same write, so items are idempotent.
6. **Leaving mid-transfer.**
   - A thief leaving during delivery: v1 `fail` returns the car home.
   - A thief leaving during lay-low: mail return.
   - Trades: cancel if either player leaves before the swap step.
   - Heist or truck bags carried by a leaver drop at their last valid position.
7. **Combat logging.** Leaving within 15 s of player damage (In Combat), or at 2★ or more, applies the BUSTED wallet penalty (35%) at release. This is recorded in the same final save. The Roblox disconnect reason doesn't change it; a mobile drop counts, and the rule is announced in the help text the first time you get 2★.

### 10.4 Things the client must never be trusted with

Money amounts, prices, car stats, level or XP, upgrade levels, finish or trait rolls, "1 in X", payout multipliers, wanted stars, district, party membership, split percentages after lock, mini-game success flags, bag ownership, race times, positions used for payouts (always server-sampled), and anything gta_combat §10.7 lists.

---

## Appendix A: Config skeletons (starting values for engineers)

```lua
-- Config/Theft.luau
return {
	CARJACK_MAX_SPEED = 8, CARJACK_HOLD = 0.8, CARJACK_DELIVERY_LIMIT = 180,
	WALLET_SPILL_ON_CARJACK = 0.10, PLAYER_CAR_CHOP_RATE = 0.20, PLAYER_CAR_CHOPS_PER_DAY = 3,
	LAYLOW_SECONDS = 300, REPO_HOLD = 3, REPO_HOLD_TRACKER3 = 1.5,
	REVENGE_MARK_SECONDS = 900, REVENGE_BONUS_SECONDS = 60, REVENGE_BONUS_BASE = 500,
	INTERCEPTOR_BASE = 500, INTERCEPTOR_SECONDS = 30, INTERCEPTOR_PER_DAY = 5,
	STARTER_REP = 5, STARTER_CARS = 4, MIN_CARS_KEPT = 2,
	VICTIM_COOLDOWN = 600, MAX_LOSSES_PER_DAY = 3, PAIR_COOLDOWN = 3600, PUNCH_DOWN_REP_GAP = 15,
	INSURANCE_RATES = { [0] = 0.25, 0.40, 0.55, 0.70 }, INSURANCE_MIN_HOLD = 1200, INSURANCE_CLAIMS_PER_DAY = 3,
	IMMOBILIZER = { [0] = 1, 1, 1.5, 2.0 }, -- by tracker level
	S_CAP = 10, S_CAP_BOUND = 5, S_BASE = 3, S_RAMP_PER_MIN = 0.5, S_RAMP_MAX = 3, S_PER_STAR = 1, S_PASSIVE = 1.5,
	FLASH_HEAT_SECONDS = 120, FLASH_MIN_RARITY_ORDER = 5, FLASH_MIN_MULT = 6,
}

-- Config/Crime.luau (excerpt)
return {
	WANTED_MULT = { [0] = 1.0, 1.2, 1.5, 2.0, 2.5, 3.0 },
	PARTY_BONUS_EACH = 0.10, PARTY_BONUS_MAX = 0.30, PARTY_RADIUS = 150, PASSIVE_MULT = 0.5,
	Activities = {
		store = { rep = 1, fill = 8, base = 500, secs = 120, heatStart = 1, heatFull = 2, storeCd = 300, playerCd = 45, rp = 80 },
		gas = { rep = 6, fill = 10, base = 800, secs = 150, heatStart = 2, heatFull = 2, storeCd = 300, playerCd = 45, rp = 100 },
		pawn = { rep = 10, fill = 12, base = 1500, secs = 200, heatStart = 3, heatFull = 3, storeCd = 480, playerCd = 45, rp = 140 },
		atm = { rep = 6, time = 6, base = 300, secs = 90, heat = 2, atmCd = 600, rp = 70 },
		npcMug = { rep = 1, hold = 1.5, base = 40, secs = 8, heatChance = 0.5, pedCd = 120, drAfter = 10, drMult = 0.25, rp = 8 },
		jewelryCase = { rep = 8, cases = 8, smash = 2, base = 800, secs = 30, heat = 3, serverCd = 900, rp = 250 },
		evade = { basePerStar = 100, secsPerStar = 15, rpPerStar = 20, paidPerHour = 6 },
	},
	Truck = { interval = 300, warn = 30, hp = 2000, tireHp = 150, guards = 2, crack = 8, bags = 4,
		bagBase = 2000, bagMedianSecs = 120, clampBase = 5000, clampSecs = 300, heat = 3, bagsPerHour = 12, rp = 200 },
	Heist = { interval = 1800, window = 300, minCrew = 2, maxCrew = 4, rep = 10, kitBase = 10000, kitSecs = 30,
		bags = 8, bagBase = 15000, bagMedianSecs = 450, objectiveBonus = 0.05, splitMin = 0.15, splitMax = 0.40,
		clampBase = 60000, clampSecs = 3600, rivalShare = 0.5, rp = 800, rpPerBag = 100 },
	MostWanted = { base = 2500, secs = 60, growthPer30s = 0.1, growthCap = 3, minSeconds = 60, perClaimerDay = 3,
		survivalBase = 1000, survivalSecsPerMin = 60, survivalMaxMin = 10 },
}

-- Config/Progression.luau (excerpt)
return {
	REP_MAX = 100, REP_COEF = 40, REP_EXP = 1.45, -- repToNext(L) = floor(40 * L^1.45)
	CAR_XP_COEF = 80, CAR_XP_EXP = 1.6, CAR_XP_PER_STUD = 0.05, -- xpToNext(L) = floor(80 * L^1.6)
	CAR_LEVEL_CAP = { Common = 20, Uncommon = 25, Rare = 30, Epic = 35, Legendary = 40, Mythic = 45, Secret = 50, Exclusive = 35 },
	LEVEL_INCOME_STEP = 0.03, LEVEL_VALUE_STEP = 0.02,
	VAULT_BAYS = { { rep = 5 }, { rep = 25 }, { pass = "vault" } },
	SEASON_TIERS = 50, SEASON_TIER_XP = 2000,
}
```

---

## Appendix B: v1 config values, kept vs changed

| v1 value | V2 |
|---|---|
| `STARTING_CASH 150`, `STARTER_CAR rustbucket` | Kept; the cash goes to the bank |
| `START_SLOTS 4`, `MAX_SLOTS 10`, `PASS_EXTRA_SLOTS 2`, `SLOT_PRICES` | Kept |
| `SELL_FRACTION 0.5`, `CHOP_SHOP_FRACTION 0.35` | Kept. Sell is now 50% of *value* (§2.6). |
| `Upgrades.lock {45,60,90,120}` | Garage security plus a level 4 at 180 s / $2.5M |
| `Upgrades.hotwire` | Kept as the Hotwire Kit skill |
| `Upgrades.nitro`, `Upgrades.armor` | Become per-car tracks (§2.4), grandfathered |
| `Tools` bat / taser / spikes | Bat → weapons; taser and spikes stay as tools (gta_combat). Prices kept. |
| `BUSTED_CASH_PENALTY 0.1` / cap 600 s | 35% of wallet, uncapped, bank safe (§4.4) |
| `SPRAY_*` | Kept (G-based) |
| `THEFT_TIME_LIMIT 150`, `DROPPED_CAR_TIMEOUT 20`, `THEFT_ABANDON_LIMIT 12`, `THEFT_HOLD_MULTIPLIER 1.4` | Kept |
| `NEWBIE_PROTECTION_CARS 3` | Starter protection: Rep 5 **and** 4 cars |
| `THEFT_VICTIM_COOLDOWN 25` | 600 (Shaken) |
| `RECOVERY_BONUS_SECONDS 30`, `BONUS_PAIR_COOLDOWN 600` | Kept (repo uses 30 s) |
| `REVENGE_BONUS_SECONDS 20` | 60 + $500 |
| `OFFLINE_RATE 0.3`, `OFFLINE_CAP_HOURS 6`, `VIP_OFFLINE_RATE 0.6` | Kept; to the bank |
| `REBIRTH_BASE_COST 750,000`, `REBIRTH_COST_GROWTH 2.75`, `REBIRTH_INCOME_BONUS 0.5` | Kept (Prestige) |
| `REBIRTH_KEEP_CARS 2` | 3, plus vault and bound cars |
| `DAILY_REWARDS`, `PLAYTIME_REWARDS`, `Contracts` | Kept. Streak pauses; rewards to the bank; new stats added. |
| `GROUP_BONUS 0.1`, `FRIEND_BONUS_EACH 0.1` (max 3), `INDEX_RARITY_BONUS 0.05` | Kept (garageMult); plus set bonuses (§6.4) |
| `Rarity` weights, `hotwireTime`, `wantedOnSteal`, `wantedChance` | Kept |
| `Mutations` | Finishes with the same multipliers and weights, plus event finishes |
| `Events.HOT_DROP_INTERVAL {360,540}` | {600, 900} |
| `DealershipService.RESTOCK_INTERVAL 240` | 300 (pulse) |
| `Police.UNITS_PER_STAR`, `MAX_UNITS_GLOBAL 14`, `DECAY_DELAY` | Kept; × district factor; `DECAY_DELAY` becomes the evade timer (gta_combat) |
| `Police.Heat` | Extended (§3.11) |
| `Vehicle.MAX_HEALTH 100`, `NITRO_*`, watchdog constants | Kept. The watchdog uses `CarStats` effective top speed. |
| `Monetization` passes and products | §8 (Master Thief, Infinite Nitro and Zapper Pass retired; VIP split) |
