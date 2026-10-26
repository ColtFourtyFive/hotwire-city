## Files: src/shared/Vehicle/VehicleController.luau, src/client/Controllers/VehicleClient.luau, src/client/Controllers/WheelAnimator.luau, tests/spec/vehicle.spec.luau, docs/previews/driving_hud.png

### Public API
VehicleController (Shared/Vehicle/VehicleController):
- VehicleController.new(model: Model, def: CarDef, opts: { isServer: boolean, nitroSeconds: number?, infiniteNitro: boolean? }) -> Controller. Creates on Chassis: VectorForce "Suspension_FL/FR/RL/RR" (RelativeTo World, ApplyAtCenterOfMass=false, Attachment0 = CarBuilder WheelXX attachment; falls back to estimated "WheelXX_Fallback" attachments if missing), Attachment "DriveAttachment" + VectorForce "Drive" (ApplyAtCenterOfMass=true), Attachment "UprightAttachment" (X axis = chassis up) + AlignOrientation "Upright" (OneAttachment, PrimaryAxisParallel, PrimaryAxis=world up, disabled by default). All tagged with attribute HCVehicleMover=true.
- controller:setInput({throttle, steer, handbrake, nitro}) (clamped; NaN/non-number -> 0; non-boolean flags -> false)
- controller:step(dt) (dt clamped to [1/240, MAX_DT]; reads AssemblyMass live; polls TiresPopped (Workspace:GetServerTimeNow() deadline) and SpeedMultiplier attributes every 0.2s; anchored chassis -> forces zeroed)
- controller:destroy() (zeroes forces, destroys created instances, re-enables suppressed foreign movers; idempotent)
- Extras: controller:setNitroTank(seconds?, infinite?), controller:refillNitro(fraction?), controller:flipUpright()
- Exposed state: speed, forwardSpeed, lateralSpeed, grounded (0..4), nitro (0..1), boosting, drifting, tiresPopped, speedMultiplier, vMax, yawRate, upDot, airTime, wheelCompression[1..4] (studs), wheelOffset[1..4] (visual wheel offset vs built hub, studs), wheelGrounded[1..4], wheelRadius, input, wheels (internal), destroyed.
- VehicleController.math (pure, tested): clamp, staticCompression(g,k,downforceG), rayLength(rest,r), mountOffset(rest,staticComp,lift), suspensionAccel, wheelVisualOffset, driveAccel(throttle,vF,vMax,accel,dt), airDrag, lateralAccel, downforce, targetYaw(steer,vF,vMax,drifting?), approachYaw, nitroStep, gripFactorStep, topSpeed, estimateSteerAngle(yawRate,vF,wheelbase,maxAngle), signedAngleTo(cf,target), steerToward(cf,target,fullLockDeg?) (police helper: +1 = right), mph(studsPerSec), uprightCFrame(cf,pos).
- Constants: VehicleController.WHEEL_NAMES, .MOVER_ATTRIBUTE ("HCVehicleMover"), .RIDE_LIFT (0.2).

VehicleClient (Client/Controllers/VehicleClient): init(), start(); Signals Entered(model, controller), Exited(model); isDriving(): boolean, getModel(): Model?, getController(): any, exit() (re-enables Jumping + Humanoid.Jump=true), honk(); flag positionsWheels=false. ScreenGui "DrivingUI" (DisplayOrder Theme.Layers.HUD+1, Enabled only while driving) with Root/Speedometer and Root/Touch (NitroButton, DriftButton, HornButton, ExitButton). CAS actions HC_Handbrake (Space/ButtonX), HC_Nitro (LeftShift/ButtonR1), HC_Horn (H/ButtonY), HC_Exit (F/E/ButtonA) at priority High+50, Sink. Lazily uses StateController.get() (settings.autoAccelerate/sfx, upgrades.nitro, passes.nitro) and SoundController.play(key, pos) via pcall.

WheelAnimator (Client/Controllers/WheelAnimator): init(), start(); tunables RANGE=250, HOT_COUNT=25, COLD_PER_FRAME=6; pure helpers wheelC0(basePos, baseRot, c1, offset, steer, spin) -> CFrame and spinSign(baseRot) -> number; trackedCount(). Tracks tags Vehicle/DisplayCar/DealerCar; stores original weld C0 in weld attribute HC_BaseC0 (client-local).

### Contract deviations
- Suspension mount sign: task text said mount = hub + up*(REST - staticComp + small), which puts the equilibrium BELOW the built pose by 'small' (bump-stop balls would scrape). Implemented mount = hub + up*(REST - staticComp - RIDE_LIFT) with RIDE_LIFT=0.2 so the car rests 0.2 studs ABOVE the built pose (CarBuilder bump-stops sit 0.25 above ground -> 0.45 clearance). Derivation documented in VehicleController.math.mountOffset and verified by a settle simulation test at 60 and 30 FPS.
- staticComp includes the always-on base downforce: g*(1+DOWNFORCE_BASE_G)/(4*SPRING_K) instead of g/(4*SPRING_K), otherwise the resting height would be ~0.18 studs lower than intended.
- Upright AlignOrientation is enabled when airborne (0 wheels) OR tilted (up.Y<0.5) with fewer than MIN_GROUNDED_WHEELS grounded; tilted with >=2 wheels down stays physical so the Stunt Park half-pipe/ramps work. Spec said 'airborne or tilted'.
- Suspension force is applied along chassis up (not hit.Normal) and ray hits with normal·up < 0.2 are ignored, to avoid sideways shoves on curb edges.
- VehicleClient does NOT pose its own wheels; WheelAnimator poses the driven car using VehicleClient.getController() data (exact suspension offsets + steer input, no extra raycasts). Coordination flag: VehicleClient.positionsWheels=false.
- Jump-exit prevention: besides the high-priority CAS Sink on Space/ButtonX, Humanoid Jumping state is disabled while driving (covers the IAS-based PlayerModule and mobile jump button); exit() re-enables it then sets Humanoid.Jump=true. Gamepad exit is ButtonA (Roblox 'jump out' convention) instead of ButtonB so menus keep B.
- Extra feel mechanics not in the spec (local constants in VehicleController, since Config/Vehicle is foundation): drifting refills nitro faster (+0.22 tank/s), drift keeps momentum (bonus capped at 0.5*accel), handbrake scrubs 14 studs/s^2 and boosts yaw x1.35, parking hold below 2.5 studs/s with no throttle, popped tires also reduce grip (x0.75) and accel (x0.7).
- Defensive foreign-mover suppression: a controller locally disables VectorForce/AlignOrientation children of the chassis tagged HCVehicleMover that it did not create (e.g. a server settling controller replicated to the driver), re-checked every 0.2s, restored on destroy. VehicleService should still destroy its server-side controller when a player sits.
- Tooling: /root/.cargo/bin/stylua (2.6.0) was built without Luau syntax support and fails on every file including foundation files; I formatted with the project-pinned StyLua v2.3.0 release binary downloaded to my scratchpad (/tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/stylua-dl/stylua). Other slices will hit the same issue.

