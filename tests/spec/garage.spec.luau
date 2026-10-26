--!nocheck
-- Plots + garage: buildGarageModel structure/geometry and GarageService pure helpers.
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local Economy = H.require("src/shared/Config/Economy")
	local EconomyMath = H.require("src/shared/Util/EconomyMath")
	local PlotService = H.require("src/server/Systems/PlotService")
	local GarageService = H.require("src/server/Systems/GarageService")
	local G = MapConfig.Garage

	local models = {}
	local function plot(i)
		if not models[i] then
			models[i] = PlotService.buildGarageModel(i)
		end
		return models[i]
	end

	local function toLocal(i, pos)
		return MapLayout.plotOrigin(i):PointToObjectSpace(pos)
	end

	t.test("buildGarageModel has every named part other systems rely on", function()
		for i = 1, MapLayout.plotCount() do
			local m = plot(i)
			t.eq(m.Name, "Plot" .. i, "model name")
			t.eq(m:GetAttribute("PlotIndex"), i, "PlotIndex attr")
			for _, name in
				{
					"Dropoff",
					"DropoffMark",
					"CollectPad",
					"CollectSign",
					"LockButton",
					"LockSign",
					"Gate",
					"OwnerSpawn",
					"Sign",
					"StatusLight",
				}
			do
				local c = m:FindFirstChild(name)
				t.ok(c and c:IsA("BasePart"), ("plot %d missing part %s"):format(i, name))
			end
			local display = m:FindFirstChild("Display")
			t.ok(display and display:IsA("Folder"), "Display folder")
			local signGui = m.Sign:FindFirstChild("SignGui")
			t.ok(signGui and signGui:IsA("SurfaceGui"), "SignGui")
			t.eq(signGui.Face, H.roblox.Enum.NormalId.Front, "sign faces out")
			local owner = signGui:FindFirstChild("OwnerName")
			t.ok(owner and owner:IsA("TextLabel"), "OwnerName label")
			for slot = 1, MapLayout.maxPhysicalSlots() do
				local pad = m:FindFirstChild("Pad" .. slot)
				t.ok(pad and pad:IsA("BasePart"), "Pad" .. slot)
				t.eq(pad:GetAttribute("Slot"), slot, "pad Slot attr")
				t.eq(pad:GetAttribute("Locked"), false, "pad Locked attr")
				local gui = pad:FindFirstChild("PadGui")
				t.ok(gui and gui:IsA("SurfaceGui"), "PadGui")
				t.ok(gui.Root:FindFirstChild("Number") and gui.Root:FindFirstChild("Lock"), "pad gui children")
				local sign = pad:FindFirstChild("Sign")
				t.ok(sign and sign:FindFirstChild("SignGui"), "bay sign")
			end
		end
	end)

	t.test("pads sit on the floor at MapLayout.slotWorld positions", function()
		for i = 1, MapLayout.plotCount() do
			local m = plot(i)
			for slot = 1, MapLayout.maxPhysicalSlots() do
				local pad = m["Pad" .. slot]
				local want = MapLayout.slotWorld(i, slot).Position
				local got = pad.CFrame.Position
				t.near(got.X, want.X, 1e-3, ("plot %d pad %d X"):format(i, slot))
				t.near(got.Z, want.Z, 1e-3, ("plot %d pad %d Z"):format(i, slot))
				t.near(
					got.Y,
					MapLayout.CURB_TOP + PlotService.FLOOR_LIFT + PlotService.PAD_THICKNESS / 2,
					1e-3,
					"pad Y"
				)
				-- footprint matches SLOT_PAD_SIZE in plot axes
				local lx = math.abs(pad.CFrame.RightVector:Dot(MapLayout.plotOrigin(i).RightVector))
				local alongX = if lx > 0.9 then pad.Size.X else pad.Size.Z
				t.near(alongX, G.SLOT_PAD_SIZE.X, 1e-3, "pad length along plot X")
			end
		end
	end)

	t.test("pads don't overlap each other or the drop-off", function()
		local m = plot(1)
		local dcf, dsize = MapLayout.plotDropoffZone(1)
		for a = 1, MapLayout.maxPhysicalSlots() do
			local pa = toLocal(1, m["Pad" .. a].CFrame.Position)
			t.ok(not MapLayout.isInBox(dcf, dsize, m["Pad" .. a].CFrame.Position), "pad in dropoff")
			for b = a + 1, MapLayout.maxPhysicalSlots() do
				local pb = toLocal(1, m["Pad" .. b].CFrame.Position)
				local sepX = math.abs(pa.X - pb.X) >= G.SLOT_PAD_SIZE.X - 1e-3
				local sepZ = math.abs(pa.Z - pb.Z) >= G.SLOT_PAD_SIZE.Z - 1e-3
				t.ok(sepX or sepZ, ("pads %d and %d overlap"):format(a, b))
			end
		end
	end)

	t.test("gate spans the door opening and starts unlocked", function()
		for i = 1, MapLayout.plotCount() do
			local gate = plot(i).Gate
			local lp = toLocal(i, gate.CFrame.Position)
			t.near(lp.X, 0, 1e-3, "gate centered")
			t.ok(
				lp.Z > G.FRONT_Z - 0.01 and lp.Z < G.FRONT_Z + G.WALL_THICKNESS + 0.01,
				"gate inside the front wall plane"
			)
			t.near(gate.Size.X, G.DOOR_WIDTH, 1e-3, "gate width = door width")
			t.ok(gate.Size.Y >= G.DOOR_HEIGHT - 0.01, "gate covers door height")
			t.near(lp.Y - gate.Size.Y / 2, PlotService.FLOOR_LIFT, 0.06, "gate reaches the floor")
			t.eq(gate.CanCollide, false, "gate unlocked collide")
			t.eq(gate.Transparency, 1, "gate unlocked invisible")
			local beams = 0
			for _, c in gate:GetChildren() do
				if c:IsA("BasePart") then
					beams += 1
					t.eq(c.CanCollide, false, "beam non-collide")
				end
			end
			t.ok(beams >= 2, "gate has laser beams")
			-- the door opening is actually open: no collidable wall part crosses the doorway at waist height
			for _, d in plot(i):GetDescendants() do
				if d:IsA("BasePart") and d.CanCollide and d.Name ~= "Gate" and d.Name ~= "Floor" then
					local p = toLocal(i, d.CFrame.Position)
					local half = d.Size / 2
					local blocksDoor = math.abs(p.X) < half.X
						and math.abs(p.Y - 4) < half.Y
						and math.abs(p.Z - (G.FRONT_Z + G.WALL_THICKNESS / 2)) < half.Z
					t.ok(
						not blocksDoor or d.Name:find("Wheel") ~= nil,
						("plot %d: %s blocks the door"):format(i, d.Name)
					)
				end
			end
		end
	end)

	t.test("dropoff, collect, lock, spawn and sign are where Config says", function()
		for i = 1, MapLayout.plotCount() do
			local m = plot(i)
			local dcf, dsize = MapLayout.plotDropoffZone(i)
			local z = m.Dropoff
			t.ok((z.CFrame.Position - dcf.Position).Magnitude < 1e-3, "dropoff position")
			t.ok((z.Size - dsize).Magnitude < 1e-3, "dropoff size")
			t.eq(z.CanCollide, false, "dropoff collide")
			t.eq(z.CanQuery, false, "dropoff query")
			t.eq(z.CanTouch, false, "dropoff touch")
			t.eq(z.Transparency, 1, "dropoff invisible")
			local cp = toLocal(i, m.CollectPad.CFrame.Position)
			t.near(cp.X, G.COLLECT_CENTER.X, 1e-3, "collect x")
			t.near(cp.Z, G.COLLECT_CENTER.Z, 1e-3, "collect z")
			t.eq(m.CollectPad.CanTouch, true, "collect touch")
			t.eq(m.CollectPad.Material, H.roblox.Enum.Material.Neon, "collect neon")
			local lb = toLocal(i, m.LockButton.CFrame.Position)
			t.near(lb.X, G.LOCK_BUTTON.X, 1e-3, "lock x")
			t.ok(math.abs(lb.Z - G.LOCK_BUTTON.Z) < 1, "lock z")
			t.eq(m.LockButton.CanTouch, true, "lock touch")
			local os_ = toLocal(i, m.OwnerSpawn.CFrame.Position)
			t.near(os_.X, G.OWNER_SPAWN.X, 1e-3, "spawn x")
			t.near(os_.Z, G.OWNER_SPAWN.Z, 1e-3, "spawn z")
			t.eq(m.OwnerSpawn.CanCollide, false, "spawn collide")
			t.eq(m.OwnerSpawn.Transparency, 1, "spawn invisible")
			-- owner spawn faces out of the door
			t.ok(m.OwnerSpawn.CFrame.LookVector:Dot(MapLayout.plotOrigin(i).LookVector) > 0.99, "spawn faces door")
			local sp = toLocal(i, m.Sign.CFrame.Position)
			t.ok((sp - G.SIGN).Magnitude < 1e-3, "sign at Garage.SIGN")
			t.ok(
				MapLayout.plotAt(PlotService.ownerSpawnCFrame(i).Position + Vector3.new(0, 3, 0)) == i,
				"spawn inside own plot"
			)
		end
	end)

	t.test("garage parts stay inside the lot and the budget", function()
		for i = 1, MapLayout.plotCount() do
			local m = plot(i)
			local n = 0
			local halfLot = (MapConfig.GRID_SPACING - MapConfig.ROAD_WIDTH) / 2
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then
					n += 1
					local p = toLocal(i, d.CFrame.Position)
					t.ok(math.abs(p.X) <= halfLot + 0.01, d.Name .. " outside lot X")
					-- the curb ramp may poke onto the road edge
					t.ok(p.Z >= -halfLot - 4.01 and p.Z <= halfLot + 0.01, d.Name .. " outside lot Z")
					t.eq(d.Anchored, true, d.Name .. " anchored")
				end
			end
			t.ok(n <= 260, "part budget per garage: " .. n)
		end
	end)

	t.test("plot accents are distinct", function()
		local seen = {}
		for i = 1, MapLayout.plotCount() do
			local c = PlotService.accentFor(i)
			local key = ("%d,%d,%d"):format(c.R * 255, c.G * 255, c.B * 255)
			t.ok(not seen[key], "duplicate accent for plot " .. i)
			seen[key] = true
		end
	end)

	t.test("push-out spots are outside the interior, on the lot", function()
		for i = 1, MapLayout.plotCount() do
			local icf, isize = MapLayout.plotInteriorZone(i)
			for n = 1, 6 do
				local cf = MapLayout.plotToWorld(i, PlotService._drivewayOffset(n))
				t.ok(
					not MapLayout.isInBox(icf, isize, cf.Position + Vector3.new(0, 3, 0)),
					"push-out spot inside garage"
				)
				local lp = toLocal(i, cf.Position)
				t.ok(lp.Z > -(MapConfig.GRID_SPACING - MapConfig.ROAD_WIDTH) / 2, "push-out spot on the road")
			end
		end
	end)

	t.test("lock duration", function()
		t.eq(PlotService._lockDuration(0, 0), EconomyMath.upgradeValue("lock", 0), "base")
		t.eq(PlotService._lockDuration(3, 2), EconomyMath.upgradeValue("lock", 3) + 20, "level 3 + 2 rebirths")
		t.eq(PlotService._lockDuration(99, 0), EconomyMath.upgradeValue("lock", 3), "level clamp")
	end)

	t.test("slot capacity and max slots", function()
		local phys = MapLayout.maxPhysicalSlots()
		t.eq(GarageService._capacity(Economy.START_SLOTS, false), Economy.START_SLOTS, "start")
		t.eq(GarageService._capacity(Economy.START_SLOTS, true), Economy.START_SLOTS + Economy.PASS_EXTRA_SLOTS, "pass")
		t.eq(GarageService._capacity(Economy.MAX_SLOTS + 5, false), Economy.MAX_SLOTS, "cash cap")
		t.eq(
			GarageService._capacity(Economy.MAX_SLOTS, true),
			math.min(Economy.MAX_SLOTS + Economy.PASS_EXTRA_SLOTS, phys),
			"max"
		)
		t.eq(GarageService._maxSlots(false), math.min(Economy.MAX_SLOTS, phys), "maxSlots no pass")
		t.eq(
			GarageService._maxSlots(true),
			math.min(Economy.MAX_SLOTS + Economy.PASS_EXTRA_SLOTS, phys),
			"maxSlots pass"
		)
		t.ok(GarageService._maxSlots(true) <= phys, "never more than the physical pads")
	end)

	t.test("first free slot", function()
		local garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } }
		t.eq(GarageService._firstFreeSlot(garage, 4), 2, "next")
		garage["2"] = garage["1"]
		garage["3"] = garage["1"]
		garage["4"] = garage["1"]
		t.eq(GarageService._firstFreeSlot(garage, 4), nil, "full")
		t.eq(GarageService._firstFreeSlot(garage, 6), 5, "pass slots")
		garage["2"] = nil
		t.eq(GarageService._firstFreeSlot(garage, 4), 2, "hole")
	end)

	t.test("pad info: prices, next unlock, pass pads", function()
		local s = Economy.START_SLOTS
		local a = GarageService._padInfo(s, s, false)
		t.eq(a.locked, false, "owned slot unlocked")
		local b = GarageService._padInfo(s + 1, s, false)
		t.eq(b.locked, true, "next locked")
		t.eq(b.nextUnlock, true, "next flagged")
		t.eq(b.price, Economy.SLOT_PRICES[s + 1], "next price")
		local c = GarageService._padInfo(s + 2, s, false)
		t.eq(c.nextUnlock, false, "only one next")
		t.eq(c.price, Economy.SLOT_PRICES[s + 2], "later price")
		local d = GarageService._padInfo(Economy.MAX_SLOTS + 1, s, false)
		t.eq(d.passOnly, true, "pass pad")
		t.eq(d.price, 0, "pass pad no cash price")
		-- with the pass, the two extra pads come first and prices shift back
		local e = GarageService._padInfo(s + 2, s, true)
		t.eq(e.locked, false, "pass slots usable")
		local f = GarageService._padInfo(s + 3, s, true)
		t.eq(f.nextUnlock, true, "next after pass slots")
		t.eq(f.price, Economy.SLOT_PRICES[s + 1], "price follows purchase count")
		local g = GarageService._padInfo(MapLayout.maxPhysicalSlots(), s, true)
		t.eq(g.passOnly, false, "no pass pads when owned")
		t.eq(g.price, Economy.SLOT_PRICES[Economy.MAX_SLOTS], "last price")
		local h = GarageService._padInfo(Economy.MAX_SLOTS + 1, Economy.MAX_SLOTS, false)
		t.eq(h.passOnly, true, "all cash slots bought -> pass pad")
		t.eq(h.nextUnlock, false, "nothing to buy with cash")
	end)

	t.test("income accrual only on Parked slots", function()
		local garage = {
			["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 },
			["2"] = { carId = "rustbucket", mutation = "Gold", uncollected = 10 },
			["3"] = { carId = "rustbucket", mutation = "None", uncollected = 5 },
		}
		local states = { [3] = "Driving" }
		local base = EconomyMath.carIncome("rustbucket", "None")
		local total = GarageService._accrue(garage, states, 2, 1.5)
		t.near(total, base * 2 + base * 2 * 2, 1e-6, "income/s")
		t.near(garage["1"].uncollected, base * 2 * 1.5, 1e-6, "slot1")
		t.near(garage["2"].uncollected, 10 + base * 2 * 2 * 1.5, 1e-6, "slot2 gold")
		t.near(garage["3"].uncollected, 5, 1e-6, "driving slot frozen")
		states[3] = "BeingStolen"
		GarageService._accrue(garage, states, 1, 10)
		t.near(garage["3"].uncollected, 5, 1e-6, "stolen slot frozen")
		local empty = GarageService._accrue({}, {}, 3, 1)
		t.eq(empty, 0, "empty garage")
	end)

	t.test("steal hold timing", function()
		local base = GarageService._baseStealHold("rustbucket")
		t.ok(base > 0, "base hold")
		t.near(GarageService._requiredHold(base, 1), base * 0.9, 1e-6, "slack")
		t.ok(GarageService._requiredHold(base, 0.5) < GarageService._requiredHold(base, 1), "upgrades shorten")
		t.near(GarageService._baseStealHold("does_not_exist"), Economy.THEFT_HOLD_MULTIPLIER, 1e-6, "unknown car")
	end)

	t.test("GarageService flows with fake systems", function()
		local Net = H.require("src/shared/Net")
		local Cars = H.require("src/shared/Config/Cars")
		local saved = { fireClient = Net.fireClient, fireNear = Net.fireNear, fireAll = Net.fireAll }
		local fired = {}
		Net.fireClient = function(name, _p, ...)
			table.insert(fired, { name = name, args = { ... } })
		end
		Net.fireNear = function(name, _pos, _r, ...)
			table.insert(fired, { name = name, args = { ... } })
		end
		Net.fireAll = function(name, ...)
			table.insert(fired, { name = name, args = { ... } })
		end
		local function count(name)
			local n = 0
			for _, f in fired do
				if f.name == name then
					n += 1
				end
			end
			return n
		end

		local attrs = {}
		local player = { UserId = 77, Name = "Tester", DisplayName = "Tester", Parent = H.game, Character = nil }
		function player:SetAttribute(k, v)
			attrs[k] = v
		end
		function player:GetAttribute(k)
			return attrs[k]
		end
		local data = {
			cash = 0,
			rebirths = 0,
			slotsUnlocked = Economy.START_SLOTS,
			garage = { ["1"] = { carId = "rustbucket", mutation = "None", uncollected = 0 } },
			discovered = { rustbucket = true },
			upgrades = { lock = 0, hotwire = 0, nitro = 0, armor = 0 },
			stats = { steals = 0, playerSteals = 0, busted = 0, hotDrops = 0, timesRobbed = 0 },
		}
		local model = PlotService.buildGarageModel(1)
		local progressLog = {}
		local destroyed = {}
		GarageService._inject("DataService", {
			get = function(p)
				return if p == player then data else nil
			end,
			markDirty = function() end,
			addCash = function(_p, a)
				data.cash += a
				return data.cash
			end,
			spendCash = function(_p, a)
				if data.cash >= a then
					data.cash -= a
					return true
				end
				return false
			end,
		})
		GarageService._inject("PlotService", {
			getPlotIndex = function()
				return 1
			end,
			getPlotModel = function()
				return model
			end,
			getDisplayFolder = function()
				return nil -- no display cars in the harness (ProximityPrompt events don't exist in Lune)
			end,
			PAD_TOP = PlotService.PAD_TOP,
		})
		GarageService._inject("MonetizationService", {
			hasPass = function()
				return false
			end,
		})
		GarageService._inject("RewardsService", {
			progress = function(_p, stat, _n)
				table.insert(progressLog, stat)
			end,
			friendsInServer = function()
				return 0
			end,
			isInGroup = function()
				return false
			end,
		})
		GarageService._inject("EventService", {
			getIncomeMultiplier = function()
				return 1
			end,
		})
		GarageService._inject("VehicleService", {
			destroy = function(car, reason)
				destroyed[car] = reason
			end,
			eject = function() end,
			getDriving = function()
				return nil
			end,
		})

		local ok, err = pcall(function()
			-- store
			local stored, slot = GarageService.storeCar(player, "grandma_sedan", "Gold")
			t.eq(stored, true, "store ok")
			t.eq(slot, 2, "first free slot")
			t.eq(GarageService.ownedCount(player), 2, "owned")
			t.eq(GarageService.freeSlots(player), Economy.START_SLOTS - 2, "free")
			t.eq(GarageService.capacity(player), Economy.START_SLOTS, "capacity")
			t.eq(GarageService.maxSlots(player), Economy.MAX_SLOTS, "max slots")
			t.eq(model.Pad2:GetAttribute("State"), "Parked", "pad state")
			t.eq(model.Pad3:GetAttribute("State"), "Empty", "empty pad")
			local nextPad = model["Pad" .. (Economy.START_SLOTS + 1)]
			t.eq(nextPad:GetAttribute("Locked"), true, "next pad locked")
			t.eq(nextPad:GetAttribute("NextUnlock"), true, "next pad flagged")
			t.eq(nextPad:GetAttribute("Price"), Economy.SLOT_PRICES[Economy.START_SLOTS + 1], "next pad price")
			t.eq(model:GetAttribute("CarCount"), 2, "plot car count")
			local bad = { GarageService.storeCar(player, "nope", "None") }
			t.eq(bad[1], false, "bad car")
			t.eq(bad[2], "badcar", "bad car reason")

			local r = EconomyMath.carIncome("rustbucket", "None")
			local g = EconomyMath.carIncome("grandma_sedan", "Gold")
			t.near(GarageService.incomePerSec(player), r + g, 1e-6, "income")
			t.near(GarageService.multiplier(player), 1, 1e-6, "multiplier")

			-- states
			GarageService.setSlotState(player, 2, "BeingStolen")
			t.eq(GarageService.getSlotState(player, 2), "BeingStolen", "being stolen")
			t.eq(model.Pad2:GetAttribute("State"), "BeingStolen", "pad shows theft")
			t.near(GarageService.incomePerSec(player), r, 1e-6, "stolen slot earns nothing")
			GarageService.restoreSlot(player, 2)
			t.eq(GarageService.getSlotState(player, 2), "Parked", "restored")
			t.eq(GarageService.getSlotState(player, 9), nil, "no record")

			-- fill up
			t.eq(select(2, GarageService.storeCar(player, "rustbucket", "None")), 3, "slot 3")
			t.eq(select(2, GarageService.storeCar(player, "rustbucket", "None")), 4, "slot 4")
			local full = { GarageService.storeCar(player, "rustbucket", "None") }
			t.eq(full[1], false, "full")
			t.eq(full[2], "full", "full reason")

			-- collect
			data.garage["1"].uncollected = 100.7
			data.garage["2"].uncollected = 50
			local got = GarageService.collect(player)
			t.eq(got, 150, "collected (floored)")
			t.eq(data.cash, 150, "cash added")
			for _, rec in data.garage do
				t.eq(rec.uncollected, 0, "uncollected cleared")
			end
			t.ok(table.find(progressLog, "collectCash") ~= nil, "collect contract")
			t.ok(count("CashPopup") >= 1, "cash popup")
			t.eq(GarageService.collect(player), 0, "nothing left")

			-- snapshots
			local snaps = GarageService.slotSnapshots(player)
			t.eq(snaps["2"].carId, "grandma_sedan", "snapshot car")
			t.eq(snaps["2"].state, "Parked", "snapshot state")
			t.near(snaps["2"].income, g, 1e-6, "snapshot income")

			-- sell (keeps uncollected cash for the seller)
			data.garage["4"].uncollected = 10
			local before = data.cash
			t.eq(GarageService.sell(player, 4), true, "sold")
			t.eq(data.cash - before, EconomyMath.sellValue("rustbucket", "None") + 10, "sell value + uncollected")
			t.eq(GarageService.ownedCount(player), 3, "owned after sell")
			t.eq(model.Pad4:GetAttribute("State"), "Empty", "pad emptied")
			t.eq(GarageService.sell(player, 4), false, "can't sell empty")

			-- unlock the next slot
			data.cash = 0
			GarageService.unlockNextSlot(player)
			t.eq(data.slotsUnlocked, Economy.START_SLOTS, "too poor to unlock")
			data.cash = Economy.SLOT_PRICES[Economy.START_SLOTS + 1]
			GarageService.unlockNextSlot(player)
			t.eq(data.slotsUnlocked, Economy.START_SLOTS + 1, "unlocked")
			t.eq(data.cash, 0, "paid")
			t.eq(nextPad:GetAttribute("Locked"), false, "pad unlocked")

			-- deliveries: loot car goes into the garage, counts a steal, discovers
			local epic
			for _, def in Cars.List do
				if def.rarity == "Epic" then
					epic = def
					break
				end
			end
			local car = { kind = "Loot", carId = epic.id, mutation = "None", data = {}, driver = player }
			GarageService._onDelivery(player, car)
			t.eq(destroyed[car], "delivered", "loot destroyed on delivery")
			t.eq(data.stats.steals, 1, "steal counted")
			t.eq(data.discovered[epic.id], true, "discovered")
			t.ok(table.find(progressLog, "deliverRare") ~= nil, "rare contract")
			t.ok(table.find(progressLog, "deliverEpic") ~= nil, "epic contract")
			t.eq(count("EventFeed"), 1, "epic delivery in the feed")
			GarageService._onDelivery(player, car)
			t.eq(data.stats.steals, 1, "no double count")

			-- garage full -> nothing happens
			GarageService.storeCar(player, "rustbucket", "None")
			local car2 = { kind = "Loot", carId = "rustbucket", mutation = "None", data = {}, driver = player }
			GarageService._onDelivery(player, car2)
			t.eq(destroyed[car2], nil, "full garage keeps the car")

			-- owned car coming home only parks after it left the garage
			GarageService.setSlotState(player, 1, "Driving")
			local own =
				{ kind = "Owned", carId = "rustbucket", mutation = "None", ownerUserId = 77, data = { slot = 1 } }
			GarageService._onDelivery(player, own)
			t.eq(destroyed[own], nil, "leaving car not parked")
			own.data.leftGarage = true
			GarageService._onDelivery(player, own)
			t.eq(destroyed[own], "parked", "returning car parked")
			t.eq(GarageService.getSlotState(player, 1), "Parked", "slot restored")

			-- chop: loot only
			local chopCar = { kind = "Loot", carId = "rustbucket", mutation = "Gold", data = {}, driver = player }
			local cashBefore = data.cash
			GarageService._onChop(player, chopCar)
			t.eq(destroyed[chopCar], "chopped", "chopped")
			t.eq(data.cash - cashBefore, EconomyMath.chopValue("rustbucket", "Gold"), "chop cash")
			local ownedChop = { kind = "Owned", carId = "rustbucket", mutation = "None", data = {}, driver = player }
			GarageService._onChop(player, ownedChop)
			t.eq(destroyed[ownedChop], nil, "owned cars can't be chopped")

			-- remove + income attribute
			local rec = GarageService.removeSlot(player, 2)
			t.eq(rec and rec.carId, "grandma_sedan", "removed record")
			t.eq(GarageService.removeSlot(player, 2), nil, "already removed")
			t.near(attrs.IncomePerSec, GarageService.incomePerSec(player), 1e-6, "IncomePerSec attribute")
		end)
		for _, name in
			{ "DataService", "PlotService", "MonetizationService", "RewardsService", "EventService", "VehicleService" }
		do
			GarageService._inject(name, nil)
		end
		Net.fireClient, Net.fireNear, Net.fireAll = saved.fireClient, saved.fireNear, saved.fireAll
		if not ok then
			error(err, 0)
		end
	end)

	t.test("public API surface", function()
		for _, fn in
			{
				"getPlot",
				"getPlotIndex",
				"getOwner",
				"isLocked",
				"lockFor",
				"plotAt",
				"getPlotModel",
				"getDisplayFolder",
				"buildGarageModel",
				"init",
				"start",
			}
		do
			t.eq(type(PlotService[fn]), "function", "PlotService." .. fn)
		end
		t.ok(PlotService.PlotAssigned and PlotService.PlotReleased, "PlotService signals")
		for _, fn in
			{
				"storeCar",
				"freeSlots",
				"ownedCount",
				"removeSlot",
				"setSlotState",
				"getSlotState",
				"restoreSlot",
				"refresh",
				"incomePerSec",
				"multiplier",
				"slotSnapshots",
				"maxSlots",
				"capacity",
				"discover",
				"collect",
				"init",
				"start",
			}
		do
			t.eq(type(GarageService[fn]), "function", "GarageService." .. fn)
		end
	end)

	local _ = CFrame
end
