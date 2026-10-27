# Original Brief: what the user asked for in "Viral Roblox game research"

*Distilled 2026-10-27 from the full transcript of Claude Code session `session_01QbnFLTotVTF3iTpj62qZ18` ("Viral Roblox game research", 2026-10-26, 20:29–21:33 UTC). That session researched viral Roblox games and produced the concept that became Hotwire City. It wrote three documents to its own repo (`/home/user/roblox`, branch `claude/compassionate-ramanujan-7ocah9`). Those are not in this repo, so the important content is reproduced here:*
- `research/01-market-research-oct-2026.md`
- `research/02-viral-dna-deep-dive.md`
- `design/01-game-concept.md` (23 sections)

> **Reading notes**
> - The user's words are quoted **verbatim, typos included**. Interpretations are in [brackets].
> - Several user messages paste back text the earlier assistant wrote. Those passages are marked *pasted*. Pasting them back is taken as endorsement, but they are not the user's own ideas.
> - All market numbers are third-party tracker estimates from Oct 26, 2026, and sources disagree by 10–50%.
> - **No "ideas file" was found.** No user message in this session had an attachment, image or document. The only user input is the six typed messages in §1.

---

## 0. TL;DR: what the user wants

1. **A viral Roblox game.** Their goal from message one: *"We will be building a viral roblox game."*
2. **The concept they picked is "Steal a Car: Heist City".** It's a steal-and-collect car game timed to the **GTA VI launch (Nov 19, 2026)**.
3. **"We are building GTA", not a thin steal loop.** The user wants to steal cars, rob people, make money, buy **guns and ammo**, "kill people", party up with friends or go solo, do small missions, and troll around the streets: *"exaclty the same as GTA."*
4. **They worry that a simple loop gets boring.** *"a siple game loop like that would just gets borign. and weak and lame fast right? not really scable is it?"* They want real depth on top of the viral hook, and they would rather pivot away from GTA than ship something shallow.
5. **Players keep, upgrade and level their cars, then ride the streets in them.** Other players can **steal those upgraded cars and keep them**. The user added this idea themselves.
6. **They endorsed "the garage is a bank, the street is a casino".** This is the core tension, and they pasted it back as the basis for the explanation.
7. **They want more complexity, concepts, features and game theory, not less.** *"there is a lot more compelxiity adn concepts features game thoryt and more to this that we ignored left out"*.
8. **Constraints are not a factor.** *"do not worry about time… dont worry abotu compelxity… dont worry abouthow big team is or bueget"*.
9. **Every one of the "seven layers of a viral hit" should apply.** *"with all fothese -"*, followed by the full list.
10. **Four decisions were never answered** when the session ended (§3.13):
    - the title, *Steal a Car* or *Heist City*;
    - the PvP model;
    - player cops at launch;
    - crew betrayal in or out.

---

## 1. The user's own words, in order

### 1.1 Message 1 (20:29). Kickoff
> We will be building a viral roblox game.
>
> Lets start by researching the most viral roblox games that have been released over the past week, month, and 3 months. The most successful and most viral roblox games that have made the most money.
>
> We will then be determining what factor(s) are common accross these games external factors or factors directly relating to the games itself that might be helpful in brainstorming the viral game that we will be building. Do deeper market and competitive research past this.

### 1.2 Message 2 (20:48). Go deeper; constraints don't matter
> yes this is good but go a little deeper. what speicifclaly abotu these gaems makes them popular. similar game features, game thoryt, UIUX, dopamine, features, functonality, markketing, themses, etc and so much more
>
> to actually idenifywhat type of gme we coudl buoild wihting the next 2-3 days that woudl go viral
>
> do not worry about time we have to build
> dont worry abotu compelxity
> dont worry abouthow big team is or bueget or anythign else
>
> just fous on first idenifyign exacltywhat makes game sivrla what underlyign overlyign ocmmon patterns tresdns factors etc we see that might hekp ifnorm and help us while braistomign what what gameto build

[This was the user's answer to the assistant's questions about team size, budget and timeline: ignore them all. The user cares about game theory, UI/UX, dopamine, features, functionality, marketing and themes.]

### 1.3 Message 3 (21:15). The concept decision and the GTA ambition
User-authored part:
> we are building Steal a Car: Heist City	Steal-and-collect cars, timed to GTA VI	.
>
> not just that. we ar ebuilidng GTA. enter in steal gars rob people make oney. buy guns and ammo, kill peopel. party up with freidns or go solo  and do small missions to amke money or go troll aroudn GTA steets. exaclty the same as GTA. woudlnt this go viral. with all fothese -

It was followed by a *pasted* copy of the assistant's "seven layers" and "other key findings" (see §2.3). [The user wants all seven layers applied.]

**Requirements the user stated here:**
- steal cars
- rob people
- make money
- buy guns and ammo
- kill people
- party up with friends **or** go solo
- small missions to make money
- troll around the streets
- "exactly the same as GTA"
- timed to GTA VI

### 1.4 Message 4 (21:20). Depth and scalability
The user *pasted* the assistant's list of GTA layers and social friction:
- Guns and ammo: bought with money, used to defend your garage, carjack and fight the police.
- Crews: party up with friends for a shared garage and a friend money boost.
- Missions: an armored-truck robbery every 5 minutes as the server-wide clock, plus a bank heist event on a timer.
- Robbing people and stores: a quick source of cash.
- Trolling: ragdoll physics, flinging, a wanted level that makes you a target.
- Raid other players' garages when their door lock runs out, and get an alert when someone is raiding yours.
- Carjack other players on the street.

**The user added this bullet themselves:**
> * stal cars that other players upgrade adn level up and keep

They then asked *"how would this play into the loop below"* and pasted the assistant's "first 30 seconds" loop and collectible section (see §3.2). They closed with:
> palyers can keep adn upgrade cars. then rie the steets with them. rob people do much more maybe? or how would we do this? a siple game loop like that would just  gets borign. and weak and lame fast right? not really scable is it?. we can picot off gta unless goign deeper into a real game is feasible and would actually go viral