### Known issues
- Not exercised in the real Roblox engine (no Studio here): driving feel and tuning are verified only by pure-math tests and a vertical settle simulation. Assumes AlignType.PrimaryAxisParallel aligns the attachment X axis to PrimaryAxis in the same direction (not antiparallel); the 1.5s auto-flip covers it if not.
- Upright torque (M*400) cannot lift a car resting on its side (needs ~M*g*halfWidth); the auto-flip after AUTO_FLIP_AFTER at low speed handles it.
- If the IAS-based PlayerModule ignores the CAS Sink on Space, the disabled Jumping state is what keeps the driver seated; if the TouchJump button doesn't hide while Jumping is disabled it will simply do nothing (EXIT button is the touch exit).
- Horn is local-only (there is no client->server remote for others to hear it).
- Crash shake/sound trigger on any sudden 3D speed drop > 40 studs/s, so hard landings also shake (intended juice).
- WheelAnimator bob raycasts exclude Workspace.Vehicles/Effects/Dealership, characters and the camera, so a car driving on top of another car won't bob visually for observers; other players' cars sit ~0.2 studs above their built pose (RIDE_LIFT) and the bob shows the wheels touching the ground.
- Touch hold buttons release on InputEnded of the same InputObject or when its state is End/Cancel; if a platform reuses objects unusually a hold could stick until the next InputEnded event.
- HUD preview is a PIL approximation of the layout, not an in-engine screenshot (emoji icons render as letters in the mock).

### Verification
selene on all 4 owned files: 0 errors, 0 warnings. StyLua v2.3.0 (Luau syntax, project stylua.toml): formatted, --check clean. rojo build -o /tmp/claude-0/build-*.rbxlx: succeeds. lune run tests/run.luau: 95 passed, 0 failed (vehicle spec: 18 tests, covering: static compression/mount math reproduces built pose + lift for several radii; vertical suspension settle simulation stable at 1/60 and MAX_DT=1/30 from 3 starting heights; suspension clamps; drive curve reaches ~topSpeed within 6s and never exceeds it; braking never flips direction, reverse capped; coasting parks; lateral grip no-overshoot; targetYaw sign/falloff/drift boost; nitro drain time, refill rate, drift refill, infinite; grip recovery time; top-speed modifiers (spikes/nitro/multiplier); visual steer estimate, steerToward, mph; uprightCFrame from upside-down and nose-down; WheelAnimator wheelC0 offset/steer/spin direction for 3 axle orientations and non-identity C1; new()/destroy() instance structure, property types and input sanitizing in Lune; fallback attachments; foreign mover suppression/restore; and EVERY real CarBuilder car (all catalog + police) checked: attachments present, hub height == WheelRadius in built pose, WheelWeld C0 at hub, chassis bottom + lift clears 0.6 curbs, controller builds with no fallbacks). Confirmed PoliceService's calls (new with Cars.Police/{isServer=true}, setInput, step on PreSimulation, destroy) and CombatService's TiresPopped GetServerTimeNow deadline match my implementation. HUD layout mock rendered with PIL and inspected: docs/previews/driving_hud.png (no geometry built by this slice).

---
## Files: src/shared/Vehicle/CarBuilder.luau, tests/spec/carbuilder.spec.luau, docs/previews/cars_1.png, docs/previews/cars_2.png, docs/previews/cars_3.png, docs/previews/cars_4.png, docs/previews/cars_5.png, docs/previews/cars_6.png, docs/previews/cars_lineup.png, docs/previews/cars_mutations.png

### Public API
Shared/Vehicle/CarBuilder (ModuleScript, --!strict, pure instance construction, no services, harness-compatible):
- CarBuilder.build(carId: string, mutation: MutationId?, opts: { forDisplay: boolean? }?) -> Model. Unknown ids warn once and fall back to Cars.List[1]; Cars.Police.id or "police" resolve to Cars.Police.
- CarBuilder.buildDef(def: CarDef, mutation: MutationId?, opts?) -> Model. Works for Cars.Police and ad-hoc defs.
- CarBuilder.applyMutation(model: Model, mutation: MutationId). Recolors and re-materials Paint="primary" parts from Config/Rarity (Gold Foil, Diamond Glass, Galaxy ForceField). Rainbow gets SmoothPlastic plus a static front-to-back hue sweep; clients animate it. Adds a ParticleEmitter "MutationSparkles" (sparkles_main.dds, Rate 5 or 8) to the largest primary part for Diamond and Galaxy. It can be applied again (old sparkles are removed), "None" restores BaseColor/BaseMaterial, unknown values become "None", and it always sets the "Mutation" attribute.
- CarBuilder.styleDims(style: string) -> { length, width, height, wheelRadius }, measured from a cached reference build.
- Extra helpers:
  - CarBuilder.repaint(model, color: Color3) sets BaseColor and re-applies the current mutation, so Gold stays gold.
  - CarBuilder.setHeadlights(model, on: boolean) toggles the Headlight SpotLights.
  - CarBuilder.styles() -> {string} returns all 22 styles.
  - Exported types: BuildOpts, StyleDims.

