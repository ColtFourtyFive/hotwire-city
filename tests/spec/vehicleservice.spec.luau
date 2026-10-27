--!nocheck
-- vehicle-service slice: VehicleService (pure validation helpers, zones, spawn/prompt contract in the harness),
-- TrafficService (lane state machine, turns, spacing, NPC driver) and StreetSpawnService (counts, spots, newbie car).
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local MapConfig = H.require("src/shared/Config/Map")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local VehicleConfig = H.require("src/shared/Config/Vehicle")
	local Monetization = H.require("src/shared/Config/Monetization")
	local Cars = H.require("src/shared/Config/Cars")
	local CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
	local VS = H.require("src/server/Systems/VehicleService")
	local Traffic = H.require("src/server/Systems/TrafficService")
	local Street = H.require("src/server/Systems/StreetSpawnService")

	local S = MapConfig.GRID_SPACING
	local LMIN, LMAX = MapConfig.LINE_MIN, MapConfig.LINE_MAX

	local function flatDist(a, b)
		return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
	end

	-- VEHICLESERVICE: pure helpers ----------------------------------------------------------------------------------

	t.test("canDrive: police nobody, owned owner only, stolen thief/victim, loot anyone", function()
		t.eq(VS._canDrive("Police", nil, nil, 1), false, "police")
		t.eq(VS._canDrive("Owned", 5, nil, 5), true, "owner")
		t.eq(VS._canDrive("Owned", 5, nil, 6), false, "other on owned")
		t.eq(VS._canDrive("Owned", nil, nil, 6), true, "unowned owned")
		local theft = { thief = 10, victim = 20 }
		t.eq(VS._canDrive("Stolen", 20, theft, 10), true, "thief")
		t.eq(VS._canDrive("Stolen", 20, theft, 20), true, "victim")
		t.eq(VS._canDrive("Stolen", 20, theft, 30), false, "stranger on stolen")
		t.eq(VS._canDrive("Stolen", 20, { victimUserId = 20, thiefUserId = 10 }, 10), true, "userId fields")
		t.eq(VS._canDrive("Loot", 5, nil, 99), true, "loot")
		t.eq(VS._canDrive("Parked", nil, nil, 99), true, "parked (conversion done by caller)")
	end)

	t.test("holdOk: needs began + tolerance * required", function()
		t.eq(VS._holdOk(nil, 10, 0), true, "instant prompt")
		t.eq(VS._holdOk(nil, 10, 1), false, "never began")
		t.eq(VS._holdOk(9.0, 10, 1), true, "full hold")
		t.eq(VS._holdOk(9.2, 10, 1), false, "0.8s of 1s")
		t.eq(VS._holdOk(10 - 0.86, 10, 1), true, "0.86s of 1s passes the 0.85 tolerance")
		t.eq(VS._holdOk(10 - 0.5, 10, 0.5), true, "scaled hold")
	end)

	t.test("hold multiplier: upgrade levels and Master Thief", function()
		t.near(VS._holdMultiplier(0, false), 1, 1e-9, "base")
		t.near(VS._holdMultiplier(4, false), 0.5, 1e-9, "max level")
		t.near(VS._holdMultiplier(99, false), 0.5, 1e-9, "clamped")
		t.near(VS._holdMultiplier(0, true), Monetization.MASTER_THIEF_MULT, 1e-9, "pass")
		t.near(VS._holdMultiplier(4, true), 0.5 * Monetization.MASTER_THIEF_MULT, 1e-9, "both")
		t.near(VS._holdMultiplier(1.7, false), 0.85, 1e-9, "fractional level floors")
		t.near(VS._holdMultiplier(-3, false), 1, 1e-9, "negative level")
	end)

	t.test("watchdog: speed cap formula and verdicts", function()
		local cap = VS._speedCap(70, nil)
		local expected = 70
			* VehicleConfig.SPEED_CAP_MULT
			* VehicleConfig.NITRO_SPEED_MULT
			* VehicleConfig.SPEED_CAP_GRACE
		t.near(cap, expected, 1e-6, "cap")
		t.near(VS._speedCap(70, 2), expected * 2, 1e-6, "SpeedMultiplier raises the cap")
		t.near(VS._speedCap(70, 0.5), expected, 1e-6, "slowdowns never lower the cap")
		t.eq(VS._watchdogVerdict(60, 30, 0.5, cap), nil, "legit driving")
		t.eq(VS._watchdogVerdict(60, cap * 0.5 + VehicleConfig.WATCHDOG_TELEPORT_SLACK + 1, 0.5, cap), "teleport")
		t.eq(VS._watchdogVerdict(cap + 1, 10, 0.5, cap), "speed")
		t.eq(VS._watchdogVerdict(0 / 0, 1, 0.5, cap), "teleport", "NaN speed")
		t.eq(VS._watchdogVerdict(10, 200, 3, cap), nil, "lag stall: allowance accrues with dt")
	end)

	t.test("crash damage: threshold, scale, horizontal only", function()
		t.eq(VS._crashDamage(Vector3.new(50, 0, 0), Vector3.new(10, 0, 0)), 0, "below threshold")
		local dv = 90
		local dmg = VS._crashDamage(Vector3.new(dv, 0, 0), Vector3.new(0, 0, 0))
		t.near(
			dmg,
			(dv - VehicleConfig.CRASH_DAMAGE_THRESHOLD) * VehicleConfig.CRASH_DAMAGE_SCALE,
			1e-6,
			"head-on stop"
		)
		t.eq(VS._crashDamage(Vector3.new(0, -150, 0), Vector3.new(0, 0, 0)), 0, "landing a jump is free")
	end)

	t.test("zones: own drop-off, chop shop, spray booths", function()
		for i = 1, MapLayout.plotCount() do
			local cf = MapLayout.plotDropoffZone(i)
			local pos = cf.Position - Vector3.new(0, 3, 0) -- chassis height above the garage floor
			local inDrop, inChop, spray = VS._zoneFlags(pos, i)
			t.ok(inDrop, "plot " .. i .. " drop-off center")
			t.ok(not inChop and spray == nil, "plot " .. i .. " not chop/spray")
			local other = if i == 1 then 2 else 1
			t.eq((VS._zoneFlags(pos, other)), false, "someone else's drop-off doesn't count")
			t.eq((VS._zoneFlags(pos, nil)), false, "no plot")
			t.eq((VS._zoneFlags(pos, 0.5)), false, "garbage plot index")
			-- driving out of the garage the car passes the drop-off: the interior check marks leftGarage only outside
			t.eq(MapLayout.plotAt(pos), i, "drop-off is inside the garage interior")
		end
		local chopCF = MapLayout.chopZone()
		local _, inChop = VS._zoneFlags(chopCF.Position - Vector3.new(0, 4, 0), nil)
		t.ok(inChop, "chop zone")
		for idx, z in MapLayout.sprayZones() do
			local _, _, spray = VS._zoneFlags(z.cframe.Position - Vector3.new(0, 4, 0), nil)
			t.eq(spray, idx, "spray booth " .. idx)
		end
		local _, c2, s2 = VS._zoneFlags(Vector3.new(0, 2, 0), nil)
		t.ok(not c2 and s2 == nil, "plain road")
	end)

	t.test("steal heat: first steal is free", function()
		t.eq(VS._stealHeat(2, true), 0)
		t.eq(VS._stealHeat(2, false), 2)
		t.eq(VS._stealHeat(1.7, false), 1)
		t.eq(VS._stealHeat(-1, false), 0)
	end)

	-- VEHICLESERVICE: spawn / prompt contract in the harness ---------------------------------------------------------

	t.test("spawn: model contract, attributes, tags, anchoring, registry", function()
		local ground = CFrame.new(100, 0, 8) * CFrame.Angles(0, math.rad(30), 0)
		local spawned = nil
		local conn = VS.Spawned:Connect(function(c)
			spawned = c
		end)
		local car = VS.spawn("viper_strike", "Gold", ground, "Parked")
		conn:Disconnect()
		t.ok(spawned == car, "Spawned fired")
		local model = car.model
		t.eq(model.Parent, H.workspace:FindFirstChild("Vehicles"), "parented to Workspace.Vehicles")
		t.ok(model:HasTag("Vehicle"), "Vehicle tag")
		t.ok(not model:HasTag("Police"), "no Police tag")
		t.eq(model:GetAttribute("VehicleId"), car.id)
		t.eq(model:GetAttribute("CarId"), "viper_strike")
		t.eq(model:GetAttribute("Mutation"), "Gold")
		t.eq(model:GetAttribute("Kind"), "Parked")
		t.eq(model:GetAttribute("Rarity"), "Rare")
		t.eq(model:GetAttribute("OwnerUserId"), 0)
		t.eq(model:GetAttribute("Health"), VehicleConfig.MAX_HEALTH)
		t.eq(model:GetAttribute("DriverUserId"), 0)
		t.eq(car.chassis.Anchored, true, "parked cars spawn anchored")
		t.eq(car.seat.Disabled, true, "seat disabled")
		t.eq(car.seat.Name, "DriverSeat")
		-- colliding parts in the Car group (NPC humans don't collide with it); everything else stays Default
		local colliders = 0
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				if d.CanCollide then
					colliders += 1
					t.eq(d.CollisionGroup, VS.CAR_GROUP, "Car group: " .. d.Name)
				end
			end
		end
		t.ok(colliders >= 1 and car.chassis.CollisionGroup == "Car", "chassis in the Car group")
		local ride = model:GetAttribute("RideHeight")
		-- anchored kinds never drop: exactly at rest height, no hover (F10)
		local expectY = (ground * CFrame.new(0, ride, 0)).Position.Y
		t.near(car.chassis.CFrame.Position.Y, expectY, 1e-3, "wheels rest on the ground")
		t.near(flatDist(car.chassis.CFrame.Position, ground.Position), 0, 1e-3, "centered on the ground CFrame")
		t.ok(car.chassis.CFrame.LookVector:Dot(ground.LookVector) > 0.999, "faces the ground CFrame")
		t.eq(VS.get(car.id), car, "get")
		t.eq(VS.fromModel(model), car, "fromModel(model)")
		t.eq(VS.fromModel(car.chassis), car, "fromModel(descendant)")
		local found = false
		for _, c in VS.all() do
			found = found or c == car
		end
		t.ok(found, "all()")
		t.eq(car.health, VehicleConfig.MAX_HEALTH)
		t.ok(type(car.data) == "table", "data scratch table")
		-- a steal prompt on top
		local prompt = VS.addStealPrompt(car, {
			actionText = "Hotwire",
			holdDuration = 1.8,
			canSteal = function()
				return true
			end,
			onStolen = function() end,
		})
		t.eq(prompt.Parent, car.chassis, "prompt in chassis")
		t.eq(prompt.Name, "Hotwire", "client scaling recognizes the name")
		t.eq(prompt:GetAttribute("BaseHoldDuration"), 1.8)
		t.near(prompt.HoldDuration, 1.8, 1e-5)
		t.eq(prompt.RequiresLineOfSight, false)
		t.eq(prompt.MaxActivationDistance, VS.PROMPT_DISTANCE)
		-- parked cars get no VehicleService-managed prompts
		t.eq(car.chassis:FindFirstChild("EnterPrompt"), nil, "no enter prompt on parked")
		-- kind change
		t.eq(VS.setKind(car, "Police"), "Parked", "setKind returns old kind")
		t.ok(model:HasTag("Police"), "Police tag added")
		t.eq(model:GetAttribute("Kind"), "Police")
		VS.setKind(car, "Parked")
		t.ok(not model:HasTag("Police"), "Police tag removed")
		-- destroy
		local reason = nil
		local c2 = VS.Destroyed:Connect(function(c, why)
			if c == car then
				reason = why
			end
		end)
		VS.destroy(car, "test")
		c2:Disconnect()
		t.eq(reason, "test", "Destroyed(car, reason)")
		t.eq(model.Parent, nil, "model destroyed")
		t.eq(VS.get(car.id), nil, "unregistered")
		t.eq(car.destroyed, true)
		VS.destroy(car, "again") -- idempotent
	end)

	t.test("spawn: CarDef (police), unanchored kinds, bad input", function()
		local car = VS.spawn(Cars.Police, "None", CFrame.new(0, 0, 300), "Police")
		t.eq(car.carId, Cars.Police.id)
		t.ok(car.model:HasTag("Police"), "Police tag")
		t.eq(car.chassis.Anchored, false, "police are physics cars")
		VS.destroy(car, "test")
		local owned =
			VS.spawn("rustbucket", "None", CFrame.new(0, 0, 330), "Owned", { owner = nil, ownerUserId = 77, slot = 3 })
		t.eq(owned.chassis.Anchored, false, "owned unanchored")
		local ride = owned.model:GetAttribute("RideHeight")
		t.near(owned.chassis.CFrame.Position.Y, ride + VS.SPAWN_DROP, 1e-3, "physics cars drop the last few tenths")
		t.eq(owned.ownerUserId, 77)
		t.eq(owned.data.slot, 3, "opts.slot -> data.slot")
		t.eq(owned.model:GetAttribute("OwnerUserId"), 77)
		local enter = owned.chassis:FindFirstChild("EnterPrompt")
		t.ok(enter ~= nil, "unoccupied owned car can be re-entered")
		t.eq(enter:GetAttribute("OnlyUserId"), 77, "enter prompt is owner-only")
		VS.destroy(owned, "test")
		t.eq(enter.Parent, nil, "managed prompt destroyed with the car")
		local ok = pcall(VS.spawn, "definitely_not_a_car", "None", CFrame.new(), "Loot")
		t.eq(ok, false, "unknown car id errors")
		local ok2 = pcall(VS.spawn, "rustbucket", "None", CFrame.new(), "Banana")
		t.eq(ok2, false, "unknown kind errors")
		local weird = VS.spawn("rustbucket", "NotAMutation", CFrame.new(0, 0, 360), "Loot")
		t.eq(weird.mutation, "None", "bad mutation falls back to None")
		VS.destroy(weird, "test")
	end)

	t.test("loot cars: unclaimed -> Hotwire for all; claimed -> Get in (claimer) + Hotwire (others)", function()
		local free = VS.spawn("hot_hatch", "None", CFrame.new(0, 0, 400), "Loot")
		local hot = free.chassis:FindFirstChild("Hotwire")
		t.ok(hot ~= nil, "hotwire prompt on unclaimed loot")
		t.eq(free.chassis:FindFirstChild("EnterPrompt"), nil, "no enter prompt without a claimer")
		t.near(hot:GetAttribute("BaseHoldDuration"), 1.2, 1e-9, "rarity hotwire time (Uncommon)")
		VS.destroy(free, "test")
		local claimed = VS.spawn("hot_hatch", "None", CFrame.new(0, 0, 430), "Loot", { ownerUserId = 42 })
		local enter = claimed.chassis:FindFirstChild("EnterPrompt")
		local hw = claimed.chassis:FindFirstChild("Hotwire")
		t.ok(enter ~= nil and hw ~= nil, "both prompts")
		t.eq(enter:GetAttribute("OnlyUserId"), 42)
		t.eq(hw:GetAttribute("HideForUserId"), 42)
		t.ok(enter.KeyboardKeyCode ~= hw.KeyboardKeyCode, "different keys so both can show")
		VS.setKind(claimed, "Stolen")
		t.eq(claimed.chassis:FindFirstChild("EnterPrompt"), nil, "stolen cars: TheftService owns the prompts")
		t.eq(claimed.chassis:FindFirstChild("Hotwire"), nil)
		VS.destroy(claimed, "test")
	end)

	t.test("wreck path marks the car and schedules destroy", function()
		local car = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 460), "Loot")
		VS.damage(car, 30)
		t.near(car.health, VehicleConfig.MAX_HEALTH - 30, 1e-9, "damage without driver = no armor")
		t.eq(car.model:GetAttribute("Health"), VehicleConfig.MAX_HEALTH - 30)
		VS.damage(car, 0 / 0)
		VS.damage(car, -5)
		t.near(car.health, VehicleConfig.MAX_HEALTH - 30, 1e-9, "NaN / negative ignored")
		local wrecked = false
		local conn = VS.Wrecked:Connect(function(c)
			wrecked = wrecked or c == car
		end)
		VS.damage(car, 1000)
		conn:Disconnect()
		t.ok(wrecked and car.wrecked, "wrecked at 0 health")
		t.eq(car.model:GetAttribute("Wrecked"), true)
		t.eq(car.chassis:FindFirstChild("Hotwire"), nil, "wrecks can't be stolen")
		VS.destroy(car, "test")
	end)

	-- VEHICLESERVICE: audit fixes ------------------------------------------------------------------------------------

	t.test("hold check: a stale (pre-charged) hold is refused (SEC-2)", function()
		local maxAge = VS._holdMaxAge(1.8, 1.8)
		t.ok(maxAge >= 1.8 + 1, "room for latency")
		t.eq(VS._holdOk(10 - 1.8, 10, 1.8, nil, maxAge), true, "fresh full hold")
		t.eq(VS._holdOk(10 - 30, 10, 1.8, nil, maxAge), false, "tapped 30s ago, triggered now")
		t.eq(VS._holdOk(10 - 30, 10, 1.8), true, "no maxAge = old behaviour")
		-- a client with a stale (unscaled) HoldMultiplier holds the base duration: still accepted
		local need = 4.5 * 0.5
		t.eq(VS._holdOk(10 - 4.5, 10, need, nil, VS._holdMaxAge(need, 4.5)), true, "stale client multiplier")
		t.eq(VS._holdOk(nil, 10, 0, nil, 1), true, "instant prompts never need a hold")
	end)

	t.test("watchdog: upward teleports, fling samples, shorter stall allowance (F5 / SEC-6)", function()
		local cap = VS._speedCap(70, nil)
		local allowance = cap * 0.5 + VehicleConfig.WATCHDOG_TELEPORT_SLACK
		t.eq(VS._watchdogVerdict(30, 5, 0.5, cap, allowance + 1), "teleport", "straight up")
		t.eq(VS._watchdogVerdict(30, 5, 0.5, cap, -200), nil, "falling is not a teleport")
		t.eq(VS._watchdogVerdict(30, 5, 0.5, cap, 0 / 0), "teleport", "NaN rise")
		t.eq(VS._watchdogVerdict(30, 5, 0.5, cap), nil, "rise optional")
		t.ok(VS.WATCHDOG_MAX_DT <= 1, "a parked car can't bank seconds of hop allowance")
		-- the biggest legal hop after holding still: the cap for WATCHDOG_MAX_DT, not 3 s worth
		local hop = cap * 2.9 + VehicleConfig.WATCHDOG_TELEPORT_SLACK - 1
		t.eq(VS._watchdogVerdict(0, hop, math.min(2.9, VS.WATCHDOG_MAX_DT), cap), "teleport", "2.9 s stall hop")
		t.eq(VS._flingSample(2.4, 0), false, "steering yaw")
		t.eq(VS._flingSample(6, -120), false, "upright recovery + a big landing")
		t.eq(VS._flingSample(VS.WATCHDOG_FLING_SPIN + 1, 0), true, "spin fling")
		t.eq(VS._flingSample(0, VS.WATCHDOG_FLING_VERTICAL + 1), true, "launch fling")
		t.eq(VS._flingSample(0 / 0, 0), true, "NaN")
	end)

	t.test("zone gate: teleports into a zone are refused and rewound, travel time enforced (SEC-1 / F2)", function()
		local cap = VS._speedCap(100, nil)
		-- legit: drove there at speed, long enough after the drive began
		t.eq((VS._zoneGate(90, 40, 0, 0.4, cap, 30, 10)), true, "legit arrival")
		-- client teleport 600 studs into its drop-off within one zone tick
		local ok, violation = VS._zoneGate(0, 600, 0, 0.2, cap, 30, 10)
		t.eq(ok, false, "teleport never reaches a zone")
		t.eq(violation, "teleport", "...and is rewound")
		-- a hop the stall allowance would let through, but faster than any legal drive from the drive start
		local ok2, v2 = VS._zoneGate(0, cap * 0.9, 0, VS.WATCHDOG_MAX_DT, cap, 1.2, 4)
		t.eq(ok2, false, "too soon after the drive began")
		t.eq(v2, nil, "no rewind for that alone")
		-- one fast (non-blatant) sample: no zone this tick, no rewind
		local ok3, v3 = VS._zoneGate(cap * 1.1, 10, 0, 0.5, cap, 30, 0)
		t.eq(ok3, false)
		t.eq(v3, nil)
		t.eq(select(2, VS._zoneGate(cap * 2, 10, 0, 0.5, cap, 30, 0)), "speed", "blatant speed is rewound")
	end)

	t.test("minTravelTime / isTainted / drive start contract", function()
		local d = 1000
		local fastest = 120 * VehicleConfig.SPEED_CAP_MULT * VehicleConfig.NITRO_SPEED_MULT
		t.near(VS._minTravelTime(d, 120, nil), d / fastest, 1e-9, "watchdog band incl. nitro, no lag grace")
		t.near(VS._minTravelTime(d, 120, 2), d / (fastest * 2), 1e-9, "SpeedMultiplier")
		t.eq(VS._minTravelTime(0 / 0, 120, nil), math.huge, "NaN distance never passes")
		t.eq(VS._minTravelTime(-5, 120, nil), 0)
		local car = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 600), "Loot")
		t.eq(VS.minTravelTime(car, Vector3.new(500, 0, 600)), 0, "never driven: no constraint")
		car.data.driveStartAt = os.clock()
		car.data.driveStartPos = Vector3.new(0, 3, 600)
		t.near(
			VS.minTravelTime(car, Vector3.new(500, 50, 600)),
			VS._minTravelTime(500, car.def.topSpeed, nil),
			1e-9,
			"flat distance from the drive start"
		)
		t.eq(VS.isTainted(car), false)
		car.data.tainted = true
		t.eq(VS.isTainted(car), true)
		t.eq(VS.isTainted(nil), false)
		VS.destroy(car, "test")
	end)

	t.test("crash damage scales with the real time between samples (F12)", function()
		local base = VS._crashDamage(Vector3.new(90, 0, 0), Vector3.zero)
		t.near(VS._crashDamage(Vector3.new(90, 0, 0), Vector3.zero, 0.1), base, 1e-9, "normal tick unchanged")
		t.near(VS._crashDamage(Vector3.new(90, 0, 0), Vector3.zero, 0.15), base, 1e-9, "frame jitter unchanged")
		-- 0.6 s replication gap while braking hard from 120 (~104 studs/s^2): no phantom crash
		t.eq(VS._crashDamage(Vector3.new(120, 0, 0), Vector3.new(58, 0, 0), 0.6), 0, "hitch during braking")
		-- hypercar nitro launch (180 studs/s^2) over a 0.31 s gap
		t.eq(VS._crashDamage(Vector3.zero, Vector3.new(56, 0, 0), 0.31), 0, "hitch during a nitro launch")
		t.ok(VS._crashDamage(Vector3.new(150, 0, 0), Vector3.zero, 0.3) > 0, "a real wall hit still hurts")
	end)

	t.test("street heat: witness roll (DECISIONS §1)", function()
		local Rarity = H.require("src/shared/Config/Rarity")
		local common, uncommon, mythic = Rarity.Tiers.Common, Rarity.Tiers.Uncommon, Rarity.Tiers.Mythic
		t.eq(VS._streetStars(common.wantedOnSteal, common.wantedChance, 0.2), 1, "common, seen: 1 star")
		t.eq(VS._streetStars(common.wantedOnSteal, common.wantedChance, 0.5), 0, "common, unseen")
		t.eq(VS._streetStars(uncommon.wantedOnSteal, uncommon.wantedChance, 0.999), 1, "uncommon always")
		t.eq(VS._streetStars(mythic.wantedOnSteal, mythic.wantedChance, 0.999), mythic.wantedOnSteal, "mythic")
		t.eq(VS._streetStars(2, nil, 0.999), 2, "missing chance = always")
		local Police = H.require("src/shared/Config/Police")
		t.eq(Traffic._carjackStars("Common"), Police.Heat.carjack, "carjack floor")
		t.eq(Traffic._carjackStars("Mythic"), math.max(Police.Heat.carjack, mythic.wantedOnSteal), "rarer is hotter")
		t.eq(Traffic._carjackStars(nil), Police.Heat.carjack, "unknown rarity")
	end)

	t.test("a leaving player's Owned cars are destroyed with them (DUPE-1)", function()
		local leaver = { UserId = 9001, Name = "Leaver" }
		local mine = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 640), "Owned", { ownerUserId = 9001, slot = 2 })
		local theirs = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 670), "Owned", { ownerUserId = 9002 })
		local loot = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 700), "Loot", { ownerUserId = 9001 })
		local reason = nil
		local conn = VS.Destroyed:Connect(function(c, why)
			if c == mine then
				reason = why
			end
		end)
		VS._cleanupLeaver(leaver)
		conn:Disconnect()
		t.eq(mine.destroyed, true, "own car gone")
		t.eq(reason, "owner_left")
		t.eq(theirs.destroyed, false, "someone else's car stays")
		t.eq(loot.destroyed, false, "claimed loot stays (abandon rules)")
		VS.destroy(theirs, "test")
		VS.destroy(loot, "test")
	end)

	t.test("settling: driverless physics cars get a server controller, anchored kinds don't (F4)", function()
		local parked = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 730), "Parked")
		t.eq(VS.settle(parked), false, "anchored cars don't settle")
		local loot = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 760), "Loot")
		t.eq(VS.settle(loot), true, "loose loot car settles")
		t.eq(VS.settle(loot), true, "idempotent (extends)")
		VS.destroy(loot, "test") -- stops the controller with the car
		t.eq(VS.settle(loot), false, "destroyed")
		local traffic = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 790), "Traffic")
		t.eq(VS.settle(traffic), false, "traffic drives itself")
		VS.destroy(traffic, "test")
		VS.destroy(parked, "test")
	end)

	t.test("allInto refills a caller buffer", function()
		local buf = { "junk", "junk", "junk", "junk", "junk", "junk", "junk", "junk" }
		local a = VS.spawn("rustbucket", "None", CFrame.new(0, 0, 820), "Loot")
		local out = VS.allInto(buf)
		t.ok(out == buf, "same table")
		local found = false
		for _, c in out do
			t.ok(type(c) == "table", "no stale entries")
			found = found or c == a
		end
		t.ok(found, "has the car")
		t.eq(#out, #VS.all(), "same as all()")
		VS.destroy(a, "test")
	end)

	-- TRAFFIC: lane state machine ----------------------------------------------------------------------------------------

	t.test("lanePoint matches MapLayout.laneCFrame at the shared lane offset", function()
		for _, axis in { "X", "Z" } do
			for _, dir in { 1, -1 } do
				for _, line in { LMIN, -2, 0, 3, LMAX } do
					local along = 37.5
					local mine = Traffic._lanePoint(axis, line, dir, along, MapConfig.LANE_OFFSET)
					local theirs = MapLayout.laneCFrame(axis, line, along, dir)
					t.near((mine - theirs.Position).Magnitude, 0, 1e-6, ("%s %d %d"):format(axis, line, dir))
					t.ok(Traffic._forward(axis, dir):Dot(theirs.LookVector) > 0.999, "forward matches")
				end
			end
		end
	end)

	t.test("nextCross: next intersection whose box edge is still ahead", function()
		t.eq(Traffic._nextCross(100, 1), 1)
		t.eq(Traffic._nextCross(150, 1), 2, "inside box 1 -> next one")
		t.eq(Traffic._nextCross(0, 1), 1)
		t.eq(Traffic._nextCross(-100, -1), -1)
		t.eq(Traffic._nextCross(-150, -1), -2)
		t.eq(Traffic._nextCross(10, -1), -1)
	end)

	t.test("turn options: never a U-turn, never off the grid", function()
		for _, axis in { "X", "Z" } do
			for line = LMIN, LMAX do
				for _, dir in { 1, -1 } do
					for cross = LMIN, LMAX do
						local opts = Traffic._turnOptions(axis, line, dir, cross)
						t.ok(#opts >= 1, "a corner always has a way out")
						for _, turn in opts do
							t.ok(turn == "straight" or turn == "left" or turn == "right", "no u-turn option")
							local naxis, nline, ndir = Traffic._turnTarget(axis, line, dir, cross, turn)
							if turn == "straight" then
								t.ok(cross + dir >= LMIN and cross + dir <= LMAX, "straight stays on grid")
							else
								t.ok(naxis ~= axis, "turns change axis")
								t.eq(nline, cross, "new road runs through the intersection")
								t.ok(line + ndir >= LMIN and line + ndir <= LMAX, "turn stays on grid")
							end
							-- the new heading is never the reverse of the old one
							local f = Traffic._forward(axis, dir)
							local f2 = Traffic._forward(naxis, ndir)
							t.ok(f:Dot(f2) > -0.5, "no reversal")
							if turn == "right" then
								t.ok(f2:Dot(Traffic._right(axis, dir)) > 0.99, "right is right")
							elseif turn == "left" then
								t.ok(f2:Dot(Traffic._right(axis, dir)) < -0.99, "left is left")
							end
						end
					end
				end
			end
		end
		-- ring corner: heading east on the north ring (z = -800) at the NE corner -> only right (south)
		local opts = Traffic._turnOptions("X", LMIN, 1, LMAX)
		t.eq(#opts, 1)
		t.eq(opts[1], "right")
	end)

	t.test("chooseTurn: weighted, only legal options", function()
		local all = { "straight", "right", "left" }
		t.eq(Traffic._chooseTurn(all, 0), "straight")
		t.eq(Traffic._chooseTurn(all, 0.6), "right")
		t.eq(Traffic._chooseTurn(all, 0.9), "left")
		t.eq(Traffic._chooseTurn(all, 1), "left", "r = 1 clamps")
		t.eq(Traffic._chooseTurn({ "left" }, 0.1), "left")
		t.eq(Traffic._chooseTurn({}, 0.5), "straight", "empty -> straight")
	end)

	t.test("turns start on the old lane and end on the new lane at the box edges", function()
		for _, axis in { "X", "Z" } do
			for _, dir in { 1, -1 } do
				for _, turn in { "right", "left" } do
					local line, cross = 1, -2
					local naxis, nline, ndir = Traffic._turnTarget(axis, line, dir, cross, turn)
					local p0 = Traffic._lanePoint(axis, line, dir, cross * S - dir * Traffic.BOX_HALF)
					local f, f2 = Traffic._forward(axis, dir), Traffic._forward(naxis, ndir)
					local R, lead, len = Traffic._turnRadius(turn), Traffic._turnLead(turn), Traffic._turnLength(turn)
					t.ok(R >= 8, "drivable radius")
					local a, ha = Traffic._turnPoint(p0, f, f2, R, 0, lead)
					t.near((a - p0).Magnitude, 0, 1e-9, "starts at p0")
					t.ok(ha:Dot(f) > 0.9999, "starts heading f")
					local b, hb = Traffic._turnPoint(p0, f, f2, R, len, lead)
					local expected = Traffic._lanePoint(naxis, nline, ndir, line * S + ndir * Traffic.BOX_HALF)
					t.near((b - expected).Magnitude, 0, 1e-6, ("%s %d %s ends on the new lane"):format(axis, dir, turn))
					t.ok(hb:Dot(f2) > 0.9999, "ends heading f2")
					local prev = a
					for i = 1, 40 do
						local p = Traffic._turnPoint(p0, f, f2, R, len * i / 40, lead)
						t.ok(MapLayout.isOnRoad(p), "turn stays on asphalt")
						t.ok((p - prev).Magnitude <= len / 40 + 1e-3, "continuous")
						prev = p
					end
				end
			end
		end
	end)

	t.test("opposing left-turners pass each other instead of meeting in the box", function()
		local function leftPath(axis, dir)
			local line, cross = 0, 0
			local naxis, _, ndir = Traffic._turnTarget(axis, line, dir, cross, "left")
			local p0 = Traffic._lanePoint(axis, line, dir, cross * S - dir * Traffic.BOX_HALF)
			return p0, Traffic._forward(axis, dir), Traffic._forward(naxis, ndir)
		end
		local pa, fa, f2a = leftPath("X", 1)
		local pb, fb, f2b = leftPath("X", -1)
		local R, lead, len = Traffic._turnRadius("left"), Traffic._turnLead("left"), Traffic._turnLength("left")
		local closest = math.huge
		for i = 0, 60 do
			local d = len * i / 60
			local a = Traffic._turnPoint(pa, fa, f2a, R, d, lead)
			local b = Traffic._turnPoint(pb, fb, f2b, R, d, lead)
			closest = math.min(closest, (a - b).Magnitude)
		end
		t.ok(closest >= 7.3, ("simultaneous opposite left turns keep %.1f studs apart"):format(closest))
	end)

	t.test("long drive: carrot stays on the road, moves continuously, turns both ways, never reverses", function()
		local rng = H.Random.new(99)
		local function pick(options)
			return Traffic._chooseTurn(options, rng:NextNumber())
		end
		local lefts, rights = 0, 0
		for carIdx = 1, 12 do
			local axis = if carIdx % 2 == 0 then "X" else "Z"
			local line = rng:NextInteger(LMIN, LMAX)
			local dir = if rng:NextNumber() < 0.5 then 1 else -1
			local _, _, s = Traffic._snapToRoad(Vector3.new(rng:NextNumber(-700, 700), 0, rng:NextNumber(-700, 700)))
			local st = Traffic._newPath(axis, line, dir, s, pick)
			local prevPos, prevHead = Traffic._pose(st)
			local lastMode = st.mode
			for _ = 1, 3000 do
				local stepLen = rng:NextNumber(0.2, 2.5)
				Traffic._advance(st, stepLen, pick)
				local pos, head = Traffic._pose(st)
				t.ok(MapLayout.isOnRoad(pos), "on road at " .. tostring(pos))
				t.ok(math.abs(pos.X) <= MapConfig.HALF_EXTENT + 10 and math.abs(pos.Z) <= MapConfig.HALF_EXTENT + 10)
				t.ok(st.cross >= LMIN and st.cross <= LMAX, "approaching a real intersection")
				local jump = (pos - prevPos).Magnitude
				t.ok(jump <= stepLen + 1e-3, ("continuous (%.3f > %.3f)"):format(jump, stepLen))
				t.ok(head:Dot(prevHead) > 0.9, "smooth heading")
				if st.mode == "turn" and lastMode == "lane" then
					if st.turnKind == "left" then
						lefts += 1
					else
						rights += 1
					end
				end
				lastMode = st.mode
				prevPos, prevHead = pos, head
			end
		end
		t.ok(lefts > 5 and rights > 5, ("turns both ways (L%d R%d)"):format(lefts, rights))
	end)

	t.test("turn speed planning slows before arcs", function()
		local st = Traffic._newPath("X", 0, 1, 20, function(options)
			return if table.find(options, "right") then "right" else options[1]
		end)
		t.eq(st.nextTurn, "right")
		local far = Traffic._turnSpeedCap(st)
		Traffic._advance(st, Traffic._distToTurn(st) - 5)
		local near = Traffic._turnSpeedCap(st)
		t.ok(near < far, "cap drops near the corner")
		t.ok(near <= 30, "slow at the corner")
		Traffic._advance(st, 6)
		t.eq(st.mode, "turn")
		t.eq(Traffic._turnSpeedCap(st), Traffic.TURN_SPEED.right)
	end)

	t.test("snapToRoad: lane spawn points clear of intersections", function()
		local rng = H.Random.new(5)
		for _ = 1, 400 do
			local p = Vector3.new(rng:NextNumber(-1000, 1000), 0, rng:NextNumber(-1000, 1000))
			local axis, line, s = Traffic._snapToRoad(p)
			t.ok(axis == "X" or axis == "Z")
			t.ok(line >= LMIN and line <= LMAX)
			local nearest = math.round(s / S) * S
			t.ok(math.abs(s - nearest) >= Traffic.BOX_HALF + 12 - 1e-6, "clear of the box")
			t.ok(math.abs(s) <= MapConfig.HALF_EXTENT - Traffic.BOX_HALF - 12 + 1e-6, "clear of the ring ends")
			for _, dir in { 1, -1 } do
				local lp = Traffic._lanePoint(axis, line, dir, s)
				t.ok(MapLayout.isOnRoad(lp), "lane point on road")
				local cross = Traffic._nextCross(s, dir)
				t.ok(cross >= LMIN and cross <= LMAX, "has an intersection ahead")
			end
		end
		t.eq((Traffic._snapToRoad(Vector3.new(0 / 0, 0, 0))), nil, "NaN")
	end)

	t.test("spacing cone: same lane ahead blocks; oncoming, behind and curb-parked don't", function()
		local pos = Traffic._lanePoint("X", 0, 1, 100)
		local fwd = Traffic._forward("X", 1)
		t.near(Traffic._aheadDistance(pos, fwd, pos + fwd * 12), 12, 1e-9, "car ahead")
		t.eq(Traffic._aheadDistance(pos, fwd, pos - fwd * 12), nil, "behind")
		local oncoming = Traffic._lanePoint("X", 0, -1, 120)
		t.eq(Traffic._aheadDistance(pos, fwd, oncoming), nil, "oncoming lane")
		for _, spot in MapLayout.parkingSpots() do
			-- the parked car nearest to this lane sits PARK_OFFSET from the centerline
			local rel = spot.Position - pos
			if math.abs(rel.Z) < 20 and rel.X > 0 and rel.X < 34 then
				t.eq(Traffic._aheadDistance(pos, fwd, spot.Position), nil, "curb-parked car")
			end
		end
		local parkedLateral = MapConfig.PARK_OFFSET - Traffic.LANE_OFFSET
		t.ok(
			parkedLateral > Traffic.CONE_BASE + Traffic.SLOW_DIST * Traffic.CONE_SLOPE,
			"cone narrower than the curb gap"
		)
		t.ok(parkedLateral >= 7.3 + 0.5, "widest chassis (7.3) clears a parked one")
		t.eq(Traffic._isCrossing(fwd, fwd), false, "same-way queue is not a deadlock")
		t.eq(Traffic._isCrossing(fwd, Traffic._forward("Z", 1)), true, "crossing traffic")
		t.eq(Traffic._isCrossing(fwd, -fwd), true, "head-on")
		t.eq(Traffic._limitFromGap(10, 14, 34, 40), 0, "stop")
		t.eq(Traffic._limitFromGap(40, 14, 34, 40), math.huge, "free")
		t.near(Traffic._limitFromGap(24, 14, 34, 40), 20, 1e-9, "linear slowdown")
	end)

	t.test("NPC driver: 8 non-colliding massless parts welded to the torso, fits under the roof", function()
		local rng = H.Random.new(3)
		for _, def in Cars.List do
			if def.street then
				local model = CarBuilder.build(def.id, "None")
				local seat = model:FindFirstChild("DriverSeat")
				local scale = Traffic.driverScale(model, seat)
				t.ok(scale >= 0.6 and scale <= 1, def.id .. " scale")
				local npc = Traffic.buildDriver(seat.CFrame, scale, rng)
				local parts = 0
				local top = -math.huge
				for _, d in npc:GetDescendants() do
					if d:IsA("BasePart") then
						parts += 1
						t.eq(d.CanCollide, false)
						t.eq(d.Massless, true)
						t.eq(d.CanTouch, false)
						if d ~= npc.PrimaryPart then
							local w = d:FindFirstChildOfClass("WeldConstraint")
							t.ok(w and w.Part0 == npc.PrimaryPart, "welded to torso")
						end
						top = math.max(top, d.CFrame.Position.Y + d.Size.Y / 2)
					end
				end
				t.eq(parts, 8, "part budget")
				t.eq(npc.PrimaryPart.Name, "Torso")
				if scale > 0.6 then
					t.ok(top <= model:GetAttribute("Height") + 0.05, def.id .. " hat under the roof line")
				end
			end
		end
	end)

	-- STREET SPAWNS ----------------------------------------------------------------------------------------------------------

	t.test("street target count scales with players and caps", function()
		t.eq(Street._targetCount(0), 24)
		t.eq(Street._targetCount(1), 26)
		t.eq(Street._targetCount(8), 40)
		t.eq(Street._targetCount(20), 44)
	end)

	t.test("spot freeness and distances", function()
		local occupied = { Vector3.new(0, 0, 0), Vector3.new(100, 0, 0) }
		t.eq(Street._isSpotFree(Vector3.new(5, 3, 5), occupied, 12), false)
		t.eq(Street._isSpotFree(Vector3.new(50, 0, 0), occupied, 12), true)
		t.eq(Street._minDist(Vector3.new(0, 0, 30), occupied), 30)
		t.eq(Street._minDist(Vector3.new(0, 0, 30), {}), math.huge)
	end)

	t.test("newbie spots: on the road, within reach of every garage door, facing along the road", function()
		for plot = 1, MapLayout.plotCount() do
			local door = Street._doorPosition(plot)
			local spots = Street._newbieSpots(plot)
			t.ok(#spots >= 4, "plot " .. plot .. " has candidates")
			local first = spots[1]
			t.ok(flatDist(first.Position, door) <= Street.NEWBIE_RADIUS, "first candidate near the door")
			t.ok(Street._inFrontOfDoor(plot, first.Position), "first candidate in front of the door")
			local near = 0
			for _, cf in spots do
				t.ok(MapLayout.isOnRoad(cf.Position), "on road")
				t.near(cf.Position.Y, MapConfig.ROAD_Y, 1e-6, "ground height")
				if flatDist(cf.Position, door) <= Street.NEWBIE_RADIUS then
					near += 1
				end
				-- along the road: the facing is axis-aligned
				local look = cf.LookVector
				t.ok(math.abs(look.X) > 0.999 or math.abs(look.Z) > 0.999, "axis aligned")
			end
			t.ok(near >= 4, "several free-able spots near the door")
			-- curbside spots never sit in a traffic lane
			for _, cf in spots do
				local p = cf.Position
				local lx = math.abs(p.X - math.round(p.X / S) * S)
				local lz = math.abs(p.Z - math.round(p.Z / S) * S)
				local lateral = math.min(lx, lz)
				t.ok(lateral >= Traffic.LANE_OFFSET + 7.3, "clear of traffic lanes")
			end
		end
	end)

	t.test("traffic mover: quantized, dead-banded, stable while cruising (PERF-02)", function()
		t.eq(Traffic._quantize(37.3), 37.5)
		t.eq(Traffic._quantize(37.2), 37)
		local heading = Traffic._forward("X", 1)
		local target = Vector3.new(100, 2.5, 8)
		-- cruising on the carrot (inside the dead band): exactly heading * speed, every frame
		local a = Traffic._moverVelocity(target + Vector3.new(0.2, -0.1, 0.1), target, heading, 37.5)
		local b = Traffic._moverVelocity(target - Vector3.new(0.3, 0, 0.2), target, heading, 37.5)
		t.ok(a == heading * 37.5 and a == b, "no change -> nothing to write")
		-- knocked 3 studs to the side: pulled back toward the lane, capped
		local c = Traffic._moverVelocity(target + Vector3.new(0, 0, 3), target, heading, 37.5)
		t.ok(c.Z < 0, "pulls back toward the carrot")
		local far = Traffic._moverVelocity(target + Vector3.new(0, 0, 20), target, heading, 0)
		t.ok(far.Magnitude <= Traffic.MAX_CORRECTION + Traffic.VEL_QUANTUM, "correction capped")
		for _, v in { c, far } do
			for _, comp in { v.X, v.Y, v.Z } do
				t.near(comp / Traffic.VEL_QUANTUM, math.round(comp / Traffic.VEL_QUANTUM), 1e-9, "quantized")
			end
		end
		-- sagging under the ride height: pushed back up
		t.ok(Traffic._moverVelocity(target - Vector3.new(0, 2, 0), target, heading, 30).Y > 0, "holds ride height")
	end)

	t.test("spacing cone: precomputed right vector gives the same answer (PERF-09)", function()
		local pos = Traffic._lanePoint("Z", 1, -1, 100)
		local fwd = Traffic._forward("Z", -1)
		local right = fwd:Cross(Vector3.yAxis)
		local rng = H.Random.new(11)
		for _ = 1, 200 do
			local other = pos + Vector3.new(rng:NextNumber(-40, 40), 0, rng:NextNumber(-40, 40))
			t.eq(Traffic._aheadDistance(pos, fwd, other, nil, right), Traffic._aheadDistance(pos, fwd, other))
		end
	end)

	t.test("street: rerollOutOfView expires out-of-view parked cars for a luck event (F21)", function()
		local cars = {}
		for i = 1, 3 do
			local car = Street.spawnAt(CFrame.new(400 + i * 30, 0, -400))
			t.ok(car ~= nil, "spawned")
			table.insert(cars, car)
		end
		t.eq(Street.rerollOutOfView(0), 0, "fraction 0")
		local n = Street.rerollOutOfView(1)
		t.ok(n >= #cars, "nobody around: every parked car can re-roll")
		t.eq(Street.rerollOutOfView(1), 0, "already expired ones aren't counted twice")
		t.eq(Street.rerollOutOfView(0 / 0), 0, "NaN fraction -> default, nothing left to expire")
		for _, car in cars do
			VS.destroy(car, "test")
		end
	end)

	t.test("parking spots never sit in traffic lanes", function()
		for _, cf in MapLayout.parkingSpots() do
			local p = cf.Position
			local lx = math.abs(p.X - math.round(p.X / S) * S)
			local lz = math.abs(p.Z - math.round(p.Z / S) * S)
			t.ok(math.min(lx, lz) - Traffic.LANE_OFFSET >= 7.3 + 0.5, "parked chassis clears traffic chassis")
		end
	end)
end
