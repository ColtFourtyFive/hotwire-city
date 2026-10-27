# Reference teardown: GTA V / VI, realistic Roblox open-worlds, steal-hits, virality

*Written 2026-10-27 for Hotwire City v2. This file sits below `00_LEAD_DIRECTION.md`, which wins on any conflict. It reads the user vision in `original_brief.md` ("we are building GTA") as binding.*

**Evidence used**
- **Live Roblox API snapshot**, taken 2026-10-27 at about 14:50–16:00 UTC:
  - `games.roblox.com`: playing, visits, votes, max server size, game passes and descriptions;
  - `apis.roblox.com/explore-api`: the chart sorts;
  - `thumbnails.roblox.com`.
- **Twelve-month CCU peaks and revenue estimates** from rowatcher.com. Its "all-time peak" covers only its tracking window. Steal a Brainrot shows 9.0M (Feb 2026) there, against the Guinness 25.8M from Oct 2025. Its revenue figures are third-party estimates and **low confidence**.
- **GTA VI facts** come from the gta.wiki "Wanted Level in GTA VI" page and press coverage of Rockstar's 26-minute "Extended Look" (Engadget, Aug 28 2026).
- **GTA V and GTA Online facts** are long-established series knowledge. Where a fact could not be re-verified today, it is marked *(unverified)*.
- **Contact sheets**, made from official thumbnails and icons:
  - `img/thirdparty_ref_thumbs_a_2026-10-27.png` and `img/thirdparty_ref_thumbs_b_2026-10-27.png`: 24 games, first thumbnail each;
  - `img/thirdparty_ref_driving_thumbs_a_2026-10-27.png` and `img/thirdparty_ref_driving_thumbs_b_2026-10-27.png`: the realistic driving and cops games, three thumbnails each;
  - `img/thirdparty_ref_icons_2026-10-27.png`: 24 icons;
  - `img/thirdparty_ref_gtalikes_2025-26_2026-10-27.jpg`: San Diego RP, Riot City, BlockSpin, Wanted, ROB IT, Emergency Hamburg;
  - `img/hotwire_v1_marketing_strip.png`: v1's own marketing, for contrast.

  These are third-party images for internal reference only. Never ship or upload them.
- **GTA HUD and screen references** are already in `img_gta/`: radar, wanted states, weapon wheel, Wasted/Busted, phone and pause menu.
- **Raw stats table:** `data/reference_stats_2026-10-27.tsv`.

---

## 0. The five findings that should change what we build

1. **"Steal a Car" as a brainrot reskin has already been tried three times, and it tops out small.**

   | Game | Launched | Peak CCU (12-mo) | Playing now |
   |---|---|---|---|
   | *[🎃] Steal A Car* | Sep 4 2026 | 31K | 2.5K |
   | *Steal a Supercar* | 2025 | 495 | |
   | *Steal a Car* | May 2025 | | ~100 |

   *Steal An Egg*, on the same verb, peaked at **14.3M**. Putting the car noun on the steal-from-bases verb is not enough. The GTA sandbox and the realism the user chose are the differentiator, not a nice-to-have. The bare title "Steal a Car" is also taken.

2. **The realistic GTA-likes that grew in 2025–26 each have one legible hook inside a realistic city.**

   | Game | Peak CCU (12-mo) | Hook |
   |---|---|---|
   | San Diego Roleplay | 138K (Aug 2026), created Mar 2026 | Smuggle past the border checkpoint |
   | Emergency Hamburg | 76K (Oct 2026), 25K playing today | Rob the bank, jeweler and harbor containers vs. player cops |
   | Wanted | 40K, 96.8% likes | Bank robber vs. cops; crimes put a bounty on you |
   | BlockSpin | 42K | Jobs into unboxing cases; you drop everything on death |
   | Ghost Driver | 49K | Weave through heavy highway traffic |

   Realism plus a sharp verb works. Realism alone stays niche: Southwest Florida, the most realistic of them, peaked at **20K** and has **570** playing now.

3. **Vehicle-plus-police-chase games are the hot sub-trend this month.**

   | Game | Created | Playing now | Hook |
   |---|---|---|---|
   | Kukirin Life | Sep 19 2026 | 38K | E-scooters with "fun and responsive police chases" |
   | Bike Universe | Sep 27 2026 | 36K | Money from wheelies and tricks |
   | Backseat Rally | Oct 5 2026 | 28K | Co-driver calls the turns |
   | Ragdoll Reality | Oct 13 2026 | 29K (60K peak) | Ragdoll physics |

   Driving feel, chases and ragdoll are what players are clicking on right now.

4. **The money is in weapons and cosmetic economies, not in RP.**
   - Today's Top Earning chart reads: **RIVALS, Murder Mystery 2, Steal An Egg, Blox Fruits, Jujutsu Shenanigans**.
   - **Criminality**, the gritty open-world crime fighter, ranks **#18 in Top Earning with 2.8K CCU**. That is very high revenue per player.
   - The only car game near the top is Driving Empire, at an estimated $289K/month (low confidence). It earns from licensed supercars, limited cars and gifting.
   - The GTA layer we add (guns, weapon skins, cars as status) is exactly where Roblox spending concentrates.

5. **Every top-20 thumbnail is a rendered key-art image.**
   - **The realistic games** use one consistent formula: a photoreal hero car at a low three-quarter angle with motion blur, cop lights or golden hour, and a small corner logo.
   - **v1's marketing strip** shows a neon cartoon duck and kid fonts. It fails twice: it isn't GTA, and it doesn't match the first 3 minutes of play, which Roblox's qualified-play-through metric punishes.

---

## 1. GTA V / GTA VI: the concrete ingredients

### 1.1 World composition ("compressed reality")

GTA V compresses Los Angeles into its recognizable landmarks, about 75–80 km² of land *(unverified)*. Every district has its own silhouette, palette and soundscape, and the road network is designed for chases rather than for accuracy.