MODEL CONTRACT as built:
- Model.Name = carId; PrimaryPart "Chassis" (Part, Transparency 1, the only collidable body part, CanQuery/CanTouch true, unanchored). Pivot = Chassis CFrame, facing -Z. Built pose has the ground at y=0 with wheels resting on it.
- Chassis children:
  - Attachments WheelFL/WheelFR/WheelRL/WheelRR at the hub centers (both .CFrame and .Position are set).
  - Welds "WheelWeld_FL".. with Part0=Chassis, Part1=Wheel_XX, C0=hub offset, C1=identity.
- Wheel_XX: Cylinder Parts, axis along local X, size (tireWidth, 2r, 2r). Rim_XX cylinders are WeldConstraint-ed to their wheel, so they follow C0 edits.
- DriverSeat (VehicleSeat): Disabled, CanTouch/CanCollide false, MaxSpeed/Torque/TurnSpeed 0, no HUD, invisible, massless, welded. Placed so a seated avatar's head clears the roof. On meme cars the rider sits visibly on the sausage, duck, couch cushion or toilet bowl.
- 2 BumpStop Ball parts (diameter 1) under the axles, bottoms 0.25 above the ground, collidable, invisible, massless.
- DriverSeat and BumpStops are omitted with forDisplay=true; everything else stays.
- Every other part is CanCollide/CanQuery/CanTouch false, Massless, unanchored, with a WeldConstraint child (Part1 = itself, Part0 = Chassis, or the wheel for rims).
- Paint attribute is "primary", "accent" or "glass" (glass is 0.3 transparent Glass). Primary parts also carry BaseColor and BaseMaterial.
- Lights: "Headlight" is Neon with a child SpotLight "Beam" (Enabled=false, Face=Front), as a Block or a Ball for compact bug-eyes, never rotated. "Taillight" is Neon red. Police have SirenRed and SirenBlue (Neon). Other Neon parts: Blinker, TaxiSign, RoofLight, Beacon, Thruster, HoverGlow, Underglow, SideLine, TubWater.
- Model attributes: RideHeight (chassis-center height above ground), WheelRadius, Length, Width, Height (measured visible extents), Style, CarId, Mutation. ModelStreamingMode = Atomic. Nothing is tagged.
- Sizes: every car is ≤16 long (the limo is 17.6, ≤18), ≤8.5 wide and ≤12 high. Part counts are 29–40, counting chassis, seat and bump-stops.
- All 22 CarStyles are implemented with distinct silhouettes, plus per-car touches:
  - rustbucket: rust, primer door, duct tape, odd rim
  - grandma_sedan: whitewalls, white roof, always-on blinker
  - yellow_cab: checker band, TAXI sign
  - pizza_van: pizza slice on the roof
  - bull_charger: horns
  - stallion_gt: double stripes
  - neon_drift: neon underglow
  - stretch_limo: hot tub on the roof
  - bank_truck: money sacks, vault door
  - night_raven: bat fins
  - gold_rush: Foil body
  - mini_tank: commander in the hatch
- SurfaceGui labels (TAXI, POLICE, RETIRED, PIZZA, $ BANK $, ICE CREAM) use FredokaOne with MaxDistance 160.

### Contract deviations
- Chassis density: the task text said 'density ~0.7', but SPEC §8 (the contract) says AssemblyMass should be about 900–3000. I followed the spec: density = targetMass / chassisVolume for each style, clamped to 0.7–100. Targets: compact/toilet 900–950, sedan 1250, police 1500, SUV 1900, monster 2600, armored/tank 3000. Friction 0.3, elasticity 0 and weights 1/1 match the task. A heavy chassis also keeps the seated avatar's mass from shifting the centre of mass. A test asserts 850–3100.
- Chassis CanTouch=true and CanQuery=true. CanTouch is needed so CombatService spike strips can detect the chassis; the spec did not say.
- BumpStop CanQuery=false is ignored by the engine because CanCollide=true. They are Massless per the task.
- Extra model attributes beyond the spec: Height and CarId.
- Extra parts Rim_FL..RR are WeldConstraint-ed to Wheel_XX, not to the Chassis, so they follow WheelAnimator's C0 edits.
- Wheel Welds are parented to the Chassis. WheelAnimator searches recursively and VehicleController looks in the Chassis, so both find them.
- Hover and tank keep Wheel_XX parts, welds and attachments, but the wheels have Transparency=1 and no rims.
- Attachments set both .CFrame and .Position: identical in Roblox, but the Lune harness stores them separately.
- The mutation parameter is optional (nil means 'None'). An unknown carId warns once and builds Cars.List[1] instead of erroring, so a stale save cannot crash the garage display.
- Visual identity comes from a per-car VARIANTS table keyed by id, layered on the shared style silhouettes. Some cars carry SurfaceGui text labels; these are not parts, so they do not count toward the 40-part budget.

### Known issues
- I could not run a Luau strict type checker: downloading luau-lsp was denied by the sandbox and no analyzer is installed. Strictness was checked by careful review only. Spots that may need a cast under luau-lsp: the merge() any-cast for RoadSpec, `mutation :: any` in repaint, and `style :: any` in styleDims.
- tools/render.py sorts faces by depth instead of using a z-buffer, so previews can show faces that are buried in-engine (for example a stripe sitting 0.1 under a sloped hood). I moved those parts so the sheets read correctly; the real engine is unaffected.
- SurfaceGui text labels (TAXI, POLICE, PIZZA, $ BANK $, ICE CREAM, RETIRED) cannot be seen in the Lune previews, so they are unverified visually; check them in Studio.
- Hypercars have roof height 3.95 with the seat at the 0.45 minimum. Very tall or custom avatars may poke their head through the roof. Other cars leave about 3.45 studs from seat top to roof bottom.
- The two bump-stops sit on the centerline, as the task specified. A car left resting only on them with no controller (for example a traffic car released to plain physics) can tip about 11° sideways onto the chassis edge until it is anchored. VehicleController handles normal settling.
- Gold mutation on cars that are already yellow or gold (rubber_ducky, raging_bull, gold_rush) changes colour only slightly; the Foil material provides the difference in-engine. Galaxy uses the ForceField material from Config/Rarity, which renders semi-transparent and animated.
- WeldConstraints and Welds are created while the model is unparented. This is the standard pattern and the offsets are captured on assignment, but it is worth confirming once in Studio that a spawned car holds together.
- Some cars are close to the 40-part cap (bull_charger 40, family_suv 40, stallion_gt 39, counting chassis, seat and bump-stops), so future decorations on those styles need to trade parts.

