--!nocheck
-- TheftService + DealershipService + DealershipClient: pure rules, the full theft lifecycle against mocked systems
-- (a car is never lost or duplicated), dealership stock/restock timing and the harness-compatible builders.
return function(t)
	local H = t.H
	local R = H.roblox
	H.setMode("server")

	local Theft = H.require("src/server/Systems/TheftService")
	local Dealer = H.require("src/server/Systems/DealershipService")
	local Economy = H.require("src/shared/Config/Economy")
	local Cars = H.require("src/shared/Config/Cars")
	local MapLayout = H.require("src/shared/Util/MapLayout")

	-------------------------------------------------------------------------------------------------------------
	-- _canSteal
	-------------------------------------------------------------------------------------------------------------
	local function okState()
		return {
			isSelf = false,
			victimOnline = true,
			victimLoaded = true,
			thiefLoaded = true,
			thiefAlive = true,
			thiefStunned = false,
			thiefDriving = false,
			thiefBusy = false,
			hasCar = true,
			slotParked = true,
			stealable = true,
			locked = false,
			inside = true,
			victimCars = 5,
			victimBusy = false,
			cooldownLeft = 0,
			thiefHasPlot = true,
			thiefFreeSlots = 2,
		}
	end

	t.test("_canSteal accepts a valid attempt", function()
		local ok, code, msg = Theft._canSteal(okState())
		t.ok(ok, "should be ok")
		t.eq(code, "ok")
		t.eq(msg, "")
	end)

	t.test("_canSteal reason codes", function()
		local cases = {
			{ "isSelf", true, "self" },
			{ "victimOnline", false, "offline" },
			{ "victimLoaded", false, "loading" },
			{ "thiefLoaded", false, "loading" },
			{ "thiefAlive", false, "dead" },
			{ "thiefStunned", true, "stunned" },
			{ "thiefDriving", true, "driving" },
			{ "thiefBusy", true, "busy" },
			{ "hasCar", false, "gone" },
			{ "slotParked", false, "gone" },
			{ "stealable", false, "unstealable" },
			{ "locked", true, "locked" },
			{ "inside", false, "outside" },
			{ "victimCars", Economy.NEWBIE_PROTECTION_CARS - 1, "newbie" },
			{ "victimBusy", true, "victimBusy" },
			{ "cooldownLeft", 12, "cooldown" },
			{ "thiefHasPlot", false, "noPlot" },
			{ "thiefFreeSlots", 0, "full" },
		}
		for _, c in cases do
			local s = okState()
			s[c[1]] = c[2]
			local ok, code, msg = Theft._canSteal(s)
			t.ok(not ok, c[1] .. " should fail")
			t.eq(code, c[3], c[1])
			t.ok(type(msg) == "string" and #msg > 0, c[1] .. " needs a message")
		end
		-- exactly at the newbie threshold is robbable
		local s = okState()
		s.victimCars = Economy.NEWBIE_PROTECTION_CARS
		t.ok((Theft._canSteal(s)), "threshold count is robbable")
	end)

	t.test("_canSteal messages + precedence", function()
		local s = okState()
		s.locked = true
		s.victimCars = 1
		s.thiefFreeSlots = 0
		local _, code, msg = Theft._canSteal(s)
		t.eq(code, "locked", "locked gate beats newbie/full")
		t.ok(msg:find("Garage locked!", 1, true) ~= nil, "locked text")
		s = okState()
		s.cooldownLeft = 12
		_, code, msg = Theft._canSteal(s)
		t.eq(code, "cooldown")
		t.ok(msg:find("try again in 12s", 1, true) ~= nil, "cooldown seconds in text: " .. msg)
		s = okState()
		s.thiefFreeSlots = 0
		_, _, msg = Theft._canSteal(s)
		t.ok(msg:find("Your garage is full!", 1, true) ~= nil, "full text")
		s = okState()
		s.victimCars = 0
		_, _, msg = Theft._canSteal(s)
		t.ok(msg:find("Too new to rob (protected)", 1, true) ~= nil, "newbie text")
	end)

	t.test("theft timing helpers", function()
		t.eq(Theft._cooldownLeft(nil, 10), 0)
		t.eq(Theft._cooldownLeft(9, 10), 0)
		t.eq(Theft._cooldownLeft(10.2, 10), 1, "rounds up")
		t.eq(Theft._cooldownLeft(35, 10), 25)
		t.eq(Theft._dropTimeout(true), Economy.DROPPED_CAR_TIMEOUT)
		t.eq(Theft._dropTimeout(false), Economy.THEFT_ABANDON_LIMIT)
		t.eq(Theft._bonus(0, 30), Theft.MIN_BONUS)
		t.eq(Theft._bonus(0 / 0, 30), Theft.MIN_BONUS, "NaN income")
		t.eq(Theft._bonus(100, 30), 3000)
		t.eq(Theft._takeoverDeadline(500, 100), 500)
		t.eq(Theft._takeoverDeadline(110, 100), 100 + Theft.TAKEOVER_MIN_TIME)
		local v, th = Theft._failText("timeout", "Viper", "Bob")
		t.ok(#v > 0 and #th > 0, "timeout texts")
		v, th = Theft._failText("victim_left", "Viper", "Bob")
		t.eq(v, "")
		t.ok(th:find("Bob", 1, true) ~= nil)
	end)

	-------------------------------------------------------------------------------------------------------------
	-- Lifecycle against mocks
	-------------------------------------------------------------------------------------------------------------
	local clock = 1000
	local fired = {}
	local log = {}
	local datas = {}
	local states = {}
	local capacity = {}
	local plots = {}
	local locked = {}
	local roots = {}
	local cars = {}

	local function fakePlayer(name, userId)
		local attrs = {}
		return {
			Name = name,
			DisplayName = name,
			UserId = userId,
			_online = true,
			SetAttribute = function(_, k, v)
				attrs[k] = v
			end,
			GetAttribute = function(_, k)
				return attrs[k]
			end,
			IsA = function(_, cls)
				return cls == "Player" or cls == "Instance"
			end,
			_attrs = attrs,
		}
	end

	local function countLog(kind)
		local n = 0
		for _, e in log do
			if e[1] == kind then
				n += 1
			end
		end
		return n
	end

	local function firedTo(name, player)
		local out = {}
		for _, f in fired do
			if f.name == name and (player == nil or f.player == player) then
				table.insert(out, f)
			end
		end
		return out
	end

	local GS = {
		getSlotState = function(p, slot)
			local d = datas[p]
			if not d or not d.garage[tostring(slot)] then
				return nil
			end
			return (states[p] and states[p][slot]) or "Parked"
		end,
		setSlotState = function(p, slot, st)
			states[p] = states[p] or {}
			states[p][slot] = st
			table.insert(log, { "setSlotState", p, slot, st })
		end,
		restoreSlot = function(p, slot)
			states[p] = states[p] or {}
			states[p][slot] = "Parked"
			table.insert(log, { "restoreSlot", p, slot })
		end,
		removeSlot = function(p, slot)
			local rec = datas[p].garage[tostring(slot)]
			datas[p].garage[tostring(slot)] = nil
			if states[p] then
				states[p][slot] = nil
			end
			table.insert(log, { "removeSlot", p, slot })
			return rec
		end,
		storeCar = function(p, carId, mutation)
			local cap = capacity[p] or 4
			for i = 1, cap do
				if datas[p].garage[tostring(i)] == nil then
					datas[p].garage[tostring(i)] = { carId = carId, mutation = mutation, uncollected = 0 }
					table.insert(log, { "storeCar", p, i, carId })
					return true, i
				end
			end
			return false, "full"
		end,
		freeSlots = function(p)
			local n = 0
			for i = 1, capacity[p] or 4 do
				if datas[p].garage[tostring(i)] == nil then
					n += 1
				end
			end
			return n
		end,
		ownedCount = function(p)
			local n = 0
			for _ in datas[p].garage do
				n += 1
			end
			return n
		end,
		discover = function()
			return true
		end,
		incomePerSec = function()
			return 10
		end,
		multiplier = function()
			return 1
		end,
	}
	local mocks = {
		GarageService = GS,
		DataService = {
			get = function(p)
				return datas[p]
			end,
			addCash = function(p, amount, reason)
				datas[p].cash += amount
				table.insert(log, { "addCash", p, amount, reason })
				return datas[p].cash
			end,
			markDirty = function() end,
			saveNow = function(p)
				table.insert(log, { "saveNow", p })
				return true
			end,
		},
		PlotService = {
			PAD_TOP = 0.25,
			getPlotIndex = function(p)
				return plots[p]
			end,
			isLocked = function(i)
				return locked[i] == true
			end,
			isInside = function(_p, _i)
				return true
			end,
		},
		VehicleService = {
			spawn = function(carId, mutation, _cf, kind)
				local car = {
					carId = carId,
					mutation = mutation,
					kind = kind,
					model = R.Instance.new("Model"),
					data = {},
					_alive = true,
				}
				table.insert(cars, car)
				table.insert(log, { "spawn", carId, kind })
				return car
			end,
			seat = function(car, p)
				car.driver = p
			end,
			eject = function(car)
				car.driver = nil
			end,
			destroy = function(car, reason)
				car._alive = false
				table.insert(log, { "destroy", car, reason })
			end,
			getDriving = function()
				return nil
			end,
		},
		WantedService = {
			addHeat = function(p, stars, reason)
				table.insert(log, { "heat", p, stars, reason })
			end,
		},
		RewardsService = {
			progress = function(p, stat, n)
				table.insert(log, { "progress", p, stat, n })
			end,
		},
	}

	Theft._setHooks({
		isTest = true,
		clock = function()
			return clock
		end,
		serverNow = function()
			return clock + 5000
		end,
		system = function(name)
			return mocks[name]
		end,
		isOnline = function(p)
			return p._online == true
		end,
		rootOf = function(p)
			local r = roots[p]
			if not r then
				return nil, nil
			end
			return r, { Health = 100, SeatPart = nil }
		end,
		fireClient = function(name, player, ...)
			table.insert(fired, { name = name, player = player, args = { ... } })
		end,
		fireAll = function(name, ...)
			table.insert(fired, { name = name, all = true, args = { ... } })
		end,
		fireNear = function(name, _pos, _r, ...)
			table.insert(fired, { name = name, near = true, args = { ... } })
		end,
		spawnTask = function(fn, ...)
			fn(...)
		end,
	})

	local thief, victim, other
	local function setup()
		Theft._reset()
		table.clear(fired)
		table.clear(log)
		table.clear(states)
		table.clear(cars)
		clock += 1000
		thief = fakePlayer("Thief", 1)
		victim = fakePlayer("Victim", 2)
		other = fakePlayer("Other", 3)
		datas[thief] = {
			cash = 0,
			garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } },
			stats = { steals = 0, playerSteals = 0, timesRobbed = 0 },
		}
		datas[victim] = {
			cash = 0,
			garage = {
				["1"] = { carId = "viper_strike", mutation = "Gold", uncollected = 500 },
				["2"] = { carId = "rustbucket", mutation = "None", uncollected = 0 },
				["3"] = { carId = "yellow_cab", mutation = "None", uncollected = 0 },
			},
			stats = { steals = 0, playerSteals = 0, timesRobbed = 0 },
		}
		datas[other] = {
			cash = 0,
			garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } },
			stats = { steals = 0, playerSteals = 0, timesRobbed = 0 },
		}
		capacity[thief], capacity[victim], capacity[other] = 4, 4, 4
		plots[victim], plots[thief], plots[other] = 1, 2, 3
		locked[1] = false
		-- thief stands right next to the victim's slot 1
		roots[thief] = { Position = MapLayout.slotWorld(1, 1).Position + R.Vector3.new(0, 3, 0) }
		roots[victim] = { Position = MapLayout.slotWorld(1, 5).Position }
		roots[other] = { Position = MapLayout.slotWorld(1, 1).Position + R.Vector3.new(4, 3, 0) }
	end

	local function lastNotify(player)
		local list = firedTo("Notify", player)
		local f = list[#list]
		return f and f.args[2] or ""
	end

	local function countCars(p, carId, mutation)
		local n = 0
		for _, rec in datas[p].garage do
			if rec.carId == carId and (mutation == nil or rec.mutation == mutation) then
				n += 1
			end
		end
		return n
	end

	t.test("beginTheft starts a theft", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1), "theft should start: " .. lastNotify(thief))
		t.eq(states[victim][1], "BeingStolen")
		t.eq(#cars, 1)
		local car = cars[1]
		t.eq(car.kind, "Stolen")
		t.eq(car.driver, thief, "thief seated")
		t.eq(car.data.theft.victim, victim)
		t.eq(car.data.theft.thief, thief)
		t.eq(car.data.theft.slot, 1)
		t.ok(Theft.isBeingStolen(victim, 1))
		t.ok(Theft.getActiveTheft(thief) ~= nil)
		t.eq(Theft.getActiveTheft(thief).victim, victim)
		t.eq(countLog("heat"), 1)
		local alerts = firedTo("CarStolenAlert", victim)
		t.eq(#alerts, 1)
		t.eq(alerts[1].args[4], true)
		local st = firedTo("TheftState", thief)
		t.ok(#st >= 1 and st[#st].args[1].active == true, "TheftState active")
		t.eq(st[#st].args[1].targetPlot, 2)
		t.ok(#firedTo("Waypoint", thief) >= 1, "thief waypoint")
	end)

	t.test("beginTheft rejections notify the thief", function()
		setup()
		locked[1] = true
		t.ok(not Theft.beginTheft(thief, victim, 1))
		t.ok(lastNotify(thief):find("Garage locked!", 1, true) ~= nil, lastNotify(thief))
		t.eq(#cars, 0, "nothing spawned")
		t.eq(states[victim] and states[victim][1], nil, "slot untouched")
		locked[1] = false
		datas[victim].garage["2"] = nil
		datas[victim].garage["3"] = nil
		t.ok(not Theft.beginTheft(thief, victim, 1))
		t.ok(lastNotify(thief):find("protected", 1, true) ~= nil, lastNotify(thief))
		setup()
		capacity[thief] = 1
		t.ok(not Theft.beginTheft(thief, victim, 1))
		t.ok(lastNotify(thief):find("Your garage is full!", 1, true) ~= nil, lastNotify(thief))
		setup()
		t.ok(not Theft.beginTheft(victim, victim, 1), "self theft")
		setup()
		roots[thief] = { Position = MapLayout.slotWorld(1, 12).Position + R.Vector3.new(0, 3, 60) }
		t.ok(not Theft.beginTheft(thief, victim, 1), "too far from the slot")
	end)

	t.test("one theft per victim, then cooldown", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		-- slot 3 is the next pad in the same column, within reach of `other`
		t.ok(not Theft.beginTheft(other, victim, 3), "victim already being robbed")
		t.ok(lastNotify(other):find("already being robbed", 1, true) ~= nil, lastNotify(other))
		t.ok(Theft.fail(cars[1], "timeout"))
		t.ok(not Theft.beginTheft(other, victim, 3), "cooldown after the theft ends")
		t.ok(lastNotify(other):find("try again in", 1, true) ~= nil, lastNotify(other))
		clock += Economy.THEFT_VICTIM_COOLDOWN + 1
		t.ok(Theft.beginTheft(other, victim, 3), "robbable again after the cooldown: " .. lastNotify(other))
	end)

	t.test("complete transfers exactly one car", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		local car = cars[1]
		t.ok(Theft.complete(car), "complete should succeed")
		t.eq(countCars(victim, "viper_strike"), 0, "victim lost it")
		t.eq(countCars(thief, "viper_strike", "Gold"), 1, "thief has it (with mutation)")
		t.eq(datas[victim].cash, 500, "victim keeps the uncollected cash")
		t.eq(datas[thief].stats.playerSteals, 1)
		t.eq(datas[victim].stats.timesRobbed, 1)
		t.eq(car._alive, false, "car destroyed")
		t.eq(Theft.getActiveTheft(thief), nil)
		t.ok(not Theft.isBeingStolen(victim, 1))
		local alerts = firedTo("CarStolenAlert", victim)
		t.eq(alerts[#alerts].args[4], false, "alarm off")
		t.eq(countLog("saveNow"), 2, "both saved")
		local playerSteal = 0
		for _, e in log do
			if e[1] == "progress" and e[3] == "playerSteal" then
				playerSteal += 1
			end
		end
		t.eq(playerSteal, 1)
		-- second delivery attempt / late fail do nothing
		t.ok(not Theft.complete(car), "no double transfer")
		t.ok(not Theft.fail(car, "timeout"), "no restore after transfer")
		t.eq(countLog("restoreSlot"), 0)
		t.eq(countCars(thief, "viper_strike"), 1)
	end)

	t.test("complete refuses when the thief's garage filled up", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		capacity[thief] = 1 -- filled meanwhile
		t.ok(not Theft.complete(cars[1]))
		t.eq(countCars(victim, "viper_strike"), 1, "victim still owns it")
		t.ok(Theft.getActiveTheft(thief) ~= nil, "theft still running")
		t.ok(lastNotify(thief):find("Garage full", 1, true) ~= nil, lastNotify(thief))
	end)

	t.test("only the current driver can deliver", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		cars[1].driver = other
		t.ok(not Theft.complete(cars[1]))
		t.eq(countCars(victim, "viper_strike"), 1)
	end)

	t.test("fail restores the slot exactly once", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		local car = cars[1]
		t.ok(Theft.fail(car, "busted"))
		t.ok(not Theft.fail(car, "timeout"))
		Theft._onDestroyed(car, "wrecked")
		Theft._tick(clock + 9999)
		t.eq(countLog("restoreSlot"), 1)
		t.eq(states[victim][1], "Parked")
		t.eq(car._alive, false)
		t.eq(countCars(victim, "viper_strike"), 1)
		t.eq(countCars(thief, "viper_strike"), 0)
	end)

	t.test("time limit and wreck end the theft", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		Theft._tick(clock + Economy.THEFT_TIME_LIMIT - 20)
		t.ok(Theft.getActiveTheft(thief) ~= nil, "still running before the limit")
		Theft._tick(clock + Economy.THEFT_TIME_LIMIT + 1)
		t.eq(Theft.getActiveTheft(thief), nil)
		t.eq(countLog("restoreSlot"), 1)

		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		local car = cars[1]
		car._alive = false -- VehicleService wrecked + destroyed it
		Theft._onDestroyed(car, "wrecked")
		t.eq(Theft.getActiveTheft(thief), nil)
		t.eq(countLog("restoreSlot"), 1)
		t.eq(countLog("destroy"), 0, "no second destroy for an already destroyed car")
	end)

	t.test("thief leaving returns the car; victim leaving keeps it in their data", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		thief._online = false
		Theft._onPlayerRemoving(thief)
		t.eq(countLog("restoreSlot"), 1)
		t.eq(cars[1]._alive, false)
		t.eq(countCars(victim, "viper_strike"), 1)

		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		victim._online = false
		Theft._onPlayerRemoving(victim)
		t.eq(countLog("restoreSlot"), 0, "no restore for a leaving player")
		t.eq(countCars(victim, "viper_strike"), 1, "record still saved with the victim")
		t.eq(cars[1]._alive, false, "car vanished")
		t.eq(Theft.getActiveTheft(thief), nil)
		t.ok(lastNotify(thief):find("left", 1, true) ~= nil, lastNotify(thief))
	end)

	t.test("dropped car: recover pays a bonus; timeout tows it home", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		local car = cars[1]
		car.driver = nil
		Theft._onDriverChanged(car, nil, thief)
		local theft = Theft.getActiveTheft(thief)
		t.ok(theft.dropped, "dropped")
		t.eq(theft.droppedUntil, clock + Economy.THEFT_ABANDON_LIMIT, "hopped out = abandon limit")
		t.ok(not Theft.recover(car, other), "only the victim recovers")
		t.ok(Theft.recover(car, victim))
		t.eq(countLog("restoreSlot"), 1)
		local bonus = Theft._bonus(10, Economy.RECOVERY_BONUS_SECONDS)
		t.eq(datas[victim].cash, bonus, "recovery bonus")
		t.eq(car._alive, false)
		t.ok(not Theft.recover(car, victim), "recover is single-shot")

		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		car = cars[1]
		Theft.onThiefHit(other, thief) -- someone bonks the thief...
		car.driver = nil
		Theft._onDriverChanged(car, nil, thief) -- ...and they pop out
		theft = Theft.getActiveTheft(thief)
		t.eq(theft.droppedUntil, clock + Economy.DROPPED_CAR_TIMEOUT, "knocked out = longer window")
		Theft._tick(clock + Economy.DROPPED_CAR_TIMEOUT - 1)
		t.ok(Theft.getActiveTheft(thief) ~= nil)
		Theft._tick(clock + Economy.DROPPED_CAR_TIMEOUT + 0.5)
		t.eq(Theft.getActiveTheft(thief), nil, "towed home")
		t.eq(countLog("restoreSlot"), 1)
	end)

	t.test("thief getting back in resumes the theft", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		local car = cars[1]
		car.driver = nil
		Theft._onDriverChanged(car, nil, thief)
		t.ok(Theft.getActiveTheft(thief).dropped)
		car.driver = thief
		Theft._onDriverChanged(car, thief, nil)
		t.ok(not Theft.getActiveTheft(thief).dropped)
		Theft._tick(clock + Economy.DROPPED_CAR_TIMEOUT + 1)
		t.ok(Theft.getActiveTheft(thief) ~= nil, "no tow while driven")
	end)

	t.test("hijack: another player takes over a dropped theft", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		local car = cars[1]
		car.driver = nil
		Theft._onDriverChanged(car, nil, thief)
		local theft = Theft.getActiveTheft(thief)
		local okV, why = Theft._canTakeover(theft, victim)
		t.ok(not okV and why ~= nil, "victim must use Recover")
		t.ok(Theft._takeover(theft, other), "other hijacks")
		t.eq(Theft.getActiveTheft(thief), nil)
		t.eq(Theft.getActiveTheft(other), theft)
		t.eq(car.data.theft.thief, other)
		t.eq(car.driver, other)
		t.ok(not theft.dropped)
		t.ok(Theft.complete(car))
		t.eq(countCars(other, "viper_strike"), 1)
		t.eq(countCars(thief, "viper_strike"), 0)
		t.eq(countCars(victim, "viper_strike"), 0)
	end)

	t.test("revenge pays once per theft and once per robbery", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		Theft.onThiefHit(victim, thief)
		Theft.onThiefHit(victim, thief)
		local revenge = 0
		for _, e in log do
			if e[1] == "addCash" and e[4] == "revenge" then
				revenge += 1
			end
		end
		t.eq(revenge, 1, "once per theft")
		t.ok(Theft.complete(cars[1]))
		Theft.onThiefHit(victim, thief) -- bonk the robber after the fact
		Theft.onThiefHit(victim, thief)
		revenge = 0
		for _, e in log do
			if e[1] == "addCash" and e[4] == "revenge" then
				revenge += 1
			end
		end
		t.eq(revenge, 2, "one more for the completed robbery")
		Theft.onThiefHit(other, thief)
		t.eq(datas[other].cash, 0, "bystanders get nothing")
	end)

	t.test("spawn failure hands the slot back", function()
		setup()
		local spawn = mocks.VehicleService.spawn
		mocks.VehicleService.spawn = function()
			error("boom")
		end
		t.ok(not Theft.beginTheft(thief, victim, 1))
		mocks.VehicleService.spawn = spawn
		t.eq(states[victim][1], "Parked")
		t.eq(Theft.getActiveTheft(thief), nil)
		t.ok(not Theft.isBeingStolen(victim, 1))
	end)

	-------------------------------------------------------------------------------------------------------------
	-- Dealership
	-------------------------------------------------------------------------------------------------------------
	t.test("dealer price / steal hold", function()
		local def = Cars.get("viper_strike")
		t.eq(Dealer._price("viper_strike", "None"), def.price)
		t.eq(Dealer._price("viper_strike", "Gold"), def.price * 2)
		t.eq(Dealer._price("viper_strike", "Galaxy"), def.price * 8)
		t.eq(Dealer._price("nope", "None"), 0)
		t.near(Dealer._stealHold("viper_strike"), 1.8 * Economy.DEALER_STEAL_HOLD_MULTIPLIER, 1e-9)
		-- buy -> sell is never profitable
		for _, mut in { "None", "Gold", "Diamond", "Rainbow", "Galaxy" } do
			local EconomyMath = H.require("src/shared/Util/EconomyMath")
			t.ok(EconomyMath.sellValue("viper_strike", mut) < Dealer._price("viper_strike", mut), mut)
		end
	end)

	t.test("dealer restock timing", function()
		local now = 100
		local nextGlobal = Dealer._nextGlobal(now)
		t.eq(nextGlobal, now + 240)
		t.eq(Dealer._padRestockAt(now + 10, nextGlobal), now + 10 + Dealer.PAD_RESTOCK, "sold early: 30s")
		t.eq(Dealer._padRestockAt(now + 230, nextGlobal), nextGlobal, "global restock comes first")
		t.eq(Dealer._countdown(now + 192, now), "3:12")
		t.eq(Dealer._countdown(now + 0.2, now), "0:01", "rounds up")
		t.eq(Dealer._countdown(now - 5, now), "0:00")
	end)

	t.test("dealer stock rolls", function()
		for seed = 1, 40 do
			local rng = H.Random.new(seed)
			local stock = Dealer._rollStock(8, 1, rng, nil, true)
			t.eq(#stock, 8)
			local ids, unique, hasCommon = {}, 0, false
			for _, e in stock do
				local def = Cars.get(e.carId)
				t.ok(def ~= nil and def.dealer, "dealer car " .. tostring(e.carId))
				t.ok(e.mutation ~= nil)
				if not ids[e.carId] then
					unique += 1
					ids[e.carId] = true
				end
				if def.rarity == "Common" then
					hasCommon = true
				end
			end
			t.ok(hasCommon, "always a Common on the floor (seed " .. seed .. ")")
			t.ok(unique >= 6, "mostly unique stock")
		end
		-- single-pad restock avoids what's on the floor
		local taken = {}
		for _, def in Cars.List do
			if def.dealer and def.id ~= "rustbucket" then
				taken[def.id] = true
			end
		end
		local hits = 0
		for seed = 1, 20 do
			local one = Dealer._rollStock(1, 1, H.Random.new(seed), taken, false)
			if one[1].carId == "rustbucket" then
				hits += 1
			end
		end
		t.ok(hits >= 1, "retries steer away from taken ids")
	end)

	t.test("dealer hype levels", function()
		t.eq(Dealer._hype("night_raven", "None"), "announce", "Mythic")
		t.eq(Dealer._hype("rubber_ducky", "None"), "announce", "Secret")
		t.eq(Dealer._hype("hyperion_x", "None"), "feed", "Legendary")
		t.eq(Dealer._hype("raging_bull", "Rainbow"), "feed", "Rainbow Epic")
		t.eq(Dealer._hype("raging_bull", "Gold"), "none")
		t.eq(Dealer._hype("rustbucket", "Galaxy"), "none")
	end)

	t.test("dealer showroom + display builders", function()
		local folder = R.Instance.new("Folder")
		local tables, board = Dealer.buildShowroom(folder)
		t.eq(#tables, #MapLayout.dealerPads())
		for i, tt in tables do
			t.eq(tt:GetAttribute("PadIndex"), i)
			t.eq(tt:GetAttribute("Empty"), true)
			t.ok(tt.Anchored and tt.CanCollide)
			t.ok(tt:FindFirstChild("Rim" .. i) ~= nil, "neon rim")
			local pad = MapLayout.dealerPads()[i]
			t.near(tt.CFrame.Position.X, pad.Position.X, 1e-3)
			t.near(tt.CFrame.Position.Z, pad.Position.Z, 1e-3)
		end
		local display = board:FindFirstChild("Display")
		t.ok(display ~= nil, "sign SurfaceGui")
		local bg = display:FindFirstChild("Background")
		t.ok(bg and bg:FindFirstChild("Countdown") ~= nil, "countdown label")
		-- sign stands behind the back row, above car height
		local c = MapLayout.poiCenter("Dealership")
		t.ok(board.CFrame.Position.Z > c.Z + 30, "behind the back row")
		t.ok(board.CFrame.Position.Y - board.Size.Y / 2 >= c.Y + 8, "above the cars")

		local pad = MapLayout.dealerPads()[1]
		local top = pad * R.CFrame.new(0, Dealer.TURNTABLE_HEIGHT, 0)
		local model = Dealer.buildDisplay("viper_strike", "Gold", top)
		t.ok(model ~= nil, "display built")
		t.eq(model:GetAttribute("Price"), Dealer._price("viper_strike", "Gold"))
		t.eq(model:GetAttribute("CarId"), "viper_strike")
		t.eq(model:GetAttribute("Rarity"), "Rare")
		t.ok(model.PrimaryPart.Anchored, "chassis anchored")
		local ride = model:GetAttribute("RideHeight")
		t.near(model:GetPivot().Position.Y, top.Position.Y + ride, 1e-3, "rests on the turntable")
		t.near(model:GetPivot().LookVector.Z, -1, 1e-3, "faces the street")
		t.eq(Dealer.buildDisplay("not_a_car", "None", top), nil)
	end)

	-------------------------------------------------------------------------------------------------------------
	-- DealershipClient pure helpers
	-------------------------------------------------------------------------------------------------------------
	t.test("DealershipClient helpers", function()
		H.setMode("client")
		local DC = H.require("src/client/Controllers/DealershipClient")
		t.eq(DC._countdownText("NEW STOCK IN", 192, 0), "NEW STOCK IN 3:12")
		t.eq(DC._countdownText("NEW CAR IN", -3, 0), "NEW CAR IN 0:00")
		t.near(DC._scaledHold(2, 0.5), 1, 1e-9)
		t.near(DC._scaledHold(2, nil), 2, 1e-9)
		t.near(DC._scaledHold(2, 0 / 0), 2, 1e-9)
		t.near(DC._scaledHold(2, -1), 2, 1e-9)
		t.ok(DC._audienceVisible(nil, nil, 5))
		t.ok(DC._audienceVisible(5, nil, 5))
		t.ok(not DC._audienceVisible(6, nil, 5), "OnlyUserId hides for others")
		t.ok(not DC._audienceVisible(nil, 5, 5), "HideForUserId hides for that user")
		t.ok(DC._audienceVisible(nil, 6, 5))
		t.ok(DC._displayColor("Secret") ~= nil)
		H.setMode("server")
	end)
end
