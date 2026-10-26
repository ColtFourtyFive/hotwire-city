## Files: src/server/Systems/CombatService.luau, src/client/Controllers/CombatClient.luau, src/client/Controllers/EffectsController.luau, tests/spec/combat.spec.luau, docs/previews/combat_tools.png

### Public API
CombatService (server). All cross-system calls are lazy and wrapped in pcall, so the module also loads in the Lune harness.
- init(): pre-builds the tool templates and registers Net.on("ToolAction", handler, 5/s).
- start(): connects PlayerAdded (and loops over existing players), PlayerRemoving cleanup, DataService.Loaded -> giveTools, MonetizationService.PassChanged("taser") -> giveTools, and a Heartbeat spike-strip poller.
- giveTools(player): makes the Backpack and StarterGear each hold exactly one of every owned tool. The bat is always owned; the Zapper ("taser") comes from data.tools.taser or the "taser" pass. It also removes duplicates and tools the player no longer owns. Called on CharacterAdded (deferred), on data load, on pass change, and by ShopService after BuyTool.
- buildTool(toolId: "bat"|"taser"|"spikes"): Tool? builds the tool from parts:
  - Tool names are "Bonk Bat", "Zapper" and "Spike Strip".
  - Each has a ToolId attribute, ToolTip, CanBeDropped=false and RequiresHandle=true.
  - Bat: Handle with an attachment-based Trail "SwingTrail" (disabled by default).
  - Zapper: a "Tip" part with a "Muzzle" attachment and a "Glow" PointLight, plus parts "Coil1".."Coil3".
- buildSpikeStrip(groundCFrame): Model "SpikeStrip". Anchored, PrimaryPart "Base", invisible "Trigger" volume; -Z of groundCFrame is the dropping car's forward.
- stun(player, seconds): sets the Stunned attribute, then 1s of stun immunity after it ends.
- isStunned(player): boolean.
- Hit: Signal(attacker, victim, toolId, ejectedCar?).
- Pure helpers (tested):
  - selectTarget(origin, forwards, candidates {key, position}, range, minDot, pointBlank) -> key?
  - cooldownFor(toolId, hasTaserPass)
  - cooldownReady(book, toolId, now, tolerance?)
  - startCooldown(book, toolId, now, duration)
  - shouldAddAssaultHeat({attackerInOwnGarage, victimInAttackerGarage, victimStealingFromAttacker, victimWanted})
  - segmentCrossesStrip(p0Local, p1Local, halfWidth, halfDepth, height)
  - isSamePlayer(PlayerOrUserId, player)
- Remote behavior:
  - ToolAction(toolId, aim?) checks, in order: types (string id in Economy.Tools; aim nil or Net.isFiniteVector), alive character, not Stunned, data loaded, owns the tool, tool equipped (spikes: equipped OR driving), cooldown (0.12s jitter tolerance).
  - Hits send Knockback(velocity, stun) to the victim and call VehicleService.eject(car) if the victim was driving.
  - Then TheftService.onThiefHit(attacker, victim). If the victim was driving the attacker's Stolen car: RewardsService.progress(attacker, "defend", 1) plus a Notify.
  - Assault heat goes through WantedService.addHeat(attacker, Police.Heat.assault, "assault").
  - Spikes: popped cars get model + chassis attribute TiresPopped = workspace:GetServerTimeNow() + SPIKES_POP_TIME; the driver and the dropper get a Notify.
- Effects sent:
  - Bonk {position, sound="Bonk"}
  - Zap {from (Zapper tip), to, hit, sound="Zap"}, sent to players within 300 studs of either end
  - TirePop {position, sound="Poof"}
  - SpikeDrop {position, sound="MetalHit"}

CombatClient (client)
- init() / start().
- activate(toolId): activates a tool from code (spikes work while driving without equipping).
- cooldownRemaining(toolId): number.
- Behavior:
  - Hooks Tool.Activated for every Tool with a ToolId and fires Net.fire("ToolAction", id, aim).
  - Aim: mouse via GetMouseLocation + ViewportPointToRay (screen center under shift-lock); touch uses the last tap (with the inset added) or screen center; gamepad uses screen center.
  - Zapper aim assist: 60px radius on mouse, 170px on touch/gamepad. The bat auto-targets and turns to face the nearest player in reach.
  - Swing/lunge plays through the default Animate script's "toolanim" StringValue ("Slash"/"Lunge"), so other players see it. The bat also gets a local trail and Whoosh sound; the Zapper gets a coil flash.
  - CombatHUD ScreenGui (built with Kit/Theme): ActionButton (round, radial cooldown ring) while a tool is equipped and you're on foot; SpikeButton while driving if you own spikes (also key G / gamepad L1).
  - Knockback: waits for the server eject, then sets PlatformStand, AssemblyLinearVelocity and a random spin, plus a camera-offset shake. It ends with GettingUp.
  - While Stunned: WalkSpeed/JumpPower/JumpHeight 0 and ProximityPromptService.Enabled=false; restored afterwards (prompts only if we disabled them).
  - Spinning ★ stars BillboardGui above every stunned player's head.

EffectsController (client)
- init() / start().
- play(name, data?): public local trigger for any effect.
- Pure helpers: shouldShowRarityTag(kind, rarityOrder, occupied, distance), boltPoints(a, b, segments, amplitude, Random), tagText(carId, mutation) -> rich text.
- Effect router handles CarWreck, Confetti, Zap, Bonk, TirePop, SpikeDrop, CashBurst and BigSteal.
  - Position comes from data.position (fallbacks: data.cframe, data.model/instance pivot, data.from).
  - data.sound (Config/Sounds key) plays via SoundController.play(key, pos). CarWreck defaults to "Poof". BigSteal accepts an optional data.text; CarWreck accepts an optional data.color for debris.
- Pooling:
  - Effect parts: up to 420, anchored, simulated by one Heartbeat with BulkMoveTo (bouncing debris, growing puffs/rings, confetti, bills).
  - Lightning bolt segments come from the same pool.
  - 6 particle hosts (sparkles_main.dds, smoke_main.dds, fire_main.dds, sparkle.png) with PointLight flashes.
  - 6 comic billboards ("KAPOW!", "BONK!", "POP!", "ZAP!", "BIG STEAL!") on a 12-point starburst.
- Rarity tags:
  - Pooled BillboardGuis (max 30, in PlayerGui, AlwaysOnTop) for Vehicle-tagged cars of Kind Parked/Traffic/HotDrop or unoccupied Loot, Rare+, within 150 studs.
  - Text like "EPIC • Phantom GT • $260/s" with a glow stroke in the rarity color and a ✨ mutation label; Legendary+ tags pulse.
- Steal prompts named Hotwire/Carjack/StealPrompt (or whose ActionText starts with Hotwire/Carjack/Steal) on Vehicle-tagged cars:
  - HoldDuration = base × the player's HoldMultiplier attribute, re-applied when the attribute changes.
  - The base comes from the BaseHoldDuration or BaseHold attribute, otherwise from the server-replicated value.