### Verification
- `selene` on CarBuilder.luau and carbuilder.spec.luau: 0 errors, 0 warnings.
- `stylua --check` on both files: clean.
- `rojo build -o /tmp/claude-0/build-*.rbxlx`: succeeded.
- `lune run tests/run.luau carbuilder`: 18 passed, 0 failed. The tests build every car in Cars.List plus Cars.Police and check:
  - names and classes, PrimaryPart and pivot, LookVector -Z
  - mass range and ModelStreamingMode
  - attributes and size limits
  - ≤40 parts
  - wheel attachments, cylinders, welds (C0 matches the attachment, wheel sits at the weld pose), wheel bottoms within 0.15 of pivot.Y − RideHeight, FL/FR/RL/RR sides
  - only Chassis and BumpStops collidable; every other part welded, massless, unanchored, CanTouch/CanQuery false
  - bump-stop clearance
  - seat props
  - lights and SpotLights, paint values, sirens on police
  - invisible wheels only on hover and tank
  - forDisplay omits exactly the seat and bump-stops
  - PivotTo onto a rotated ground CFrame keeps the wheels on the ground
  - deterministic builds
  - each mutation's colour, material and sparkles, accent untouched, re-apply and None restore
  - repaint and setHeadlights, unknown-id fallback, styleDims for all 22 styles
- `lune run tests/run.luau` (full suite): 144 passed, 2 failed. Both failures are in police.spec.luau (grid routing 'never arrived' and unstuck AI), which another slice is editing concurrently. That spec does not reference CarBuilder.
- Visual iteration: I ran dump.luau and render.py across 6 batches and about 5 rounds, looking at every sheet. Fixes along the way:
  - replaced full-width fender slabs with rounded off-centre-cylinder wheel arches
  - parallel-wedge hood stripes and vents
  - chrome fallback for dark accent rims
  - monster trucks with tires fully exposed and a roll bar
  - pickup cab moved forward
  - super roof snorkel, compact bug-eye headlights
  - toilet lid tilt and limo/hyper/armored lengths fixed
- Final previews are in docs/previews: cars_1–6.png (iso/side/top, 6 cars each), cars_lineup.png (all 33 in iso) and cars_mutations.png (None/Gold/Diamond/Rainbow/Galaxy on stallion_gt and rubber_ducky).
- I re-read the module end to end. Lune rejects unknown property names, which confirms every property I set exists (including VehicleSeat.Disabled, Model.ModelStreamingMode and SurfaceGui.MaxDistance).
- Checked consumers already in the tree: WheelAnimator finds WheelWeld_XX recursively and caches C0; VehicleController reads WheelXX attachments, RideHeight and WheelRadius. VehicleController already offsets the suspension mount so cars settle at the built pose. PoliceService uses SirenRed; WantedService uses Paint=primary.

---
## Files: src/server/Systems/MapBuilder.luau, src/server/Systems/LightingService.luau, tests/spec/map.spec.luau, docs/previews/map.png, docs/previews/map_hero.png, docs/previews/map_top.png, docs/previews/map_downtown.png, docs/previews/map_pois.png, docs/previews/map_street.png, docs/previews/map_night.png

### Public API
MapBuilder (src/server/Systems/MapBuilder.luau)
- build(parent: Instance): Folder: harness-compatible, deterministic (Random seed MapBuilder.SEED). Replaces any existing parent.Map, builds everything unparented, then parents the "Map" folder. Subfolders: Ground, Roads (+Roads/Markings), Blocks, Buildings, POIs/<PoiName>, Props, Beach, Boundary.
- init(): build(Workspace) plus buildTerrain(Workspace.Terrain). The terrain call is wrapped in pcall.
- getMapFolder(): Folder. Returns the cached folder, otherwise Workspace.Map, otherwise builds it.
- Extra helpers:
  - districtOf(bx, bz) -> "downtown"|"midrise"|"lowrise"|"beach"
  - cutsFor(bx, bz) -> {{side,a,b}}: curb cuts per block
  - buildTerrain(terrain): ocean water from SLOPE_START (880) to WATER_EXTENT, plus a sand seabed. Filled in 512-stud tiles, aligned to the voxel grid. Also sets water colour and waves.
  - Constants: SEED, PART_BUDGET (9000), LANDMARK_BLOCK {x=1,z=0}, TAG_ROAD/TAG_STREET_LIGHT/TAG_NIGHT_GLOW.

Instances and tags other slices can rely on:
- Road parts are tagged "Road" with attributes Axis and Line. X roads run full length; Z roads are split into segments between intersections. Tops are at ROAD_Y.
- Lane markings use CanCollide=false and CanQuery=false, so suspension raycasts ignore them.
- Each block has 4 Sidewalk strips plus a "Lot" part, all with tops at CURB_TOP. Lot attributes: BlockX, BlockZ, District, Poi, PlotIndex.
- "DrivewayRamp" WedgeParts are curb cuts through the sidewalk at:
  - every plot front (40 wide)
  - the Dealership north side (x -50..50)
  - both Spray Shops (30 wide)
  - the Chop Shop (34 wide)
  - the Stunt Park (two cuts)
- POIs/SpawnPlaza:
  - SpawnLocation at MapLayout.spawnCFrame() with Neutral=true, Duration=0, CanTouch=false.
  - LeaderboardEarned / LeaderboardSteals parts tagged "LeaderboardBoard", with attributes Stat="totalEarned"/"steals" and Face="Front". Both face the spawn.
  - Fountain, benches, palms and a "HOTWIRE CITY" welcome sign.
