--!nocheck
-- Combat v2 weapons (gta_combat §4, §13.1): Config/Weapons balance rules, Ballistics (deterministic pellets, spread,
-- bloom, falloff, recoil, reload), WeaponModels builders, WeaponClient / WeaponWheel / GunShopUI pure helpers and the
-- ShopService ammo quote.
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local Weapons = H.require("src/shared/Config/Weapons")
	local Ballistics = H.require("src/shared/Combat/Ballistics")
	local WeaponModels = H.require("src/shared/Combat/WeaponModels")
	local ShopService = H.require("src/server/Systems/ShopService")

	local FWD = V3.new(0, 0, -1)
	local STILL = { aiming = false, moving = false, sprinting = false, airborne = false }

	-- balance ---------------------------------------------------------------------------------------------------------
	t.test("every gun except the marksman: body TTK >= 0.38 s, all-headshot TTK >= 0.25 s (100 HP)", function()
		for _, def in Weapons.List do
			if Weapons.isGun(def) and def.id ~= "marksman" then
				local body = Ballistics.ttk(def, 100, false)
				local head = Ballistics.ttk(def, 100, true)
				t.ok(body >= 0.38 - 1e-6, ("%s body TTK %.3f"):format(def.id, body))
				t.ok(head >= 0.25 - 1e-6, ("%s head TTK %.3f"):format(def.id, head))
			end
		end
	end)

	t.test("no single pump blast reaches 100 (all pellets, point blank, any part)", function()
		local pump = Weapons.get("pump")
		t.ok(pump ~= nil, "pump exists")
		local blast = pump.damage * Weapons.pelletCount(pump) * pump.headMult
		t.ok(blast < 100, "pump blast " .. blast)
		t.eq(pump.headMult, 1, "pellets never get a head bonus")
		t.ok(Weapons.pelletCount(pump) > 1 and Weapons.pelletCount(pump) <= Weapons.MAX_PELLETS, "pellet count")
	end)

	t.test("roster shape: ids, slots, guns have ammo economy, melee has reach", function()
		local seen = {}
		for i, def in Weapons.List do
			t.ok(not seen[def.id], "unique id " .. def.id)
			seen[def.id] = true
			t.eq(Weapons.ById[def.id], def, "ById " .. def.id)
			t.eq(Weapons.Index[def.id], i, "Index " .. def.id)
			t.ok(def.wheelSlot >= 1 and def.wheelSlot <= 8, "wheel slot " .. def.id)
			t.ok(#def.id <= 16, "id fits the remote limit " .. def.id)
			t.ok(not string.find(string.lower(def.name), "ammu"), "no Rockstar trademarks")
			if Weapons.isGun(def) then
				t.ok(def.mag and def.mag > 0, "mag " .. def.id)
				t.ok(def.ammoPrice and def.ammoPerPurchase and def.reserveCap, "ammo economy " .. def.id)
				t.ok(def.maxRange > 0 and def.drawTime > 0, "range / draw " .. def.id)
				t.ok(Weapons.maxSpread(def) >= def.spreadHip, "max spread covers hip spread " .. def.id)
			else
				t.ok(def.meleeReach and def.meleeReach > 0, "melee reach " .. def.id)
			end
		end
		for _, id in { "fists", "bat", "pistol", "microsmg", "pump", "carbine", "marksman" } do
			t.ok(Weapons.get(id) ~= nil, "C0/C2 roster has " .. id)
		end
		t.eq(Weapons.get("nope"), nil)
		t.eq(Weapons.get(42), nil)
	end)

	t.test("shopList: buyable weapons only, grouped by class in SHOP_CLASSES order", function()
		local list = Weapons.shopList()
		t.ok(#list >= 8, "enough stock")
		local lastClass = 0
		for _, def in list do
			t.ok(not def.policeOnly, "no police-only gear " .. def.id)
			t.eq(def.unlock, nil, "no free / always items " .. def.id)
			local ci = table.find(Weapons.SHOP_CLASSES, def.class)
			t.ok(ci ~= nil and ci >= lastClass, "class order " .. def.id)
			lastClass = ci
		end
	end)

	t.test("inSlot: owned weapons of a slot sorted by order", function()
		local owned = { fists = true, bat = true, pistol = true, handcannon = true }
		local melee = Weapons.inSlot(5, owned)
		t.eq(melee[1], "fists", "fists first")
		t.eq(melee[2], "bat")
		local pistols = Weapons.inSlot(1, owned)
		t.eq(#pistols, 2)
		t.eq(pistols[1], "pistol")
		t.eq(#Weapons.inSlot(3, owned), 0, "no rifles owned")
	end)

	t.test("statBars are 0..1", function()
		for _, def in Weapons.List do
			local b = Weapons.statBars(def)
			for k, v in b do
				t.ok(v >= 0 and v <= 1, def.id .. " " .. k)
			end
		end
	end)

	t.test("tints: no pink / neon, black is free, gold + platinum are the expensive ones", function()
		for id, tint in Weapons.Tints do
			t.ok(tint.material ~= H.roblox.Enum.Material.Neon, id .. " not neon")
			local c = tint.color
			t.ok(not (c.R > 0.8 and c.B > 0.6 and c.G < 0.6), id .. " not pink")
		end
		t.eq(Weapons.Tints.black.price, 0)
		t.ok(Weapons.Tints.gold.price > Weapons.Tints.army.price)
	end)

	-- ballistics ------------------------------------------------------------------------------------------------------
	t.test("pellets are deterministic per seed and differ between seeds", function()
		local a = Ballistics.pellets(FWD, 4, 123456, 8)
		local b = Ballistics.pellets(FWD, 4, 123456, 8)
		local c = Ballistics.pellets(FWD, 4, 654321, 8)
		t.eq(#a, 8)
		local differs = false
		for i = 1, 8 do
			t.near((a[i] - b[i]).Magnitude, 0, 1e-9, "same seed, pellet " .. i)
			t.ok(Ballistics.angleBetween(a[i], FWD) <= 4 + 1e-6, "inside the cone " .. i)
			t.near(a[i].Magnitude, 1, 1e-6, "unit " .. i)
			if (a[i] - c[i]).Magnitude > 1e-6 then
				differs = true
			end
		end
		t.ok(differs, "other seed, other pattern")
		-- seed 0 / negative seeds are normalised, never stuck
		local z = Ballistics.pellets(FWD, 3, 0, 3)
		t.ok((z[1] - z[2]).Magnitude > 1e-9, "seed 0 still spreads")
	end)

	t.test("Park-Miller generator stays in range", function()
		local s = Ballistics.seedState(42)
		for _ = 1, 1000 do
			local u
			s, u = Ballistics.nextRandom(s)
			t.ok(u >= 0 and u < 1, "uniform in [0,1)")
			t.ok(s >= 1 and s < 2147483647, "state valid")
		end
	end)

	t.test("spread: aim < hip, movement widens, never past maxSpread; pump is fixed", function()
		local smg = Weapons.get("microsmg")
		local hip = Ballistics.spreadAngle(smg, 0, STILL)
		local aim =
			Ballistics.spreadAngle(smg, 0, { aiming = true, moving = false, sprinting = false, airborne = false })
		local run =
			Ballistics.spreadAngle(smg, 0, { aiming = false, moving = true, sprinting = true, airborne = false })
		local air =
			Ballistics.spreadAngle(smg, 99, { aiming = false, moving = false, sprinting = false, airborne = true })
		t.ok(aim < hip, "aim tighter")
		t.ok(run >= hip, "sprint wider")
		t.ok(air <= Weapons.maxSpread(smg) + 1e-9, "clamped to max spread")
		local pump = Weapons.get("pump")
		t.eq(Ballistics.spreadAngle(pump, 50, STILL), pump.spreadHip, "pump ignores bloom")
	end)

	t.test("bloom: grows per shot, capped, recovers after the delay", function()
		local smg = Weapons.get("microsmg")
		local b = 0
		for _ = 1, 100 do
			b = Ballistics.addBloom(smg, b)
		end
		t.ok(b <= Weapons.maxSpread(smg) + 1e-9, "capped")
		t.eq(Ballistics.recoverBloom(b, 0.1, 0), b, "no recovery right after a shot")
		t.ok(Ballistics.recoverBloom(b, 0.1, 1) < b, "recovers later")
		t.eq(Ballistics.recoverBloom(0.1, 10, 1), 0, "never negative")
	end)

	t.test("falloff: 1 inside fullDist, minMult past zeroDist, monotonic", function()
		local def = Weapons.get("pistol")
		t.eq(Ballistics.falloff(def, 0), 1)
		t.near(Ballistics.falloff(def, def.zeroDist + 100), def.minMult, 1e-9)
		local prev = 1
		for d = 0, def.zeroDist + 20, 5 do
			local f = Ballistics.falloff(def, d)
			t.ok(f <= prev + 1e-9, "monotonic at " .. d)
			prev = f
		end
	end)

	t.test("recoil: kick inside the weapon's range, mobile kicks less, accumulation clamped, decay", function()
		local def = Weapons.get("carbine")
		local p1, y1 = Ballistics.recoilKick(def, 1, 1, false)
		local p2, y2 = Ballistics.recoilKick(def, 1, 1, true)
		t.near(p1, def.recoil.pitchMax, 1e-9)
		t.ok(p2 < p1 and math.abs(y2) <= math.abs(y1), "mobile softer")
		t.eq(Ballistics.clampRecoil(def, 1e6), def.recoil.pitchMax * Weapons.TOTAL_RECOIL_MULT)
		t.ok(Ballistics.decayRecoil(10, 1 / 60) < 10, "decays")
	end)

	t.test("muzzleToPoint: muzzle -> crosshair point, camera dir when too close or behind", function()
		local m = V3.new(0, 0, 0)
		local d = Ballistics.muzzleToPoint(m, V3.new(0, 0, -50), FWD)
		t.near((d - FWD).Magnitude, 0, 1e-9)
		local close = Ballistics.muzzleToPoint(m, V3.new(0, 0, -0.5), FWD)
		t.near((close - FWD).Magnitude, 0, 1e-9, "too close")
		local behind = Ballistics.muzzleToPoint(m, V3.new(0, 0, 20), FWD)
		t.near((behind - FWD).Magnitude, 0, 1e-9, "behind")
	end)

	t.test("reload: empty reload is slower, shells one by one, never more than the reserve", function()
		local pistol = Weapons.get("pistol")
		t.ok(Ballistics.reloadTime(pistol, 0) > Ballistics.reloadTime(pistol, 3), "empty slower")
		t.eq(Ballistics.reloadAmount(pistol, 3, 100), pistol.mag - 3)
		t.eq(Ballistics.reloadAmount(pistol, 3, 2), 2, "limited by reserve")
		local pump = Weapons.get("pump")
		t.eq(Ballistics.reloadAmount(pump, 2, 30), 1, "one shell at a time")
		t.eq(Ballistics.reloadAmount(pump, pump.mag, 30), 0, "full")
	end)

	-- models ------------------------------------------------------------------------------------------------------------
	t.test("WeaponModels: every weapon + gadget builds a realistic part model with a Muzzle", function()
		local keys = {}
		for _, def in Weapons.List do
			keys[def.asset.model] = true
		end
		keys.taser = true
		keys.spikes = true
		for key in keys do
			t.ok(WeaponModels.has(key), "builder " .. key)
			local model = WeaponModels.buildModel(key)
			local parts = 0
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					parts += 1
					t.ok(d.Material ~= H.roblox.Enum.Material.Neon, key .. ": no neon")
					t.ok(d.Anchored, key .. ": preview parts anchored")
				end
			end
			t.ok(parts >= 1, key .. " has parts")
			t.ok(model.PrimaryPart ~= nil, key .. " has a handle")
			model:Destroy()
		end
	end)

	-- client pure helpers ---------------------------------------------------------------------------------------------
	t.test("WeaponClient._cycleSlot / _canFire", function()
		H.setMode("client")
		local WC = H.require("src/client/Controllers/WeaponClient")
		local owned = { fists = true, pistol = true, handcannon = true }
		t.eq(WC._cycleSlot(1, owned, nil), "pistol")
		t.eq(WC._cycleSlot(1, owned, "pistol"), "handcannon")
		t.eq(WC._cycleSlot(1, owned, "handcannon"), "pistol", "wraps")
		t.eq(WC._cycleSlot(3, owned, nil), nil, "empty slot")
		local pistol = Weapons.get("pistol")
		t.ok(WC._canFire(pistol, 5, 10, 0, 0, false), "ready")
		t.ok(not WC._canFire(pistol, 0, 10, 0, 0, false), "empty")
		t.ok(not WC._canFire(pistol, 5, 10, 9.99, 0, false), "still drawing")
		t.ok(not WC._canFire(pistol, 5, 10, 0, 11, false), "rate")
		t.ok(not WC._canFire(pistol, 5, 10, 0, 0, true), "mag reload blocks")
		t.ok(WC._canFire(Weapons.get("pump"), 3, 10, 0, 0, true), "shell reload can be interrupted")
		t.ok(not WC._canFire(Weapons.get("bat"), 1, 10, 0, 0, false), "melee never 'fires'")
		H.setMode("server")
	end)

	t.test("WeaponWheel: slot geometry, vector -> slot, entries", function()
		H.setMode("client")
		local WW = H.require("src/client/Controllers/WeaponWheel")
		local top = WW._slotOffset(1, 190)
		t.near(top.X, 0, 1e-9)
		t.near(top.Y, -190, 1e-9)
		local right = WW._slotOffset(3, 190)
		t.near(right.X, 190, 1e-9)
		t.near(right.Y, 0, 1e-6)
		t.eq(WW._slotFromVector(H.roblox.Vector2.new(0, -100), 40), 1, "up")
		t.eq(WW._slotFromVector(H.roblox.Vector2.new(100, 0), 40), 3, "right")
		t.eq(WW._slotFromVector(H.roblox.Vector2.new(0, 100), 40), 5, "down")
		t.eq(WW._slotFromVector(H.roblox.Vector2.new(-100, -100), 40), 8, "up-left")
		t.eq(WW._slotFromVector(H.roblox.Vector2.new(10, 10), 40), nil, "dead zone")
		local owned = { fists = true, bat = true, pistol = true }
		t.eq(WW._entries(5, owned, {}, 0)[1], "fists")
		t.eq(#WW._entries(6, owned, { "spikes", "taser" }, 0), 2, "gadgets")
		t.eq(WW._entries(6, owned, { "spikes", "taser" }, 0)[1], "taser", "gadget order")
		t.eq(WW._entries(7, owned, {}, 2)[1], "medkit")
		t.eq(#WW._entries(7, owned, {}, 0), 0)
		H.setMode("server")
	end)

	t.test("GunShopUI menus: categories, buy / owned rows, ammo quotes match the server", function()
		H.setMode("client")
		local Shop = H.require("src/client/Controllers/GunShopUI")
		local ctx = {
			cash = 5000,
			owned = { pistol = { mag = 12, reserve = 24 }, bat = { mag = 0, reserve = 0 } },
			tintsOwned = {},
			armor = 100,
			medkits = 3,
		}
		local root = Shop._menu("root", ctx)
		t.ok(#root.rows >= #Weapons.SHOP_CLASSES + 3, "root rows")
		local medRow
		for _, r in root.rows do
			if r.label == Weapons.MedKit.name then
				medRow = r
			end
		end
		t.eq(medRow.action, "none", "med kits full")
		local handguns = Shop._menu("class:Handgun", ctx)
		local pistolRow, cannonRow
		for _, r in handguns.rows do
			if r.weapon == "pistol" then
				pistolRow = r
			elseif r.weapon == "handcannon" then
				cannonRow = r
			end
		end
		t.eq(pistolRow.value, "OWNED")
		t.eq(pistolRow.action, "open")
		t.eq(cannonRow.action, "buy")
		local armor = Shop._menu("armor", ctx)
		t.eq(armor.rows[1].action, "none", "armor full")
		local tints = Shop._menu("tint:pistol", ctx)
		t.eq(tints.rows[1].value, "EQUIPPED", "black is the default")
		-- ammo quote parity with ShopService
		for _, def in Weapons.List do
			if Weapons.isGun(def) then
				for _, reserve in { 0, 5, def.reserveCap - 1, def.reserveCap } do
					for _, full in { false, true } do
						local r1, p1 = Shop._ammoQuote(def, reserve, full)
						local r2, p2 = ShopService._ammoQuote(def.id, def.reserveCap - reserve, full)
						t.eq(r1, r2, def.id .. " rounds")
						t.eq(p1, p2, def.id .. " price")
					end
				end
			end
		end
		H.setMode("server")
	end)

	t.test("ShopService._weaponQuote: police gear, fists and owned guns are not for sale", function()
		local ok, price = ShopService._weaponQuote("pistol", {})
		t.ok(ok and price == Weapons.get("pistol").price)
		t.eq(select(2, ShopService._weaponQuote("pistol", { pistol = { ammo = 1 } })), "owned")
		t.eq(select(2, ShopService._weaponQuote("nightstick", {})), "police")
		t.eq(select(2, ShopService._weaponQuote("fists", {})), "invalid")
		t.eq(select(2, ShopService._weaponQuote(123, {})), "invalid")
	end)
end