- Police lights: for Police-tagged models within 300 studs, SirenRed/SirenBlue alternate Transparency 0/0.8 about 6 times per second, plus one local PointLight that flips red/blue.

### Contract deviations
- Tool id for the Zapper is "taser" (matches Economy.Tools, Economy.ToolOrder and the Monetization pass key), not "zapper". The display name is "Zapper".
- Spikes: the server accepts ToolAction("spikes") while driving even if the Spike Strip tool is not equipped, so the SPIKES touch button and G/L1 work mid-chase on mobile. Ownership, cooldown, not-stunned and must-be-driving are still checked. Bat and Zapper still require the tool to be equipped.
- TiresPopped is a deadline from workspace:GetServerTimeNow() + SPIKES_POP_TIME (as the task text says), not os.clock() (as SPEC §6 says). VehicleController already compares against GetServerTimeNow. The attribute is set on both the car Model and its Chassis.
- Combat sounds travel inside the Effect payload as data.sound, which EffectsController plays via SoundController.play, instead of a separate Sound remote. Other slices can also put sound="Key" in any Effect.
- Effects added beyond the spec: "SpikeDrop"; Zap carries a `hit` flag; BigSteal accepts an optional `text`; CarWreck accepts an optional `color`.
- Fairness tweaks beyond spec:
- Assault heat is also skipped when the victim is inside the attacker's own garage, and is limited to one star per attacker every 5s.
- After a stun ends, the victim cannot be stunned again for 1s (prevents stun-lock).
- Bat: range BAT_RANGE + 2 studs of lag slack; targets within 3 studs count regardless of facing. The aim direction is accepted as a second facing, since the client auto-targets the nearest player in reach.
- Zapper: precise raycast first, then a 1.25-stud spherecast that can't pass the ray's wall hit. Hitting a car zaps its driver.
- Spike Strip also has RequiresHandle=true (a folded hazard case held in hand). The task only required it for the bat and Zapper.
- Hold-duration scaling in EffectsController only touches prompts on Vehicle-tagged cars, to avoid double-scaling with GarageClient's DisplayCar StealPrompt. It reads a base from the BaseHoldDuration or BaseHold attribute (GarageService uses BaseHold). Suggest VehicleService set BaseHold on its steal prompts too.
- CombatClient sets ProximityPromptService.Enabled=false while the local player is Stunned, so nobody can hotwire mid-stun. It only re-enables prompts it disabled itself.

### Known issues
- VehicleService, TheftService and RewardsService don't exist yet. These calls are lazy and pcall'd and become no-ops until those slices land: VehicleService.getDriving/eject, TheftService.getActiveTheft/onThiefHit, RewardsService.progress. Assumed shapes: getActiveTheft may return either the car (with data.theft) or the theft record; theft.victim may be a Player or a userId. Both are handled.
- Swing/lunge animations rely on the default Animate script's toolanim StringValue convention. If the game replaces Animate, there is no arm animation (the trail and effects still play).
- Not verified in a live engine:
- Server Touched on client-owned fast chassis. A 10 Hz swept poll over Workspace.Vehicles is the backup.
- Workspace:Spherecast. It is pcall'd, and the precise raycast still works without it.
- Whether a parent Frame's Rotation rotates the comic starburst children. Purely cosmetic.
- Glyph rendering of ★ and emoji (🏏 ⚡ 📌 ✨) depends on Roblox font fallback.
- Particles use the .dds built-ins listed in the task. RESEARCH notes .dds acceptance as unverified, though sparkles_main.dds is the engine's own ParticleEmitter default.
- Hit validation uses server-side character positions, which lag behind what the attacker sees. Range slack and the sphere radius compensate, but very fast strafing targets may occasionally be missed.
- Runtime VFX (comic billboards, particles, bolts, rarity tags, siren flashing) can't be rendered by the headless part renderer. Only the tool and spike-strip geometry was visually checked.
- The ActionButton is shown on PC as well as touch, as a clickable cooldown indicator. HUDController doesn't exist yet, so possible overlap with its right-side elements is unchecked.

### Verification
- selene on all 4 owned files: 0 errors, 0 warnings.
- stylua: all 4 files formatted.
- rojo build -o /tmp/claude-0/build-*.rbxlx: succeeds.
- lune run tests/run.luau combat: 16/16 pass. Covered:
  - target cone, range, point-blank and the extra aim forward
  - cooldowns, including the Zapper Pass halving and jitter tolerance
  - assault-heat rules
  - swept spike crossing, including the airborne / beside / short / diagonal cases
  - isSamePlayer
  - tool builders: Tool class, ToolId, welds, unanchored/non-collide parts, trail, tip glow
  - spike strip builder: anchored, on the ground, trigger volume, neon spikes
  - EffectsController loading headless, rarity-tag rules, bolt polyline bounds, tag text
- Full suite: 143 passed, 2 failed. Both failures are in carbuilder.spec.luau (ice_cream height, limo length), another slice that is still being edited.
- Geometry renders: a scratch Lune dump through the real harness, then tools/render.py, inspected with Read.
  - The bat, Zapper and Spike Strip were each rendered standalone and held by a block dummy using the real Tool.Grip math (R6 grip, arm raised forward). The dropped strip was rendered on a road with a car for scale.
  - I checked numerically that the bat leans 20° back over the shoulder and the Zapper barrel points forward (-Z).
  - Spike size was enlarged after the first render for readability.
  - Final preview: docs/previews/combat_tools.png.
- Cross-checked the APIs I call against slices that already exist, and they match: DataService.get/isLoaded/Loaded, MonetizationService.hasPass/PassChanged, PlotService.getPlotIndex/isLocked, WantedService.addHeat, VehicleController reading model TiresPopped against GetServerTimeNow, PoliceService tagging the Police model, CarBuilder siren part names, VehicleClient touch-button layout (no overlap with the SPIKES button). No other slice touches CameraOffset, PlatformStand, WalkSpeed or ProximityPromptService.Enabled.
- Checked every property name I set against the API dump (roblox.yml), including LayerCollector.ResetOnSpawn on BillboardGui.

---
## Files: src/server/Systems/WantedService.luau, src/server/Systems/PoliceService.luau, tests/spec/police.spec.luau, docs/previews/police_heli.png, docs/previews/police_routes.png