- POIs/Dealership:
  - Discs DealerPad1..8 tagged "DealerPad" with a PadIndex attribute, placed at MapLayout.dealerPads().
  - Glass walls on the W/S/E sides only; the north side is open.
  - Skylight canopy and two "HOTWIRE MOTORS" signs (north and west).
  - "RestockBoard" part tagged "DealerRestockBoard", with Face="Front", facing into the showroom.
- POIs/PoliceHQ: blue/white HQ with POLICE signs, helipad and siren bars. The busted-release spot is kept clear.
- POIs/GearShop:
  - Part "GearShopCounter" tagged "GearShopCounter", centred on MapLayout.gearShopCounter() XZ (y = floor + 1.8). It is collidable, with the customer side kept open.
  - Downtown tower on the north half of the block.
- POIs/SprayShopA and SprayShopB: booths around MapLayout.sprayZones(), open toward -Z, with a neon "SPRAY" sign.
- POIs/ChopShop: shop around MapLayout.chopZone(), open toward +Z, with a "CHOP SHOP" sign, plus a junkyard.
- POIs/StuntPark: launch ramp over a pool onto a landing ramp, a half-pipe (two plank quarter-pipes), kickers, a 14-high mega ramp, bleachers and an entrance arch.
- POIs/Park: grass, pond, trees, paths, gazebo and a slide.
- POIs/Pier:
  - Model "FerrisWheel" tagged "FerrisWheel", with attributes Hub (Vector3) and Axis (Vector3). Its child Model "Rotor" holds the rim, spokes and gondolas, so a client could spin it.
  - Booths, plus a wooden pier from the promenade out to z=-950 with an open end.
- POIs/HotwireTower: a 300-stud landmark tower with "HOTWIRE CITY" billboards facing the spawn.
- Buildings: one Model each, tagged "AssetSlot" with Category="Buildings", Role="building_<class>", Fit and Footprint attributes.
- Props: palms and round trees are Models tagged "AssetSlot" (Category="Props", Role "palm_tree" / "tree").
- Rooftop parody-ad boards are tagged "Billboard" with an AdText attribute.
- Street lights: lamp parts are tagged "StreetLight", and every other one has a disabled PointLight.
- Night swaps: window bands, tower floor bands and lamp heads are tagged "NightGlow" with DayColor/DayMaterial/NightColor/NightMaterial attributes.
- Boundary: 4 invisible collidable walls at ±BOUNDARY.

LightingService (src/server/Systems/LightingService.luau)
- isNight(): boolean
- NightChanged: Signal(isNight)
- getClockTime(): number
- setClockTime(hour): jumps the cycle (for admin/testing) and updates night state immediately.
- Pure helpers: hourAt(cycleSeconds), timeForHour(hour), isNightHour(hour), lookAt(hour) -> keyframe blend.
- Constants: DAY_SECONDS=720, NIGHT_SECONDS=240, SUNRISE=6, SUNSET=18, NIGHT_ON=17.75, NIGHT_OFF=6.25, START_HOUR=14.
- Sets the Lighting attribute "IsNight" for clients (for example, for headlights).
- init():
  - Lighting setup: Future (pcall), Sky with defaults, Atmosphere, Bloom, ColorCorrection (saturation +0.24), SunRays, Terrain Clouds.
  - Applies the current night state synchronously.
  - Listens for late-tagged NightGlow/StreetLight instances (for example, garages) and applies the state to them.
- start():
  - 10 Hz ClockTime advance; ambient/tint/atmosphere/bloom/exposure blended from keyframes at 2 Hz.
  - On a day/night flip, toggles StreetLight PointLights and swaps NightGlow parts in batches of 150 per frame.

### Contract deviations
- PlotService already builds its own driveway apron plus a road-side CurbRamp in front of each garage. My DrivewayRamp is a curb-cut wedge inside the sidewalk, top flush with CURB_TOP and 40 wide to match PlotService's apron. It sits entirely under PlotService's apron (apron top CURB_TOP+0.05), so the two coexist without z-fighting, and mine still works if PlotService drops its own.
- The beach goes past SAND_EXTENT: flat sand to 880, then a sloped wedge into the water to 940 (<BOUNDARY-12). The shoreline is about 890 because the water level is -2. Terrain water starts at 880 so the shoreline comes out right.
- Terrain seabed/water boundary is snapped to the 4-stud voxel grid (-12), rather than the parts' SEABED_Y of -14, so no voxel is split between sand and water.
- Beach corners use a large sand Ball (R=133) whose top is flush with the sand at each corner. It gives a smooth rounded dune; most of its volume is underground or below the seabed and can't be seen in-game. WedgePart can't form a pyramid corner, and the CornerWedgePart apex convention couldn't be verified from the docs.
- SpawnLocation has CanTouch=false, since spawning doesn't need touch and it avoids touch events. Neutral=true and Duration=0 as specced.
- Extra block-level curb cuts and tags/instances that the spec doesn't define, documented in publicApi: DealerPad discs, DealerRestockBoard, FerrisWheel/Rotor, Billboard, NightGlow, AssetSlot attributes, Lot attributes, Lighting attribute IsNight. DealershipService/DealershipClient may use them but don't have to.
- A landmark tower (HotwireTower, its own POIs subfolder) occupies generic block (1,0), which Config/Map does not list as a POI. Nothing in the spec reserves that block.