| District archetype | GTA V instance | Palette / material | Gameplay job | Hotwire v2 equivalent |
|---|---|---|---|---|
| Glass downtown | Pillbox Hill, Maze Bank Tower | cool blue glass, steel, clean concrete | Banks, heists, landmark visible from anywhere | Downtown towers; one signature tallest tower as the navigation landmark |
| Hills and the sign | Vinewood Hills, the VINEWOOD sign | warm golden stucco, green hills, mansions | Rich targets, status, view over the city | Hillside letter sign with our own name; mansion garages with hyper and secret cars |
| Beach strip | Vespucci, Del Perro Pier (Ferris wheel) | bleached pastel stucco, sand, palms | Crowds, flexing, races along the coast road | Boardwalk, pier with Ferris wheel, beach road |
| Hood / low-rise | Davis, Strawberry, Grove St | dusty yellow-brown stucco, chain-link, graffiti, liquor stores | Cheap cars, store robberies, gangs | Starter district: beaters, gas stations, chop shop |
| Port / industrial | Elysian Island, Cypress Flats | rust, containers, cranes, rail | Car exports, cargo, shootouts | Port with cranes and containers; the export dock for the order board |
| Airport | LSIA | flat concrete, hangars, planes landing | Endgame spawns, jets | Airport as the end gate, with planes on approach |
| Countryside / desert | Blaine County, Sandy Shores, Great Ocean Hwy | dry ochre, scrub, long straight roads | Top speed, escapes, contrast | Desert highway loop for speed |

**Composition rules to copy**
1. Landmarks visible from every district: the tower, the sign, the pier wheel and the cranes. Players navigate by silhouette, not by the minimap.
2. Rich and poor districts sit side by side. The contrast is the story: the hood looks up at the hills.
3. Freeways ring and cut through the city, with on-ramps that make natural chase loops and jumps.
4. Alleys, parking garages, tunnels and storm drains serve as line-of-sight breakers for losing cops.
5. Streets are never empty: parked cars at curbs, street furniture, signage and storefronts.

**GTA VI** (Leonida / Vice City, Florida) adds:
- Art-deco Ocean Drive in pastel and neon;
- the Keys bridges;
- swamps with airboats;
- beaches with **hundreds** of NPCs;
- humid, bloom-heavy sunsets in saturated pink, orange and teal.

The trailers are cut as **in-world vertical social-media clips**, a game world built to produce clips.

### 1.2 Color grading and lighting

GTA V's look comes from five things:
- **Warm key light:** golden hour is the default "money shot."
- **Atmospheric perspective:** distant hills go blue-gray, the city stays readable, and haze sits behind the subject rather than in front of it.
- **Saturated but not neon diffuse colors.**
- **Strong specular** on car paint and glass.
- **Night lighting:** orange sodium street lights, colored neon, and headlights and police lights that light the surroundings. Rain makes the streets reflective.

**Roblox starting values** for an LA golden hour. These are untested starting points for the Studio operator, not measured values:

| Setting | Value |
|---|---|
| `Lighting.Technology` | `Future` |
| `ClockTime` | ~17.0–17.5 |
| `GeographicLatitude` | ~34 |
| `Brightness` | ~3 |
| `EnvironmentDiffuseScale` / `EnvironmentSpecularScale` | 1 / 1 |
| `ShadowSoftness` | ~0.2 |
| `Atmosphere` | Density **≤0.30**, Offset ~0.1, Haze 1–1.8, Glare 0.3–0.6, warm Color, blue-gray Decay |
| `ColorCorrection` | Contrast +0.1, Saturation +0.1, faint warm Tint |
| `Bloom` | Threshold ~1.6, so only lights, sun and chrome bloom |
| `SunRays` | low |
| `Clouds` | on |
| `Sky` | HDRI-style sky |

v1's brown-haze screenshot comes from a density setting above this range.

### 1.3 Traffic and pedestrian density

- **GTA's "alive" feeling** comes from:
  - continuous lane traffic that stops at lights, with taxis, buses, trucks and emergency vehicles responding to scenes;
  - pedestrians running *scenarios*: phone calls, smoking, jogging, dog walking, chatting, street performers;
  - Euphoria ragdoll reactions when hit;
  - planes, helicopters and blimps overhead.
- **GTA V random events** (blue blips) create emergent mini-missions: a robbery in progress, a security van on its route.
- **Roblox targets** (recommendation, not a reference measurement):
  - 25–40 client-simulated AI cars within ~500 studs of each player;
  - 30–60 pedestrians within ~300 studs;
  - parked cars on every curb.

  All of it runs as client-side CFrame simulation on a lane graph, with no server physics, so it scales to mobile. Server-owned NPC cars should exist only when a player enters or steals one.

### 1.4 Camera

- **On foot:** a third-person shoulder camera offset to the right.
- **In vehicles:** a chase camera with near, mid and far settings, smoothing lag, auto-recenter after a moment of no input, look-behind, and a **cinematic camera button** that cuts to dramatic angles during chases.
- **First person** is optional.
- **For Roblox:**
  - a chase camera with a speed-scaled FOV kick of +5–8°;
  - short decaying shake on impacts;
  - a cinematic camera key;
  - a photo mode.

  The cinematic camera and photo mode are also the clip tooling (§4).

### 1.5 Driving feel

GTA V is arcade with weight:
- heavy body roll and pitch, with suspension bounce over curbs;
- generous grip with easy handbrake slides;
- burnouts at launch and visible tire smoke;
- skid marks and sparks on scrape;
- damage you can see: dents, bumpers and doors coming off, broken glass, engine smoke and then fire;
- distinct engine sounds per class;
- the radio keeps playing in the car;
- tire squeal and horn.

On Roblox, Greenville and Southwest Florida use deep custom chassis; Southwest Florida even has a manual clutch. **We should aim for the GTA arcade-weight middle, not sim.** Mobile players and chase gameplay need forgiving grip.

### 1.6 Police escalation

**GTA V** *(per-star detail from series knowledge)*

| Stars | Response |
|---|---|
| 1★ | Local patrols |
| 2★ | More units; they shoot if you are armed |
| 3★ | Helicopters (searchlight at night), roadblocks, ramming and PIT |
| 4★ | NOOSE (SWAT) vans and rappelling units |
| 5★ | Maximum units and aggression |

