# GTA-style gunplay and police combat: research and implementation spec

Date: 2026-10-27. Status: research complete, design proposed. Binding context: `docs/v2/research/00_LEAD_DIRECTION.md`. The user decided on grounded GTA V realism and GTA-style guns with no gore, at Moderate maturity (13+). A downed player gets **WASTED** and a hospital respawn; a caught player gets **BUSTED**.

Evidence images for this note are in `docs/v2/research/img_gta/`:

- `combat_guns_regole_ckc_candidates_2026-10-27.jpg`: realistic gun models (recommended set)
- `combat_guns_misc_candidates_2026-10-27.jpg`: other realistic gun candidates, with rips and scripted packs flagged
- `combat_roblox_weapons_kit_2019_2026-10-27.jpg`: Roblox's own Weapons Kit models
- `combat_melee_armor_candidates_2026-10-27.jpg`
- `combat_vest_accessories_2026-10-27.jpg`

GTA reference frames from another agent are in the same folder: `ref_gtawiki_WeaponWheel-GTAV.jpg`, `ref_gtawiki_Wasted-GTAV-EnhancedVersion.jpg` and `ref_gtawiki_Busted-GTAV.jpg`.

---

## 0. Decisions at a glance

1. **The rating stays Moderate with no blood at all.** Roblox defines Moderate as *"Non-graphic, realistic-looking depictions of violence and/or death"*.
   - Comparable crime games are already rated Moderate with repeated/moderate violence: Mad City, ER:LC, Da Hood and Criminality (section 1.5).
   - We answer the questionnaire as Violence = Repeated/Moderate and Blood = None.
2. **Every gun is hitscan.** The client raycasts and the server validates with lag compensation.
   - Client detection plus server validation is the pattern Roblox's own Laser Tag tutorial teaches. The tutorial validates against *current* positions with tolerances and does **no** rewinding; the position-history rewind is our addition, taken from a DevForum proposal (section 2.1). *(Corrected in verification.)*
   - No FastCast, which is unmaintained, and no projectile physics.
   - Do **not** adopt Roblox's new Server Authority model for v2. It requires `StreamingEnabled=true`, NextGenerationReplication, the Input Action System for player scripts and fixed simulation. Our place runs `StreamingEnabled=false`, and cars are client-owned physics.
3. **Launch roster: 11 weapons plus 2 gadgets.**
   - 3 melee, 2 handguns, 2 SMGs, 1 pump shotgun and 3 rifles, all with parody names.
   - The existing Zapper (taser) and Spike Strip become gadgets, restyled realistically.
   - No explosives in v2; the user listed pistols, SMGs, rifles, shotguns and melee.
4. **Gun models:** use the Regole_CKC set as v2 placeholders. It is script-free, textured and realistic, at 8k–50k tris (section 12.1). Provenance is a risk: some of this creator's uploads are named after commercial games. Plan replacements from our Blender pipeline (task #8) before monetized launch.
5. **Animations:** only animations owned by Roblox or by our experience owner can play.
   - Six Roblox-owned third-person gun animations exist and are verified (section 12.3). They are good enough for the first playable build.
   - A custom set of about 22 animations must be authored under the experience owner for GTA quality.
6. **Audio:** use the Roblox-licensed SFX library, which comes from the Pro Sound Effects and Audioscape partner uploads, plus the Weapons Kit audio.
   - Pro Sound Effects picks were checked by waveform: single shot versus burst, and reverb tail length.
   - Layer each gun as a close shot, a distant tail and mechanical foley, GTA-style.
7. **Health and armor:**
   - Health 100 and armor 100; armor absorbs damage first.
   - Health regenerates to 50% only, GTA V style. The garage heals fully. Med kits are a consumable.
8. **Death:** at 0 HP the player goes straight to WASTED: ragdoll with no joint breaking, then a hospital respawn after 5 s with a hospital bill.
   - No Da Hood-style "knocked + stomp" state.
   - A death caused by damage while wanted is WASTED, not BUSTED.
   - A reset or other undamaged death while wanted stays BUSTED; this is the existing anti-exploit rule.
9. **Police escalate GTA-style, tuned so the game is not oppressive:**
   - 1★ arrests only.
   - 2★ shoots only at an armed suspect.
   - 3★ is lethal and adds roadblocks.
   - 4★ adds the helicopter, with a sniper who telegraphs each shot with a laser, and spike strips.
   - 5★ adds a SWAT van and relentless ramming.
   - A per-target DPS budget, warning-shot misses, reaction delays and a low-health mercy window keep fights survivable.
10. **PvP for a fun 13+ server:**
    - Spawn protection, safe zones (garages, shops, hospital) and a GTA-style passive mode with cooldowns.
    - 30-minute rookie protection.
    - Revenge immunity against spawn-campers, and a "Menace" status that gives serial griefers wanted stars plus a bounty.
    - No cash reward for killing players who are not wanted.
    - Bounties are zero-sum, paid out of the target's own cash, so alt accounts cannot farm them.
11. **Controls:**
    - GTA over-the-shoulder camera, plus a weapon wheel: hold Tab, hold LB, or tap the weapon icon on mobile.
    - Mobile and gamepad get GTA "Assisted Aim" style lock-on against NPC cops, but only friction and magnetism against players. This NPC/player split is our own design. GTA Online instead separates players into lobbies by targeting mode. *(Corrected in verification.)*

---

## 1. Policy: what Roblox allows at Moderate (verbatim)

### 1.1 Maturity label rules
Source: <https://create.roblox.com/docs/production/promotion/content-maturity>, fetched 2026-10-27.

- **Minimal:** "May contain occasional mild violence and/or light unrealistic blood."
- **Mild:** "May contain repeated mild violence, heavy unrealistic blood, mild fear-based content, and/or mild crude humor."
- **Moderate:** "May contain moderate violence, light realistic blood, moderate fear-based content," … "moderate crude humor, and/or unplayable gambling content."
- **Restricted:** "May contain strong violence, heavy realistic blood, moderate crude humor, romantic themes," … "unplayable gambling content, the presence of alcohol, and/or strong language."

### 1.2 Violence intensity (questionnaire table)
- **Mild:** "Implied or unrealistic depictions of violence, such as bodies disappearing the moment their health reaches zero."
- **Moderate:** "Non-graphic, realistic-looking depictions of violence and/or death that don't violate Roblox Community Standards," … "such as realistic depictions of real-life injuries."
- **Restricted:** "Graphic and realistic-looking depictions of violence and/or death that do not violate the Age-Restricted Content Policy," … "such as non-real world beheadings/decapitation, impalement, hangings, dismemberment, mutilation,"
  - "Games with strong violence are only available to age-verified players that are at least 18 years old."

### 1.3 Blood
- **Unrealistic:** "Blood appears unrealistic, such as being pixelated or having a different color or shape."
- **Realistic:** "Blood appears realistic, such as having the same color, shape, and splatter properties as blood in the real world."
- **Light:** "The bloodshed is minimal, such as blood spatter from a distance."
- **Heavy:** "The bloodshed is significant, such as pools of blood, gushing blood, and up-close blood spatter."
  - "Games with heavy, realistic blood are only available to age-verified players that are at least 18 years old."

### 1.4 Community Standards
Source: <https://about.roblox.com/community-standards>.

- **Violent Content and Gore:** "Although some games on Roblox may include weapons and violence," Roblox does "not allow content that contains extreme violence or serious physical or psychological abuse, including:"
  - "Depicting or glorifying human, animal, or fictional creature abuse and torture"
  - "Realistic or real-world depictions of extreme gore, graphic violence, or death"
- **Illegal and Regulated Goods and Activities:** "Realistic modern firearms outside of in-game items." In-game guns are therefore allowed. Never sell, link or encourage real guns.
- **Real-World Sensitive Events:** content that "recreates or imitates real-world sensitive events" is prohibited, including "Acts of mass violence against people or property" and "Sensational crimes". There must be no school, church or mall shooting scenarios and no references to real incidents.

### 1.5 How comparable games are rated
Source: the public age-recommendation endpoint `POST apis.roblox.com/experience-guidelines-api/experience-guidelines/get-age-recommendation`, queried 2026-10-27.

| Game (universe) | Label | Descriptors |
|---|---|---|
| Mad City (498490399) | Moderate | Violence Repeated/Moderate; Gambling (unplayable) |
| ER:LC (903807016) | Moderate | Violence Repeated/Moderate |
| Da Hood (1008451066) | Moderate | Violence Repeated/Moderate; Blood Light/Unrealistic |
| Criminality (1494262959) | Moderate | Violence Repeated/Moderate; Blood Light/Realistic |
| Frontlines (2132866904) | Moderate | Violence Repeated/Moderate; Blood Light/Realistic |
| Jailbreak (245662005) | Mild | Violence Repeated/Mild |
| Southwest Florida (1769712451) | Mild | Violence Repeated/Mild; Crude Humor Mild |
| Arsenal, Phantom Forces, Rivals | Mild | Violence Repeated/Mild |
| Bad Business (1168263273) | Mild | Blood Light/Unrealistic; Violence Repeated/Mild |
| Greenville (371263894) | Minimal | — |

Audience *(corrected in verification; the 2024 ESRB/TechCrunch model below is superseded)*: Roblox now has three account tiers: **Roblox Kids (5–8)**, **Roblox Select (9–15)** and **standard Roblox (16+)**.
- Moderate games are eligible for Select and standard Roblox. Minimal and Mild games can also reach Kids.
- A new game starts in a trial phase visible only to **age-checked users 16+**.
- It reaches Select (our 13–15 players) only after evaluation. Evaluation needs:
  - an age-checked creator account, ID-verified (government ID for creators 18+);
  - 2-Step Verification;
  - a refundable per-game publishing fee, or an active Plus/Premium subscription at least 2 months old;
  - **250 unique plays from highly engaged players within 60 days**, plus a safety review.
- An optional expedited review costs a refundable 50,000 Robux.
- Sources: <https://create.roblox.com/docs/production/promotion/content-maturity> and <https://create.roblox.com/docs/production/publishing/kids-and-select>, both fetched 2026-10-27.
- Superseded sources: ESRB "What parents need to know about Roblox" and TechCrunch 2024-11-18.

### 1.6 Our compliance rules (binding for implementation)

**Do:**
- Use realistic humans and guns.
- Ragdoll on death, with joints kept intact.
- Show impact dust and sparks on world surfaces and cars.
- On a character hit, show a small grey cloth puff and play a "thwack" SFX.
- Use desaturated WASTED and BUSTED screens.
- Remove downed NPC bodies after 6 s with a quick fade.