### Known issues
- Preview images can't show SurfaceGui text: signs and leaderboards render as dark panels, and LeaderboardService draws the boards at runtime. Terrain water and the seabed are faked with planes in my previews; tools/render.py's map.png shows the corner dune balls under the island because it has no terrain.
- Corner dunes make a gentle rounded bulge in the shoreline at the 4 island corners, extending about 26 studs past the straight beaches.
- Quarter-pipe planks are open underneath at the sides (a visible hollow from a side angle). Cartoon-acceptable.
- Day/night is server-driven: ClockTime replicates at 10 Hz and Lighting look properties at 2 Hz. Each dusk/dawn flip changes Color+Material on about 1.5k NightGlow parts, spread over about 10 frames, twice per 16-minute cycle. If bandwidth matters, ClockTime could later be interpolated client-side.
- About 195 street-light PointLights plus about 10 always-on POI lights (Future lighting, shadows off). These should be checked on low-end mobile; LightingService could disable every second PointLight on low quality if needed.
- The Dealership north exit can be partly blocked by parked cars, because MapLayout.parkingSpots() may include spots on the north road in front of the showroom. That is StreetSpawnService's or MapLayout's call.
- The pier ends 10 studs short of the invisible boundary wall, and its end is open on purpose so cars can launch into the ocean. VehicleService's water/abandon handling applies.
- Building and prop variation comes from Random(seed). The harness RNG differs from Roblox's, so the in-game layout differs from the previews in detail. Placement is clamped to parcels by construction, and the tests check those invariants rather than specific layouts.
- The z-buffer preview renderer lives only in my scratchpad, because tools/ isn't my slice. Consider adopting /tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/zrender.py into tools/ for accurate previews.

### Verification
- selene on all 3 owned files: 0 errors, 0 warnings, 0 parse errors.
- stylua --check: clean.
- `rojo build -o /tmp/claude-0/build-*.rbxlx`: succeeds.
- `lune run tests/run.luau`: 313 passed, 0 failed (full suite, including the boot spec loading both modules).
- tests/spec/map.spec.luau has 29 tests:
  - Overlap-detector sanity check, so the clear-zone tests can't pass vacuously.
  - Folder layout and getMapFolder; rebuild replaces the old map.
  - Part budget and anchoring: 8011 parts, within the ≤9000 budget; all parts anchored with sane sizes.
  - Plot interiors empty above the curb, and a curb-cut ramp in front of every plot (flush with the sidewalk, facing the road).
  - Spray and chop zones clear; dealer pads and the north exit corridor clear.
  - Roads tagged and at ROAD_Y, with a road under every hot drop, parking spot and police spawn.
  - Every road corridor free of obstacles at car height; every parking spot clear.
  - Every building part stays inside its lot (sidewalks clear).
  - SpawnLocation position, facing and properties; both leaderboards present, tagged with Stat, and facing the spawn.
  - Gear shop counter tagged at the MapLayout position, with its front kept open.
  - Busted-release spot clear; 4 boundary walls; every other street light has a PointLight; NightGlow attribute validity; every POI built; district classification.
  - LightingService cycle math: inverse round-trips, about 270 s of night per 16-minute cycle, look keyframes.
  - LightingService.init plus setClockTime(22/12): effects created, NightChanged fires, the IsNight attribute flips, lamps toggle, NightGlow parts swap.
- Rendered with tools/dump.luau + tools/render.py into docs/previews/map.png (top + iso, 1400).
- Because render.py's painter's algorithm misdraws long roads and band caps, I also wrote a z-buffered perspective renderer in my scratchpad: /tmp/claude-0/-home-user/eee557c6-e616-59f3-9670-c1bf8e316e0b/scratchpad/zrender.py, with a crop/night dumper mapview.luau. Its outputs are docs/previews/map_hero.png, map_top.png, map_downtown.png, map_pois.png, map_street.png (spawn view, downtown street, coastal road, stunt park) and map_night.png.
- I looked at each preview and iterated on:
  - Glow plates covering back-face text.
  - Hidden fountain water and the spawn ring covering the pad.
  - Bench and bleacher facing.
  - White shop roofs.
  - Added a dealership skylight, stunt mega ramp, tower fins, the landmark tower, randomized lit windows and rooftop billboards.
- Re-read the code for runtime errors.

---
## Files: src/server/Systems/VehicleService.luau, src/server/Systems/StreetSpawnService.luau, src/server/Systems/TrafficService.luau, tests/spec/vehicleservice.spec.luau, docs/previews/traffic_drivers.png, docs/previews/traffic_paths.png

### Public API
VehicleService (SPEC §6, exact names):
- spawn(carId: string | CarDef, mutation, groundCFrame, kind, opts?) -> Car. It builds the car with CarBuilder.buildDef and pivots it to groundCFrame * (0, RideHeight + 0.3, 0). The model is parented to Workspace.Vehicles (the folder is created in init and lazily) and tagged "Vehicle" (+ "Police" for kind Police).
  - Model attributes: VehicleId, CarId, Mutation, Kind, Rarity, OwnerUserId (0 if none), Health, MaxHealth, DriverUserId (0 when empty), and Slot if opts.slot is given.
  - Parked, Dealership and HotDrop spawn anchored (opts.anchored overrides). Other kinds spawn unanchored with SetNetworkOwner(nil).
  - opts: { ownerUserId?, owner?: Player, slot? (copied to data.slot), anchored?, data?, health? }.
  - Unknown carId or kind raises an error; callers already pcall.
- Car = { id, model, chassis, seat, carId, mutation, kind, ownerUserId?, driver?, health, lastDriverAt, data } plus read-only extras: def, rarity, maxHealth, spawnedAt, destroyed, wrecked.
- seat(car, player) -> (boolean, reason?). This is the only way into a car. It authorizes the player for 3 s, unanchors, sets Disabled=false, calls SetNetworkOwner(player), then Sit. It enforces the kind rules: Police nobody, Owned owner only, Stolen thief or victim.
- eject(car): destroys the SeatWeld and moves the character out beside the car (raycast picks a clear side, falls back to the roof).
- addStealPrompt(car, { actionText, holdDuration, objectText?, canSteal(player) -> (ok, reason?), onStolen(player), name?, scaleWithHotwire? (default true), maxDistance?, keyCode?, gamepadKeyCode?, onHoldBegan? }) -> ProximityPrompt.
  - Prompt name defaults to "Hotwire"/"Carjack" from actionText, otherwise "StealPrompt"; with scaleWithHotwire=false it is "ActionPrompt". Attribute BaseHoldDuration is set for client scaling.
  - Server checks on Triggered: PromptButtonHoldBegan was recorded per (prompt, player); an interrupted hold is reset on HoldEnded; now - began >= base * getHoldMultiplier(player) * 0.85; distance <= MaxActivationDistance + 4; then canSteal and a re-entrancy guard.
  - After onStolen succeeds it fires Stolen(player, car, prevKind). onStolen does the conversion itself.
