--!nocheck
-- UI v2 second review pass: touch buttons vs Roblox's jump button on every screen size, one set of health bars (the
-- combat package's CombatHUD dedupe contract), the shard title at 1080p+, UI sounds through a muted group, DrivingUI
-- under the HUD's hidden states, pause footer key caps per input, escaped display names.
return function(t)
	local H = t.H
	H.setMode("client")
	local HudLayout = H.require("src/client/UI/HudLayout")
	local Shard = H.require("src/client/UI/Shard")
	local UISound = H.require("src/client/UI/UISound")
	local PauseMenu = H.require("src/client/UI/PauseMenu")
	local RichText = H.require("src/client/UI/RichText")
	local Vehicle = H.require("src/client/Controllers/VehicleClient")
	local Menu = H.require("src/client/Controllers/MenuController")
	H.setMode("server")

	-- Touch PHONE / MAP vs the jump button ------------------------------------------------------------------------------
	-- real screens (w, h at UIScale `s`, minus a 36 / 58 px top bar): phones (small jump button) and tablets (big)
	local SCREENS = {
		{ 844, 390, 0.72 },
		{ 667, 375, 0.72 },
		{ 932, 430, 0.72 },
		{ 1280, 720, 1 },
		{ 1440, 900, 1.125 },
		{ 1024, 768, 0.8 },
		{ 1180, 820, 0.92 },
		{ 1366, 1024, 1.067 },
	}

	t.test("HudLayout.jumpButton: Roblox's 70 px phone / 120 px tablet jump button", function()
		local small = HudLayout.jumpButton(844 / 0.72, 354 / 0.72, 0.72)
		t.near(small.w * 0.72, 70, 1e-6, "phone: 70 real px")
		t.near((844 / 0.72 - small.x) * 0.72, 95, 1e-6, "phone: 95 px from the right")
		t.near((354 / 0.72 - small.y) * 0.72, 90, 1e-6, "phone: 90 px from the bottom")
		local big = HudLayout.jumpButton(1280, 684, 1)
		t.eq(big.w, 120, "tablet: 120 real px")
		t.eq(big.x, 1280 - 170)
		t.eq(big.y, 684 - 210)
		-- the switch is on the real short side (500 px), not the design canvas
		t.near(HudLayout.jumpButton(1280, 600, 0.8).w * 0.8, 70, 1e-6, "480 real px tall: the small one")
		t.near(HudLayout.jumpButton(1280, 640, 0.8).w * 0.8, 120, 1e-6, "512 real px tall: the big one")
	end)

	t.test("HudLayout touch: PHONE / MAP never cover the jump button (phones and tablets)", function()
		for _, sc in SCREENS do
			for _, topbar in { 36, 58 } do
				local s = sc[3]
				local w, h = sc[1] / s, (sc[2] - topbar) / s
				local tag = ("%dx%d at %.2f, top bar %d"):format(sc[1], sc[2], s, topbar)
				local L = HudLayout.compute(w, h, true, { scale = s })
				local jump = HudLayout.jumpButton(w, h, s)
				for _, key in { "phone", "map" } do
					local b = L.buttons[key]
					t.ok(not HudLayout.overlaps(b, jump), tag .. ": " .. key .. " clear of the jump button")
					t.ok(HudLayout.inside(b, w, h), tag .. ": " .. key .. " on screen")
					t.ok(b.y >= L.arrest.y + L.arrest.h, tag .. ": " .. key .. " below the top-right block")
					t.ok(b.w * s >= 0.08 * sc[2] - 1e-6 or b.w * s >= 40, tag .. ": " .. key .. " big enough to hit")
				end
				-- a measured jump button wins over the estimate
				local measured = HudLayout.compute(w, h, true, { scale = s, jumpTop = h - 300 })
				t.ok(measured.buttons.phone.y + measured.buttons.phone.h <= h - 300 - 8 + 1e-6, tag .. ": measured")
			end
		end
		-- desktop ignores all of it
		local D = HudLayout.compute(1280, 720, false, { scale = 1, jumpTop = 10 })
		t.eq(D.buttons.phone, nil)
	end)

	-- One set of bars ----------------------------------------------------------------------------------------------------
	t.test("HUD: the bars hang under HC_HUD > Minimap (the combat package's dedupe contract), one set only", function()
		H.setMode("client")
		local lp = H.localPlayer
		local Kit = H.require("src/client/UI/Kit")
		local made = {}
		Kit.screen = function(name, order)
			local g = H.roblox.Instance.new("ScreenGui")
			g.Name = name
			g.DisplayOrder = order
			g.Parent = lp:FindFirstChild("PlayerGui")
			table.insert(made, g)
			return g
		end
		Kit.isTouch = function()
			return false
		end
		local ok, err = pcall(function()
			local HUD = H.require("src/client/Controllers/HUDController")
			HUD.mount()
			local hud = lp.PlayerGui:FindFirstChild("HC_HUD")
			t.ok(hud ~= nil, "HC_HUD built")
			-- CombatHUD.findRadar: HC_HUD:FindFirstChild("Minimap", true), then hides its own bars when it has "Bars"
			local box = hud:FindFirstChild("Minimap", true)
			t.ok(box ~= nil and box:IsA("GuiObject"), "a Minimap frame in HC_HUD")
			t.ok(box:FindFirstChild("Bars") ~= nil, "with the Bars under it")
			local count = 0
			for _, d in lp.PlayerGui:GetDescendants() do
				if d.Name == "Bars" then
					count += 1
				end
			end
			t.eq(count, 1, "exactly one Bars frame")
			-- the radar reports where it is (expanded radar): the box and the bars follow
			HUD.setRadarRect(20, 400, 384, 272)
			t.eq(box.Position.X.Offset, 20)
			t.eq(box.Position.Y.Offset, 400)
			t.eq(box.Size.X.Offset, 384)
			local a, b, c = HudLayout.barSegments(384, 2)
			t.eq(box.Bars.Health.Size.X.Offset, a)
			t.eq(box.Bars.Armour.Size.X.Offset, b)
			t.eq(box.Bars.Ability.Size.X.Offset, c)
		end)
		for _, g in made do
			g:Destroy()
		end
		H.setMode("server")
		t.ok(ok, tostring(err))
	end)

	-- Shard text size ----------------------------------------------------------------------------------------------------
	t.test("Shard title / subtitle follow the screen height (Roblox caps text at 100 px)", function()
		local s720, sub720 = Shard.textMetrics(1280, 720)
		t.near(s720, 1, 1e-9, "720p: the design size")
		t.eq(sub720, 18, "720p subtitle: 18 px (§5.9)")
		local s1080, sub1080 = Shard.textMetrics(1920, 1080)
		t.near(s1080, 1.5, 1e-9)
		t.eq(sub1080, 27, "1080p subtitle")
		-- the title box is 101 design px tall with text up to 100 px: ~14% of the screen height at every size
		for _, vp in { { 1280, 720 }, { 1920, 1080 }, { 2560, 1440 }, { 3840, 2160 } } do
			local s = Shard.textMetrics(vp[1], vp[2])
			t.ok(100 * s / vp[2] >= 0.135, ("%dx%d: title ~14%% H"):format(vp[1], vp[2]))
		end
		-- a narrow screen keeps the title box inside the width
		local narrow = Shard.textMetrics(800, 1280)
		t.ok(794 * narrow <= 800 * 0.9 + 1e-6, "portrait: fits the width")
		local j1, j2 = Shard.textMetrics(0 / 0, -1)
		t.ok(j1 > 0 and j2 >= 12, "junk viewport")
	end)

	-- UI sounds ------------------------------------------------------------------------------------------------------------
	t.test("UISound: UI one-shots go through HC_UI (outside the muffle), else HC_SFX (muted by the setting)", function()
		local svc = H.roblox.Instance.new("Folder")
		t.eq(UISound.groupFor(svc), nil, "no group yet")
		local sfx = H.roblox.Instance.new("SoundGroup")
		sfx.Name = "HC_SFX"
		sfx.Parent = svc
		t.eq(UISound.groupFor(svc), sfx, "the sfx group")
		local uiGroup = H.roblox.Instance.new("SoundGroup")
		uiGroup.Name = "HC_UI"
		uiGroup.Parent = svc
		t.eq(UISound.groupFor(svc), uiGroup, "the UI group wins")
		svc:Destroy()
	end)

	-- DrivingUI follows the HUD --------------------------------------------------------------------------------------------
	t.test("DrivingUI: hidden with the HUD; EXIT stays usable in streamer mode", function()
		local info, touch = Vehicle.drivingUiVisibility(false, false, false)
		t.ok(info and touch, "normal")
		info, touch = Vehicle.drivingUiVisibility(true, false, false)
		t.ok(not info, "streamer: no speed readout / drift line")
		t.ok(touch, "streamer: the touch buttons (EXIT) stay")
		info, touch = Vehicle.drivingUiVisibility(false, true, false)
		t.ok(not info and not touch, "photo mode: nothing in the picture")
		info, touch = Vehicle.drivingUiVisibility(false, false, true)
		t.ok(not info and not touch, "pause menu: nothing to tap through the tint")
	end)

	-- Pause footer keys ----------------------------------------------------------------------------------------------------
	t.test("PauseMenu.keyLabel: keyboard keys, gamepad buttons, nothing on touch", function()
		t.eq(PauseMenu.keyLabel("Enter", "keyboard"), "Enter")
		t.eq(PauseMenu.keyLabel("Enter", "gamepad"), "A")
		t.eq(PauseMenu.keyLabel("Backspace", "gamepad"), "B")
		t.eq(PauseMenu.keyLabel("Q", "gamepad"), "LB")
		t.eq(PauseMenu.keyLabel("E", "gamepad"), "RB")
		t.eq(PauseMenu.keyLabel("P", "gamepad"), "Back", "the pause button is Back / View (Start is Roblox's)")
		t.eq(PauseMenu.keyLabel("Q", "touch"), nil)
		t.eq(PauseMenu.keyLabel(nil, "keyboard"), nil)
	end)

	-- Escaped names ----------------------------------------------------------------------------------------------------------
	t.test("STATS player rows escape display names (rich text labels)", function()
		local rows = Menu.playerRows({
			{ userId = 1, name = "<b>Me</b> & co", cash = 1, steals = 0, rebirths = 0, wanted = 0, isYou = true },
			{ userId = 2, name = "Plain", cash = 2, steals = 0, rebirths = 0, wanted = 0, isYou = false },
		})
		t.eq(rows[1].label, RichText.escape("<b>Me</b> & co") .. "  (you)")
		t.ok(rows[1].label:find("<b>", 1, true) == nil, "no live tags")
		t.eq(rows[2].label, "Plain", "plain names unchanged")
	end)
end
