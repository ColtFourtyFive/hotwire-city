--!nocheck
-- Vehicle physics: pure math of Shared/Vehicle/VehicleController (VehicleController.math) + controller construction.
return function(t)
	local H = t.H
	local VC = H.require("src/shared/Vehicle/VehicleController")
	local Tuning = H.require("src/shared/Config/Vehicle")
	local Cars = H.require("src/shared/Config/Cars")
	local Economy = H.require("src/shared/Config/Economy")
	local Map = H.require("src/shared/Config/Map")
	local M = VC.math
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local Instance = H.roblox.Instance
	local G = 196.2

	-- Vertical-only simulation of a car on flat ground: zero-order-hold forces per frame (like VectorForce updated in
	-- PreSimulation), integrated at 240 Hz inside the frame (like the physics solver). Returns final y, vy, max |y|.
	-- lowFps = true evaluates the spring like the controller does (softened above VC.SPRING_HOLD_DT, F13).
	local function simulateVertical(frameDt: number, seconds: number, y0: number, wheelRadius: number, lowFps: boolean?)
		local sc = M.staticCompression(G, Tuning.SPRING_K, Tuning.DOWNFORCE_BASE_G)
		local s = if lowFps then M.lowFpsScale(frameDt, VC.SPRING_HOLD_DT) else 1
		local mount = M.mountOffset(Tuning.SUSPENSION_REST, sc, VC.RIDE_LIFT)
		local L = M.rayLength(Tuning.SUSPENSION_REST, wheelRadius)
		local y, vy = y0, 0
		local maxAbs = 0
		local maxA = Tuning.MAX_SUSPENSION_ACCEL_G * G
		local frames = math.floor(seconds / frameDt)
		for _ = 1, frames do
			-- controller step: ray from hub + up*mount hits flat ground at d = r + y + mount
			local d = wheelRadius + y + mount
			local a = -G
			if d <= L then
				local comp = L - d
				a += 4 * M.suspensionAccel(comp, -vy, Tuning.SPRING_K, Tuning.SPRING_C, maxA, sc, s)
				a -= M.downforce(G, 0)
			end
			local substeps = math.max(1, math.floor(frameDt * 240 + 0.5))
			local h = frameDt / substeps
			for _ = 1, substeps do
				vy += a * h
				y += vy * h
			end
			maxAbs = math.max(maxAbs, math.abs(y))
		end
		return y, vy, maxAbs
	end

	t.test("static compression + mount offset reproduce the built pose (+ lift)", function()
		local sc = M.staticCompression(G, Tuning.SPRING_K, Tuning.DOWNFORCE_BASE_G)
		t.near(sc, G * (1 + Tuning.DOWNFORCE_BASE_G) / (4 * Tuning.SPRING_K), 1e-9, "sc formula")
		t.ok(sc > 0.3 and sc < Tuning.SUSPENSION_REST, "static compression within travel: " .. sc)
		local mount = M.mountOffset(Tuning.SUSPENSION_REST, sc, VC.RIDE_LIFT)
		t.ok(mount > 0, "mount must be above the hub: " .. mount)
		-- analytic equilibrium: comp(y) = rest - mount - y == sc  =>  y == lift
		for _, r in { 0.8, 1.2, 2.5 } do
			local L = M.rayLength(Tuning.SUSPENSION_REST, r)
			local dEq = r + VC.RIDE_LIFT + mount
			t.near(L - dEq, sc, 1e-9, "equilibrium compression r=" .. r)
			-- visual wheel offset at equilibrium puts the wheel bottom exactly on the ground
			local off = M.wheelVisualOffset(dEq, mount, Tuning.SUSPENSION_REST, r)
			-- wheel center height = hub height (r + lift) + off  should equal r
			t.near(r + VC.RIDE_LIFT + off, r, 1e-9, "wheel touches ground r=" .. r)
		end
	end)

	t.test("suspension settles at built pose + lift and is stable at 60 and 30 FPS", function()
		for _, frameDt in { 1 / 60, Tuning.MAX_DT } do
			for _, y0 in { 0.3, 1.5, -0.4 } do
				local y, vy, maxAbs = simulateVertical(frameDt, 4, y0, 1.2)
				t.near(y, VC.RIDE_LIFT, 0.02, ("settle y (dt=%.4f y0=%.1f)"):format(frameDt, y0))
				t.ok(math.abs(vy) < 0.05, "settled velocity " .. vy)
				t.ok(maxAbs < 4, "bounded motion " .. maxAbs)
			end
		end
	end)

	t.test("suspension accel clamps", function()
		t.eq(M.suspensionAccel(0, 5, 68, 4.2, 100), 0, "no comp -> no force")
		t.eq(M.suspensionAccel(0.5, -100, 68, 4.2, 100), 0, "never pulls")
		t.eq(M.suspensionAccel(5, 100, 68, 4.2, 100), 100, "max clamp")
	end)

	t.test("drive accel reaches but does not exceed top speed", function()
		local def = Cars.get("rustbucket")
		local v = 0
		local dt = 1 / 60
		local tTo90 = nil
		for i = 1, 60 * 20 do
			v += (M.driveAccel(1, v, def.topSpeed, def.accel, dt) + M.airDrag(v)) * dt
			if not tTo90 and v >= def.topSpeed * 0.9 then
				tTo90 = i * dt
			end
		end
		t.ok(v > def.topSpeed * 0.9 and v <= def.topSpeed, "top speed approached: " .. v)
		t.ok(tTo90 and tTo90 < 6, "reaches 90% quickly: " .. tostring(tTo90))
	end)

	t.test("braking stops without reversing; reverse is capped", function()
		local dt = 1 / 60
		local v = 50
		local steps = 0
		while v > 0 and steps < 1000 do
			v += M.driveAccel(-1, v, 100, 50, dt) * dt
			steps += 1
			t.ok(v >= -2.0001, "brake must not flip direction in one step: " .. v)
		end
		t.ok(steps < 60, "brakes from 50 within a second, took " .. steps)
		for _ = 1, 60 * 15 do
			v += M.driveAccel(-1, v, 100, 50, dt) * dt
		end
		t.ok(v < 0 and v >= -Tuning.REVERSE_MAX_SPEED, "reverse capped: " .. v)
		-- throttle forward while rolling backwards = brake (positive accel)
		t.ok(M.driveAccel(1, -20, 100, 50, dt) > 0, "forward throttle brakes backward motion")
		-- above top speed (nitro ended / downhill) the soft limiter pulls back
		t.ok(M.driveAccel(1, 130, 100, 50, dt) < 0, "soft limiter above vMax")
	end)

	t.test("coasting slows down and parks", function()
		local dt = 1 / 60
		local v = 30
		for _ = 1, 60 * 10 do
			v += M.driveAccel(0, v, 100, 50, dt) * dt
		end
		t.ok(math.abs(v) < 0.05, "parked: " .. v)
		t.ok(M.driveAccel(0, 1, 100, 50, dt) < 0, "hold opposes creep")
		t.ok(M.driveAccel(0, -1, 100, 50, dt) > 0, "hold opposes creep backwards")
	end)

	t.test("lateral grip never overshoots and respects max", function()
		local dt = 1 / 60
		t.ok(M.lateralAccel(10, 10, 235, dt) < 0, "pushes against slide")
		t.near(M.lateralAccel(0.01, 1000, 235, dt), -0.01 / dt, 1e-6, "capped to zero sideways speed")
		t.eq(M.lateralAccel(-500, 10, 235, dt), 235, "max lateral")
	end)

	t.test("target yaw sign convention", function()
		t.ok(M.targetYaw(1, 50, 100) < 0, "steer right forward = negative yaw")
		t.ok(M.targetYaw(-1, 50, 100) > 0, "steer left forward = positive yaw")
		t.ok(M.targetYaw(1, -20, 100) > 0, "reversing flips")
		t.eq(M.targetYaw(1, 0, 100), 0, "no yaw at standstill")
		t.ok(math.abs(M.targetYaw(1, 50, 100, true)) > math.abs(M.targetYaw(1, 50, 100)), "drift turns harder")
		-- high speed falloff
		local slow = math.abs(M.targetYaw(1, 20, 100))
		local fast = math.abs(M.targetYaw(1, 100, 100))
		t.ok(fast < slow, "less yaw at top speed")
		t.near(fast, Tuning.MAX_YAW_RATE * (1 - Tuning.HIGH_SPEED_STEER_FALLOFF), 1e-9, "falloff value")
		t.near(M.approachYaw(0, 2, Tuning.YAW_RESPONSE, 1 / 60), 2 * Tuning.YAW_RESPONSE / 60, 1e-9, "yaw response")
		t.eq(M.approachYaw(0, 2, 8, 1), 2, "response capped at 1")
	end)

	t.test("nitro tank drains, refills, drift charges faster", function()
		local n = 1
		local dt = 1 / 60
		local tank = 2.5
		local frames = 0
		while n > 0 and frames < 10000 do
			n = M.nitroStep(n, true, false, dt, tank, false)
			frames += 1
		end
		t.near(frames * dt, tank, 0.05, "drain time")
		local plain, drift = 0, 0
		for _ = 1, 60 do
			plain = M.nitroStep(plain, false, false, dt, tank, false)
			drift = M.nitroStep(drift, false, true, dt, tank, false)
		end
		t.near(plain, Tuning.NITRO_REFILL_PER_SEC, 1e-6, "refill per second")
		t.ok(drift > plain * 2, "drifting refills faster")
		t.eq(M.nitroStep(0.2, true, false, dt, tank, true), 1, "infinite nitro")
	end)

	t.test("grip factor: handbrake drop and recovery time", function()
		local f = M.gripFactorStep(1, true, 1 / 60)
		t.near(f, Tuning.HANDBRAKE_GRIP_RATE / Tuning.GRIP_RATE, 1e-9, "handbrake grip")
		local time = 0
		while f < 1 do
			f = M.gripFactorStep(f, false, 1 / 60)
			time += 1 / 60
		end
		t.near(time, Tuning.GRIP_RECOVER_TIME, 1 / 30, "recover time")
	end)

	t.test("top speed modifiers", function()
		t.eq(M.topSpeed(100, 1, false, false), 100)
		t.near(M.topSpeed(100, 1, true, false), 100 * Economy.SPIKES_SLOW, 1e-9, "spikes")
		t.near(M.topSpeed(100, 1, false, true), 100 * Tuning.NITRO_SPEED_MULT, 1e-9, "nitro")
		t.near(M.topSpeed(100, 1.5, false, false), 150, 1e-9, "multiplier")
	end)

	t.test("visual steer estimate + steerToward + mph", function()
		local maxA = math.rad(30)
		t.ok(M.estimateSteerAngle(1, 40, 8, maxA) > 0, "left yaw -> wheels left")
		t.ok(M.estimateSteerAngle(-1, 40, 8, maxA) < 0, "right yaw -> wheels right")
		t.eq(M.estimateSteerAngle(1, 0.2, 8, maxA), 0, "no estimate when stopped")
		t.near(M.estimateSteerAngle(50, 5, 8, maxA), maxA, 1e-9, "clamped")
		local cf = CFrame.new(0, 0, 0) -- facing -Z
		t.ok(M.steerToward(cf, Vector3.new(10, 0, -10)) > 0, "target right -> steer right")
		t.ok(M.steerToward(cf, Vector3.new(-10, 0, -10)) < 0, "target left -> steer left")
		t.near(M.steerToward(cf, Vector3.new(0, 0, -10)), 0, 1e-9, "straight ahead")
		t.eq(M.steerToward(cf, Vector3.new(0, 0, 10)), 1, "behind = full lock")
		t.near(M.mph(100), 68.18, 0.01, "mph")
	end)

	t.test("uprightCFrame flips an upside-down car keeping heading", function()
		local upsideDown = CFrame.new(5, 2, 5) * CFrame.Angles(0, math.rad(40), 0) * CFrame.Angles(0, 0, math.pi)
		local pos = Vector3.new(5, 5, 5)
		local out = M.uprightCFrame(upsideDown, pos)
		t.near(out.UpVector.Y, 1, 1e-6, "upright")
		t.near((out.Position - pos).Magnitude, 0, 1e-6, "position")
		local heading = CFrame.Angles(0, math.rad(40), 0).LookVector
		t.near(out.LookVector:Dot(heading), 1, 1e-6, "heading kept")
		-- nose straight down: still upright with a horizontal look
		local nose = CFrame.Angles(-math.pi / 2, 0, 0)
		local out2 = M.uprightCFrame(nose, pos)
		t.near(out2.UpVector.Y, 1, 1e-6, "upright from nose-down")
	end)

	t.test("WheelAnimator pose math: offset, steer and spin directions", function()
		local WA = H.require("src/client/Controllers/WheelAnimator")
		local base = Vector3.new(-2.8, -1, -4)
		local id = CFrame.new()
		local c0 = WA.wheelC0(base, id, id, 0.3, 0, 0)
		t.near((c0.Position - (base + Vector3.new(0, 0.3, 0))).Magnitude, 0, 1e-6, "offset along chassis up")
		local steered = WA.wheelC0(base, id, id, 0, 0.3, 0)
		t.ok(steered.LookVector.X < 0, "positive steer turns the wheel left")
		t.near((steered.Position - base).Magnitude, 0, 1e-6, "steer pivots in place")
		-- rolling forward: the top of the wheel must move toward -Z (the car's front) for either axle orientation
		for _, rot in { id, CFrame.Angles(0, math.pi, 0), CFrame.Angles(0, 0, math.pi) } do
			local sign = WA.spinSign(rot)
			local top0 = (WA.wheelC0(Vector3.zero, rot, id, 0, 0, 0) * rot:Inverse()).Position
			local rolled = WA.wheelC0(Vector3.zero, rot, id, 0, 0, 0.1 * sign)
			local topWorld = rolled * (rot:Inverse() * Vector3.new(0, 1, 0))
			t.near(top0.Magnitude, 0, 1e-9, "centered")
			t.ok(topWorld.Z < -0.05, "top of wheel rolls forward (rot " .. tostring(rot.RightVector) .. ")")
		end
		-- a non-identity C1 is honoured: Part1 = Part0 * C0 * C1:Inverse()
		local c1 = CFrame.new(0.2, 0, 0) * CFrame.Angles(0, 0, math.pi / 2)
		local wheelCF = CFrame.new(base) * CFrame.Angles(0, 0, math.pi / 2)
		local posed = WA.wheelC0(wheelCF.Position, wheelCF.Rotation, c1, 0.5, 0, 0) * c1:Inverse()
		t.near((posed.Position - (base + Vector3.new(0, 0.5, 0))).Magnitude, 0, 1e-6, "C1 honoured")
	end)

	-- Construction / destruction against the CarBuilder contract (no physics in Lune).
	local function fakeCar(withAttachments: boolean)
		local model = Instance.new("Model")
		model.Name = "TestCar"
		local chassis = Instance.new("Part")
		chassis.Name = "Chassis"
		chassis.Size = Vector3.new(6, 1.6, 12)
		chassis.Parent = model
		model.PrimaryPart = chassis
		model:SetAttribute("WheelRadius", 1.2)
		model:SetAttribute("RideHeight", 2.2)
		model:SetAttribute("Length", 13)
		model:SetAttribute("Width", 6.4)
		if withAttachments then
			for _, n in { "FL", "FR", "RL", "RR" } do
				local a = Instance.new("Attachment")
				a.Name = "Wheel" .. n
				a.Position =
					Vector3.new(if n:sub(2, 2) == "L" then -2.8 else 2.8, -1, if n:sub(1, 1) == "F" then -4 else 4)
				a.Parent = chassis
			end
		end
		model.Parent = H.workspace
		return model, chassis
	end

	t.test("client new() creates the VectorForce movers, destroy() removes them", function()
		local model, chassis = fakeCar(true)
		local c = VC.new(model, Cars.get("rustbucket"), { isServer = false, nitroSeconds = 3.5 })
		for _, n in { "FL", "FR", "RL", "RR" } do
			local f = chassis:FindFirstChild("Suspension_" .. n)
			t.ok(f and f:IsA("VectorForce"), "suspension " .. n)
			t.eq(f.Attachment0, chassis:FindFirstChild("Wheel" .. n), "attached to wheel " .. n)
			t.eq(f.ApplyAtCenterOfMass, false, "wheel force at the wheel")
			t.eq(f.RelativeTo, H.roblox.Enum.ActuatorRelativeTo.World, "world relative")
		end
		local drive = chassis:FindFirstChild("Drive")
		t.ok(drive and drive:IsA("VectorForce") and drive.ApplyAtCenterOfMass, "drive at COM")
		local upright = chassis:FindFirstChild("Upright")
		t.ok(upright and upright:IsA("AlignOrientation") and not upright.Enabled, "upright starts disabled")
		t.eq(c.nitro, 1, "full tank")
		t.eq(c.nitroSeconds, 3.5, "tank seconds from opts")
		c:setInput({ throttle = 5, steer = -3, handbrake = true, nitro = 1 })
		t.eq(c.input.throttle, 1, "throttle clamped")
		t.eq(c.input.steer, -1, "steer clamped")
		t.eq(c.input.handbrake, true)
		t.eq(c.input.nitro, false, "non-boolean nitro ignored")
		c:setInput({ throttle = 0 / 0, steer = 0, handbrake = false, nitro = false })
		t.eq(c.input.throttle, 0, "NaN throttle sanitized to 0")
		c:destroy()
		t.ok(chassis:FindFirstChild("Drive") == nil, "drive removed")
		t.ok(chassis:FindFirstChild("Upright") == nil, "upright removed")
		t.ok(chassis:FindFirstChild("Suspension_FL") == nil, "suspension removed")
		t.ok(chassis:FindFirstChild("WheelFL") ~= nil, "CarBuilder attachments kept")
		c:step(1 / 60) -- no-op after destroy
		model:Destroy()
	end)

	-- PERF-01: a server write to VectorForce.Force replicates to every client every frame, so server controllers
	-- (police, settling cars) create no VectorForces and apply the same forces as impulses.
	t.test("server new() creates no VectorForces; impulses carry force * frame dt", function()
		local model, chassis = fakeCar(true)
		local c = VC.new(model, Cars.Police, { isServer = true })
		for _, d in chassis:GetDescendants() do
			t.ok(not d:IsA("VectorForce"), "no replicated VectorForce on the server: " .. d.Name)
		end
		t.ok(chassis:FindFirstChild("DriveAttachment") == nil, "no drive attachment")
		local upright = chassis:FindFirstChild("Upright")
		t.ok(
			upright and upright:IsA("AlignOrientation") and not upright.Enabled,
			"upright kept (toggled on change only)"
		)
		t.eq(c.drive, nil, "no drive mover")
		for _, w in c.wheels do
			t.eq(w.force, nil, "no wheel mover " .. w.name)
		end
		-- _applyServerImpulses: wheel impulses at the hubs, drive at the COM, buffers cleared for the next frame
		local calls = {}
		local recorder = {
			ApplyImpulseAtPosition = function(_, impulse, at)
				table.insert(calls, { "at", impulse, at })
			end,
			ApplyImpulse = function(_, impulse)
				table.insert(calls, { "com", impulse })
			end,
		}
		local realChassis = c.chassis
		c.chassis = recorder
		local hub = Vector3.new(2.8, -1, -4)
		c._wheelForce[2] = Vector3.new(0, 600, 0)
		c._wheelAt[2] = hub
		c._driveForce = Vector3.new(0, 0, -1200)
		c:_applyServerImpulses(1 / 30)
		c.chassis = realChassis
		t.eq(#calls, 2, "one wheel impulse + the drive impulse (zero forces skipped)")
		t.eq(calls[1][1], "at", "wheel impulse at a position")
		t.near((calls[1][2] - Vector3.new(0, 20, 0)).Magnitude, 0, 1e-4, "wheel impulse = force * dt")
		t.near((calls[1][3] - hub).Magnitude, 0, 1e-4, "applied at the hub")
		t.eq(calls[2][1], "com", "drive impulse at the COM")
		t.near((calls[2][2] - Vector3.new(0, 0, -40)).Magnitude, 0, 1e-4, "drive impulse = force * dt")
		t.eq(c._wheelForce[2], Vector3.zero, "wheel buffer cleared")
		t.eq(c._driveForce, Vector3.zero, "drive buffer cleared")
		c:destroy()
		t.ok(chassis:FindFirstChild("Upright") == nil, "upright removed")
		model:Destroy()
	end)

	-- F1: the balls ride below the curb, so they must not collide while a controller holds the car up.
	t.test("bump stops are non-collidable while a controller runs and restored on destroy", function()
		local model, chassis = fakeCar(true)
		local stops = {}
		for _, z in { -4, 4 } do
			local stop = Instance.new("Part")
			stop.Name = VC.BUMP_STOP_NAME
			stop.Size = Vector3.new(1, 1, 1)
			stop.CFrame = chassis.CFrame * CFrame.new(0, -1.75, z)
			stop.CanCollide = true
			stop.Parent = model
			table.insert(stops, stop)
		end
		local c = VC.new(model, Cars.get("rustbucket"), { isServer = false })
		for _, stop in stops do
			t.eq(stop.CanCollide, false, "bump stop off while driving")
		end
		-- something else (e.g. a replicated server change) turns one back on: the next attribute poll catches it
		stops[1].CanCollide = true
		c:_pollAttributes()
		t.eq(stops[1].CanCollide, false, "re-disabled on poll")
		c:destroy()
		for _, stop in stops do
			t.eq(stop.CanCollide, true, "bump stop restored")
		end
		-- a stop that was already non-collidable is left alone
		stops[2].CanCollide = false
		local c2 = VC.new(model, Cars.get("rustbucket"), { isServer = true })
		c2:destroy()
		t.eq(stops[1].CanCollide, true, "restored")
		t.eq(stops[2].CanCollide, false, "not ours: untouched")
		model:Destroy()
	end)

	t.test("new() falls back when wheel attachments are missing", function()
		local model, chassis = fakeCar(false)
		local c = VC.new(model, Cars.Police, { isServer = true })
		local fl = chassis:FindFirstChild("WheelFL_Fallback")
		t.ok(fl ~= nil, "fallback attachment created")
		t.ok(fl.Position.Z < 0 and fl.Position.X < 0, "FL is front-left")
		t.near(fl.Position.Y, 1.2 - 2.2, 1e-6, "hub height from RideHeight")
		c:destroy()
		t.ok(chassis:FindFirstChild("WheelFL_Fallback") == nil, "fallback removed")
		model:Destroy()
	end)

	t.test("every real CarBuilder car fits the controller contract", function()
		local ok, CarBuilder = pcall(H.require, "src/shared/Vehicle/CarBuilder")
		if not ok then
			return -- CarBuilder slice not present yet
		end
		local defs = table.clone(Cars.List)
		table.insert(defs, Cars.Police)
		for _, def in defs do
			local model = CarBuilder.buildDef(def, "None", {})
			local chassis = model.PrimaryPart
			t.ok(chassis and chassis.Name == "Chassis", def.id .. " chassis")
			local r = model:GetAttribute("WheelRadius")
			t.ok(typeof(r) == "number" and r > 0.3, def.id .. " WheelRadius")
			local chassisY = chassis.CFrame.Position.Y
			for _, n in { "FL", "FR", "RL", "RR" } do
				local att = chassis:FindFirstChild("Wheel" .. n)
				t.ok(att and att:IsA("Attachment"), def.id .. " attachment " .. n)
				-- hub sits one wheel radius above the ground plane in the built pose (mount math relies on it)
				t.near(chassisY + att.Position.Y, r, 0.02, def.id .. " hub height " .. n)
				local weld = chassis:FindFirstChild("WheelWeld_" .. n)
				t.ok(weld and weld:IsA("Weld"), def.id .. " weld " .. n)
				t.near((weld.C0.Position - att.Position).Magnitude, 0, 0.02, def.id .. " weld at hub " .. n)
			end
			-- chassis must clear the 0.6 curb at ride height or cars bump instead of climbing
			local bottom = chassisY - chassis.Size.Y / 2 + VC.RIDE_LIFT
			t.ok(bottom > 0.6, def.id .. " chassis bottom clears curbs: " .. bottom)
			-- the bump stops ride below the curb even with the lift: that's why a controller disables them (F1)
			local stops = {}
			for _, child in model:GetChildren() do
				if child.Name == VC.BUMP_STOP_NAME and child:IsA("BasePart") then
					table.insert(stops, child)
					local stopBottom = child.CFrame.Position.Y - child.Size.Y / 2 + VC.RIDE_LIFT
					t.ok(stopBottom < Map.CURB_HEIGHT, def.id .. " bump stop rides below the curb: " .. stopBottom)
				end
			end
			t.eq(#stops, 2, def.id .. " two bump stops")
			local c = VC.new(model, def, { isServer = true })
			t.ok(chassis:FindFirstChild("WheelFL_Fallback") == nil, def.id .. " no fallback attachments")
			for _, stop in stops do
				t.eq(stop.CanCollide, false, def.id .. " bump stop off under a controller")
			end
			c:destroy()
			for _, stop in stops do
				t.eq(stop.CanCollide, true, def.id .. " bump stop back on")
			end
			model:Destroy()
		end
	end)

	t.test("foreign movers are suppressed and restored", function()
		local model, chassis = fakeCar(true)
		local a = VC.new(model, Cars.get("rustbucket"), { isServer = false })
		local foreignDrive = chassis:FindFirstChild("Drive")
		local b = VC.new(model, Cars.get("rustbucket"), { isServer = false })
		t.eq(foreignDrive.Enabled, false, "other controller's drive disabled locally")
		b:destroy()
		t.eq(foreignDrive.Enabled, true, "restored")
		a:destroy()
		-- a server controller's Upright replicates to the driver: suppressed while it is enabled
		local server = VC.new(model, Cars.Police, { isServer = true })
		local serverUpright = chassis:FindFirstChild("Upright")
		serverUpright.Enabled = true
		local driver = VC.new(model, Cars.Police, { isServer = false })
		t.eq(serverUpright.Enabled, false, "server upright disabled in the driver's simulation")
		driver:destroy()
		t.eq(serverUpright.Enabled, true, "restored")
		server:destroy()
		model:Destroy()
	end)

	t.test("low FPS: the held spring is softened only below 15 FPS and then stays stable (F13)", function()
		t.eq(M.lowFpsScale(1 / 60, VC.SPRING_HOLD_DT), 1, "60 FPS untouched")
		t.eq(M.lowFpsScale(1 / 20, VC.SPRING_HOLD_DT), 1, "20 FPS untouched")
		t.eq(M.lowFpsScale(0 / 0, VC.SPRING_HOLD_DT), 1, "NaN frame time")
		t.near(M.lowFpsScale(1 / 5, 1 / 15), 1 / 3, 1e-9, "5 FPS scale")
		local sc = M.staticCompression(G, Tuning.SPRING_K, Tuning.DOWNFORCE_BASE_G)
		local maxA = Tuning.MAX_SUSPENSION_ACCEL_G * G
		t.near(
			M.suspensionAccel(sc, 0, Tuning.SPRING_K, Tuning.SPRING_C, maxA, sc, 0.3),
			Tuning.SPRING_K * sc,
			1e-9,
			"static load carried unchanged"
		)
		t.eq(
			M.suspensionAccel(0.5, 1, Tuning.SPRING_K, Tuning.SPRING_C, maxA, sc, 1),
			M.suspensionAccel(0.5, 1, Tuning.SPRING_K, Tuning.SPRING_C, maxA),
			"scale 1 = plain spring"
		)
		-- the plain held spring diverges at 8 FPS (the car hops, then launches) ...
		local _, _, plainMax = simulateVertical(1 / 8, 10, 0.3, 1.2)
		t.ok(plainMax > 4, "plain spring is unstable at 8 FPS: " .. plainMax)
		-- ... the softened one settles at the same ride height
		for _, frameDt in { 1 / 8, 1 / 6, 1 / 4 } do
			for _, y0 in { 0.3, -0.4 } do
				local y, vy, maxAbs = simulateVertical(frameDt, 12, y0, 1.2, true)
				t.near(y, VC.RIDE_LIFT, 0.02, ("low-FPS settle (dt=%.3f y0=%.1f)"):format(frameDt, y0))
				t.ok(math.abs(vy) < 0.05, "settled velocity " .. vy)
				t.ok(maxAbs < 1, "bounded motion " .. maxAbs)
			end
		end
		-- and nothing changes at 15+ FPS
		for _, frameDt in { 1 / 60, 1 / 30, 1 / 15 } do
			local y1 = simulateVertical(frameDt, 2, 0.6, 1.2)
			local y2 = simulateVertical(frameDt, 2, 0.6, 1.2, true)
			t.eq(y1, y2, "identical ride at dt=" .. frameDt)
		end
	end)

	t.test("drift test shared with observers", function()
		t.ok(M.isDrifting(40, 20, true), "fast + sliding + grounded")
		t.ok(not M.isDrifting(40, 20, false), "airborne")
		t.ok(not M.isDrifting(5, 20, true), "too slow forward")
		t.ok(not M.isDrifting(40, Tuning.DRIFT_SLIP_SPEED - 1, true), "below slip threshold")
		local WA = H.require("src/client/Controllers/WheelAnimator")
		local cf = CFrame.new() -- facing -Z, right = +X
		t.ok(WA.observedDrift(cf, Vector3.new(20, 0, -40)), "observer sees the slide")
		t.ok(not WA.observedDrift(cf, Vector3.new(2, 0, -40)), "straight line")
		t.ok(not WA.observedDrift(cf, Vector3.new(20, -30, -40)), "falling = airborne")
		t.ok(not WA.observedDrift(CFrame.Angles(0, 0, math.rad(80)), Vector3.new(20, 0, -40)), "on its side")
	end)

	t.test("WheelAnimator budget helpers (PERF-07, F10, PERF-13)", function()
		local WA = H.require("src/client/Controllers/WheelAnimator")
		t.ok(WA.isLowTier(true, false, false), "phone")
		t.ok(not WA.isLowTier(true, true, false), "touch laptop")
		t.ok(not WA.isLowTier(true, false, true), "tablet with mouse")
		t.ok(not WA.isLowTier(false, true, true), "desktop")
		local tier = WA.LOW_TIER
		t.ok(tier.HOT_COUNT < WA.HOT_COUNT and tier.RANGE < WA.RANGE and tier.BOB_RANGE < WA.BOB_RANGE, "smaller")
		local camPos, look = Vector3.zero, Vector3.new(0, 0, -1)
		t.ok(not WA.behindCamera(Vector3.new(0, 0, -50), camPos, look, 12), "ahead")
		t.ok(not WA.behindCamera(Vector3.new(40, 0, 5), camPos, look, 12), "beside, within the margin")
		t.ok(WA.behindCamera(Vector3.new(0, 0, 30), camPos, look, 12), "behind")
		t.ok(WA.enteredBobRange(math.huge, 100, 140), "first seen in range")
		t.ok(WA.enteredBobRange(200, 139, 140), "walked into range: re-pose the settled car")
		t.ok(not WA.enteredBobRange(100, 90, 140), "already in range")
		t.ok(not WA.enteredBobRange(200, 180, 140), "still far")
		local ok, CarBuilder = pcall(H.require, "src/shared/Vehicle/CarBuilder")
		if ok then
			t.eq(WA.SPARKLES_NAME, CarBuilder.SPARKLES_NAME, "sparkles emitter name matches CarBuilder")
		end
	end)

	t.test("VehicleClient: phone text boost (UI-PHONE-TEXT-TOO-SMALL)", function()
		H.setMode("client")
		local ok, VClient = pcall(H.require, "src/client/Controllers/VehicleClient")
		H.setMode("server")
		t.ok(ok, "VehicleClient loads headlessly: " .. tostring(VClient))
		t.eq(VClient.textBoost(false, 0.55, 0.72), 1, "no boost without touch")
		t.near(VClient.textBoost(true, 0.55, 0.72), 0.72 / 0.55, 1e-9, "phone at the 0.55 floor")
		t.eq(VClient.textBoost(true, 0.8, 0.72), 1, "tablet already large enough")
		t.eq(VClient.textBoost(true, 0.3, 0.72), 1.4, "capped")
		t.eq(VClient.textBoost(true, 0 / 0, 0.72), 1, "NaN scale")
	end)
end