- damage(car, amount, sourcePlayer?): armor-scaled when there is a driver. destroy(car, reason): idempotent; fires Destroyed before the model is destroyed.
- get(id), fromModel(model or any descendant), getDriving(player), all() (returns a snapshot), setKind(car, kind) -> oldKind (syncs the Police tag and managed prompts), getHoldMultiplier(player).
- Signals: Spawned, DriverChanged(car, new, old), Destroyed(car, reason), DeliveryAttempt(player, car), ChopAttempt, SprayAttempt, ReturnedHome(car), Stolen(player, car, prevKind).
- Player attributes it sets: Driving, HoldMultiplier (refreshed on DataService.Loaded, MonetizationService.PassChanged "hotwire", player join, and every 5 s).
- Extras:
  - wreck(car) and signal Wrecked(car). Wreck fires the Effect "CarWreck" {position, color}, adds charred paint, a Smoke plume and a hop, ejects the driver, and destroys the car 2 s later with reason "wrecked".
  - teleport(car, cf) and resetWatchdog(car), for server-side moves that should not trip the watchdog.
  - getSpeedCap(car), refreshHoldMultiplier(player), isFirstSteal(player), addStealHeat(player, stars, reason) -> applied (honors the free first steal, lazy WantedService).
  - contractProgress(player, stat, n) (lazy RewardsService), announceSteal(player, car, verb) (EventFeed + BigSteal effect for Legendary+), carLabel(car), getFolder().
  - Pure test helpers: _canDrive, _holdOk, _holdMultiplier, _speedCap, _watchdogVerdict, _crashDamage, _zoneFlags, _stealHeat.