- **Evasion:** police vision cones show on the radar. Once you break line of sight the stars flash, and you must stay unseen until they clear.
- **GTA Online** adds two paid ways to clear stars: Lester's "remove wanted level" phone service, and CEO "bribe authorities". Both are cash sinks for losing stars.

**GTA VI** (gta.wiki, from the Extended Look) is the more modern model and maps well onto car theft:
- **Six stars.** A crime counts only if an NPC witnesses it or an alarm fires.
- **Star states:**

  | State | Meaning |
  |---|---|
  | Hollow | Crime reported, no description; you can pass cops |
  | Solid gray | Police have a description but haven't arrived |
  | Solid white | Pursuit with line of sight |
  | Flashing | Line of sight lost |
  | Red | Lost you but still inside the search radius |

  The search radius shows as dark and light red circles on the minimap, and it stays on the original scene until things cool down.
- **Heat indicators** sit under the stars. Each one has its own way to clear it:

  | Indicator | How to clear it |
  |---|---|
  | **CCTV** | Destroy the footage |
  | **Appearance** | Change hairstyle; a mask prevents it |
  | **Outfit** | Change clothes |
  | **Weapon** | Ditch the gun |
  | **Vehicle** | **Respray, destroy or swap the car** |
  | **Couple** | Split up from your partner |

- **Criminal Profile:** crimes are judged by context. Carjacking also gets a "Slim Jim" stick-timed break-in, and electronically locked cars need key cloners.

**For us:**
- Vehicle heat cleared by a paint shop is literally our loop.
- A mask item prevents the appearance heat.
- An outfit change in the garage clears the outfit heat.
- The timed break-in meter is the hotwire minigame.
- Key-cloner gadgets gate the high-end cars.
- We keep five stars, because the lead direction says 1–5.

### 1.7 HUD and presentation (references in `img_gta/`)

- **Layout:**
  - the minimap sits bottom-left, with health (green) and armor (blue) bars under it;
  - wanted stars, cash and weapon/ammo are top-right;
  - help text sits in a small black box top-left;
  - notifications stack above the minimap;
  - mission objective subtitles run bottom-center, with **nouns colored to match their map blips** (yellow destination, blue target or vehicle, red enemy).
- **Wheels:** holding the weapon wheel slows time and offers 8 slots. The radio wheel works the same way.
- **Full-screen moments** in a heavy Pricedown-style font: **WASTED** (slow-motion, desaturated) and **BUSTED** (respawn at the hospital or police station with a fee), and **MISSION PASSED** with a reward and medal stats.
- **GTA VI** cleans this up further: a contextual minimap that appears when driving or wanted, a 3D-building map, and quick-swap between two guns.

### 1.8 Mission structure

- **Single player:** a contact blip or phone call, then a **drive-and-talk** leg (about 1–2 min), an **action set piece**, an **escape** ("lose the cops"), and a drop-off. Missions have checkpoints and medal objectives that invite replays.
- **Heists:** setup, then a planning board where you **choose the approach** (loud or smart) and **pick a crew**, each member with a skill and a % cut. Then prep missions, the finale, and the split.
- **GTA Online contact missions** run about 5–10 minutes.
- **For Roblox:**
  - 2–5 minute phone contracts with one verb each;
  - a server heist on a clock, compressed to prep, job and getaway with roles: driver, hacker, gunner.

### 1.9 Money loops (GTA Online, closest analogs to our steal-cars spine)

| GTA Online system | How it works | Hotwire v2 analog |
|---|---|---|
| **Import/Export** | Steal a listed high-end car, deliver it undamaged to your warehouse, sell it later. Damage cuts the payout, cops chase, and players can intercept the sale | **The core loop**: steal, escape, garage, sell. Damage reduces the value of the delivery |
| **Exotic Exports** (LS Tuners) | A daily list of 10 cars hidden around the map, delivered to the docks, with a bonus for the full set | The 5-minute **order board** with a full-set bonus |
| **Salvage Yard / Chop Shop** (Dec 2023) | Weekly vehicle-robbery jobs, plus a tow-truck service that boosts passive income | A chop shop for instant cash; tow jobs as a low-risk starter job |
| Business Battles / Freemode events | Server-wide announced crate drops; organizations race to capture them | Hot Drops, armored truck, rare-car spawns |
| Properties and businesses | Passive income that must be resupplied; status display | Garage income, multi-district safehouses |
| Bounties / Mugger / Lester | Pay to hurt others or clear stars | Server bounty at 5★; pay a contact to drop stars (a cash sink) |
| Weekly event rotation (Thursdays) | 2×/3× cash on chosen modes, a podium car, a "Prize Ride" challenge, time-limited cars | Weekly 2× activity, numbered limited cars, Saturday Admin Abuse |
| Shark Cards / GTA+ | Cash packs and a subscription | Robux cash packs (honest), VIP, season pass |

### 1.10 Online social loops

- **Crews:** emblem, colors and rank.
- **Organizations and MCs:** a boss plus associates, with business ownership.
- **LS Car Meet:** a social space where players show off cars and earn rep that unlocks parts. It is an on-ramp to the test track.
- **Heists as the friend activity.**
- **Passive mode, and "bad sport" lobbies for griefers.**

**What transfers:**
- crews of 2–4 with a shared cut and crew colors and plates;
- a car-meet spot where players like each other's cars;
- protections against griefing (passive inside garages, a bounty on griefers).

### 1.11 What a Roblox version must reproduce first

These are the cues a viewer uses to say "that looks like GTA", in priority order:

1. A wide, palm-lined multi-lane road with lane markings, curbs, traffic and parked cars.
2. Warm sun and haze with a readable skyline and the hillside sign.
3. A realistic car mid-action: drift smoke, sparks, motion.
4. Red and blue police lights chasing it.
5. Minimap bottom-left and stars top-right.
6. Ragdolling pedestrians.
7. WASTED, BUSTED and MISSION PASSED in the heavy font.
8. Radio and police scanner audio.

v1 currently has none of these cues (`evidence/v1_real_engine/downtown_street.jpg`, `driving.jpg`).

---

## 2. Realistic Roblox open-worlds and 2025–26 GTA-likes