[Players keep and upgrade cars, then ride the streets in them. The user wants more than steal-park-earn and fears the bare loop is boring and doesn't scale. They are willing to pivot away from GTA unless a deeper, real game is feasible **and** would go viral.]

### 1.5 Message 5 (21:29). Explain the whole game to an outsider
> this is good now write a 1-3 paraphs expalnation epxalinin the ame. overign all of this .
>
> the game the features, more adn aeveyrhign
> the game theory
> the scoial interaction

Next the user *pasted* the assistant's whole "garage is a bank, the street is a casino" design: the feature table, districts, loop time scales, loss softening and PvP default (see §3). They closed with:
> assume giving to a person /agen twho knows nothign abotu this idea. dont go overly speific wiht hwo to build this. jsut evyerhign baout the game. hwo it works. expirnce. what it woudl have. and more

[The user wanted a "what it is and how it feels" explanation of the whole game for someone new: the game, features, game theory and social interaction. Implementation detail was not wanted.]

### 1.6 Message 6 (21:30). The summary was too thin
> there is a lot more compelxiity adn concepts features game thoryt and more to this that we ignored left out are missing etc

[This led to the full 23-section concept document (§3). The user did not reply after that. The session ended with three decisions still open.]

### 1.7 Distilled user requirements

| # | Requirement (user's intent) | Source | Hotwire City v1 status |
|---|---|---|---|
| U1 | Build something **viral**, and also money-making ("made the most money") | Msg 1 | Aimed at, not yet proven |
| U2 | Base the design on what is common across the most viral and highest-earning games | Msg 1–2 | Partly; see §2 |
| U3 | Deep coverage of game theory, UI/UX, dopamine, features, functionality, marketing and themes | Msg 2 | Partly |
| U4 | Ignore time, complexity, team size and budget | Msg 2 | n/a |
| U5 | Title and concept: **"Steal a Car: Heist City"**, steal-and-collect cars timed to GTA VI | Msg 3 | Renamed **Hotwire City** (§4, G25) |
| U6 | **GTA gameplay:** steal cars, rob people, make money, **buy guns and ammo, kill people**, crews or solo, small missions, trolling | Msg 3 | Partial. No guns, robbery, crews or missions |
| U7 | All seven viral layers | Msg 3 | Partial |
| U8 | **Players keep, upgrade and level their cars**, then **ride the streets** with them | Msg 4 | Upgrades are player-wide; no per-car levels |
| U9 | **Others can steal those upgraded, leveled cars and keep them** | Msg 4 (user's own bullet) | Garage theft exists; no levels or upgrades carry over; street carjacking of owned cars is blocked |
| U10 | Not a "simple loop" that gets "boring", "weak", "lame" or doesn't scale | Msg 4 | Main risk for v1 |
| U11 | Go deeper only if it is feasible **and** viral; otherwise pivot off GTA | Msg 4 | n/a |
| U12 | "Garage is a bank, street is a casino" as the explanation | Msg 5 (endorsed) | Garage side only; no street payout multiplier |
| U13 | Explain the game, game theory and social interaction to an outsider, without build detail | Msg 5 | Concept doc existed (§3) |
| U14 | Add more complexity, concepts, features and game theory | Msg 6 | Most of §3 is missing in v1 |

**Reference games the user named themselves:** GTA and GTA VI. In *pasted* text they also cite Steal an Egg, DONT SPLASH, 99 Nights in the Forest, Steal a Brainrot, Break and Steal an Egg and Animal Hospital.

**Name ideas:** "Steal a Car: Heist City". Earlier, the assistant offered "Steal a Car" vs "Heist City" as alternatives.

---

## 2. What the earlier research concluded

### 2.1 Market snapshot (late Oct 2026)

| Game | Launch | Peak CCU | Notes |
|---|---|---|---|
| Steal a Brainrot | May 16 2025 | **25.9M** (Guinness: 25,836,222 on Oct 11 2025) | The steal-from-bases loop. The Admin War with Grow a Garden set the **47.4M** platform record on Aug 23 2025. A Bruno Mars concert drew 12.8M |
| Grow a Garden | Mar 2025 | **22.4M** | First version built in about 3 days by a 16-year-old. Peaks rose with each Saturday update: 5M → 11.7M → 16M → 21.3M → 22.4M |
| Steal An Egg (and Collect Rare Pets) | Jul 25 2026 | **12.4–14.27M** (Sep 19) | #1 in Q3 with about 6B visits. #2 on Top Earning, about $6–8M per 30 days. Now 726K and falling |
| 99 Nights in the Forest | Mar 2025 | **14.2M** | About 250K a year later. Film deal with 20th Century Studios |
| +1 Speed Keyboard Escape | Jan 2026 | 3–7.2M | Its Halloween reskin produced an **8.5× spike** |
| Kick a Lucky Block | Apr 2026 | ~1.7M | |
| Ride A Pet | Apr 2026 | ~1.6M | Dormant, then 3.5K → 129K in a day on a weather-mutation update. Fell to 3% of peak within weeks |
| Break and Steal an Egg | Sep 5 2026 | **1.31M** | **97.4% like rate**, higher than the original. It added one verb (pickaxe) and one stat (egg HP) |
| Animal Hospital (Anomaly) | May 2026 | ~1.2M | Average CCU went from 884 to 430K in 3 weeks. Head Nurse cat fan animations got 9.4M and 8M views |
| DONT SPLASH | Oct 17 2026 | 116K in 9 days, 48M visits | One-rule horror obby, spread by TikTok and Shorts |

- **Top Earning chart (Oct 26):**
  1. RIVALS (136K CCU)
  2. Steal An Egg (726K)
  3. Blox Fruits
  4. Moped Drag
  5. Murder Mystery 2
  6. Adopt Me!
  7–10. Evade, Fisch, Fish It!, Tower Defense Simulator
- **What that chart implies:**
  - Steal An Egg needs about **5× RIVALS' player count** to rank just below it.
  - Small competitive or collectible economies (Tower Defense, anime gacha, skins, trading) earn far more per player.
  - Estimates put RIVALS, Blox Fruits and Brookhaven at roughly **$6–15M a month**.
- **GameAnalytics benchmarks (1M+ MAU games):**

  | Metric | p50 | p90 | p99 |
  |---|---|---|---|
  | D1 | 10.3% | 15.9% | 22.2% |
  | D7 | 1.6% | | 9.1% |
  | D30 | 0.5% | | 4.7% |
  | Avg session | 9.8 min | 14.7 min | 21.1 min |
  | Sessions per day | 1.56 | 3.22 | 8.30 |
  | ARPPU | $0.70 | $2.33 | $55.31 |
  | Payer conversion | 3.8% | | |

  - **Retention depends on session length:**

    | Median session | Median D1 |
    |---|---|
    | 0–3 min | 4.3% |
    | 19–24 min | 11.5% |

    Among the 19–24 min games, the top 2% reach D1 of 32%. Median ARPPU rises from $0.48 to $1.71 across the same range.
  - **Design target: 13–24 minute sessions.**
- **Platform:**
  - DAU fell from 152M (Q3'25) to 123M (Q2'26).
  - Q3'26 bookings are guided down 14–18% year over year, and the stock is down 35–50% this year.
  - Q2 bookings missed because "players moved away from 2025's high-spending viral games."
  - **Adults are the growth segment:** US players aged 18–34 grew 40–50% and spend about 50% more. DevEx pays +42% on spending from age-checked US 18+ players in qualifying games.
  - Concentration is falling: the top 10 games hold about 20% of hours.
  - Devices: about 44% play on mobile and PC, 41% PC only, 12% mobile only. **Build for both.**

### 2.2 Platform rules that constrain the design (2026)

- **Recommended For You** was rewritten on **Jun 15 2026** and drives about 90% of traffic.
  - It looks at a **28-day window**, in day 1, days 2–7 and days 8–28 buckets.
  - **Most important signals:**
    - play-through rate
    - **first-play bounce under 60 s and at 61–180 s** (both negative)
    - play days
    - playtime (capped at 60 min a day)
  - **Important signals:**
    - **intentional co-play days**
    - qualified sessions
    - **days with a purchase**
    - Robux per user
  - Only organic Recommended For You joins count toward ranking.
  - Similarity detection deprioritizes clones whose metadata or place files resemble other games.
- **Audience gate for new games.** A new game is shown only to age-checked players aged 16+ until it has **500 highly engaged players** within 60 days. It also needs a refundable 1,000 Robux fee and an ID-verified creator account with 2-step verification. Ads Manager's Engagement objective buys exactly this audience. After that, about **50–100 steady CCU for a week** gets the algorithm to start recommending the game.
  - *Note: v1's `docs/RESEARCH.md` says "250 unique plays" here. The figures conflict; re-check before launch.*
- **Content maturity:**

  | Label | Who can see it |
  |---|---|
  | Mild | Roblox Kids (5–8) and Select (9–15) |
  | **Moderate** | Select (9–15) and 16+, but not 5–8 |
  | Restricted | 18+ only |

  - Realistic consequences of violence, even once, make a game Moderate.
  - Realistic blood: light blood is Moderate, heavy blood is Restricted (18+).
  - **The earlier chat recommended Moderate:** guns with ragdoll deaths, no realistic blood.
  - **v1 chose Mild:** no guns, no death. See §4, G4.
- **Paid random items:**
  - Show odds as percentages that add up to 100% before purchase.
  - Luck boosts must state their effect, and the displayed odds must update while a boost is active.
  - Check `PolicyService` `ArePaidRandomItemsRestricted` and `IsPaidItemTradingAllowed`.
  - This applies globally since about May 2026.
- **Banned mechanics:** reward-for-watching feeds. Steal An Egg was pulled for about a day (around Aug 24–25) over its TikTok-style Reels treadmill.
- **IP:**
  - No "GTA", "Grand Theft", Rockstar logos, or "Vice City" / "Leonida" place names.
  - No real car brands without a licence.
  - Steal a Brainrot had to remove Tung Tung Tung Sahur over a licensing dispute.
- **Chat:**
  - 57% of DAU is age-checked.
  - Chat is limited to the same or an adjacent age band, and it is off by default for under-9s.
  - Social links on game pages are hidden from under-16s.
  - So the social layer must work without text chat.

### 2.3 The "viral equation": seven layers every 1M+ hit shares
The user pasted this back as a requirement ("with all fothese").

1. **The title is the rule.** "Steal an Egg", "DONT SPLASH", "99 Nights in the Forest": a kid gets the whole game from the name. About 9 of 12 recent 1M+ hits use "Verb a Noun", "+1 X", "Don't X" or "Survive N Nights".
2. **One action you can play within 30 seconds,** with no tutorial.
3. **A trending collectible with rarity tiers.** The collectible rotates every 3–6 months: brainrot, then lucky block, then egg and pet, then cats and dinos. Value multipliers stack on rarity, and "1 in X" odds give players something to brag about.
4. **Social friction:** stealing, betrayal, pushing a friend into the water. That emotion is what gets clipped.
5. **A number that climbs forever:** Speed, $/s, "Night 47".
6. **A clock the whole server shares:** 5-minute restocks, a Saturday update with "Admin Abuse" an hour before it, seasonal reskins. **Every record peak landed on an event day.**
7. **A 3-second clip moment:** a rare reveal, a theft, a splash death, a jumpscare.

**Two more 2026 gates sit on top:**
- **Retention:** the game must hold players for 28 days.
- **Audience:** the first wave must come from 16+ players.

**Other key findings** (also pasted back by the user):
- **Two families of hits:**
  - Collect, steal and idle games peak highest (10–26M) but decay 95–99% within 6–9 months, leaving a 200–300K tail.
  - One-rule horror and co-op games peak lower (1–14M) but last longer.
  - The newest hits combine both, for example *Sell Fries!*, a tycoon by day with anomalies at night.
- **The winner is rarely first.** It takes a proven loop, adds the hot collectible and changes one thing.
- **Trends move fast.**
  - 2025 hits took about 5 months to peak; 2026 hits take 3–8 weeks (Break and Steal an Egg took 19 days).
  - Waves last 2–3 months, and 20–50 clones appear within 2–4 weeks.
  - Once a trend has 15 or more clones, the window has closed.
- **The first 60 seconds decide everything.** Spawn on your own plot, an arrow points at the one action, and a big reward reveal comes within 30 seconds.
- **Viral characters sell.** Animal Hospital's two Robux-only classes (Head Nurse 190 R$, Secret Agent 890 R$) are the characters fans draw most.
- **Sell at the moment of loss or desire.** Examples: a revive, a "double coins" button on the results screen, a base lock while you're being robbed. Price items to fit Robux pack sizes.
- **Cautionary tale: Grow a Garden 2 (2026)** added guilds, combat and night raids, and fell from about 976K to 21K. **Depth bolted on without a clean hook failed.** This matters given the user's push for depth: the hook has to stay simple, and depth gets layered in over time.

### 2.4 Teardown details worth copying

- **Steal An Egg**
  - Servers hold 7 players, and sessions average about 15 minutes.
  - **Loop:**
    1. Grab an egg with E.
    2. Sprint home while a biome Guardian chases you, with a "RUN!!" warning. If it catches you, you ragdoll and drop the egg.
    3. Put the egg in your Pen and hatch it on a timer.
    4. The pet earns $/s.
  - **Speed is the one gating stat**, trained on a treadmill. Each biome has a soft speed requirement: 0 → 900 → 10K → … → 700M → 20B.
  - **Rarity and mutations:** 10 tiers, earning $1/s to $8M/s. Mutations: Silver 1.2×, Golden 2×, Rainbow 3×, Luminous 10×.
  - **Shared clocks:**
    - egg spawns reset every 5 minutes, followed by a 13-second map closure;
    - rifts every 30 minutes;
    - a biome rotates nightly.
  - **First 60 seconds:** like, favorite and join the group for **+10,000 Speed**, which skips two biomes.
  - **Monetization is lean:** 2× Money (399 R$), 2× Hatch (467 R$), Instant Hatch (about 9 R$ per egg).
  - Ships every Saturday with Admin Abuse.
- **Steal a Brainrot**
  - **Stealing:** a carrier is slowed and the owner gets an alert. One bat hit returns the stolen item.
  - **Base lock:** 30 seconds on join, then a 60-second lock button, +10 seconds per rebirth or VIP.
  - **Pity timers:** a Legendary every ~5 minutes, a Mythic every 15.
  - **Mutations stack:** Gold 1.25× up to Rainbow 10×, and Rainbow + Nyan = 60×.
  - **Rituals:** a three-player summon calls a meteor for the whole server.
  - **Rebirth:** later rebirths need specific Secret-tier units, which pushes top players to steal.
  - **Viral clip:** "kid cries after getting robbed" videos.
- **Grow a Garden**
  - Plants grow offline.
  - The shop **restocks every 5 minutes for the whole server** (skip for 79 R$).
  - **Weather is a server-wide mutation:** Rain 2×, Frozen 10×, Shocked 100×, Celestial 120×.
  - Stealing a crop costs 37 R$ and is **announced to the whole server**.
- **Break and Steal an Egg:** a 20-tier pickaxe ladder (each tier about 4× the power at 7–10× the cost), plus a server-wide "Titanic Egg" swarm event.
- **Kick a Lucky Block:**
  - a power meter where a "perfect" kick adds luck;
  - a **tsunami chases you home**;
  - server-wide luck events (2×, 4× or 8× for 5 minutes) announced in chat.
- **DONT SPLASH:**
  - The title is the rule.
  - **Player collision plus a Push / Super Push tool** lets friends betray each other.
  - Downed players get rescued with a rope.
  - **Monetization at the moment of loss:** revive, "double this run" for 24 R$, 2× Cash (200 R$), tool slots (99/149 R$).
  - Shipped "[NEW STAGES]" within 7 days.
- **Huss Valley:** "Hero or Chicken" picks one runner each round for a solo spotlight, which manufactures a clip moment every round.
- **Backseat Rally:** the driver can't see the road, so the co-driver calls the turns. That information gap turns voice chat into comedy.
- **Murder Mystery 2** has lasted 12 years on cosmetics and trading.

### 2.5 GTA-genre competitor analysis
Researched at 21:16 in answer to "exactly the same as GTA".

- **Market:**
  - GTA-inspired Roblox games have more than **100B plays**, and the genre is a decade old.
  - Searching "Grand Theft Auto" on Roblox returns *Grand Treat Auto 5* and *THE GTA 6*.
  - Analysts told AFP (via The Star, Sep 30 2026) to expect a wave of GTA VI copies around launch.
- **Incumbents have faded:**

  | Game | Players now |
  |---|---|
  | Jailbreak | ~11K (10,957 in Aug 2026) |
  | Da Hood | ~1–3K (once 80–120K) |
  | Mad City Ch. 2 | ~298 |
  | Criminality | small |

- **GTA VI tailwind:**
  - It launches **Nov 19 2026**, costs **$80**, is **rated M**, and ships **without online mode**. GTA V sold more than 230M copies.
  - Most of Roblox's audience can't play it.
  - The pitch: **"free GTA your friends can play."**
- **The assistant's verdict:**
  - An exact GTA copy would **not** go viral on its own, scoring about **55/105** on the rubric.
  - GTA fantasy plus the Steal a Car loop scores about **85/105**.
  - **Why the exact copy fails:**
    - you can't use "GTA" in the title, and "open-world crime" isn't a rule;
    - ten activities give no single 30-second action;
    - there's no collectible;
    - there's no shared clock;
    - **open PvP kills a new player's first minute** (Da Hood is known for this), and the algorithm punishes 60-second bounces.

### 2.6 Psychology, juice and UI/UX (the "dopamine stack")

**What fires at each time scale:**

| Scale | What fires | UX that delivers it |
|---|---|---|
| ~1 s | Action → feedback: "+$" floaters, coin tick | Floating numbers, pitch-varied sounds, button squash, haptics |
| ~10 s | Variable reward: hatch, roll, grab-and-run | Slot-machine reveal, rarity colors, "1 in X" |
| ~1 min | Upgrade or goal tick | Progress bars that start ~40% full, red "!" badges, a purchase prompt at the point of desire |
| 5–10 min | Pulse event: restock, weather, base lock expires | Toast with countdown, server announcement, playtime gifts past the 10-minute mark |
| Session (15–25 min) | Big unlock: rebirth, new zone, Index tier | Natural stopping point, then "ready in X min" |
| Day | Offline earnings, daily login, free spin | "While you were away you earned…" |
| Week | Saturday update + Admin Abuse | Event countdown, update log, title tag, codes |
| Season (4–8 wk) | Battle pass, reskin, crossover | Pass track with honest end dates |

**Psychological levers:**
- variable-ratio rewards
- legible rarity ("1 in 1,000,000")
- **loss aversion** (your stuff is visible and can be taken)
- endowment (your named plot)
- social proof and envy (server-wide rare-drop announcements)
- goal gradient
- FOMO (honest only)
- appointments
- anticipation, then payoff
- sunk cost
- status and self-expression
- reciprocity (gifting, server-wide luck)

**Juice spec:**
- **Floating "+$" numbers:** rarity-colored, merged when spammed ("+$4.2K ×12").
- **Currency counter:** rolls up and pops (scale 1.0 → 1.15 → 1.0, bouncy easing).
- **Panels and buttons:** panels open from 0.8 → 1.05 → 1.0 with Back easing over a dimmed backdrop; buttons squash to 0.9 on press.
- **Slot-machine reveal:**
  1. The item sits center-screen for about 0.3 s.
  2. 2–3 wobbles with rising pitch.
  3. A **color flash that hints the rarity**.
  4. The item pops in with "1 in X".
  5. Legendary and above add slow-motion, screen shake, confetti, a unique sound sting and a server announcement.
- **Sound:** a **sound sting per rarity tier**, so players hear a Legendary from across the map.
- **Camera:** a FOV punch of +5–8° on boosts and a short decaying shake, both with a settings toggle.
- **Particles:** rarity auras and pickup trails.
- **Number format:** abbreviated as K/M/B/T/Qa.

**First 60 seconds recipe:**

| Time | What happens |
|---|---|
| 0–5 s | Spawn on your **own named plot** |
| 5–15 s | An animated Beam plus a bouncing arrow point at the one verb |
| 15–30 s | A guaranteed first success and a full-juice reward reveal |
| 30–60 s | Income ticking, first upgrade, a bar already ~40% full, a like/group prompt for a big boost |
| 1–3 min | Second goal, the Index reveal ("1/30") |
| 3–10 min | Social hook: someone's rare item, or a server announcement |

**HUD conventions:**

| Position | What goes there |
|---|---|
| Left vertical stack | Shop, Inventory, Index, Rebirth, Trade, Settings |
| Top | Currency pills with a "+" that opens the shop |
| Right | Free gift timer, active boosts, quest tracker |
| Top-center toast lane | Restocks, events, rare-drop announcements |
| Buttons with rewards waiting | Red "!" badges |

- **Simulator look:** thick dark outlines, saturated gradients, rounded corners, chunky cartoon fonts, icons first, almost no text.
- **Touch targets:** about 8–10% of screen height.

**Rarity colors:**

| Tier | Color |
|---|---|
| Common | Gray |
| Uncommon | Green |
| Rare | Blue |
| Epic | Purple |
| Legendary | Gold |
| Mythic | Red or pink |
| Secret | Rainbow, or black with a glow |

Use the same color on the frame, label, chat message, particles and sound pitch.

**Retention widgets:**
- playtime gift ladder at 5, 10, 15, 25, 40 and 60 minutes
- 7-day calendar that **pauses** the streak instead of resetting it
- daily free spin
- offline-earnings popup with an optional 2× (from a manually started rewarded ad, or a pass)
- codes
- friend boost
- rebirth: the first one about 20–40 minutes into a player's life, each later one 1.5–3× the cost

**Session targets:** a median above 10 minutes (the Creator Rewards line), aiming for 13–24. Give natural stopping points, each paired with a "ready in X" hook.

### 2.7 Monetization findings

- **Robux packs:**

  | Robux | Price |
  |---|---|
  | 80 | $0.99 |
  | 400 | $4.99 |
  | 800 | $9.99 |
  | 1,700 | $19.99 |
  | 4,500 | $49.99 |
  | 10,000 | $99.99 |

  - Price items at 99, 199, 399, 799 or 1,299 R$.
  - The creator keeps about 70% of gamepass Robux, and DevEx pays about $0.0038 per Robux.
- **Price ladder:**

  | Tier | Robux | Examples |
  |---|---|---|
  | Impulse | 9–99 | revive, restock skip, instant actions |
  | Core | 139–499 | 2× Money, 2× Luck, Auto-collect, extra slots |
  | Status / anchor | 499–1,299 | VIP, hero characters |
  | Whale | 1,999–4,999 | |
  | Season pass | 749–849 | |

- **What converts:**
  - Prompt at the point of desire, never on join:
    - after a near-jackpot
    - when inventory is full
    - **while your item is being stolen** ("Lock base 10 min — 49 R$")
    - on the death or results screen
  - a one-time starter pack 3–10 minutes into the first session
  - convenience passes (auto-collect, skip animation)
  - server-wide luck passes that help everyone
  - gifting
  - Robux-only hero characters
- **Spend days are a ranking signal,** so **one early cheap purchase** is worth more than one big purchase later.
- **Honest only:**
  - no fake timers
  - no permanent "sales"
  - no near-miss visuals on paid rolls
  - no false reference prices

  A University of Sydney study (May 2026) found deceptive practices in **14 of the 15** top games, and enforcement is expected to tighten.

### 2.8 Marketing and distribution playbook

- **Packaging:**
  - Upload 3–5 thumbnails and use Roblox's built-in A/B test, which averages **+8.5% play-through** (up to +50%).
  - The thumbnail must match the first 60 seconds of play.
  - Add a gameplay video thumbnail.
  - Use a "Verb a Noun" title with tags like `[UPD]` and `[🎃]`, and never promise Robux.
- **Short-form video** (average views by format, from one creator's 30-day test):

  | Format | Avg views |
  |---|---|
  | Glitch or exploit discoveries | 890K |
  | Horror jumpscare reactions | 720K |
  | "POV: you find…" | 540K |
  | Secret locations | 480K |
  | Before and after an update | 310K |
  | **Plain gameplay** | **42K** |

  - Also: "I stole the rarest…", "Day 1 vs Day 30", friend betrayal, Admin Abuse chaos.
  - The first 1.5 seconds decide whether people keep watching. Post 3–5 times a day.
  - **Clipping campaigns** pay about $1–1.50 per 1,000 verified views.
- **Creators:**
  - YouTubers amplify a trend; they rarely start one.
  - Seed with mid-size creators (10K–500K subscribers) through free passes or admin perks.
  - The developer as streamer during Admin Abuse is itself content.
  - Roblox's own TikTok started Dead Rails' rise (499K likes, then 600K+ CCU).
- **Built-in loops:**
  - **Referral rewards:** reward both sides using `ReferredByPlayerId`. In-game invite prompts get 6× more players sending invites.
  - **Share links:** `PromptLinkSharing` with deep links.
    - **Creator Rewards** pay 35% of a new player's first $100 of spending.
  - free or cheap private servers
  - like/group rewards and codes at like milestones
  - **Experience Events** with countdown and "Notify Me"
- **Timing:**
  - Saturday is the weekly peak (around 19:00 UTC, ~16M CCU).
  - Update on Friday or Saturday, with Admin Abuse about an hour before.
  - Holidays bring 3–4× normal traffic; Halloween week is +38% CCU.
  - The next window is **US Thanksgiving to New Year**.

### 2.9 Open lanes and trends (as of Oct 26)

- **Cats are the next animal noun:** Cat Battles grew nearly 500% in a week.
- **Dinos and mounts:** Ride a Dino grew 404% in a week.
- **Ragdoll and physics chaos:** Ragdoll Reality grew 2,525%, and no 1M+ ragdoll game exists.
- **Tesla Roadster "kickflip" meme:** about 98M views.
- **GTA VI on Nov 19.**
- **Steam Next Fest hits not yet on Roblox:** Probably Stolen (a stolen-goods fence) and Dumpster Gang (a raccoon heist).
- **Winter and Christmas reskin window.**

### 2.10 Viral Fit Score rubric (out of 105) and concept scores

Score each criterion 0–3 and multiply by the weight:

| Criterion | Weight |
|---|---|
| Title = rule | 3 |
| 30-second core moment | 3 |
| Clip moment | 3 |
| Fresh noun on a proven verb | 3 |
| Social friction or co-op | 2 |
| Collectible depth | 2 |
| Climbing number | 2 |
| Return hooks | 2 |
| Shared clock | 2 |
| Monetization at the moment of desire | 2 |
| Mascot | 1 |
| Seasonal / update extensibility | 1 |
| Cheap to build | 3 |
| Policy-safe | 2 |

**Concept scores:**

| Concept | Score |
|---|---|
| Steal a Cat | ~88 |
| Ride a Dino, Steal Its Eggs | ~84 |
| Escape the Blizzard for Pets | ~84 |
| **Steal a Car: Heist City** | **~82** |
| Don't Wake the ___ | ~80 |
| Raccoon Heist | ~78 |
| Airport Security (Anomaly) | ~74 |
| Ragdoll ___ | ~72 |

**The user picked Steal a Car: Heist City** and pushed it toward GTA depth. The assistant re-scored the GTA-fantasy version at about 85.

### 2.11 Policy landmines
- No watch-for-reward feeds.
- No other people's IP or meme characters.
- No copied code or assets. Steal An Egg was accused of reusing Pet Sim 99 code.
- No "free Robux" promises.
- No fake timers or near-miss visuals on paid rolls.
- Disclose odds and handle PolicyService for anything paid and random.
- Thumbnails must show the real game.
- **All gun, damage, money and ownership logic runs on the server.** Gun games are the top target for cheaters.

### 2.12 Key sources cited in that chat
- **Roblox:**
  - [Newsroom: Optimizing Discovery (Jun 15 2026)](https://about.roblox.com/newsroom/2026/06/optimizing-discovery-great-games-reach-millions-players-roblox)
  - [DevForum: RFY retention update](https://devforum.roblox.com/t/recommended-for-you-algorithm-improvements-that-better-value-long-term-retention/4684575)
  - [Kids & Select gate](https://create.roblox.com/docs/production/publishing/kids-and-select)
  - [Paid Random Items](https://create.roblox.com/docs/production/monetization/paid-random-items)
  - [Content maturity](https://create.roblox.com/docs/production/promotion/content-maturity)
  - [Creator Rewards](https://create.roblox.com/docs/creator-rewards)
  - [Referral system](https://create.roblox.com/docs/production/promotion/referral-system)
  - [Experience Events](https://create.roblox.com/docs/production/promotion/experience-events)
  - [Thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)
- **Data:**
  - [GameAnalytics 2026 Roblox report](https://www.gameanalytics.com/reports/2026-roblox-report)
  - [RBLXSTAT](https://rblxstat.com/lists/trending-roblox-games)
  - [BloxRant Top Earning](https://bloxrant.com/roblox-top-earning-games)
  - [RoWatcher brainrot decline](https://rowatcher.com/news/is-the-brainrot-trend-dying-what-ccu-data-from-three-top-games-reveals)
  - [Aream & Co. Q3 2026 report](https://investgame.net/wp-content/uploads/2026/10/aream_co._video_game_market_report_q3_2026.pdf)
  - [University of Sydney monetization study](https://www.sydney.edu.au/news-opinion/news/2026/05/17/inside-the-pay-to-play-world-of-roblox-targeting-children-.html)
- **GTA:**
  - [AFP via The Star: Roblox poised to cash in on GTA copycats](https://www.thestar.com.my/tech/tech-news/2026/09/30/roblox-is-poised-to-cash-in-on-grand-theft-auto-copycats)
  - [Mad City vs Jailbreak](https://earnaldo.com/blog/mad-city-vs-jailbreak)
  - [Da Hood vs Jailbreak](https://earnaldo.com/blog/da-hood-vs-jailbreak)
- **Teardowns:**
  - [Steal An Egg guide](https://allthings.how/steal-an-egg-beginner-guide-biomes-speed-and-pets-explained/)
  - [Kotaku on the Reels crackdown](https://kotaku.com/roblox-cracks-down-on-doomscrolling-games-like-steal-an-egg-that-forces-players-to-watch-reels-while-running-on-a-treadmill-2000727952)
  - [DONT SPLASH guide](https://dontsplash.wiki/guide/dont-splash-how-to-play)
  - [Tubefilter: Admin War record](https://www.tubefilter.com/2025/08/25/roblox-grow-garden-steal-brainrot-admin-war-record/amp/)

---

## 3. The proposed game design from that chat ("Steal a Car", alt. "Heist City")
Sources: the assistant's turns at 21:17, 21:21, 21:29 and 21:33, plus `design/01-game-concept.md`.

### 3.1 Pitch and core idea
- **One-liner:** *"Steal cars, build the sickest garage in the city, and protect it from everyone else trying to do the same."*
- **Positioning:** *"free GTA your friends can play"*, released the week GTA VI launches to an audience that mostly can't play it. The hook is the GTA fantasy; the car collection is what brings players back.
- **Audience and rating:** ages 9+, Roblox **Moderate**. Violence is non-graphic: no realistic blood, players ragdoll and respawn, and police **bust** rather than kill. Mobile-first, plays well on PC.
- **Core tension: the garage is a bank, the street is a casino.**
  - **In the garage,** a car earns $/s, including offline, and is mostly safe unless the door lock is down.
  - **On the street,** the same car earns **3–10× more** through missions, heists, races and robberies, and its speed and armor matter. But it can be carjacked, wrecked or impounded.
  - **Upgrades raise both** garage income and street performance. *"Your best cars are the ones you most want to show off, and the ones everyone else most wants to take."*
  - **The risk-vs-reward choices this creates:**
    - bank your cash or keep pushing;
    - take your prized car out or keep it locked away;
    - push to 5 stars for 3× payouts or lie low.
- **The rule for depth:** every GTA feature must **serve the car loop rather than sit beside it**. Showing the depth too early is the real risk, so in minute one players only steal and park.

### 3.2 The player experience
**First 30–60 seconds** (the user pasted this):
1. Spawn inside **your own garage**, with your name on the sign.
2. An arrow points to a beat-up car on the curb.
3. **Hold E to hotwire** with a short **timing bar**: nail it for a faster start.
4. The engine roars, **one wanted star lights up**, and a siren starts behind you.
5. Floor it home. The door slams, the car rolls onto its spot, and a counter starts ticking: **+$5/s**. (Or sell the car at the chop shop.)

**First ten minutes** (concept-doc version):

| Minute | What unlocks |
|---|---|
| 1–2 | First upgrade, so income visibly jumps |
| 2–4 | The chop-shop order board gives you a target ("any blue car in 3 minutes") |
| 4–6 | A **free pistol**, plus the server-wide armored-truck announcement |
| 6–10 | First raid alert, a crew-invite prompt, the first server-wide rare spawn |

*The 21:21 version: 1–3 min first upgrade and order; 3–5 min free pistol and first armored truck; 5–10 min crew invite and first raid alert.*

**A 20-minute session:**
1. Collect offline earnings.
2. Hunt an order-board car across two districts.
3. Defend your garage when the lock drops.
4. Join the armored-truck rush.
5. Level up your favorite car.
6. Run a bank heist with your crew.
7. Lose your stars at a paint shop.
8. Log off as "Rare spawn in 4:00" counts down.

**What long-term players chase:**
- a complete collection
- serial-numbered limited cars
- a garage empire across several districts
- a top crew that controls turf
- a legendary Rep rank
- the "Most Wanted" leaderboard

### 3.3 The loop at every time scale

| Scale | What happens |
|---|---|
| 30 s | Hotwire, escape the cops, park, start earning |
| 5 min | Order board refreshes, armored truck spawns, a rare car is announced. You upgrade, raid or defend |
| Session (15–25 min) | Level a car into a new tier, unlock a district, run a crew heist, climb your permanent Rep rank |
| Day | Offline garage earnings, a daily chop-shop contract, a free spin |
| Week | Saturday update with 3–5 new cars, a paint finish and a heist or district. **Admin Abuse** beforehand (Hypercar Rain, Police Strike, 10× Gold-paint luck) |
| Season | Car pass, city reskin (e.g. winter) |

### 3.4 The city: districts are soft progression gates
Anyone can go anywhere. Richer districts spawn better cars but bring heavier police, so you need an upgraded car to escape. *"You can steal a Hypercar at the Airport on day one, but your starter car won't get it out."*

| District | Spawns | Police | Feel |
|---|---|---|---|
| Junkyard / Docks (start) | Beaters, Sedans | Light | Rusty, chaotic |
| Suburbs | Sedans, Sports | Light–Medium | Driveways, easy targets |
| Downtown | Sports, Muscle | Medium | Traffic, banks, stores; the action hub |
| Beachfront | Muscle, Super | Medium–High | Showrooms, flex spot, race strip |
| The Hills | Super, Hyper | High | Mansions with private garages |
| Airport / Port | Hyper, Secret | Very high, helicopters | Endgame: cargo planes, containers, rarest spawns |

- **Setting:** stylized, colorful, sun-soaked, original. A coastal downtown, palm trees, neon nights, a chunky cartoon style. "Cheerful and exaggerated, not gritty."
- **Living world:**
  - NPC traffic and pedestrians.
  - **Day/night cycle:** night brings rarer spawns but tougher cops.
  - **Weather** (rain, fog, heatwave, thunderstorm) changes driving and spawn odds. A thunderstorm can "charge" cars with an **Electric** finish, the way Grow a Garden's weather mutates crops.
  - **City events:**
    - a **blackout** knocks out police radios for 3 minutes;
    - a **parade** closes Downtown;
    - an hourly **supercar expo** spawns showroom cars you can steal.

### 3.5 Cars: the collectible
**Tiers:**

| Tier | Example (original designs) |
|---|---|
| Beater | rust bucket, mail van |
| Sedan | family car, taxi |
| Sports | hatchback, roadster |
| Muscle | classic V8 |
| Super | low exotic |
| Hyper | concept hypercar |
| Secret | prototype, armored limo, jet-car |

**Value layers stack multiplicatively.** Value = rarity × finish × level × upgrades, and that stacking produces the "1-in-X" moments.
- **Paint finish (mutation):** Matte → Metallic → Chrome → Gold → Neon → Rainbow → Glitch / Void / Galaxy.
- **Traits:** *Turbo*, *Bulletproof*, *Classic*, *Prototype*, *Stolen from a cop*.
- **Level / XP:** earned from driving, missions and races. Higher levels mean more income and better stats.
- **Upgrades:** engine, armor, nitro, tires, handling. Each is a money sink that also makes the car more desirable.
- **Car mastery:** each model has mastery levels with small perks.
- **Limited editions:** event and seasonal cars with **serial numbers** ("#7 of 500").

**Rare spawns are announced to the whole server:**
- *"A 1-in-5,000 Gold Hypercar just spawned at the Airport!"*
- The whole server stampedes to it. This is the signature clip.
- A rare spawn comes every 10–15 minutes.

**Collection Book (Index):**
- silhouettes of everything not yet owned
- **set bonuses** ("all Muscle cars", "every Gold finish")
- limited cars leave permanent gaps, which creates collector FOMO

**Customization:**
- wraps, rims, spoilers, underglow, tinted windows, custom horns
- **custom license plates**, which players write themselves and which become clip and meme fuel

### 3.6 The garage: base, bank and trophy room
- **Growth:** starts with a couple of spots, then **multi-floor garages**, then **safehouses in other districts**.
- **Income:** parked cars earn $/s, with an offline cap.
- **Showroom:** other players can walk in, see your cars with income labels, and **like your garage**.
- **Door lock:**
  - The garage is safe while it is locked.
  - When the lock expires, others can raid until you re-lock.
  - Lock length grows with upgrades and Rep.
  - The owner gets an alert ("Someone is breaking into your garage!") and rushes home.
- **Defenses:**
  - reinforced doors
  - alarms
  - traps: spike strips, oil slicks, a guard dog
  - crewmates can defend too
- **Favorite slot:** one car (expandable with Rep) that **can never be stolen**.

### 3.7 Ways to make money (and the risk of each)

| Activity | Payout | Risk |
|---|---|---|
| Garage income | Steady, passive | Low (raids) |
| Chop shop + **order board** (refreshes every 5 min, timed bonuses) | Instant cash | Low |
| **Robbing stores** (gas stations, jewelry stores, ATMs; skill-timed mini-actions) | Quick cash | +1★ |
| **Mugging players** | Their **carried, unbanked** cash | Medium |
| **Carjacking players** | Their car, upgrades included | High; triggers a chase and a bounty |
| Raiding garages | Their parked cars | High; only while the lock is down; owner alerted |
| **Armored truck, every 5 min** | Big cash bag | High; the whole server converges. The shared clock |
| **Bank heist** (timed event) | Huge | Very high; crew; multi-stage |
| **Street races** | Prize money or **pink slips** | Variable |
| **Bounty hunting** | Bounty value | Medium |
| **Police work** (cop role) | Arrest rewards | Medium |
| Businesses (later) | Passive | Low |

**Cash on hand vs. banked.** Carried cash can be stolen, and part of it drops when you're busted or taken down. Deposits at your garage or an ATM are safe. Players constantly decide whether to bank now or push for more.

### 3.8 Combat, guns and trolling (the user's explicit ask)
- **Weapon ladder:** pistol → SMG → shotgun → rifle → special/heavy. Unlocked by Rep and bought with cash.
- **Ammo** is a consumable and a constant cash sink.
- **What guns are for:**
  - carjacking (shoot out tires, pull the driver out)
  - defending your garage
  - fighting cops
  - robberies
  - heist shootouts
- **Melee and non-lethal tools:** bat, taser, smoke grenades, spike strips, an **EMP** that stalls engines.
- **Takedowns:** the player ragdolls and respawns at a hospital for a small fee, dropping part of their carried cash.
- **Trolling is built in on purpose:**
  - ragdoll, flinging, ramming;
  - **ramming knocks cash loose**;
  - griefers rack up stars until they become the bounty.

### 3.9 Police, heat and the law
- **Wanted stars (1–5) are the risk dial.**
  - **Escalation:** patrol cars → roadblocks → SWAT → helicopters → special units at 5★.
  - **Payouts rise with stars,** up to **~3× at 5★**.
  - **At 5★:** a **server-wide bounty**, and your location is pinged to everyone periodically.
  - A **"Longest at 5 stars"** leaderboard, which becomes a natural video series.
  - **Losing stars:** break line of sight, hide in your garage, or repaint at a paint shop.
- **Busted vs. taken down:**
  - **Busted** by police: jail, and your car is **impounded**. Pay a fee to get it back, or break it out.
  - **Taken down** by players: ragdoll, hospital respawn, and you drop carried cash.
- **Jail is a mini-game, not a timeout.** Serve a short sentence, or **jailbreak**: dig, sneak, or get broken out by your crew.
- **Player cops** (optional faction, "strongly recommended"):
  - Earn by busting high-star players and recovering stolen cars.
  - Adds a second playstyle and makes chases player vs. player.
  - The assistant recommended adding it after launch.

### 3.10 Crews, heists, missions, racing
- **Crews:**
  - 2–4 players at first, with ranks later.
  - **+10% cash per crewmate** in the server.
  - shared crew garage, colors, decals and plates
  - crew Rep, levels and leaderboards
  - **crew turf** (later): crews control districts for a passive cut
- **Crew betrayal** (optional, high-drama):
  - The heist loot is a **physical bag** anyone can run off with.
  - A fair split is the default.
  - Betrayers are publicly tagged **"Backstabber"** and lose Rep.
  - This is the prisoner's dilemma.
- **Heists** (bank, jewelry store, casino, cargo plane, armored convoy):
  1. **Prep:** get a getaway car, gear and scouting.
  2. **The job:** loud or stealth, a vault-crack mini-game, police waves.
  3. **The getaway:** a multi-star chase to the drop-off.
  4. **The split:** carry the bag home.

  **Roles:** driver, gunner, hacker, lookout.
- **Timed server events:**

  | Event | When |
  |---|---|
  | Armored truck | every 5 min |
  | Bank heist window | every 30 min |
  | Rare-car spawn | every 10–15 min |
  | Supercar expo | hourly |

- **Small jobs** (1–3 min, solo):
  - chop-shop orders
  - timed deliveries
  - **taxi rides with chaotic NPC passengers**
  - **stunt jumps**
  - "lose the cops" challenges
  - repo jobs
- **Street racing:**
  - **Formats:** sprint, circuit, drag, drift, time trials.
  - **Pink slips:** both players stake a car and the winner keeps both, *"the purest high-stakes moment in the game."*
  - Skill matters (nitro timing, drifting, lines), so a well-driven cheap car can beat a badly driven hypercar.

### 3.11 Losing things, economy and progression
- **Anti-quit:**
  - **Insurance** pays back part of a stolen car's value (about 25%; better tiers are an upgrade).
  - **Repo:** your stolen car is marked in the thief's garage, so you have a revenge target.
  - **Favorite slot** that can't be taken.
  - Protection for new players' first few minutes (10 minutes in the PvP default).
  - Spawn and garage safe zones, lock timers, bounties on serial griefers.
- **Catch-up:**
  - the richest player is always worth more to rob and carries a bounty;
  - bounties scale with how much someone has stolen;
  - the leader gets pulled back toward the pack.
- **Theft spectacle:**
  - The thief keeps everything you built.
  - The owner gets an alert and a GPS ping.
  - **The thief shows up on everyone's map with a bounty**, so every theft becomes a server-wide chase.
- **Economy:**
  - **Sources:** garage, chop shop, robberies, heists, races, bounties, police work, businesses.
  - **Sinks:**
    - upgrades, ammo, repairs
    - impound, hospital, insurance and bail fees
    - garage expansion, cosmetics, heist gear
    - fees to lower your stars
  - **Transfers:**
    - mugging, carjacking, raids, pink slips
    - **player-placed bounties** (revenge becomes an economy)
    - **trading** in a safe two-sided window, where rare finishes and serials become a status economy like Adopt Me pets or MM2 knives
- **Progression:**
  - **Rep rank:** permanent and always climbing, shown above your head. It unlocks districts, weapons, garage space and cosmetics.
  - car mastery
  - sets and serials
  - **Prestige, "Go Legit" / "Retire":** cash out for a permanent income multiplier plus an exclusive badge, car or plate.
  - **Empire layer** (later): car wash, nightclub, tuning shop, dealership. Businesses earn passively and can be raided.
  - **Seasonal leaderboards:** Richest, Most Wanted, Best Garage, Top Crew, Fastest Racer, Top Cop.
- **Why it scales:** cars are cheap to add. Each week extends the top of the ladder with new cars, finishes, districts, heists and guns, the way Steal An Egg added a biome, an egg and a mutation each week.

### 3.12 Game theory, social design, live-ops, monetization, viral moments

**Game theory map:**

| Concept | Where it lives |
|---|---|
| Risk vs reward | Garage vs street; banked vs carried cash; star multipliers; pink slips |
| Loss aversion | Your cars are physically visible and stealable |
| Endowment | Your named garage; your customized car with a custom plate |
| Variable rewards | Rare spawns, finish rolls, trait rolls, crate contents, heist loot |
| Prisoner's dilemma | Crew loot splits and betrayal |
| Scramble competition | Everyone rushes the same armored truck or rare spawn |
| Deterrence | Visible defenses, crew presence, insurance and repo |
| Signaling and status | Rare cars, finishes, plates, Rep, showrooms, serials |
| Catch-up / anti-snowball | Bounties on leaders, a richest-player target, insurance, newbie protection |
| Goal gradient | Districts, levels and sets that are always "almost there" |
| Asymmetric roles | Criminal vs cop; driver, gunner, hacker |
| Reciprocity and alliances | Crews, defending friends, shared bonuses, gifting |
| Appointments | Offline earnings, timed events, daily contracts, weekly updates |
| Hot potato | Whoever carries the heist bag or truck loot is visible, slowed and hunted |

**Social design:**
- Every player is both a threat and an opportunity.
- Server-wide moments: rare spawns, trucks, bounty chases, 5★ rampages, Admin Abuse.
- Chases are shown on the minimap, so the whole server watches the drama.
- **Chatless communication:**
  - quick-chat callouts ("Need backup!", "Cops!", "Nice car!")
  - emotes
  - car horns
  - map pings
  - gifting
- garage visits and likes, plus a "best garage" leaderboard
- **photo mode and highlight moments**
- friend invites that reward both sides, and a bonus for playing together

**Live-ops:**
- **Weekly Saturday update:** 3–5 new cars, plus a finish or trait, plus a heist, district, event or weapon.
- **Admin Abuse about an hour before each update:**
  - Hypercar Rain
  - Police Strike (no cops for 15 minutes)
  - 10× Gold-paint luck
  - a Golden armored truck
  - everyone gets 5★
- **Seasons** of 6–8 weeks: a theme, a car pass and a city reskin (winter with snow drifting, summer beach, Halloween night city).
- Limited-time cars.
- Crossovers and collabs.

**Monetization ("fair, never pay-to-win at the core"):**
- **Passes:**
  - 2× Cash
  - VIP (bigger garage, longer lock, tag)
  - extra slots
  - better insurance
  - auto-collect
  - bigger favorite protection
- **Cosmetics:**
  - wraps, neon, horns, outfits, heist masks, plates
  - cosmetic-forward premium "hero" cars
- **Impulse buys at the moment of need:**
  - instant repair
  - bail out of jail
  - lose your stars
  - **extend your garage lock while it's being raided**
  - revive in a heist
  - double the payout on the results screen
- a season car pass
- crates only with odds shown
- prices fit Robux packs, with no fake timers

**Viral moments the design is built to produce:**
- *"Someone stole my max-level Rainbow hypercar"*, then a server-wide revenge chase
- *"1-in-10,000 Glitch finish"*
- *"I bet my best car in a pink-slip race"*
- *"My crew betrayed me after the bank heist"*
- *"How long can I survive at 5 stars?"*
- *"Day 1 vs Day 30 garage"*
- *"I raided the richest player in the server"*
- ragdoll and fling fails, ramming chaos, custom plate jokes
- Admin Abuse Hypercar Rain

**Safety:**
- non-graphic violence; no real gangs or drugs ("cartoon-heist energy")
- original IP
- server-authoritative money, damage, ownership and steals

### 3.13 Launch scope, title options and open questions

**What ships when:**

| Version | Scope |
|---|---|
| **Launch core** | steal → drive home → park → earn; rarities, finishes, upgrades and levels; garages with lock and raids; **carjacking**; wanted stars and AI police; **chop-shop order board**; **armored truck every 5 min**; **basic guns**; **crews with a friend bonus**; rare-spawn announcements; **insurance and repo**; daily rewards; offline earnings |
| Fast follow (weeks 1–4) | street races and pink slips, bank heist, jail and jailbreak, player bounties, trading, car customization, more districts |
| Later | player-cop faction, crew turf, businesses and empire, prestige, seasons, crossovers |

**Title options:**
- **"Steal a Car"** fits the title-is-the-rule layer.
- **"Heist City"** is a GTA-style city name.
- **"Steal a Car: Heist City"** is the combined name the user used.
- *Context from v1's own research: a "Steal A Car" by By Car Stealers already exists (Sep 2026, 31K peak, 21.7M visits), and there are about 3,300 "Steal a ___" clones.*

**Open questions** (asked of the user, never answered):
1. **Final title:** *Steal a Car* or *Heist City*?
2. **PvP model:** attackable anywhere with safe zones, or opt-in through a wanted/"criminal mode" like Jailbreak? The assistant's default: **attack anywhere except garages and spawn, 10 minutes of new-player protection, and bounties punish griefers.**
3. **Player cops** at launch or later? The assistant recommended later.
4. **Crew betrayal:** in or out? It's great drama, but possibly too harsh for younger players.
5. Earlier questions about team size, budget and a late-November ship date were answered with "don't worry about it" (§1.2).

---

## 4. Gap table: what that chat specified that Hotwire City v1 lacks or does differently

*Checked against `README.md`, `docs/SPEC.md`, `docs/integration/DECISIONS.md` and a grep of `src/` (Config/Economy, Cars, Rarity, Events, Police, Monetization).*

**What v1 already has from the brief:**
- **Core loop:** hotwire, drive home through a chase, garage $/s.
- **Garage theft:** a laser lock, owner alerts, newbie protection, recovery and revenge bonuses.
- **Collection:** 8 rarities plus 4 mutations, and a Car Index.
- **Police:** 1–5★ wanted with a chopper at 4★; busted → impound; spray shops.
- **Server events:** Hot Drop (a server-wide race), Cash Rain, Rush Hour, 2× Cash, Server Luck.
- **Retention:** offline earnings, a daily streak, contracts, playtime gifts, codes, referral, friend and group bonuses, rebirth, leaderboards.
- **World:** day/night and NPC traffic.

**Ranked gaps.** Ranking is by impact on **A**ddictiveness, **V**irality and **B**eauty.

| Rank | Gap (from the original brief) | v1 today | Impact | Why it matters |
|---|---|---|---|---|
| G1 | **"Garage = bank, street = casino":** street activities pay 3–10× garage income; taking your best car out is a real gamble | Owned cars driven out earn nothing extra and **can't be taken on the street** (owner-only seat). No street payout multiplier | A V | The user endorsed this as the central idea. Without it the loop is the "simple loop" they called boring |
| G2 | **Per-car level/XP and per-car upgrades** (engine, armor, nitro, tires, handling); value = rarity × finish × level × upgrades; **thieves keep the upgrades** | Upgrades are player-wide (Laser Lock, Hotwire Kit, Nitro Tank, Car Armor). No car levels or XP | A V | The user wrote this one themselves (U8, U9). It is the money sink that makes cars worth stealing |
| G3 | **A shared 5-minute clock:** armored truck every 5 min; chop-shop **order board** refreshing every 5 min; announced rare spawns every 10–15 min | Hot Drop every 6–9 min; Dealership restocks every 4 min; chop shop is a flat sell; contracts are daily | A V | Layer 6. Every record peak landed on a shared event |
| G4 | **Guns and ammo ladder** (pistol → SMG → shotgun → rifle), ammo sink, EMP and smoke; **Moderate** rating with ragdoll | **Mild:** Bonk Bat, Zapper, Spike Strips only. No guns, no "kill" | V A | **The user explicitly asked for "buy guns and ammo, kill peopel."** v1 traded this for the Mild label (ages 5–8). **This needs an explicit decision from the user** |
| G5 | **Theft and 5★ spectacle:** the thief appears on everyone's map with a bounty; 5★ triggers a server-wide bounty and periodic pings; payouts up to 3× at 5★; a "Longest at 5★" leaderboard | Theft goes to EventFeed plus the victim's waypoint. Stars only add police and cost | V A | Every theft becomes a server-wide chase. This is the main clip generator |
| G6 | **Crews (2–4)** with +10% per crewmate, a shared garage, colors and defense; **crew heists** with roles (driver, gunner, hacker, lookout) | Friends-in-server bonus only | A V | Co-play days are a ranking signal. The user asked to "party up with freidns or go solo" |
| G7 | **Heists:** bank heist every 30 min (prep → job (loud or stealth, vault mini-game) → getaway → split); also jewelry store, casino, cargo plane, armored convoy | Dealership "heist" (steal a showroom car) only | A V | Pays off upgrades. A session-scale goal |
| G8 | **"1 in X" rare reveals plus juice:** server-wide "1-in-5,000 Gold Hypercar" stampedes; slot-machine reveal; per-rarity stings; a wider finish ladder (Matte → Metallic → Chrome → Gold → Neon → Rainbow → Glitch/Void/Galaxy); **traits** | Hot Drop beacon and rarity tags exist. No "1 in X" anywhere in `src/`. 4 mutations, no traits | V B A | Layers 3 and 7. "1 in X" is the bragging unit |
| G9 | **Districts as soft progression gates** (Junkyard → Suburbs → Downtown → Beachfront → Hills → **Airport/Port**): better spawns with heavier police | Districts are visual only. Street rarity isn't district-weighted. No Hills or Airport endgame | A B | Shows the goal from minute one ("steal a Hypercar day one, can't escape") |
| G10 | **Robbing stores and mugging:** ATMs, gas stations and jewelry stores with skill-timed actions; **carried vs banked cash** | None. Single cash balance; busted costs 10% | A V | "rob people" (U6). The bank-or-push decision |
| G11 | **Loss softening:** insurance (~25%), repo mission on your stolen car, an unraidable **favorite slot** expandable with Rep | Recovery and revenge bonuses; offline garages can't be robbed; the only unstealable car is the paid Diamond Dragster | A | Turns a loss into a revenge arc instead of a reason to quit. Matters more once per-car upgrades (G2) exist |
| G12 | **Street racing and pink slips** (sprint, circuit, drag, drift, time trials) | Stunt Park only | V A | "The purest high-stakes moment"; gives upgrades a use beyond income |
| G13 | **Customization and flex:** wraps, rims, spoilers, underglow, horns, **custom license plates**; **garage showroom visits and likes**; Best Garage leaderboard; multi-floor garages and safehouses | Spray shop gives a random color. 12 slots in one garage. Leaderboards: totalEarned, steals | B V | Beauty and status; "Day 1 vs Day 30 garage" videos |
| G14 | **Living world:** weather that mutates cars (thunderstorm → Electric); rarer spawns at night with tougher cops; city events (police-radio blackout, parade, hourly supercar expo) | Day/night is visual. No weather. Events: Cash Rain, Rush Hour, 2× Cash | A B V | Server-wide variable rewards; Grow a Garden's weather was a key driver |
| G15 | **Live-ops framework:** Saturday update cadence; **Admin Abuse** an hour before (Hypercar Rain, Police Strike, 10× Gold luck, Golden truck, everyone 5★); Experience Events; seasons, car pass and city reskins; limited and serial cars | Admin chat commands exist (`/hc hotdrop`, `/hc event`). No scheduled live-event layer, seasons or pass | V A | Every record peak was an event day; the Halloween reskin gave an 8.5× spike |
| G16 | **Police depth:** roadblocks, SWAT, special units; **jail mini-game and jailbreak**; impound retrieval or break-out | Cruisers scale 1–6 units per star; chopper at 4★; busted → impound → release point | A V | Getting caught becomes content, not a timeout |
| G17 | **Contextual monetization at the moment of loss or desire:** extend the lock during a raid, bail, instant repair, double payout on results, starter pack, luck pass, auto-collect, insurance pass, season pass, gifting; prices at 99/199/399/799 | Store menu only (`PromptProductPurchase` in MenuController). Lockdown, Lose the Cops, cash packs, Server Luck, 5 passes, Diamond Dragster | Revenue, algorithm | Spend days are a ranking signal; an early cheap purchase matters |
| G18 | **Onboarding beats:** a hotwire **timing bar** skill moment; the first steal lights **1★ and a siren** for drama; the 10-minute unlock ladder (order board → free weapon → truck → raid alert → crew invite → rare spawn); like/group reward that skips early progress | Hold E 0.8 s; the first steal adds 0★ by design; tutorial is steal → deliver → collect → dealership | A V | The first-60-second bounce is a top ranking signal; the drama makes the clip |
| G19 | **Chatless social and sharing:** quick-chat callouts, emote wheel, map pings, gifting, photo mode or highlights, share links (`PromptLinkSharing`), Experience Events | Horn only (plus referral `ReferredByPlayerId`) | V | Most kids can't text-chat; share links pay 35% Creator Rewards |
| G20 | **Trading** (two-sided, anti-scam) plus **serial-numbered limited cars** | None | A | The MM2 and Adopt Me evergreen layer; days 8–28 retention |
| G21 | **Player-placed bounties and bounty hunting** | None | A V | Revenge becomes an economy |
| G22 | **Collection depth:** set bonuses ("all Muscle", "every Gold"), **car mastery**, limited-car gaps in the Index | Index with rarity-completion bonus | A | Goal gradient; collector FOMO |
| G23 | **Garage defenses:** reinforced doors, alarms, traps (spikes, oil slick, guard dog) | Laser lock plus owner tools | A V | Deterrence and showing off your base |
| G24 | **Productive trolling:** ramming knocks cash loose; ragdoll and fling physics on players | Bonk knockback, carjacked NPC ragdoll | V | Physics chaos is a rising lane with no 1M+ owner |
| G25 | **Title is the rule:** "Steal a Car" / "Heist City" | **"Hotwire City"** (tagline "Steal cars. Outrun the cops. Stack cash.") | V | Layer 1. "Hotwire" reads less instantly than "Steal a Car", but the "Steal A Car" name is already taken by a 31K game. Decide deliberately |
| G26 | **Small jobs:** timed deliveries, taxi rides with chaotic NPCs, stunt jumps, "lose the cops" challenges, repo jobs | Contracts include escapes and chops; a Stunt Park exists | A | Solo filler between server pulses |
| G27 | **Mascot or character fans adopt** | Meme cars (Rubber Ducky, Toilet Turbo, Couch Cruiser, Hotdog Wagon) | V | Could serve as mascots; no character exists |
| G28 | **Later systems:** player-cop faction, crew turf, businesses and empire, prestige "Go Legit" | Rebirth (≈ prestige) exists; the rest are missing | A | Fast-follow and later scope, per the original plan |

**Different by design (needs a decision, not necessarily a fix):**
- **Rating:**
  - The original brief chose **Moderate** (guns, ragdoll deaths, no blood).
  - v1 chose **Mild** (reaches ages 5–8).
  - The user's own words ask for guns and killing.
- **Rarity naming:**
  - The brief uses vehicle classes as tiers (Beater … Secret).
  - v1 uses Common … Secret, Exclusive, with meme cars.
  - Either works; v1's color and rarity mapping should still follow §2.6.
- **Offline garages:**
  - v1 makes them unrobbable.
  - The brief only said "mostly safe".
- **Servers:** v1 has 8 players, one garage each. The research recommends 6–10 for tycoons, so this matches.
- **New-game gate:** v1's RESEARCH.md says "250 unique plays"; this chat says "500 highly engaged + 1,000 R$ fee". Verify.

---

## 5. What the user disliked or ruled out

**Explicitly from the user:**
1. **A shallow loop.** *"a siple game loop like that would just gets borign. and weak and lame fast right? not really scable is it?"*
2. **Under-specified designs.** *"there is a lot more compelxiity adn concepts features game thoryt and more to this that we ignored left out are missing etc"*
3. **Letting constraints drive the choice.** *"do not worry about time… compelxity… how big team is or bueget or anythign else"*
4. **Implementation detail in the explanation.** *"dont go overly speific wiht hwo to build this. jsut evyerhign baout the game. hwo it works. expirnce. what it woudl have."*
5. **A conditional pivot.** *"we can picot off gta unless goign deeper into a real game is feasible and would actually go viral"*. GTA depth stays in only if it is feasible **and** viral.

The user ruled out **nothing** about violence or guns. They asked for them.

**Ruled out by the earlier assistant's research** (the user didn't object):
- **An exact GTA clone.** It scored ~55/105: no title rule, no 30-second action, no collectible, no shared clock.
- **Rockstar or GTA IP:** no "GTA", "Grand Theft", Vice City or Leonida names, no logos, no real car brands.
- **Realistic or heavy blood.** It would make the game 18+ only.
- **Open PvP with no protections.** Use spawn and garage safe zones, newbie protection and bounties on griefers.
- **Total-loss theft like Steal a Brainrot.** Use insurance, repo and a favorite slot.
- **Showing the depth before the hook.** Minute one is steal and park only.
- **Reward-for-watching feeds, fake timers, permanent sales, near-miss visuals on paid rolls, undisclosed odds, pay-to-win at the core, and "free Robux" claims.**
- **Copied code or assets, and clone-like metadata.**
- **Bolting complexity onto a sequel.** Grow a Garden 2 fell from 976K to 21K.
