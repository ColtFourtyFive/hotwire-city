--!nocheck
-- DataService pure pipeline (template / migrate / reconcile / sanitize / locks), Monetization receipt
-- idempotency, Leaderboard score encoding + merge, Admin command parsing, and board UI construction.
return function(t)
	local H = t.H
	local DataService = H.require("src/server/Systems/DataService")
	local Monetization = H.require("src/server/Systems/MonetizationService")
	local Leaderboard = H.require("src/server/Systems/LeaderboardService")
	local Admin = H.require("src/server/Systems/AdminService")
	local Economy = H.require("src/shared/Config/Economy")
	local MonetizationConfig = H.require("src/shared/Config/Monetization")

	local NOW = 1_800_000_000

	-- template ------------------------------------------------------------------------------------------
	t.test("template matches SPEC §5 defaults", function()
		local d = DataService._template()
		t.eq(d.version, DataService.SCHEMA_VERSION, "version")
		t.eq(d.cash, Economy.STARTING_CASH, "cash")
		t.eq(d.slotsUnlocked, Economy.START_SLOTS, "slots")
		t.eq(d.garage["1"].carId, Economy.STARTER_CAR, "starter car")
		t.eq(d.garage["1"].mutation, "None", "starter mutation")
		t.eq(d.garage["1"].uncollected, 0, "uncollected")
		t.ok(d.discovered[Economy.STARTER_CAR], "starter discovered")
		t.eq(d.upgrades.lock + d.upgrades.hotwire + d.upgrades.nitro + d.upgrades.armor, 0, "upgrades 0")
		t.ok(d.tools.bat, "bat owned")
		t.eq(d.settings.music, true)
		t.eq(d.settings.sfx, true)
		t.eq(d.settings.hideHud, false)
		t.eq(d.settings.autoAccelerate, false)
		t.eq(d.contracts.day, 0)
		t.eq(#d.contracts.list, 0)
		t.eq(#d.receipts, 0)
		t.eq(d.tutorialDone, false)
		-- fresh table every call
		d.garage["1"] = nil
		t.ok(DataService._template().garage["1"], "template not shared between calls")
	end)

	t.test("prepare(nil) builds a new player with lastOnline = now", function()
		local d, isNew = DataService._prepare(nil, NOW)
		t.ok(isNew, "isNew")
		t.eq(d.lastOnline, NOW, "no offline earnings for new players")
		t.eq(d.garage["1"].carId, Economy.STARTER_CAR)
	end)

	-- reconcile ---------------------------------------------------------------------------------------------
	t.test("reconcile fills missing keys without touching existing ones", function()
		local d = {
			version = 1,
			cash = 12345,
			garage = { ["3"] = { carId = "rustbucket", mutation = "Gold", uncollected = 50 } },
			settings = { music = false },
			stats = { steals = 7 },
			customField = "keep me",
		}
		DataService._reconcile(d)
		t.eq(d.cash, 12345, "cash kept")
		t.eq(d.settings.music, false, "existing setting kept")
		t.eq(d.settings.sfx, true, "missing setting filled")
		t.eq(d.stats.steals, 7, "stat kept")
		t.eq(d.stats.busted, 0, "missing stat filled")
		t.eq(d.customField, "keep me", "unknown fields preserved")
		t.ok(d.upgrades and d.upgrades.lock == 0, "upgrades filled")
		t.ok(d.garage["3"], "existing garage kept")
		t.eq(d.garage["1"], nil, "returning players do NOT get a free starter car merged in")
	end)

	t.test("reconcile replaces wrong-typed fields", function()
		local d = { cash = "lots", settings = "nope", garage = 5 }
		DataService._reconcile(d)
		t.eq(d.cash, Economy.STARTING_CASH)
		t.eq(typeof(d.settings), "table")
		t.eq(typeof(d.garage), "table")
	end)

	-- migrate -------------------------------------------------------------------------------------------------
	t.test("migrate stamps version and runs steps in order", function()
		local d = DataService._migrate({ cash = 1 })
		t.eq(d.version, DataService.SCHEMA_VERSION, "unversioned -> current")
		local newer = DataService._migrate({ version = DataService.SCHEMA_VERSION + 3 })
		t.eq(newer.version, DataService.SCHEMA_VERSION + 3, "never downgrades newer data")

		-- simulate a future migration chain on a copy of the table
		local M = DataService._MIGRATIONS
		local saved = M[1]
		local ran = false
		M[1] = function(x)
			ran = true
			x.migratedField = true
			return x
		end
		local old = DataService.SCHEMA_VERSION
		-- only exercise if schema is >1; otherwise check the step is not run for current data
		local r = DataService._migrate({ version = 1 })
		if old > 1 then
			t.ok(ran and r.migratedField, "v1 -> v2 step ran")
		else
			t.ok(not ran, "no step runs when already current")
		end
		M[1] = saved
	end)

	-- sanitize ------------------------------------------------------------------------------------------------
	t.test("sanitize removes NaN / inf / negatives and bad shapes", function()
		local nan = 0 / 0
		local raw = {
			version = 1,
			cash = nan,
			totalEarned = math.huge,
			rebirths = -3.7,
			slotsUnlocked = 999,
			garage = {
				["1"] = { carId = "rustbucket", mutation = "Bogus", uncollected = -math.huge },
				["2"] = { carId = "not_a_car", mutation = "Gold", uncollected = 10 },
				["99"] = { carId = "rustbucket", mutation = "None", uncollected = 0 },
				[3] = { carId = "rustbucket", mutation = "Gold", uncollected = nan },
				junk = "x",
			},
			upgrades = { lock = 99, hotwire = -1, nitro = 2.6, armor = nan },
			tools = { bat = false, taser = true, laserGun = true },
			stats = { steals = nan, busted = 4 },
			receipts = {},
			lastOnline = NOW + 100000,
			settings = { music = "yes", sfx = false },
			contracts = { day = 5, list = { { id = "steal5", progress = nan, claimed = 1 }, "garbage" } },
			discovered = { rustbucket = true, foo = "bar" },
			deep = { nested = { value = math.huge } },
		}
		for i = 1, 80 do
			table.insert(raw.receipts, "r" .. i)
		end
		local d = DataService._prepare(raw, NOW)
		t.eq(d.cash, 0, "NaN cash -> 0")
		t.eq(d.totalEarned, 0, "inf earned -> 0")
		t.eq(d.rebirths, 0, "negative rebirths clamped")
		t.eq(d.slotsUnlocked, Economy.MAX_SLOTS + Economy.PASS_EXTRA_SLOTS, "slots clamped")
		t.eq(d.garage["1"].mutation, "None", "bad mutation -> None")
		t.eq(d.garage["1"].uncollected, 0, "bad uncollected -> 0")
		t.eq(d.garage["2"], nil, "unknown car removed from garage")
		t.eq(d.retiredCars[1].carId, "not_a_car", "unknown car kept in retiredCars")
		t.eq(d.garage["99"], nil, "out-of-range slot dropped")
		t.eq(d.garage["3"].mutation, "Gold", "numeric key normalized to string")
		t.eq(d.garage["3"].uncollected, 0)
		t.eq(d.garage.junk, nil)
		t.eq(d.upgrades.lock, Economy.Upgrades.lock.maxLevel, "upgrade clamped to max")
		t.eq(d.upgrades.hotwire, 0)
		t.eq(d.upgrades.nitro, 2)
		t.eq(d.upgrades.armor, 0)
		t.ok(d.tools.bat, "bat always owned")
		t.ok(d.tools.taser, "known tool kept")
		t.eq(d.tools.laserGun, nil, "unknown tool dropped")
		t.eq(d.stats.steals, 0)
		t.eq(d.stats.busted, 4)
		t.eq(#d.receipts, DataService.RECEIPT_CAP, "receipts capped")
		t.eq(d.receipts[#d.receipts], "r80", "newest receipts kept")
		t.eq(d.lastOnline, NOW, "future lastOnline clamped")
		t.eq(d.settings.music, true, "bad setting -> default")
		t.eq(d.settings.sfx, false)
		t.eq(#d.contracts.list, 1, "malformed contract dropped")
		t.eq(d.contracts.list[1].progress, 0)
		t.eq(d.contracts.list[1].claimed, false)
		t.eq(d.discovered.foo, nil)
		t.eq(d.deep.nested.value, 0, "deep inf scrubbed")
	end)

	t.test("serialize is JSON-safe and stamps lastOnline", function()
		local d = DataService._prepare(nil, NOW)
		d.weird = { fn = function() end, inst = H.roblox.Instance.new("Folder"), n = 0 / 0 }
		local s = DataService._serialize(d, NOW + 5)
		t.eq(s.lastOnline, NOW + 5)
		t.eq(s.weird.fn, nil)
		t.eq(s.weird.inst, nil)
		t.eq(s.weird.n, 0)
		t.eq(d.lastOnline, NOW, "live table untouched")
		t.ok(s.garage ~= d.garage, "deep copy")
	end)

	t.test("unpackRecord handles wrapped, legacy and empty values", function()
		local data, lock = DataService._unpackRecord({ data = { cash = 1 }, lock = { session = "a" } })
		t.eq(data.cash, 1)
		t.eq(lock.session, "a")
		local legacy = DataService._unpackRecord({ cash = 5, garage = {} })
		t.eq(legacy.cash, 5)
		t.eq(DataService._unpackRecord(nil), nil)
	end)

	t.test("lockState: free / ours / held / stale", function()
		local function active(s)
			return s == "live-session"
		end
		local ls = DataService._lockState
		t.eq(ls(nil, NOW, "job", "me", active), "free")
		t.eq(ls({ jobId = "job", session = "me", time = NOW }, NOW, "job", "me", active), "ours")
		t.eq(ls({ jobId = "other", session = "x", time = NOW - 30 }, NOW, "job", "me", active), "held")
		t.eq(ls({ jobId = "other", session = "x", time = NOW - 301 }, NOW, "job", "me", active), "stale")
		-- same server, session no longer alive here -> safe to take immediately
		t.eq(ls({ jobId = "job", session = "dead", time = NOW - 5 }, NOW, "job", "me", active), "stale")
		-- same server, session still alive (mid-release) -> must wait
		t.eq(ls({ jobId = "job", session = "live-session", time = NOW - 5 }, NOW, "job", "me", active), "held")
		-- Studio JobId "" never short-circuits
		t.eq(ls({ jobId = "", session = "dead", time = NOW - 5 }, NOW, "", "me", active), "held")
	end)

	-- monetization --------------------------------------------------------------------------------------------
	t.test("receipt idempotency", function()
		local receipts = {}
		t.eq(Monetization._receiptAction(receipts, "p1", {}), "grant")
		t.ok(Monetization._recordReceipt(receipts, "p1", 3), "first record")
		t.ok(not Monetization._recordReceipt(receipts, "p1", 3), "duplicate not recorded")
		t.eq(#receipts, 1)
		t.eq(Monetization._receiptAction(receipts, "p1", {}), "alreadyGranted")
		t.eq(Monetization._receiptAction(receipts, "p1", { p1 = true }), "confirmSave")
		for i = 2, 5 do
			Monetization._recordReceipt(receipts, "p" .. i, 3)
		end
		t.eq(#receipts, 3, "capped")
		t.eq(receipts[1], "p3", "oldest dropped first")
		t.ok(Monetization._hasReceipt(receipts, "p5"))
		t.ok(not Monetization._hasReceipt(receipts, "p1"))
	end)

	t.test("cash product amounts are income-scaled with minimums", function()
		t.eq(Monetization._cashAmount("cash_small", 0), 5000)
		t.eq(Monetization._cashAmount("cash_small", 100), 60000)
		t.eq(Monetization._cashAmount("cash_big", 3), 50000)
		t.eq(Monetization._cashAmount("cash_big", 100), 360000)
		t.eq(Monetization._cashAmount("cash_small", 0 / 0), 5000, "NaN income safe")
		t.eq(Monetization._cashAmount("nope", 100), 0)
	end)

	t.test("pass/product id helpers + every product has a built-in handler", function()
		t.eq(Monetization.passIdFor("vip"), MonetizationConfig.Passes.vip.id)
		t.eq(Monetization.passIdFor("nope"), 0)
		t.eq(Monetization.productIdFor("cash_small"), MonetizationConfig.Products.cash_small.id)
		Monetization.init()
		local registered = {}
		local original = Monetization.registerProduct
		-- re-run built-ins through a spy to list keys
		Monetization.registerProduct = function(key, fn)
			registered[key] = true
			original(key, fn)
		end
		Monetization.init()
		Monetization.registerProduct = original
		for key in MonetizationConfig.Products do
			t.ok(registered[key], "handler for " .. key)
		end
	end)

	-- leaderboard ---------------------------------------------------------------------------------------------
	t.test("leaderboard log encoding is monotonic and round-trips", function()
		local prev = -1
		for _, x in { 0, 1, 2, 10, 999, 1000, 123456, 1e9, 5e15, 1e18, 1e30 } do
			local e = Leaderboard._encode(x)
			t.ok(e > prev or (x == 0 and e == 0), "monotonic at " .. x)
			t.ok(e < 2 ^ 53, "fits in a double-safe int")
			prev = e
		end
		for _, x in { 1, 7, 150, 99999, 1234567 } do
			t.eq(Leaderboard._decode(Leaderboard._encode(x)), x, "round trip " .. x)
		end
		t.near(Leaderboard._decode(Leaderboard._encode(5e15)) / 5e15, 1, 1e-6)
		t.eq(Leaderboard._encode(0 / 0), 0)
		t.eq(Leaderboard._decode(-5), 0)
	end)

	t.test("leaderboard merge prefers live values and sorts", function()
		local global = {
			{ name = "A", userId = 1, value = 500 },
			{ name = "B", userId = 2, value = 300 },
			{ name = "C", userId = 3, value = 100 },
		}
		local live = {
			{ name = "Bee", userId = 2, value = 900 },
			{ name = "D", userId = 4, value = 200 },
			{ name = "A2", userId = 1, value = 10 },
		}
		local m = Leaderboard._merge(global, live, 3)
		t.eq(#m, 3)
		t.eq(m[1].userId, 2)
		t.eq(m[1].value, 900)
		t.eq(m[1].name, "Bee")
		t.eq(m[2].userId, 1)
		t.eq(m[2].value, 500, "global higher than stale live value")
		t.eq(m[3].userId, 4)
	end)

	t.test("leaderboard board UI builds on a tagged part", function()
		local part = H.roblox.Instance.new("Part")
		part.Size = H.roblox.Vector3.new(24, 14, 1)
		part:SetAttribute("Stat", "totalEarned")
		Leaderboard.attachBoard(part)
		local guis = 0
		for _, c in part:GetChildren() do
			if c:IsA("SurfaceGui") then
				guis += 1
				local rows = c:FindFirstChild("Board"):FindFirstChild("Rows")
				t.ok(rows:FindFirstChild("Row10"), "10 rows")
			end
		end
		t.eq(guis, 2, "front + back faces")
		local p2 = H.roblox.Instance.new("Part")
		p2:SetAttribute("Stat", "steals")
		p2:SetAttribute("Face", "Left")
		Leaderboard.attachBoard(p2)
		t.ok(p2:FindFirstChild("LeaderboardGui_Left"), "Face attribute respected")
	end)

	-- admin ------------------------------------------------------------------------------------------------------
	t.test("admin command parsing", function()
		local cmd, args = Admin._parse("/hc car hyperion_x Gold")
		t.eq(cmd, "car")
		t.eq(args[1], "hyperion_x")
		t.eq(args[2], "Gold")
		cmd, args = Admin._parse("  CASH   1000 ")
		t.eq(cmd, "cash")
		t.eq(args[1], "1000")
		cmd = Admin._parse("/admin !hotdrop")
		t.eq(cmd, "hotdrop")
		t.eq(Admin._parse(""), nil)
		t.eq(Admin._parse("/hc"), nil)
	end)

	t.test("admin amount / car / mutation / event resolution", function()
		t.eq(Admin._parseAmount("1000"), 1000)
		t.eq(Admin._parseAmount("1,000"), 1000)
		t.eq(Admin._parseAmount("2.5k"), 2500)
		t.eq(Admin._parseAmount("3M"), 3000000)
		t.eq(Admin._parseAmount("1e6"), 1000000)
		t.eq(Admin._parseAmount("-500"), -500)
		t.eq(Admin._parseAmount("abc"), nil)
		t.eq(Admin._parseAmount("inf"), nil)
		t.eq(Admin._parseAmount("nan"), nil)
		t.eq(Admin._parseAmount(nil), nil)
		t.eq(Admin._resolveCar("hyperion_x"), "hyperion_x")
		t.eq(Admin._resolveCar("Hyperion X"), "hyperion_x")
		t.eq(Admin._resolveCar("HYPERION_X"), "hyperion_x")
		t.eq(Admin._resolveCar("zzzz_not_a_car"), nil)
		t.eq(Admin._resolveMutation(nil), "None")
		t.eq(Admin._resolveMutation("gold"), "Gold")
		t.eq(Admin._resolveMutation("plaid"), nil)
		t.eq(Admin._resolveEvent("rushhour"), "rushHour")
		t.eq(Admin._resolveEvent("cashrain"), "cashRain")
		t.eq(Admin._resolveEvent("doublecash"), "doubleCash")
		t.eq(Admin._resolveEvent("luck"), "serverLuck")
		t.eq(Admin._resolveEvent("party"), nil)
	end)

	-- session locking against a fake DataStore -----------------------------------------------------------------
	local I = DataService._internals
	local Players = I.Players

	local function copy(v)
		if type(v) ~= "table" then
			return v
		end
		local o = {}
		for k, x in v do
			o[k] = copy(x)
		end
		return o
	end

	local fake = { values = {}, calls = 0, failNext = 0 }
	function fake:UpdateAsync(key, transform)
		self.calls += 1
		if self.failNext > 0 then
			self.failNext -= 1
			error("502: simulated DataStore outage")
		end
		local result = transform(copy(self.values[key])) -- JSON round trip
		if result ~= nil then
			self.values[key] = copy(result)
		end
		return result
	end

	local function fakePlayer(userId)
		local attrs = {}
		local p = { UserId = userId, Name = "P" .. userId, DisplayName = "P" .. userId, Parent = Players }
		function p:Kick(msg)
			self.kicked = msg
		end
		function p:SetAttribute(k, v)
			attrs[k] = v
		end
		function p:GetAttribute(k)
			return attrs[k]
		end
		return p
	end

	local function makeProfile(player, key, session, data)
		return {
			player = player,
			userId = player.UserId,
			key = key,
			session = session,
			data = data,
			loaded = true,
			releasing = false,
			lost = false,
			saving = false,
			dirty = false,
			changeGen = 0,
			nextAutosave = 0,
			pushQueued = false,
			isNew = false,
			previousLastOnline = 0,
			joinedAt = 0,
		}
	end

	local savedTuning = { I.TUNING.keyWriteCooldown, I.TUNING.backoffScale }
	I.TUNING.keyWriteCooldown = 0
	I.TUNING.backoffScale = 0.0005
	I.setStore(fake, "live")

	t.test("claim new player -> save keeps lock -> release clears it -> reclaim sees data", function()
		local p = fakePlayer(101)
		local status, data, isNew = I.claimAsync(p, 101, "p_101", "sessA")
		t.eq(status, "ok")
		t.ok(isNew, "isNew")
		t.eq(data.cash, Economy.STARTING_CASH)
		local rec = fake.values.p_101
		t.eq(rec.lock.session, "sessA", "lock written on claim")
		t.eq(rec.data.garage["1"].carId, Economy.STARTER_CAR)

		local profile = makeProfile(p, "p_101", "sessA", data)
		data.cash = 999
		t.ok(I.writeAsync(profile, false), "save ok")
		t.eq(fake.values.p_101.data.cash, 999)
		t.eq(fake.values.p_101.lock.session, "sessA", "autosave keeps (refreshes) the lock")
		t.ok(I.writeAsync(profile, true), "release ok")
		t.eq(fake.values.p_101.lock, nil, "release clears the lock")

		local s2, d2, new2 = I.claimAsync(p, 101, "p_101", "sessB")
		t.eq(s2, "ok")
		t.ok(not new2)
		t.eq(d2.cash, 999, "progress persisted")

		-- the old session must never overwrite the new owner
		p.kicked = nil
		data.cash = 5
		t.ok(not I.writeAsync(profile, false), "old session save refused")
		t.ok(profile.lost, "old session marked lost")
		t.ok(p.kicked ~= nil, "player kicked on lost session")
		t.eq(fake.values.p_101.data.cash, 999, "new owner's data untouched")
		t.eq(fake.values.p_101.lock.session, "sessB")
	end)

	t.test("live lock held elsewhere: retries, then steals and keeps the stored data", function()
		fake.values.p_202 =
			{ data = { version = 1, cash = 777 }, lock = { jobId = "otherJob", session = "other", time = os.time() } }
		local before = fake.calls
		local status, data = I.claimAsync(fakePlayer(202), 202, "p_202", "sessC")
		t.eq(status, "ok")
		t.eq(data.cash, 777, "data from the dead server is kept")
		t.eq(fake.values.p_202.lock.session, "sessC")
		t.eq(fake.calls - before, #I.LOCK_RETRY_DELAYS + 1, "N locked attempts + 1 steal")
	end)

	t.test("stale lock and legacy bare profile are claimed on the first try", function()
		fake.values.p_303 = { data = { cash = 55 }, lock = { jobId = "x", session = "y", time = os.time() - 1000 } }
		local before = fake.calls
		local status, data = I.claimAsync(fakePlayer(303), 303, "p_303", "sessD")
		t.eq(status, "ok")
		t.eq(data.cash, 55)
		t.eq(fake.calls - before, 1)

		fake.values.p_304 =
			{ cash = 66, garage = { ["2"] = { carId = "rustbucket", mutation = "Gold", uncollected = 1 } } }
		local s2, d2 = I.claimAsync(fakePlayer(304), 304, "p_304", "sessE")
		t.eq(s2, "ok")
		t.eq(d2.cash, 66)
		t.eq(d2.garage["2"].mutation, "Gold")
		t.ok(fake.values.p_304.data ~= nil, "rewritten in the wrapped format")
	end)

	t.test("transient errors retry; persistent errors fail (caller kicks, never plays on defaults)", function()
		fake.failNext = 2
		local before = fake.calls
		local status = I.claimAsync(fakePlayer(404), 404, "p_404", "sessF")
		t.eq(status, "ok")
		t.eq(fake.calls - before, 3)

		fake.values.p_405 = { data = { cash = 123456 } }
		fake.failNext = 1000
		local s2, d2 = I.claimAsync(fakePlayer(405), 405, "p_405", "sessG")
		fake.failNext = 0
		t.eq(s2, "failed")
		t.eq(d2, nil, "no default data handed out")
		t.eq(fake.values.p_405.data.cash, 123456, "stored data untouched")
	end)

	t.test("player who left is not claimed; save errors are retried", function()
		local gone = fakePlayer(505)
		gone.Parent = nil
		local status = I.claimAsync(gone, 505, "p_505", "sessH")
		t.eq(status, "left")
		t.eq(fake.values.p_505, nil, "nothing written for a player who left")

		local p = fakePlayer(506)
		local _, data = I.claimAsync(p, 506, "p_506", "sessI")
		local profile = makeProfile(p, "p_506", "sessI", data)
		data.cash = 4242
		fake.failNext = 2
		t.ok(I.writeAsync(profile, false), "save succeeds after retries")
		t.eq(fake.values.p_506.data.cash, 4242)
		fake.failNext = 100
		t.ok(not I.writeAsync(profile, false), "save reports failure when the store is down")
		fake.failNext = 0
		t.ok(not profile.lost, "a failed save is not a lost session")
	end)

	t.test("memory mode never touches the store", function()
		I.setStore(nil, "memory")
		local profile = makeProfile(fakePlayer(606), "p_606", "s", DataService._template())
		t.ok(I.writeAsync(profile, true))
		t.eq(fake.values.p_606, nil)
	end)

	t.test("ProcessReceipt: grant once, ack only after save, no double grant on redelivery", function()
		I.setStore(fake, "live")
		local Decision = H.roblox.Enum.ProductPurchaseDecision
		local product = MonetizationConfig.Products.cash_small
		local savedId = product.id
		product.id = 777001
		local grants = 0
		local fail = false
		Monetization.registerProduct("cash_small", function(player)
			if fail then
				return false
			end
			local d = DataService.get(player)
			d.cash += 100
			grants += 1
			return true
		end)
		local p = fakePlayer(707)
		local _, data = I.claimAsync(p, 707, "p_707", "sessR")
		local start = data.cash
		local profile = makeProfile(p, "p_707", "sessR", data)
		I.profiles[p] = profile

		local ok, err = pcall(function()
			-- 1. normal purchase
			t.eq(Monetization._processWhileLocked(p, 777001, "pur1"), Decision.PurchaseGranted)
			t.eq(grants, 1)
			t.ok(table.find(fake.values.p_707.data.receipts, "pur1"), "receipt persisted with the grant")
			t.eq(fake.values.p_707.data.cash, start + 100)
			-- 2. redelivery of a confirmed receipt: no grant, no write
			local calls = fake.calls
			t.eq(Monetization._processWhileLocked(p, 777001, "pur1"), Decision.PurchaseGranted)
			t.eq(grants, 1, "no double grant")
			t.eq(fake.calls, calls, "no extra write")
			-- 3. save fails: granted in memory, NOT acknowledged
			fake.failNext = 1000
			t.eq(Monetization._processWhileLocked(p, 777001, "pur2"), Decision.NotProcessedYet)
			t.eq(grants, 2)
			t.ok(table.find(data.receipts, "pur2"), "receipt kept in memory with the grant")
			t.ok(not table.find(fake.values.p_707.data.receipts, "pur2"), "not persisted yet")
			-- 4. redelivery while still failing: still not acknowledged, still no double grant
			t.eq(Monetization._processWhileLocked(p, 777001, "pur2"), Decision.NotProcessedYet)
			t.eq(grants, 2)
			-- 5. store recovers: redelivery confirms the save and acknowledges
			fake.failNext = 0
			t.eq(Monetization._processWhileLocked(p, 777001, "pur2"), Decision.PurchaseGranted)
			t.eq(grants, 2, "exactly one grant per purchase")
			t.ok(table.find(fake.values.p_707.data.receipts, "pur2"))
			t.eq(fake.values.p_707.data.cash, start + 200)
			-- 6. unknown product / handler refusing -> NotProcessedYet and nothing recorded
			t.eq(Monetization._processWhileLocked(p, 999999, "pur3"), Decision.NotProcessedYet)
			fail = true
			t.eq(Monetization._processWhileLocked(p, 777001, "pur4"), Decision.NotProcessedYet)
			t.ok(not table.find(data.receipts, "pur4"), "refused grant not recorded")
			-- 7. data not loaded -> NotProcessedYet
			profile.loaded = false
			fail = false
			t.eq(Monetization._processWhileLocked(p, 777001, "pur5"), Decision.NotProcessedYet)
			t.eq(grants, 2)
		end)
		I.profiles[p] = nil
		product.id = savedId
		fake.failNext = 0
		Monetization.init() -- restore the built-in handlers
		if not ok then
			error(err, 0)
		end
	end)

	-- restore module state for any other spec that requires DataService
	I.TUNING.keyWriteCooldown = savedTuning[1]
	I.TUNING.backoffScale = savedTuning[2]
	I.setStore(nil, "pending")
end