### 2.1 Numbers (snapshot 2026-10-27)

| Game (dev) | Created | Playing now | 12-mo peak (rowatcher) | Visits | Like % | Server size | Est. revenue/mo* |
|---|---|---|---|---|---|---|---|
| Jailbreak (Badimo) | 2017 | 5,452 | 173K (Jun 2026, platform event) | 8.08B | 87.7 | 30 | n/a |
| Southwest Florida (Strigid) | 2020 | 570 | 20K (Dec 2024) | 0.78B | 90.1 | 50 | $24K |
| Greenville | 2017 | 7,384 | 75K (Jul 2026) | 1.48B | 87.9 | 30 | $34K |
| ER:LC (Police Roleplay Community) | 2018 | 4,042 | 45K (Sep 2026) | 1.61B | 90.8 | 50 | $56K |
| Driving Empire (Voldex) | 2019 | 23,881 | 90K (Aug 2026) | 3.39B | 93.0 | 22 | **$289K** |
| Car Dealership Tycoon (Foxzie) | 2018 | 4,558 | 36K (Dec 2024) | 2.54B | 92.9 | 15 | $87K |
| Mad City Ch.2 (Schwifty) | 2017 | 190 | 815 | 2.61B | 83.5 | 32 | n/a |
| Emergency Hamburg | 2021 | 24,677 | **76K (Oct 2026)** | 1.47B | 85.9 | 50 | $10K (suspect) |
| **San Diego Roleplay** | **Mar 2026** | 10,680 | **138K (Aug 2026)** | 0.23B | 85.5 | 50 | n/a |
| **Wanted** (DevvGames) | 2023 | 9,088 | 40K (Sep 2026) | 0.14B | **96.8** | 30 | n/a |
| **BlockSpin** (Cinnamon Go!) | Nov 2024 | 17,323 | 42K (May 2026) | 1.32B | 78.7 | 28 | $113K |
| **Riot City** | Dec 2025 | 4,723 | 16K (Sep 2026) | 0.10B | **97.7** | 24 | $30K |
| **ROB IT** (stealth heists) | Dec 2025 | 3,391 | 31K (Jan 2026) | 0.31B | 95.8 | 20 | n/a |
| Da Hood | 2019 | 2,050 | 26K (Sep 2026) | 2.96B | 70.5 | 45 | $13K |
| Criminality | 2020 | 2,808 | n/a | 0.37B | 75.2 | 30 | **#18 Top Earning** |
| **Ghost Driver** (highway traffic) | May 2026 | 9,770 | 49K (Aug 2026) | 0.12B | 97.4 | 15 | n/a |
| Midnight Chasers | 2023 | 3,129 | 17K | 0.32B | 97.5 | 14 | n/a |
| **[🎃] Steal A Car** (brainrot format) | **Sep 2026** | 2,511 | 31K (Oct 2026) | 0.02B | 89.9 | **5** | n/a |
| *Context: Steal An Egg* | Jul 2026 | 1,302,573 | 14.3M (Sep 2026) | 9.63B | 91.6 | 7 | n/a |
| *Context: Steal a Brainrot* | May 2025 | 192,984 | 25.8M (Oct 2025, Guinness) | 74.19B | 85.1 | 8 | $1.43M |

*\*Revenue figures are rowatcher estimates and low confidence. They are useful only for ranking games against each other.*

### 2.2 Game-by-game: what they do well and what we take

**Southwest Florida (Strigid)**
- **Look:**
  - the most photoreal look on Roblox: real Bonita Springs road layout, Future lighting, dense palms and vegetation;
  - real-proportioned cars with glass and chrome;
  - thumbnails are photoreal motion-blur shots.