### Public API
WantedService (src/server/Systems/WantedService.luau) — SPEC §6 API:
- addHeat(player, stars, reason?) — ignored during 8s post-bust grace and while busting; halved (floor) during a brand-new player's first 30s (DataService.getSessionInfo(player).isNew, fallback data.tutorialDone == false); clamps to MAX_STARS; any crime refreshes the decay timer even at max stars. reason "admin" bypasses grace + halving.
- getStars(player): number
- clear(player, reason?) — "decay"/"spray" count as escapes: RewardsService.progress(player,"escape",1) and "escape3" if the chase peak was >= 3 (lazy, pcall). "purchase"/"admin"/"busted" do not.
- bust(player): boolean — penalty floor(min(cash*BUSTED_CASH_PENALTY, GarageService.incomePerSec*BUSTED_MAX_PENALTY_SECONDS)) via DataService.spendCash (fallback addCash(-x)); stats.busted += 1 + markDirty; VehicleService.eject(car) then Stolen -> TheftService.fail(car,"busted"), Loot -> VehicleService.destroy(car,"busted"); clears stars; Busted remote (lostCash); EventFeed if peak >= 3; Busted signal; character pivoted to MapLayout.bustedReleaseCFrame() (+jitter) after 1.1s; 8s grace.
- Changed: Signal(player, stars, old); Busted: Signal(player)
- Spray: listens to VehicleService.SprayAttempt; charges SPRAY_COST_PER_STAR*stars (Notify on failure, 4s cooldown), clear("spray"), repaints Paint="primary" parts one random bright color, Health = MAX_HEALTH (car.health + model attribute), clears TiresPopped, Notify "Fresh paint! Cops lost you.", Sound "Purchase", Effect "Confetti" {position}.
- Decay: every 0.25s; reset while PoliceService.isSeen(player) (lazy); DECAY_DELAY[stars], then one star per DECAY_STEP.
- Extras: set(player, stars, reason?), isInGrace(player), getPeak(player).
- Player attributes: Wanted (0..5), WantedSeen (bool; true while a cop/heli sees you, HUD can flash the stars when false).
- Test hooks: _setHooks, _penalty, _adjustHeat, _decayDelay, _tickDecay, _decayPass, _repaint, _addPlayer, _removePlayer.

PoliceService (src/server/Systems/PoliceService.luau):
- isSeen(player): boolean — any of the suspect's chasing units within SIGHT_RANGE with raycast line of sight (or within 60 studs), any other suspect's unit within 60 studs, or their heli within 110 studs horizontal with LOS. Always false while the suspect is inside their own garage (safe house).
- getUnitCount(player?): number
- buildHeli(): Model — harness-compatible builder. Model "PoliceHeli": PrimaryPart "Body" (anchored, everything else welded), "RotorHub" on Weld "RotorWeld", Blade1/2, RotorBlur, SirenRed/SirenBlue, "Searchlight" (SpotLight, Attachment BeamStart, Beam "LightCone"), anchored "SpotDisc" (BeamEnd, PointLight), POLICE SurfaceGuis, tag "PoliceHeli". 26 parts.
- Units: VehicleService.spawn(Cars.Police, "None", laneCF, "Police") (falls back to Cars.Police.id), unanchored, SetNetworkOwner(nil), VehicleController.new(model, Cars.Police, {isServer=true, nitroSeconds=3}), stepped on RunService.PreSimulation (dt clamped to MAX_DT). Each car gets tag "Police", attributes SuspectUserId, Siren (bool) and SpeedMultiplier (by stars 0.82/0.9/0.97/1.03/1.08, +0.12 catch-up when far and hidden), and car.data.police.
- AI every AI_TICK: roles chaser / flanker / interceptor; box-in ring when the suspect is slower than 20; pure pursuit with prediction when feasible (_usePursuit), else grid routing (_nextWaypoint) and the control law (_drive); unstuck; crash damage via VehicleService.damage (wrecked units replaced after 6s); rubber-band PivotTo a hidden lane behind the suspect.
- Bust check every 0.25s writes player attribute BustProgress (0..1) and calls WantedService.bust.
- Ramming: chassis Touched by a driven player car with relative speed > 40 where the player is the one closing -> addHeat(Heat.copHit), max 1 per 10s, with Notify.
- Heli at HELI_AT_STARS (max 3 per server), parented to Workspace.Effects.
- Units leave (sirens off, routed away) when stars hit 0 or on bust, and despawn after 3s once no player is within 140 studs (max 15s); destroyed on PlayerRemoving.
- Pure helpers (tested): _steerToward(fwd, toTarget) -> (steer, angleDeg); _nextWaypoint(pos, target, fwd?, speed?, keep?) -> (wp, isTurn); _roadAnchor; _roadLines; _drive(fwd, fwdSpeed, toAim, cornering, wpDist) -> (throttle, steer, handbrake, angle); _usePursuit; _newStuck/_updateStuck; _isRam; _allocateUnits; _orientedLane; _spawnCandidates.

### Contract deviations
- VehicleService was not in the tree while this was written. PoliceService calls VehicleService.spawn(Cars.Police, "None", laneCF, "Police") (the def, as the task says) and retries with Cars.Police.id if that errors, remembering which form works. VehicleService must accept one of these forms.
- VehicleService needs to exclude kind "Police" from its own driverless-car handling: anchoring at rest after PARK_ANCHOR_AFTER, abandon/despawn rules, and any server settling VehicleController. Two controllers on one chassis would disable each other's movers via _suppressForeignMovers. As a guard, PoliceService un-anchors police chassis and resets network ownership every 0.5s.
- Police crash damage is sampled by PoliceService (horizontal velocity change per AI tick, same threshold and scale as player cars) and sent to VehicleService.damage(car, amount), because VehicleService's damage sampling only covers cars with drivers. If damage() is missing, PoliceService tracks health itself.
- isSeen is stricter than 'within SIGHT_RANGE': it also needs raycast line of sight (or being within 60 studs), so breaking sight around buildings lets stars decay. The heli sees within 110 studs horizontal with line of sight.
- New design addition, the own-garage safe house: a suspect inside their own garage interior (PlotIndex attribute + MapLayout.plotAt) can't be busted and isn't seen; cops line up outside the door.
- Ram heat requires relative speed > 40 and that the player's car is the one closing (playerClosing > copClosing and > 10), so cops rear-ending a fleeing player don't add heat.
- Helicopter: moved by setting the anchored Body's CFrame each Heartbeat, with velocity-limited smoothing (max 95 studs/s so fast cars can outrun it), instead of the AlignPosition in SPEC §6; the rotor spins server-side via Weld.C0. Tagged "PoliceHeli", not "Police", so car-centric client code ignores it. SpotLight range is engine-capped at 60, so the visible searchlight is a camera-facing Beam cone plus a neon ground disc with a PointLight.
- The research rule 'brake when |angle| > 70 and speed > 40' is replaced by a graded law: speed held to corner speed above 45°, a straight-line brake then K-turn above 100°, reversing onto close points behind, a curvature limit against orbiting, and braking in time for corners. Routing also penalizes turns that can't be braked for in time and keeps a committed route unless another is clearly better. Pure pursuit only runs when the turn is feasible.
- WantedService: reason "admin" bypasses the bust grace and new-player halving, matching how AdminService calls clear(..,"admin") and addHeat(..,"admin"). Only "decay" and "spray" clears count as escapes. "Brand-new player" uses DataService.getSessionInfo(player).isNew, an extra DataService function, falling back to data.tutorialDone == false.
- Extra player attributes for the HUD: WantedSeen (bool) and BustProgress (0..1). HUDController doesn't exist yet, so nothing reads them.
- Extra feedback remotes: first-time 'Cops are on you' hint, 'ESCAPED!' Notify + Whoosh + Confetti on escape by decay, EventFeed for escapes and busts at 3+ stars, Notify when the heli arrives and when you ram a cop.
- Tooling: both stylua binaries on PATH (/root/.cargo/bin/stylua and /usr/local/bin/stylua 2.6.0) lack Luau support and fail on every .luau file in the repo. I formatted with the StyLua 2.3.0 build in the session scratchpad (/tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/stylua-dl/stylua).

