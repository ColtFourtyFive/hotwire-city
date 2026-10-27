--!nocheck
-- Police slice: pure AI helpers (steering, grid routing, unstuck, ramming, allocation, spawn lanes),
-- the helicopter builder, and WantedService logic with injected fakes.
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local PoliceConfig = H.require("src/shared/Config/Police")
	local Economy = H.require("src/shared/Config/Economy")
	local Police = H.require("src/server/Systems/PoliceService")
	local Wanted = H.require("src/server/Systems/WantedService")

	local S = MapConfig.GRID_SPACING
	local rng = H.Random.new(1234)

	local function flatDist(a, b)
		return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
	end

	-- every sample along a -> b must be on asphalt
	local function segmentOnRoad(a, b)
		local d = flatDist(a, b)
		local n = math.max(1, math.ceil(d / 2))
		for i = 0, n do
			local p = a:Lerp(b, i / n)
			if not MapLayout.isOnRoad(p) then
				return false, p
			end
		end
		return true
	end

	local function randomRoadPoint()
		local line = rng:NextInteger(MapConfig.LINE_MIN, MapConfig.LINE_MAX)
		local along = rng:NextNumber(-MapConfig.HALF_EXTENT, MapConfig.HALF_EXTENT)
		local off = rng:NextNumber(-18, 18)
		if rng:NextNumber() < 0.5 then
			return Vector3.new(line * S + off, 0, along)
		end
		return Vector3.new(along, 0, line * S + off)
	end

	-- STEERING ---------------------------------------------------------------------------------------

	t.test("steerToward sign: +1 = right turn", function()
		local fwd = Vector3.new(0, 0, -1) -- identity LookVector; RightVector is +X
		local s, a = Police._steerToward(fwd, Vector3.new(10, 0, -10))
		t.ok(s > 0, "target ahead-right should steer right, got " .. s)
		t.near(a, 45, 1e-6, "angle")
		s = Police._steerToward(fwd, Vector3.new(-10, 0, -10))
		t.ok(s < 0, "target ahead-left should steer left")
		s, a = Police._steerToward(fwd, Vector3.new(0, 0, -50))
		t.near(s, 0, 1e-9, "straight ahead")
		t.near(a, 0, 1e-9)
		s, a = Police._steerToward(fwd, Vector3.new(30, 0, 0))
		t.eq(s, 1, "90° right clamps to full lock")
		t.near(a, 90, 1e-6)
		s, a = Police._steerToward(fwd, Vector3.new(0.01, 0, 40))
		t.ok(math.abs(a) > 170, "behind is ~180°")
		-- facing +Z, right is -X
		s = Police._steerToward(Vector3.new(0, 0, 1), Vector3.new(-5, 0, 10))
		t.ok(s > 0, "facing +Z, -X is to the right")
		-- proportional below the full-lock angle (35°)
		s, a = Police._steerToward(fwd, CFrame.Angles(0, math.rad(-17.5), 0).LookVector)
		t.near(a, 17.5, 1e-3)
		t.near(s, 0.5, 1e-3, "half angle -> half steer")
		-- vertical components are ignored
		s = Police._steerToward(Vector3.new(0, 0.5, -1), Vector3.new(10, 50, -10))
		t.ok(s > 0)
		t.eq(Police._steerToward(fwd, Vector3.zero), 0, "zero vector -> no steer")
	end)

	t.test("steering sign agrees with the yaw convention (right turn = negative Y rotation)", function()
		-- Rotating the car by a negative yaw turns it right: that new heading must read as positive steer.
		for _, deg in { 5, 20, 34, 60, 120 } do
			for _, base in { 0, 37, 90, 180, 251 } do
				local car = CFrame.Angles(0, math.rad(base), 0)
				local turnedRight = (car * CFrame.Angles(0, math.rad(-deg), 0)).LookVector
				local s, a = Police._steerToward(car.LookVector, turnedRight)
				t.ok(s > 0, ("base %d turn %d -> steer %s"):format(base, deg, tostring(s)))
				t.near(a, deg, 1e-3)
			end
		end
	end)

	-- ROAD GRID ----------------------------------------------------------------------------------------

	t.test("roadLines classifies roads, intersections and blocks", function()
		local x, z = Police._roadLines(Vector3.new(160 + 8, 0, 75))
		t.eq(x, 1)
		t.eq(z, nil)
		x, z = Police._roadLines(Vector3.new(-12, 0, 320 + 5))
		t.eq(x, 0)
		t.eq(z, 2)
		x, z = Police._roadLines(Vector3.new(80, 0, 80)) -- block center
		t.eq(x, nil)
		t.eq(z, nil)
		x, z = Police._roadLines(Vector3.new(870, 0, 0)) -- beach
		t.eq(x, nil)
		t.eq(z, nil)
	end)

	t.test("roadAnchor always lands on asphalt, near the input", function()
		for _ = 1, 400 do
			local p = Vector3.new(rng:NextNumber(-950, 950), 0, rng:NextNumber(-950, 950))
			local a = Police._roadAnchor(p)
			t.ok(MapLayout.isOnRoad(a), "anchor off road for " .. tostring(p))
			local cx = math.clamp(p.X, -800, 800)
			local cz = math.clamp(p.Z, -800, 800)
			t.ok(flatDist(a, Vector3.new(cx, 0, cz)) <= S / 2 + 1, "anchor too far for " .. tostring(p))
		end
		local inter = Vector3.new(160 + 5, 0, -320 - 9)
		local a = Police._roadAnchor(inter)
		t.near(a.X, inter.X, 1e-9, "intersection point unchanged")
		t.near(a.Z, inter.Z, 1e-9)
	end)

	t.test("nextWaypoint: same road -> drive straight at the target", function()
		local pos = Vector3.new(160 - 8, 0, -300)
		local target = Vector3.new(160 + 6, 0, 250)
		local wp, isTurn = Police._nextWaypoint(pos, target)
		t.eq(isTurn, false)
		t.near(wp.X, target.X, 1e-9)
		t.near(wp.Z, target.Z, 1e-9)
	end)

	t.test("nextWaypoint: perpendicular road -> turn at the shared intersection", function()
		local pos = Vector3.new(160 - 8, 0, -300) -- on the x=160 road
		local target = Vector3.new(-250, 0, 480 + 4) -- on the z=480 road
		local wp, isTurn = Police._nextWaypoint(pos, target)
		t.eq(isTurn, true)
		t.near(wp.X, 160, 1e-9)
		t.near(wp.Z, 480, 1e-9)
	end)

	t.test("grid routing never cuts through a block and always arrives", function()
		local trips = 0
		for i = 1, 600 do
			local start = if i % 5 == 0
				then Vector3.new(rng:NextNumber(-940, 940), 0, rng:NextNumber(-940, 940))
				else randomRoadPoint()
			local target = Vector3.new(rng:NextNumber(-950, 950), 0, rng:NextNumber(-950, 950))
			local fwd = if i % 2 == 0 then CFrame.Angles(0, rng:NextNumber(0, 2 * math.pi), 0).LookVector else nil
			local tA = Police._roadAnchor(target)
			local pos = start
			local arrived = false
			local length = 0
			local firstLegOffRoad = not MapLayout.isOnRoad(start)
			for hop = 1, 8 do
				local wp, isTurn = Police._nextWaypoint(pos, target, fwd)
				if not (hop == 1 and firstLegOffRoad) then
					local ok, bad = segmentOnRoad(pos, wp)
					t.ok(
						ok,
						("leg %d from %s to %s leaves the road at %s"):format(
							hop,
							tostring(pos),
							tostring(wp),
							tostring(bad)
						)
					)
				else
					t.ok(MapLayout.isOnRoad(wp), "off-road start must hop onto a road")
				end
				length += flatDist(pos, wp)
				if fwd and flatDist(pos, wp) > 0.5 then
					fwd = (wp - pos) * Vector3.new(1, 0, 1)
					fwd = fwd.Unit
				end
				pos = wp
				if not isTurn then
					arrived = true
					break
				end
			end
			t.ok(arrived, ("never arrived: %s -> %s"):format(tostring(start), tostring(target)))
			t.ok(flatDist(pos, tA) < 1e-6, "must end exactly at the road anchor")
			if not firstLegOffRoad and fwd == nil then
				local manhattan = math.abs(start.X - tA.X) + math.abs(start.Z - tA.Z)
				t.ok(length <= manhattan + 2 * S, ("route too long: %.0f vs manhattan %.0f"):format(length, manhattan))
			end
			trips += 1
		end
		t.eq(trips, 600)
	end)

	t.test("nextWaypoint: off-road cop first returns to the nearest road", function()
		local pos = Vector3.new(80, 0.6, 70) -- middle of a block, nearest edge is the z=160 road side? no: z=0 edge is 70 away
		local wp, isTurn = Police._nextWaypoint(pos, Vector3.new(-600, 0, -600))
		t.eq(isTurn, true)
		t.ok(MapLayout.isOnRoad(wp))
		t.ok(flatDist(wp, pos) <= 80, "short hop")
	end)

	-- UNSTUCK ------------------------------------------------------------------------------------------

	t.test("unstuck: reverse with opposite steer after STUCK_TIME, then recover", function()
		local s = Police._newStuck()
		local now = 0
		local reversing = false
		local steps = 0
		while not reversing and steps < 100 do
			steps += 1
			now += 0.1
			reversing = Police._updateStuck(s, 0.5, 1, 0.8, 0.1, now)
		end
		t.ok(reversing, "should start reversing")
		t.near(steps * 0.1, PoliceConfig.STUCK_TIME, 0.11, "after ~STUCK_TIME")
		t.eq(s.reverseSteer, -1, "opposite of the right steer")
		t.eq(s.count, 1)
		-- keeps reversing for ~1.2s regardless of input
		t.ok(Police._updateStuck(s, 10, 1, 0, 0.1, now + 0.5))
		t.ok(Police._updateStuck(s, 10, 1, 0, 0.1, now + 1.1))
		t.eq(Police._updateStuck(s, 10, 1, 0, 0.1, now + 1.3), false, "done reversing")
		-- left steer -> reverse right
		local s2 = Police._newStuck()
		local r = false
		for k = 1, 40 do
			r = Police._updateStuck(s2, 0, 1, -0.6, 0.1, k * 0.1)
			if r then
				break
			end
		end
		t.ok(r)
		t.eq(s2.reverseSteer, 1)
	end)

	t.test("unstuck: holding / moving never counts as stuck; blocked reversing pulls forward", function()
		local s = Police._newStuck()
		for k = 1, 100 do
			t.eq(Police._updateStuck(s, 0, 0, 0, 0.1, k * 0.1), false, "holding still (throttle 0) is not stuck")
		end
		for k = 1, 100 do
			t.eq(Police._updateStuck(s, 40, 1, 0, 0.1, 10 + k * 0.1), false, "moving is not stuck")
		end
		-- progress resets when the car moves again
		for k = 1, 15 do
			Police._updateStuck(s, 0, 1, 0, 0.1, 30 + k * 0.1)
		end
		Police._updateStuck(s, 20, 1, 0, 0.1, 32)
		t.eq(s.stuckTime, 0)
		t.eq(s.recoverThrottle, -1, "default recovery backs out")
		-- reversing into a wall (throttle -1, no motion) -> recover by pulling forward with the opposite steer
		local r = false
		for k = 1, 40 do
			r = Police._updateStuck(s, 0.5, -1, -1, 0.1, 40 + k * 0.1)
			if r then
				break
			end
		end
		t.ok(r, "blocked reverse is stuck too")
		t.eq(s.recoverThrottle, 1)
		t.eq(s.reverseSteer, 1)
	end)

	-- DRIVING LAW --------------------------------------------------------------------------------------

	t.test("drive law: full send straight, brake for turns, K-turn when the aim is behind", function()
		local fwd = Vector3.new(0, 0, -1)
		local thr, steer, hb = Police._drive(fwd, 80, Vector3.new(0, 0, -300), false, 300)
		t.eq(thr, 1)
		t.near(steer, 0, 1e-6)
		t.eq(hb, false)
		-- 90° to the right at 100 studs/s: brake hard, full lock
		thr, steer = Police._drive(fwd, 100, Vector3.new(300, 0, 0), false, 300)
		t.eq(thr, -1)
		t.eq(steer, 1)
		-- approaching a turn: fine when far, braking when close and fast
		thr = Police._drive(fwd, 100, Vector3.new(0, 0, -400), true, 400)
		t.eq(thr, 1)
		thr = Police._drive(fwd, 100, Vector3.new(0, 0, -40), true, 40)
		t.eq(thr, -1)
		thr = Police._drive(fwd, 30, Vector3.new(0, 0, -40), true, 40)
		t.eq(thr, 1, "slow enough for the corner")
		-- aim right behind us: brake straight from speed, then back up on opposite lock
		thr, steer = Police._drive(fwd, 60, Vector3.new(5, 0, 80), false, 80)
		t.eq(thr, -1)
		t.eq(steer, 0, "no steering while braking hard")
		thr, steer = Police._drive(fwd, 1, Vector3.new(5, 0, 80), false, 80)
		t.eq(thr, -1, "reverse")
		t.eq(steer, -1, "opposite lock swings the nose toward the right-behind aim")
		-- close aim point off to the side: slow down instead of orbiting it
		thr = Police._drive(fwd, 40, Vector3.new(20, 0, -2), false, 20)
		t.ok(thr <= 0, "must not accelerate into an orbit")
	end)

	t.test("routing hysteresis keeps a committed turn unless a new route is clearly better", function()
		local pos = Vector3.new(-152, 0, -300) -- northbound-ish on the x=-160 road
		local target = Vector3.new(545, 0, 306) -- on the z=320 road
		local best = Police._nextWaypoint(pos, target, Vector3.new(0, 0, 1), 60)
		t.near(best.X, -160, 1e-6)
		t.near(best.Z, 320, 1e-6)
		-- a near-tied alternative we were already committed to is kept
		local keep = Vector3.new(-160, 0, 160)
		local wp, isTurn = Police._nextWaypoint(pos, target, Vector3.new(0, 0, 1), 60, keep)
		t.eq(isTurn, true)
		t.near(wp.Z, 160, 1e-6, "kept committed turn")
		-- a committed waypoint that isn't on our road any more is dropped
		wp = Police._nextWaypoint(pos, target, Vector3.new(0, 0, 1), 60, Vector3.new(320, 0, 160))
		t.near(wp.X, -160, 1e-6)
		t.near(wp.Z, 320, 1e-6)
		-- at speed, turning right now is expensive: prefer the straight-ahead route when Manhattan-tied
		local inJunction = Vector3.new(-151, 0, -495) -- entering the (-160,-480) junction at speed
		wp = Police._nextWaypoint(inJunction, target, Vector3.new(0, 0, 1), 105)
		t.near(wp.X, -160, 1e-6, "keep going straight")
	end)

	t.test("driving simulation: routed cops make every turn without leaving the road", function()
		-- Kinematic arcade model from Config/Vehicle (drive/brake/drag + first-order yaw), AI at AI_TICK.
		local T = H.require("src/shared/Config/Vehicle")
		local Cars = H.require("src/shared/Config/Cars")
		local def = Cars.Police
		local simRng = H.Random.new(4242)
		local function sgn(x)
			return if x < 0 then -1 else 1
		end
		local function stepCar(c, inp, dt, vMax)
			local vF = c.v
			local a
			if inp.throttle > 0.01 then
				if vF < -2 then
					a = math.min(T.BRAKE_DECEL, math.abs(vF) / dt)
				else
					local r = math.max(vF, 0) / vMax
					a = inp.throttle * def.accel * (1 - r * r)
				end
			elseif inp.throttle < -0.01 then
				if vF > 2 then
					a = -math.min(T.BRAKE_DECEL, math.abs(vF) / dt)
				else
					local r = math.max(-vF, 0) / T.REVERSE_MAX_SPEED
					a = -T.REVERSE_ACCEL * (1 - r * r)
				end
			else
				a = -sgn(vF) * math.min(T.ROLLING_RESISTANCE, math.abs(vF) / dt)
			end
			if inp.handbrake and math.abs(vF) > 0.5 then
				a -= sgn(vF) * math.min(14, math.abs(vF) / dt)
			end
			a += -T.AIR_DRAG * vF * math.abs(vF)
			c.v = vF + a * dt
			local sp = math.abs(c.v)
			local yaw = -inp.steer
				* T.MAX_YAW_RATE
				* math.clamp(sp / 15, 0, 1)
				* (1 - T.HIGH_SPEED_STEER_FALLOFF * math.clamp(sp / vMax, 0, 1))
				* (if c.v < -0.5 then -1 else 1)
			c.yawRate += (yaw - c.yawRate) * math.min(1, T.YAW_RESPONSE * dt)
			c.th += c.yawRate * dt
			local fwd = Vector3.new(-math.sin(c.th), 0, -math.cos(c.th))
			c.pos += fwd * c.v * dt
			return fwd
		end
		local function excursion(p)
			if math.abs(p.X) > 820 or math.abs(p.Z) > 820 then
				return 0 -- beach ring is open ground
			end
			local dx = math.abs(p.X - math.round(p.X / S) * S)
			local dz = math.abs(p.Z - math.round(p.Z / S) * S)
			return math.max(0, math.min(dx, dz) - MapConfig.ROAD_WIDTH / 2)
		end
		local worst, total, trips = 0, 0, 0
		for _, mult in { 0.82, 1.2 } do
			local vMax = def.topSpeed * mult
			for trip = 1, 30 do
				local target = Vector3.new(simRng:NextNumber(-780, 780), 0, simRng:NextNumber(-780, 780))
				local start = Police._orientedLane(
					Vector3.new(simRng:NextNumber(-780, 780), 0, simRng:NextNumber(-780, 780)),
					target
				)
				if trip % 2 == 0 then
					start = start * CFrame.Angles(0, math.pi, 0) -- facing away: needs a K-turn
				end
				local look = start.LookVector
				local c = { pos = start.Position, v = 40, th = math.atan2(-look.X, -look.Z), yawRate = 0 }
				local fwd = look
				local inp = { throttle = 0, steer = 0, handbrake = false }
				local keep = nil
				local acc, tSim, arrived, tripWorst = 1, 0, false, 0
				while tSim < 60 do
					acc += 1 / 60
					if acc >= PoliceConfig.AI_TICK then
						acc = 0
						local wp, isTurn = Police._nextWaypoint(c.pos, target, fwd, c.v, keep)
						keep = if isTurn then wp else nil
						local d = flatDist(wp, c.pos)
						inp.throttle, inp.steer, inp.handbrake = Police._drive(fwd, c.v, wp - c.pos, isTurn, d)
						if not isTurn and d < 20 then
							arrived = true
							break
						end
					end
					fwd = stepCar(c, inp, 1 / 60, vMax)
					tSim += 1 / 60
					tripWorst = math.max(tripWorst, excursion(c.pos))
				end
				t.ok(arrived, ("trip %d (x%.2f) never arrived"):format(trip, mult))
				worst = math.max(worst, tripWorst)
				total += tripWorst
				trips += 1
			end
		end
		t.ok(worst <= 6, ("a cop left the road by %.1f studs"):format(worst))
		t.ok(total / trips <= 0.5, ("mean excursion %.2f"):format(total / trips))
	end)

	t.test("chase simulation: cops run down a lane-driving suspect and stay on the asphalt", function()
		-- Same decision split as PoliceService.think: pursuit when feasible with line of sight, else grid routing.
		-- LOS approximation: the straight segment stays on asphalt (blocks are the only occluders).
		local T = H.require("src/shared/Config/Vehicle")
		local Cars = H.require("src/shared/Config/Cars")
		local def = Cars.Police
		local simRng = H.Random.new(99)
		local vMax = def.topSpeed
		local suspectSpeed = 80
		local function sgn(x)
			return if x < 0 then -1 else 1
		end
		local function los(a, b)
			local n = math.max(1, math.ceil((a - b).Magnitude / 4))
			for i = 0, n do
				if not MapLayout.isOnRoad(a:Lerp(b, i / n)) then
					return false
				end
			end
			return true
		end
		local function excursion(p)
			if math.abs(p.X) > 820 or math.abs(p.Z) > 820 then
				return 0
			end
			local dx = math.abs(p.X - math.round(p.X / S) * S)
			local dz = math.abs(p.Z - math.round(p.Z / S) * S)
			return math.max(0, math.min(dx, dz) - MapConfig.ROAD_WIDTH / 2)
		end
		local caught, trials, exSum = 0, 20, 0
		for _ = 1, trials do
			-- suspect: lane follower turning at random junctions
			local sus = {
				axis = if simRng:NextNumber() < 0.5 then "X" else "Z",
				line = simRng:NextInteger(-4, 4),
				dir = if simRng:NextNumber() < 0.5 then 1 else -1,
				along = simRng:NextInteger(-4, 4) * S + 80,
				lastJ = nil,
			}
			local spos = MapLayout.laneCFrame(sus.axis, sus.line, sus.along, sus.dir).Position
			local start = Police._orientedLane(
				spos + Vector3.new(simRng:NextNumber(-250, 250), 0, simRng:NextNumber(-250, 250)),
				spos
			)
			local look = start.LookVector
			local c = { pos = start.Position, v = 45, th = math.atan2(-look.X, -look.Z), yawRate = 0 }
			local fwd, keep, svel = look, nil, Vector3.zero
			local inp = { throttle = 0, steer = 0 }
			local acc, tSim, done, worstEx = 1, 0, false, 0
			while tSim < 60 and not done do
				local dt = 1 / 60
				-- advance suspect
				local old = sus.along
				sus.along += sus.dir * suspectSpeed * dt
				local j = math.round(sus.along / S) * S
				if (old - j) * (sus.along - j) <= 0 and math.abs(j) <= 800 and sus.lastJ ~= j then
					sus.lastJ = j
					if simRng:NextNumber() < 0.45 or math.abs(sus.along + sus.dir * 30) > 800 then
						local newDir = if simRng:NextNumber() < 0.5 then 1 else -1
						local newAlong = sus.line * S
						if math.abs(newAlong + newDir * 100) > 800 then
							newDir = -newDir
						end
						sus.axis = if sus.axis == "X" then "Z" else "X"
						sus.line = j / S
						sus.along = newAlong
						sus.dir = newDir
						sus.lastJ = newAlong
					end
				end
				if math.abs(sus.along) > 790 then
					sus.dir = -sus.dir
				end
				local scf = MapLayout.laneCFrame(sus.axis, sus.line, sus.along, sus.dir)
				spos, svel = scf.Position, scf.LookVector * suspectSpeed
				-- cop AI at AI_TICK
				acc += dt
				if acc >= PoliceConfig.AI_TICK then
					acc = 0
					local dist = flatDist(spos, c.pos)
					local L = dist <= 260 and los(c.pos, spos)
					local _, angS = Police._steerToward(fwd, spos - c.pos)
					local aim, cornering, wpDist
					if Police._usePursuit(L, dist, math.abs(angS), c.v) then
						keep = nil
						local pred = spos + svel * math.clamp(dist / 60, 0.3, 1.5)
						if not MapLayout.isOnRoad(pred) and MapLayout.isOnRoad(spos) then
							pred = Police._roadAnchor(pred)
						end
						if flatDist(pred, spos) > 4 and not los(c.pos, pred) then
							pred = spos
						end
						aim, cornering, wpDist = pred, false, 0
					else
						local wp, isTurn = Police._nextWaypoint(c.pos, spos, fwd, c.v, keep)
						keep = if isTurn then wp else nil
						aim, cornering, wpDist = wp, isTurn, flatDist(wp, c.pos)
					end
					inp.throttle, inp.steer = Police._drive(fwd, c.v, aim - c.pos, cornering, wpDist)
					if dist < 12 then
						done = true
					end
				end
				-- cop physics (arcade kinematics, no handbrake)
				local vF = c.v
				local a
				if inp.throttle > 0.01 then
					if vF < -2 then
						a = math.min(T.BRAKE_DECEL, math.abs(vF) / dt)
					else
						local r = math.max(vF, 0) / vMax
						a = def.accel * (1 - r * r)
					end
				elseif inp.throttle < -0.01 then
					if vF > 2 then
						a = -math.min(T.BRAKE_DECEL, math.abs(vF) / dt)
					else
						local r = math.max(-vF, 0) / T.REVERSE_MAX_SPEED
						a = -T.REVERSE_ACCEL * (1 - r * r)
					end
				else
					a = -sgn(vF) * math.min(T.ROLLING_RESISTANCE, math.abs(vF) / dt)
				end
				c.v = vF + (a - T.AIR_DRAG * vF * math.abs(vF)) * dt
				local sp = math.abs(c.v)
				local yaw = -inp.steer
					* T.MAX_YAW_RATE
					* math.clamp(sp / 15, 0, 1)
					* (1 - T.HIGH_SPEED_STEER_FALLOFF * math.clamp(sp / vMax, 0, 1))
					* (if c.v < -0.5 then -1 else 1)
				c.yawRate += (yaw - c.yawRate) * math.min(1, T.YAW_RESPONSE * dt)
				c.th += c.yawRate * dt
				fwd = Vector3.new(-math.sin(c.th), 0, -math.cos(c.th))
				c.pos += fwd * c.v * dt
				tSim += dt
				worstEx = math.max(worstEx, excursion(c.pos))
			end
			if done then
				caught += 1
			end
			exSum += worstEx
		end
		t.ok(caught >= trials * 0.8, ("cops caught only %d/%d slower suspects"):format(caught, trials))
		t.ok(exSum / trials <= 3, ("mean worst excursion per chase %.2f"):format(exSum / trials))
	end)

	-- RAMMING / ALLOCATION / SPAWNING --------------------------------------------------------------------

	t.test("isRam: only the player hitting the cop counts", function()
		local cop = Vector3.new(0, 0, 0)
		-- player T-bones a parked cop at 70
		t.eq((Police._isRam(Vector3.new(-12, 0, 0), Vector3.new(70, 0, 0), cop, Vector3.zero)), true)
		-- cop rear-ends a fleeing player: no heat
		t.eq((Police._isRam(Vector3.new(0, 0, -10), Vector3.new(0, 0, -50), cop, Vector3.new(0, 0, -100))), false)
		-- gentle bump
		t.eq((Police._isRam(Vector3.new(-12, 0, 0), Vector3.new(25, 0, 0), cop, Vector3.zero)), false)
		-- head-on, player faster
		t.eq((Police._isRam(Vector3.new(0, 0, 12), Vector3.new(0, 0, -60), cop, Vector3.new(0, 0, 30))), true)
	end)

	t.test("allocateUnits shares the global cap fairly", function()
		local a = Police._allocateUnits({ 6, 6, 6 }, 14)
		t.eq(a[1] + a[2] + a[3], 14)
		t.ok(math.max(a[1], a[2], a[3]) - math.min(a[1], a[2], a[3]) <= 1, "fair split")
		t.eq(a[1], 5, "priority order gets the remainder")
		a = Police._allocateUnits({ 1, 2 }, 14)
		t.eq(a[1], 1)
		t.eq(a[2], 2)
		a = Police._allocateUnits({ 3, 3 }, 0)
		t.eq(a[1] + a[2], 0)
		a = Police._allocateUnits({}, 10)
		t.eq(#a, 0)
		-- config sanity
		t.eq(#PoliceConfig.UNITS_PER_STAR, PoliceConfig.MAX_STARS)
		t.ok(PoliceConfig.RESPAWN_IF_FARTHER > PoliceConfig.SIGHT_RANGE, "rubber band must happen out of sight range")
	end)

	t.test("orientedLane: on the road, facing the suspect", function()
		for _ = 1, 300 do
			local p = Vector3.new(rng:NextNumber(-800, 800), 0, rng:NextNumber(-800, 800))
			local suspect = Vector3.new(rng:NextNumber(-800, 800), 0, rng:NextNumber(-800, 800))
			local lane = Police._orientedLane(p, suspect)
			t.ok(MapLayout.isOnRoad(lane.Position), "lane off road")
			local look = lane.LookVector
			local axisDelta = if math.abs(look.X) > 0.5
				then (suspect.X - lane.Position.X) * look.X
				else (suspect.Z - lane.Position.Z) * look.Z
			t.ok(axisDelta >= -1e-6, "lane faces away from the suspect")
		end
	end)

	t.test("spawnCandidates start directly behind the suspect", function()
		local origin = Vector3.new(100, 0, 100)
		local list = Police._spawnCandidates(origin, Vector3.new(0, 0, 1), { 200 })
		t.ok(#list >= 8)
		t.near(list[1].X, 100, 1e-3)
		t.near(list[1].Z, 300, 1e-3)
		for _, p in list do
			t.near(flatDist(p, origin), 200, 1e-3)
		end
		-- the "ahead" candidate is last
		t.near(list[#list].Z, -100, 1e-3)
	end)

	-- HELICOPTER -------------------------------------------------------------------------------------------

	t.test("buildHeli: structure the runtime relies on", function()
		local model = Police.buildHeli()
		t.eq(model.Name, "PoliceHeli")
		local body = model.PrimaryPart
		t.ok(body and body.Name == "Body", "PrimaryPart Body")
		t.ok(body.Anchored, "root anchored")
		local hub = model:FindFirstChild("RotorHub")
		t.ok(hub, "RotorHub")
		local weld = hub:FindFirstChild("RotorWeld")
		t.ok(weld and weld:IsA("Weld") and weld.Part0 == body and weld.Part1 == hub, "RotorWeld")
		-- weld C0 reproduces the built hub pose
		local posErr = ((body.CFrame * weld.C0).Position - hub.CFrame.Position).Magnitude
		t.ok(posErr < 1e-4, "RotorWeld C0 mismatch " .. posErr)
		local disc = model:FindFirstChild("SpotDisc")
		t.ok(disc and disc.Anchored, "SpotDisc anchored")
		local light = model:FindFirstChild("Searchlight")
		t.ok(light and light:FindFirstChildOfClass("SpotLight"), "SpotLight")
		t.ok(light:FindFirstChild("LightCone"), "beam cone")
		t.ok(model:FindFirstChild("SirenRed") and model:FindFirstChild("SirenBlue"), "siren lights")
		local count = 0
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				count += 1
				t.eq(d.CanCollide, false, d.Name .. " must not collide")
				t.eq(d.CanTouch, false, d.Name .. " must not touch")
				if d ~= body and d ~= disc then
					t.eq(d.Anchored, false, d.Name .. " should hang off the anchored root")
					local hasWeld = false
					for _, c in d:GetChildren() do
						if c:IsA("WeldConstraint") or c:IsA("Weld") then
							hasWeld = true
						end
					end
					t.ok(hasWeld, d.Name .. " not welded")
				end
			end
		end
		t.ok(count <= 40, "part budget: " .. count)
		t.ok(model:HasTag("PoliceHeli"))
	end)

	-- PURSUIT SPEED (fast getaway cars) -------------------------------------------------------------------

	t.test("unit speed: per-star base, matched to fast suspect cars, catch-up bonus", function()
		local Cars = H.require("src/shared/Config/Cars")
		local cop = Cars.Police.topSpeed
		local mult = Police._unitSpeedMult
		-- on foot / slow cars: the old per-star table
		t.near(mult(1, 0, false), 0.82, 1e-9, "1 star on foot")
		t.near(mult(5, 0, false), 1.08, 1e-9, "5 stars on foot")
		t.near(mult(3, 70, false), 0.97, 1e-9, "slow car: star base wins")
		t.near(mult(3, 0, true), 0.97 + 0.12, 1e-9, "catch-up bonus")
		-- a 175 studs/s Legendary: 1-star cops stay beatable, 5-star cops are faster than the car
		t.ok(mult(1, 175, false) * cop < 175, "1-star cops are slower than a Legendary")
		t.ok(mult(3, 175, false) * cop < 175, "3-star cops still a bit slower")
		t.ok(mult(5, 175, false) * cop > 175, "5-star cops catch a Legendary")
		t.ok(mult(5, 175, false) > mult(3, 175, false) and mult(3, 175, false) > mult(1, 175, false), "monotonic")
		-- sane bounds / junk input
		t.ok(mult(5, 10000, true) <= 2.5, "capped")
		t.near(mult(0, 0, false), 0.82, 1e-9, "stars clamp to 1")
		t.near(mult(9, 0 / 0, false), 1.08, 1e-9, "NaN top speed ignored, stars clamp to 5")
		t.eq(mult(4, 150, false), math.floor(mult(4, 150, false) * 100 + 0.5) / 100, "rounded (attribute churn)")
	end)

	t.test("heli speed + suspect car top speed", function()
		t.eq(Police._heliMaxSpeed(0), 95, "on foot: base chopper speed")
		t.eq(Police._heliMaxSpeed(70), 95, "slow car: base")
		t.near(Police._heliMaxSpeed(175), 175 * 0.9, 1e-9, "fast car: 90% of its top speed")
		t.eq(Police._heliMaxSpeed(0 / 0), 95)
		local Cars = H.require("src/shared/Config/Cars")
		local def = Cars.List[1]
		t.eq(Police._carTopSpeed({ def = def }), def.topSpeed, "from the record's def")
		t.eq(Police._carTopSpeed({ carId = def.id }), def.topSpeed, "from the carId")
		t.eq(Police._carTopSpeed({ carId = "nope" }), 0)
		t.eq(Police._carTopSpeed(nil), 0)
	end)

	t.test("spawn lane clearance against pre-collected blockers", function()
		local blockers = { Vector3.new(0, 0, 0), Vector3.new(100, 0, 0) }
		t.ok(not Police._isClearOf(Vector3.new(5, 30, 5), blockers), "flat distance (height ignored)")
		t.ok(not Police._isClearOf(Vector3.new(110, 0, 0), blockers), "second blocker")
		t.ok(Police._isClearOf(Vector3.new(50, 0, 0), blockers), "between them")
		t.ok(Police._isClearOf(Vector3.new(0, 0, 0), {}), "nothing around")
	end)

	-- WANTED SERVICE -----------------------------------------------------------------------------------------

	t.test("wanted pure helpers", function()
		t.eq(Wanted._penalty(10000, 1), 600, "capped at 600s of income")
		t.eq(Wanted._penalty(500, 100), 50, "10% of cash")
		t.eq(Wanted._penalty(1234, 0), 0, "no income -> nothing")
		t.eq(Wanted._penalty(-50, 10), 0)
		t.eq(Wanted._penalty(999, 1000), 99, "floored")
		t.eq(Wanted._adjustHeat(1, true), 0)
		t.eq(Wanted._adjustHeat(3, true), 1)
		t.eq(Wanted._adjustHeat(2, false), 2)
		t.eq(Wanted._adjustHeat(-1, false), 0)
		t.eq(Wanted._decayDelay(1), PoliceConfig.DECAY_DELAY[1])
		t.eq(Wanted._decayDelay(5), PoliceConfig.DECAY_DELAY[5])
		t.eq(Wanted._decayDelay(99), PoliceConfig.DECAY_DELAY[#PoliceConfig.DECAY_DELAY])
	end)

	t.test("wanted decay timer: seen resets, then one star per DECAY_STEP", function()
		local st = { stars = 2, nextDecayAt = 10 }
		t.eq(Wanted._tickDecay(st, 5, false), 2)
		t.eq(Wanted._tickDecay(st, 5, true), 2)
		t.eq(st.nextDecayAt, 5 + PoliceConfig.DECAY_DELAY[2], "seen resets the timer")
		local at = st.nextDecayAt
		t.eq(Wanted._tickDecay(st, at - 0.01, false), 2)
		st.stars = Wanted._tickDecay(st, at, false)
		t.eq(st.stars, 1)
		t.eq(st.nextDecayAt, at + PoliceConfig.DECAY_STEP)
		st.stars = Wanted._tickDecay(st, at + PoliceConfig.DECAY_STEP, false)
		t.eq(st.stars, 0)
		t.eq(Wanted._tickDecay(st, 1e6, false), 0)
	end)

	-- Fake player + systems for the stateful API.
	local function fakePlayer(name, userId)
		local attrs = {}
		return {
			Name = name,
			DisplayName = name,
			UserId = userId,
			Parent = nil,
			Character = nil,
			SetAttribute = function(_, k, v)
				attrs[k] = v
			end,
			GetAttribute = function(_, k)
				return attrs[k]
			end,
			IsA = function(_, cls)
				return cls == "Player" or cls == "Instance"
			end,
			_attrs = attrs,
		}
	end

	local clock = 0
	local fired = {}
	local progressCalls = {}
	local seenMap = {}
	local datas = {}
	local driving = {}
	local calls = {}
	local mocks = {
		DataService = {
			get = function(p)
				return datas[p]
			end,
			spendCash = function(p, amount)
				local d = datas[p]
				if d and d.cash >= amount then
					d.cash -= amount
					return true
				end
				return false
			end,
			addCash = function(p, amount)
				datas[p].cash += amount
			end,
			markDirty = function() end,
		},
		GarageService = {
			incomePerSec = function()
				return 10
			end,
		},
		RewardsService = {
			progress = function(p, stat, n)
				table.insert(progressCalls, { p, stat, n })
			end,
		},
		PoliceService = {
			isSeen = function(p)
				return seenMap[p] == true
			end,
		},
		VehicleService = {
			getDriving = function(p)
				return driving[p]
			end,
			eject = function(car)
				table.insert(calls, { "eject", car })
			end,
			destroy = function(car, reason)
				table.insert(calls, { "destroy", car, reason })
			end,
		},
		TheftService = {
			fail = function(car, reason)
				table.insert(calls, { "fail", car, reason })
			end,
		},
	}
	Wanted._setHooks({
		isTest = true,
		clock = function()
			return clock
		end,
		system = function(name)
			return mocks[name]
		end,
		fireClient = function(name, player, ...)
			table.insert(fired, { name = name, player = player, args = { ... } })
		end,
		fireAll = function(name, ...)
			table.insert(fired, { name = name, all = true, args = { ... } })
		end,
		fireNear = function(name, _pos, _r, ...)
			table.insert(fired, { name = name, near = true, args = { ... } })
		end,
	})

	local function newData(cash, tutorialDone)
		return { cash = cash, tutorialDone = tutorialDone, stats = { busted = 0 } }
	end

	local function countFired(name)
		local n = 0
		for _, f in fired do
			if f.name == name then
				n += 1
			end
		end
		return n
	end

	t.test("addHeat / Changed / attribute / clamp", function()
		clock = 1000
		local p = fakePlayer("Ace", 1)
		datas[p] = newData(5000, true)
		Wanted._addPlayer(p)
		local changes = {}
		local conn = Wanted.Changed:Connect(function(pl, stars, old)
			if pl == p then
				table.insert(changes, { stars, old })
			end
		end)
		Wanted.addHeat(p, 2, "carjack")
		t.eq(Wanted.getStars(p), 2)
		t.eq(p._attrs.Wanted, 2)
		t.eq(#changes, 1)
		t.eq(changes[1][1], 2)
		t.eq(changes[1][2], 0)
		Wanted.addHeat(p, 9, "hotDrop")
		t.eq(Wanted.getStars(p), PoliceConfig.MAX_STARS, "clamped")
		t.eq(Wanted.getPeak(p), 5)
		Wanted.addHeat(p, 1, "carjack") -- at max: no Changed, but timer refresh
		t.eq(#changes, 2)
		Wanted.clear(p, "product")
		t.eq(Wanted.getStars(p), 0)
		t.eq(p._attrs.Wanted, 0)
		t.eq(#progressCalls, 0, "paid clears are not escapes")
		conn:Disconnect()
		Wanted._removePlayer(p)
	end)

	t.test("brand-new players get halved heat for their first 30s", function()
		clock = 2000
		local p = fakePlayer("Newbie", 2)
		datas[p] = newData(150, false)
		Wanted._addPlayer(p)
		Wanted.addHeat(p, 1, "carjack")
		t.eq(Wanted.getStars(p), 0, "1 halves to 0")
		Wanted.addHeat(p, 3, "hotDrop")
		t.eq(Wanted.getStars(p), 1, "3 halves to 1")
		clock = 2031
		Wanted.addHeat(p, 1, "carjack")
		t.eq(Wanted.getStars(p), 2, "after 30s heat is normal")
		Wanted._removePlayer(p)
	end)

	t.test("decay to zero counts as an escape (escape3 when the peak was >= 3)", function()
		clock = 3000
		table.clear(progressCalls)
		table.clear(fired)
		local p = fakePlayer("Runner", 3)
		datas[p] = newData(1000, true)
		Wanted._addPlayer(p)
		Wanted.addHeat(p, 3, "dealerSteal")
		seenMap[p] = true
		clock += 100
		Wanted._decayPass()
		t.eq(Wanted.getStars(p), 3, "seen: no decay")
		t.eq(p._attrs.WantedSeen, true)
		seenMap[p] = false
		local guard = 0
		while Wanted.getStars(p) > 0 and guard < 2000 do
			guard += 1
			clock += 0.25
			Wanted._decayPass()
		end
		t.eq(Wanted.getStars(p), 0)
		local expected = PoliceConfig.DECAY_DELAY[3] + 2 * PoliceConfig.DECAY_STEP
		t.near(guard * 0.25, expected, 0.3, "3 stars hidden decay time")
		local stats = {}
		for _, c in progressCalls do
			stats[c[2]] = (stats[c[2]] or 0) + c[3]
		end
		t.eq(stats.escape, 1)
		t.eq(stats.escape3, 1)
		t.ok(countFired("EventFeed") >= 1, "3-star escape is announced")
		-- a 1-star escape: escape only
		table.clear(progressCalls)
		Wanted.addHeat(p, 1, "carjack")
		for _ = 1, 400 do
			clock += 0.25
			Wanted._decayPass()
		end
		t.eq(Wanted.getStars(p), 0)
		t.eq(#progressCalls, 1)
		t.eq(progressCalls[1][2], "escape")
		Wanted._removePlayer(p)
	end)

	t.test("bust: penalty, stolen car fails, grace blocks heat", function()
		clock = 5000
		table.clear(fired)
		table.clear(calls)
		local p = fakePlayer("Crook", 4)
		datas[p] = newData(20000, true) -- 10% = 2000, income cap 10*600 = 6000 -> 2000
		Wanted._addPlayer(p)
		local Cars = H.require("src/shared/Config/Cars")
		local carDef = Cars.List[1]
		local car = { kind = "Stolen", carId = carDef.id, mutation = "Gold" }
		driving[p] = car
		Wanted.addHeat(p, 4, "playerTheft")
		local bustedSignal = 0
		local conn = Wanted.Busted:Connect(function(pl)
			if pl == p then
				bustedSignal += 1
			end
		end)
		t.eq(Wanted.bust(p), true)
		t.eq(datas[p].cash, 18000, "lost 10%")
		t.eq(datas[p].stats.busted, 1)
		t.eq(Wanted.getStars(p), 0)
		t.eq(bustedSignal, 1)
		-- the theft ends BEFORE the eject (no spurious "dropped car" state)
		t.eq(calls[1][1], "fail")
		t.eq(calls[1][3], "busted")
		t.eq(calls[2][1], "eject")
		local bustedRemote
		for _, f in fired do
			if f.name == "Busted" then
				bustedRemote = f
			end
		end
		t.ok(bustedRemote and bustedRemote.args[1] == 2000, "Busted remote carries lost cash")
		t.eq(bustedRemote.args[2], "GOLD " .. carDef.name, "Busted remote carries the impounded car")
		t.eq(p._attrs.Stunned, true, "stunned until the release teleport (no CombatService: raw attribute)")
		Wanted.addHeat(p, 2, "carjack")
		t.eq(Wanted.getStars(p), 0, "grace period")
		t.eq(Wanted.bust(p), false, "can't bust with 0 stars")
		clock += 9
		Wanted.addHeat(p, 1, "carjack")
		t.eq(Wanted.getStars(p), 1, "grace over")
		-- loot cars are destroyed
		driving[p] = { kind = "Loot" }
		table.clear(calls)
		t.eq(Wanted.bust(p), true)
		t.eq(calls[1][1], "eject")
		t.eq(calls[2][1], "destroy")
		-- own cars are only ejected: nothing impounded, no car line on the overlay
		clock += 9
		Wanted.addHeat(p, 1, "carjack")
		driving[p] = { kind = "Owned", carId = carDef.id, mutation = "None" }
		table.clear(calls)
		table.clear(fired)
		t.eq(Wanted.bust(p), true)
		t.eq(#calls, 1)
		t.eq(calls[1][1], "eject")
		for _, f in fired do
			if f.name == "Busted" then
				t.eq(f.args[2], nil, "no impound label for an owned car")
			end
		end
		conn:Disconnect()
		driving[p] = nil
		Wanted._removePlayer(p)
	end)

	t.test("clear reports whether there was anything to clear", function()
		clock = 6000
		local p = fakePlayer("Clean", 6)
		datas[p] = newData(100, true)
		Wanted._addPlayer(p)
		t.eq(Wanted.clear(p, "product"), false, "0 stars: nothing to clear")
		Wanted.addHeat(p, 2, "carjack")
		t.eq(Wanted.clear(p, "product"), true)
		t.eq(Wanted.getStars(p), 0)
		t.eq(Wanted.clear(p, "product"), false)
		Wanted._removePlayer(p)
	end)

	t.test("dying while wanted is a bust (respawn at HQ), except inside your own garage", function()
		clock = 6500
		table.clear(fired)
		local p = fakePlayer("Resetter", 7)
		datas[p] = newData(1000, true)
		Wanted._addPlayer(p)
		p._attrs.PlotIndex = 1
		t.eq(Wanted._onDied(p, Vector3.new(0, 5, 0)), false, "not wanted: nothing happens")
		t.eq(Wanted.consumeRespawnAtHQ(p), false)
		Wanted.addHeat(p, 3, "dealerSteal")
		-- dying inside your own garage gains nothing: no bust
		local interior = MapLayout.plotInteriorZone(1)
		t.eq(MapLayout.plotAt(interior.Position), 1, "fixture: point is inside plot 1")
		t.eq(Wanted._onDied(p, interior.Position), false, "own garage is a safe house")
		t.eq(Wanted.getStars(p), 3)
		-- anywhere else: busted
		local street = Vector3.new(MapConfig.GRID_SPACING, MapConfig.ROAD_Y, 7)
		t.eq(Wanted._onDied(p, street), true)
		t.eq(Wanted.getStars(p), 0)
		t.eq(datas[p].cash, 900, "normal bust penalty")
		t.eq(countFired("Busted"), 1)
		t.ok(p._attrs.Stunned ~= true, "no stun on a dead body")
		t.eq(Wanted.consumeRespawnAtHQ(p), true, "next spawn goes to Police HQ")
		t.eq(Wanted.consumeRespawnAtHQ(p), false, "only once")
		-- a stale flag (no respawn for a long time) expires
		clock += 9
		Wanted.addHeat(p, 1, "carjack")
		t.eq(Wanted._onDied(p, street), true)
		clock += 120
		t.eq(Wanted.consumeRespawnAtHQ(p), false, "expired")
		Wanted._removePlayer(p)
	end)

	t.test("WantedDecayAt: server time of the next star loss while hidden, 0 while seen", function()
		clock = 6800
		local serverOffset = 50000
		Wanted._setHooks({
			serverNow = function()
				return clock + serverOffset
			end,
		})
		local p = fakePlayer("Hider", 8)
		datas[p] = newData(1000, true)
		Wanted._addPlayer(p)
		t.eq(p._attrs.WantedDecayAt, 0)
		Wanted.addHeat(p, 2, "carjack")
		seenMap[p] = true
		Wanted._decayPass()
		t.eq(p._attrs.WantedDecayAt, 0, "seen: no countdown")
		seenMap[p] = false
		clock += 0.25
		Wanted._decayPass()
		local at = p._attrs.WantedDecayAt
		t.near(at, clock + serverOffset + PoliceConfig.DECAY_DELAY[2] - 0.25, 0.3, "countdown to the next star")
		clock += 0.25
		Wanted._decayPass()
		t.eq(p._attrs.WantedDecayAt, at, "not rewritten while it holds")
		Wanted.clear(p, "admin")
		t.eq(p._attrs.WantedDecayAt, 0)
		seenMap[p] = nil
		Wanted._removePlayer(p)
	end)

	t.test("SprayCost attribute: current Spray Shop price while wanted, 0 when clean", function()
		clock = 6900
		local p = fakePlayer("Pricey", 10)
		datas[p] = newData(1000, true)
		Wanted._addPlayer(p)
		t.eq(p._attrs.SprayCost, 0)
		Wanted.addHeat(p, 2, "carjack")
		seenMap[p] = true
		clock += 0.25
		Wanted._decayPass()
		t.eq(p._attrs.SprayCost, Wanted._sprayCost(2, 10), "2 stars at the mocked income")
		Wanted.addHeat(p, 1, "carjack")
		clock += 0.25
		Wanted._decayPass()
		t.eq(p._attrs.SprayCost, Wanted._sprayCost(3, 10), "refreshed at once when the stars change")
		Wanted.clear(p, "admin")
		t.eq(p._attrs.SprayCost, 0, "clean")
		seenMap[p] = nil
		Wanted._removePlayer(p)
	end)

	t.test("spray price scales with income: stars * max(min, income * SPRAY_INCOME_SECONDS)", function()
		t.eq(Wanted._sprayCost(0, 1000), 0)
		t.eq(Wanted._sprayCost(1, 0), Economy.SPRAY_COST_PER_STAR, "floor for new players")
		t.eq(Wanted._sprayCost(3, 1), 3 * Economy.SPRAY_COST_PER_STAR)
		t.eq(Wanted._sprayCost(2, 900), 2 * 900 * Economy.SPRAY_INCOME_SECONDS, "mid game: seconds of income")
		t.eq(Wanted._sprayCost(1, 0 / 0), Economy.SPRAY_COST_PER_STAR, "NaN income is ignored")
	end)

	t.test("spray: pay per star, clear, repaint + repair; broke players are told", function()
		clock = 7000
		table.clear(fired)
		local p = fakePlayer("Painter", 5)
		datas[p] = newData(100, true)
		Wanted._addPlayer(p)
		Wanted.addHeat(p, 2, "carjack")
		local Instance = H.roblox.Instance
		local model = Instance.new("Model")
		local body = Instance.new("Part")
		body:SetAttribute("Paint", "primary")
		body.Color = H.roblox.Color3.new(0, 0, 0)
		body.Parent = model
		local trim = Instance.new("Part")
		trim:SetAttribute("Paint", "accent")
		trim.Color = H.roblox.Color3.new(0, 0, 0)
		trim.Parent = model
		local chassis = Instance.new("Part")
		chassis.Parent = model
		local car = { model = model, chassis = chassis, health = 20 }
		-- can't afford 2 * 250
		local handler = nil
		-- reach the private handler through init(): VehicleService mock exposes SprayAttempt
		local Signal = H.require("src/shared/Util/Signal")
		mocks.VehicleService.SprayAttempt = Signal.new()
		Wanted.init()
		handler = mocks.VehicleService.SprayAttempt
		handler:Fire(p, car)
		t.eq(Wanted.getStars(p), 2, "not enough cash")
		t.eq(countFired("Notify"), 2, "wanted hint + can't-afford notice") -- first-wanted hint + error
		datas[p].cash = 10000
		clock += 5
		handler:Fire(p, car)
		t.eq(Wanted.getStars(p), 0, "cleared")
		t.eq(datas[p].cash, 10000 - 2 * Economy.SPRAY_COST_PER_STAR)
		t.ok(body.Color ~= H.roblox.Color3.new(0, 0, 0), "primary repainted")
		t.ok(trim.Color == H.roblox.Color3.new(0, 0, 0), "accent untouched")
		t.eq(car.health, 100)
		t.eq(model:GetAttribute("Health"), 100)
		local escaped = false
		for _, c in progressCalls do
			if c[1] == p and c[2] == "escape" then
				escaped = true
			end
		end
		t.ok(escaped, "spray counts as an escape")
		mocks.VehicleService.SprayAttempt = nil
		Wanted._removePlayer(p)
	end)

	t.test("spray: refused while a cop sees you, then sprays in the booth once they lose you", function()
		clock = 8000
		table.clear(fired)
		local p = fakePlayer("Booth", 9)
		datas[p] = newData(100000, true)
		Wanted._addPlayer(p)
		Wanted.addHeat(p, 2, "carjack")
		local Instance = H.roblox.Instance
		local model = Instance.new("Model")
		local chassis = Instance.new("Part")
		chassis.Parent = model
		local zone = MapLayout.sprayZones()[1]
		chassis.CFrame = zone.cframe
		local car = { model = model, chassis = chassis, health = 50 }
		driving[p] = car
		local Signal = H.require("src/shared/Util/Signal")
		mocks.VehicleService.SprayAttempt = Signal.new()
		Wanted.init()
		local spray = mocks.VehicleService.SprayAttempt
		seenMap[p] = true
		spray:Fire(p, car)
		t.eq(Wanted.getStars(p), 2, "seen: no paint job")
		t.eq(datas[p].cash, 100000, "not charged")
		clock += 0.25
		Wanted._decayPass()
		t.eq(Wanted.getStars(p), 2, "still seen: still waiting")
		seenMap[p] = false
		clock += 0.25
		Wanted._decayPass()
		t.eq(Wanted.getStars(p), 0, "sprayed as soon as nobody sees the car")
		t.eq(datas[p].cash, 100000 - Wanted._sprayCost(2, 10))
		-- leaving the booth drops the pending spray
		clock += 10
		Wanted.addHeat(p, 1, "carjack")
		seenMap[p] = true
		spray:Fire(p, car)
		chassis.CFrame = zone.cframe * CFrame.new(0, 0, 200)
		seenMap[p] = false
		clock += 0.25
		Wanted._decayPass()
		t.eq(Wanted.getStars(p), 1, "left the booth: no spray")
		chassis.CFrame = zone.cframe
		clock += 0.25
		Wanted._decayPass()
		t.eq(Wanted.getStars(p), 1, "pending spray was dropped; needs a new entry")
		mocks.VehicleService.SprayAttempt = nil
		driving[p] = nil
		seenMap[p] = nil
		Wanted._removePlayer(p)
	end)
end
