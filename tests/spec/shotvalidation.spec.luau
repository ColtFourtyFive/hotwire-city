--!nocheck
-- Combat v2 netcode (gta_combat §10): ShotValidation (packet shape, time machine / future shots, origin, angle,
-- pellets, facing, range, target tolerance, rate bucket, audit) and HitboxHistory's lag-compensation ring.
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local CF = H.roblox.CFrame
	local Weapons = H.require("src/shared/Config/Weapons")
	local Ballistics = H.require("src/shared/Combat/Ballistics")
	local SV = H.require("src/shared/Combat/ShotValidation")
	local HitboxHistory = H.require("src/server/Systems/HitboxHistory")

	local FWD = V3.new(0, 0, -1)
	local PART = { fake = "part" }
	local function isPart(p)
		return p == PART
	end
	local function shot(over)
		local s = { w = "pistol", t = 100, o = V3.new(0, 5, 0), d = FWD, s = 1234, a = false }
		for k, v in over or {} do
			s[k] = v
		end
		return s
	end

	t.test("parseShot accepts a well-formed shot", function()
		local s, why = SV.parseShot(shot({ h = { { p = PART, x = V3.new(0, 5, -20), k = 1 } } }), isPart)
		t.ok(s ~= nil, tostring(why))
		t.eq(#s.h, 1)
		t.eq(s.w, "pistol")
	end)

	t.test("parseShot rejects bad shapes", function()
		local bad = {
			"not a table",
			shot({ w = "fists" }), -- melee is not a gun
			shot({ w = "nope" }),
			shot({ w = string.rep("x", 40) }),
			shot({ t = 0 / 0 }),
			shot({ o = V3.new(1e9, 0, 0) }),
			shot({ d = V3.new(0, 0, -5) }), -- not unit
			shot({ s = 1.5 }),
			shot({ s = -1 }),
			shot({ h = "x" }),
			shot({ h = { { p = PART, x = V3.new(0, 0, -10), k = 2 } } }), -- pistol has 1 pellet
			shot({ h = { { p = "spoof", x = V3.new(0, 0, -10), k = 1 } } }),
			shot({ h = { { p = PART, x = V3.new(0, 0, -10), k = 1 }, { p = PART, x = V3.new(0, 0, -11), k = 1 } } }),
		}
		for i, raw in bad do
			local s, why = SV.parseShot(raw, isPart)
			t.eq(s, nil, "case " .. i)
			t.eq(why, "shape", "case " .. i)
		end
		-- the pump may claim up to its pellet count, each index once
		local hits = {}
		for k = 1, Weapons.pelletCount(Weapons.get("pump")) do
			table.insert(hits, { p = PART, x = V3.new(0, 5, -10), k = k })
		end
		t.ok(SV.parseShot(shot({ w = "pump", h = hits }), isPart) ~= nil, "full pump claim")
	end)

	t.test("packetSize: 1..4 shots", function()
		t.eq(SV.packetSize({}), nil)
		t.eq(SV.packetSize({ 1 }), 1)
		t.eq(SV.packetSize({ 1, 2, 3, 4 }), 4)
		t.eq(SV.packetSize({ 1, 2, 3, 4, 5 }), nil)
		t.eq(SV.packetSize("x"), nil)
	end)

	t.test("time: future shots and time-machine shots are rejected", function()
		t.ok(SV.checkTime(0.08, 0.1), "normal")
		t.ok(SV.checkTime(-0.02, 0.1), "tiny clock skew ok")
		local ok, why = SV.checkTime(-0.5, 0.1)
		t.ok(not ok)
		t.eq(why, "future")
		local ok2, why2 = SV.checkTime(2.0, 0.1)
		t.ok(not ok2)
		t.eq(why2, "stale", "time machine")
		local ok3 = SV.checkTime(0.34, 2)
		t.ok(ok3, "high ping allows up to MAX_REWIND")
		t.ok(not SV.checkTime(SV.MAX_REWIND + 0.01, 5), "never past MAX_REWIND")
	end)

	t.test("origin: muzzle near the rewound head, more slack while moving", function()
		local head = V3.new(0, 5, 0)
		t.ok(SV.checkOrigin(V3.new(2, 5, 0), head, 0, 0))
		t.ok(not SV.checkOrigin(V3.new(20, 5, 0), head, 0, 0.1), "bad origin")
		t.ok(SV.checkOrigin(V3.new(9, 5, 0), head, 40, 0.1), "sprinting slack")
	end)

	t.test("angle / pellets / facing / range", function()
		local pistol = Weapons.get("pistol")
		local o = V3.new(0, 0, 0)
		t.ok(SV.checkAngle(pistol, o, FWD, V3.new(0, 0, -50)))
		t.ok(not SV.checkAngle(pistol, o, FWD, V3.new(50, 0, -50)), "45 degrees off")
		local pump = Weapons.get("pump")
		local exp = SV.expectedPellets(pump, FWD, 777, false)
		t.eq(#exp, Weapons.pelletCount(pump))
		t.ok(SV.checkPellet(exp, 3, o, exp[3] * 20), "claimed pellet matches its regenerated direction")
		t.ok(not SV.checkPellet(exp, 3, o, V3.new(30, 0, -20)), "made-up pellet")
		t.ok(not SV.checkPellet(exp, 99, o, exp[1] * 20), "unknown pellet index")
		-- the server's regenerated pellets equal the client's Ballistics.pellets for the same seed
		local client = Ballistics.pellets(FWD, pump.spreadHip, 777, Weapons.pelletCount(pump))
		for i = 1, #exp do
			t.near((exp[i] - client[i]).Magnitude, 0, 1e-12, "pellet " .. i)
		end
		t.ok(SV.checkFacing(FWD, FWD))
		t.ok(not SV.checkFacing(V3.new(0, 0, 1), FWD), "shooting behind your back")
		t.ok(SV.checkFacing(V3.new(0, 1, 0), FWD), "straight up is fine")
		t.ok(SV.checkRange(pistol, o, V3.new(0, 0, -pistol.maxRange)))
		t.ok(not SV.checkRange(pistol, o, V3.new(0, 0, -pistol.maxRange - 5)))
	end)

	t.test("target: tolerance grows with speed, rewind and car occupancy", function()
		local still = SV.targetTolerance(0, 0, false)
		t.ok(SV.targetTolerance(60, 0.2, false) > still)
		t.ok(SV.targetTolerance(0, 0, true) > still)
		local part = V3.new(0, 5, -30)
		t.ok(SV.checkTarget(V3.new(0.5, 5, -30), part, 2, 0, 0, false))
		t.ok(not SV.checkTarget(V3.new(15, 5, -30), part, 2, 0, 0, false), "nowhere near the victim")
		t.near(SV.victimSampleTime(10, 0.2), 10 - (0.1 + SV.INTERP_DELAY), 1e-9)
	end)

	t.test("rate bucket: bursts capped, refill at the weapon's rpm", function()
		local pistol = Weapons.get("pistol")
		local b = SV.newBucket(pistol, 0)
		local granted = 0
		for _ = 1, 10 do
			if SV.take(b, 0) then
				granted += 1
			end
		end
		t.eq(granted, 3, "semi burst cap")
		local total = 0
		for i = 1, 600 do
			if SV.take(b, i / 60) then
				total += 1
			end
		end
		local maxShots = pistol.rpm / 60 * 1.1 * 10 + 1
		t.ok(total <= maxShots, ("10 s of spam: %d <= %.1f"):format(total, maxShots))
	end)

	t.test("audit: drops above 30, kicks above 80 in 2 min, state rejections are free", function()
		local a = SV.newAudit(0)
		t.eq(SV.addAudit(a, "state", 0), "ok")
		t.eq(a.score, 0, "state weighs nothing")
		local result = "ok"
		local n = 0
		while result == "ok" and n < 100 do
			n += 1
			result = SV.addAudit(a, "origin", n * 0.1)
		end
		t.eq(result, "drop", "drop first")
		t.ok(SV.isDropping(a, n * 0.1 + 1))
		while result ~= "kick" and n < 200 do
			n += 1
			result = SV.addAudit(a, "origin", n * 0.1)
		end
		t.eq(result, "kick")
		-- the score decays over time
		local b = SV.newAudit(0)
		SV.addAudit(b, "origin", 0)
		SV.decayAudit(b, 600)
		t.eq(b.score, 0)
	end)

	t.test("HitboxHistory ring: interpolates, clamps to newest / oldest, wraps", function()
		local ring = HitboxHistory._newRing(5)
		t.eq(HitboxHistory._sampleRing(ring, 1), nil, "empty")
		for i = 0, 9 do
			HitboxHistory._push(ring, i * 0.05, CF.new(i, 0, 0))
		end
		t.eq(ring.count, 5, "capped at size")
		t.near(HitboxHistory._sampleRing(ring, 99).Position.X, 9, 1e-9, "future -> newest")
		t.near(HitboxHistory._sampleRing(ring, 0.425).Position.X, 8.5, 1e-6, "lerp between samples")
		t.near(HitboxHistory._sampleRing(ring, 0).Position.X, 5, 1e-9, "older than the buffer -> oldest kept")
	end)
end