### Known issues
- Nothing has run in the real engine: VehicleService, HUDController and RewardsService weren't in the tree. Spawning, despawn, damage/wreck and spray only become active once VehicleService exists; until then init() logs a warning and police don't spawn.
- The AI was tuned against a kinematic model (no sideways slip, no collisions, no traffic) using the Config/Vehicle formulas. Real Roblox physics will need a playtest pass on CORNER_SPEED, TURN_IN_DIST, the K-turn speeds and SPEED_MULT_BY_STARS.
- Cops tailgating a suspect who turns sharply at speed overshoot onto the sidewalk or into corners. This is kept on purpose as a 'juke the cops' escape, and crashing causes cop damage.
- The heli's position and rotor are written server-side every Heartbeat (2 properties per frame per heli, max 3 helis); clients don't interpolate anchored CFrames, so motion may look slightly stepped on laggy connections.
- Line-of-sight rays ignore vehicles, characters, Effects and Dealership, but they respect CanCollide, so collidable street props (lamps, trees) can occasionally block 'seen'.
- Strict-mode type checking wasn't run because no Luau type checker is installed; external system boundaries are typed `any`.
- Research extras not built: police spike strips at 3★ and anchored roadblocks at 4★. Good follow-ups for chase variety.
- The bust release teleport waits 1.1s so the BUSTED stamp plays at the scene; the character isn't frozen during that window. A stun or freeze could be added if needed.
- Running `stylua` from PATH fails on every .luau file in the repo (those builds lack Luau support); the orchestrator should point formatting at a Luau-enabled StyLua (2.3.0 is in the scratchpad).

### Verification
selene on WantedService.luau, PoliceService.luau and police.spec.luau: 0 errors, 0 warnings. StyLua 2.3.0 (Luau-capable scratchpad build) --check: formatted. `lune run tests/run.luau`: 156 passed, 0 failed (26 in police.spec.luau). `rojo build -o /tmp/claude-0/build-*.rbxlx`: succeeds.

police.spec.luau covers:
- steering sign against the yaw convention
- roadLines / roadAnchor on 400 random points
- grid routing on 600 random trips: every leg sampled on asphalt, always arrives, within Manhattan + 2 blocks
- routing hysteresis and the turn-feasibility costs
- the _drive control law (cornering, K-turn, anti-orbit)
- unstuck in both directions
- isRam, unit allocation, oriented lanes, spawn candidates
- buildHeli structure: welds, anchoring, RotorWeld C0, no collisions, part budget
- WantedService pure helpers, plus addHeat / Changed / clamp, new-player halving, decay escapes (escape and escape3, EventFeed), bust (penalty, TheftService.fail / destroy, Busted remote, grace) and spray (cost, clear, repaint, repair), using injected fakes
- a kinematic driving simulation (60 routed trips, half starting backwards): all arrive, worst off-road excursion <= 6 studs
- a chase simulation (20 chases against a lane-driving suspect): >= 80% caught, mean excursion <= 3

Scratch tuning sweeps with the same models: 1,000+ routed trips at cop speeds 0.82 / 1.08 / 1.2 had mean excursion ~0.0 and all arrived. Chases had mean excursion 0.6–1.4 studs and p90 ~3 (sidewalk).

Rendered and inspected:
- docs/previews/police_heli.png: the heli on its own, plus a chase scene with a police cruiser and a suspect car
- docs/previews/police_routes.png: route overlay on the city grid

Re-read both modules end to end. Checked integration against code already in the tree: TheftService.fail(car, reason) is idempotent and handles "busted"; AdminService, MonetizationService, CombatService, TheftService and DealershipService call addHeat/clear with matching arguments; VehicleController's API (new/setInput/step/destroy, model SpeedMultiplier attribute, throttle and steer conventions) matches what the AI feeds it. No deprecated APIs in either module; Instance.new is used only in the heli builder and Effects-folder creation.

---
## Files: src/client/Controllers/StateController.luau, src/client/Controllers/SoundController.luau, src/client/Controllers/NotificationController.luau, src/client/Controllers/WaypointController.luau, tests/spec/clientcore.spec.luau, docs/previews/clientcore_notifications.png, docs/previews/clientcore_waypoints.png, docs/previews/clientcore_theft_alert.png, docs/previews/clientcore_offline.png

### Public API
StateController (first in client ORDER; no dependencies on other controllers)
- get(): Snapshot? | isReady(): boolean | onReady(fn(snapshot)): runs at once (task.spawn) if a snapshot exists, otherwise queues fn | waitForSnapshot(timeout?): Snapshot? | getSetting(key): boolean?
- Changed: Signal(snapshot, previous?) fires on every snapshot | Ready: Signal(snapshot) fires once
- getEventState(): {[name]: endsAt} + EventStateChanged(state, prev)
- getHotDrop(): {active, position?, carId?, mutation?, endsAt?, startsAt?} + HotDropChanged(state, prev)
- getTheft(): {active, endsAt?, carId?, targetPlot?} + TheftChanged(state, prev)
- Test/internal helpers: applySnapshot(any): boolean, applyEventState, applyHotDrop, applyTheft, sanitizeEventState, sanitizeHotDrop, sanitizeTheft.
- start(): listens to DataSnapshot, EventState, HotDropState and TheftState first, then polls GetSnapshot (pcall-wrapped, backoff 0.5s to 3s, retries forever) until data arrives. A push that lands first wins.

SoundController
- play(key, position?): Sound? — one-shot from Config/Sounds with ±5% pitch variation.
  - No position: UI sound, pooled up to 4 per key in SoundService.HC_UISounds.
  - With position: world sound on a pool of 20 Attachments on an anchored part in Workspace.HC_ClientSounds; skipped beyond 450 studs from the camera.
  - Returns nil when the key is unknown or sfx is off.
- playLoop(key, parent?, channel?: "sfx"|"music"): Sound | stopLoop(sound)
- setEnabled(enabled, channel?) or setEnabled(channel, enabled) | isEnabled(channel) | setVolume(channel, 0..1). Channels are SoundGroups HC_SFX and HC_Music, driven by snapshot settings.sfx and settings.music.
- Sound remote: listens for (key, pos?).
- Engine loop: 6 slots on the closest driven Vehicle-tagged cars within 220 studs. A car counts if it has a seated driver or DriverUserId > 0, or if it is Traffic/Police; Parked, Dealership and HotDrop are silent. PlaybackSpeed = 0.7 + 1.1 × speed/topSpeed, ratio clamped 0..1.3 and smoothed.
- Sirens: 3 slots on the closest Police-tagged cars within 250 studs.
- CityAmbience loop on the music channel at 60% volume, ducked while the player's Driving attribute is true.
- Preloads all sound ids with PreloadAsync (pcall).
- Pure helpers: enginePitch, isEngineEligible, topSpeedFor, selectNearest.

