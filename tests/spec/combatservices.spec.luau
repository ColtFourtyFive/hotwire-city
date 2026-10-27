--!nocheck
-- Combat v2 server services driven through their test seams with fake systems (review fix pass): WeaponService shot
-- pipeline (lag never scores, live-head origin gate, live facing), aim state vs holster, the aim pitch and distant
-- gunfire helpers; CombatService stun-lock immunity; DamageService death classification / hospital bill, passive vs
-- wanted, spawn-style protection, med kits, and garage defense vs Menace.
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local CF = H.roblox.CFrame
	local Weapons = H.require("src/shared/Config/Weapons")
	local ShotValidation = H.require("src/shared/Combat/ShotValidation")
	local DamageModel = H.require("src/shared/Combat/DamageModel")
	local Police = H.require("src/shared/Config/Police")
	local WeaponService = H.require("src/server/Systems/WeaponService")
	local CombatService = H.require("src/server/Systems/CombatService")
	local Damage = H.require("src/server/Systems/DamageService")

	-- FAKES ---------------------------------------------------------------------------------------------------------
	local function fake(name, class, props)
		local attrs = {}
		local children = {}
		local o = props or {}
		o.Name = name
		o.Parent = o.Parent or true
		o._class = class
		o._attrs = attrs
		o._children = children
		o.GetAttribute = function(_, k)
			return attrs[k]
		end
		o.SetAttribute = function(_, k, v)
			attrs[k] = v
		end
		o.FindFirstChild = function(_, n)
			return children[n]
		end
		o.FindFirstChildOfClass = function(_, cls)
			for _, c in children do
				if c._class == cls then
					return c
				end
			end
			return nil
		end
		o.IsA = function(_, cls)
			return class == cls or (cls == "BasePart" and class == "Part") or cls == "Instance"
		end
		return o
	end

	-- A character standing at `at`, facing -Z (or `look`).
	local function fakeCharacter(at, look)
		local cf = if look then CF.lookAt(at, at + look) else CF.new(at)
		local char = fake("Character", "Model")
		local hum = fake("Humanoid", "Humanoid", { Health = 100, SeatPart = nil })
		local root = fake("HumanoidRootPart", "Part", {
			Position = at,
			CFrame = cf,
			AssemblyLinearVelocity = V3.zero,
			Size = V3.new(2, 2, 1),
		})
		local head = fake("Head", "Part", { Position = at + V3.new(0, 1.5, 0), Size = V3.new(1, 1, 1) })
		char._children.Humanoid = hum
		char._children.HumanoidRootPart = root
		char._children.Head = head
		return char, hum, root, head
	end

	local nextId = 9000
	local function fakePlayer(name, at, look)
		nextId += 1
		local char = if at then fakeCharacter(at, look) else nil
		return fake(name, "Player", { UserId = nextId, DisplayName = name, Character = char })
	end

	-- WEAPONSERVICE -------------------------------------------------------------------------------------------------
	local fired = {}
	local crimes = {}
	local damageCalls = {}
	local datas = {}
	local wmocks = {
		DataService = {
			get = function(p)
				return datas[p]
			end,
		},
		DamageService = {
			canDraw = function()
				return true
			end,
			onFired = function() end,
			reportCrime = function(p, crime, pos)
				table.insert(crimes, { p = p, crime = crime, pos = pos })
			end,
			applyDamage = function(...)
				table.insert(damageCalls, { ... })
			end,
			applyNpcDamage = function(...)
				table.insert(damageCalls, { ... })
			end,
		},
		AdminService = { logAudit = function() end },
		VehicleService = {
			getDriving = function()
				return nil
			end,
		},
	}
	WeaponService._setHooks({
		system = function(name)
			return wmocks[name]
		end,
		fire = function(how, name, ...)
			table.insert(fired, { how = how, name = name, args = { ... } })
		end,
	})

	local function count(list, name)
		local n = 0
		for _, f in list do
			if f.name == name then
				n += 1
			end
		end
		return n
	end

	-- An armed shooter at the origin, P9 drawn long ago.
	local function armed(name, look)
		local p = fakePlayer(name, V3.new(0, 3, 0), look)
		datas[p] = { weapons = { pistol = { ammo = 36 } } }
		local inv = WeaponService._getInv(p)
		inv.loaded = true
		inv.ammo.pistol = { mag = 12, reserve = 24 }
		inv.equipped = "pistol"
		inv.equippedAt = -100
		return p, inv
	end

	-- A pistol shot from just in front of the face, straight down -Z, claiming a world hit 30 studs away.
	local function shotAt(tShot, origin, dir)
		local o = origin or V3.new(0, 4.5, -1)
		local d = dir or V3.new(0, 0, -1)
		return { w = "pistol", t = tShot, o = o, d = d, s = 7, a = true, h = { { x = o + d * 30, k = 1 } } }
	end

	t.test("WeaponService: a late shot (lag) drops its hits but never scores the audit", function()
		table.clear(fired)
		table.clear(crimes)
		local p, inv = armed("Laggy")
		local now, tNow = 10, 500
		-- two shots in one packet, both far past the rewind window (a server hitch / jitter)
		WeaponService._processShot(inv, shotAt(tNow - 1.0), now, tNow, 0.02)
		WeaponService._processShot(inv, shotAt(tNow - 1.2), now + 0.05, tNow, 0.02)
		t.eq(inv.audit.score, 0, "honest lag costs nothing")
		t.eq(inv.audit.reasons.stale, 2, "but it is counted for the admin log")
		t.eq(#damageCalls, 0, "no hits applied")
		t.eq(count(fired, "ShotFx"), 2, "the shots are still seen by others")
		t.eq(inv.ammo.pistol.mag, 10, "and still cost ammo")
		t.eq(#crimes, 2)
		t.ok((crimes[1].pos - V3.new(0, 3, 0)).Magnitude < 1e-6, "gunfire is reported where the shooter stands")
		WeaponService._removeInv(p)
	end)

	t.test("WeaponService: a muzzle far from the live head is never relayed and scores 'origin'", function()
		table.clear(fired)
		table.clear(crimes)
		local p, inv = armed("Teleporter")
		local tNow = 600
		WeaponService._processShot(inv, shotAt(tNow - 0.05, V3.new(300, 4.5, 300)), 10, tNow, 0.05)
		t.eq(count(fired, "ShotFx"), 0, "no tracer anywhere on the map")
		t.eq(#crimes, 0, "no gunfire crime moved across town")
		t.near(inv.audit.score, ShotValidation.WEIGHTS.origin, 0.01)
		t.eq(inv.ammo.pistol.mag, 11, "the round is spent anyway")
		WeaponService._removeInv(p)
	end)

	t.test("WeaponService: the live facing passes when the rewound one is behind the shot", function()
		table.clear(fired)
		local p, inv = armed("Turner")
		-- history says we still faced +Z when we fired down -Z (the turn replicated just after the click)
		wmocks.HitboxHistory = {
			samplePart = function(_char, part)
				return part.Position
			end,
			sample = function()
				return CF.lookAt(V3.new(0, 3, 0), V3.new(0, 3, 10))
			end,
		}
		local tNow = 700
		WeaponService._processShot(inv, shotAt(tNow - 0.05), 10, tNow, 0.05)
		t.eq(inv.audit.reasons.facing, nil, "accepted on the live look vector")
		t.eq(inv.audit.score, 0)
		wmocks.HitboxHistory = nil
		WeaponService._removeInv(p)
		-- a shot straight behind both the rewound and the live facing is refused (and still free: weight 0)
		local p2, inv2 = armed("Backwards")
		WeaponService._processShot(inv2, shotAt(tNow - 0.05, V3.new(0, 4.5, 1), V3.new(0, 0, 1)), 10, tNow, 0.05)
		t.eq(inv2.audit.reasons.facing, 1)
		t.eq(inv2.audit.score, 0)
		WeaponService._removeInv(p2)
	end)

	t.test("WeaponService: a packet scores at most PACKET_CAP however many shots fail", function()
		local p, inv = armed("Burst")
		ShotValidation.beginPacket(inv.audit)
		for i = 1, 4 do
			WeaponService._processShot(inv, shotAt(800, V3.new(200, 4.5, 0)), 10 + i * 0.01, 800, 0.05)
		end
		t.near(inv.audit.score, ShotValidation.PACKET_CAP, 0.01, "one origin weight, not four") -- decays in real time
		WeaponService._removeInv(p)
	end)

	t.test("WeaponService: holstering (or swapping to melee) clears Aiming and the aim pitch", function()
		local p = fakePlayer("Aimer", V3.new(0, 3, 0))
		local inv = WeaponService._getInv(p)
		inv.ammo.pistol = { mag = 12, reserve = 0 }
		inv.ammo.bat = { mag = 0, reserve = 0 }
		WeaponService._setEquipped(inv, "pistol")
		WeaponService._onAim(p, true, 10.4)
		t.eq(WeaponService.isAiming(p), true)
		t.eq(p._attrs.Aiming, true)
		t.eq(p.Character._attrs.AimPitch, 9, "pitch snapped to the 3 degree step")
		WeaponService._setEquipped(inv, nil) -- safe zone / passive / BUSTED holster
		t.eq(WeaponService.isAiming(p), false, "no brandishing with an empty hand")
		t.eq(p._attrs.Aiming, false)
		t.eq(p.Character._attrs.AimPitch, nil)
		WeaponService._setEquipped(inv, "pistol")
		WeaponService._onAim(p, true, 0)
		WeaponService._setEquipped(inv, "bat")
		t.eq(WeaponService.isAiming(p), false, "a bat is not aimed")
		WeaponService._onAim(p, true, 0)
		t.eq(WeaponService.isAiming(p), false, "the server never believes an aim without a gun")
		WeaponService._onAim(p, "yes")
		t.eq(WeaponService.isAiming(p), false, "bad args ignored")
		WeaponService._removeInv(p)
	end)

	t.test("WeaponService._aimPitch: validated, clamped, stepped", function()
		t.eq(WeaponService._aimPitch(nil, 10.4), 9)
		t.eq(WeaponService._aimPitch(9, 10), 9, "small moves are not re-replicated")
		t.eq(WeaponService._aimPitch(9, 13), 12)
		t.eq(WeaponService._aimPitch(nil, 500), WeaponService.AIM_PITCH_LIMIT)
		t.eq(WeaponService._aimPitch(nil, -500), -WeaponService.AIM_PITCH_LIMIT)
		t.eq(WeaponService._aimPitch(6, 0 / 0), 6, "NaN keeps the old value")
		t.eq(WeaponService._aimPitch(nil, math.huge), nil)
		t.eq(WeaponService._aimPitch(nil, "up"), nil)
	end)

	t.test("WeaponService._isDistantListener: beyond every ShotFx point, within DISTANT_RADIUS", function()
		local origin = V3.new(0, 0, 0)
		local points = { origin, V3.new(0, 0, -300) }
		local r = Weapons.FX_RADIUS
		t.ok(not WeaponService._isDistantListener(V3.new(r - 1, 0, 0), origin, points), "hears the full shot")
		t.ok(
			not WeaponService._isDistantListener(V3.new(0, 0, -300 - r + 5), origin, points),
			"near the impact: got ShotFx"
		)
		t.ok(WeaponService._isDistantListener(V3.new(r + 50, 0, 0), origin, points), "distant tail")
		t.ok(
			not WeaponService._isDistantListener(V3.new(WeaponService.DISTANT_RADIUS + 1, 0, 0), origin, points),
			"too far to hear"
		)
	end)

	-- COMBATSERVICE -------------------------------------------------------------------------------------------------
	t.test(
		"CombatService.stun: no stun-lock (immune while stunned and just after), forced arrests still land",
		function()
			local victim = fake("Victim", "Player", { UserId = 4242 })
			t.eq(CombatService.stun(victim, 0.9), true, "first hit stuns")
			t.eq(victim._attrs.Stunned, true)
			t.eq(CombatService.stun(victim, 0.9), false, "a re-stun inside the window neither lands nor extends")
			t.eq(CombatService.stun(victim, 0.9), false)
			t.eq(CombatService.stun(victim, 5.3, true), true, "the BUSTED freeze is forced")
			t.eq(CombatService.stun(victim, 0), false)
			victim.Parent = nil -- the delayed release bails for a player who left
		end
	)

	-- DAMAGESERVICE -------------------------------------------------------------------------------------------------
	local clock = 1000
	local dfired = {}
	local busts = {}
	local clears = {}
	local raises = {}
	local ddatas = {}
	local dmocks = {
		DataService = {
			get = function(p)
				return ddatas[p]
			end,
			spendCash = function(p, amount)
				local d = ddatas[p]
				if d and d.cash >= amount then
					d.cash -= amount
					return true
				end
				return false
			end,
			addCash = function(p, amount)
				ddatas[p].cash += amount
			end,
			markDirty = function() end,
		},
		GarageService = {
			incomePerSec = function()
				return 10
			end,
		},
		WantedService = {
			bust = function(p, reason)
				table.insert(busts, { p = p, reason = reason })
			end,
			clearOnWasted = function(p)
				table.insert(clears, p)
			end,
			raiseTo = function(p, stars, reason)
				table.insert(raises, { p = p, stars = stars, reason = reason })
			end,
		},
		WeaponService = {
			holster = function() end,
			pushState = function() end,
		},
		TheftService = {
			getActiveTheft = function()
				return nil
			end,
			onThiefHit = function() end,
		},
	}
	Damage._setHooks({
		clock = function()
			return clock
		end,
		serverNow = function()
			return clock
		end,
		system = function(name)
			return dmocks[name]
		end,
		fireClient = function(name, player, ...)
			table.insert(dfired, { name = name, player = player, args = { ... } })
		end,
	})

	local function newVictim(name, cash)
		local p = fakePlayer(name)
		ddatas[p] = { cash = cash, stats = {}, combat = { passivePref = false }, medkits = 0 }
		Damage._addPlayer(p)
		return p
	end
	local deadBody = fake("Body", "Model")

	local function firedFor(name, p)
		for _, f in dfired do
			if f.name == name and f.player == p then
				return f
			end
		end
		return nil
	end

	t.test("DamageService: a reset while wanted (no damage) is BUSTED, with no hospital bill", function()
		clock = 2000
		table.clear(busts)
		table.clear(dfired)
		local p = newVictim("Resetter", 10000)
		p:SetAttribute("Wanted", 2)
		clock += 30
		Damage._onHealthChanged(p, 0) -- the engine drops Health on a reset: adopted, but not damage
		local st = Damage._getState(p)
		t.eq(st.health, 0)
		t.eq(st.lastDamageAt, nil, "no fake damage stamp")
		Damage._onDied(p, deadBody)
		t.eq(#busts, 1, "busted: §7.1 anti-reset")
		t.eq(busts[1].reason, "died")
		t.eq(firedFor("Wasted", p), nil, "not WASTED")
		t.eq(ddatas[p].cash, 10000, "no bill")
		Damage._removePlayer(p)
	end)

	t.test("DamageService: plain deaths are free; deaths a player caused bill the victim", function()
		clock = 3000
		table.clear(busts)
		table.clear(clears)
		table.clear(dfired)
		local fell = newVictim("Faller", 10000)
		clock += 30
		Damage._onHealthChanged(fell, 0)
		Damage._onDied(fell, deadBody)
		local w = firedFor("Wasted", fell)
		t.ok(w ~= nil, "WASTED")
		t.eq(w.args[1].bill, 0, "nobody to blame: no bill")
		t.eq(ddatas[fell].cash, 10000)
		t.eq(#clears, 1)
		-- a rise in Health that we didn't write is put back (nothing heals but the server)
		local healer = newVictim("Healer", 0)
		local hs = Damage._getState(healer)
		hs.health = 40
		Damage._onHealthChanged(healer, 100)
		t.eq(hs.health, 40)
		-- shot dead by a player: billed min(5 % cash, 120 s income)
		local shooter = fakePlayer("Shooter")
		Damage._addPlayer(shooter)
		local victim = newVictim("Shot", 10000)
		local st = Damage._getState(victim)
		st.lastDamage = { amount = 30, source = shooter, weapon = "pistol" }
		st.lastDamageAt = clock
		Damage._onDied(victim, deadBody)
		local bill = DamageModel.hospitalBill(10000, 10, 0.05, 120, false)
		t.ok(bill > 0)
		t.eq(firedFor("Wasted", victim).args[1].bill, bill)
		t.eq(ddatas[victim].cash, 10000 - bill)
		for _, p in { fell, healer, shooter, victim } do
			Damage._removePlayer(p)
		end
	end)

	t.test("DamageService: a passive player who gets wanted loses passive and the police may fire", function()
		clock = 4000
		local p = newVictim("Pacifist", 500)
		local attacker = fakePlayer("Hunter")
		Damage._addPlayer(attacker)
		clock += 120 -- past spawn protection and the respawn hold-fire
		t.eq(Damage.setPassive(p, true), true)
		t.eq(Damage.policeHoldFire(p), true, "passive and clean: police hold fire")
		t.eq(Damage.canDamage(attacker, p), false, "passive and clean: immune to players")
		p:SetAttribute("Wanted", 2) -- a bat swing at an officer
		t.eq(Damage.policeHoldFire(p), false, "wanted: passive no longer protects, even before the switch-off")
		t.eq(Damage.canDamage(attacker, p), true, "bounty hunters can reach them")
		t.eq(Damage.forcePassiveOff(p), true)
		local st = Damage._getState(p)
		t.eq(st.passive, false)
		t.eq(p._attrs.Passive, false)
		t.eq(ddatas[p].combat.passivePref, false)
		t.ok(st.weaponsLockedUntil <= clock, "no weapons lock")
		t.ok(st.passiveReadyAt <= clock, "no re-enable cooldown")
		t.eq(Damage.forcePassiveOff(p), false, "already off")
		t.eq(select(1, Damage.setPassive(p, true)), false, "can't go passive while wanted")
		Damage._removePlayer(p)
		Damage._removePlayer(attacker)
	end)

	t.test("DamageService.grantProtection: protected while cuffed and after the release, then fair game", function()
		clock = 5000
		local p = newVictim("Cuffed", 500)
		local attacker = fakePlayer("Opportunist")
		Damage._addPlayer(attacker)
		clock += 120
		t.eq(Damage.canDamage(attacker, p), true)
		Damage.grantProtection(p, 5)
		t.eq(Damage.canDamage(attacker, p), false, "cuffed: protected")
		t.eq(Damage.policeHoldFire(p), true)
		clock += 5 + Damage.SPAWN_PROTECTION - 0.5
		t.eq(Damage.canDamage(attacker, p), false, "still protected just after the release")
		clock += 1 + Police.HOLD_FIRE_RESPAWN
		t.eq(Damage.canDamage(attacker, p), true)
		t.eq(Damage.policeHoldFire(p), false)
		Damage._removePlayer(p)
		Damage._removePlayer(attacker)
	end)

	t.test("DamageService.useMedKit: a second kit while the first heals is refused (and not spent)", function()
		clock = 6000
		local p = newVictim("Medic", 0)
		ddatas[p].medkits = 2
		local st = Damage._getState(p)
		st.health = 50
		t.eq(Damage.useMedKit(p), true)
		local ok, why = Damage.useMedKit(p)
		t.eq(ok, false)
		t.eq(why, "Already patching up.")
		t.eq(ddatas[p].medkits, 1, "the second kit stays in the pocket")
		clock += Weapons.MedKit.duration + 0.1
		t.eq(Damage.useMedKit(p), true, "after the first one finishes")
		Damage._removePlayer(p)
	end)

	t.test("DamageService: defending your garage never counts toward Menace; open-street downs do", function()
		clock = 7000
		table.clear(raises)
		local owner = fakePlayer("Owner")
		Damage._addPlayer(owner)
		for i = 1, 4 do
			local raider = newVictim("Raider" .. i, 0)
			Damage._onKilledBy(owner, raider, { amount = 50, source = owner, defense = true })
			clock += 10
		end
		t.ok(owner._attrs.Menace ~= true, "four raiders downed in your garage: not a menace")
		t.eq(#raises, 0)
		local griefer = fakePlayer("Griefer")
		Damage._addPlayer(griefer)
		for i = 1, 3 do
			local walker = newVictim("Walker" .. i, 0)
			Damage._onKilledBy(griefer, walker, { amount = 50, source = griefer })
			clock += 10
		end
		t.eq(griefer._attrs.Menace, true, "three bystanders in a few minutes: menace")
		t.eq(#raises, 1)
		t.eq(raises[1].p, griefer)
	end)
end
