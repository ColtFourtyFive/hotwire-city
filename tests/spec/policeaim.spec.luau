--!nocheck
-- Combat v2 police fairness (gta_combat §9) and aim assist (§11.2): PoliceAim hit chance / lethal rules / director /
-- vision cones / evade timer, PoliceCombatService pure helpers, AimAssist lock / friction / magnetism.
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local Police = H.require("src/shared/Config/Police")
	local PoliceAim = H.require("src/shared/Combat/PoliceAim")
	local AimAssist = H.require("src/shared/Combat/AimAssist")
	local PCS = H.require("src/server/Systems/PoliceCombatService")

	t.test("per-star table: 5 stars, accuracy and DPS budget never decrease", function()
		t.eq(#Police.Combat, 5)
		for s = 2, 5 do
			t.ok(Police.Combat[s].accuracy >= Police.Combat[s - 1].accuracy, "accuracy " .. s)
			t.ok(Police.Combat[s].dpsBudget >= Police.Combat[s - 1].dpsBudget, "budget " .. s)
		end
		t.eq(Police.Combat[1].dpsBudget, 0, "1 star never shoots")
	end)

	t.test("hit chance: distance, motion, cover, cars and mercy all lower it", function()
		local base = PoliceAim.hitChance(3, 20, 0, 1, false, false)
		t.near(base, PoliceAim.starCombat(3).accuracy, 1e-9)
		t.ok(PoliceAim.hitChance(3, 150, 0, 1, false, false) < base, "far")
		t.ok(PoliceAim.hitChance(3, 20, 25, 1, false, false) < base, "sprinting")
		t.ok(PoliceAim.hitChance(3, 20, 0, 0.33, false, false) < base, "cover")
		t.ok(PoliceAim.hitChance(3, 20, 0, 1, true, false) < base, "in a car")
		t.ok(PoliceAim.hitChance(3, 20, 0, 1, false, true) < base, "mercy")
		t.eq(PoliceAim.hitChance(3, 20, 0, 0, false, false), 0, "fully covered")
		t.eq(PoliceAim.fDist(1000), 0.25, "distance floor")
	end)

	t.test("lethal force rules per star", function()
		t.ok(not PoliceAim.lethal(1, true, false, 0), "1 star: never")
		t.ok(not PoliceAim.lethal(2, false, false, 0), "2 stars: unarmed suspect is safe")
		t.ok(PoliceAim.lethal(2, true, false, 0), "2 stars: armed suspect")
		t.ok(not PoliceAim.lethal(2, true, true, Police.NO_FIRE_SPEED + 5), "2 stars: no shooting at fast cars")
		t.ok(PoliceAim.lethal(3, false, true, 80), "3 stars: always")
		t.ok(not PoliceAim.lethal(0, true, false, 0))
		t.ok(not PoliceAim.mayFire({ protected = true, lethal = true }), "protected targets")
		t.ok(not PoliceAim.mayFire({ recentlySpawned = true, lethal = true }), "fresh spawns")
		t.ok(PoliceAim.mayFire({ lethal = true }))
	end)

	t.test("warning shots, reaction delay, car-body share", function()
		t.ok(PoliceAim.isWarningShot(0))
		t.ok(not PoliceAim.isWarningShot(Police.WARNING_SHOTS))
		local r = PoliceAim.starCombat(4).reaction
		t.near(PoliceAim.reactionDelay(4, 0), r[1], 1e-9)
		t.near(PoliceAim.reactionDelay(4, 1), r[2], 1e-9)
		t.ok(PoliceAim.hitsCarBody(0.1))
		t.ok(not PoliceAim.hitsCarBody(0.9))
	end)

	t.test("firing director: 10 officers never exceed the star's DPS budget", function()
		for stars = 1, 5 do
			local budget = PoliceAim.starCombat(stars).dpsBudget
			local avg = PCS._avgShotDamage(stars)
			local d = PoliceAim.newDirector(budget, avg, 0)
			local granted = 0
			local duration = 60
			local steps = duration * 20
			for i = 1, steps do
				local now = i / 20
				for _ = 1, 10 do -- ten officers ask every tick
					if PoliceAim.request(d, now) then
						granted += 1
					end
				end
			end
			local dealt = granted * avg
			local allowed = budget * duration + avg * d.cap
			t.ok(dealt <= allowed + 1e-6, ("%d stars: %.1f dmg <= %.1f"):format(stars, dealt, allowed))
			if budget == 0 then
				t.eq(granted, 0, "no budget, no shots")
			end
		end
	end)

	t.test("director re-tunes on a star change and never banks more than its cap", function()
		local d = PoliceAim.newDirector(8, 10, 0)
		t.ok(PoliceAim.request(d, 0))
		PoliceAim.setBudget(d, 28, 10)
		t.ok(d.rate > 0.8 * 2.8 and d.cap >= 1)
		PoliceAim.request(d, 1000)
		t.ok(d.tokens <= d.cap)
	end)

	t.test("vision cones, search radius, evade timer, search points", function()
		local cone = { fov = 90, range = 100, near = 10 }
		local o = V3.new(0, 0, 0)
		local look = V3.new(0, 0, -1)
		t.ok(PoliceAim.inCone(o, look, cone, V3.new(0, 0, -50)), "ahead")
		t.ok(not PoliceAim.inCone(o, look, cone, V3.new(0, 0, 50)), "behind")
		t.ok(PoliceAim.inCone(o, look, cone, V3.new(0, 0, 5)), "too close to miss")
		t.ok(not PoliceAim.inCone(o, look, cone, V3.new(0, 0, -150)), "out of range")
		t.ok(PoliceAim.inCone(o, look, { fov = 360, range = 100 }, V3.new(50, 0, 50)), "heli sees all around")
		for s = 2, 5 do
			t.ok(PoliceAim.searchRadius(s) >= PoliceAim.searchRadius(s - 1), "radius grows " .. s)
		end
		t.eq(PoliceAim.evadeStep(5, 20, 1, true, true), 20, "seen resets")
		t.eq(PoliceAim.evadeStep(5, 20, 1, false, true), 4, "inside: 1x")
		t.eq(PoliceAim.evadeStep(5, 20, 1, false, false), 5 - Police.EVADE_OUTSIDE_MULT, "outside: faster")
		local c = V3.new(100, 0, 100)
		for i = 1, 50 do
			local p = PoliceAim.searchPoint(c, 120, (i % 7) / 7, (i % 11) / 11)
			t.ok((p - c).Magnitude <= 120 + 1e-6, "inside the circle")
		end
	end)

	t.test("PoliceCombatService helpers", function()
		t.near(PCS._segmentDistance(V3.new(0, 5, 0), V3.new(-10, 0, 0), V3.new(10, 0, 0)), 5, 1e-9)
		t.near(PCS._segmentDistance(V3.new(20, 0, 0), V3.new(-10, 0, 0), V3.new(10, 0, 0)), 10, 1e-9, "past the end")
		t.near(PCS._segmentDistance(V3.new(1, 0, 0), V3.new(0, 0, 0), V3.new(0, 0, 0)), 1, 1e-9, "degenerate")
		t.eq(PCS._hitPart(0.1), "UpperTorso")
		t.eq(PCS._hitPart(0.7), "LeftUpperArm")
		t.eq(PCS._hitPart(0.95), "Head")
		local target = V3.new(0, 0, 0)
		for i = 0, 10 do
			local m = PCS._missPoint(target, i / 10, (i * 3 % 10) / 10, (i * 7 % 10) / 10)
			local flat = V3.new(m.X, 0, m.Z).Magnitude
			t.ok(flat >= 2 - 1e-9 and flat <= 4 + 1e-9, "warning shots land 2-4 studs away")
		end
		for s = 1, 5 do
			t.ok(PCS._avgShotDamage(s) > 0, "avg shot " .. s)
		end
	end)

	-- aim assist ----------------------------------------------------------------------------------------------------
	local function cand(key, angle, dist, extra)
		local c =
			{ key = key, angle = angle, distance = dist, visible = true, threat = false, isPlayer = false, side = 1 }
		for k, v in extra or {} do
			c[k] = v
		end
		return c
	end

	t.test("AimAssist.pickLock: NPCs only, visible, inside 22 deg / 150 studs; Full mode only", function()
		local list = {
			cand("far", 5, 140),
			cand("near", 6, 20),
			cand("player", 1, 10, { isPlayer = true }),
			cand("hidden", 1, 10, { visible = false }),
			cand("wide", 30, 10),
		}
		t.eq(AimAssist.pickLock(list, "Full"), "near")
		t.eq(AimAssist.pickLock(list, "Light"), nil)
		t.eq(AimAssist.pickLock({ cand("p", 1, 10, { isPlayer = true }) }, "Full"), nil, "players are never locked")
		local threat = { cand("calm", 4, 30), cand("shooter", 8, 30, { threat = true }) }
		t.eq(AimAssist.pickLock(threat, "Full"), "shooter", "threats first")
	end)

	t.test("AimAssist: switching, lock break, friction, magnetism, flick", function()
		local list = { cand("a", 2, 30, { side = 1 }), cand("b", 9, 30, { side = 1 }), cand("c", 4, 30, { side = -1 }) }
		t.eq(AimAssist.switchLock(list, "a", 1), "b")
		t.eq(AimAssist.switchLock(list, "a", -1), "c")
		t.ok(not AimAssist.lockExpired(0, 2))
		t.ok(AimAssist.lockExpired(0, AimAssist.LOCK_BREAK))
		t.eq(AimAssist.friction(1, "Full"), AimAssist.FRICTION_MULT)
		t.eq(AimAssist.friction(1, "Off"), 1)
		t.eq(AimAssist.friction(10, "Full"), 1)
		t.ok(AimAssist.magnetism(3, 1 / 60, "Full") > 0)
		t.eq(AimAssist.magnetism(3, 1 / 60, "Light"), 0, "light = friction only")
		t.eq(AimAssist.magnetism(20, 1 / 60, "Full"), 0)
		t.eq(AimAssist.flick(20), 1)
		t.eq(AimAssist.flick(-20), -1)
		t.eq(AimAssist.flick(2), 0)
	end)
end