NotificationController
- toast(kind, text, duration?): top-right stack, max 4. Slides in with a kind colour and emoji icon and a timer bar; tap to dismiss; identical toasts merge with a "×N" badge. Listens to the Notify remote.
- announce(title, subtitle?, color?, sound?): centre banner at 45% screen height. Scale-pop and wiggle, glossy gradient title, shine sweep across a neon ribbon. Queued, about 3s each, shorter when a backlog exists (max 6 queued); default sound "Whoosh". Listens to Announce.
- feed(richText): left-side lines, newest on top, max 5, fade after 8s. Listens to EventFeed.
- cashPopup(amount, worldPos?): with a position, a pooled BillboardGui pops, rises and fades (gold when ≥ $10K, red when negative). Without one, it rises into HUDController.getCashAnchor(), falling back to top-centre. Listens to CashPopup.
- offlineEarnings(amount, seconds): modal with count-up, rotating god rays and a pulsing COLLECT button that bursts coins into the cash counter. Repeat calls merge into one modal; auto-closes after 30s. Listens to OfflineEarnings.
- carStolenAlert(thief, carId, mutation, active): pulsing red edge vignette (4 gradient frames), swaying flashing banner "🚨 THIEF IS STEALING YOUR GOLD PHANTOM GT!" with a "BONK them" call to action. Siren loop drops to 45% volume after 5s. Live waypoint "stolen_car" follows the thief's car via WaypointController.track. A same-car alert replaces the old one (takeover); active=false clears it; a safety timeout of about 190s also clears it. Listens to CarStolenAlert.
- isAlertActive(): boolean.
- Pure helpers: kindStyle, trimOldest, formatCashDelta, richEscape, carLabel, stolenAlertText, bannerHold.

WaypointController
- set(id, position: Vector3?, color?, label?): nil position clears. Listens to the Waypoint remote.
- track(id, target: Instance | () -> Vector3?, color?, label?): moving target; clears itself when a tracked Instance is destroyed.
- clear(id) | clearAll() | has(id) | getPosition(id) | step(dt) (test hook).
- Each waypoint draws:
  - a core beam plus a scrolling sparkle beam from the character's HumanoidRootPart (attachment HC_WaypointStart) to an anchored invisible part in Workspace.HC_Waypoints;
  - a 140-stud light pillar;
  - a bobbing BillboardGui with pin, emoji, label and distance ("245m", 3 studs = 1 m);
  - a screen-edge arrow when off-screen (rotating tip, upright icon, distance on the inner side) in ScreenGui HC_WaypointArrows.
- Auto waypoints:
  - "home": own plot drop-off floor while driving a car whose Kind is Loot or Stolen.
  - "hotdrop": while HotDropState is in countdown or live (stale drops expire).
  - Auto waypoints never override an externally owned id and hide when another waypoint is within 30 studs.
- Pure helpers: formatDistance, iconFor, edgeArrow(screen, viewport, margin: number | {left, top, right, bottom}, topMargin?, camRel?), isNearAny, hotDropVisible.

### Contract deviations
- Theme has no per-kind notification colours, so toast kinds map to existing Theme colours: info=Secondary, success=Cash, money=Gold, warning=Warning, error=Danger.
- Config/Sounds has no music track, so the snapshot 'music' setting controls the CityAmbience loop (SoundGroup HC_Music); 'sfx' controls everything else (HC_SFX).
- SPEC says engine loops are for cars 'with drivers'. AI-driven Traffic and Police cars have no seated player, so they also count as driven; abandoned Loot/Owned/Stolen cars are silent.
- SoundController.setEnabled's signature isn't specified, so it accepts both (enabled, channel?) and (channel, enabled). setVolume and isEnabled were added.
- The edge-arrow ScreenGui (HC_WaypointArrows) is built with Kit.new instead of Kit.screen. It needs IgnoreGuiInset=true and 1:1 viewport pixels for WorldToViewportPoint; each arrow carries its own UIScale using Kit.screen's scale formula.
- CarStolenAlert uses two ScreenGuis: the vignette is in HC_TheftAlert (IgnoreGuiInset, so it covers the topbar) and the banner is in the inset-aware HC_Banners (so it sits under the HUD cash counter).
- The hot-drop auto waypoint also shows during the countdown (server sends active=false with startsAt and position), matching EventsClient.hotDropPhase, instead of only while active=true.
- Added public WaypointController.track(id, target, ...) for moving targets. NotificationController uses it for the victim's live 'stolen_car' arrow; TheftService already uses that id and only clears it.
- Uses the optional HUDController.getCashAnchor() (implemented by the HUD slice) as the target for HUD cash popups and the coin burst, with a top-centre fallback.
- Auto 'home' waypoint: if another system sets the same id, it takes ownership and auto logic won't clear it. When the server's 'theft' DROP OFF waypoint is within 30 studs, the auto one is hidden to avoid duplicate arrows.

### Known issues
- No Luau type-checker pass. I downloaded luau-lsp, but running a downloaded binary was blocked in this environment, so --!strict type warnings are possible even though selene, the tests and the headless smoke run are clean.
- Preview PNGs are approximations: real GUI instance trees rendered by a custom PIL renderer with DejaVu Sans Bold in place of FredokaOne. The world beam/pillar is drawn illustratively and the white HUD boxes are mock placeholders for other slices.
- Toasts (DisplayOrder 40) can briefly cover a right-edge waypoint arrow when the target is near horizon height and 3-4 toasts are stacked; the arrow reappears when they expire.
- SoundController uses classic Sound objects per SPEC, not the newer AudioPlayer/AudioEmitter API. Engine loops parent into each car's chassis; slots self-heal when a car despawns.
- The per-frame paths (engine pitch, waypoint arrows) were smoke-tested headlessly with a faked camera projection, not in a live Roblox client. Tuning (volumes, the 30-stud dedupe radius, arrow insets) may need a playtest.
- Waypoints and edge arrows don't hide when settings.hideHud is on. hideHud is HUDController's concern; this is easy to add if wanted.
- The victim's live 'stolen_car' arrow finds the thief by Name/DisplayName from the CarStolenAlert payload. If two players share a DisplayName it may track the wrong one; a thief userId in the payload would fix this.

### Verification
All checks were run from /home/user/HotwireCity:
- stylua --check on my 5 files: clean.
- selene on my 4 controllers: 0 errors, 0 warnings.
- rojo build -o /tmp/claude-0/build-*.rbxlx: succeeds.
- lune run tests/run.luau: 313 passed, 0 failed. This includes 13 clientcore tests covering:
  - StateController onReady/Changed/sanitizers;
  - engine pitch, eligibility, top speed and nearest-slot selection;
  - toast trimming, cash formatting, rich-text escaping, car labels and banner pacing;
  - distance formatting, edge-arrow math (on-screen, four edges, behind, in-camera-plane, diagonal, per-side insets, degenerate viewport, huge values) and the hot-drop phase helper.

