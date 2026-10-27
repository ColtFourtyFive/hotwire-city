--!nocheck
-- Combat v2 damage (gta_combat §4.3, §6-8): DamageModel (parts, armor split, regen, death classification, hospital
-- bill), DamageService PvP rules, the v1 -> v2 DataService migration and sanitizer, MapLayout combat POIs.
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local Weapons = H.require("src/shared/Config/Weapons")
	local DamageModel = H.require("src/shared/Combat/DamageModel")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local DamageService = H.require("src/server/Systems/DamageService")
	local DataService = H.require("src/server/Systems/DataService")

	t.test("partClass / partMultiplier: head, torso, limbs; shotgun pellets never headshot", function()
		t.eq(DamageModel.partClass("Head"), "head")
		t.eq(DamageModel.partClass("UpperTorso"), "torso")
		t.eq(DamageModel.partClass("HumanoidRootPart"), "torso")
		t.eq(DamageModel.partClass("LeftHand"), "limb")
		t.eq(DamageModel.partClass("Hat"), "limb", "accessories count as limbs")
		local pistol = Weapons.get("pistol")
		t.eq(DamageModel.partMultiplier(pistol, "Head"), pistol.headMult)
		t.eq(DamageModel.partMultiplier(pistol, "LowerTorso"), 1)
		t.eq(DamageModel.partMultiplier(pistol, "RightFoot"), pistol.limbMult)
		t.eq(DamageModel.partMultiplier(Weapons.get("pump"), "Head"), 1)
	end)

	t.test("raw damage: falloff for guns only, occupants shielded", function()
		local pistol = Weapons.get("pistol")
		local near = DamageModel.raw(pistol, "UpperTorso", 0)
		local far = DamageModel.raw(pistol, "UpperTorso", pistol.zeroDist + 50)
		t.eq(near, pistol.damage)
		t.ok(far < near, "falloff")
		t.near(DamageModel.raw(pistol, "UpperTorso", 0, true), pistol.damage * Weapons.OCCUPANT_MULT, 1e-9)
		local bat = Weapons.get("bat")
		t.eq(DamageModel.raw(bat, "UpperTorso", 500), bat.damage, "melee has no falloff")
	end)

	t.test("armor absorbs first, whole numbers, a lethal hit lands on 0", function()
		local a, h = DamageModel.split(30, 50)
		t.eq(a, 30)
		t.eq(h, 20)
		local nh, na, ht, at = DamageModel.apply(100, 30, 50)
		t.eq(na, 0, "armor gone")
		t.eq(nh, 80, "health took the rest")
		t.eq(ht, 20)
		t.eq(at, 30)
		local nh2, na2 = DamageModel.apply(100, 100, 40)
		t.eq(nh2, 100, "full armor soaks it")
		t.eq(na2, 60)
		local nh3 = DamageModel.apply(10, 0, 10.4)
		t.eq(nh3, 0, "lethal")
		local nh4 = DamageModel.apply(50, 0, 0.4)
		t.eq(nh4, 50, "a scratch costs nothing visible")
		local nh5, na5 = DamageModel.apply(100, 0, -20)
		t.eq(nh5, 100, "negative damage ignored")
		t.eq(na5, 0)
	end)

	t.test("regen: waits 6 s, +4/s, capped at 50; garage heals to 100 after 3 s", function()
		t.eq(DamageModel.regen(30, 5, 1, false), 30, "too soon")
		t.eq(DamageModel.regen(30, 6, 1, false), 34)
		t.eq(DamageModel.regen(49, 10, 1, false), 50, "cap")
		t.eq(DamageModel.regen(60, 10, 1, false), 60, "never above 50 by regen")
		t.eq(DamageModel.regen(60, 3, 1, true), 85, "garage")
		t.eq(DamageModel.regen(90, 3, 1, true), 100, "garage cap")
		t.eq(DamageModel.regen(0, 100, 1, false), 0, "dead stays dead")
	end)

	t.test("classifyDeath: recent damage = wasted, wanted without damage = busted, own garage = wasted", function()
		t.eq(DamageModel.classifyDeath(95, 100, 3, false), "wasted")
		t.eq(DamageModel.classifyDeath(80, 100, 3, false), "busted")
		t.eq(DamageModel.classifyDeath(nil, 100, 2, false), "busted")
		t.eq(DamageModel.classifyDeath(nil, 100, 2, true), "wasted")
		t.eq(DamageModel.classifyDeath(nil, 100, 0, false), "wasted")
	end)

	t.test("hospitalBill: min(5% cash, 120 s income), free for rookies", function()
		t.eq(DamageModel.hospitalBill(10000, 1, 0.05, 120, false), 120)
		t.eq(DamageModel.hospitalBill(1000, 100, 0.05, 120, false), 50)
		t.eq(DamageModel.hospitalBill(1000, 100, 0.05, 120, true), 0)
		t.eq(DamageModel.hospitalBill(-5, 100, 0.05, 120, false), 0)
	end)

	t.test("DamageService._ruleCanDamage: protection, harmless attackers, revenge, safe zones, garages", function()
		local base = {
			victimProtected = false,
			attackerHarmless = false,
			victimSafe = false,
			attackerSafe = false,
			attackerInOwnGarage = false,
			victimInAttackerGarage = false,
			revengeImmune = false,
		}
		local function with(k, v)
			local c = table.clone(base)
			c[k] = v
			return c
		end
		t.ok(DamageService._ruleCanDamage(base), "open street")
		t.eq(select(2, DamageService._ruleCanDamage(with("victimProtected", true))), "protected")
		t.eq(select(2, DamageService._ruleCanDamage(with("attackerHarmless", true))), "harmless")
		t.eq(select(2, DamageService._ruleCanDamage(with("revengeImmune", true))), "revenge")
		t.eq(select(2, DamageService._ruleCanDamage(with("victimSafe", true))), "victimSafe")
		t.eq(select(2, DamageService._ruleCanDamage(with("attackerSafe", true))), "attackerSafe")
		t.ok(not DamageService._ruleCanDamage(with("attackerInOwnGarage", true)), "no sniping from home")
		local defend = with("attackerInOwnGarage", true)
		defend.victimInAttackerGarage = true
		t.ok(DamageService._ruleCanDamage(defend), "defending your garage is allowed")
	end)

	-- data v2 ------------------------------------------------------------------------------------------------------
	t.test("schema v2: template has the combat fields", function()
		t.eq(DataService.SCHEMA_VERSION, 2)
		local d = DataService._template()
		t.ok(d.weapons.bat ~= nil, "free bat")
		t.eq(d.armor, 0)
		t.eq(d.medkits, 0)
		t.ok(d.combat.rookieSeconds > 0, "new players start as rookies")
		t.eq(d.combat.passivePref, false)
		t.ok(typeof(d.tintsOwned) == "table")
	end)

	t.test("v1 -> v2 migration is additive: bat -> weapons, P9 welcome gift, veterans are not rookies", function()
		local v1 = {
			version = 1,
			cash = 12345,
			tools = { bat = true, taser = true },
			upgrades = { lock = 2 },
			garage = {},
		}
		local d = DataService._prepare(v1, 1_800_000_000)
		t.eq(d.version, 2)
		t.eq(d.cash, 12345, "cash untouched")
		t.eq(d.tools.taser, true, "gadgets stay in tools")
		t.eq(d.tools.bat, true, "v1 tools.bat kept")
		t.ok(d.weapons.bat ~= nil, "bat weapon")
		local p9 = Weapons.get("pistol")
		t.eq(d.weapons.pistol.ammo, p9.mag * (1 + Weapons.FREE_MAGS_ON_BUY), "P9 + 2 spare mags")
		t.eq(d.combat.rookieSeconds, 0, "veterans skip rookie protection")
		-- migrating twice never gifts twice
		local again = DataService._migrate(d)
		t.eq(again.weapons.pistol.ammo, d.weapons.pistol.ammo)
	end)

	t.test("sanitize: weapons / tints / armor / medkits are validated", function()
		local raw = DataService._template()
		raw.weapons = {
			pistol = { ammo = 1e9, tint = "gold" },
			nightstick = { ammo = 5 },
			fists = { ammo = 1 },
			laser = { ammo = 3 },
			carbine = { ammo = -4, tint = "hotpink" },
			pump = "junk",
		}
		raw.tintsOwned = { gold = true, hotpink = true }
		raw.armor = 500
		raw.medkits = 99
		raw.combat = { rookieSeconds = 1e9, passivePref = "yes" }
		local d = DataService._prepare(raw, 1_800_000_000)
		local p9 = Weapons.get("pistol")
		t.eq(d.weapons.pistol.ammo, p9.reserveCap + p9.mag, "ammo clamped")
		t.eq(d.weapons.pistol.tint, "gold")
		t.eq(d.weapons.nightstick, nil, "police gear dropped")
		t.eq(d.weapons.fists, nil, "fists are implicit")
		t.eq(d.weapons.laser, nil, "unknown dropped")
		t.eq(d.weapons.carbine.ammo, 0, "negative ammo -> 0")
		t.eq(d.weapons.carbine.tint, nil, "unknown tint dropped")
		t.eq(d.weapons.pump, nil, "bad record dropped")
		t.ok(d.weapons.bat ~= nil, "bat always owned")
		t.eq(d.tintsOwned.gold, true)
		t.eq(d.tintsOwned.hotpink, nil)
		t.eq(d.armor, 100)
		t.eq(d.medkits, Weapons.MedKit.carry)
		t.eq(d.combat.passivePref, false)
		t.ok(d.combat.rookieSeconds <= 1800, "rookie clamp")
	end)

	-- map ------------------------------------------------------------------------------------------------------------
	t.test("MapLayout: 2 hospitals (nearest wins), 2 gun stores, safe zones contain their centres", function()
		local hs = MapLayout.hospitals()
		t.eq(#hs, 2)
		local cf1, name1 = MapLayout.hospitalCFrame(hs[1].cframe.Position + V3.new(3, 0, 3))
		t.eq(name1, hs[1].name)
		t.ok((cf1.Position - hs[1].cframe.Position).Magnitude < 1e-6)
		local _, name2 = MapLayout.hospitalCFrame(hs[2].cframe.Position)
		t.eq(name2, hs[2].name)
		local _, fallback = MapLayout.hospitalCFrame(nil)
		t.ok(typeof(fallback) == "string")
		t.eq(#MapLayout.gunStores(), 2)
		local kinds = {}
		for _, z in MapLayout.safeZones() do
			kinds[z.kind] = true
			local at = MapLayout.safeZoneAt(z.cframe.Position)
			t.ok(at ~= nil, "zone contains its centre: " .. z.name)
		end
		for _, k in { "garage", "gunstore", "hospital" } do
			t.ok(kinds[k], "zone kind " .. k)
		end
		t.eq(MapLayout.safeZoneAt(V3.new(1e5, 0, 1e5)), nil, "open world is not safe")
	end)
end