- Loops (one Heartbeat with accumulators, every pass pcall'd):
  - Crash damage every 0.1 s.
  - Zones every 0.2 s: drop-off on entry, retried every 3 s while inside; chop and spray on entry; Owned cars count only after data.leftGarage.
  - Watchdog every 0.5 s: two speed strikes or one blatant/teleport sample leads to revoke-and-rewind.
  - Lifecycle every 1 s: anchor after 10 s at rest; Owned with no driver for 20 s gets ReturnedHome then a fallback destroy; Loot with no driver for 45 s and nobody within 120 studs is destroyed; sunk or lost cars are cleaned up; missed Occupant changes are fixed up.

StreetSpawnService: no spec API. Extras: spawnAt(groundCFrame, carId?, mutation?) -> Car?, getParked(), ensureNewbieCar(player) -> Car?, and pure helpers _targetCount, _isSpotFree, _minDist, _doorPosition, _inFrontOfDoor, _newbieSpots.
- Target count is min(44, 24 + 2 per player). Spots are free when no car is within 12 studs; new cars prefer spots at least 60 studs from players.
- Parked cars untouched for 300–540 s are re-rolled when nobody is within 160 studs. Excess cars are removed only when nobody is within 200 studs.
- The "Hotwire" prompt uses the rarity hotwireTime. On steal: seat, setKind Loot, OwnerUserId = thief, heat (none on the first steal), contract progress "steal", Legendary+ announcement, engine sound.
- Newbie guarantee: while tutorialDone is false (up to 10 min after joining, checked every 8 s) there is a Common car in front of the player's garage door within 120 studs. It is tagged with attribute TutorialForUserId.

TrafficService: no spec API. Extras: getCount(), release(car, reason?), buildDriver(seatCFrame, scale, rng) -> Model (8 parts, harness-compatible), driverScale(model, seat), and pure path helpers _forward, _right, _lanePoint, _nextCross, _turnTarget, _turnOptions, _chooseTurn, _turnLead, _turnRadius, _turnLength, _turnPoint, _newPath, _advance, _pose, _distToTurn, _turnSpeedCap, _snapToRoad, _aheadDistance, _limitFromGap, _isCrossing.
- Count: 18 × EventService.getTrafficMultiplier() (capped at 36). Cars spawn 150–450 studs from a random player and at least 130 from everyone, and despawn beyond 650 studs.
- Cars follow a moving target point with AlignPosition + AlignOrientation. Turns: straight 50%, left/right 25% each, never a U-turn.
- Spacing cone; slow down near people on foot; brake when someone starts holding Carjack; honk at players blocking the road.
- Carjack: hold = hotwireTime × 0.9; the NPC is thrown out with a Bonk effect; car becomes Loot.
- Ram release: relative speed > 35 makes the car unowned Loot with no driver (VehicleService's abandon rule then despawns it).

### Contract deviations
- TrafficService drives lanes 7 studs from the centerline (MapConfig.LANE_OFFSET - 1) instead of exactly MapLayout.laneCFrame's 8. At 8, a 7.3-wide traffic chassis clears a curb-parked chassis (PARK_OFFSET 15.5) by only 0.2 studs; at 7 the gap is 1.2 studs and oncoming traffic still has 6.7 studs. The tests check that _lanePoint at offset 8 matches laneCFrame exactly.
- Turns are smooth tangent paths from box edge to box edge, not 'aim at the intersection center, then the new lane'. Right turns are a radius-13 arc. Left turns drive 14 studs into the box, take a radius-13 arc, then drive 14 out, so opposing left-turners stay at least 7.3 studs apart (tested). A pure arc made them meet in the middle.
- VehicleService adds prompts the spec doesn't list, so players can get back into a car after hopping out. Unoccupied Owned and Loot cars get an "EnterPrompt" (F / ButtonY, instant, attribute OnlyUserId = owner or claimer). Unoccupied Loot cars also get a "Hotwire" prompt for everyone else (rarity hold, attribute HideForUserId = claimer). The server re-checks; a non-owner who uses EnterPrompt gets a Notify. No client hides prompts by OnlyUserId/HideForUserId yet; TheftService relies on the same attributes, so a client controller should add this.
- On Loot cars, OwnerUserId means the claimer. Whoever drives a Loot car (or is driving when setKind makes it Loot) becomes the claimer. Released traffic and unclaimed loot have OwnerUserId 0.
- When an Owned car enters its own drop-off after leaving the garage, VehicleService fires DeliveryAttempt (GarageService parks Owned cars on that signal). ReturnedHome fires only as a fallback if the car still exists 1 s later. Firing ReturnedHome directly would make GarageService show a 'towed back home' message on a normal drive-in. ReturnedHome is still the abandon rule after OWNED_RETURN_AFTER, and for sunk Owned cars.
- DeliveryAttempt fires on entering the drop-off and then again every 3 s while the car stays inside, so a full-garage delivery succeeds once a slot frees up. GarageService rate-limits its 'garage full' message. Chop and Spray fire once per entry.
- seat() returns (boolean, reason?) and never throws. GarageService, TheftService and AdminService treat pcall success as 'seated', so a failed seat leaves the car empty (the player can still get in via the prompts, and TheftService's drop logic still applies).
- The server hold check uses required * 0.85 as the task specifies; SPEC §6 says 0.9.
- The free first steal (no wanted level when stats.steals == 0, once per session) also applies to carjacks and loot hotwires, not only street steals.
- Extras beyond the spec: Wrecked signal; model attributes MaxHealth, Wrecked and Slot; TutorialForUserId on the newbie street car; prompt attributes BaseHoldDuration and ScalesWithHotwire; car.data.source = "street" | "traffic"; car.data.lastDamagedBy.

### Known issues
- Engine behaviour that Lune can't simulate still needs a Studio playtest: server-side seat:Sit and SeatWeld exit, ram detection via Touched between client-owned and server-owned parts, and the traffic constraint tuning (Responsiveness 25, MaxForce = 10 × mass × gravity, MaxAngularVelocity 8). If traffic looks floaty or jittery, the TrafficService ALIGN_* / ACCEL / BRAKE constants are the knobs.
- Traffic blocked by a stationary non-player obstacle in its lane (e.g. a HotDrop car anchored in the middle of an intersection) waits 8 s. It then despawns if nobody is within 150 studs, otherwise it ignores the obstacle and may push into it until it is knocked off its path and released as free loot. This is rare (hot drops only) and arguably fun, but not polished.
- The watchdog can trip on extreme physics flings, such as a very fast police ram at more than 1.5× the cap. It only rewinds the car and keeps ownership for 2 s, and logs a warning; it never kicks.
- No client controller hides prompts by OnlyUserId / HideForUserId yet (VehicleService and TheftService both set them). Until then everyone sees 'Drive'/'Get in' on other players' cars and gets a friendly 'That's X's ride!' if they press it. EffectsController or GarageClient should hide these locally.
- Hero mesh shells from AssetLibrary/Config.Assets.Hero are not applied in VehicleService.spawn; cars use the procedural CarBuilder body. The art pass can add this right after CarBuilder.buildDef in spawn.
- On some cars the NPC driver's scale bottoms out at 0.6 and the hat can poke slightly above the roof line. The test exempts that case; all current street cars passed.

### Verification
- selene on all three systems and the spec: 0 errors, 0 warnings.
- stylua --check: clean.
- rojo build -o /tmp/claude-0/build-*.rbxlx: succeeds.
- lune run tests/run.luau: 314 passed, 0 failed. That includes 26 tests in tests/spec/vehicleservice.spec.luau, and boot.spec loads all three modules headlessly.

What my tests cover:
- VehicleService pure helpers: who may drive each kind, hold check with tolerance, hold multiplier (levels, clamping, Master Thief), speed cap and watchdog verdicts (teleport, speed, NaN, lag stall), crash damage (horizontal only), zones (every plot's drop-off, someone else's plot, chop, both spray booths), first-steal heat.
- VehicleService in the Lune harness:
  - spawn contract: attributes, tags, folder, anchoring by kind, wheels at ground + RideHeight + 0.3, get/fromModel/all/setKind/destroy and the Destroyed reason; CarDef (police) spawn.
  - Prompts: managed prompts on Owned and on claimed/unclaimed Loot, and their removal on Stolen; steal prompt name, attributes and hold.
  - Damage and wreck path.
  - Bad input errors.
- TrafficService:
  - _lanePoint matches MapLayout.laneCFrame.
  - _nextCross.
  - Turn options exhaustively over every road, direction and intersection: never a U-turn, never off the grid, right is right.
  - Turn geometry: starts and ends on the correct lanes, stays on asphalt, continuous.
  - Opposing left-turners stay at least 7.3 studs apart.
  - A 36,000-step random drive: always on road, continuous, smooth heading, turns both ways.
  - Turn speed planning, road snapping for spawns, spacing cone (curb-parked and oncoming cars never block), crossing check.
  - NPC driver: 8 non-colliding massless welded parts, hat under the roof for every street car.
- StreetSpawnService: target counts, free-spot check, newbie spots for all 8 plots (on road, near and in front of the door, clear of traffic lanes), and every parking spot clears traffic lanes.

Previews: rendered with tools/render.py and inspected; saved to docs/previews/.
- traffic_drivers.png: NPC drivers in a sedan, sports car, monster truck and tank (the tank's driver pops out of the hatch).
- traffic_paths.png: top view of straight, right and left paths through an intersection, with nearby parking spots.

I re-read all three modules end to end for runtime errors. That led to these fixes:
- NPC eject order: the cleanup step was destroying the dummy before it could be thrown out.
- Signal passes now iterate snapshots, so a handler that seats someone mid-pass can't break the loop.
- Player lookups are wrapped in pcall so they don't fail in the harness.
- Queued cars no longer 'ghost' through the car in front; only cars crossing each other do.