Beyond the test suite, a headless smoke/capture script in my scratchpad built every UI path through the real harness. It shimmed the engine events Lune lacks and found and fixed three bugs:
- re-parenting engine/siren Sounds that had been destroyed with their car would throw;
- edge arrows landed on the wrong side for targets in the camera plane (fixed by switching to a camera-space direction);
- `Net.invoke` asserting would end StateController's snapshot retry loop.

It also exported the GUI trees, which I rendered with a custom PIL GUI renderer into docs/previews/clientcore_{notifications,waypoints,theft_alert,offline}.png. Iterating on those previews fixed several layout clashes:
- the banner overlapped the toasts and feed;
- left-edge arrows sat on the HUD side menu;
- the alert banner overlapped the cash counter;
- the marker label was too small.

I re-read all four controllers end to end, and cross-checked how the slices written in parallel (CombatClient, VehicleClient, EffectsController, HUDController, EventsClient, TutorialController, TheftService, EventService) call my APIs and ids.

---
## Files: src/client/Controllers/HUDController.luau, src/client/Controllers/TutorialController.luau, tests/spec/hud.spec.luau, docs/previews/hud_desktop.png, docs/previews/hud_desktop_safe_areas.png, docs/previews/hud_chase.png, docs/previews/hud_busted.png, docs/previews/hud_phone_safe_areas.png, docs/previews/tutorial_steal.png, docs/previews/tutorial_phone.png

