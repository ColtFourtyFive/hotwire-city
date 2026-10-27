--!nocheck
-- Events + rewards slice: daily streak math, contract rolling, playtime gifts, codes, offline earnings, rebirth reset,
-- shop quotes, event multipliers / hot drop rolls / beacon geometry, EventsClient pure helpers.
return function(t)
	local H = t.H
	H.setMode("server")
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local Color3 = H.roblox.Color3
	local Economy = H.require("src/shared/Config/Economy")
	local Events = H.require("src/shared/Config/Events")
	local EconomyMath = H.require("src/shared/Util/EconomyMath")
	local Cars = H.require("src/shared/Config/Cars")
	local Rarity = H.require("src/shared/Config/Rarity")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local Rewards = H.require("src/server/Systems/RewardsService")
	local Rebirth = H.require("src/server/Systems/RebirthService")
	local Shop = H.require("src/server/Systems/ShopService")
	local EventService = H.require("src/server/Systems/EventService")
	local Codes = H.require("src/server/Config/Codes")

	local DAY = 20000

	-- Daily streak ---------------------------------------------------------------------------------------------------
	t.test("daily: dayNumber is the UTC day", function()
		t.eq(EconomyMath.dayNumber(DAY * 86400), DAY, "midnight")
		t.eq(EconomyMath.dayNumber(DAY * 86400 + 86399), DAY, "last second")
		t.eq(EconomyMath.dayNumber((DAY + 1) * 86400), DAY + 1, "next day")
	end)

	t.test("daily: first claim ever starts a streak of 1", function()
		local ok, streak, index = Rewards._dailyClaim(0, 0, DAY)
		t.eq(ok, true, "claimable")
		t.eq(streak, 1, "streak")
		t.eq(index, 1, "reward index")
	end)

	t.test("daily: claiming the next day continues the streak", function()
		local ok, streak, index = Rewards._dailyClaim(3, DAY - 1, DAY)
		t.eq(ok, true, "claimable")
		t.eq(streak, 4, "streak")
		t.eq(index, 4, "reward index")
	end)

	t.test("daily: missing a day resets to 1", function()
		local ok, streak, index = Rewards._dailyClaim(6, DAY - 2, DAY)
		t.eq(ok, true, "claimable")
		t.eq(streak, 1, "streak reset")
		t.eq(index, 1, "reward index")
	end)

	t.test("daily: the 7-day cycle wraps", function()
		local _, s7, i7 = Rewards._dailyClaim(6, DAY - 1, DAY)
		t.eq(s7, 7, "day 7 streak")
		t.eq(i7, 7, "day 7 reward (car)")
		t.eq(Economy.DAILY_REWARDS[i7].kind, "car", "day 7 is the car")
		local _, s8, i8 = Rewards._dailyClaim(7, DAY - 1, DAY)
		t.eq(s8, 8, "streak keeps counting")
		t.eq(i8, 1, "reward index wraps to 1")
		local _, s15, i15 = Rewards._dailyClaim(14, DAY - 1, DAY)
		t.eq(s15, 15, "streak 15")
		t.eq(i15, 1, "index wraps again")
	end)

	t.test("daily: cannot claim twice the same day", function()
		local ok = Rewards._dailyClaim(5, DAY, DAY)
		t.eq(ok, false, "already claimed")
		local ok2 = Rewards._dailyClaim(5, DAY + 3, DAY) -- clock skew: last claim in the future
		t.eq(ok2, false, "future claim day")
	end)

	t.test("daily: view shows live streak + next reward", function()
		local v = Rewards._dailyView(5, DAY, DAY)
		t.eq(v.canClaim, false, "claimed today")
		t.eq(v.streak, 5, "streak")
		t.eq(v.nextDay, 6, "tomorrow is day 6")
		local v2 = Rewards._dailyView(5, DAY - 1, DAY)
		t.eq(v2.canClaim, true, "claimable")
		t.eq(v2.streak, 5, "streak alive")
		t.eq(v2.nextDay, 6, "today is day 6")
		local v3 = Rewards._dailyView(5, DAY - 2, DAY)
		t.eq(v3.canClaim, true, "claimable after a gap")
		t.eq(v3.streak, 0, "broken streak shows 0")
		t.eq(v3.nextDay, 1, "back to day 1")
		local v4 = Rewards._dailyView(7, DAY, DAY)
		t.eq(v4.nextDay, 1, "after day 7 comes day 1")
	end)

	-- Contracts ------------------------------------------------------------------------------------------------------
	local byId = {}
	for _, def in Economy.Contracts do
		byId[def.id] = def
	end

	t.test("contracts: deterministic per user + day", function()
		local a = Rewards._rollContracts(123456789, DAY)
		local b = Rewards._rollContracts(123456789, DAY)
		t.eq(#a, Economy.CONTRACTS_PER_DAY, "count")
		for i = 1, #a do
			t.eq(a[i], b[i], "same roll " .. i)
		end
	end)

	t.test("contracts: 3 unique valid ids with distinct stats, for many users/days", function()
		for user = 1, 40 do
			for day = DAY, DAY + 10 do
				local ids = Rewards._rollContracts(user * 7919, day)
				t.eq(#ids, Economy.CONTRACTS_PER_DAY, "count")
				local seen, stats = {}, {}
				for _, id in ids do
					t.ok(byId[id] ~= nil, "unknown contract " .. tostring(id))
					t.ok(not seen[id], "duplicate id " .. id)
					t.ok(not stats[byId[id].stat], "duplicate stat " .. byId[id].stat)
					seen[id] = true
					stats[byId[id].stat] = true
				end
			end
		end
	end)

	t.test("contracts: rolls vary between days", function()
		local first = table.concat(Rewards._rollContracts(42, DAY), ",")
		local different = false
		for day = DAY + 1, DAY + 6 do
			if table.concat(Rewards._rollContracts(42, day), ",") ~= first then
				different = true
			end
		end
		t.ok(different, "a week of identical contracts")
	end)

	t.test("contracts: progress completes and claims once", function()
		local list = {
			{ id = "steal5", progress = 4, claimed = false },
			{ id = "chop2", progress = 0, claimed = false },
			{ id = "nope", progress = 0, claimed = false },
		}
		local done, changed = Rewards._applyProgress(list, "steal", 1)
		t.eq(changed, true, "changed")
		t.eq(#done, 1, "one completion")
		t.eq(done[1].id, "steal5", "steal5 done")
		t.eq(list[1].claimed, true, "claimed")
		t.eq(list[1].progress, 5, "progress capped at goal")
		local done2, changed2 = Rewards._applyProgress(list, "steal", 3)
		t.eq(#done2, 0, "no double claim")
		t.eq(changed2, false, "claimed contracts don't change")
		local done3 = Rewards._applyProgress(list, "chop", 1)
		t.eq(#done3, 0, "chop2 needs 2")
		t.eq(list[2].progress, 1, "chop progress")
		local done4 = Rewards._applyProgress(list, "unknownStat", 1)
		t.eq(#done4, 0, "unknown stat ignored")
	end)

	t.test("contracts: daily swap replaces an unfinished job with a new kind of job", function()
		local r = H.Random.new(9)
		local seen = {}
		for _ = 1, 60 do
			local list = {
				{ id = "rob1", progress = 0, claimed = false },
				{ id = "steal5", progress = 2, claimed = false },
				{ id = "chop2", progress = 2, claimed = true },
			}
			local newId = Rewards._rerollContract(list, "rob1", r)
			t.ok(newId ~= nil and byId[newId] ~= nil, "valid replacement")
			t.eq(list[1].id, newId, "swapped in place")
			t.eq(list[1].progress, 0, "progress reset")
			t.eq(list[1].claimed, false, "not claimed")
			local stat = byId[newId].stat
			t.ok(stat ~= "playerSteal" and stat ~= "steal" and stat ~= "chop", "a stat nobody tracks yet: " .. stat)
			t.eq(list[2].id, "steal5", "others untouched")
			seen[newId] = true
		end
		t.ok(next(seen, next(seen)) ~= nil, "random picks vary")
		local list = { { id = "chop2", progress = 2, claimed = true }, { id = "rob1", progress = 0, claimed = false } }
		t.eq(Rewards._rerollContract(list, "chop2", r), nil, "finished contracts stay")
		t.eq(Rewards._rerollContract(list, "hotdrop", r), nil, "not in today's list")
		t.eq(Rewards._rerollContract(list, "nope", r), nil, "unknown id")
		t.eq(list[1].id, "chop2", "unchanged")
	end)

	t.test("contracts/income rewards have a $500 floor", function()
		t.eq(Rewards._contractReward(300, 0), 500, "zero income")
		t.eq(Rewards._contractReward(300, 10), 3000, "300s x $10")
		t.eq(Rewards._contractReward(300, 0 / 0), 500, "NaN income")
		t.eq(Rewards._incomeMinutesReward(15, 0), 500, "zero income minutes")
		t.eq(Rewards._incomeMinutesReward(15, 100), 90000, "15 min x $100/s")
		t.eq(Rewards._incomeMinutesReward(5, 0, 750), 750, "entry floor (min) replaces the $500 default")
		t.eq(Rewards._incomeMinutesReward(5, 100, 750), 30000, "income beats the floor")
		t.eq(Rewards._incomeMinutesReward(5, 1, 0 / 0), 500, "junk min -> default floor")
	end)

	t.test("daily/codes/playtime: every incomeMinutes entry is well-formed", function()
		local lists = { Economy.DAILY_REWARDS, Economy.PLAYTIME_REWARDS }
		local codeList = {}
		for _, def in Codes do
			table.insert(codeList, def)
		end
		table.insert(lists, codeList)
		for _, list in lists do
			for _, r in list do
				t.ok(r.kind == "cash" or r.kind == "incomeMinutes" or r.kind == "car", "kind " .. tostring(r.kind))
				if r.kind == "incomeMinutes" then
					t.ok(typeof(r.amount) == "number" and r.amount > 0, "minutes")
					t.ok(r.min == nil or (typeof(r.min) == "number" and r.min >= 0), "min floor")
				elseif r.kind == "car" then
					t.ok(Rarity.Tiers[r.rarity] ~= nil, "car rarity " .. tostring(r.rarity))
				end
			end
		end
		t.eq(Economy.DAILY_REWARDS[4].kind, "car", "day 4 is a car")
		t.eq(Economy.DAILY_REWARDS[7].kind, "car", "day 7 is a car")
		t.eq(Economy.Codes, nil, "codes are not in the replicated Economy config")
	end)

	-- Playtime -------------------------------------------------------------------------------------------------------
	t.test("playtime: validates index, minutes and claimed", function()
		local first = Economy.PLAYTIME_REWARDS[1].minutes * 60
		t.eq((Rewards._canClaimPlaytime(1, first - 5, {})), false, "too early")
		local _, why = Rewards._canClaimPlaytime(1, first - 5, {})
		t.eq(why, "early", "reason early")
		t.eq((Rewards._canClaimPlaytime(1, first, {})), true, "exactly on time")
		t.eq((Rewards._canClaimPlaytime(1, first + 100, { ["1"] = true })), false, "already claimed")
		t.eq((Rewards._canClaimPlaytime(2, first, {})), false, "gift 2 needs more minutes")
		for _, bad in { 0, -1, 1.5, "1", nil, 0 / 0, math.huge, #Economy.PLAYTIME_REWARDS + 1, {} } do
			t.eq((Rewards._canClaimPlaytime(bad, 1e9, {})), false, "bad index " .. tostring(bad))
		end
		local last = #Economy.PLAYTIME_REWARDS
		t.eq(
			(Rewards._canClaimPlaytime(last, Economy.PLAYTIME_REWARDS[last].minutes * 60, {})),
			true,
			"last gift after its minutes"
		)
	end)

	t.test("playtime: stored per UTC day, a new day starts a fresh ladder", function()
		local pt = { day = DAY, seconds = 900, claimed = { ["1"] = true } }
		local same = Rewards._playtimeFor(pt, DAY)
		t.eq(same, pt, "today's table is reused (rejoin keeps progress)")
		t.eq(same.seconds, 900, "seconds kept")
		t.eq(same.claimed["1"], true, "claims kept")
		local fresh = Rewards._playtimeFor(pt, DAY + 1)
		t.eq(fresh.day, DAY + 1, "new day")
		t.eq(fresh.seconds, 0, "seconds reset")
		t.eq(next(fresh.claimed), nil, "claims reset")
		local junk = Rewards._playtimeFor({ day = DAY, seconds = 0 / 0, claimed = "x" }, DAY)
		t.eq(junk.seconds, 0, "NaN seconds")
		t.eq(typeof(junk.claimed), "table", "claimed table")
		t.eq(Rewards._playtimeFor({ day = DAY, seconds = 1e9, claimed = {} }, DAY).seconds, Rewards.PLAYTIME_DAY_CAP)
		t.eq(Rewards._playtimeFor(nil, DAY).seconds, 0, "missing")
	end)

	t.test("referral: inviter rewards are capped per UTC day", function()
		local cap = Rewards.REFERRAL_INVITER_DAILY_CAP
		local state = nil
		for i = 1, cap do
			local ok, nextState = Rewards._referralAllowance(state, DAY, cap)
			t.eq(ok, true, "invite " .. i)
			t.eq(nextState.count, i, "count")
			state = nextState
		end
		local okOver, over = Rewards._referralAllowance(state, DAY, cap)
		t.eq(okOver, false, "over the cap")
		t.eq(over.count, cap, "count unchanged")
		local okNext, nextDay = Rewards._referralAllowance(state, DAY + 1, cap)
		t.eq(okNext, true, "a new day resets the cap")
		t.eq(nextDay.count, 1, "fresh count")
		t.eq((Rewards._referralAllowance({ day = DAY, count = 0 / 0 }, DAY, cap)), true, "junk state")
	end)

	-- Codes ----------------------------------------------------------------------------------------------------------
	t.test("codes: normalization is case + space insensitive and rejects junk", function()
		t.eq(Rewards._normalizeCode("release"), "RELEASE", "lower")
		t.eq(Rewards._normalizeCode("  ReLeAsE \n"), "RELEASE", "mixed + whitespace")
		t.eq(Rewards._normalizeCode("rel ease"), "RELEASE", "inner space")
		t.eq(Rewards._normalizeCode(""), nil, "empty")
		t.eq(Rewards._normalizeCode("   "), nil, "only spaces")
		t.eq(Rewards._normalizeCode(123), nil, "number")
		t.eq(Rewards._normalizeCode(nil), nil, "nil")
		t.eq(Rewards._normalizeCode("bad!code"), nil, "punctuation")
		t.eq(Rewards._normalizeCode(string.rep("A", 200)), nil, "too long")
		for code in Codes do
			t.eq(Rewards._normalizeCode(string.lower(code)), code, "config code " .. code)
		end
	end)

	-- Offline earnings -----------------------------------------------------------------------------------------------
	t.test("offline: amount = capped seconds x base income x rate", function()
		local garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } }
		local income = EconomyMath.carIncome("rustbucket", "None")
		t.eq((Rewards._offlineAmount(30, garage, 0, false)), 0, "under a minute")
		local amount, secs = Rewards._offlineAmount(3600, garage, 0, false)
		t.eq(secs, 3600, "seconds")
		t.eq(amount, math.floor(3600 * income * Economy.OFFLINE_RATE), "base rate")
		t.eq(
			(Rewards._offlineAmount(3600, garage, 0, true)),
			math.floor(3600 * income * Economy.VIP_OFFLINE_RATE),
			"VIP rate"
		)
		local capped, csecs = Rewards._offlineAmount(10 * 86400, garage, 0, false)
		t.eq(csecs, Economy.OFFLINE_CAP_HOURS * 3600, "cap seconds")
		t.eq(capped, math.floor(Economy.OFFLINE_CAP_HOURS * 3600 * income * Economy.OFFLINE_RATE), "capped")
		local reb = Rewards._offlineAmount(3600, garage, 2, false)
		t.eq(
			reb,
			math.floor(3600 * income * (1 + 2 * Economy.REBIRTH_INCOME_BONUS) * Economy.OFFLINE_RATE),
			"rebirth mult"
		)
		t.eq((Rewards._offlineAmount(0 / 0, garage, 0, false)), 0, "NaN elapsed")
		t.eq((Rewards._offlineAmount(-500, garage, 0, false)), 0, "negative elapsed")
	end)

	t.test("car reward fallback = half the price (mutation scaled), min $500", function()
		local def = Cars.get("hot_hatch")
		t.eq(Rewards._carFallbackCash("hot_hatch", "None"), math.max(500, math.floor(def.price * 0.5)), "half price")
		t.eq(
			Rewards._carFallbackCash("hot_hatch", "Gold"),
			math.max(500, math.floor(def.price * 0.5 * Rarity.getMutation("Gold").multiplier)),
			"gold"
		)
		t.eq(Rewards._carFallbackCash("not_a_car", "None"), 500, "unknown car")
	end)

	-- Rebirth --------------------------------------------------------------------------------------------------------
	local function bestCarIds()
		local list = table.clone(Cars.List)
		table.sort(list, function(a, b)
			return a.income > b.income
		end)
		local nonExclusive = {}
		for _, def in list do
			if def.rarity ~= "Exclusive" then
				table.insert(nonExclusive, def)
			end
		end
		return nonExclusive
	end

	-- the cars a reset should keep: top REBIRTH_KEEP_CARS non-exclusives by income (ties -> lowest slot)
	local function expectedKept(garage)
		local entries = {}
		for key, rec in garage do
			local def = Cars.get(rec.carId)
			if def and def.rarity ~= "Exclusive" then
				table.insert(
					entries,
					{ slot = tonumber(key), rec = rec, income = EconomyMath.carIncome(rec.carId, rec.mutation) }
				)
			end
		end
		table.sort(entries, function(a, b)
			if a.income ~= b.income then
				return a.income > b.income
			end
			return a.slot < b.slot
		end)
		local out = {}
		for i = 1, math.min(Economy.REBIRTH_KEEP_CARS, #entries) do
			table.insert(out, entries[i].rec)
		end
		return out
	end

	local function firstExclusive()
		for _, def in Cars.List do
			if def.rarity == "Exclusive" then
				return def
			end
		end
		return nil
	end

	t.test("rebirth: reset keeps the best REBIRTH_KEEP_CARS cars and pays out uncollected cash", function()
		local sorted = bestCarIds()
		local top, second = sorted[1], sorted[2]
		local data = {
			cash = 99999999,
			totalEarned = 1000,
			rebirths = 1,
			slotsUnlocked = 8,
			upgrades = { lock = 2, hotwire = 1, nitro = 0, armor = 3 },
			tools = { bat = true, taser = true },
			discovered = { rustbucket = true },
			garage = {
				["1"] = { carId = "rustbucket", mutation = "None", uncollected = 50 },
				["3"] = { carId = top.id, mutation = "None", uncollected = 999 },
				["6"] = { carId = second.id, mutation = "Galaxy", uncollected = 5.7 },
			},
		}
		local expect = expectedKept(data.garage)
		local kept = Rebirth._applyReset(data, Economy.START_SLOTS)
		t.eq(Economy.REBIRTH_KEEP_CARS, 2, "DECISIONS: keep the best 2")
		t.eq(data.rebirths, 2, "rebirths +1")
		t.eq(data.cash, Economy.STARTING_CASH, "cash reset")
		t.eq(data.totalEarned, 1000 + 50 + 999 + 5, "uncollected paid out (counts toward totalEarned)")
		t.eq(data.slotsUnlocked, Economy.START_SLOTS, "slots reset")
		t.eq(#kept, Economy.REBIRTH_KEEP_CARS, "best N kept")
		for i, rec in expect do
			t.eq(data.garage[tostring(i)].carId, rec.carId, "kept car " .. i)
			t.eq(data.garage[tostring(i)].mutation, rec.mutation, "kept mutation " .. i)
			t.eq(data.garage[tostring(i)].uncollected, 0, "uncollected cleared " .. i)
		end
		local n = 0
		for _ in data.garage do
			n += 1
		end
		t.eq(n, Economy.REBIRTH_KEEP_CARS, "the rest is gone")
		t.eq(data.upgrades.lock, 2, "upgrades kept")
		t.eq(data.upgrades.armor, 3, "upgrades kept")
		t.eq(data.tools.taser, true, "tools kept")
		t.eq(data.discovered.rustbucket, true, "index kept")
	end)

	t.test("rebirth: ties go to the lowest slot; empty garage keeps the starter", function()
		local g = {
			["4"] = { carId = "yellow_cab", mutation = "None", uncollected = 0 },
			["2"] = { carId = "yellow_cab", mutation = "Gold", uncollected = 0 },
			["9"] = { carId = "rustbucket", mutation = "None", uncollected = 0 },
			["7"] = { carId = "yellow_cab", mutation = "None", uncollected = 0 },
		}
		local plan = Rebirth._plan(g)
		t.eq(#plan, 2, "two kept")
		t.eq(plan[1].mutation, "Gold", "best first")
		t.eq(plan[2].carId, "yellow_cab", "then the next best")
		t.eq(plan[2].mutation, "None", "plain cab (the rustbucket earns less)")
		t.eq(#Rebirth._plan(g, 1), 1, "keep override")
		t.eq(Rebirth._plan(g, 1)[1].mutation, "Gold", "keep 1 = the best")
		local empty = Rebirth._plan({})
		t.eq(#empty, 1, "starter kept")
		t.eq(empty[1].carId, Economy.STARTER_CAR, "starter car")
		local junk = Rebirth._plan({ ["1"] = { carId = "deleted_car", mutation = "None", uncollected = 0 } })
		t.eq(junk[1].carId, Economy.STARTER_CAR, "unknown cars dropped")
	end)

	t.test("rebirth: Robux exclusives are never lost and never count toward the keep limit", function()
		local exclusive = firstExclusive()
		if not exclusive then
			return -- no exclusive cars configured
		end
		local data = {
			cash = 1e12,
			rebirths = 0,
			slotsUnlocked = 10,
			exclusives = {},
			garage = {
				["1"] = { carId = "rustbucket", mutation = "Galaxy", uncollected = 0 },
				["2"] = { carId = exclusive.id, mutation = "None", uncollected = 0 },
				["5"] = { carId = exclusive.id, mutation = "None", uncollected = 0 },
			},
		}
		local kept = Rebirth._applyReset(data, 1)
		t.eq(#kept, 3, "the regular car + both exclusives")
		t.eq(kept[1].carId, "rustbucket", "regular cars first (the exclusive doesn't take its spot)")
		local inGarage = 0
		for _ in data.garage do
			inGarage += 1
		end
		t.eq(inGarage, 1, "capacity respected")
		local pending = 0
		for key in data.exclusives do
			t.ok(key:match("^([^#]+)") == exclusive.id, "pending key format")
			pending += 1
		end
		t.eq(pending, 2, "overflow exclusives owed")

		-- 3 regular cars + 1 exclusive with room: best 2 regular + the exclusive
		local data2 = {
			cash = 1e12,
			rebirths = 0,
			exclusives = {},
			garage = {
				["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 },
				["2"] = { carId = "yellow_cab", mutation = "None", uncollected = 0 },
				["3"] = { carId = exclusive.id, mutation = "None", uncollected = 0 },
				["4"] = { carId = "yellow_cab", mutation = "Gold", uncollected = 0 },
			},
		}
		local kept2 = Rebirth._applyReset(data2, Economy.START_SLOTS)
		t.eq(#kept2, Economy.REBIRTH_KEEP_CARS + 1, "exclusive on top of the limit")
		t.eq(kept2[#kept2].carId, exclusive.id, "exclusive kept")
		t.eq(next(data2.exclusives), nil, "nothing owed")
		for _, rec in kept2 do
			t.ok(rec.carId ~= "rustbucket", "the worst regular car is dropped")
		end
	end)

	t.test("rebirth: uncollected total + kept label", function()
		t.eq(
			Rebirth._uncollectedTotal({
				["1"] = { carId = "rustbucket", mutation = "None", uncollected = 10.6 },
				["2"] = { carId = "rustbucket", mutation = "None", uncollected = 0 / 0 },
				["3"] = { carId = "rustbucket", mutation = "None", uncollected = -5 },
				["4"] = { carId = "rustbucket", mutation = "None", uncollected = math.huge },
				["5"] = { carId = "rustbucket", mutation = "None", uncollected = 4.5 },
			}),
			15,
			"junk ignored, floored"
		)
		t.eq(Rebirth._uncollectedTotal({}), 0)
		local label = Rebirth._keptLabel({
			{ carId = "yellow_cab", mutation = "Gold", uncollected = 0 },
			{ carId = "rustbucket", mutation = "None", uncollected = 0 },
		})
		t.eq(label, "GOLD " .. Cars.get("yellow_cab").name .. " + " .. Cars.get("rustbucket").name)
	end)

	t.test("rebirth: affordability + multiplier labels", function()
		local cost = EconomyMath.rebirthCost(0)
		t.eq((Rebirth._canAfford(cost - 1, 0)), false, "short by $1")
		local ok, c = Rebirth._canAfford(cost, 0)
		t.eq(ok, true, "exact cost")
		t.eq(c, cost, "cost")
		t.eq(Rebirth._formatMultiplier(1), "x1.5", "1 rebirth")
		t.eq(Rebirth._formatMultiplier(2), "x2", "2 rebirths")
	end)

	-- Shop -----------------------------------------------------------------------------------------------------------
	t.test("shop: upgrade quotes use server prices and stop at max", function()
		for id, def in Economy.Upgrades do
			for level = 0, def.maxLevel - 1 do
				local ok, price = Shop._upgradeQuote(id, level)
				t.eq(ok, true, id .. " lvl " .. level)
				t.eq(price, def.prices[level + 1], id .. " price")
			end
			local ok, why = Shop._upgradeQuote(id, def.maxLevel)
			t.eq(ok, false, id .. " maxed")
			t.eq(why, "maxed", id .. " reason")
		end
		for _, bad in { "nope", 5, nil, "__index", string.rep("x", 100) } do
			t.eq((Shop._upgradeQuote(bad, 0)), false, "bad upgrade " .. tostring(bad))
		end
	end)

	t.test("shop: tool quotes reject owned/unknown tools", function()
		t.eq((Shop._toolQuote("taser", {})), true, "taser buyable")
		local _, price = Shop._toolQuote("taser", {})
		t.eq(price, Economy.Tools.taser.price, "taser price")
		local ok, why = Shop._toolQuote("taser", { taser = true })
		t.eq(ok, false, "owned")
		t.eq(why, "owned", "reason owned")
		t.eq((Shop._toolQuote("rocket_launcher", {})), false, "unknown tool")
		t.eq((Shop._toolQuote(7, {})), false, "non-string")
	end)

	-- Events ---------------------------------------------------------------------------------------------------------
	t.test("events: luck / income / traffic multipliers", function()
		local now = 1000
		t.eq(EventService._luck(now, 0, 0), 1, "no events")
		t.eq(EventService._luck(now, now + 10, 0), 2, "server luck")
		t.eq(EventService._luck(now, 0, now + 10), Events.RUSH_HOUR_LUCK, "rush hour")
		t.eq(EventService._luck(now, now + 10, now + 10), 2 * Events.RUSH_HOUR_LUCK, "stacked")
		t.eq(EventService._luck(now, now, now), 1, "ended exactly now")
		t.eq(EventService._incomeMultiplier(now, now + 1), 2, "2x cash")
		t.eq(EventService._incomeMultiplier(now, now - 1), 1, "2x cash over")
		t.eq(EventService._trafficMultiplier(now, now + 1), Events.RUSH_HOUR_TRAFFIC_MULT, "rush traffic")
		t.eq(EventService._trafficMultiplier(now, 0), 1, "normal traffic")
	end)

	t.test("events: server luck stacks duration", function()
		t.eq(EventService._stack(0, 1000, 900), 1900, "fresh")
		t.eq(EventService._stack(1500, 1000, 900), 2400, "stacks onto remaining")
		t.eq(EventService._stack(900, 1000, 900), 1900, "expired timer restarts from now")
	end)

	t.test("events: fallback hot drop prompt rejects short, missing and stale holds", function()
		local hold = Events.HOT_DROP_HOLD
		t.eq(EventService._holdValid(nil, 100, hold), false, "no HoldBegan")
		t.eq(EventService._holdValid(100, 100 + hold, hold), true, "full hold")
		t.eq(EventService._holdValid(100, 100 + hold * 0.9, hold), true, "within tolerance")
		t.eq(EventService._holdValid(100, 100 + hold * 0.5, hold), false, "too short")
		t.eq(EventService._holdValid(100, 100 + hold / 0.9 + 1.4, hold), true, "a little slow")
		t.eq(EventService._holdValid(100, 100 + hold + 60, hold), false, "stale arm (tap long ago)")
	end)

	t.test("events: landing spot push-out", function()
		local center = Vector3.new(160, 0, 320)
		local p = EventService._pushOut(center, Vector3.new(163, 5, 320), 14)
		t.near(p.X, 174, 1e-6, "straight out along +X")
		t.near(p.Z, 320, 1e-6)
		t.eq(p.Y, 5, "height kept")
		local q = EventService._pushOut(center, Vector3.new(160, 2, 320), 14, H.Random.new(3))
		local flat = Vector3.new(q.X - center.X, 0, q.Z - center.Z).Magnitude
		t.near(flat, 14, 1e-6, "dead center -> random direction at the radius")
	end)

	t.test("events: cash bag value", function()
		t.eq(EventService._bagValue(0), 250, "min")
		t.eq(EventService._bagValue(100), 100 * Events.CASH_RAIN_BAG_SECONDS, "income scaled")
		t.eq(EventService._bagValue(0 / 0), 250, "NaN")
		t.eq(EventService._bagValue(-50), 250, "negative")
	end)

	t.test("events: name resolution", function()
		t.eq(EventService._resolveEvent("hotdrop"), "hotDrop", "hotdrop")
		t.eq(EventService._resolveEvent("hotDrop"), "hotDrop", "camel")
		t.eq(EventService._resolveEvent("Hot Drop"), "hotDrop", "spaced")
		t.eq(EventService._resolveEvent("cashrain"), "cashRain", "cashrain")
		t.eq(EventService._resolveEvent("rushhour"), "rushHour", "rushhour")
		t.eq(EventService._resolveEvent("doublecash"), "doubleCash", "doublecash")
		t.eq(EventService._resolveEvent("2x-cash"), "doubleCash", "2x-cash")
		t.eq(EventService._resolveEvent("luck"), "serverLuck", "luck")
		t.eq(EventService._resolveEvent("serverLuck"), "serverLuck", "serverLuck")
		t.eq(EventService._resolveEvent("party"), nil, "unknown")
		t.eq(EventService._resolveEvent(5), nil, "non-string")
	end)

	t.test("events: EventState only lists active events", function()
		local s =
			EventService._eventState(100, { rushHour = 150, doubleCash = 50, serverLuck = 0, cashRain = 101 }, 300)
		t.eq(s.rushHour, 150, "rush hour active")
		t.eq(s.doubleCash, nil, "2x over")
		t.eq(s.serverLuck, nil, "luck inactive")
		t.eq(s.cashRain, 101, "cash rain active")
		t.eq(s.hotDrop, 300, "hot drop live")
		local s2 = EventService._eventState(100, { rushHour = 0 }, nil)
		t.eq(next(s2), nil, "empty")
	end)

	t.test("events: hot drop rolls are Legendary+ real cars", function()
		local rng = H.Random.new(777)
		local allowed = {}
		for rarity in Events.HOT_DROP_RARITY do
			allowed[rarity] = true
		end
		local mutated = 0
		for _ = 1, 300 do
			local carId, mutation, rarity = EventService._rollHotDrop(rng)
			local def = Cars.get(carId)
			t.ok(def ~= nil, "car exists: " .. tostring(carId))
			t.eq(def.rarity, rarity, "rarity matches car")
			t.ok(def.rarity ~= "Exclusive", "never an exclusive")
			t.ok(Rarity.Tiers[rarity].order >= Rarity.Tiers.Legendary.order, "Legendary or better")
			t.ok(Rarity.Mutations[mutation] ~= nil, "valid mutation")
			if mutation ~= "None" then
				mutated += 1
			end
		end
		t.ok(mutated > 300 * 0.2, "mutation boost applied (" .. mutated .. ")")
	end)

	t.test("events: drop points never repeat back-to-back and skip blocked points", function()
		local rng = H.Random.new(5)
		local n = #MapLayout.hotDropCFrames()
		t.ok(n >= 2, "enough hot drop points")
		local last = nil
		for _ = 1, 200 do
			local i = EventService._pickDropIndex(n, last, rng)
			t.ok(i >= 1 and i <= n, "in range")
			t.ok(i ~= last, "no repeat")
			last = i
		end
		for _ = 1, 50 do
			local i = EventService._pickDropIndex(n, 1, rng, function(k)
				return k ~= 3
			end)
			t.eq(i, 3, "only unblocked point")
		end
		t.eq(EventService._pickDropIndex(1, 1, rng), 1, "single point")
	end)

	t.test("events: beacon + cash bag build with the expected parts", function()
		local cf = CFrame.new(160, 0, 320)
		local beacon = EventService._buildBeacon(cf, Color3.fromRGB(255, 60, 90), "MYTHIC • Test")
		for _, name in { "Pillar", "Core", "Ring", "RingInner", "Glow", "Label" } do
			local p = beacon:FindFirstChild(name)
			t.ok(p and p:IsA("BasePart"), "beacon part " .. name)
			t.eq(p.Anchored, true, name .. " anchored")
			t.eq(p.CanCollide, false, name .. " non-collide")
		end
		local pillar = beacon.Pillar
		local top = pillar.CFrame.Position.Y + pillar.Size.X / 2
		local bottom = pillar.CFrame.Position.Y - pillar.Size.X / 2
		t.near(top, EventService.BEACON_HEIGHT, 1e-3, "beam reaches the sky")
		t.near(bottom, EventService.BEACON_GAP, 1e-3, "beam hovers above the car")
		t.near(pillar.CFrame.RightVector.Y, 1, 1e-3, "cylinder axis is vertical")
		t.ok(beacon.Glow:FindFirstChildOfClass("PointLight") ~= nil, "light")
		t.ok(beacon.Label:FindFirstChild("BeaconGui") ~= nil, "billboard")
		local bag = EventService._buildBag(Vector3.new(0, 50, 0))
		t.eq(bag.Name, "CashBag", "bag name")
		t.eq(bag.Anchored, false, "bag falls")
		t.eq(bag.CanTouch, true, "bag touchable")
		t.ok(bag:FindFirstChild("BagGui") ~= nil, "bag billboard")
		t.ok(bag:FindFirstChild("Tie") ~= nil and bag:FindFirstChild("Top") ~= nil, "bag tie + top")
	end)

	-- Stateful flows with injected fakes ---------------------------------------------------------------------------
	local Net = H.require("src/shared/Net")
	local savedNet = { fireClient = Net.fireClient, fireNear = Net.fireNear, fireAll = Net.fireAll }
	local sent = {}
	Net.fireClient = function(name, _player, ...)
		table.insert(sent, { name = name, args = { ... } })
	end
	Net.fireNear = function(name, _pos, _radius, ...)
		table.insert(sent, { name = name, args = { ... } })
	end
	Net.fireAll = function(name, ...)
		table.insert(sent, { name = name, args = { ... } })
	end
	local function sentNamed(name)
		local out = {}
		for _, s in sent do
			if s.name == name then
				table.insert(out, s)
			end
		end
		return out
	end

	local attrs = {}
	local player = {
		Name = "Tester",
		DisplayName = "Tester",
		UserId = 4242,
		Parent = nil,
		Character = nil,
		SetAttribute = function(_, k, v)
			attrs[k] = v
		end,
		GetAttribute = function(_, k)
			return attrs[k]
		end,
		IsA = function(_, cls)
			return cls == "Player" or cls == "Instance"
		end,
	}
	local data
	local cashLog = {}
	local function freshData()
		cashLog = {}
		return {
			cash = 1000,
			totalEarned = 0,
			rebirths = 0,
			slotsUnlocked = 6,
			garage = {
				["1"] = { carId = "rustbucket", mutation = "None", uncollected = 10 },
				["2"] = { carId = "yellow_cab", mutation = "Gold", uncollected = 0 },
			},
			discovered = {},
			upgrades = { lock = 0, hotwire = 0, nitro = 0, armor = 0 },
			tools = { bat = true },
			stats = { steals = 0, playerSteals = 0, busted = 0, hotDrops = 0, timesRobbed = 0 },
			daily = { streak = 0, lastClaimDay = 0 },
			codes = {},
			contracts = { day = 0, list = {} },
			exclusives = {},
			referralRewarded = false,
		}
	end
	local fakeData = {
		isLoaded = function()
			return true
		end,
		get = function()
			return data
		end,
		markDirty = function() end,
		addCash = function(_p, amount, reason)
			data.cash += amount
			table.insert(cashLog, { amount = amount, reason = reason })
			return data.cash
		end,
		spendCash = function(_p, amount)
			if data.cash < amount then
				return false
			end
			data.cash -= amount
			return true
		end,
	}
	local slotStates = {}
	local fakeIncome = 10
	local fakeGarage = {
		incomePerSec = function()
			return fakeIncome
		end,
		getSlotState = function(_p, slot)
			return slotStates[slot] or "Parked"
		end,
		removeSlot = function(_p, slot)
			local rec = data.garage[tostring(slot)]
			data.garage[tostring(slot)] = nil
			return rec
		end,
		storeCar = function(_p, carId, mutation)
			for i = 1, data.slotsUnlocked do
				if not data.garage[tostring(i)] then
					data.garage[tostring(i)] = { carId = carId, mutation = mutation, uncollected = 0 }
					return true, i
				end
			end
			return false, "full"
		end,
		discover = function(_p, carId)
			data.discovered[carId] = true
			return true
		end,
		refresh = function() end,
	}
	for _, svc in { Rewards, Rebirth, Shop } do
		svc._inject("DataService", fakeData)
		svc._inject("GarageService", fakeGarage)
		svc._inject("MonetizationService", {
			hasPass = function()
				return false
			end,
		})
		svc._inject("PlotService", {
			getPlotIndex = function()
				return nil
			end,
		})
	end

	local today = EconomyMath.dayNumber(os.time())

	t.test("flow: claimDaily pays the streak reward once per day", function()
		data = freshData()
		data.daily = { streak = 2, lastClaimDay = today - 1 }
		local ok = Rewards.claimDaily(player)
		t.eq(ok, true, "claimed")
		t.eq(data.daily.streak, 3, "streak 3")
		t.eq(data.daily.lastClaimDay, today, "last claim today")
		local r3 = Economy.DAILY_REWARDS[3]
		t.eq(cashLog[1].amount, Rewards._incomeMinutesReward(r3.amount, 10, r3.min), "day 3 reward")
		t.eq(cashLog[1].reason, "daily", "reason")
		local again = Rewards.claimDaily(player)
		t.eq(again, false, "second claim refused")
		t.eq(#cashLog, 1, "paid once")
		local view = Rewards.getDailyView(player)
		t.eq(view.canClaim, false, "view: claimed")
		t.eq(view.nextDay, 4, "view: tomorrow is day 4")
	end)

	t.test("flow: incomeMinutes daily reward scales with income, floored by its min", function()
		local r5 = Economy.DAILY_REWARDS[5]
		t.eq(r5.kind, "incomeMinutes", "day 5 is income minutes")
		data = freshData()
		data.daily = { streak = 4, lastClaimDay = today - 1 } -- next is day 5
		fakeIncome = 1
		Rewards.claimDaily(player)
		t.eq(cashLog[1].amount, r5.min, "poor player gets the floor")
		data = freshData()
		data.daily = { streak = 4, lastClaimDay = today - 1 }
		fakeIncome = 1000
		Rewards.claimDaily(player)
		t.eq(cashLog[1].amount, r5.amount * 60 * 1000, "minutes x income")
		fakeIncome = 10
	end)

	t.test("flow: day-7 car reward goes into the garage", function()
		data = freshData()
		data.daily = { streak = 6, lastClaimDay = today - 1 }
		local before = 0
		for _ in data.garage do
			before += 1
		end
		Rewards.claimDaily(player)
		local after = 0
		local newCar
		for key, rec in data.garage do
			after += 1
			if key ~= "1" and key ~= "2" then
				newCar = rec
			end
		end
		t.eq(after, before + 1, "car stored")
		t.eq(Cars.get(newCar.carId).rarity, "Epic", "epic car")
		t.eq(data.discovered[newCar.carId], true, "discovered")
	end)

	t.test("flow: car reward falls back to cash when the garage is full", function()
		data = freshData()
		data.slotsUnlocked = 2 -- both slots occupied
		data.daily = { streak = 6, lastClaimDay = today - 1 }
		Rewards.claimDaily(player)
		t.eq(#cashLog, 1, "cash fallback paid")
		t.ok(cashLog[1].amount >= 500, "fallback amount")
	end)

	t.test("flow: codes redeem once, case-insensitively", function()
		data = freshData()
		local ok = Rewards.redeemCode(player, "  release ")
		t.eq(ok, true, "redeemed")
		t.eq(
			cashLog[1].amount,
			Rewards._incomeMinutesReward(Codes.RELEASE.amount, 10, Codes.RELEASE.min),
			"code reward (income minutes)"
		)
		t.eq(data.codes.RELEASE, true, "remembered")
		local ok2, why = Rewards.redeemCode(player, "RELEASE")
		t.eq(ok2, false, "second use refused")
		t.eq(why, "used", "reason")
		local ok3, why3 = Rewards.redeemCode(player, "NOTACODE")
		t.eq(ok3, false, "invalid")
		t.eq(why3, "invalid", "reason invalid")
		t.eq(#cashLog, 1, "paid once")
	end)

	t.test("flow: contracts roll for today and auto-claim on completion", function()
		data = freshData()
		local view = Rewards.getContractsView(player)
		t.eq(view.day, today, "rolled for today")
		t.eq(#view.list, Economy.CONTRACTS_PER_DAY, "3 contracts")
		local first = byId[view.list[1].id]
		Rewards.progress(player, first.stat, first.goal - 1)
		t.eq(#cashLog, 0, "not done yet")
		Rewards.progress(player, first.stat, 5)
		t.eq(#cashLog, 1, "auto-claimed")
		t.eq(cashLog[1].amount, math.max(500, first.reward * 10), "reward seconds x income")
		t.eq(data.contracts.list[1].claimed, true, "claimed flag")
		Rewards.progress(player, first.stat, 5)
		t.eq(#cashLog, 1, "no double pay")
		Rewards.progress(player, first.stat, 0 / 0)
		Rewards.progress(player, first.stat, -5)
		Rewards.progress(player, 5, 1)
		t.eq(#cashLog, 1, "junk progress ignored")
	end)

	t.test("flow: playtime gift needs today's minutes (stored across sessions)", function()
		data = freshData()
		local ok, why = Rewards.claimPlaytime(player, 1)
		t.eq(ok, false, "too early in a fresh session")
		t.eq(why, "early", "reason")
		local view = Rewards.getPlaytimeView(player)
		t.eq(next(view.claimed), nil, "nothing claimed")
		t.ok(view.sessionSeconds >= 0, "session seconds")

		-- minutes banked earlier today (another session) count after a rejoin
		local first = Economy.PLAYTIME_REWARDS[1]
		data.playtime = { day = today, seconds = first.minutes * 60, claimed = {} }
		local ok2 = Rewards.claimPlaytime(player, 1)
		t.eq(ok2, true, "claimable with stored seconds")
		t.eq(data.playtime.claimed["1"], true, "claim persisted in data.playtime")
		t.eq(cashLog[1].amount, Rewards._incomeMinutesReward(first.amount, 10, first.min), "gift amount")
		local ok3, why3 = Rewards.claimPlaytime(player, 1)
		t.eq(ok3, false, "once per day")
		t.eq(why3, "claimed", "reason claimed")
		local view2 = Rewards.getPlaytimeView(player)
		t.eq(view2.claimed["1"], true, "view shows the claim")
		t.ok(view2.sessionSeconds >= first.minutes * 60, "view shows today's seconds")

		-- yesterday's seconds don't count today
		data.playtime = { day = today - 1, seconds = 999999, claimed = { ["2"] = true } }
		local ok4, why4 = Rewards.claimPlaytime(player, 1)
		t.eq(ok4, false, "new day, new ladder")
		t.eq(why4, "early", "reason")
		t.eq(data.playtime.day, today, "rolled over to today")
		t.eq(data.playtime.claimed["2"], nil, "yesterday's claims cleared")
	end)

	t.test("flow: one free contract swap per day", function()
		data = freshData()
		local view = Rewards.getContractsView(player)
		t.eq(view.rerolled, false, "swap available")
		local oldId = view.list[1].id
		local okBad, whyBad = Rewards.rerollContract(player, "nope")
		t.eq(okBad, false, "unknown id")
		t.eq(whyBad, "invalid")
		local ok, newId = Rewards.rerollContract(player, oldId)
		t.eq(ok, true, "swapped")
		t.ok(newId ~= oldId, "a different contract")
		t.eq(data.contracts.list[1].id, newId, "stored")
		t.eq(data.contracts.rerolled, true, "flag set")
		t.eq(Rewards.getContractsView(player).rerolled, true, "view flag")
		local ok2, why2 = Rewards.rerollContract(player, data.contracts.list[2].id)
		t.eq(ok2, false, "only once a day")
		t.eq(why2, "used")
	end)

	t.test("flow: rebirth resets the garage through GarageService", function()
		data = freshData()
		data.cash = EconomyMath.rebirthCost(0)
		data.upgrades.hotwire = 2
		data.garage["3"] = { carId = "rustbucket", mutation = "None", uncollected = 7 }
		slotStates = {}
		local ok = Rebirth.rebirth(player)
		t.eq(ok, true, "rebirthed")
		t.eq(data.rebirths, 1, "rebirths")
		t.eq(data.cash, Economy.STARTING_CASH, "cash reset")
		t.eq(data.slotsUnlocked, Economy.START_SLOTS, "slots reset")
		t.eq(data.garage["1"].carId, "yellow_cab", "best car (Gold cab) kept in slot 1")
		t.eq(data.garage["2"].carId, "rustbucket", "2nd best kept (ties -> lowest slot)")
		t.eq(data.garage["3"], nil, "others gone")
		t.eq(cashLog[1].amount, 10 + 7, "uncollected garage cash paid out first")
		t.eq(cashLog[1].reason, "rebirth", "payout reason")
		t.eq(data.upgrades.hotwire, 2, "upgrades kept")
		t.eq(player:GetAttribute("Rebirths"), 1, "attribute")
		t.ok(#sentNamed("Announce") > 0, "announced")
	end)

	t.test("flow: rebirth refuses when broke or while a car is out", function()
		data = freshData()
		data.cash = EconomyMath.rebirthCost(0) - 1
		local ok, why = Rebirth.rebirth(player)
		t.eq(ok, false, "broke")
		t.eq(why, "cash", "reason cash")
		data.cash = EconomyMath.rebirthCost(0)
		slotStates = { [2] = "Driving" }
		local ok2, why2 = Rebirth.rebirth(player)
		t.eq(ok2, false, "car out")
		t.eq(why2, "blocked", "reason blocked")
		t.eq(data.rebirths, 0, "nothing changed")
		slotStates = {}
	end)

	t.test("flow: shop upgrades + tools charge server prices", function()
		data = freshData()
		data.cash = 1e9
		local ok = Shop.buyUpgrade(player, "hotwire")
		t.eq(ok, true, "bought upgrade")
		t.eq(data.upgrades.hotwire, 1, "level 1")
		t.eq(data.cash, 1e9 - Economy.Upgrades.hotwire.prices[1], "charged")
		local okT = Shop.buyTool(player, "spikes")
		t.eq(okT, true, "bought tool")
		t.eq(data.tools.spikes, true, "owned")
		local okT2, whyT2 = Shop.buyTool(player, "spikes")
		t.eq(okT2, false, "already owned")
		t.eq(whyT2, "owned", "reason")
		data.cash = 0
		local okU, whyU = Shop.buyUpgrade(player, "armor")
		t.eq(okU, false, "broke")
		t.eq(whyU, "cash", "reason cash")
		t.eq(data.upgrades.armor, 0, "no level")
		local okBad = Shop.buyUpgrade(player, { "hotwire" })
		t.eq(okBad, false, "table id rejected")
		data.upgrades.lock = Economy.Upgrades.lock.maxLevel
		data.cash = 1e12
		local okMax, whyMax = Shop.buyUpgrade(player, "lock")
		t.eq(okMax, false, "maxed")
		t.eq(whyMax, "maxed", "reason maxed")
	end)

	for _, svc in { Rewards, Rebirth, Shop } do
		for _, name in { "DataService", "GarageService", "MonetizationService", "PlotService" } do
			svc._inject(name, nil)
		end
	end
	Net.fireClient, Net.fireNear, Net.fireAll = savedNet.fireClient, savedNet.fireNear, savedNet.fireAll

	-- EventsClient pure helpers ------------------------------------------------------------------------------------
	H.setMode("client")
	local okClient, EventsClient = pcall(H.require, "src/client/Controllers/EventsClient")
	t.test("EventsClient loads headlessly", function()
		t.ok(okClient, "require failed: " .. tostring(EventsClient))
	end)
	if okClient then
		t.test("EventsClient: pill text", function()
			t.eq(EventsClient.pillText("rushHour", 72), "🚦 RUSH HOUR 1:12", "rush hour")
			t.eq(EventsClient.pillText("doubleCash", 240.2), "💸 2X CASH 4:01", "2x cash rounds up")
			t.eq(EventsClient.pillText("serverLuck", 750), "🍀 SERVER LUCK x2 12:30", "luck")
			t.eq(EventsClient.pillText("cashRain", 30), "💰 CASH RAIN @ PLAZA", "cash rain has no timer")
			t.eq(EventsClient.pillText("nope", 30), nil, "unknown")
		end)
		t.test("EventsClient: hot drop phases", function()
			local pos = Vector3.new(1, 2, 3)
			t.eq(EventsClient.hotDropPhase({ active = false }, 100), "none", "idle")
			t.eq(EventsClient.hotDropPhase({ active = false, startsAt = 110, position = pos }, 100), "countdown", "cd")
			t.eq(EventsClient.hotDropPhase({ active = true, endsAt = 200, position = pos }, 100), "live", "live")
			t.eq(EventsClient.hotDropPhase({ active = true, endsAt = 50, position = pos }, 100), "none", "stale live")
			t.eq(EventsClient.hotDropPhase({ active = false, startsAt = 10, position = pos }, 100), "none", "stale cd")
			t.eq(EventsClient.hotDropPhase(nil, 100), "none", "nil")
		end)
		t.test("EventsClient: car text + rarity color", function()
			local text = EventsClient.carText("rustbucket", "Gold")
			t.ok(text:find("COMMON", 1, true) ~= nil and text:find("GOLD Rustbucket", 1, true) ~= nil, text)
			t.eq(EventsClient.carText(nil, nil), "MYSTERY CAR", "unknown")
			t.ok(typeof(EventsClient.rarityColor("rustbucket")) == "Color3", "color")
		end)
	end
	H.setMode("server")
end
