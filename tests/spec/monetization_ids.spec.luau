--!nocheck
-- Monetization ids (LOOP_V2 §8): the generated Config/MonetizationIds has a live id for every item in
-- tools/monetization/spec.json (and nothing else), each pass has a same-price gift product, and Config/Monetization
-- reads those ids for the v1 keys that match (retired v1 passes stay id 0, so they stay hidden).
return function(t)
	local H = t.H
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")

	local spec = serde.decode("json", fs.readFile("tools/monetization/spec.json"))
	local Ids = H.require("src/shared/Config/MonetizationIds")
	local Monetization = H.require("src/shared/Config/Monetization")

	local function tableFor(kind)
		return if kind == "pass" then Ids.passes else Ids.products
	end

	t.test("monetization ids: every spec key has a live id of the right kind", function()
		t.eq(spec.universeId, 10773288390, "Hotwire City universe")
		t.ok(#spec.items > 0, "spec has items")
		for _, item in spec.items do
			t.ok(item.kind == "pass" or item.kind == "product", "kind of " .. item.key)
			local id = tableFor(item.kind)[item.key]
			t.ok(typeof(id) == "number", "id for " .. item.kind .. " " .. item.key)
			t.ok(id > 0 and id == math.floor(id), "positive integer id for " .. item.key)
		end
	end)

	t.test("monetization ids: no stray keys and no duplicate ids", function()
		local specKeys = { pass = {}, product = {} }
		for _, item in spec.items do
			specKeys[item.kind][item.key] = true
		end
		for kind, tbl in { pass = Ids.passes, product = Ids.products } do
			local seen = {}
			for key, id in tbl do
				t.ok(specKeys[kind][key], ("%s %s is not in spec.json"):format(kind, key))
				t.ok(not seen[id], "duplicate id " .. tostring(id))
				seen[id] = true
			end
		end
	end)

	t.test("monetization ids: each pass has a gift product at the same price", function()
		local byKey = {}
		for _, item in spec.items do
			byKey[item.key] = item
		end
		for _, item in spec.items do
			if item.kind == "pass" then
				local gift = byKey["gift_" .. item.key]
				t.ok(gift ~= nil and gift.kind == "product", "gift_" .. item.key)
				t.eq(gift.price, item.price, "gift price for " .. item.key)
				t.eq(gift.giftOf, item.key)
			end
		end
	end)

	t.test("monetization ids: Config/Monetization reads matching ids, retired passes stay hidden", function()
		for key, def in Monetization.Passes do
			t.eq(def.id, Ids.passes[key] or 0, "pass " .. key)
		end
		for key, def in Monetization.Products do
			local v2 = Monetization.V1_PRODUCT_ALIASES[key] or key
			t.eq(def.id, Ids.products[v2] or 0, "product " .. key)
		end
		t.ok(Monetization.Passes.vip.id > 0 and Monetization.Products.cash_small.id > 0, "shared keys are wired")
		t.eq(Monetization.Products.lock_10.id, Ids.products.lockdown, "lock_10 reads lockdown")
		for _, retired in { "nitro", "hotwire", "taser" } do
			t.eq(Monetization.Passes[retired].id, 0, retired .. " is retired (LOOP_V2 §8.4)")
		end
	end)
end
