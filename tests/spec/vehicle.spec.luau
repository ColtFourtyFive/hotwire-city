--!nocheck
-- Vehicle physics: pure math of Shared/Vehicle/VehicleController (VehicleController.math) + controller construction.
return function(t)
	local H = t.H
	local VC = H.require("src/shared/Vehicle/VehicleController")
	local Tuning = H.require("src/shared/Config/Vehicle")
	local Cars = H.require("src/shared/Config/Cars")
	local Economy = H.require("src/shared/Config/Economy")
	local M = VC.math
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local Instance = H.roblox.Instance
	local G = 196.2

	-- Vertical-only simulation of a car on flat ground: zero-order-hold forces per frame (like VectorForce updated in
	-- PreSimulation), integrated at 240 Hz inside the frame (like the physics solver). Returns final y, vy, max |y|.
	local function simulateVertical(frameDt: number, seconds: number, y0: number, wheelRadius: number)
		local sc = M.staticCompression(G, Tuning.SPRING_K, Tuning.DOWNFORCE_BASE_G)
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
				a += 4 * M.suspensionAccel(comp, -vy, Tuning.SPRING_K, Tuning.SPRING_C, maxA)
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

	t.test("new() creates the movers, destroy() removes them", function()
		local model, chassis = fakeCar(true)
		local c = VC.new(model, Cars.get("rustbucket"), { isServer = true, nitroSeconds = 3.5 })
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
			local c = VC.new(model, def, { isServer = true })
			t.ok(chassis:FindFirstChild("WheelFL_Fallback") == nil, def.id .. " no fallback attachments")
			c:destroy()
			model:Destroy()
		end
	end)

	t.test("foreign movers are suppressed and restored", function()
		local model, chassis = fakeCar(true)
		local a = VC.new(model, Cars.get("rustbucket"), { isServer = true })
		local foreignDrive = chassis:FindFirstChild("Drive")
		local b = VC.new(model, Cars.get("rustbucket"), { isServer = false })
		t.eq(foreignDrive.Enabled, false, "other controller's drive disabled locally")
		b:destroy()
		t.eq(foreignDrive.Enabled, true, "restored")
		a:destroy()
		model:Destroy()
	end)
end