### Public API
HUDController (client ORDER #4; init() is empty, start() builds the UI and runs a 10 Hz loop plus a Heartbeat for cosmetics):
- getCashAnchor(): GuiObject? — the cash pill. This is the optional hook NotificationController already calls for coin bursts and popups. Returns nil in streamer mode.
- getMenuButton(id: string): GuiButton? — ids: "Store", "GearShop", "Index", "Daily", "Contracts", "Playtime", "Rebirth", "Codes", "Settings".
- setFocusMode(on: boolean) — the tutorial uses this to hide the menus and the HOME button; turning it off pops them back in one by one.
- isHidden(): boolean — true while streamer mode (settings.hideHud) is on.
- showBusted(lostCash: number) — plays the BUSTED overlay. The "Busted" remote calls it too.
- getBottomClearance(): number — design pixels used at bottom-center (hotbar clearance, plus the HOME button when it is showing).
- VisibilityChanged: Signal(hidden: boolean).
- HUDController.MENU and HUDController.MENU_TOP_ROW: { {id, icon, caption, color, names} }.
- Pure helpers: clampStars(v, max?), starStates(stars, previous, max?) -> {filled, changed, gained}[], cashTrend(new, old?), theftView(endsAt, now, total?) -> (text, fraction, urgent), playtimeClaimable(playtime, extraSeconds?), rebirthReady(cash, rebirths), gearAffordable(snapshot, cash), homeState(ctx) -> "hidden"|"wanted"|"cooldown"|"ready", gridFit(count, available, cell, pad) -> (cols, rows), countGarage(snap), countDiscovered(snap), menuNameCandidates(id).

What the HUD reads: player attributes Cash, IncomePerSec, VIP, Wanted, BustProgress, Driving, Rebirths, PlotIndex; StateController get/Changed/TheftChanged/getTheft; the Busted remote.
What it sends: Net.fire("GoHome") and Net.fire("SetSetting", "hideHud", false).
It calls MenuController.has (if present), then toggle (or open) with each candidate name until one works. It also uses NotificationController.toast and SoundController.play. All of these are loaded lazily and wrapped in pcall.

TutorialController (client ORDER last):
- isActive(): boolean
- getStep(): (index: number, id: string?)
- skip()
- StepChanged: Signal(index, id)
- Finished: Signal(skipped)
- STEPS: {id, icon, title, hint, hintTouch?, hintPad?, color, timed?, key?}; the ids are money, steal, deliver, collect, dealer. DONE = 6.
- Pure helpers: transition(step, ctx {elapsed, driving, notDrivingFor, delivered, collected}) -> next step; pickNearest(candidates {position, kind}, origin, maxDistance?) -> index? (only kind "Parked"); shouldRun(snapshot) (only when tutorialDone == false); hintFor(stepDef, "touch"|"gamepad"|"keyboard"); keyFor(input) -> "E" / "👆" / "X"; garageCount(snap); stealCount(snap).

How it works: it uses WaypointController.track or set (id "tutorial") and clear. If that fails it shows its own BillboardGui arrow. It adds a pulsing Highlight on the target street car, calls HUDController.setFocusMode, and calls Net.fire("TutorialDone") once at the end or on SKIP.

### Contract deviations
- Theft delivery timer sits at bottom-center, just above VehicleClient's speedometer (184 design px from the bottom), not top-center under the cash. EventsClient already owns the strip under the cash pill: event pills at y=78 and the Hot Drop banner at y=128-246. The thief is driving and looking at the bottom of the screen anyway.
- The left column has 7 buttons: STORE, GEAR, INDEX, DAILY, JOBS (opens Contracts), GIFTS, REBIRTH. CODES and SETTINGS sit in a small row at the top-left. The column wraps into 2 columns when the screen is short, so it never covers the touch thumbstick. On touch, buttons grow from 62 to 76 design px because phones hit Kit's 0.55 scale floor. The caption is 'JOBS' rather than 'CONTRACTS' because the long word shrinks to an unreadable size.
- MenuController did not exist when I finished, so I could not check its window names. HUD buttons try these names in order: Store; GearShop then Gear; Index then CarIndex; Daily; Contracts; Playtime then Gifts then PlaytimeGifts; Rebirth; Codes; Settings. If MenuController exposes has(name), the HUD uses it to pick a name. It calls toggle, falling back to open, and moves to the next name if the call errors. If MenuController is missing, tapping a button shows a 'Coming soon!' toast. MenuController should use the first name in each list.
- The SPEC §7 HUD row mentions Hot Drop and event timers. These are not in the HUD because EventsClient already shows them (pills and the Hot Drop banner).
- Streamer mode (settings.hideHud) hides cash, stars, the bust bar, menus, HOME and the theft timer. Two additions: (1) a small 👁️ button at the top-left stays visible so players can turn the HUD back on (it fires SetSetting('hideHud', false)), because the Settings button is hidden; (2) the 3-second BUSTED stamp still plays, since it is one-off gameplay feedback.
- HOME is also hidden while you are inside your own garage, where it is useless and would overlap GarageClient's LOCK button. It is hidden during tutorial focus mode too. While you are wanted it shows greyed out with 🚨, and tapping it shows the toast 'Lose the cops first!'. It sits above the backpack hotbar, using an estimated 74 real px hotbar height.
- Tutorial step 2 → 3 needs Driving=true and the seat's car Kind must not be 'Owned' or 'Police', so driving your own car out of the garage does not count. Step 3 → 4 fires when the garage count or stats.steals rises (either works). Step 3 drops back to step 2 if the player is out of the car for 2.5 s without delivering. The state machine also jumps ahead when the player moves faster than the tutorial.
- The tutorial card is a GTA-style objective line at bottom-center, 186 design px up so it clears the LOCK button and the speedometer. It moves higher while a theft timer is showing. It is scaled 1.25x on touch. During steps 1-3 the HUD is in focus mode (menus and HOME hidden), capped at 150 s. When no parked car is found yet, step 2 points at a 'STREET' waypoint in front of the garage door. A keycap (E / 👆 / X plus 'HOLD') teaches the hotwire hold.
- StateController.sanitizeTheft drops TheftService's dropped, droppedEndsAt and victimName fields. Because of that, the HUD timer cannot show a separate 'GET BACK IN!' state for a dropped car; it shows the normal countdown and relies on TheftService's waypoint label. Suggested fix for the StateController owner: keep `dropped` and `droppedEndsAt`.
- The tutorial's Highlight is a client-only child of the target car model (Workspace.Vehicles), so it disappears with the car. Other code that loops over a car model's children will see one extra Highlight instance there.

### Known issues
- No Luau type checker (luau-lsp / luau-analyze) is installed, so the --!strict annotations were only linted by selene, not type-checked. I used `any` in a few places on purpose (snapshot reads, the lazily loaded modules).
- The previews come from my own renderer, which approximates Roblox layout. Real engine text sizing, UIStroke thickness under UIScale, and whether UIScale scales around the AnchorPoint may differ slightly. Worth a quick check in Studio's device emulator.
- Wanted stars use the '★' character (U+2605). FredokaOne does not contain it, so it depends on Roblox's font fallback. Confirm it renders in Studio; if not, switch to an ImageLabel star.
- The hotbar clearance (74 real px) and the touch thumbstick reserve (120 real px) are estimates of Roblox core UI sizes. Touch detection reads UserInputService.PreferredInput inside pcall and falls back to TouchEnabled without MouseEnabled.
- The HOME cooldown display (20 s, assumed to match PlotService) only starts if the character actually arrives in their own garage within 2.5 s of pressing. A server rejection therefore shows no fake cooldown, but the countdown can drift slightly from the server's own cooldown.
- The Busted listener uses Net.listen, which waits up to 30 s for the remote. If the remote never appears it logs a warning and the overlay only plays via a direct showBusted() call.
- The tutorial's collect step only advances early if the Cash attribute rises while the player is within 16 studs (horizontally) of the CollectPad; otherwise it moves on after 20 s. If CollectPad is not found, it falls back to the MapLayout position.
- Tutorial progress is not saved. A player who leaves mid-tutorial restarts at step 1 next time, because only tutorialDone is persisted.
- Menu badges are computed on the client from the snapshot: daily canClaim, playtime gifts (sessionSeconds plus time since the snapshot arrived), rebirth cost, affordable gear, and new Car Index discoveries since the INDEX button was last tapped (resets each session). The Store button never shows a badge (no fake urgency).
- The guess at MenuController's API and window names (see the deviations) needs to be reconciled once MenuController is written.

### Verification
- selene on HUDController.luau, TutorialController.luau and hud.spec.luau: 0 errors, 0 warnings.
- stylua --check on the same 3 files: clean.
- rojo build -o /tmp/claude-0/build-*.rbxlx: succeeded.
- lune run tests/run.luau: 314 passed, 0 failed. My hud.spec.luau adds 17 tests covering star fill/flash logic, cash trend, theft timer view, playtime/rebirth/gear badges, HOME state, menu grid wrapping, menu definitions, the tutorial transition function (normal path, shortcuts, fallbacks), pickNearest, shouldRun, hints and keycaps. The boot spec also loads both controllers headlessly.

Runtime check: I ran the real start() code in a headless Lune setup (a patched copy of the test harness with tweens applied instantly and engine-event shims). The full tutorial ran in order: money (4 s) → steal → deliver when Driving goes true → collect when the garage gains a car → dealer after the 20 s fallback → finished after 8 s, with no tick errors. The HUD built with no errors in desktop, phone, chase, busted, streamer and tutorial setups.

Visual check: I dumped the GUI tree my code builds to JSON, rendered it with a small Python layout engine (FredokaOne from Google Fonts, Noto emoji), and looked at every PNG. Things I fixed after looking:
- the cash-pill gloss looked like a flat grey slot (now fades at the edges);
- 'CONTRACTS' was too small to read (now 'JOBS');
- touch targets were too small (bigger on touch);
- the touch tutorial hint was unreadable (shortened, plus the 1.25x scale);
- a keycap was added.

I also drew faint boxes for other slices' screen areas (EventsHUD pills and Hot Drop banner, toasts, event feed, speedometer, hotbar, phone thumbstick and jump button) and confirmed nothing overlaps.

Final previews: docs/previews/hud_desktop.png, hud_desktop_safe_areas.png, hud_chase.png, hud_busted.png, hud_phone_safe_areas.png, tutorial_steal.png, tutorial_phone.png.

Preview tooling is in the scratchpad only, not in the repo: /tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/hudprev/dump.luau, render_gui.py and the patched harness.luau.

---
## Files: src/client/Controllers/MenuController.luau, tests/spec/menus.spec.luau, docs/previews/menus_sheet.png, docs/previews/menus_index.png, docs/previews/menus_phone.png

### Public API
MenuController (src/client/Controllers/MenuController.luau). Every menu is a Kit.window inside one ScreenGui named "Menus" (DisplayOrder Theme.Layers.Menus, IgnoreGuiInset=true). Each window Frame is named by its canonical menu name, e.g. PlayerGui.Menus.GearShop.

SPEC API:
- open(name): boolean. Closes any other open menu. Returns false for unknown names or a failed build.
- close(name?): boolean. With nil, closes whichever menu is open. Returns false if that menu was not open.
- toggle(name): boolean. Returns false only for unknown names.
- isOpen(name): boolean.
- init() does not yield. start() builds the gui, connects StateController.Changed, the Cash/IncomePerSec/Rebirths attribute signals, Escape/ButtonB to close and the OpenUI remote, then runs a 1 Hz ticker loop.
- Canonical names: "GearShop", "Store", "Index", "Daily", "Contracts", "Gifts", "Rebirth", "Codes", "Settings".

Extra public helpers:
- has(name): boolean. HUDController probes this.
- getOpen(): string?
- closeAll()
- Opened: Signal(name) and Closed: Signal(name).
- NAMES and ALIASES. Aliases are case-, space-, '_'- and '-'-insensitive. Gear/Shop/Upgrades/Tools -> GearShop, Robux -> Store, CarIndex/Collection -> Index, Playtime/PlaytimeGifts/Gift -> Gifts, Jobs/Missions/Quests -> Contracts, DailyReward(s)/Streak -> Daily, Code -> Codes, Options -> Settings. All HUDController button names resolve.
- Pure helpers, all unit tested: resolveName, secondsUntilUtcMidnight, formatHhMm, durationWords, formatMultiplier, fmtNum, rewardInfo, dailyTileStates, playtimeTiles, contractRows, contractProgressText, upgradeIds, upgradeRows, upgradeValueText, toolIds, toolRows, storeItems, indexGroups, indexTotals, carSources, rarityColor, cameraCFrame, rebirthView, bestCar, garageBusy, settingValue, windowScale.

Remotes sent (all via Net.fire):
- BuyUpgrade(id)
- BuyTool(id)
- ClaimDaily()
- ClaimPlaytime(index)
- RedeemCode(text): whitespace stripped, 1–32 chars.
- Rebirth(): only after a second tap within 4s.
- SetSetting(key, bool): the switch flips immediately (optimistic). The local override is dropped once a snapshot confirms it, or after 4s. music/sfx are also applied at once through SoundController.setEnabled (lazy).

Remote listened: OpenUI(name) -> open(name), plus a "Whoosh" sound.

Store buttons call MarketplaceService:PromptGamePassPurchase or PromptProductPurchase (pcall'd). Robux prices come from GetProductInfoAsync (pcall'd and cached); the button shows "R$ BUY" until the price is known.

Dependencies:
- Reads state only through StateController (get/Changed) and the player attributes Cash, IncomePerSec and Rebirths.
- SoundController.play/setEnabled and NotificationController.toast are required lazily and pcall'd.
- CarBuilder is required lazily inside buildCarModel, only when the Index opens.

### Contract deviations
- Store: SPEC says to show 'Store coming soon!' when all passes have id 0. The card appears only when passes AND products are all 0; if only products exist, the passes section is simply left out. With the current config (all ids 0), the coming-soon card shows, plus two buttons that open Codes and Daily.
- The Kit.window close button is replaced by an identical one. Kit's built-in handler calls Kit.close, which sets Visible=false when its tween finishes, so a quick close-then-reopen would hide the reopened window. I don't edit Kit (a foundation file); MenuController runs its own open/close tweens with a reopen token.
- Windows get an extra per-window UIScale (MenuController.windowScale). Kit.screen clamps at 0.55, which leaves text about 7px on phones. Below 500px real height a window grows up to 1.4x to fill the screen. On desktop it never grows. It shrinks only when it would not fit, e.g. on a portrait screen. Kit itself is unchanged.
- Index silhouettes use ViewportFrame.ImageColor3 = near-black on the same viewport instead of recoloring every part (same look, one property). Undiscovered Secret cars show a '❓' card with no model, to keep the mystery. Other undiscovered cars show a silhouette.
- The Index builds previews lazily: after the Index first opens, 3 CarBuilder models per frame. Once built they stay cached for later opens. The selected car (card + detail panel) and the hovered card rotate on RunService.PreRender, connected only while the Index is open.
- Contract cards show a '✅ CLAIMED!' stamp when claimed=true and '✅ DONE!' when progress has reached the goal but claimed is not set yet. The reward shows '≈ $X' (max($500, reward × income)) with 'N min of income' under it.
- Gear Shop prices come from EconomyMath.upgradePrice. Tool prices come from Economy.Tools[id].price, since EconomyMath has no tool price helper. The Zapper shows as OWNED when snapshot.passes.taser is true (Zapper Pass).

### Known issues
- Nothing has run inside real Roblox. TweenService timing, ViewportFrame lighting, nested AutomaticSize on chips, and Escape (Roblox may also open its own menu on Escape) were checked by reasoning and the headless render, not in Studio. Do a Studio playtest on phone emulation.
- Robux prices depend on MarketplaceService:GetProductInfoAsync (the non-deprecated API per docs/RESEARCH.md). If it errors or is missing, buttons stay on 'R$ BUY', which still opens the purchase prompt.
- Index previews: once built, 32 cached CarBuilder models (40 parts or fewer each) stay in ViewportFrames for the session. They render only while the Index is visible, but they use memory. If mobile memory gets tight, destroy them on close (one line in onClose).
- Rebirth refusals (not enough cash, garage busy) come from the server's Notify. The button stays 'REBIRTHING...' for up to 3s and then re-enables on the ticker. The menu also disables the button itself while any garage slot is Driving or BeingStolen, mirroring RebirthService.
- Streamer mode (hideHud) is sent optimistically, but HUDController only hides once the snapshot arrives (about 0.1s), because HUD has no public setter.
- The backdrop is a full-screen button: while a menu is open it blocks the HUD and the touch thumbstick. Tapping anywhere outside the window closes the menu (standard modal behavior).

### Verification
Commands were run in /home/user/HotwireCity.

Lint, format, build:
- selene on src/client/Controllers/MenuController.luau and tests/spec/menus.spec.luau: 0 errors, 0 warnings.
- stylua: the system stylua lacks Luau support, so I used the Luau build at /tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/stylua-luau/bin/stylua. Formatted, then `--check` came back clean.
- rojo build -o /tmp/claude-0/build-$RANDOM.rbxlx: built.

Tests:
- `lune run tests/run.luau`: 343 passed, 0 failed, including 28 in menus.spec.
- menus.spec checks against the real server rules:
  - every streak/claim-day combination against RewardsService._dailyView/_dailyClaim;
  - every 'ready' gift tile is accepted by RewardsService._canClaimPlaytime;
  - bestCar matches RebirthService._plan;
  - the multiplier text matches RebirthService._formatMultiplier;
  - upgrade prices match EconomyMath for every level;
  - every HUDController.MENU / MENU_TOP_ROW button resolves to a real menu;
  - a UTC-midnight countdown always lands on the next dayNumber.
- Card sort order is tested: contracts put unfinished first and keep a stable order; Index groups follow Rarity.Order with the cheapest car first; upgrades show in a fixed order.

Visual check:
- I adapted the HUD slice's headless GUI pipeline in my scratchpad (/tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/menuprev/).
- dump_menus.luau runs the real MenuController in Lune and serializes the PlayerGui tree, including each ViewportFrame's camera CFrame and car parts.
- render_menus.py is an extended copy of render_gui.py. It adds RichText colors, word wrap, nested AutomaticSize, grid alignment, and a perspective render of the viewports, so the camera framing is checked for real.
- I looked at every menu on desktop (1280x720) and phone (844x390) and fixed what I saw:
  - contract titles overflowing;
  - the stamp overlapping the bar text;
  - the Index grid changed from 4 to 5 per row;
  - menus too small on phones (now windowScale);
  - an empty coming-soon store (added links).
- Final previews: docs/previews/menus_sheet.png (12 states), menus_index.png (3D cards, silhouettes, Secret ❓), menus_phone.png.

Interactions:
- menuprev/interact.luau fires the real Activated/FocusLost handlers headlessly. 38 checks pass, with no warnings logged:
  - buy an upgrade, and an unaffordable one is blocked;
  - tab switch, buy a tool, owned tool blocked, OWNED badge appears after the snapshot;
  - daily claim goes pending, then shows the countdown;
  - claim a gift;
  - Index selection and detail panel, undiscovered cars stay hidden, a Secret car discovered while the Index is open builds its model;
  - rebirth needs a second tap, then goes pending;
  - code is trimmed and redeemed, empty codes are blocked, Enter redeems;
  - settings switches update optimistically;
  - the Store link opens Codes;
  - close button, toggle twice, backdrop and close() with nothing open all behave.

I re-read the whole file end to end. That pass found two bugs, both fixed:
- Lune can't read ViewportFrame.CurrentCamera, so the code now keeps its own reference to each camera.
- A Secret car discovered while the Index is open now gets its model right away.