**Don't:**
- Any red particle or decal on characters, blood pools, or wound decals.
- Limb loss or `BreakJointsOnDeath=true`.
- Executions, stomps or finishers on downed bodies (this rejects Da Hood's stomp).
- Kill counters or leaderboards for police or civilian kills. Track "bounties claimed" and "escapes" instead.
- Torture or hostage mechanics.
- Real brand names: no Glock, Beretta, HK or Colt in UI text. Retexture or remove visible engravings; for example, the USP model has a "USP45" engraving.
- Real-world event recreations.

**Questionnaire:** Violence: Yes, Repeated, Moderate. Blood: No. Re-submit it the day guns ship.

---

## 2. How top Roblox shooters build guns (research synthesis)

### 2.1 Hit detection and netcode
- **Roblox's official pattern is client detection with server validation.** The Laser Tag curriculum's "Detect hits" chapter (<https://create.roblox.com/docs/tutorials/curriculums/gameplay-scripting/detect-hits>) casts rays on the client and sends them in a RemoteEvent. The server validates them in `getValidatedBlastData`, then `getValidatedRayResults`, in four checks:
  1. type-check the payload (`validateRayResult`);
  2. check the claimed direction's angle against the server's own recomputed spread, within a tolerance (`isRayAngleFromOriginValid`, `BLAST_ANGLE_SANITY_CHECK_TOLERANCE_DEGREES`);
  3. check that the shooter is near the origin and the victim is near the destination (`DISTANCE_SANITY_CHECK_TOLERANCE_STUDS`);
  4. check whether the path is obstructed (`isRayPathObstructed`), so "if a malicious player were to systematically remove all walls … the server would check and confirm that the rays are invalid."

  The tutorial adds: "No anti-exploit strategy is comprehensive…"
- **Roblox Game Security article** (<https://developer.roblox.com/articles/Game-Security>): the client "should instead tell the server the origin position of the shot and the part/position it thinks it has hit", and "extra tolerance will need to be applied" for latency. *(Verification: this URL now redirects to the Security tactics page, which does not contain these sentences, so the quotes cannot be re-checked. Treat them as from the archived legacy article.)*
- **Security tactics doc** (<https://create.roblox.com/docs/scripting/security/security-tactics>): exploiters can "Fire or invoke RemoteEvents and RemoteFunctions at any frequency with arbitrary arguments". Every number, rate and instance in the shot packet is therefore untrusted.
- **Lag compensation by position history.** A DevForum proposal (<https://devforum.roblox.com/t/projectile-lag-compensation/672468>): store every player's part positions at an interval, roll back by the shooter's ping, compare the claimed hit against the stored positions, and raycast to check for walls. We adopt this pattern: an `HitboxHistory` ring buffer at 20 Hz.
- **Server Authority (2026)** (<https://create.roblox.com/docs/projects/server-authority>; newsroom <https://about.roblox.com/newsroom/2026/07/creating-responsive-cheat-resistant-games-roblox-server-authority>): client prediction plus rollback, with `RunService:BindToSimulation`.
  - Setup requires `Workspace.AuthorityMode=Server`, `NextGenerationReplication`, `PlayerScriptsUseInputActionSystem`, `SignalBehavior=Deferred`, `UseFixedSimulation` and `StreamingEnabled`.
  - `default.project.json` has `StreamingEnabled: false`, and our cars rely on client network ownership. **Verdict: not for v2.** Revisit when the world moves to streaming.
- **Projectiles.** A DevForum thread (<https://devforum.roblox.com/t/alternatives-to-fastcast/2630169>, 2023-10-04, 3 posts) has its asker saying "the creator of fastcast left roblox, it will no longer maintain updates". The one reply recommends "the good ole' reliable built-in raycast". *(Corrected in verification: the earlier quote "stuff like bullets often don't need to be projectiles…" is not in that thread.)* GTA bullets are effectively instant. **Hitscan everything**; tracers are cosmetic.

### 2.2 Roblox Weapons Kit conventions
Source: <https://create.roblox.com/docs/resources/weapons-kit>.

- Configuration values we mirror by name: `AmmoCapacity`, `ShotCooldown`, `FireMode` (Semiautomatic/Automatic/Burst), `FullDamageDistance`, `ZeroDamageDistance`, `MinSpread`/`MaxSpread`, `NumProjectiles`, `RecoilMin`/`RecoilMax`/`RecoilDecay`/`TotalRecoilMax`, `StartupTime`.
  - `StartupTime` is the "Length of time after equipping the weapon before the player can shoot. This prevents players from firing a single shot from multiple different weapons in quick succession."
- It ships an over-the-shoulder **ShoulderCamera**, separate `SmallTouchscreen` and `LargeTouchscreen` Aim/Fire button frames, a hit marker, **directional damage indicators**, and sprint plus zoom-slow-walk.
- Real kit tuning, extracted from the original Roblox-owned models with Lune:

  | Kit weapon | HitDamage | ShotCooldown | Mag | Notes |
  |---|---|---|---|---|
  | Pistol | 20 | 0.2 | 10 | |
  | AR | 14 | 0.125 | 30 | Automatic, MaxSpread 0.6 |
  | SMG | 9 | 0.05 | 30 | |
  | Shotgun | 20×5 pellets | 0.4 | 5 | FullDamage 25 / ZeroDamage 250 studs |
  | Sniper | 100 | 1.5 | 5 | ZoomFactor 4.5 |

  These confirm Roblox-scale damage and fire-rate numbers.

### 2.3 Aim assist and targeting
- **GTA V** (Rockstar, via <https://mp1st.com/news/grand-theft-auto-5-rockstar-on-weapon-handling-and-customization>) has four targeting modes:
  - **Assisted Aim – Full:** "Lock-on targeting with a wide lock angle that allows for target switching".
  - **Assisted Aim – Partial:** "medium lock angle. The reticule slows down whenever it passes over a target".
  - **Free Aim – Assisted:** "Snap-lock targeting with a narrower lock-on angle".
  - **Free Aim.**

  Rockstar "removed hard lock … too disorientating", and every lock has a break timer.
- **Rivals (Roblox)** aim assist is described as "a light pull toward nearby targets plus a small slowdown as the crosshair passes over them, without locking onto anyone automatically" (<https://progameguides.com/roblox/roblox-rivals-controls-pc-controller-and-mobile-layouts/>). That is magnetism plus friction.
- **Our split:**
  - Against NPC cops: GTA "Assisted Aim – Partial" lock, a 2.5 s break timer, and target switching with a flick.
  - Against players: friction and magnetism only, for all inputs, so mouse users are not disadvantaged.

### 2.4 Health and downed conventions in Roblox crime games
- **Jailbreak:** constant health regen. Headshots do double damage. Wallbangs deal half damage. Police loadout is pistol + handcuffs + taser + spikes. Source: <https://jailbreak.fandom.com/wiki/Weapons>.
- **Da Hood:** near-zero health means "knocked"; downed players can be "stomped" or carried; armor is bought or found; a gun store sells weapons and ammo. Source: videogamer "How to stomp in Da Hood". We reject knock and stomp: it is a humiliation mechanic and pushes toward gratuitous violence.
- **GTA V:** regen to 50% in story mode; hospital bill on death; arrest loses ammo and armor. Source: <https://www.grandtheftwiki.com/Wanted_Level_in_GTA_V>.

### 2.5 GTA V wanted reference
Source: <https://www.grandtheftwiki.com/Wanted_Level_in_GTA_V>.

| ★ | GTA V response |
|---|---|
| 1 | Patrols chase and "try to arrest the player at gunpoint" |
| 2 | Backup, more aggressive driving, more shoot-to-kill |
| 3 | Officers in vests. Single-car roadblocks "open fire", sometimes with spike strips. A Police Maverick with carbine sharpshooters |
| 4 | NOOSE in SUVs with carbines, pump shotguns and tear gas. A second heli; rappelling. Heavier two-way roadblocks |
| 5 | A third heli. "All police vehicles pursue, fire on, and ram the player's vehicle" |

- **Search:**
  - During an active chase, the radar flashes red and blue and the stars are solid.
  - When police lose sight, the radar stops flashing, the stars flash, and officers show **vision cones**: "narrow for foot officers, moderate for ground vehicles, and wide for helicopters."
  - Re-entering an officer's view restarts the pursuit.
- **Evade times:** 30 / 45 / 60 / 75 / 90 s for 1 to 5 stars.
- **At 3★+:** "arrest is almost impossible. Police focus on killing the player."
- **Crimes:**

  | Stars | Crimes |
  |---|---|
  | 1★ | Discharging a firearm in public, attacking civilians, stealing a vehicle |
  | 2★ | Resisting or evading arrest |
  | 3★ | Attacking or killing an officer, shooting down an aircraft |

---

## 3. Current codebase audit

| File | What it does now | v2 verdict |
|---|---|---|
| `src/server/Systems/CombatService.luau` (1,521 lines) | Mild cartoon tools built from parts: Bonk Bat (pink/cyan neon), Zapper (orange sci-fi blaster, lime coils), Spike Strip (neon pink spikes). Stun + knockback + eject, `ToolAction(toolId, aim)`. Server raycast/spherecast, assault-heat rules, spawn and locked-garage protection | **Keep the logic, kill the visuals.** <br>• Keep `shouldAddAssaultHeat`, `isStealingFrom`, `countsAsThiefBonk`, the spike polling and `segmentCrossesStrip` (move the pure rules to `Shared/Combat/CrimeRules`). <br>• The bat becomes a WeaponService melee weapon. <br>• The Zapper becomes a realistic taser gadget, keeping the Zapper Pass. <br>• Spikes become a realistic strip mesh. <br>• All `COLORS.Pink/Cyan/Lime` builders are deleted (kill list). |
| `src/client/Controllers/CombatClient.luau` (978 lines) | Activation, BONK/ZAP round buttons with emoji icons (`🏏 ⚡ 📌`), cartoon spinning stars over stunned heads, knockback | **Keep:** knockback/stun freeze and the spikes button (restyled). <br>**Delete:** emoji buttons and spinning stars. Guns move to the new `WeaponClient`. |
| `src/server/Systems/WantedService.luau` (969 lines) | Stars 0–5; step decay (`DECAY_DELAY {15,20,25,32,40}` then one star per `DECAY_STEP` 10 s); spray shop works only when unseen; BUSTED; died-while-wanted equals a bust; confetti and emoji toasts | **Change:** GTA all-at-once evade plus search area (section 9.4); WASTED versus BUSTED classification (section 7); new heat reasons (section 9.5); remove confetti and emoji (`😎 ESCAPED`, `🚨`). |
| `src/server/Systems/PoliceService.luau` (2,409 lines) | Physical cruisers with pursuit AI, roles, rubber-banding, cartoon heli with searchlight (`HELI_AT_STARS=4`), bust ring, visual-only BUSTED officer; `isSeen` is "any unit has LOS" | **Keep** the driving AI. **Add:** officer exit/on-foot, firing via a new `PoliceCombatService`, vision cones, last known position, roadblocks, SWAT, heli sniper. Replace the cartoon heli model (realistic heli, in the vehicles research). |
| `src/server/Systems/NPCService.luau` | Peds never die (Mild); `ejectComic`; `_ragdoll` helper exists; officer only as a BUSTED prop | Officers and peds can be downed (ragdoll, fade after 6 s). On-foot armed officers. Peds flee or cower on gunfire. Witness queries. Rename `ejectComic` to `eject`. |
| `src/shared/Net.luau` / `Remotes.luau` | Reliable RemoteEvents only, with a per-player token bucket | Add an `UnreliableRemoteEvent` list for cosmetic shot FX (section 10.6). |
| `src/shared/Config/Economy.luau` | Early cars earn $3–7/s; mid-game cars $55–75/s; late-game cars $220–320/s each, across 4–12 slots. Starting cash $150 | The weapon price curve is pinned to this (section 5). |

---

## 4. Weapons roster and stats

### 4.1 Roster (launch)
Parody names, in GTA's own register. The manufacturer brands are ours: "Kessler Arms", "Brandt & Sons", "Coastline Tactical" and "Volk". The real-world basis is internal only and is never shown in the UI.

| Id | In-game name | Class / wheel slot | Model basis (internal) | Fire mode | Unlock |
|---|---|---|---|---|---|
| `fists` | Fists | Melee | — | melee | always |
| `bat` | Slugger Bat | Melee | wooden bat | melee | free (replaces Bonk Bat) |
| `crowbar` | Pry Bar | Melee | crowbar | melee | $750 |
| `knuckles` | Knuckle Dusters | Melee | brass knuckles | melee | $500 |
| `pistol` | Kessler P9 | Handgun | Beretta 92-type | semi | $1,200 |
| `handcannon` | Brandt .50 "Hand Cannon" | Handgun | Desert Eagle-type | semi | $9,500 |
| `microsmg` | Volk Micro SMG | SMG | Micro Uzi-type | auto | $6,000 |
| `tacsmg` | Brandt Tactical SMG | SMG | MP5-type | auto | $24,000 |
| `pump` | Coastline Pump Shotgun | Shotgun | Mossberg 590-type | pump | $15,000 |
| `comrade` | Volk "Comrade" Assault Rifle | Rifle | AK-type | auto | $55,000 |
| `carbine` | Coastline Carbine Rifle | Rifle | M4-type | auto | $85,000 |
| `marksman` | Volk Marksman Rifle | Rifle (scoped) | SVD-type | semi | $250,000 |
| `taser` (gadget) | Kessler Stun Gun | Gadget | taser | single | existing $15,000 / Zapper Pass |
| `spikes` (gadget) | Stinger Strip | Gadget | spike strip | drop | existing $6,000 |

Police-only weapons, used in AI loadouts and never sold: nightstick, pistol, pump, carbine and marksman (heli).

### 4.2 Stats

Health is 100 and armor is up to 100. Ranges are in studs: an R15 character is about 5.2 studs tall, so 1 stud is roughly 0.35 m.

| Id | Dmg | Head× | RPM | Mag | Reload s | Hip / Aim spread° | Bloom max° | Full → zero range | Min mult | Max range | Reserve cap | TTK vs 100 HP (no armor) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fists | 10 | 1.0 | 130 | — | — | reach 4.5 | — | — | — | 4.5 | — | 10 hits |
| bat | 30 | 1.0 | 75 | — | — | reach 7 | — | — | — | 7 | — | 4 hits / 2.4 s |
| crowbar | 28 | 1.0 | 92 | — | — | reach 6.5 | — | — | — | 6.5 | — | 4 hits / 2.0 s |
| knuckles | 18 | 1.0 | 133 | — | — | reach 4.5 | — | — | — | 4.5 | — | 6 hits / 2.3 s |
| pistol | 25 | 1.6 | 360 | 12 | 1.4 | 1.2 / 0.4 | 3.0 | 70 → 180 | 0.6 | 250 | 240 | 4 body / 0.50 s |
| handcannon | 50 | 1.5 | 140 | 7 | 1.8 | 2.0 / 0.5 | 4.5 | 80 → 200 | 0.6 | 260 | 84 | 2 body / 0.43 s |
| microsmg | 11 | 1.4 | 900 | 32 | 1.6 | 3.0 / 1.6 | 5.5 | 30 → 90 | 0.5 | 160 | 320 | 10 body / 0.60 s |
| tacsmg | 14 | 1.4 | 780 | 30 | 1.9 | 2.2 / 0.8 | 4.0 | 45 → 130 | 0.55 | 220 | 300 | 8 body / 0.54 s |
| pump | 8 × 11 | 1.2 / pellet | 70 | 8 (per shell, 0.45 s) | — | 5.5 / 4.0 (fixed pattern) | — | 12 → 45 | 0.15 | 70 | 64 | 2 blasts close / 0.86 s |
| comrade | 20 | 1.5 | 600 | 30 | 2.3 | 1.8 / 0.6 | 4.0 | 100 → 260 | 0.6 | 400 | 300 | 5 body / 0.40 s |
| carbine | 18 | 1.5 | 700 | 30 | 2.1 | 1.4 / 0.4 | 3.0 | 110 → 280 | 0.6 | 420 | 300 | 6 body / 0.43 s |
| marksman | 60 | 2.0 | 75 | 10 | 2.6 | 3.0 / 0.0 (scoped) | — | no falloff | 1.0 | 900 | 60 | head 1 / body 2 / 0.80 s |

Design rules behind the numbers:

- **Minimum PvP time-to-kill is about 0.4 s against an unarmored target** for everything except a marksman headshot. Against full armor it doubles to about 0.8 s, which gives time to react.
- **No one-shot close-range kills.** The pump needs two blasts. This is friendlier for 13+ than GTA's one-shot pump.
- **Body-part multipliers:** head ×Head (from the table), torso ×1.0, limbs ×0.75.
- **Inside vehicles:** occupants hit through glass take ×0.7. A ray that hits the car body damages the car instead (section 10.5).

### 4.3 Damage model (pure, `Shared/Combat/DamageModel.luau`)

```
falloff(d)  = lerp(1, minMult, clamp((d - full) / (zero - full), 0, 1))   -- 1 inside full, minMult at/after zero
raw         = dmg * partMult * falloff(d) * (occupant and 0.7 or 1)
armorTaken  = min(armor, raw)            -- armor absorbs 100 % first (GTA)
healthTaken = raw - armorTaken
regen       : after 6 s without damage, +4 HP/s up to 50 (never above 50); garage: +25 HP/s to 100
```

Floor the result to integers at the end so the HUD never shows fractions.

### 4.4 Recoil, spread and aim
- **Spread:** `spread = clamp(base + bloomPerShot * recentShots, base, bloomMax)`, then multiplied by:
  - ×0.4 to ×0.3 while aiming (the Aim column);
  - ×1.5 while moving;
  - ×1.8 while sprinting;
  - ×2.5 while in the air.

  Bloom recovers at 6°/s after 0.15 s without firing.
- **Recoil (camera kick per shot):**
  - Pitch: Uniform(RecoilMin, RecoilMax) in degrees. Pistol 1.2–1.6, hand cannon 3.0–3.8, micro SMG 0.35–0.5 (yaw ±0.6), tactical SMG 0.3–0.45, comrade 0.6–0.85 (yaw ±0.35), carbine 0.4–0.6, pump 3.5–4.5, marksman 4–5.
  - Recovery is exponential, at about 0.82 per 1/60 s, which is the kit's `RecoilDecay` feel. Recoil accumulates up to `TotalRecoilMax` = 3 × RecoilMax.
  - Mobile gets ×0.6 recoil. Thumb aiming cannot counter-pull.
- **Aim (GTA style, not iron sights):**
  - Field of view 70° hip-fire, 52° aiming with handguns and SMGs, 48° aiming with rifles, 70° → 75° sprinting.
  - The marksman rifle uses a scope overlay at 15°, with 0.3° idle sway. Holding breath (Shift) removes sway for 3 s.
- **Swaps:** weapon swap 0.35 s (handguns) to 0.5 s (rifles). `StartupTime` is the same as the draw time: you cannot fire before the draw finishes.
- **Firing on the move:** hip-fire while running is allowed with the spread penalty. Sprint cancels aiming.

### 4.5 Reload and ammo behaviour
- Manual reload is R, X on gamepad, or the mobile button. Reload is automatic when the magazine is empty.
- Shotgun reload is per shell and interruptible by firing.
- An empty-magazine reload takes 0.3 s longer than a tactical reload.
- The server is the authority on magazine and reserve ammo (section 10.4). The client predicts and resyncs from `AmmoState`.
- The weapon wheel shows `reserve / mag`, as GTA's wheel does: "386 / 12".

### 4.6 Config schema (`src/shared/Config/Weapons.luau`)

```lua
export type WeaponDef = {
  id: string, name: string, class: "Melee" | "Handgun" | "SMG" | "Shotgun" | "Rifle" | "Gadget",
  price: number, ammoPrice: number?, ammoPerPurchase: number?, reserveCap: number?,
  fireMode: "Semi" | "Auto" | "Pump" | "Melee", rpm: number, mag: number?, reloadTime: number?, perShellReload: number?,
  damage: number, pellets: number?, headMult: number, limbMult: number,
  fullDist: number?, zeroDist: number?, minMult: number?, maxRange: number,
  spreadHip: number, spreadAim: number, bloomPerShot: number?, bloomMax: number?,
  recoil: { pitchMin: number, pitchMax: number, yaw: number }, aimFov: number, scoped: boolean?,
  drawTime: number, meleeReach: number?, meleeArc: number?,
  asset: { modelId: number, grip: CFrame, muzzle: Vector3, scale: number }, -- placeholder until our own meshes
  anims: { idle: string, aim: string, fire: string, reload: string, equip: string }, -- keys into Config/Animations
  sounds: { shot: { string }, tail: { string }, mech: { string }, reload: { string } }, -- keys into Config/Sounds
  wheelSlot: number, policeOnly: boolean?,
}
```

---

## 5. Shop, ammo economy, armor and tints

### 5.1 The store

**Brand.** Use our own parody, not "Ammu-Nation", which is a Rockstar trademark. The recommendation is **"FREEDOM ARMS: Guns & Ammo"** (tagline "Protect what's yours. Twice."). The alternative is "Bullet Barn". Two locations: downtown and the industrial zone, at `MapLayout` POIs `GunStoreA` and `GunStoreB`.

**Interior.**
- A counter with a clerk; `NPCService` shopkeepers already exist.
- Wall racks, glass display cases, and a practice range lane behind glass, which is a phase 2 item.
- The interior is a **safe zone**: weapons are holstered and no damage is possible.

**UI (GTA list-menu language).**
- Left: a dark translucent panel listing categories, then weapons.
- Right: a ViewportFrame with a rotating model, a stat bar for each of Damage, Fire Rate, Accuracy, Range and Clip, and the price.
- Buttons: BUY, AMMO (+1 magazine), FULL AMMO, ARMOR and TINT.
- Condensed sans font, never FredokaOne.

**Purchase validation (server, ShopService).** The server checks all of the following before charging:
- the player is inside the store's zone volume;
- the item is not already owned, and the reserve is not at its cap;
- `DataService.spendCash` succeeds.

### 5.2 Prices vs our economy

| Item | Price | Rationale |
|---|---|---|
| Kessler P9 | $1,200 | About 4–6 min of early income. First gun inside the first session |
| Knuckles / Pry Bar | $500 / $750 | Early impulse buys |
| Micro SMG | $6,000 | Early to mid game |
| Hand Cannon | $9,500 | |
| Pump | $15,000 | Mid game (2–3 Uncommon cars) |
| Tactical SMG | $24,000 | |
| Comrade AR | $55,000 | About the price of an Epic car |
| Carbine | $85,000 | |
| Marksman | $250,000 | Late game |
| Light armor (+50) | $750 | Consumable; lost on WASTED or BUSTED |
| Heavy armor (+100) | $1,800 | |
| Med kit (+40 HP over 1.5 s, carry 3) | $400 | Cannot use within 1 s of taking damage |

**Ammo per magazine (or box):**

| Weapon | Ammo price |
|---|---|
| P9 | $36 / 12 |
| Hand Cannon | $70 / 7 |
| Micro SMG | $64 / 32 |
| Tactical SMG | $75 / 30 |
| Pump | $80 / 8 shells |
| Comrade / Carbine | $120 / 30 |
| Marksman | $250 / 10 |

**Rules:**
- Each purchase of a gun includes 2 free magazines.
- **Ammo sustain:** a downed police officer drops an ammo pickup for the player's current weapon class (1 magazine, despawns after 20 s), GTA style. This makes big chases self-sustaining without a cash grant.
- Downed players and pedestrians drop **nothing**, so there is no kill-farming loop.
- Ammo stays a soft sink at every stage; prices do not scale with income. A late-game player will not notice it, but GTA's ammo is also trivial late on. The real late-game sinks stay cars, slots and rebirth.

### 5.3 Monetization (no pay-to-win)
- **Weapon tints:** cosmetic material/colour swaps, GTA-style.
  - Black (default), Army green, Desert tan, Gunmetal, Gold, Platinum, Carbon.
  - Pink and neon tints are excluded (kill list).
  - Prices: $25k cash for basic tints; gold and platinum via Robux developer products, or $2M cash.
- **Never sold for Robux:** damage, magazine size, armor above 100, faster reload, or exclusive guns.
- The existing **Zapper Pass** (half taser cooldown) is grandfathered. It is non-lethal utility.

---

## 6. Health, armor and healing (`DamageService`)

| Parameter | Value |
|---|---|
| Max health / max armor | 100 / 100 |
| Regen | 6 s after the last damage, +4 HP/s, capped at 50 |
| Garage (own plot) | heal +25 HP/s to 100 after 3 s inside; not while "in combat" (section 8) |
| Hospital respawn | 100 HP, 0 armor |
| Default Roblox `Health` script | **Disabled.** Ship an empty `Health` Script in StarterCharacterScripts (Rojo mapping), otherwise the default script regenerates 1%/s |
| Fall damage | Optional, phase 2: above 40 studs of fall, 2 HP per stud over the threshold |
| Car hits a player above 40 studs/s | 25 damage + 1.5 s ragdoll knockdown; rookies and passive players are immune; counts toward Menace (section 8) |

**Authority.**
- The server keeps `health` and `armor` in its own table and writes `Humanoid.Health` from it.
- Client-side `Humanoid.Health` changes are ignored.
- Replicated player attributes: `Armor`, `InCombat`, `Protected` (until a server timestamp), `Passive`, `Rookie`, `Bounty`.

**Armor visual.** While armor is above 0, the player wears a plate-carrier front accessory applied through `HumanoidDescription` (section 12.2).

---

## 7. WASTED and BUSTED flows

### 7.1 Death classification (server, `DamageService.onDied`)

```
lastDamage = most recent damage record (source, weapon, time)
if lastDamage and now - lastDamage.time <= 10 s  -> WASTED   (any wanted level; stars cleared; theft fails like a bust)
else if wantedStars > 0 and not inOwnGarage       -> BUSTED   (existing reset-exploit rule, WantedService._onDied)
else                                              -> WASTED   (plain death: fall, drowning) - hospital, no bill if no damage source
```

### 7.2 WASTED

| t (s) | Server | Client (DeathScreenController) |
|---|---|---|
| 0 | `Humanoid.BreakJointsOnDeath=false`; the shared Ragdoll converts Motor6Ds to BallSocketConstraints with limits. Body parts stay attached. Stars are cleared. A Stolen car fails or goes home through the existing TheftService fail path. Armor is set to 0. | The camera detaches and orbits the body slowly (about 6°/s) at FOV 60. `ColorCorrection` saturation tweens to −1 and contrast to +0.15 over 0.4 s. Blur 2. Subtle film-grain image. A muffle EQ goes on the SFX group (HighGain −30 dB). |
| 0.6 | — | A full-width dark translucent band (45% opacity) at 42% screen height. Lowercase "wasted" in deep red (#B3121F) in the heavy display font from the UI research note, slamming from scale 1.1 to 1.0. Below it, small condensed text: "Downed by <DisplayName>", or "Downed by the police" or "Downed". Sound: a low whoosh plus a body-fall thud. |
| 4.0 | — | Fade to black over 0.6 s. |
| 5.0 | `Players.RespawnTime = 5`. `PlotService` spawns the player at the nearest hospital (new `MapLayout.hospitalCFrame(pos)`; 2 hospitals), unless a garage respawn is preferred (setting, phase 2). Hospital bill: `min(5% cash, 120 s income)`, free for rookies. Spawn protection for 6 s. | Fade in over 0.5 s. A small top-left notification: "Hospital bill −$X". A faint shimmer on the character while protected. |

### 7.3 BUSTED
The trigger is the existing `PoliceService.bustPass`: a suspect slowed down near a unit. New ways in:
- 1★ taser stun followed by proximity;
- **surrender** at 2★ or below: hold H, gamepad D-pad down, or the mobile SURRENDER button that appears when cops are within 40 studs.

The sequence:

1. Officer step-out. This is the existing `onBusted` / `NPCService.spawnOfficerAt`, now a real armed officer.
2. The player plays a hands-up, then kneel, animation (custom; section 12.3). The cuff SFX plays.
3. The client shows the same monochrome treatment with the band. The text is lowercase **"busted" in GTA blue (#4BA3D9)**, matching `ref_gtawiki_Busted-GTAV.jpg`.
4. The existing penalty stays: `min(10% cash, 600 s income)`, impound the car, release at Police HQ, 8 s heat grace.
5. New penalties: armor is set to 0, and **50% of the reserve ammo** of every weapon is lost. GTA takes all of it; we soften this.
6. A surrender halves the cash penalty, so giving up is a real choice.
7. Replace the cartoon `HUDController.showBusted` overlay (comic "BUSTED!" stamp, police lights, emoji car label) with this screen.

---

## 8. PvP rules for a fun 13+ server

| Rule | Spec |
|---|---|
| **No reward for murder** | Downing a player who is not wanted pays $0 and gives no XP or contract progress. Only defense, vigilante action and bounties pay. |
| **Spawn protection** | 6 s after any spawn, hospital or HQ release, or until the player fires first. Protected players can't take or deal player damage. Police do not fire on them. |
| **Safe zones** (server volumes from MapLayout) | Every garage plot (own plot always; others' plots follow the existing locked-garage rule), gun stores, dealership, spray shops, the hospital plaza (30-stud radius) and the Police HQ release area. Weapons auto-holster and can't be drawn; no damage in or out. **Entering while In Combat:** protection starts after 5 s inside, so running in does not instantly save you mid-fight. |
| **In Combat** | For 15 s after dealing or receiving player damage. Blocks: passive toggle, `GoHome` teleport (add to the existing remote's checks), and the garage heal. |
| **Passive mode** (GTA Online) | Toggled from the phone or interaction menu. While passive: immune to and unable to deal player damage; guns can't be drawn (melee only, against NPCs); can't steal player-owned cars (dealer and street cars only); a dove icon shows on the name tag and map. **Can't enable** while wanted, while In Combat, or while carrying a player-stolen car. **Re-enable cooldown:** 5 min after turning it off. Turning it off gives 10 s with weapons locked (GTA's 30 s, shortened). |
| **Rookie protection** | The first 30 min of total playtime: works like passive but automatic. Ends early if the rookie deals player damage, buys a rifle, or opts out. Coexists with the existing `NEWBIE_PROTECTION_CARS=3` theft rule. |
| **Revenge immunity** (anti spawn-camp) | If the same attacker downs you twice within 3 min, that attacker cannot damage you for 5 min, and you may enable passive immediately, bypassing the cooldown. |
| **Menace** (anti-grief, Bad Sport lite) | Downing 3 non-wanted players within 5 min, or 2 rookies or passive-adjacent targets, makes the attacker a Menace for 5 min: minimum 3★, an automatic bounty, and a red map marker visible to everyone. Repeat offences in one session extend it to 10 min. |
| **Bounties** (zero-sum) | Any player at 4★ or more carries a bounty of `min(10% of their cash, stars × 20 s of their income)`, **paid from the target's cash** to whoever downs them. Cops never claim it. A given (killer, target) pair pays at most once per 30 min (mirrors `BONUS_PAIR_COOLDOWN`). There are **no player-placed bounties** in v2: alt-account farming and harassment risk. |
| **Vigilante and defense** | Damaging a wanted player (1★ or more), a thief driving your car, or a raider inside your garage adds no heat. This is the existing `shouldAddAssaultHeat` logic, now used for all weapons. |
| **Vehicle PvP** | Shooting a player's car damages it (`VehicleService.damage(car, n, source)`). Shooting a wheel well pops a tire (existing `TiresPopped`). Cars parked in garages are invulnerable. A driver hit through glass takes ×0.7. Drive-by from the driver seat (pistol or micro SMG, sideways) is phase 2. |
| **Friendly fire** | On between everyone; no crews in v2. |

---

## 9. Police combat (`PoliceCombatService`, a new module alongside `PoliceService`)

### 9.1 Escalation per star
Unit counts follow the existing `UNITS_PER_STAR {1,2,3,4,6}`.

| ★ | Units | Lethal? | Officer weapons | Base accuracy | DPS budget vs one player | Specials |
|---|---|---|---|---|---|---|
| 1 | 1 cruiser | **No.** Arrest only | Taser (≤25 studs, 1.5 s stun, 4 s cooldown); pistol drawn but held | — | 0 | The suspect escalates to 2★ by firing a gun within 120 studs of a cop, or by aiming at an officer for 1.5 s or more within 40 studs. |
| 2 | 2 cruisers | **Only if the suspect is armed**: fired in the last 10 s or aimed at cops | Pistol | 0.25 | 8 | No shooting at cars moving faster than 20 studs/s; they ram instead (existing AI). |
| 3 | 3 cruisers + 1 roadblock | Yes | Pistol, pump; vests (+50 armor) | 0.32 | 14 | Passengers lean out and fire pistols from moving cruisers within 60 studs: car damage, plus a 10% chance per hit to pop a tire. Roadblock: 2 cruisers angled across the predicted route, with officers firing from behind the cars. |
| 4 | 4 cruisers + heli + roadblocks with spike strip | Yes | Carbine, pump | 0.38 | 20 | **Heli sniper:** a 1.2 s red laser telegraph (Beam) plus an audio cue, then a 35-damage shot every 4 s, only with line of sight from the heli. Counts toward the budget. |
| 5 | 6 units including a SWAT van (4 SWAT, armor 100, carbines) + 2 helis | Yes | Carbine | 0.45 | 28 | All units ram relentlessly (existing). SWAT deploy at the last known position and use cover points. |

### 9.2 Officer on-foot behaviour (state machine per officer)
States: `Seated → Exit → Cover → Engage → Advance → Arrest → Return`.

- **Exit.** Trigger: the suspect is on foot, or in a stopped car, within 60 studs of a stopped cruiser. The officer humanoid spawns at the driver door (`NPCService.spawnOfficerOnFoot(cframe, loadout)`).
- **Cover.** The point is chosen by priority:
  1. behind their own cruiser, on the far side from the suspect;
  2. the nearest `CoverPoint`-tagged part within 25 studs. MapBuilder tags planters, walls, dumpsters and parked cars.

  Peek-fire comes from cover.
- **Engage.** Fire only with LOS from head height and only when the firing director grants a shot (section 9.3). Officers never fire through or near (within 3 studs of the ray) a non-wanted player, a passive player, or a pedestrian.
- **Advance.** If the suspect has been out of LOS for more than 4 s, move toward the last known position along the sidewalk; Humanoid MoveTo works, and `NPCService` already steers pedestrians.
- **Arrest.** At 1–2★ with an unarmed suspect within 6 studs, start bust progress; the existing `BustProgress` ring is reused.
- **Downed.** At 0 HP the officer ragdolls, drops an ammo pickup and fades after 6 s; there is no body persistence. The existing manage pass respawns units out of view.
- **Budget.** At most 8 on-foot officers in total per server; the existing `NPCService.BUDGET` is extended with an `officerFoot` cap. Server-owned with `SetNetworkOwner(nil)`, steered at 4 Hz or less, matching the pedestrians.

### 9.3 Accuracy model and fairness (pure: `Shared/Combat/PoliceAim.luau`)

```
P(hit) = acc[stars] * fDist * fMotion * fCover * fVehicle * fMercy
fDist    = clamp(1 - (d - 20) / 180, 0.25, 1)
fMotion  = 1 / (1 + v / 25)            -- v = target speed (studs/s): sprint ~0.53, car at 60 ~0.29
fCover   = visible fraction (3 rays: head, torso, legs)
fVehicle = 0.7 when the target is in a car (and 60 % of "hits" strike the car body instead of the driver)
fMercy   = 0.5 for 4 s once per life when the target drops under 30 HP (GTA-style breather to escape)
```

Rules that keep it from being oppressive:
- **Reaction delay.** After acquiring line of sight: 0.8–1.2 s at 2–3★, 0.6 s at 4–5★.
- **Warning shots.** The first 2 shots at a newly acquired target always miss. They impact 2–4 studs away with a visible tracer and a near-miss whiz, so the player knows they are being shot at.
- **Firing director.** One per target: a token bucket that refills at `DPSbudget / averageShotDamage` shots/s. Officers request shots and only granted requests fire. Ten officers cannot stack damage beyond the star's budget.
- **Hold fire** on players who are protected, passive, rookie, surrendering, inside a safe zone, or within 5 s of a respawn or release.
- **No cover-ignoring snipes.** The heli sniper needs LOS and gives a 1.2 s laser telegraph. Breaking LOS (tunnels, parking garages, overpasses) cancels the shot.

### 9.4 Search and evasion (GTA V model, replaces step decay)

**Vision cones.** These are config constants; the client draws them on the minimap from the units' CFrames, so nothing extra is replicated.
- On-foot officer: 70° / 90 studs.
- Cruiser: 100° / 150 studs, plus 40 studs of 360° awareness (the existing `CLOSE_SEE_RANGE` is 60; reduce it).
- Heli: a ground circle of 110 studs (the existing `HELI_SIGHT`), requiring LOS.
- SWAT: 80° / 110 studs.

`isSeen` = the suspect is inside any cone with a clear line of sight.

**While seen:**
- Stars are solid and the minimap border flashes red and blue.
- `LastKnownPos` (LKP) updates and is published as a player attribute.

**While not seen:**
- Stars flash and unit cones show on the minimap.
- The minimap shows a translucent **search area** circle centred on the LKP, with radius {120, 160, 210, 260, 320} studs by star level.
- Units route to random points inside that circle.

**Evade timer.** The existing `DECAY_DELAY {15,20,25,32,40}` s is reused as the evade time. That is deliberately shorter than GTA's 30–90 s, for Roblox session pacing.
- The timer runs 1× inside the search area and **2× outside it**.
- Any sighting resets it.
- When it completes, **all stars clear at once**, GTA style, with a restrained "You evaded the police" notification top-left. No confetti and no emoji.

The spray shop keeps its existing unseen-only rule; it already matches GTA's Pay 'n' Spray.

### 9.5 Combat crimes → heat
Implemented in `Shared/Combat/CrimeRules`.

**Witnessed** means a pedestrian within 60 studs or a cop within 120 studs has line of sight to the offender. `NPCService.witnessesNear(pos, radius)` provides this.

| Crime | Heat |
|---|---|
| Firing a gun in public (witnessed) | Minimum 1★ |
| Aiming at an officer for 1.5 s or more within 40 studs | Minimum 1★, 2★ if already 1★ |
| Hitting a pedestrian | +1★ (pedestrians alone cap at 2★) |
| Downing a pedestrian | Minimum 2★ |
| Hitting an officer | Minimum 2★ |
| Downing an officer | Minimum 3★; +1★ for every 3 more officers downed |
| Damaging the heli | Minimum 4★ |
| Disabling the heli (1,500 HP; it limps away smoking and returns 45 s later) | 5★ |
| Hitting a non-wanted player outside the defense rules | +1★ (the existing `assault` heat, with its 5 s per-attacker cooldown) |
| Downing a non-wanted player | Minimum 2★, plus a Menace count |
| Vigilante or defense hits | 0 |

**Pedestrians:**
- They react to gunfire within 80 studs: 70% flee and 30% cower. The cower animation is custom; the flee logic exists as `_fleeDecision`.
- Downed pedestrians ragdoll and fade after 6 s.

---

## 10. Netcode and anti-cheat design

### 10.1 Shot protocol
Client to server, `WeaponFire`, reliable. Shots are **batched**: at most 20 packets/s and at most 4 shots per packet.

```lua
type ShotPacket = {
  w: string,            -- weapon id (<= 16 chars)
  t: number,            -- client Workspace:GetServerTimeNow() at trigger
  o: Vector3,           -- muzzle origin (client computes crosshair point by camera ray, then fires muzzle -> point)
  d: Vector3,           -- aim direction (unit, pre-spread)
  s: number,            -- integer spread seed (pellet directions = Ballistics.pellets(d, spread, s, n))
  h: { { p: BasePart?, x: Vector3, k: number } }?, -- claimed hits: part ref (nil = world), hit point, pellet index
}
```

### 10.2 Server validation pipeline
`WeaponService.onFire` runs these checks in order. Any failed check drops that shot's hits (or the whole packet) and adds an audit score.

1. **Shape.** Types, `Net.isFiniteVector`, a unit `d` (|d| between 0.98 and 1.02), and pellet indexes within range.
2. **State.** The player is alive. The weapon is owned **and equipped**: a Tool with `WeaponId` in the character, plus `drawTime` elapsed. Not reloading. Not in a safe zone, not passive or rookie when hitting players, not stunned.
3. **Rate.** A per-weapon token bucket with capacity 3 (semi) or 4 (auto), refilling at `rpm/60 × 1.1`, on top of `Net.on("WeaponFire", …, 25)`.
4. **Ammo.** The server magazine is above 0; decrement it. One shot uses one round regardless of pellets, as in the kit.
5. **Time.** `rewind = serverNow - t` must satisfy `-0.05 ≤ rewind ≤ min(0.35, 2 × player:GetNetworkPing() + 0.1)`, else the shot is rejected. A shot from the future, or a stale "time machine" claim, fails here.
6. **Origin.** `o` is within `6 + v × rewind` studs of the shooter's **rewound** head position (from `HitboxHistory`), and the segment from head to `o` is clear.
7. **Direction.**
   - Single-pellet weapons: the angle between `(x − o).Unit` and `d` is at most `bloomMax + 1.0°`.
   - Shotguns: the server regenerates the pellet directions from `s` (deterministic `Random.new(s)`), and each claimed pellet must sit within 1.5° of its regenerated direction.
   - `d` must be within 100° of the shooter's rewound facing direction: no shooting behind the back.
8. **Range.** `|x − o| ≤ maxRange`.
9. **Target.** For player and NPC hits, the claimed point must be within `3.5 + victimSpeed × 0.05 + 0.1 × victimSpeed × rewind` studs of the victim part's rewound position. The rewound position is the rewound root CFrame multiplied by the part's current offset from the root. Car occupants get +1.5 studs.
10. **Line of sight.** A server raycast from `o` to `x`, ignoring all characters and `Workspace.Effects`, with `RespectCanCollide=true`, must not hit anything before `|x − o| − 1`. This is the Laser Tag `isRayPathObstructed` check.
11. **Rules.** `DamageService.canDamage(attacker, victim)` applies protection, safe zones, passive, rookie, revenge immunity and spawn protection.
12. **Apply.** `DamageService.apply{victim, amount = DamageModel(...), source, weapon, part, pos, dir}`. Crime rules add heat. TheftService `onThiefHit` handles thief drops.
13. **Feedback.**
    - `HitConfirm(kind, pos)` goes to the shooter, where kind is body, head, armor or down.
    - `DamageTaken(fromPos, amount)` goes to the victim and drives the directional indicator.
    - `ShotFx` goes to nearby clients (section 10.6).

### 10.3 Lag compensation (`HitboxHistory`, server)
- Samples the root CFrame of every player character, on-foot officer and pedestrian within 400 studs of a player, and the chassis of every car, at 20 Hz on `Heartbeat`.
- Keeps a 1.0 s ring buffer per model, 20 entries. `sample(model, t)` linearly interpolates the position and slerps the rotation.
- Cost at 30 players + 8 officers + 14 pedestrians + 40 cars is about 92 × 20 = 1,840 writes/s. That is trivial.
- Raycasts per validated shot: one line-of-sight check, plus one origin check if the origin is more than 3 studs from the head. At 30 shooters × 10 shots/s that is at most about 600 raycasts/s, which is fine.

### 10.4 Server-authoritative ammo
- `WeaponService` owns `mag` and `reserve`. Reloading starts on `WeaponReload(w)` and completes after `reloadTime`. It is cancelled by unequip, sprint or entering a car.
- The client predicts and shows the predicted count. `AmmoState(w, mag, reserve)` is sent on reload completion, on purchase, and whenever the server rejects a shot because of ammo; the client snaps to it.

### 10.5 Melee and vehicles
- **Melee** reuses the existing bat logic: cone + reach + LOS (`CombatService.selectTarget`, `batLineOfSight`), with the reach from the weapon config. `WeaponMelee(w, aimDir)` is rate-limited by `rpm`.
- **Ray hits a character part:** damage the player. If the victim is seated in a car, apply ×0.7.
- **Ray hits a vehicle part:**
  - `VehicleService.damage(car, dmg × 0.6, source)`.
  - If the hit part is named `Wheel*` or sits within 1.5 studs of a wheel hub: set `TiresPopped` with a 6 s deadline (the same field the spike strip uses).
  - When the car's health reaches 0, the existing wreck flow runs.

### 10.6 Cosmetic replication
- New `Remotes.Unreliable = { "ShotFx", "PoliceShotFx" }`. `Net.init` creates `UnreliableRemoteEvent`s; add `Net.fireNearUnreliable`.
- **Payload:** `(shooterUserIdOrUnitId, weaponIndex u8, origin, endpoints {≤8}, impactKinds {u8})`, which stays well under the 900-byte unreliable limit.
- **Who receives it:** clients within 400 studs of the origin or any endpoint, excluding the shooter, who already rendered predicted FX.
- **When the server sends it:** after checks 1–4 of section 10.2, so misses are visible too, but a cheater cannot spoof visuals for weapons they don't hold.
- **Client budget:** pooled tracers (Beam plus two Attachments, 64 maximum), muzzle flashes (PointLight + ParticleEmitter, 16 maximum) and impact effects (dust, sparks, glass; 48 maximum). Impact decals go on world surfaces only, maximum 128, oldest removed first.

### 10.7 Anomaly scoring (`ShotAudit`, inside WeaponService)
- **Scoring:** each rejection adds weight: future time +3, bad origin +3, line of sight +2, angle +2, target distance +1, rate +1, ammo +1. The score decays by 10 per minute.
- **Over 30:** silently drop that player's hits for 60 s and log through `AdminService` (player, reasons, sample packet).
- **Over 80 within 2 min:** kick with a generic message and log. No automatic bans.
- **Statistical flags (log only, for review):** a headshot ratio above 70% over 50 or more hits, or median time-to-first-hit under 120 ms after a target becomes visible.
- **Never trust from the client:** damage amounts, victim identity without a part reference, health, armor, ammo counts, wanted level, or zone membership.

---

## 11. Controls, camera, HUD and audio

### 11.1 Bindings
Implement with the **Input Action System**: an `InputContext` "Weapon" that is enabled while armed on foot. Every `InputAction` gets keyboard, gamepad and touch `InputBinding`s, and `UIButton` bindings serve the touch buttons. Source: <https://create.roblox.com/docs/input/input-action-system>.

| Action | PC | Gamepad | Mobile |
|---|---|---|---|
| Aim | Hold RMB | Hold LT | AIM toggle button (80 px, left of FIRE) |
| Fire | LMB | RT | FIRE button (110 px, bottom-right). **Dragging from the FIRE button rotates the camera**, as in COD Mobile and Rivals |
| Reload | R | X | RELOAD button (56 px); also automatic on empty |
| Weapon wheel | Hold Tab, then mouse direction, release | Hold LB, then right stick | Tap the weapon icon (top-right, under the cash). Swipe the icon left or right to cycle |
| Quick select | 1–8 (wheel slots), mouse wheel cycles | D-pad left/right cycles within a slot | — |
| Shoulder swap | V | R3 | Small swap button (shown only while aiming) |
| Surrender (≤2★, cops within 40 studs) | Hold H | Hold D-pad down | SURRENDER button appears |
| Holster | Double-tap Tab or 0 | Hold LB, then centre | Wheel centre "Unarmed" |

The existing driving bindings stay unchanged. G and L1 for spikes remain the gadget binding while driving.

### 11.2 Aim assist (`Shared/Combat/AimAssist.luau`, pure scoring)
Aim assist applies on touch and gamepad only.

- **Against NPC cops and peds (GTA "Assisted Aim – Partial"):**
  - On Aim press, lock onto the best target within 22° of screen centre and 150 studs, with line of sight. The score weights angle, distance and threat (currently shooting at you).
  - The lock follows the torso. A flick of the right stick or swipe on the screen switches target. The lock **breaks after 2.5 s** (Rockstar's timer).
- **Against players:**
  - **Friction:** sensitivity ×0.5 while the crosshair is within 2° of the target's torso.
  - **Magnetism:** 15% per second pull toward the torso when the target is within 6°.
  - **No lock and no auto-fire.**
- Settings: "Aim Assist: Full / Light / Off". Light means friction only.

### 11.3 Camera (`ShoulderCamera`, client)
Use the kit's `Libraries/ShoulderCamera` as a reference.

- **Engagement.** A scriptable camera takes over only while a gun is equipped on foot. Otherwise the default camera and the existing chase cam stay.
- **Offset.** Right shoulder (1.9, 1.5, 0). Hip distance 8 studs, aim distance 4.5 studs.
- **Collision.** A 0.6-stud spherecast pulls the camera in.
- **Smoothing.** Critically damped, 0.08 s.
- **Character facing.** While aiming or firing, `AutoRotate=false` and the character's yaw is aligned to the camera. Torso and head pitch follow through an `IKControl` (LookAt chain from UpperTorso to Head) toward the aim point.
- **Recoil and shake.** Kicks are applied to the camera's pitch and yaw offsets. Shake is small: 0.2° on pistol fire, 0.5° on the marksman rifle.

### 11.4 Weapon wheel (`WeaponWheel`, client)
The visual reference is `ref_gtawiki_WeaponWheel-GTAV.jpg`.

- **Slots.** 8 radial slots, clockwise from the top: Handgun, SMG, Rifle, Marksman, Melee, Shotgun, Gadget, Consumable (med kit and armor).
- **Centre.** The selected weapon's name, "1 / N" for cycling within a slot, and `reserve / mag`.
- **Style.** White line-art silhouettes on a dark translucent disk. The highlighted slot gets a soft white wedge.
- **While open:** the local `ColorCorrection` desaturates by −0.6 with Blur 8, and walk speed drops to 50%. Server time is not slowed; this is multiplayer.

### 11.5 Combat HUD (`CombatHUD`, client)
This follows the lead direction's layout.

- **Bottom-left, under the minimap:** a green **health** bar and a blue **armor** bar, as in the GTA V radar.
- **Top-right, under cash and stars:** the weapon silhouette plus `mag | reserve`.
- **Crosshair:**
  - A 4 px white dot that turns red over a hostile.
  - SMGs and rifles show four faint ticks that open with the current spread.
  - The marksman rifle uses its scope overlay instead.
- **Hit marker:** a small white "x" flash for 80 ms, a thicker white x for a headshot, and a red x for a down. A subtle tick SFX at about 0.3 volume.
- **Damage direction:** a red translucent arc around the crosshair pointing at the source, fading over 1.5 s. This is the kit's DirectionalIndicator pattern.
- **Low health (below 30):**
  - The screen desaturates to −0.5 with a dark vignette and a quiet heartbeat.
  - **No red blood overlay.**

### 11.6 Gun audio mix (`SoundController` additions)
Each shot is three layers, picked round-robin from variation lists:

- **Shot.** Close layer, `RollOffMaxDistance` 220.
- **Tail.** Played for listeners beyond 120 studs, or always outdoors at low volume, with an `EqualizerSoundEffect` low-pass beyond 250 studs.
- **Mech.** Cycling and click, played only within 30 studs.

Further rules:
- Beyond 600 studs, play only a single distant tail at 0.15 volume. This builds the GTA-style city soundscape of distant gunfire.
- Near-miss whiz: when a tracer passes within 4 studs of the local head.
- Ducking: gunfire within 80 studs ducks the car radio by −6 dB for 1.5 s.

---

## 12. Assets (IDs, thumbnail and waveform verdicts)

The search method:
- Creator Store searches used `apis.roblox.com/toolbox-service` (v1 marketplace, with creator filters `creatorType`/`creatorTargetId`).
- Details came from `toolbox-service/v1/items/details`.
- Thumbnails came from `thumbnails.roblox.com` and were viewed as contact sheets.
- The kit model contents were deserialized with Lune 0.11 (`@lune/roblox`).

### 12.1 Gun models

**Recommended set: creator Regole_CKC (user 48023292).**
- All models are script-free, textured, realistic and at real-world scale. The M1911 description reads: "correctly scaled to real proportions, at 21.6 centimeters".
- Sheet: `img_gta/combat_guns_regole_ckc_candidates_2026-10-27.jpg`.
- Scale the models ×1.15–1.25 in-hand for third-person readability, as GTA does.

| Our weapon | Asset ID | Name | Tris | Verdict |
|---|---|---|---|---|
| Kessler P9 | 136698099681966 | Beretta 92FS/M9 | 21,025 | **Use.** Crisp textures, correct silhouette. Remove the logo on the grip. |
| P9 (alt) | 8991279287 | M1911 | 8,325 | Good, lighter. Wooden grips. |
| Brandt .50 | 17767820926 | Desert Eagle Mark XIX | 11,466 | **Use.** Worn steel texture, excellent. |
| Volk Micro SMG | 17760940350 | Mini Uzi | 18,201 | **Use.** Excellent. |
| Brandt Tac SMG | 16725069816 | MP5A3 | 25,410 | **Use.** Excellent. Decimate to about 15k. |
| Tac SMG (alt) | 17670016388 | HK UMP-45 | 34,306 | Good. |
| Coastline Pump | 102505705333696 | Mossberg 590 | 16,700 | **Use.** Clean black synthetic. |
| Volk Comrade | 8974619704 | AK-47 | 18,662 | **Use** (budget-friendly). |
| Comrade (alt) | 77441363162209 | AKM | 51,348 | The best look, but heavy: decimate to 15k or less. |
| Coastline Carbine | 108333428640727 | Magpul M4 | 38,718 | **Use.** Decimate. |
| Volk Marksman | 16708385075 | Dragunov (SVD) | 29,615 | **Use.** Wood furniture and a scope. Also used by the heli sniper. |
| SWAT carbine | 17746420462 | G36C | 32,939 | Good for the SWAT loadout, so it reads differently from the player carbine. |
| Revolver (phase 2) | 110670778436939 | Speed-Six | 12,769 | Excellent. |
| Knife (phase 2, optional) | 18775287777 | KA-BAR Combat Knife | 2,356 | Good, if the user wants knives at all. |
| Grenade (not v2) | 18948705106 | M67 Grenade | 5,301 | Excellent, but out of scope. |

**Risk.** Some of this creator's other uploads are titled "Tyre (Tire) Pack | Insurgency: Sandstorm" and "Hesco Barrier | Delta Force". The MP7 description says "Original model uploaded by Kamishiro_Sanagi. Textures fixed by me." Some meshes may therefore be ports from commercial games.
- A DMCA takedown would blank them in-game.
- Treat them as **placeholders**: build our own parody guns in the Blender pipeline (task #8) before any paid push, or get written provenance from the creator.

**Other candidates** (sheet `combat_guns_misc_candidates_2026-10-27.jpg`):

| Asset | Verdict |
|---|---|
| Glock 13324950652 (J_Suteinua), 4131984736 (b_odyguard, 24k) | Good textures |
| AKM 15857882038 (whisper games.) | Wood and metal, good |
| PBR AK 8413055627 (alphaneu) | Good |
| 870 3259591740 (SonicVFX, 9k, model only) | Stylized grey/blue, acceptable |
| 870 PBR 15488286450 | Decent |
| Low Polygon Gun Pack 9327209214 (RedWood Roleplay GROUP, 411k tris total) | A big atlas of low-poly guns. Fallback for NPC-held weapons at distance |
| CS2 Desert Eagle 15651280815, "Glock 17 \| EFT" 18230834002, "Insurgency: Sandstorm – Remington 870" 10598335983 | **Rejected.** Self-declared game rips |
| Hyg4r "(WORKING GUN) … [PBR]" packs 102413889948884 / 70766911413980 / 116284602887624 | **Rejected.** 20 scripts each; free-model scripts are a security risk. The meshes would also need stripping |

**Roblox Weapons Kit** (creator Roblox, user 1). Sheet: `combat_roblox_weapons_kit_2019_2026-10-27.jpg`.
- Pistol 4842197274, Auto Rifle 4842207161, SMG 4842212980, Shotgun 4842215723, Sniper 4842218829.
- Each model has 3 skins, 4.4k–6.2k tris, 9 animations and 39 audio.
- Verdict: realistic silhouettes (Beretta/1911, AK, MP5, 870, AWP-like) but flat-shaded low-poly. **Not GTA-grade.** Use them for scripts, config and audio reference only.
- The 2026 re-release by the Roblox Resources group (3529469; for example Pistol 118912302094201 and Auto Rifle 96131146947811) has the same models, with placeholder thumbnails only.

### 12.2 Melee and armor visuals
Sheets: `combat_melee_armor_candidates_2026-10-27.jpg` and `combat_vest_accessories_2026-10-27.jpg`.

| Use | Asset ID | Creator | Verdict |
|---|---|---|---|
| Slugger Bat | 16428159315 | Alika0946 | **Use.** Wood with black grip tape, 892 tris. |
| Bat (alt, aluminium) | 9282872148 | OfficialSpyWorksHD | Good. Could be a tint variant. |
| Knuckle Dusters | 88603423552264 | KoBoIce | **Use.** Brass, 7.6k tris. |
| Nightstick (police) | 13826913704 | Jakel_6666 | **Use.** A matte black side-handle baton. |
| Pry Bar | 113217623332553 | SodaBreadle | Acceptable but stylized and thin. Easy Blender replacement. |
| Armor vest accessory | 103113428495694 | DIVISIVE | **Use.** A plain black plate carrier. Front accessory applied via HumanoidDescription. |
| Armor vest (alt) | 91301921946676 | 2026 masterclass | Good. |
| Armor vest | 16554530715 | 8O8Mph | **Rejected.** Pentagram and anarchy patches. |
| Kevlar Vest model | 1167407301 | AgentRyanTech | **Rejected.** Blocky classic rig. |

### 12.3 Animations
Ownership was checked via `economy.roblox.com/v2/assets/{id}/details`. All of these are owned by **Roblox (user 1)**, so they play in any experience.

| Key | Asset ID | Name | Use |
|---|---|---|---|
| pistol idle | 17747125537 | blaster_character_idle | Placeholder handgun hold |
| pistol fire | 17747128593 | blaster_character_shoot | Placeholder |
| pistol reload | 17747123905 | blaster_character_reload | Placeholder |
| rifle idle | 17747384020 | autoblaster_character_idle | Placeholder long-gun hold |
| rifle fire | 17747381445 | autoblaster_character_shoot | Placeholder |
| rifle reload | 17747385966 | autoblaster_character_reload | Placeholder |
| rifle aim | 3972164452 | NewRifleAim (Weapons Kit) | Placeholder aim |
| rifle aim tight | 3972157449 | NewRifleADS | Aim zoom |
| rifle reload (alt) | 3972131105 | RifleReload | Alt |

The Blaster animations come from the Roblox Resources "Behaviors" model (132369215737591). They were designed for a stylized laser-tag blaster, so expect slightly toy-like poses; verify them in Studio.

**Custom set (about 22 clips).** Author these in Studio's Animation Editor and publish them under the **experience owner**. Roblox animations only play in experiences owned by the animation's owner, or if they are Roblox's own. Sharing is now possible through asset permissions; see "Sharing Animation Assets with Connections and Groups", <https://devforum.roblox.com/t/3892540>.
- Upper-body-only keyframes: handgun idle-aim, fire and reload; rifle idle-aim, fire and reload; pump fire and pump rack.
- Melee: bat swing A and B, punch combo L and R, crowbar swing.
- Equip and holster for each class.
- Hands-up, kneel-cuffed, cower, flinch/hit-react (light) and surrender.

Only upper-body joints are keyed, so the walk and run cycles drive the legs; Roblox has no per-bone masks. `IKControl` drives the aim pitch and the left hand on the foregrip.

### 12.4 SFX
**Sources:**
- Roblox-licensed partner uploads: **Pro Sound Effects** (user 7462895450) and **Audioscape** (group 34159607). The same family is already used in `Config/Sounds.luau`; for example, Siren is 9119165131.
- Roblox Weapons Kit audio (uploader DarthfuzzyX, public).

**Search method:** `apis.roblox.com/toolbox-service/v2/assets:search?searchCategoryType=Audio&query=…`, filtered by creator.

**Verdict method:**
- Pro Sound Effects files were downloaded and their RMS envelope analysed: onsets (local maxima within 12 dB of peak after a rise of 9 dB or more) and active length (above peak −40 dB).
- Kit and Audioscape files need authentication to download, so their verdict comes from metadata only. Audition all of them in Studio.

| Role | Asset ID | Title | Verdict |
|---|---|---|---|
| Pistol shot | 9117399029 | Pistol Single Shots 1 | **Single transient**, 0.55 s active, short reflections. Use. |
| Pistol shot (var) | 3806566911 | weapon_Pistol_Firing (kit) | Metadata only. |
| Hand cannon shot | 9114729252 | Gun Single Shots 11 | Single, loud (−6 dBFS). Has 50 ms of pre-roll: set `TimePosition` 0.04, pitch 0.85. |
| AR / SMG shot | 9113180776 | Assault Rifle 9 | **Single clean shot**, 0.78 s. Use for the Comrade (pitch 1.0), Tac SMG (1.08) and Micro SMG (1.18). |
| AR tail | 9113198012 | Assault Rifle 1 | One onset with a long 2.6 s decay. Use as the distant/outdoor tail. |
| SMG shot (var) | 4812801977 | weapon_SMG_Firing_GunTail_Mix2 (kit) | Metadata only. |
| Carbine shot | 128650101411844, 127619198178554, 86903016850225, 72333449737130 | AS_rifle_shot-01…04 | Metadata only. A round-robin set. |
| Marksman shot | 9118173988 | Rifle Single Shots 3 | **Single shot** with a 3 s reverb tail. Use. |
| Shotgun shot | 99008924129683, 82409501948316, 106454770387605, 84039532799719 | AS_shotgun_shot-01…04 | Metadata only. Pair with AS_shotgun_tail-01…04 (75302784250672, 116468550696572, 125311341637563, 99323994116525). |
| Shotgun shot (fallback) | 9112913564 | 12 Gauge Shotgun 9 | 3 onsets (shot plus mechanics) in 0.58 s. Use `PlaybackRegion` 0–0.17 s. |
| Pump rack | 9112910245 | 12 Gauge Pump Action Shotgun 4 | 3 separated clicks at 0.08, 0.92 and 1.70 s. Use region 0.85–1.25 s for one rack. |
| Generic shot tails | 90852446208160, 70527882874881, 79289354458541, 111187749925677 | AS_gun_tail-01…04 | Metadata only. Distant layer for all guns. |
| Distant automatic fire (AI) | 9116361236 | Machine Gun Bursts 12 | **3 rounds at 90 ms spacing**, 0.52 s. SWAT and heli bursts beyond 200 studs. |
| Distant automatic loop | 9116358132 | Machine Gun Bursts 1 | Sustained 3.2 s. Far-away firefight ambience. |
| Magazine out/in | 9113104176 | Ammo Magazine 1 | **2 clicks** at 0.05 and 0.35 s. Use. |
| Reload foley | 101803348893194, 92321876028160, 135901981148051, 73599108833500 | AS_gun_foley-01…04 | Metadata only. Also AS_rifle_foley-01…04 (87783544935865, 87804900931100, 91536287317404, 107500628544079) and AS_shotgun_foley-01…04 (128663118150595, 111442452811059, 114280224323666, 103060570812555). |
| Kit reloads | 3821789416 / 3821787597 / 3821793228 / 3821792115 / 3821795168 | pistol / AR / SMG / shotgun / sniper "Charging" | Metadata only. |
| Casing drop | 3909012115 | weapon_Bullet_Casing_Dropping | Metadata only. Uploader is Reference Games. |
| Near-miss whiz | 9113634361, 9113634444, 9118168291 | Bullet Whiz 1 / 2, Rico Bullet Whiz 3 | Use. |
| Ricochet | 9118168612, 9118169272 | Ricochet Metal 1, Ricochet Reverberant 3 | Use. |
| Bullet impact | 9113632396, 9113632506, 9120962232 | Bullet Impact 9 / 10, Wood Snap Bullet Impact 1 | Use. |
| Hit tick | 109431560870225 | AS_gun_punch-01 | Metadata only. Candidate for the hit-marker tick. |
| Body fall | 9113480915 | Body Fall Thud 2 | Use for WASTED and ragdolls. |
| Melee | 9117969687, 9117969717, 9125380872 | Punch Kit Beefy Hit 2 / 3, Baseball Wood Bat Power Whack | Use. |
| Handcuffs (BUSTED) | 9114764435 | Handcuff Movement 19 | Use. |
| Police radio | 9117798202, 9125774594 | Police Radio Dispatcher Many Officers 24, Police Radio Line Feed 1 | Chase ambience. |
| Heli | 9125390124, 9113416801 | Bell Huey Short Maneuver Overhead; Approach Fly By Away | Replace the cartoon heli audio. |

---

## 13. Implementation plan

### 13.1 Files to add

| Path | Responsibility |
|---|---|
| `src/shared/Config/Weapons.luau` | `WeaponDef` table (section 4), wheel order, ammo, armor, med kit and tint definitions |
| `src/shared/Config/Animations.luau` | Animation keys mapped to IDs (Roblox-owned placeholders now, custom IDs later) |
| `src/shared/Combat/Ballistics.luau` | Pure: deterministic pellets (`Random.new(seed)`), spread and bloom, falloff, muzzle→crosshair solve |
| `src/shared/Combat/DamageModel.luau` | Pure: part multipliers, armor split, regen tick |
| `src/shared/Combat/ShotValidation.luau` | Pure: the checks in section 10.2 (time, origin, angle, range, target tolerance) on plain data |
| `src/shared/Combat/AimAssist.luau` | Pure: target scoring, lock, friction and magnetism math |
| `src/shared/Combat/PoliceAim.luau` | Pure: accuracy model and firing-director token bucket (section 9.3) |
| `src/shared/Combat/CrimeRules.luau` | Pure: heat decisions (section 9.5). Absorbs `shouldAddAssaultHeat` and `countsAsThiefBonk` |
| `src/shared/Combat/Ragdoll.luau` | Motor6D ↔ BallSocket conversion and get-up. Extracted from `NPCService._ragdoll` |
| `src/server/Systems/WeaponService.luau` | Inventory, tools, equip, reload, fire and melee handlers, ammo, ShotAudit, ShotFx relay |
| `src/server/Systems/DamageService.luau` | Health and armor authority, regen, protection, safe zones, passive, rookie, revenge, Menace, bounty, death classification, hospital respawn and bill |
| `src/server/Systems/HitboxHistory.luau` | 20 Hz history and `sample(model, t)` |
| `src/server/Systems/PoliceCombatService.luau` | On-foot officers, firing director, roadblocks and spike strips, heli sniper, SWAT, vision cones, last known position and search area |
| `src/client/Controllers/WeaponClient.luau` | Input via the Input Action System, fire loop, prediction, recoil and spread, reload, packet batching, predicted FX |
| `src/client/Controllers/ShoulderCamera.luau` | Section 11.3 |
| `src/client/Controllers/WeaponWheel.luau` | Section 11.4 |
| `src/client/Controllers/CombatHUD.luau` | Health and armor bars, ammo, crosshair, hit markers, damage arcs, low-health effect |
| `src/client/Controllers/DeathScreenController.luau` | WASTED and BUSTED screens (section 7) |
| `src/client/Controllers/ShotFxController.luau` | Pooled tracers, muzzle flashes, impacts and whizzes for `ShotFx` and `PoliceShotFx` (or fold into EffectsController) |
| `src/client/Controllers/GunShopUI.luau` | Store menu (section 5.1) |
| `tests/spec/weapons.spec.luau`, `damage.spec.luau`, `shotvalidation.spec.luau`, `policeaim.spec.luau`, `crimerules.spec.luau` | Lune unit tests for the pure modules. Assertions: minimum TTK of 0.35 s or more for every gun except a marksman headshot; armor split; regen cap of 50; deterministic pellets; time-machine and future shots rejected; the DPS budget never exceeded with 10 officers |

### 13.2 Files to change

| Path | Change |
|---|---|
| `src/shared/Remotes.luau` | **Client to server:** `WeaponFire`, `WeaponReload`, `WeaponEquip`, `WeaponMelee`, `BuyWeapon`, `BuyAmmo`, `BuyArmor`, `BuyMedKit`, `UseMedKit`, `SetPassive`, `Surrender`, `SetWeaponTint`. <br>**Server to client:** `HitConfirm`, `DamageTaken`, `Wasted`, `AmmoState`, `CombatState`. <br>**New `Unreliable` list:** `ShotFx`, `PoliceShotFx`. <br>Deprecate `ToolAction` for guns; it stays for gadgets. |
| `src/shared/Net.luau` | Create `UnreliableRemoteEvent`s; add `fireNearUnreliable` and `fireClientUnreliable`; add `Net.isUnit(v)` |
| `src/shared/Config/Police.luau` | Add `Combat` per-star table (section 9.1), vision cones, search radii and `EVADE_OUTSIDE_MULT = 2`. Add heat keys: `gunfire`, `brandish`, `pedHit`, `pedDown`, `copHit`, `copDown`, `heliHit`, `heliDown`, `pvpDown` |
| `src/shared/Config/Sounds.luau` | Gun, impact, police and WASTED keys (section 12.4) |
| `src/shared/Config/Economy.luau` | Remove `Tools.bat` / `BAT_*`, which move to Weapons. Keep the taser and spikes as gadgets with new names and descriptions, without emoji |
| `src/shared/Types.luau` / `DataService.luau` | `SCHEMA_VERSION 2`. Add `weapons: {[id]: {ammo: number, tint: string?}}`, `armor`, `medkits`, `combat: {rookieSecondsLeft, passivePref}`, `stats.wasted` and `stats.bountiesClaimed`. Migration step 1→2: `tools.bat` becomes `weapons.bat`; taser and spikes stay in `tools`. Grant the P9 to existing players as a v2 welcome gift. Update the snapshot |
| `src/server/Systems/CombatService.luau` | Delete the cartoon builders and colours. The taser and spikes use realistic meshes. The bat path moves to WeaponService melee. `applyHit` stays for the taser stun |
| `src/server/Systems/WantedService.luau` | Replace `_tickDecay` with the evade timer (inside/outside the search area) and all-at-once clear. `_onDied` defers to `DamageService` classification. New heat reasons. Remove confetti, `Whoosh` and emoji notifications. Bounty hook for 4★ and above |
| `src/server/Systems/PoliceService.luau` | Expose `getUnits(player)`, `getHeli(player)` and `unitRole`. `isSeen` uses the cone and LOS test. Officer exit hook. Spawn roadblocks ahead on the predicted route, out of view (reuse `findSpawnLane`). SWAT van unit type. `CLOSE_SEE_RANGE` 60 → 40 |
| `src/server/Systems/NPCService.luau` | `spawnOfficerOnFoot(cframe, loadout)`, damageable officers and peds (no more pinned health for those kinds), `witnessesNear(pos, r)`, gunfire panic (flee or cower), downed ragdoll and fade after 6 s, `officerFoot` budget. Update the header's "Mild rating" comment |
| `src/server/Systems/VehicleService.luau` | Bullet damage entry (`damage(car, amount, source)` already exists), wheel-hit tire pop, occupant shielding flag |
| `src/server/Systems/PlotService.luau` | Hospital respawn (nearest of 2) when `DamageService` says WASTED. Garage heal and safe-zone volume. `GoHome` blocked while In Combat |
| `src/server/Systems/ShopService.luau` | Weapon, ammo, armor, med kit and tint purchases with zone checks |
| `src/server/Systems/TheftService.luau` | A thief downed by any weapon drops the car (existing `onThiefHit` / "dropped" path); a gun hit counts as a bonk for contracts |
| `src/server/Systems/AdminService.luau` | Gated QA commands: `/give <weapon>`, `/ammo`, `/armor`, `/god`, `/stars n`, `/spawncops`, `/audit <player>` |
| `src/shared/Util/MapLayout.luau` + MapBuilder | POIs `Hospital1/2`, `GunStoreA/B`; safe-zone boxes; `CoverPoint` tags; roadblock-capable intersections |
| `src/client/Controllers/CombatClient.luau` | Strip the BONK/ZAP buttons, emoji and stars. Keep the knockback, stun freeze and spikes button (restyled) |
| `src/client/Controllers/HUDController.luau` | Remove the cartoon BUSTED overlay (moves to DeathScreenController). Health and armor live in CombatHUD; keep cash and stars, restyled per the UI note |
| `src/client/Controllers/SoundController.luau` | Shot/tail/mech layering, distance rules, near-miss whiz, radio ducking |
| `src/client/Controllers/VehicleClient.luau` | Holster on entering a car. Keep G/L1 spikes |
| `default.project.json` | Map `StarterPlayer.StarterCharacterScripts` (a new `src/character` folder containing an empty `Health` Script) |

### 13.3 Phases and acceptance
Each milestone is verified by Studio operator screenshots, side by side with the GTA references.

**C0, foundation (one build wave):**
- Weapons config with the P9, Micro SMG, Pump, Carbine and Bat.
- `DamageService` with health, armor, regen and WASTED to hospital.
- `HitboxHistory`.
- `WeaponService` hitscan with the full validation pipeline and `ShotAudit`.
- `WeaponClient` and `ShoulderCamera`. `CombatHUD`: health and armor bars, ammo and crosshair.
- `DeathScreenController` (WASTED).
- `ShotFx` tracers and impacts.

Acceptance:
- Screenshots of a realistic P9 in an over-the-shoulder aim, the WASTED screen, and health and armor under the minimap.
- A two-client Studio test at 200 ms simulated latency shows hits registering, plus rejection logs when the operator injects a bad origin.

**C1, police and PvP:**
- `PoliceCombatService` with per-star escalation, on-foot officers, the firing director and roadblocks at 3★.
- Vision cones, the search area and the all-at-once evade.
- The BUSTED rework with surrender.
- Safe zones, passive mode, rookie protection, spawn protection, revenge immunity and Menace.

Acceptance:
- Screenshots of a 3★ roadblock firefight, minimap cones with flashing stars, and the BUSTED kneel.
- A 5-minute 3★ chase on foot that the operator survives without being shredded. Log the DPS budget hits.

**C2, store and economy:**
- FREEDOM ARMS interior and UI, the rest of the roster, ammo pickups, armor vest accessory, med kits, the weapon wheel and tints.

Acceptance:
- Screenshots of the store UI, the weapon wheel open, and the vest on a character.

**C3, high stars and polish:**
- Heli sniper with telegraph, the SWAT van, 2 helis, bounties.
- Custom animation set.
- Pedestrian panic and downing.
- Audio pass and mobile aim-assist tuning.

Acceptance:
- A mobile (iPhone-size) screenshot of the combat layout, and a heli laser telegraph screenshot.
- Re-submit the maturity questionnaire.

---

## 14. Risks and open questions

**Risks:**
1. **Asset provenance (high).** The Regole_CKC guns may include game-ripped meshes (section 12.1). Mitigation: placeholders only, with our own Blender parody guns before paid promotion.
2. **Animation quality (medium).** The Roblox-owned placeholder animations are generic. GTA feel depends on the custom set and the IK aim; budget animator time.
3. **Moderate audience.** Under-9s need parental consent for Moderate (ESRB). The lead direction already accepts 13+.
4. **Performance.** Third-person guns of up to 50k tris on 30 players: decimate to 15k or less and use `RenderFidelity=Automatic`. Pool all FX.
5. **Griefing.** Mitigated by the section 8 rules. Watch the analytics: PvP downs per player-hour, passive-mode uptake, and early-session quits after a first PvP death.

**Open questions for the user:**
- (a) Knives in or out? This spec ships bat, pry bar and knuckles, with the knife as optional phase 2.
- (b) Should pedestrians be downable? This spec says yes, with ragdoll, fade and no gore. The alternative is that they only flee and cower.
- (c) Is "FREEDOM ARMS" acceptable as the store parody name?
- (d) Drive-by in v2 or phase 2?
- (e) Player-placed bounties? This spec says no.

---

## Sources

**Roblox policy and docs:**
- Content maturity: <https://create.roblox.com/docs/production/promotion/content-maturity>
- Community Standards: <https://about.roblox.com/community-standards>
- Age recommendation API: `apis.roblox.com/experience-guidelines-api/experience-guidelines/get-age-recommendation`, queried for universes 498490399, 903807016, 1008451066, 1494262959, 2132866904, 245662005, 1769712451, 111958650, 113491250, 6035872082, 1168263273, 1390601379 and 371263894
- Detect hits (Laser Tag): <https://create.roblox.com/docs/tutorials/curriculums/gameplay-scripting/detect-hits>
- Implement blasters: <https://create.roblox.com/docs/tutorials/curriculums/gameplay-scripting/implement-blasters>
- Security tactics: <https://create.roblox.com/docs/scripting/security/security-tactics>
- Game Security: <https://developer.roblox.com/articles/Game-Security>
- Server authority: <https://create.roblox.com/docs/projects/server-authority> and <https://about.roblox.com/newsroom/2026/07/creating-responsive-cheat-resistant-games-roblox-server-authority>
- Weapons kit: <https://create.roblox.com/docs/resources/weapons-kit>
- Input Action System: <https://create.roblox.com/docs/input/input-action-system>
- Transfer animations: <https://create.roblox.com/docs/projects/transfer-animations>

**DevForum:**
- Projectile lag compensation: <https://devforum.roblox.com/t/projectile-lag-compensation/672468>
- Alternatives to FastCast: <https://devforum.roblox.com/t/alternatives-to-fastcast/2630169>
- Sharing animation assets: <https://devforum.roblox.com/t/3892540>

**GTA reference:**
- Wanted Level in GTA V: <https://www.grandtheftwiki.com/Wanted_Level_in_GTA_V>
- Rockstar on targeting modes: <https://mp1st.com/news/grand-theft-auto-5-rockstar-on-weapon-handling-and-customization>
- Passive mode: <https://www.sportskeeda.com/gta/gta-online-passive-mode-what-it-enable-disable-it>
- Weapon wheel layout: <https://www.grandtheftwiki.com/Weapons_in_GTA_V>

**Roblox games:**
- Jailbreak weapons: <https://jailbreak.fandom.com/wiki/Weapons>
- Da Hood stomp and knock: <https://www.videogamer.com/?p=471109>
- Rivals aim assist: <https://progameguides.com/roblox/roblox-rivals-controls-pc-controller-and-mobile-layouts/>

**Audience:**
- ESRB: <https://www.esrb.org/blog/what-parents-need-to-know-about-roblox-2/>
- TechCrunch: <https://techcrunch.com/2024/11/18/roblox-no-longer-allows-users-under-13-to-message-others-outside-of-games>

**Asset data (queried 2026-10-27):**
- `apis.roblox.com/toolbox-service/v1/marketplace/10` (creator filters `creatorType=1&creatorTargetId=48023292`, `creatorType=1&creatorTargetId=1`, `creatorType=2&creatorTargetId=3529469`)
- `apis.roblox.com/toolbox-service/v1/items/details`
- `apis.roblox.com/toolbox-service/v2/assets:search?searchCategoryType=Audio`
- `thumbnails.roblox.com/v1/assets`
- `economy.roblox.com/v2/assets/{id}/details`
- `assetdelivery.roblox.com/v2/assetId/{id}`: kit .rbxm files parsed with Lune; Pro Sound Effects audio decoded with ffmpeg for the envelope analysis
- `catalog.roblox.com/v1/search/items/details` (vest accessories)
