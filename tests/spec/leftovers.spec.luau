--!nocheck
-- Cross-group leftovers (fix phase L1): a lock push-out's dropped car stays the owner's, the victim's alert countdown,
-- reward / exclusive cars waiting out an active heist (player-theft F10), the Lockdown toast, GarageClient's billboard
-- budget + intruder flash + LOCK pill top, the tutorial card above the pill, and the Reset-while-wanted rule.
return function(t)
	local H = t.H
	local R = H.roblox

	-------------------------------------------------------------------------------------------------------------
	-- Client pure helpers
	-------------------------------------------------------------------------------------------------------------
	H.setMode("client")
	local GarageClient = H.require("src/client/Controllers/GarageClient")
	local Tut = H.require("src/client/Controllers/TutorialController")
	local HUD = H.require("src/client/Controllers/HUDController")
	local Notif = H.require("src/client/Controllers/NotificationController")

	t.test("GarageClient: billboards only near the camera (PERF-12)", function()
		local center = R.Vector3.new(100, 10, 100)
		t.ok(GarageClient._tagsNear(R.Vector3.new(100, 20, 180), center, 150), "inside the radius")
		t.ok(not GarageClient._tagsNear(R.Vector3.new(100, 20, 400), center, 150), "far garage")
		t.ok(GarageClient._tagsNear(nil, center, 150), "no camera: show")
		t.ok(GarageClient._tagsNear(R.Vector3.new(0, 0, 0), nil, 150), "unknown garage: show")
	end)

	t.test("GarageClient: intruder flash + LOCK pill top", function()
		t.ok(GarageClient._intruderFlash(1000, 1002), "fresh stamp flashes")
		t.ok(not GarageClient._intruderFlash(1000, 1010), "old stamp")
		t.ok(not GarageClient._intruderFlash(0, 5), "never stamped")
		t.ok(GarageClient._intruderFlash(1000, 999.5), "small clock skew still flashes")
		t.eq(GarageClient._lockTop(false, 112), nil, "hidden pill")
		t.eq(GarageClient._lockTop(true, 112), 170, "inside: 112 + 58")
		t.eq(GarageClient._lockTop(true, 150), 208, "stacked above HOME")
	end)

	t.test("Tutorial card clears the LOCK pill", function()
		t.eq(Tut.cardBottomAbove(186, nil), 186, "no pill")
		t.eq(Tut.cardBottomAbove(186, 170), 186, "pill inside the garage is already cleared")
		t.eq(Tut.cardBottomAbove(186, 208), 216, "pill above HOME pushes the card up")
		t.eq(Tut.cardBottomAbove(276, 208), 276, "theft timer clearance wins")
		t.eq(Tut.cardBottomAbove(186, 0 / 0), 186, "NaN ignored")
		-- the inside-the-garage pill fits under CARD_BOTTOM
		t.ok((GarageClient._lockTop(true, 112) :: number) + 8 <= 186, "CARD_BOTTOM clears the inside pill")
	end)

	t.test("HUD: Reset Character only while not wanted (F3)", function()
		t.eq(HUD.resetAllowed(0), true)
		t.eq(HUD.resetAllowed(nil), true)
		t.eq(HUD.resetAllowed(1), false)
		t.eq(HUD.resetAllowed(5), false)
		t.eq(HUD.resetAllowed(0 / 0), true)
	end)

	t.test("Stolen-car alert subtitle counts down (F3)", function()
		local plain = Notif.alertSubtitle(nil, false, nil, 100)
		t.ok(plain:find("BONK", 1, true) ~= nil, "default call to action")
		local live = Notif.alertSubtitle(200, false, nil, 100)
		t.ok(live:find("1:40", 1, true) ~= nil, "thief time left: " .. live)
		local over = Notif.alertSubtitle(90, false, nil, 100)
		t.eq(over, plain, "past deadline -> plain text")
		local dropped = Notif.alertSubtitle(200, true, 112, 100)
		t.ok(dropped:find("RECOVER", 1, true) ~= nil and dropped:find("0:12", 1, true) ~= nil, dropped)
		local late = Notif.alertSubtitle(200, true, 90, 100)
		t.ok(late:find("0:00", 1, true) ~= nil, "never negative: " .. late)
		t.eq(Notif.alertSubtitle(0 / 0, false, nil, 100), plain, "NaN deadline")
	end)

	-------------------------------------------------------------------------------------------------------------
	-- TheftService: no re-entry into a dropped car inside a locked garage (lock push-out loop)
	-------------------------------------------------------------------------------------------------------------
	H.setMode("server")
	local Theft = H.require("src/server/Systems/TheftService")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local Economy = H.require("src/shared/Config/Economy")

	local clock = 5000
	local datas, plots, locked, roots, cars = {}, {}, {}, {}, {}
	local fired = {}
	local carsFolder = R.Instance.new("Folder")

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
		}
	end

	local theftMocks = {
		GarageService = {
			getSlotState = function()
				return "Parked"
			end,
			setSlotState = function() end,
			restoreSlot = function() end,
			freeSlots = function(p)
				local n = 0
				for i = 1, 4 do
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
			incomePerSec = function()
				return 10
			end,
		},
		DataService = {
			get = function(p)
				return datas[p]
			end,
			addCash = function(p, amount)
				datas[p].cash += amount
			end,
			markDirty = function() end,
		},
		PlotService = {
			PAD_TOP = 0.25,
			getPlotIndex = function(p)
				return plots[p]
			end,
			isLocked = function(i)
				return locked[i] == true
			end,
			isInside = function()
				return true
			end,
		},
		VehicleService = {
			spawn = function(carId, mutation, cf, kind)
				local model = R.Instance.new("Model")
				model.WorldPivot = cf
				model.Parent = carsFolder
				local car = { carId = carId, mutation = mutation, kind = kind, model = model, data = {}, _alive = true }
				table.insert(cars, car)
				return car
			end,
			seat = function(car, p)
				car.driver = p
				return true
			end,
			eject = function(car)
				car.driver = nil
			end,
			destroy = function(car)
				car._alive = false
			end,
			getDriving = function()
				return nil
			end,
		},
		WantedService = { addHeat = function() end },
		RewardsService = { progress = function() end },
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
			return theftMocks[name]
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
		fireAll = function() end,
		fireNear = function() end,
		spawnTask = function(fn, ...)
			fn(...)
		end,
		defer = function(fn, ...)
			fn(...)
		end,
	})

	local thief, victim, other
	local function setup()
		Theft._reset()
		table.clear(cars)
		table.clear(fired)
		clock += 1000
		thief = fakePlayer("Thief", 11)
		victim = fakePlayer("Victim", 12)
		other = fakePlayer("Other", 13)
		datas[thief] = { cash = 0, garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } } }
		datas[victim] = {
			cash = 0,
			garage = {
				["1"] = { carId = "viper_strike", mutation = "None", uncollected = 0 },
				["2"] = { carId = "rustbucket", mutation = "None", uncollected = 0 },
				["3"] = { carId = "yellow_cab", mutation = "None", uncollected = 0 },
			},
		}
		datas[other] = { cash = 0, garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } } }
		plots[victim], plots[thief], plots[other] = 1, 2, 3
		locked[1] = false
		roots[thief] = { Position = MapLayout.slotWorld(1, 1).Position + R.Vector3.new(0, 3, 0) }
		roots[victim] = { Position = MapLayout.slotWorld(1, 5).Position }
		roots[other] = { Position = MapLayout.slotWorld(1, 1).Position + R.Vector3.new(4, 3, 0) }
	end

	local function dropCar()
		t.ok(Theft.beginTheft(thief, victim, 1), "theft starts")
		local car = cars[1]
		car.driver = nil
		Theft._onDriverChanged(car, nil, thief)
		local theft = Theft.getActiveTheft(thief)
		t.ok(theft and theft.dropped, "dropped")
		return car, theft
	end

	t.test("locked garage: nobody but the owner gets back into the dropped car", function()
		setup()
		local car, theft = dropCar()
		t.ok(MapLayout.plotAt(car.model:GetPivot().Position) == 1, "the car sits inside the victim's garage")
		locked[1] = true -- the owner locked up: PlotService pushed the thief out on foot
		local ok, why = Theft._canTakeover(theft, thief)
		t.ok(not ok, "the pushed-out thief can't re-hotwire through the gate")
		t.eq(why, "🔒 Garage locked!")
		ok, why = Theft._canTakeover(theft, other)
		t.ok(not ok and why == "🔒 Garage locked!", "nor can anyone else")
		t.ok(not Theft._takeover(theft, thief), "takeover refused")
		t.eq(car.driver, nil, "nobody seated")
		t.ok(theft.dropped and not theft.finished, "still dropped for the owner")

		locked[1] = false -- lock expired: fair game again
		t.ok((Theft._canTakeover(theft, thief)), "unlocked: the thief may get back in")

		locked[1] = true
		car.model.WorldPivot = MapLayout.plotToWorld(1, R.Vector3.new(0, 0, -120)) -- out on the street
		t.ok(MapLayout.plotAt(car.model:GetPivot().Position) ~= 1, "outside the garage")
		t.ok((Theft._canTakeover(theft, other)), "a lock only guards cars inside the garage")
	end)

	t.test("locked garage: the owner still recovers the dropped car", function()
		setup()
		local car = dropCar()
		locked[1] = true
		t.ok(Theft.recover(car, victim), "recover works through the lock")
		t.eq(Theft.getActiveTheft(thief), nil, "theft over")
	end)

	t.test("hijack re-stamps TheftEndsAt for the victim's countdown", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		local car = cars[1]
		t.eq(car.model:GetAttribute("TheftEndsAt"), clock + Economy.THEFT_TIME_LIMIT + 5000, "initial deadline")
		clock += Economy.THEFT_TIME_LIMIT - 10 -- almost out of time
		car.driver = nil
		Theft._onDriverChanged(car, nil, thief)
		local theft = Theft.getActiveTheft(thief)
		t.ok(Theft._takeover(theft, other), "hijacked")
		t.eq(theft.endsAt, clock + Theft.TAKEOVER_MIN_TIME, "the hijacker gets the minimum time")
		t.eq(car.model:GetAttribute("TheftEndsAt"), theft.endsAt + 5000, "attribute follows the new deadline")
	end)

	t.test("a tainted stolen car ends the theft on the next tick", function()
		setup()
		t.ok(Theft.beginTheft(thief, victim, 1))
		cars[1].data.tainted = true
		Theft._tick(clock + 0.5)
		t.eq(Theft.getActiveTheft(thief), nil, "failed right away, not at the time limit")
		t.eq(cars[1]._alive, false, "car gone home")
	end)

	-------------------------------------------------------------------------------------------------------------
	-- RewardsService: reward cars wait out an active heist (player-theft F10)
	-------------------------------------------------------------------------------------------------------------
	local Rewards = H.require("src/server/Systems/RewardsService")
	local Monet = H.require("src/server/Systems/MonetizationService")
	local DataService = H.require("src/server/Systems/DataService")
	local Net = H.require("src/shared/Net")
	local EconomyMath = H.require("src/shared/Util/EconomyMath")
	local Cars = H.require("src/shared/Config/Cars")

	local sent = {}
	local savedNet = { fireClient = Net.fireClient, fireNear = Net.fireNear, fireAll = Net.fireAll }
	Net.fireClient = function(name, _player, ...)
		table.insert(sent, { name = name, args = { ... } })
	end
	Net.fireNear = function() end
	Net.fireAll = function() end
	local function lastNotify()
		for i = #sent, 1, -1 do
			if sent[i].name == "Notify" then
				return sent[i].args[2]
			end
		end
		return ""
	end

	local player = fakePlayer("Claimer", 4343)
	player.Parent = nil
	local data
	local capacity = 3
	local activeTheft = nil
	local function garageCount()
		local n = 0
		for _ in data.garage do
			n += 1
		end
		return n
	end
	local fakeGarage = {
		incomePerSec = function()
			return 10
		end,
		storeCar = function(_p, carId, mutation)
			for i = 1, capacity do
				if not data.garage[tostring(i)] then
					data.garage[tostring(i)] = { carId = carId, mutation = mutation, uncollected = 0 }
					return true, i
				end
			end
			return false, "full"
		end,
		freeSlots = function()
			return capacity - garageCount()
		end,
		discover = function(_p, carId)
			data.discovered[carId] = true
			return true
		end,
	}
	local fakeData = {
		isLoaded = function()
			return true
		end,
		get = function()
			return data
		end,
		markDirty = function() end,
		addCash = function(_p, amount)
			data.cash += amount
			return data.cash
		end,
	}
	Rewards._inject("DataService", fakeData)
	Rewards._inject("GarageService", fakeGarage)
	Rewards._inject("TheftService", {
		getActiveTheft = function()
			return activeTheft
		end,
	})
	Rewards._inject("MonetizationService", {
		hasPass = function()
			return false
		end,
	})
	Rewards._inject("PlotService", {
		getPlotIndex = function()
			return nil
		end,
	})

	local today = EconomyMath.dayNumber(os.time())
	local function freshData()
		table.clear(sent)
		return {
			cash = 0,
			garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } },
			discovered = {},
			daily = { streak = 6, lastClaimDay = today - 1 }, -- next claim is day 7: a car
			codes = {},
			contracts = { day = 0, list = {} },
			exclusives = {},
		}
	end

	t.test("rewards: defer rule", function()
		t.eq(Rewards._deferCarGrant(false, 0), false, "no heist")
		t.eq(Rewards._deferCarGrant(true, 2), false, "room for both")
		t.eq(Rewards._deferCarGrant(true, 1), true, "the last slot belongs to the heist")
		t.eq(Rewards._deferCarGrant(true, 0), true)
		t.eq(Rewards._deferCarGrant(true, nil), true, "unknown slots: wait")
		t.eq(Rewards._deferCarGrant(true, 0 / 0), true, "NaN: wait")
		local list = Rewards._pendingCars({
			{ carId = "rustbucket", mutation = "Gold", reason = "daily" },
			{ carId = "no_such_car", mutation = "None" },
			"junk",
			{ carId = "yellow_cab", mutation = "Bogus" },
		})
		t.eq(#list, 2, "junk dropped")
		t.eq(list[1].mutation, "Gold")
		t.eq(list[2].mutation, "None", "bad mutation -> None")
		t.eq(list[2].reason, "reward", "default reason")
		t.eq(#Rewards._pendingCars(nil), 0)
	end)

	t.test("rewards: a day-7 car claimed mid-heist waits for the heist to end", function()
		data = freshData()
		capacity = 2 -- one free slot: the stolen car's
		activeTheft = { id = 1 }
		t.ok(Rewards.carGrantBlocked(player), "blocked mid-heist")
		t.ok(Rewards.claimDaily(player), "the claim itself goes through")
		t.eq(data.daily.lastClaimDay, today, "claimed today")
		t.eq(garageCount(), 1, "the free slot stays free for the stolen car")
		t.eq(#data.pendingCars, 1, "car owed")
		t.eq(data.cash, 0, "not swapped for cash")
		t.eq(Cars.get(data.pendingCars[1].carId).rarity, "Epic", "the day-7 roll is kept")
		t.eq(Rewards.deliverPendingCars(player), 0, "still blocked")
		t.eq(#data.pendingCars, 1, "still owed")

		activeTheft = nil -- heist over (delivered elsewhere / failed)
		t.eq(Rewards.deliverPendingCars(player), 1, "delivered")
		t.eq(garageCount(), 2, "parked")
		t.eq(data.pendingCars, nil, "queue cleared")
		t.ok(lastNotify():find("rolled into your garage", 1, true) ~= nil, lastNotify())
		t.eq(Rewards.deliverPendingCars(player), 0, "never twice")
		t.eq(garageCount(), 2)
	end)

	t.test("rewards: owed car swapped for cash when the heist filled the garage", function()
		data = freshData()
		capacity = 2
		activeTheft = { id = 2 }
		Rewards.claimDaily(player)
		t.eq(#data.pendingCars, 1)
		activeTheft = nil
		data.garage["2"] = { carId = "viper_strike", mutation = "None", uncollected = 0 } -- the stolen car parked
		t.eq(Rewards.deliverPendingCars(player), 1)
		t.ok(data.cash >= 500, "cash fallback")
		t.eq(data.pendingCars, nil)
	end)

	t.test("rewards: no deferral with room to spare or without a heist", function()
		data = freshData()
		capacity = 3 -- two free
		activeTheft = { id = 3 }
		t.ok(not Rewards.carGrantBlocked(player))
		Rewards.claimDaily(player)
		t.eq(garageCount(), 2, "stored right away")
		t.eq(data.pendingCars, nil)
		data = freshData()
		capacity = 2
		activeTheft = nil
		Rewards.claimDaily(player)
		t.eq(garageCount(), 2, "no heist: stored right away")
	end)

	t.test("monetization: owed exclusives wait out the heist; lockdown toast", function()
		local savedGet, savedLoaded, savedDirty = DataService.get, DataService.isLoaded, DataService.markDirty
		DataService.get = function()
			return data
		end
		DataService.isLoaded = function()
			return true
		end
		DataService.markDirty = function() end
		data = freshData()
		data.exclusives = { diamond_dragster = true }
		capacity = 2
		activeTheft = { id = 4 }
		local ok, delivered = pcall(Monet.deliverExclusives, player)
		DataService.get, DataService.isLoaded, DataService.markDirty = savedGet, savedLoaded, savedDirty
		t.ok(ok, tostring(delivered))
		t.eq(delivered, 0, "nothing delivered mid-heist")
		t.eq(data.exclusives.diamond_dragster, true, "still owed")
		t.eq(garageCount(), 1, "slot kept free")
		activeTheft = nil

		t.eq(Monet._lockdownText(600, 600), "🔒 LOCKDOWN! Your garage is sealed for 10 minutes.")
		t.eq(Monet._lockdownText(600, nil), "🔒 LOCKDOWN! Your garage is sealed for 10 minutes.")
		local stacked = Monet._lockdownText(600, 900)
		t.ok(stacked:find("+10 min", 1, true) ~= nil and stacked:find("15:00", 1, true) ~= nil, stacked)
	end)

	Net.fireClient, Net.fireNear, Net.fireAll = savedNet.fireClient, savedNet.fireNear, savedNet.fireAll
	for _, name in { "DataService", "GarageService", "TheftService", "MonetizationService", "PlotService" } do
		Rewards._inject(name, nil)
	end
end