- **Driving:** a manual-transmission option with clutch (E/Q shifting) and bike wheelies.
- **Loop:** jobs (police, fire, Drivers' Club), races, properties.
- **Monetization:** a micro-pass ladder of Car Reflectance 19, Car Radio+ 19, Custom License Plate 49, Car Colors+ 49, Custom Races 99, Shotgun 149, Garage Limit 199, Assault Rifles Pack 249, 2× Job Earnings 399.
- **Weakness:**
  - its own page warns that low-end PCs and phones struggle;
  - it is "Beta" after 6 years;
  - 570 CCU.
- **Take:**
  - the visual bar (palms, roads, car materials);
  - cheap cosmetic micro-passes (custom plates, reflectance);
  - **don't copy its performance cost or its sim-only depth.**

**Greenville**
- **Look:** a realistic small American town (Wisconsin) with "hundreds of cars", **licensed cars with real-life options**, drift-smoke thumbnails, and parts, wheels and plates customization.
- **Loop:** houses, jobs, limited seasonal cars (4 "spooky" limiteds this week).
- **Monetization:** sells **vehicle-class access**: Sports 500, Luxury 250, Zero-Emission 125, Classic 75, Public Services 75, Storage 150.
- **Take:** limited seasonal cars as a weekly hook; cosmetic customization depth on each car. Licensing is impossible for us; we use parody brands.

**ER:LC (Police Roleplay Community)**
- **Look:**
  - stylized-realistic cars on default blocky avatars;
  - a city, a countryside and a town;
  - 50-player servers;
  - the experience is built around private-server RP communities on Discord.
- **Monetization:** sells **roles and gear**: SWAT 750, Police K-9 400, FD Special Ops 400, Premium Jobs 400, Detective 300, "Unlawful Upgrades" 250, Big Guns 185, Instant Refuel 75.
- **Take:**
  - role passes as the monetization pattern for the cops layer later;
  - cheap private servers so communities form;
  - K-9 and SWAT as aspirational police fantasy.

**Jailbreak (Badimo)**
- **Look:** not realistic (stylized low-poly), but it is the systems benchmark.
- **Loop:** prison escape, then robberies (stores, bank, jewelry, museum, train, cargo plane, casino) that **open and close on timers announced to the server**. Cops vs. robbers, vehicle upgrades (engine, brakes, spoilers, rims), seasons, and a big trading economy with rare "hyperchrome" paint grinds.
- **Monetization:** VIP 750, Pro Garage 450, Crime Boss 400, SWAT 400, Duffel Bag 345 (carry more loot), Car Stereo 200, plus Robux cash and cars.
- **Its peak of 173K in Jun 2026 came from a Roblox platform event.**
- **Take:**
  - robbery timers as a shared clock;
  - Duffel-Bag-style "carry more loot" passes;
  - rare paint grinds as collectibles;
  - trading.
- **Warning:** its description says *"We're now focused on cheating before rolling out any remaining updates"*. Exploit pressure on crime games is existential.

**Mad City Ch.2**
- Heists plus heroes and villains. It went from millions of visits to **190 CCU**. Losing its identity and its update cadence killed it.
- **Take:** stay on one fantasy (car-theft GTA) and keep a weekly cadence.

**Driving Empire (Voldex)**
- **Look:** photoreal supercar renders, with **licensed** Lamborghini, McLaren, Porsche and Audi.
- **Scale:** 300+ cars and boats.
- **Loop:** races, car meets, bodykits, and **limited vehicles with gifting**, launched 2026-10-23.
- **Monetization:** Track Pass 450, VIP 500, Luxury 399, Delivery Pass 399, Car Radio 15, Premium Boost 125.
- **Take:**
  - **limited numbered cars plus gifting** is the top revenue engine in the car genre;
  - car meets as a social flex;
  - the "2 NEW LIMITED" tag in the title.

**Car Dealership Tycoon (Foxzie)**
- **Loop:** build a dealership (tycoon) plus open-world driving, with 600+ cars and colors, gloss and tire smokes. **Event currency** (pumpkins) unlocks limited cars, plus codes.
- **Monetization:** VIP 500, 3× Vehicles 299, Special Colors 80.
- **Thumbnails:** a stylized hero car on a purple radial background with drift smoke.
- **Take:** an event currency that unlocks limited cars; cosmetic tire smoke, underglow and rims as cheap collectibles.

**Emergency Hamburg**
- **The strongest realistic cops-and-robbers game right now:** 76K peak in Oct 2026, 25K playing today.
- **Loop:**
  - criminals rob the **bank, jeweler and harbor containers**;
  - police unlock Traffic Police, Undercover and SEK;
  - jobs: medic, mechanic (repairs traffic lights), truck, bus.
- **Monetization:** Special Ops Command 799, Crime Boss 399, Undercover 349, Motorcycles 399, Advanced Tuning 399, Classic Cars 249.
- **Thumbnails:** rendered key art of a masked robber with police at night, plus a consistent EH corner logo.
- **Take:**
  - heist targets as physical places in the city;
  - jobs that keep the world alive;
  - "Crime Boss" status pass.

**San Diego Roleplay (Mar 2026, 138K peak)**
- **The 2026 breakout realistic RP.**
- **Its rule:** spawn your vehicle, approach the **border checkpoint**, and smuggle or inspect ("pack something you shouldn't and hope they don't look too close").
- **Monetization:** sells **factions and weapons**: El Capo 639, US Army 919, RPG 999, Electric Vehicles 999, SWAT 599, Luxury Cars 599, FBI 399, Heavy Weapons 375, K9 199, **Starter Pack 69**, Portable Garage 99.
- **Take:**
  - **one legible social-tension rule inside a realistic city** beats a generic sandbox;
  - our version: *steal a car, get past the cops, get it into your garage*;
  - a cheap starter pack at 69.

**Wanted (DevvGames, Oasis City)**
- **96.8% likes.**
- **Loop:** bank robber vs. cops, missions, base upgrades, "crimes increase your wanted level and put a bounty on your head". Recent content added an evidence-room heist and an armored truck.
- **Thumbnails:** rendered police chase on a bridge, with a **five-star logo**.
- **Take:** the closest systems comp. Bounty-on-wanted is proven, and stars in the logo are an instant GTA signal.

**BlockSpin (Florida county gangster sim)**
- **Loop:** jobs give **unbox cases** (gacha), plus finishers, fishing and store robberies. **You drop your whole inventory on death**; items go in your house safe to keep them.
- **Results:** 42K peak and $113K/month estimated, but only **78.7% likes**.
- **Take:**
  - high stakes drive engagement, and full loss drives dislikes;
  - this backs our plan for insurance and a recovery window instead of total loss.

**Riot City (Dec 2025)**
- **97.7% likes.**
- **Loop:** a modern Jailbreak: escape prison, rob the bank, collect 20+ cars and 15+ guns, cop side. **Weekly limited cars** ("NEW LIMITED Demonio 13").
- **Monetization:** Mafia Boss 400, SWAT 400, VIP 350, Premium Weapons 300, Larger Duffle Bag 300, Portable Garage 80.
- **Take:** the cars-plus-guns collection ladder, and a portable-garage pass, which is cheap and liked.

**ROB IT (Dec 2025)**
- Pick a mission, break in, steal everything, avoid the guard's sight cone. 31K peak.
- **Take:** stealth "loud vs. quiet" heist variants.

**Ghost Driver and Midnight Chasers**
- Weaving through dense highway traffic. Realistic cars with plates, 97%+ likes.
- **Monetization:** cosmetic passes (Stage 4 Tuning 399, Underglow 199, Custom Plates 149, RGB 99, Police Sirens 99) with **(GIFT) versions of each**.
- **Take:**
  - our freeway with dense traffic and near-miss cash is a free sub-game;
  - giftable passes.

**Da Hood and Criminality**
- **Da Hood:** harsh open PvP, a 10-day account-age gate, 30% cash drop on death. 70.5% likes, decaying.
- **Criminality:** gritty, punishing. 75% likes, but #18 Top Earning.
- **Take:** hardcore PvP monetizes per head but gets disliked and stays small. Use **opt-in risk** ("the street is a casino") instead.

**Nightshift (unreleased)**
- A 59-second X teaser posted Oct 14 2026 showed a realistic car, tire smoke and city drifting. It was press-covered as "a Roblox game that looks like GTA VI / NFS Underground 2". The developer says mobile optimization is its first priority.
- **Take:** the "this is Roblox??" reveal is newsworthy right now, and competitors are aiming at it before Nov 19.

### 2.3 Cross-game patterns

- **Visual techniques that read as "realistic Roblox":**
  - Future lighting and PBR (`SurfaceAppearance`) car paint with low roughness;
  - real glass;
  - separate wheel meshes;
  - dense palms and vegetation meshes;
  - road meshes with painted lines and curbs;
  - license plates on every car;
  - night scenes lit by headlights and police lights.

  Avatars stay standard Roblox, so realism lives in the **world and the cars, not the characters**. For NPCs we use realistic catalog outfits (lead direction).
- **Car model quality is the product** in Driving Empire, Greenville, Southwest Florida and Ghost Driver: real proportions, panel gaps, lights, interiors visible through the glass, wheels that turn and steer.
- **UI:**
  - realistic games use restrained dark translucent panels, condensed fonts and a speedometer bottom-right;
  - Jailbreak's busy icon-column UI is the old style;
  - GTA's HUD is the target.
- **Server sizes:**
  - realistic RP runs 30–50 players;
  - steal-hits run 5–8, for high contact density;
  - car-sim runs 14–22.
  - **Recommendation:** about 20–24 players with events that funnel them together.
- **Monetization patterns that recur:**
  - role and faction passes (SWAT, Crime Boss, Mafia Boss, El Capo);
  - vehicle-class access;
  - "carry more loot" (Duffel Bag);
  - portable garage;
  - custom plates and underglow micro-passes;
  - giftable passes;
  - limited numbered cars;
  - a starter pack at 69 R$.

  None of these are pay-to-win in the "pay for damage" sense.

---

## 3. 2025–26 steal-and-collect hits: what transfers to "steal cars + GTA sandbox"

| Hook (source) | Mechanic | Transfers? | Our version |
|---|---|---|---|
| Visible, stealable base (Steal a Brainrot) | Your collection sits on display with $/s labels; anyone can walk in | **Yes, the core** | Garage showroom with income tags above each car; glass-front display that shows off your best cars to passers-by |
| Carrier slowed and owner alerted; one hit returns the item (Steal a Brainrot) | Theft is a chase the owner can win | **Yes** | A stolen car broadcasts a tracker blip to its owner for 60–90 s. Disable it (PIT, spike strip, shoot the tires) and it is **recovered** |
| Base lock timer plus a paid lock (Steal a Brainrot) | Loss aversion at the moment of risk | **Yes** | Garage door lock; the lock extends when you're being raided (honest pricing) |
| Rarity tiers plus stacked mutations (Brainrot, Egg, Garden weather) | "1 in X", multipliers up to 10–120× | **Yes** | Rarity × paint finish (Matte, Metallic, Chrome, Gold, Chameleon…) × level × upgrades; "1 in X" reveal on hotwire |
| Server-wide restock or conveyor every 5 min (Garden, Brainrot) | The shared clock | **Yes** | Rare-car traffic and a dealership restock every 5 min; armored truck; Hot Drops |
| Rare spawn announced to the server (all) | Stampede clip | **Yes, the signature clip** | "A 1-in-5,000 Gold Hypercar just spawned at the Airport" |
| Rebirth needing specific rares (Steal a Brainrot) | Forces stealing at the top end | **Yes** | Prestige needs specific Secret-tier cars |
| Pity timers (Legendary every ~5 min) (Steal a Brainrot) | Guaranteed dopamine | **Yes** | Guaranteed Epic+ spawn on a timer per district |
| Admin Abuse before updates (Grow a Garden) | Event-day record peaks | **Yes** | Saturday "City Chaos" (Hypercar Rain, Police Strike, 10× Gold-paint luck) |
| Speed stat on a treadmill (Steal An Egg, Steal A Car) | One gating number | **No** | Steal A Car copied it and peaked at 31K. In a GTA game the car *is* the speed stat |
| Meme or brainrot nouns | Novelty | **No** (kill list) | Realistic parody-brand cars; at most a couple of hidden easter eggs |
| Idle-only $/s | Passive play | **Partly** | Garage income is the bank; the street pays 3–10× (pillar 1) |
| 5–8-player servers | High contact rate | **Adapt** | 20–24 players, with events and districts funneling contact |
| Ritual and co-op summons (Brainrot meteor) | Social cooperation | **Yes** | 3-player heist start; crew-only vault doors |
| Pickaxe tier ladder (Break and Steal an Egg, 97.4% likes) | One new verb plus HP | **Yes** | Hotwire tools ladder: Slim Jim, key cloner, EMP; locked high-end cars need better tools (GTA VI's key cloners) |

**Risk:** Grow a Garden 2 added guilds, combat and raids, and fell from about 976K to 21K. **The first minute must be steal, escape, garage; nothing more.** Guns, crews and heists unlock across the first session.

---

## 4. What makes thumbnails, icons and TikToks of these games go viral

### 4.1 Thumbnails (from 60+ official thumbnails in the contact sheets)

1. **Rendered key art, not raw screenshots.**
   - Nearly every top game uses a lit 3D render with rim light, depth of field and motion blur.
   - The exception, Jailbreak slots 2–3, uses real screenshots with the UI visible as "proof of game".
   - Use one proof-of-game screenshot among 3–5 key arts.
2. **The realistic-driving formula:**
   - a photoreal hero car at a low three-quarter front angle, front wheels turned;
   - a motion-blurred background;
   - golden hour or night with the headlights on;
   - a small consistent corner logo (Southwest Florida "FL" bottom-left, Greenville top-right, EH bottom-right).
3. **The GTA-like formula** (Wanted, Riot City, San Diego RP, BlockSpin, EH):
   - a masked or expressive avatar;
   - money bags or flying cash;
   - **red/blue cop lights**;
   - a supercar;
   - a bank or gun-store sign with palms;
   - Wanted puts **5 stars under its logo**.
4. **The collector formula** (Brainrot, Egg, Garden): a giant **$ number**, a hero item, and an avatar with a shocked or grinning face.
5. **Icons:**
   - one subject, centered, readable at 150 px, on a saturated background;
   - heavy italic wordmark;
   - **seasonal tag swapped per event** (pumpkins, bats).
6. **Titles carry event tags** in almost every top game today: `[🎃]`, `[✨2 NEW LIMITED✨]`, `[UPD]`.
7. **Expectation match matters more than click-through rate.**
   - Roblox's thumbnail personalization optimizes **qualified play-through**. It averages **+8.5%**, up to +50%, and needs 2 or more active thumbnails.
   - rowatcher's analysis: a 12% CTR with early drop-off ranks below an 8% CTR with deep sessions, and sub-60-second exits above 15% signal a mismatch.
   - So **the spawn view must be as good as the thumbnail.** v1's AI cartoon strip fails this.

### 4.2 Short-form video (TikTok, Shorts, Reels)

- **Formats that fit us:**
  - "This is ROBLOX??" realism reveals (Nightshift's teaser drew press on Oct 20; fan GTA VI maps on Roblox went viral);
  - **GTA VI vs. Roblox side-by-side** in the Nov 19 launch window;
  - 5-star chase escapes;
  - "I stole the rarest car in the server";
  - the 1-in-X spawn stampede;
  - ragdoll and troll fails;
  - heist betrayal;
  - Day 1 vs. Day 30 garage;
  - first-person POV drives (Drive World and Backseat Rally use cockpit POV thumbnails).
- **Earlier research benchmark:** plain gameplay averages 42K views, while glitch, secret and POV formats reach 480–890K.
- **Tools the game must provide** so players produce these:
  - a cinematic camera;
  - photo mode with depth of field;
  - a hide-HUD toggle;
  - 9:16-friendly framing presets;
  - custom license plates (meme fuel);
  - server announcements;
  - the WASTED and BUSTED screens, which are recognizable within one second.

---

## 5. Thirty highest-impact upgrades for Hotwire City v2 (ranked)

*Impact covers three things: first-5-minutes wow, retention, and virality. 1 is highest.*

| # | Upgrade | Rationale |
|---|---|---|
| 1 | **Golden-hour lighting stack**: Future, warm sun, Atmosphere density ≤0.3, ColorCorrection, Bloom, SunRays, HDRI sky, plus a night preset | Every screenshot, thumbnail and first impression depends on it, and it fixes v1's flat pink and brown haze at near-zero asset cost |
| 2 | **Spawn on the "money shot"**: a palm-lined 6-lane boulevard with the skyline, the hillside sign and live traffic in the first frame | First-60-second bounce is a top ranking signal, and the thumbnail must match the spawn |
| 3 | **PBR street kit**: asphalt with lane markings, crosswalks, curbs, sidewalks, street lights, signals, signage and street furniture | Roads and sidewalks fill most of every street-level frame and are the #1 GTA cue; v1 has flat-colored slabs |
| 4 | **Hero car roster**: 12–15 parody-brand cars with real proportions, PBR paint, glass, chrome, working lights, separate steering wheels and plates | Car quality is the product in Driving Empire, Greenville and Southwest Florida; meme cars are on the kill list |
| 5 | **Living traffic and parked cars**: a lane graph, lights, 25–40 client-simulated cars near each player, curbs full of parked cars | GTA density is "alive" and v1 streets are empty; parked cars are also the steal targets |
| 6 | **GTA HUD replacement**: minimap bottom-left with health and armor bars, stars, cash and weapon top-right, help text top-left, condensed fonts, color-coded objective nouns | Instantly reads as GTA in any clip, and removes the kid-simulator UI the user rejected |
| 7 | **10-second core verb**: carjack or hotwire with a timing meter (GTA VI Slim Jim), pull the NPC out of the driver's seat, 1★ and sirens, a guaranteed first escape into the garage within 60 s | The one-action hook in a GTA skin; the 60-second bounce decides ranking |
| 8 | **Police 1–5★ with GTA VI-style star states**: hollow, gray, white, flashing, red search radius on the minimap; ramming, PIT, roadblocks, spikes, helicopter with searchlight, SWAT | The chase is the game's best clip and best loop; star states make evasion readable |
| 9 | **Driving feel**: weight transfer, body roll, handbrake drift, tire smoke, skid marks, sparks, visible damage and engine smoke, chase cam with speed FOV and impact shake | Kukirin Life, Bike Universe and Ghost Driver show that driving feel alone pulls 36–49K CCU |
| 10 | **Mobile performance budget**: StreamingEnabled, persistent landmark models, LOD skyline, client-side traffic and peds, tri and texture budgets per car | Southwest Florida's own page warns of phone lag, and Nightshift puts mobile first; realistic games lose their biggest audience without this |
| 11 | **Pedestrians**: realistic catalog outfits, scenarios (phone, smoke, jog), flee, hands-up and cower reactions, ragdoll on impact with no gore | "Alive city" plus troll clips; ragdoll games are trending (Ragdoll Reality 60K) |
| 12 | **WASTED / BUSTED / MISSION PASSED**: slow-motion desaturation, heavy display font, hospital or police-station respawn with a fee, partial carried-cash loss | The most recognizable 1-second GTA meme, made for clips, and it gives death meaning without gore |
| 13 | **District contrast and landmarks**: glass downtown, hood, beach and pier, port cranes, hills with the sign and mansions, desert loop, all visible from anywhere | Navigation by silhouette, and progression gates that read visually |
| 14 | **Server clock events**: armored truck every ~5 min, rare-car "1 in X" announcements every 10–15 min, Business-Battle-style Hot Drops | Shared clocks produced every record peak, and the stampede is the signature clip |
| 15 | **Garage showroom**: income tags over cars, door-lock timer, "someone is breaking in" alert, passers-by can look and like | Brainrot's loss-aversion and envy engine in a realistic skin |
| 16 | **Per-car value stack and paint finishes**: rarity × finish × level × upgrades, with a 1-in-X reveal on hotwire | The collectible depth the steal-hits monetize, and the user asked for per-car levels |
| 17 | **Order board ("Exotic Exports")**: a list that refreshes every 5 min, with a full-set bonus and damage that lowers payout | Gives minutes 2–5 a directed goal; proven in GTA Online's Import/Export and Exotic Exports |
| 18 | **Guns ladder, weapon wheel and store robberies**: pistol to SMG to shotgun to rifle, a clerk with hands up and a register, cosmetic weapon skins | The user's explicit ask, and weapon economies dominate Top Earning (RIVALS, MM2, Criminality #18) |
| 19 | **Phone**: contacts call with 2–5 min contracts, GPS waypoint, camera and selfie, request your car, pay a contact to drop stars | GTA's mission delivery and a cash sink, without giant tutorial cards |
| 20 | **Night**: wet-street reflections, sodium and neon lights, headlights and police lights lighting the scene | The second "money shot" and half of every chase clip |
| 21 | **Audio**: layered engine RPM, tire squeal, Doppler sirens, police scanner callouts, city ambience, 3–5 radio stations | Audio sells realism cheaply, and its absence makes even good visuals feel like a toy |
| 22 | **Crews of 2–4**: shared cut, crew colors and plates, invites by link (works without text chat) | Intentional co-play days are a ranking signal, and "party up with friends" is the user's ask |
| 23 | **Bank heist every 30 min**: prep, job, getaway, with driver, hacker and gunner roles and a physical loot bag | GTA's biggest set piece, a weekly content vehicle, and strong crew retention |
| 24 | **Fair-play protections**: 10-minute new-player shield, passive inside garages, insurance and a recovery window, a bounty on griefers at 5★ | Da Hood and BlockSpin show that harsh loss means 70–79% likes; the lead direction rules out total loss |
| 25 | **Freeway traffic-weaving**: near-miss and speed-camera cash, a highway loop to the desert | Ghost Driver and Midnight Chasers (97% likes) prove the sub-game; it costs only traffic plus scoring |
| 26 | **Clip tooling**: cinematic camera, photo mode with depth of field, hide HUD, 9:16 framing, custom license plates | Players make the TikToks; plain gameplay gets 42K views while moments get 10–20× that |
| 27 | **Thumbnail and icon pipeline**: 3–5 rendered key arts (realistic car, cop lights, masked avatar, "1 in X") plus one proof-of-game shot; icon with a star wordmark; personalization test | +8.5% average qualified play-through; it replaces v1's off-brand AI cartoon strip |
| 28 | **Title and launch timing**: "Hotwire City" plus a rule subtitle and event tags (e.g. `[🚨 HEIST WEEK]`; never "GTA" or Rockstar names), shipped before Nov 19 | The title should state the rule, and GTA VI launch week is the only time-boxed tailwind (an $80 M-rated game most Roblox players can't play) |
| 29 | **Weekly cadence**: Saturday "City Chaos" admin event, limited **numbered** cars, a 2× activity of the week, an event currency | Driving Empire, Riot City, Greenville and Car Dealership Tycoon all run on limited cars, and GTA Online runs on weekly rotations |
| 30 | **Honest monetization at moments of desire**: lock extension while being raided, insurance, VIP, Crime Boss and SWAT role passes, Duffel Bag, Portable Garage, custom plates, giftable cosmetics, starter pack at about 69 R$ 3–10 min into the first session, no paid power | Mirrors what earns in this genre (passes in the 69–999 range, gifting, limited cars) while staying policy-safe and not pay-to-win |

---

## Sources

**Live data**
- Roblox APIs, queried 2026-10-27:
  - `games.roblox.com/v1/games`, `/votes`, `/favorites/count`, `/game-passes`;
  - `apis.roblox.com/explore-api/v1/get-sorts` (Top Earning, Top Playing, Trending, Up-and-Coming);
  - `apis.roblox.com/search-api/omni-search`;
  - `thumbnails.roblox.com`.
- rowatcher game pages: `https://rowatcher.com/games/{universeId}` (12-month peaks and revenue estimates).

**GTA VI**
- [gta.wiki: Wanted Level in GTA VI](https://gta.wiki/w/Wanted_Level_in_Grand_Theft_Auto_VI)
- [Engadget: 20+ things you may have missed in the GTA 6 extended look](https://engadget.com/2246846/things-you-may-have-missed-gta-6-extended-look/)
- [TechRadar: 16 new GTA 6 details from the Extended Look](https://techradar.com/gaming/ps5/16-new-gta-6-details-we-learned-from-the-big-extended-look-gameplay-video-captured-in-game-on-a-ps5)
- [allthings.how: GTA 6 Extended Look mechanics](https://allthings.how/gta-6-extended-look-every-new-gameplay-mechanic-confirmed/)

**GTA on Roblox**
- [The Star / AFP: Roblox poised to cash in on GTA copycats (Sep 30 2026)](https://www.thestar.com.my/tech/tech-news/2026/09/30/roblox-is-poised-to-cash-in-on-grand-theft-auto-copycats)
- [iXBT: Nightshift Roblox teaser compared to GTA VI (Oct 20 2026)](https://ixbt.games/en/news/2026/10/20/v-razrabotke-novyi-analog-gta-vi-igroki-ne-mogut-poverit-cto-im-pokazyvaiut-kadry-geimpleia-iz-igry-na-baze-roblox.html)
- [Sportskeeda: GTA VI map concept built in Roblox](https://www.sportskeeda.com/gta/gtavi-roblox-gtavi-pc-gta-6-map-concept-built-roblox-mesmerizes-fans)

**Thumbnails**
- [Roblox docs: Thumbnails and personalization](https://create.roblox.com/docs/production/publishing/thumbnails)
- [DevForum: Thumbnail personalization remembers winners](https://devforum.roblox.com/t/thumbnail-personalization-now-remembers-your-existing-winning-thumbnails/3793665)
- [rowatcher: Thumbnail A/B testing, what the data shows](https://rowatcher.com/news/roblox-thumbnail-a-b-testing-what-the-data-actually-shows)

**GTA Online**
- [GTABase: Salvage Yards (Chop Shop DLC)](https://www.gtabase.com/gta-online/property-types/salvage-yards)
- [Gfinity: GTA Online Chop Shop patch notes](https://www.gfinityesports.com/article/gta-online-chop-shop-patch-notes)

**Wanted (Roblox)**
- [Rotrends: Wanted](https://rotrends.com/game/4987856151)
