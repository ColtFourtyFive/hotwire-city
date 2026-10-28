--!nocheck
-- Combat v2 client presentation (gta_combat §11, gta_ui_language §5.9-5.10): CombatHUD / DeathScreenController /
-- WeaponPreview / ShoulderCamera / SoundController / ShotFxController / CombatClient pure helpers, CombatStyle tokens,
-- and the content rules (no emoji, no FredokaOne, no pink / neon, no red body impacts) on every combat client file.
return function(t)
	local H = t.H
	local V3 = H.roblox.Vector3
	local CF = H.roblox.CFrame
	local fs = require("@lune/fs")
	local Weapons = H.require("src/shared/Config/Weapons")

	t.test("CombatHUD: spread ticks, damage-arc angle, low-health grade, ammo text", function()
		H.setMode("client")
		local HUD = H.require("src/client/Controllers/CombatHUD")
		t.eq(HUD._spreadPixels(0, 70, 720), 0)
		local a = HUD._spreadPixels(2, 70, 720)
		local b = HUD._spreadPixels(4, 70, 720)
		t.ok(a > 0 and b > a, "wider spread, wider ticks")
		t.ok(HUD._spreadPixels(2, 40, 720) > a, "zoomed in, wider on screen")
		local cam = CF.lookAt(V3.new(0, 0, 0), V3.new(0, 0, -10))
		t.near(HUD._arcAngle(cam, V3.new(0, 0, -50)), 0, 1e-6, "ahead")
		t.near(math.abs(HUD._arcAngle(cam, V3.new(0, 0, 50))), 180, 1e-6, "behind")
		local right = HUD._arcAngle(cam, V3.new(50, 0, 0))
		local left = HUD._arcAngle(cam, V3.new(-50, 0, 0))
		t.near(math.abs(right), 90, 1e-6)
		t.near(right, -left, 1e-6, "mirror")
		t.near(right, 90, 1e-6, "right of the camera = clockwise on screen")
		t.eq(HUD._lowHealthK(100), 0)
		t.eq(HUD._lowHealthK(30), 0)
		t.eq(HUD._lowHealthK(10), 1)
		t.ok(HUD._lowHealthK(20) > 0 and HUD._lowHealthK(20) < 1)
		local txt = HUD._ammoText(12, 48)
		t.ok(string.find(txt, "^12") ~= nil and string.find(txt, "48") ~= nil, txt)
		t.ok(string.find(txt, "#9B9B9B", 1, true) ~= nil, "reserve in TextDim")
		H.setMode("server")
	end)

	t.test("DeathScreenController: subtitles, feed lines, drift camera", function()
		H.setMode("client")
		local DS = H.require("src/client/Controllers/DeathScreenController")
		-- C4b: rich text for UI/Shard (money in red); WASTED is never without a subtitle
		t.eq(DS._wastedSubtitle({ by = "Kai", bill = 1200 }), "Downed by Kai   ·   Hospital bill  <r>-$1,200</r>")
		t.eq(DS._wastedSubtitle({}), "Taken to the hospital")
		t.eq(DS._bustedSubtitle(500, "Brute Coupe"), "Bail  <r>-$500</r>   ·   Brute Coupe impounded")
		t.eq(DS._bustedSubtitle(0, nil), "Released without bail")
		t.eq(DS._feedText("wasted", "Pillbox Memorial", 250, nil), "Treated at Pillbox Memorial. Bill -$250")
		t.eq(DS._feedText("wasted", nil, 0, nil), "Treated at the hospital.")
		t.eq(
			DS._feedText("busted", nil, 900, "Brute Coupe"),
			"Released from Police HQ. Bail -$900 Brute Coupe impounded."
		)
		local start = CF.lookAt(V3.new(0, 5, 10), V3.new(0, 0, 0))
		local target = V3.new(0, 0, 0)
		local c0 = DS._driftCFrame(start, target, 0)
		local c5 = DS._driftCFrame(start, target, 5)
		t.ok((c5.Position - target).Magnitude > (c0.Position - target).Magnitude + 5, "dollies back")
		t.ok(c5.Position.Y > c0.Position.Y, "and up")
		t.ok(c5.LookVector:Dot((target - c5.Position).Unit) > 0.99, "keeps looking at the body")
		-- no cartoon copy anywhere in the screen
		local src = fs.readFile("src/client/Controllers/DeathScreenController.luau")
		t.ok(not string.find(src, "BUSTED!", 1, true), "no comic stamp")
		H.setMode("server")
	end)

	t.test("WeaponPreview: fit distance, laid-out silhouettes", function()
		H.setMode("client")
		local WP = H.require("src/client/UI/WeaponPreview")
		local d1 = WP._fitDistance(2, 0.5, 2.5, 20, 1.1)
		local d2 = WP._fitDistance(4, 0.5, 2.5, 20, 1.1)
		t.ok(d2 > d1, "longer guns sit further away")
		t.ok(WP._fitDistance(0.1, 3, 2.5, 20, 1.1) > WP._fitDistance(0.1, 1, 2.5, 20, 1.1), "height also fits")
		t.eq(WP.modelKey("pistol"), Weapons.get("pistol").asset.model)
		t.eq(WP.modelKey("taser"), "taser")
		t.eq(WP.modelKey("nope"), nil)
		for _, id in { "pistol", "carbine", "bat", "taser" } do
			local m = WP.build(id, true)
			t.ok(m ~= nil, id)
			local _, size = m:GetBoundingBox()
			t.ok(size.Z >= size.Y - 1e-6, id .. " laid out along -Z")
			for _, p in m:GetDescendants() do
				if p:IsA("BasePart") and p.Transparency < 0.95 then
					t.eq(p.Color, H.roblox.Color3.new(1, 1, 1), id .. " silhouette is flat white")
				end
			end
			m:Destroy()
		end
		H.setMode("server")
	end)

	t.test("ShoulderCamera: critically damped smoothing, aim FOV", function()
		H.setMode("client")
		local SC = H.require("src/client/Controllers/ShoulderCamera")
		local x, v = 0, 0
		for _ = 1, 120 do
			x, v = SC._smoothDamp(x, 10, v, 0.08, 1 / 60)
			t.ok(x <= 10 + 1e-6, "no overshoot")
		end
		t.near(x, 10, 1e-3, "settles")
		t.eq(SC._targetFov("marksman", true, false), Weapons.get("marksman").aimFov)
		t.eq(SC._targetFov("pistol", false, false), Weapons.HIP_FOV)
		t.eq(SC._targetFov(nil, false, true), Weapons.SPRINT_FOV)
		H.setMode("server")
	end)

	t.test("SoundController: gun layers by distance, round-robin variants", function()
		H.setMode("client")
		local S = H.require("src/client/Controllers/SoundController")
		local shot, tail, low, mech, distant = S.gunLayers(10)
		t.ok(shot and not tail and not low and mech and not distant, "close")
		shot, tail, low, mech, distant = S.gunLayers(200)
		t.ok(shot and tail and not low and not mech, "mid")
		shot, tail, low = S.gunLayers(400)
		t.ok(shot and tail and low, "far: low-passed")
		shot, tail, low, mech, distant = S.gunLayers(900)
		t.ok(not shot and tail and distant, "city soundscape only")
		local book = {}
		local seq = {}
		for i = 1, 4 do
			seq[i] = S.pickVariant({ "A", "B", "C" }, book)
		end
		t.eq(table.concat(seq, ""), "ABCA")
		t.eq(S.pickVariant({}, book), nil)
		H.setMode("server")
	end)

	t.test("SoundController: distant tails fade with range and are emitted toward the shot", function()
		H.setMode("client")
		local S = H.require("src/client/Controllers/SoundController")
		t.near(S.distantVolume(S.GUN_FAR), 0.3, 1e-9)
		t.ok(S.distantVolume(S.GUN_DISTANT_MAX) < S.distantVolume(S.GUN_FAR), "quieter further out")
		t.ok(S.distantVolume(S.GUN_DISTANT_MAX) > 0, "still audible at the edge")
		t.eq(S.distantVolume(S.GUN_DISTANT_MAX + 1), 0, "nothing beyond")
		local listener = V3.new(0, 0, 0)
		local origin = V3.new(1000, 0, 0)
		local at = S.distantEmitPoint(listener, origin)
		t.near((at - listener).Magnitude, S.GUN_DISTANT_EMIT, 1e-6, "emitted close enough to be heard")
		t.ok(at.X > 0 and math.abs(at.Z) < 1e-9, "from the shot's direction")
		local near = V3.new(50, 0, 0)
		t.eq(S.distantEmitPoint(listener, near), near, "close shots stay where they are")
		H.setMode("server")
	end)

	t.test("ShotFxController: one impact-sound budget per shooter (8 / s)", function()
		H.setMode("client")
		local FX = H.require("src/client/Controllers/ShotFxController")
		local b = { tokens = FX.IMPACT_SOUNDS_PER_S, at = 0 }
		local n = 0
		for _ = 1, 20 do
			if FX._takeImpactSound(b, 0) then
				n += 1
			end
		end
		t.eq(n, FX.IMPACT_SOUNDS_PER_S, "a burst plays at most the bucket")
		t.eq(FX._takeImpactSound(b, 0.5 / FX.IMPACT_SOUNDS_PER_S), false, "half a token is not a sound")
		t.eq(FX._takeImpactSound(b, 1.01 / FX.IMPACT_SOUNDS_PER_S), true, "refills at the rate")
		H.setMode("server")
	end)

	t.test(
		"WeaponClient: stale presses never fire, flick switching, aim pose, touch cluster clear of the HUD",
		function()
			H.setMode("client")
			local WC = H.require("src/client/Controllers/WeaponClient")
			local AimAssist = H.require("src/shared/Combat/AimAssist")
			-- a click is buffered for PRESS_WINDOW only
			t.eq(WC._pressValid(10, 10.05), true)
			t.eq(
				WC._pressValid(10, 10 + WC.PRESS_WINDOW + 0.01),
				false,
				"a click made unarmed never fires the gun drawn later"
			)
			t.eq(WC._pressValid(-math.huge, 10), false, "no press")
			t.eq(WC._pressValid(11, 10), false)
			-- flicks: one quick swipe past FLICK_DEG switches; a slow drag never does
			local acc, side = WC._flickStep(0, AimAssist.FLICK_DEG + 1, 1 / 60)
			t.eq(side, 1)
			t.eq(acc, 0, "reset after a flick")
			_, side = WC._flickStep(0, -(AimAssist.FLICK_DEG + 1), 1 / 60)
			t.eq(side, -1)
			acc = 0
			local flicked = false
			for _ = 1, 60 do
				local s
				acc, s = WC._flickStep(acc, AimAssist.FLICK_DEG * 0.1, 0.25)
				flicked = flicked or s ~= 0
			end
			t.ok(not flicked, "a slow pan is not a flick")
			-- the aim point other clients pose a character toward
			local head = V3.new(0, 5, 0)
			local level = WC._aimTarget(head, V3.new(0, 0, -1), 0, 60)
			t.near((level - V3.new(0, 5, -60)).Magnitude, 0, 1e-6)
			local up = WC._aimTarget(head, V3.new(0, 0.5, -1), 30, 60)
			t.near(up.Y - head.Y, 60 * math.sin(math.rad(30)), 1e-6, "pitch from the attribute, not the look vector")
			t.ok(WC._aimTarget(head, V3.new(0, 0, -1), 89, 60).Y < head.Y + 60, "clamped below straight up")
			-- touch cluster from the shared HUD layout (UI/HudLayout) on phone and tablet canvases: inside the canvas,
			-- on the right half (the thumbstick owns the left), clear of each other, of Roblox's jump button, of the
			-- HUD's PHONE / MAP buttons and of the top-right cash / ammo / arrest / stars block
			local HudLayout = H.require("src/client/UI/HudLayout")
			local canvases = {
				{ 1172, 460, 0.72 }, -- small phone (combat's original budget)
				{ 844 / 0.72, 354 / 0.72, 0.72 }, -- iPhone 13 landscape inside the safe insets
				{ 1280, 720, 1 }, -- tablet: the big jump button
				{ 1024, 768, 1 }, -- 4:3 tablet
			}
			for _, c in canvases do
				local W, Hh, scale = c[1], c[2], c[3]
				local L = HudLayout.compute(W, Hh, true, { scale = scale })
				local jump = HudLayout.jumpButton(W, Hh, scale)
				local rects = WC.touchRects(L, jump)
				local tag = (" @ %dx%d"):format(W, Hh)
				local names = { "fire", "aim", "reload", "swap", "surrender", "weapon" }
				for _, name in names do
					local r = rects[name]
					t.ok(HudLayout.inside(r, W, Hh), name .. " inside the canvas" .. tag)
					t.ok(r.x > W * 0.5, name .. " stays on the right half" .. tag)
					for _, other in
						{
							{ "jump", jump },
							{ "phone", L.buttons.phone },
							{ "map", L.buttons.map },
							{ "cash", L.cash },
							{ "delta", L.delta },
							{ "ammo", L.ammo },
							{ "arrest", L.arrest },
							{ "stars", L.stars },
						}
					do
						t.ok(not HudLayout.overlaps(r, other[2]), name .. " clear of " .. other[1] .. tag)
					end
				end
				for i = 1, #names do
					for j = i + 1, #names do
						t.ok(
							not HudLayout.overlaps(rects[names[i]], rects[names[j]]),
							names[i] .. " overlaps " .. names[j] .. tag
						)
					end
				end
				t.eq(rects.fire.y + rects.fire.h, jump.y + jump.h, "FIRE level with the jump button" .. tag)
			end
			H.setMode("server")
		end
	)

	t.test("GunShopUI: the touch sheet compensates for the screen UIScale", function()
		H.setMode("client")
		local Shop = H.require("src/client/Controllers/GunShopUI")
		local s = Shop._sheetSize(0.72, Shop.SHEET_HEIGHT)
		t.near(s.X.Scale * 0.72, 1, 1e-5, "full width after scaling") -- UDim is float32
		t.near(s.Y.Scale * 0.72, Shop.SHEET_HEIGHT, 1e-5, "40 % of the height after scaling")
		t.eq(Shop._sheetSize(0, 0.4).X.Scale, 1, "a missing scale counts as 1")
		for _, h in { 400, 460, 490, 541, 720 } do
			local rows = Shop._touchRows(h)
			t.ok(rows >= 3 and rows <= Shop.MAX_ROWS_TOUCH, "row count in range")
			t.ok(rows * Shop.ROW_H_TOUCH + 24 <= h * Shop.SHEET_HEIGHT - 16, "rows + subheader fit the sheet at " .. h)
		end
		t.eq(Shop._touchRows(720), Shop.MAX_ROWS_TOUCH, "tall screens get the full list")
		H.setMode("server")
	end)

	t.test("ShotFxController: closest point on a tracer, impacts never red", function()
		H.setMode("client")
		local FX = H.require("src/client/Controllers/ShotFxController")
		local p = FX._closestPointOnSegment(V3.new(0, 5, -10), V3.new(0, 0, 0), V3.new(0, 0, -20))
		t.near((p - V3.new(0, 0, -10)).Magnitude, 0, 1e-9)
		for kind = 0, 3 do
			local _, color = FX._impactStyle(kind)
			t.ok(not (color.R > 0.6 and color.G < 0.3 and color.B < 0.3), "no blood red for kind " .. kind)
		end
		H.setMode("server")
	end)

	t.test("CombatClient: gadget cooldowns (Zapper Pass halves the stun gun)", function()
		H.setMode("client")
		local CC = H.require("src/client/Controllers/CombatClient")
		local Economy = H.require("src/shared/Config/Economy")
		t.eq(CC.cooldownFor("taser", false), Economy.Tools.taser.cooldown)
		t.eq(CC.cooldownFor("taser", true), Economy.Tools.taser.cooldown * 0.5)
		t.eq(CC.cooldownFor("spikes", true), Economy.Tools.spikes.cooldown)
		t.eq(CC.cooldownFor("nope", false), 1)
		H.setMode("server")
	end)

	t.test("CombatStyle: GTA tokens, layer order, no pink / cyan", function()
		H.setMode("client")
		local Style = H.require("src/client/UI/CombatStyle")
		local L = Style.Layers
		t.ok(L.HUD < L.Wheel and L.Wheel < L.Shard and L.Shard < L.Fade, "layer order")
		t.eq(Style.Colors.WastedRed, H.roblox.Color3.fromRGB(0xB3, 0x21, 0x2F))
		t.eq(Style.Colors.Blue, H.roblox.Color3.fromRGB(0x5D, 0xB6, 0xE5))
		for name, c in Style.Colors do
			t.ok(not (c.R > 0.8 and c.B > 0.6 and c.G < 0.6), name .. " is not pink")
			t.ok(not (c.G > 0.8 and c.B > 0.8 and c.R < 0.3), name .. " is not cyan")
		end
		t.ok(Style.font("Display") ~= nil)
		H.setMode("server")
	end)

	t.test("combat client files: no emoji, no FredokaOne, no neon", function()
		local files = {
			"src/client/Controllers/WeaponClient.luau",
			"src/client/Controllers/WeaponWheel.luau",
			"src/client/Controllers/CombatHUD.luau",
			"src/client/Controllers/DeathScreenController.luau",
			"src/client/Controllers/GunShopUI.luau",
			"src/client/Controllers/ShotFxController.luau",
			"src/client/Controllers/ShoulderCamera.luau",
			"src/client/Controllers/CombatClient.luau",
			"src/client/UI/CombatStyle.luau",
			"src/client/UI/WeaponPreview.luau",
			"src/shared/Combat/WeaponModels.luau",
			"src/shared/Config/Weapons.luau",
		}
		for _, path in files do
			local src = fs.readFile(path)
			t.ok(not string.find(src, "Fredoka", 1, true), path .. ": FredokaOne")
			t.ok(not string.find(src, "Material.Neon", 1, true), path .. ": neon")
			for _, cp in utf8.codes(src) do
				local emoji = (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF) or cp == 0x2B50
				if emoji then
					error(("%s: emoji U+%X"):format(path, cp))
				end
			end
		end
	end)
end
