--!nocheck
-- Menus slice: MenuController pure helpers (name resolution, daily/contract countdowns, daily tile states, playtime
-- gift tiles, contract/upgrade/tool/index card rows + sort order, store visibility, rebirth view, settings overrides,
-- viewport camera framing) cross-checked against the server's RewardsService / RebirthService rules.
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3

	-- server-side rules we must agree with (pure helpers only)
	H.setMode("server")
	local Rewards = H.require("src/server/Systems/RewardsService")
	local Rebirth = H.require("src/server/Systems/RebirthService")

	H.setMode("client")
	local Menu = H.require("src/client/Controllers/MenuController")
	local HUD = H.require("src/client/Controllers/HUDController")
	local Economy = H.require("src/shared/Config/Economy")
	local EconomyMath = H.require("src/shared/Util/EconomyMath")
	local Cars = H.require("src/shared/Config/Cars")
	local Rarity = H.require("src/shared/Config/Rarity")
	local Monetization = H.require("src/shared/Config/Monetization")

	-- Names ----------------------------------------------------------------------------------------------------------
	t.test("menus: public API shape", function()
		for _, fn in { "open", "close", "toggle", "isOpen", "has", "getOpen", "closeAll", "init", "start" } do
			t.eq(type(Menu[fn]), "function", fn)
		end
		t.ok(Menu.Opened and Menu.Closed, "signals")
		t.eq(#Menu.NAMES, 9, "nine menus")
		for _, n in { "GearShop", "Store", "Index", "Daily", "Contracts", "Gifts", "Rebirth", "Codes", "Settings" } do
			t.eq(Menu.resolveName(n), n, n)
		end
	end)

	t.test("menus: aliases and fuzzy names resolve", function()
		t.eq(Menu.resolveName("Gear"), "GearShop")
		t.eq(Menu.resolveName("gearshop"), "GearShop")
		t.eq(Menu.resolveName("Gear Shop"), "GearShop")
		t.eq(Menu.resolveName("CarIndex"), "Index")
		t.eq(Menu.resolveName("car_index"), "Index")
		t.eq(Menu.resolveName("Playtime"), "Gifts")
		t.eq(Menu.resolveName("PlaytimeGifts"), "Gifts")
		t.eq(Menu.resolveName("SETTINGS"), "Settings")
		t.eq(Menu.resolveName("Nope"), nil)
		t.eq(Menu.resolveName(""), nil)
		t.eq(Menu.resolveName(nil), nil)
		t.eq(Menu.resolveName(42), nil)
		t.eq(Menu.has("Jobs"), true)
		t.eq(Menu.has("Garage"), false)
	end)

	t.test("menus: every HUD button opens a real menu", function()
		for _, list in { HUD.MENU, HUD.MENU_TOP_ROW } do
			for _, def in list do
				local hit = false
				for _, n in def.names do
					if Menu.has(n) then
						hit = true
					end
				end
				t.ok(hit, "HUD button " .. def.id .. " has no MenuController name")
			end
		end
	end)

	t.test("menus: unknown names never open anything (no GUI needed)", function()
		t.eq(Menu.open("Nope"), false)
		t.eq(Menu.toggle("Nope"), false)
		t.eq(Menu.close("Nope"), false)
		t.eq(Menu.close(), false, "nothing open")
		t.eq(Menu.isOpen("GearShop"), false)
		t.eq(Menu.getOpen(), nil)
	end)

	-- Countdowns -----------------------------------------------------------------------------------------------------
	t.test("menus: seconds until UTC midnight", function()
		local DAY = 20000 * 86400
		t.eq(Menu.secondsUntilUtcMidnight(DAY), 86400, "exactly midnight -> full day")
		t.eq(Menu.secondsUntilUtcMidnight(DAY + 3600), 82800)
		t.eq(Menu.secondsUntilUtcMidnight(DAY + 86399), 1)
		t.near(Menu.secondsUntilUtcMidnight(DAY + 86399.5), 0.5, 1e-6)
		t.eq(Menu.secondsUntilUtcMidnight(0 / 0), 86400, "NaN")
		for i = 1, 50 do
			local now = DAY + i * 1733.7
			local s = Menu.secondsUntilUtcMidnight(now)
			t.ok(s > 0 and s <= 86400, "range")
			t.eq(EconomyMath.dayNumber(now + s), EconomyMath.dayNumber(now) + 1, "lands on the next UTC day")
		end
	end)

	t.test("menus: hh:mm countdown rounds minutes up", function()
		t.eq(Menu.formatHhMm(82800), "23:00")
		t.eq(Menu.formatHhMm(86400), "24:00")
		t.eq(Menu.formatHhMm(3661), "01:02")
		t.eq(Menu.formatHhMm(59), "00:01")
		t.eq(Menu.formatHhMm(60), "00:01")
		t.eq(Menu.formatHhMm(61), "00:02")
		t.eq(Menu.formatHhMm(0), "00:00")
		t.eq(Menu.formatHhMm(-5), "00:00")
		t.eq(Menu.formatHhMm(0 / 0), "00:00")
	end)

	t.test("menus: duration words + multiplier text", function()
		t.eq(Menu.durationWords(300), "5 min")
		t.eq(Menu.durationWords(450), "7.5 min")
		t.eq(Menu.durationWords(1800), "30 min")
		t.eq(Menu.durationWords(3600), "1 hr")
		t.eq(Menu.durationWords(45), "45 sec")
		t.eq(Menu.formatMultiplier(1), "x1")
		t.eq(Menu.formatMultiplier(1.5), "x1.5")
		t.eq(Menu.formatMultiplier(2.25), "x2.25")
		t.eq(Menu.formatMultiplier(0 / 0), "x1")
	end)

	-- Daily ----------------------------------------------------------------------------------------------------------
	t.test("menus: daily tile states", function()
		local function eqList(a, b, msg)
			t.eq(#a, #b, msg .. " length")
			for i = 1, #b do
				t.eq(a[i], b[i], msg .. " tile " .. i)
			end
		end
		local L, C, R, N = "locked", "claimed", "ready", "next"
		eqList(Menu.dailyTileStates(nil), { L, L, L, L, L, L, L }, "no data")
		eqList(Menu.dailyTileStates({ streak = 0, canClaim = true, nextDay = 1 }), { R, L, L, L, L, L, L }, "fresh")
		eqList(
			Menu.dailyTileStates({ streak = 2, canClaim = true, nextDay = 3 }),
			{ C, C, R, L, L, L, L },
			"day 3 ready"
		)
		eqList(
			Menu.dailyTileStates({ streak = 3, canClaim = false, nextDay = 4 }),
			{ C, C, C, N, L, L, L },
			"claimed today"
		)
		eqList(
			Menu.dailyTileStates({ streak = 7, canClaim = false, nextDay = 1 }),
			{ C, C, C, C, C, C, C },
			"full week"
		)
		eqList(
			Menu.dailyTileStates({ streak = 6, canClaim = true, nextDay = 7 }),
			{ C, C, C, C, C, C, R },
			"jackpot day"
		)
		eqList(Menu.dailyTileStates({ canClaim = true, nextDay = 99 }), { C, C, C, C, C, C, R }, "clamped high")
		eqList(Menu.dailyTileStates({ canClaim = true, nextDay = "3" }), { R, L, L, L, L, L, L }, "junk nextDay")
		eqList(Menu.dailyTileStates({ canClaim = true, nextDay = 2 }, 3), { C, R, L }, "custom count")
	end)

	t.test("menus: daily tiles agree with RewardsService._dailyView for every streak", function()
		local today = 20000
		local n = #Economy.DAILY_REWARDS
		for streak = 0, 20 do
			for _, last in { today - 3, today - 1, today } do
				local view = Rewards._dailyView(streak, last, today)
				local states = Menu.dailyTileStates(view)
				local ready, claimed, nextCount = 0, 0, 0
				for i, s in states do
					if s == "ready" then
						ready += 1
						t.eq(i, view.nextDay, "ready tile is the reward the server pays")
					elseif s == "claimed" then
						claimed += 1
					elseif s == "next" then
						nextCount += 1
						t.eq(i, view.nextDay, "next tile is tomorrow's reward")
					end
				end
				local tag = ("streak %d last %d"):format(streak, today - last)
				if view.canClaim then
					t.eq(ready, 1, tag .. " one ready tile")
					t.eq(claimed, view.nextDay - 1, tag .. " earlier days claimed")
					-- the claimed reward really is the one the ready tile shows
					local ok, _, index = Rewards._dailyClaim(streak, last, today)
					t.ok(ok, tag)
					t.eq(index, view.nextDay, tag .. " claim index")
				else
					t.eq(ready, 0, tag .. " nothing ready")
					t.ok(nextCount == 1 or claimed == n, tag .. " shows tomorrow or a finished week")
				end
			end
		end
	end)

	t.test("menus: reward info", function()
		local cash = Menu.rewardInfo({ kind = "cash", amount = 1500 }, 10)
		t.eq(cash.text, "$1.5K")
		t.eq(cash.icon, "💵")
		local mins = Menu.rewardInfo({ kind = "incomeMinutes", amount = 15 }, 10)
		t.eq(mins.text, "15 MIN")
		t.eq(mins.sub, "≈ $9K", "15 min x $10/s")
		local poor = Menu.rewardInfo({ kind = "incomeMinutes", amount = 15 }, 0)
		t.eq(poor.sub, "≈ $500", "minimum payout")
		local floored = Menu.rewardInfo({ kind = "incomeMinutes", amount = 5, min = 15000 }, 10)
		t.eq(floored.sub, "≈ $15K", "the entry's own min floor (like RewardsService)")
		for _, r in Economy.DAILY_REWARDS do
			if r.kind == "incomeMinutes" then
				for _, income in { 0, 3, 250, 1e5 } do
					local server = Rewards._incomeMinutesReward(r.amount, income, r.min)
					t.eq(
						Menu.rewardInfo(r, income).sub,
						"≈ " .. H.require("src/shared/Util/Format").cash(server),
						"daily estimate"
					)
				end
			end
		end
		local car = Menu.rewardInfo({ kind = "car", rarity = "Epic" })
		t.eq(car.text, "EPIC CAR")
		t.eq(car.color, Rarity.Tiers.Epic.color)
		t.eq(Menu.rewardInfo(nil).text, "GIFT")
		t.eq(Menu.rewardInfo({ kind = "weird" }).text, "GIFT")
		for _, r in Economy.DAILY_REWARDS do
			t.ok(Menu.rewardInfo(r, 5).text ~= "GIFT", "every daily reward kind is known")
		end
		for _, r in Economy.PLAYTIME_REWARDS do
			t.ok(Menu.rewardInfo(r, 5).text ~= "GIFT", "every playtime reward kind is known")
		end
	end)

	-- Playtime gifts --------------------------------------------------------------------------------------------------
	t.test("menus: playtime gift tiles", function()
		local tiles = Menu.playtimeTiles({ claimed = {}, sessionSeconds = 0 })
		t.eq(#tiles, #Economy.PLAYTIME_REWARDS)
		for i, tile in tiles do
			t.eq(tile.state, "waiting")
			t.eq(tile.remaining, Economy.PLAYTIME_REWARDS[i].minutes * 60)
			t.eq(tile.fraction, 0)
		end
		local first = Economy.PLAYTIME_REWARDS[1].minutes * 60
		tiles = Menu.playtimeTiles({ claimed = {}, sessionSeconds = first - 10 }, 10)
		t.eq(tiles[1].state, "ready", "local seconds advance the timer")
		t.eq(tiles[2].state, "waiting")
		tiles = Menu.playtimeTiles({ claimed = { ["1"] = true }, sessionSeconds = first + 5 })
		t.eq(tiles[1].state, "claimed")
		t.eq(tiles[1].remaining, 0)
		t.near(tiles[2].remaining, Economy.PLAYTIME_REWARDS[2].minutes * 60 - first - 5, 1e-9)
		tiles = Menu.playtimeTiles(nil, -50)
		t.eq(tiles[1].state, "waiting", "junk input")
		t.eq(tiles[1].remaining, first)
	end)

	t.test("menus: a ready gift tile is always accepted by the server", function()
		local claimed = { ["2"] = true }
		for session = 0, 3700, 37 do
			for i, tile in Menu.playtimeTiles({ claimed = claimed, sessionSeconds = session }) do
				local ok, reason = Rewards._canClaimPlaytime(i, session, claimed)
				if tile.state == "ready" then
					t.ok(ok, ("tile %d at %ds: server says %s"):format(i, session, tostring(reason)))
				elseif tile.state == "claimed" then
					t.eq(reason, "claimed")
				end
			end
		end
	end)

	-- Contracts ------------------------------------------------------------------------------------------------------
	t.test("menus: contract rows text, reward, progress", function()
		local rows = Menu.contractRows({
			day = 1,
			list = {
				{ id = "steal5", progress = 2, claimed = false },
				{ id = "collect", progress = 4200, claimed = false },
				{ id = "bogus", progress = 1, claimed = false },
			},
		}, 10)
		t.eq(#rows, 2, "unknown ids skipped")
		t.eq(rows[1].id, "steal5")
		t.eq(rows[1].text, "Steal 5 cars")
		t.eq(rows[1].icon, "🚗")
		t.near(rows[1].fraction, 0.4, 1e-9)
		t.eq(rows[1].rewardCash, 3000, "300s x $10/s")
		t.eq(Menu.contractProgressText(rows[1]), "2/5")
		t.eq(rows[2].rewardCash, 3000)
		t.eq(Menu.contractProgressText(rows[2]), "$4.2K / $10K")
		local poor = Menu.contractRows({ list = { { id = "steal5", progress = 0 } } }, 0)
		t.eq(poor[1].rewardCash, 500, "minimum $500")
		local over = Menu.contractRows({ list = { { id = "drift", progress = 99 } } }, 1)
		t.eq(over[1].progress, 30, "clamped to goal")
		t.ok(over[1].done, "finished")
		t.eq(
			Menu.contractProgressText(Menu.contractRows({ list = { { id = "drift", progress = 12.7 } } })[1]),
			"12s / 30s"
		)
		t.eq(#Menu.contractRows(nil), 0)
		t.eq(#Menu.contractRows({ list = "x" }), 0)
	end)

	t.test("menus: contract card sort order (unfinished first, stable)", function()
		local rows = Menu.contractRows({
			list = {
				{ id = "rob1", progress = 1, claimed = true },
				{ id = "steal12", progress = 3, claimed = false },
				{ id = "chop2", progress = 2, claimed = false }, -- complete but not flagged yet: still "done"
				{ id = "hotdrop", progress = 0, claimed = false },
			},
		}, 5)
		local ids = {}
		for _, r in rows do
			table.insert(ids, r.id)
		end
		t.eq(table.concat(ids, ","), "steal12,hotdrop,rob1,chop2")
		t.ok(rows[3].claimed and rows[3].fraction == 1, "claimed bar is full")
		t.ok(not rows[4].claimed and rows[4].done, "completed by progress")
	end)

	t.test("menus: every contract stat has an icon", function()
		for _, def in Economy.Contracts do
			local row = Menu.contractRows({ list = { { id = def.id, progress = 0 } } })[1]
			t.ok(row and row.icon ~= "🎯", def.id .. " uses the fallback icon")
		end
	end)

	-- Gear shop ------------------------------------------------------------------------------------------------------
	t.test("menus: upgrade card order + values", function()
		local ids = Menu.upgradeIds()
		t.eq(table.concat(ids, ","), "hotwire,nitro,armor,lock")
		local rows = Menu.upgradeRows({ upgrades = { hotwire = 1, nitro = 0, armor = 3, lock = 99 } }, 12000)
		t.eq(rows[1].id, "hotwire")
		t.eq(rows[1].level, 1)
		t.eq(rows[1].price, Economy.Upgrades.hotwire.prices[2])
		t.ok(rows[1].affordable, "12K buys hotwire 2")
		t.eq(rows[1].currentText, "85%")
		t.eq(rows[1].nextText, "72%")
		t.eq(rows[2].currentText, "2.5s")
		t.eq(rows[2].nextText, "3.5s")
		t.ok(rows[2].affordable)
		t.eq(rows[3].id, "armor")
		t.ok(rows[3].maxed, "armor 3 is max")
		t.eq(rows[3].price, nil)
		t.eq(rows[3].nextText, nil)
		t.ok(not rows[3].affordable, "maxed is never buyable")
		t.eq(rows[4].level, Economy.Upgrades.lock.maxLevel, "clamped")
		t.eq(rows[4].currentText, "120s")
		local broke = Menu.upgradeRows({ upgrades = { hotwire = 0 } }, 0)
		t.ok(not broke[1].affordable, "can't afford with $0")
		local junk = Menu.upgradeRows(nil, 0 / 0)
		t.eq(#junk, 4)
		for _, r in junk do
			t.eq(r.level, 0)
			t.ok(not r.affordable)
		end
	end)

	t.test("menus: upgrade prices match EconomyMath (the server's formula)", function()
		for id, def in Economy.Upgrades do
			for level = 0, def.maxLevel do
				local row
				for _, r in Menu.upgradeRows({ upgrades = { [id] = level } }, math.huge) do
					if r.id == id then
						row = r
					end
				end
				t.eq(row.price, EconomyMath.upgradePrice(id, level), id .. " L" .. level)
			end
		end
	end)

	t.test("menus: tool cards", function()
		local rows = Menu.toolRows({ tools = { bat = true }, passes = {} }, 7000)
		t.eq(rows[1].id, "bat")
		t.ok(rows[1].owned)
		t.eq(rows[2].id, "taser")
		t.ok(not rows[2].owned and not rows[2].affordable)
		t.eq(rows[3].id, "spikes")
		t.ok(rows[3].affordable, "7K buys spikes")
		local pass = Menu.toolRows({ tools = {}, passes = { taser = true } }, 0)
		t.ok(pass[2].owned, "Zapper Pass owns the Zapper")
		t.eq(#Menu.toolRows(nil, 0), #Economy.ToolOrder)
	end)

	-- Store ----------------------------------------------------------------------------------------------------------
	t.test("menus: store hides id-0 items and shows coming soon", function()
		local saved = {}
		for key, def in Monetization.Passes do
			saved["p" .. key] = def.id
			def.id = 0
		end
		for key, def in Monetization.Products do
			saved["d" .. key] = def.id
			def.id = 0
		end
		local items = Menu.storeItems({})
		t.ok(items.comingSoon, "all zero -> coming soon")
		t.eq(#items.passes + #items.products, 0)

		Monetization.Passes.vip.id = 111
		Monetization.Passes.taser.id = 222
		Monetization.Products.server_luck.id = 333
		items = Menu.storeItems({ vip = true })
		t.ok(not items.comingSoon)
		t.eq(#items.passes, 2)
		t.eq(items.passes[1].key, "vip", "PassOrder order")
		t.eq(items.passes[2].key, "taser")
		t.ok(items.passes[1].owned and not items.passes[2].owned)
		t.eq(items.passes[1].id, 111)
		t.eq(#items.products, 1)
		t.eq(items.products[1].kind, "product")

		for key, def in Monetization.Passes do
			def.id = saved["p" .. key]
		end
		for key, def in Monetization.Products do
			def.id = saved["d" .. key]
		end
	end)

	-- Index ----------------------------------------------------------------------------------------------------------
	t.test("menus: index groups cover every car once, sorted", function()
		local groups = Menu.indexGroups({ rustbucket = true, mini_bean = true })
		local seen, count = {}, 0
		local lastOrder = 0
		for _, g in groups do
			local order = Rarity.Tiers[g.rarity].order
			t.ok(order > lastOrder, "groups follow Rarity.Order")
			lastOrder = order
			t.eq(g.total, #g.cars)
			for i, def in g.cars do
				t.eq(def.rarity, g.rarity)
				t.ok(not seen[def.id], "duplicate " .. def.id)
				seen[def.id] = true
				count += 1
				if i > 1 then
					t.ok(g.cars[i - 1].income <= def.income, "cheapest income first")
				end
			end
			t.eq(g.bonusEligible, g.rarity ~= "Exclusive")
		end
		t.eq(count, #Cars.List, "every car")
		t.eq(groups[1].rarity, "Common")
		t.eq(groups[1].found, 2)
		t.ok(not groups[1].complete)
	end)

	t.test("menus: index completion + bonus match EconomyMath", function()
		local disc = {}
		for _, def in Cars.ByRarity.Common do
			disc[def.id] = true
		end
		local groups = Menu.indexGroups(disc)
		t.ok(groups[1].complete, "all commons")
		local found, total, bonus = Menu.indexTotals(disc)
		t.eq(found, #Cars.ByRarity.Common)
		t.eq(total, #Cars.List)
		t.near(bonus, EconomyMath.indexBonus(disc), 1e-9)
		t.near(bonus, Economy.INDEX_RARITY_BONUS, 1e-9)
		local f0, _, b0 = Menu.indexTotals(nil)
		t.eq(f0, 0)
		t.eq(b0, 0)
	end)

	t.test("menus: car sources", function()
		local function has(list, s)
			return table.find(list, s) ~= nil
		end
		local rust = Menu.carSources(Cars.get("rustbucket"))
		t.ok(has(rust, "🛣️ Streets") and has(rust, "🏪 Dealer"))
		t.ok(not has(rust, "📦 Hot Drops"))
		t.ok(has(Menu.carSources(Cars.get("diamond_dragster")), "💎 Store exclusive"))
		for _, def in Cars.List do
			local src = Menu.carSources(def)
			t.ok(#src >= 1, def.id)
			if def.rarity == "Legendary" or def.rarity == "Mythic" or def.rarity == "Secret" then
				t.ok(has(src, "📦 Hot Drops"), def.id .. " can be a hot drop")
			end
		end
		t.ok(has(Menu.carSources(Cars.ByRarity.Epic[1]), "🎁 Rewards"), "Epic cars come from the daily streak")
		t.eq(Menu.rarityColor("Secret") ~= Rarity.Tiers.Secret.color, true, "Secret readable on dark panels")
	end)

	t.test("menus: viewport camera framing", function()
		local center = Vector3.new(0, 2, 0)
		local small = Menu.cameraCFrame(center, Vector3.new(6, 4, 10), 30, 0, 20)
		local big = Menu.cameraCFrame(center, Vector3.new(12, 8, 20), 30, 0, 20)
		local dSmall = (small.Position - center).Magnitude
		local dBig = (big.Position - center).Magnitude
		t.ok(dBig > dSmall * 1.9, "distance scales with size")
		t.ok((small.LookVector - (center - small.Position).Unit).Magnitude < 1e-4, "looks at the center")
		t.ok(small.Position.Z < center.Z, "yaw 0 = in front of the car (-Z)")
		t.ok(small.Position.Y > center.Y, "pitched above")
		local side = Menu.cameraCFrame(center, Vector3.new(6, 4, 10), 30, 90, 0)
		t.ok(side.Position.X > center.X + 1, "yaw 90 = right side")
		t.near((side.Position - center).Magnitude, dSmall, 1e-3, "orbit keeps distance")
		local tiny = Menu.cameraCFrame(center, Vector3.zero, 30, 0, 0)
		t.ok((tiny.Position - center).Magnitude > 0, "degenerate size still has a camera")
	end)

	-- Rebirth --------------------------------------------------------------------------------------------------------
	t.test("menus: rebirth view", function()
		local v = Menu.rebirthView(100000, 0)
		t.eq(v.cost, EconomyMath.rebirthCost(0))
		t.near(v.fraction, 100000 / v.cost, 1e-9)
		t.ok(not v.canAfford)
		t.eq(v.missing, v.cost - 100000)
		t.eq(v.multiplier, 1)
		t.eq(v.nextMultiplier, 1 + Economy.REBIRTH_INCOME_BONUS)
		local rich = Menu.rebirthView(EconomyMath.rebirthCost(2), 2)
		t.ok(rich.canAfford, "exactly the cost")
		t.eq(rich.fraction, 1)
		t.eq(rich.missing, 0)
		t.eq(rich.multiplier, Rebirth._rebirthMultiplier(2))
		t.eq(Menu.formatMultiplier(rich.nextMultiplier), Rebirth._formatMultiplier(3))
		local junk = Menu.rebirthView(0 / 0, -3)
		t.eq(junk.rebirths, 0)
		t.eq(junk.cash, 0)
	end)

	t.test("menus: best car matches RebirthService._plan", function()
		local garages = {
			{ ["1"] = { carId = "rustbucket", mutation = "None" }, ["2"] = { carId = "mini_bean", mutation = "None" } },
			{
				["1"] = { carId = "mini_bean", mutation = "None" },
				["3"] = { carId = "rustbucket", mutation = "Galaxy" },
			},
			{
				["4"] = { carId = "yellow_cab", mutation = "None" },
				["2"] = { carId = "yellow_cab", mutation = "None" },
			},
			{ ["1"] = { carId = "not_a_car", mutation = "None" }, ["5"] = { carId = "pizza_van", mutation = "Gold" } },
		}
		for i, g in garages do
			local id, mut = Menu.bestCar(g)
			local kept = Rebirth._plan(g)
			t.eq(id, kept[1].carId, "garage " .. i)
			t.eq(mut, kept[1].mutation, "garage " .. i .. " mutation")
		end
		t.eq(Menu.bestCar(nil), nil)
		t.eq(Menu.bestCar({}), nil)
	end)

	t.test("menus: kept cars match RebirthService._plan (best N regular cars, exclusives extra)", function()
		local exclusive
		for _, def in Cars.List do
			if def.rarity == "Exclusive" then
				exclusive = def.id
				break
			end
		end
		local garages = {
			{
				["1"] = { carId = "rustbucket", mutation = "None" },
				["2"] = { carId = "mini_bean", mutation = "None" },
				["3"] = { carId = "yellow_cab", mutation = "Gold" },
			},
			{
				["4"] = { carId = "yellow_cab", mutation = "None" },
				["2"] = { carId = "yellow_cab", mutation = "Gold" },
				["7"] = { carId = "rustbucket", mutation = "Galaxy" },
			},
			{ ["1"] = { carId = "not_a_car", mutation = "None" }, ["5"] = { carId = "pizza_van", mutation = "Gold" } },
		}
		if exclusive then
			table.insert(garages, {
				["1"] = { carId = exclusive, mutation = "None" },
				["2"] = { carId = "rustbucket", mutation = "None" },
				["3"] = { carId = "mini_bean", mutation = "None" },
				["4"] = { carId = "yellow_cab", mutation = "None" },
			})
		end
		for i, g in garages do
			local kept = Menu.keptCars(g)
			local plan = Rebirth._plan(g)
			t.ok(#kept <= Economy.REBIRTH_KEEP_CARS, "garage " .. i .. " limit")
			for k, car in kept do
				t.eq(car.carId, plan[k].carId, ("garage %d car %d"):format(i, k))
				t.eq(car.mutation, plan[k].mutation, ("garage %d mutation %d"):format(i, k))
			end
			for k = #kept + 1, #plan do
				t.eq(Cars.get(plan[k].carId).rarity, "Exclusive", "anything else the server keeps is an exclusive")
			end
		end
		t.eq(#Menu.keptCars(nil), 0)
		local text = Menu.keptCarsText({
			{ carId = "yellow_cab", mutation = "Gold" },
			{ carId = "rustbucket", mutation = "None" },
		})
		t.eq(text, "GOLD " .. Cars.get("yellow_cab").name .. " + " .. Cars.get("rustbucket").name)
		t.eq(Menu.keptCarsText({}), "")
	end)

	t.test("menus: store blocks what the server would refuse", function()
		local pass = { key = "vip", kind = "pass" }
		t.eq(Menu.storeBlock(pass, { passes = { vip = true } }, 0), "owned")
		t.eq(Menu.storeBlock(pass, { passes = {} }, 0), nil)
		local clear = { key = "clear_wanted", kind = "product" }
		t.eq(Menu.storeBlock(clear, {}, 0), "notWanted", "0 stars -> disabled")
		t.eq(Menu.storeBlock(clear, {}, nil), "notWanted", "no attribute -> disabled")
		t.eq(Menu.storeBlock(clear, {}, 2), nil, "wanted -> buyable")
		local dragster = { key = "diamond_dragster", kind = "product" }
		t.eq(Menu.storeBlock(dragster, { garage = {} }, 0), nil)
		t.eq(
			Menu.storeBlock(dragster, { garage = { ["5"] = { carId = "diamond_dragster" } } }, 0),
			"owned",
			"one per account"
		)
		t.eq(Menu.storeBlock({ key = "cash_small", kind = "product" }, nil, 0), nil, "cash is always buyable")
		t.eq(Menu.storeBlock(nil, nil, 0), nil)
	end)

	t.test("menus: contract swap button rules", function()
		local row = { id = "rob1", done = false }
		t.ok(Menu.canSwapContract({ list = {} }, row, true), "unused swap")
		t.ok(not Menu.canSwapContract({ list = {}, rerolled = true }, row, true), "used today")
		t.ok(not Menu.canSwapContract({ list = {} }, { id = "rob1", done = true }, true), "finished job")
		t.ok(not Menu.canSwapContract({ list = {} }, row, false), "no remote yet")
		t.ok(not Menu.canSwapContract(nil, row, true), "no snapshot")
	end)

	t.test("menus: garage busy blocks rebirth", function()
		t.ok(not Menu.garageBusy({ ["1"] = { carId = "rustbucket", state = "Parked" } }))
		t.ok(Menu.garageBusy({ ["1"] = { carId = "rustbucket", state = "Driving" } }))
		t.ok(Menu.garageBusy({ ["2"] = { carId = "rustbucket", state = "BeingStolen" } }))
		t.ok(not Menu.garageBusy(nil))
	end)

	-- Layout ---------------------------------------------------------------------------------------------------------
	t.test("menus: windows grow on phones, never on desktop, shrink only to fit", function()
		local Vector2 = H.roblox.Vector2
		local index = Vector2.new(920, 540)
		local daily = Vector2.new(760, 470)
		t.eq(Menu.windowScale(Vector2.new(1280, 720), 1, index), 1, "desktop stays 1")
		t.eq(Menu.windowScale(Vector2.new(1920, 1080), 1.5, index), 1, "1080p stays 1")
		local phone = Vector2.new(844, 390)
		local phoneScale = 0.55 -- Kit.screen clamps here
		local s = Menu.windowScale(phone, phoneScale, index)
		t.ok(s > 1.15 and s <= 1.4, "landscape phone grows the Index: " .. s)
		t.ok(index.Y * s * phoneScale <= phone.Y, "and it still fits the screen height")
		t.ok(index.X * s * phoneScale <= phone.X, "and width")
		t.eq(Menu.windowScale(phone, phoneScale, Vector2.new(540, 330)), 1.4, "small windows hit the cap")
		t.ok(Menu.windowScale(phone, phoneScale, daily) > 1.3, "daily grows")
		local portrait = Menu.windowScale(Vector2.new(400, 900), 0.55, index)
		t.ok(portrait < 1 and index.X * portrait * 0.55 <= 400, "portrait shrinks to fit: " .. portrait)
		t.eq(Menu.windowScale(phone, 0 / 0, index), Menu.windowScale(phone, 1, index), "junk ui scale")
		t.eq(Menu.windowScale(Vector2.zero, 1, index), 1, "no viewport yet")
	end)

	-- Settings -------------------------------------------------------------------------------------------------------
	t.test("menus: optimistic setting values", function()
		local settings = { music = false, sfx = true, hideHud = false, autoAccelerate = true }
		t.eq(Menu.settingValue(settings, {}, "music"), false)
		t.eq(Menu.settingValue(settings, { music = true }, "music"), true, "override wins")
		t.eq(Menu.settingValue(settings, { music = "yes" }, "music"), false, "junk override ignored")
		t.eq(Menu.settingValue(nil, nil, "music"), true, "default music on")
		t.eq(Menu.settingValue(nil, nil, "hideHud"), false, "default HUD visible")
		t.eq(Menu.settingValue({ sfx = 1 }, nil, "sfx"), true, "junk snapshot -> default")
		t.eq(Menu.settingValue(settings, nil, "autoAccelerate"), true)
	end)

	H.setMode("server")
end
