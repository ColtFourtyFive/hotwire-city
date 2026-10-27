--!nocheck
-- PlotService lock rules (re-arm, stacking, push-out eject), the plot GUI budget, and GarageClient's pure helpers
-- (free slots, steal-block reasons, pass pad labels).
return function(t)
	local H = t.H
	H.setMode("server")
	local PlotService = H.require("src/server/Systems/PlotService")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	H.setMode("client")
	local GarageClient = H.require("src/client/Controllers/GarageClient")
	H.setMode("server")

	t.test("lock re-arm is proportional to the last lock (DECISIONS #8)", function()
		local min = PlotService.LOCK_REARM
		t.eq(PlotService._rearmSeconds(0), min, "no button lock")
		t.eq(PlotService._rearmSeconds(20), min, "short lock: floor")
		t.eq(PlotService._rearmSeconds(45), math.max(min, 22.5), "level 0")
		t.eq(PlotService._rearmSeconds(120), 60, "level 3")
		t.eq(PlotService._rearmSeconds(0 / 0), min, "NaN")
		t.eq(PlotService._rearmSeconds(-5), min, "negative")
		-- uptime with an instant re-press stays at or below ~2/3
		for _, d in { 45, 60, 90, 120, 160 } do
			local uptime = d / (d + PlotService._rearmSeconds(d))
			t.ok(uptime <= 0.75 + 1e-9, ("uptime %.2f for %ds"):format(uptime, d))
		end
	end)

	t.test("Lockdown purchases stack on a running lock (DECISIONS #7)", function()
		t.eq(PlotService._stackLock(0, 100, 600), 700, "unlocked")
		t.eq(PlotService._stackLock(580, 100, 600), 1180, "8 min left + 10 min = 18 min")
		t.eq(PlotService._stackLock(50, 100, 60), 160, "expired deadline counts from now")
		t.eq(PlotService._stackLock(3000, 100, 3600), 100 + PlotService.MAX_LOCK_SECONDS, "capped")
	end)

	t.test("lock push-out ejects only thieves of this garage's cars (DECISIONS #9)", function()
		t.eq(PlotService._ejectOnLock("Stolen", 42, 42), true, "stolen from the owner")
		t.eq(PlotService._ejectOnLock("Stolen", 7, 42), false, "stolen from someone else")
		t.eq(PlotService._ejectOnLock("Loot", 42, 42), false, "loot leaves with its driver")
		t.eq(PlotService._ejectOnLock("Owned", nil, 42), false, "own car")
		t.eq(PlotService._ejectOnLock("Stolen", nil, 42), false, "no victim recorded")
		t.eq(PlotService._ejectOnLock("Stolen", 42, nil), false, "vacant plot")
		t.eq(PlotService._ejectOnLock("Stolen", 0, 0), false, "no owner id")
	end)

	t.test("plot SurfaceGui budget (PERF-12)", function()
		local model = PlotService.buildGarageModel(1)
		local near, far = 0, 0
		for _, d in model:GetDescendants() do
			if d:IsA("SurfaceGui") then
				if d.MaxDistance <= 250 then
					near += 1
				else
					far += 1
				end
			end
		end
		t.ok(near >= MapLayout.maxPhysicalSlots() * 2, "pad + bay sign GUIs are short-range")
		t.ok(far <= 10, "only banners / murals / gate / owner sign are long-range: " .. far)
		local pad = model:FindFirstChild("Pad1")
		local padGui = pad:FindFirstChild("PadGui")
		t.ok(padGui.PixelsPerStud <= 12, "pad decal resolution")
		t.ok(pad.Sign.SignGui.PixelsPerStud <= 20, "bay sign resolution")
		local gate = model:FindFirstChild("Gate")
		t.eq(gate:FindFirstChild("CountdownGui").MaxDistance, 400, "gate countdown readable from the street")
	end)

	t.test("GarageClient free slots from the snapshot", function()
		t.eq(GarageClient._freeSlots(nil), nil, "no snapshot")
		t.eq(GarageClient._freeSlots({ slotsUnlocked = 4 }), nil, "no garage table")
		local car = { carId = "rustbucket", mutation = "None" }
		t.eq(GarageClient._freeSlots({ slotsUnlocked = 4, maxSlots = 10, garage = {} }), 4, "empty")
		t.eq(
			GarageClient._freeSlots({ slotsUnlocked = 4, maxSlots = 10, garage = { ["1"] = car, ["3"] = car } }),
			2,
			"two parked"
		)
		local full = {}
		for i = 1, 4 do
			full[tostring(i)] = car
		end
		t.eq(GarageClient._freeSlots({ slotsUnlocked = 4, maxSlots = 10, garage = full }), 0, "full")
		local ten = {}
		for i = 1, 10 do
			ten[tostring(i)] = car
		end
		t.eq(GarageClient._freeSlots({ slotsUnlocked = 10, maxSlots = 10, garage = ten }), 0, "maxed, no pass")
		t.eq(GarageClient._freeSlots({ slotsUnlocked = 10, maxSlots = 12, garage = ten }), 2, "+2 slots pass")
	end)

	t.test("GarageClient steal-block reasons follow the server's order (F7)", function()
		t.eq(GarageClient._stealBlock(false, 0, 100, 3), nil, "robbable")
		t.eq(GarageClient._stealBlock(false, 0, 100, nil), nil, "unknown slots never block")
		t.eq(GarageClient._stealBlock(true, 0, 100, 3), "🚨 BEING ROBBED", "busy")
		t.eq(GarageClient._stealBlock(false, 111.2, 100, 3), "🛡️ PROTECTED 0:12", "cooldown")
		t.eq(GarageClient._stealBlock(false, 90, 100, 3), nil, "cooldown over")
		t.eq(GarageClient._stealBlock(false, 0, 100, 0), "📦 YOUR GARAGE IS FULL", "full")
		t.eq(GarageClient._stealBlock(true, 200, 100, 0), "🚨 BEING ROBBED", "busy wins")
		t.eq(GarageClient._stealBlock(false, 200, 100, 0):sub(1, 3), ("🛡️"):sub(1, 3), "cooldown beats full")
	end)

	t.test("GarageClient pass pads never advertise an unbuyable pass (DECISIONS #11)", function()
		local icon, text, color = GarageClient._lockedPadLabel(true, false, true, false, 0)
		t.eq(text, "MAX SLOTS")
		t.eq(icon, "🔒")
		t.eq(color, "TextDim")
		_, text = GarageClient._lockedPadLabel(true, true, true, false, 0)
		t.eq(text, "+2 SLOTS PASS", "pass on sale")
		_, text, color = GarageClient._lockedPadLabel(false, false, true, true, 1500)
		t.eq(text:sub(1, 6), "UNLOCK")
		t.eq(color, "Cash")
		_, text = GarageClient._lockedPadLabel(false, false, false, true, 1500)
		t.eq(text, "LOCKED", "other players' pads")
	end)
end
