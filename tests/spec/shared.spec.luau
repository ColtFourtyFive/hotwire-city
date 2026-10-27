--!nocheck
-- Pure shared modules: Format, Rolls, EconomyMath, Config integrity.
return function(t)
	local H = t.H
	local Format = H.require("src/shared/Util/Format")
	local Rolls = H.require("src/shared/Util/Rolls")
	local EconomyMath = H.require("src/shared/Util/EconomyMath")
	local Cars = H.require("src/shared/Config/Cars")
	local Rarity = H.require("src/shared/Config/Rarity")
	local Economy = H.require("src/shared/Config/Economy")

	t.test("Format.short", function()
		t.eq(Format.short(15), "15")
		t.eq(Format.short(1000), "1K")
		t.eq(Format.short(1500), "1.5K")
		t.eq(Format.short(150000), "150K")
		t.eq(Format.short(1234567), "1.23M")
		t.eq(Format.short(10000000), "10M")
		t.eq(Format.short(-2500), "-2.5K")
		t.eq(Format.cash(250), "$250")
	end)
	t.test("Format.clock/commas", function()
		t.eq(Format.clock(75), "1:15")
		t.eq(Format.clock(3700), "1:01:40")
		t.eq(Format.commas(1234567), "1,234,567")
		t.eq(Format.commas(123), "123")
	end)
	t.test("every car is valid", function()
		for _, def in Cars.List do
			t.ok(Rarity.Tiers[def.rarity], def.id .. " rarity")
			t.ok(def.income > 0, def.id .. " income")
			t.ok(def.topSpeed > 30 and def.topSpeed < 250, def.id .. " speed")
			t.ok(def.grip > 0 and def.grip <= 1, def.id .. " grip")
			if def.dealer then
				t.ok(def.price > 0, def.id .. " dealer price")
			end
		end
	end)
	t.test("income rises with rarity", function()
		local maxPrev = 0
		for _, rid in Rarity.Order do
			local pool = Cars.ByRarity[rid]
			if pool and rid ~= "Exclusive" then
				local minHere = math.huge
				local maxHere = 0
				for _, d in pool do
					minHere = math.min(minHere, d.income)
					maxHere = math.max(maxHere, d.income)
				end
				t.ok(minHere > maxPrev, rid .. " min income should exceed previous tier max")
				maxPrev = maxHere
			end
		end
	end)
	t.test("street rolls are mostly common and never secret", function()
		local rng = H.Random.new(42)
		local counts = {}
		for _ = 1, 20000 do
			local def = Rolls.car("street", 1, rng)
			counts[def.rarity] = (counts[def.rarity] or 0) + 1
			t.ok(def.street, "street roll returned non-street car " .. def.id)
		end
		t.ok((counts.Common or 0) > 10000, "commons dominate")
		t.ok((counts.Secret or 0) == 0, "no secrets on street")
		t.ok((counts.Legendary or 0) > 0, "legendaries possible")
	end)
	t.test("luck increases rare share", function()
		local function share(luck)
			local rng = H.Random.new(7)
			local rare = 0
			for _ = 1, 20000 do
				if Rarity.Tiers[Rolls.rarity("street", luck, rng)].order >= 3 then
					rare += 1
				end
			end
			return rare
		end
		t.ok(share(3) > share(1) * 1.8, "luck x3 should ~double+ rare share")
	end)
	t.test("mutations roll None most of the time", function()
		local rng = H.Random.new(3)
		local none = 0
		for _ = 1, 10000 do
			if Rolls.mutation(1, rng) == "None" then
				none += 1
			end
		end
		t.ok(none > 8000 and none < 9200, "None ≈86%: " .. none)
	end)
	t.test("economy math", function()
		t.eq(EconomyMath.carIncome("rustbucket", "None"), 3)
		t.eq(EconomyMath.carIncome("rustbucket", "Gold"), 6)
		t.eq(EconomyMath.sellValue("rustbucket", "None"), 60)
		t.eq(EconomyMath.rebirthCost(0), Economy.REBIRTH_BASE_COST)
		t.eq(EconomyMath.rebirthCost(1), math.floor(Economy.REBIRTH_BASE_COST * Economy.REBIRTH_COST_GROWTH))
		local m = EconomyMath.playerMultiplier({ rebirths = 2, vip = true, eventMultiplier = 1, friendsInServer = 5, inGroup = true, indexBonus = 0 })
		t.near(m, (1 + 1 + 0.3 + 0.1) * 2, 1e-9)
		t.eq(EconomyMath.upgradeValue("lock", 0), 45)
		t.eq(EconomyMath.upgradePrice("lock", 3), nil)
		t.eq(EconomyMath.indexBonus({}), 0)
	end)
	t.test("starter car exists", function()
		t.ok(Cars.get(Economy.STARTER_CAR))
	end)
end
