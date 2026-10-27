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
		t.eq(DS._wastedSubtitle({ by = "Kai", bill = 1200 }), "Downed by Kai   ·   Hospital bill  -$1,200")
		t.eq(DS._wastedSubtitle({}), "")
		t.eq(DS._bustedSubtitle(500, "Brute Coupe"), "Bail  -$500   ·   Brute Coupe impounded")
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
