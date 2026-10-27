--!nocheck
-- UI v2 (GTA presentation language) pure logic: RichText tags / key caps / emoji stripping, the HudLayout anchors on
-- desktop and phone canvases (inside the canvas, no overlaps, GTA proportions), and the bar split.
return function(t)
	local H = t.H
	H.setMode("client")
	local RichText = H.require("src/client/UI/RichText")
	local HudLayout = H.require("src/client/UI/HudLayout")
	H.setMode("server")

	-- RichText ----------------------------------------------------------------------------------------------------
	t.test("RichText.format: GTA colour tags become font runs, Roblox tags pass through", function()
		local s = RichText.format("Take the car to your <y>garage</y>.")
		t.eq(s, 'Take the car to your <font color="#F0C850">garage</font>.')
		t.eq(
			RichText.format("<r>cops</r> <blue>car</blue>"),
			'<font color="#E03232">cops</font> <font color="#5DB6E5">car</font>'
		)
		t.eq(RichText.format("<b>bold</b> stays"), "<b>bold</b> stays", "Roblox bold is untouched")
		t.eq(RichText.format("<g>unclosed"), '<font color="#72CC72">unclosed</font>', "closed at the end")
		t.eq(RichText.format("stray</y> closer"), "stray closer", "stray closers dropped")
		t.eq(RichText.format(nil), "")
	end)

	t.test("RichText key caps", function()
		local k = RichText.key("e")
		t.ok(k:find("<mark", 1, true) and k:find(" E ", 1, true), "upper-cased mark key cap: " .. k)
		local s = RichText.format("Hold <key>E</key> to hotwire.")
		t.ok(s:find("<mark", 1, true) ~= nil, "inline key cap")
		t.eq(RichText.plain(s), "Hold  E  to hotwire.", "plain text keeps the key name")
		t.ok(RichText.keyFor("touch", "E", "X", "Hotwire"):find("HOTWIRE", 1, true) ~= nil, "touch names the button")
		t.ok(RichText.keyFor("gamepad", "E", "X"):find(" X ", 1, true) ~= nil, "gamepad key")
		t.ok(RichText.keyFor("keyboard", "E", "X"):find(" E ", 1, true) ~= nil, "keyboard key")
		t.eq(RichText.key("<"), RichText.key("<"), "deterministic")
		t.ok(RichText.key("<"):find("&lt;", 1, true) ~= nil, "escaped")
	end)

	t.test("RichText.stripEmoji / clean remove every emoji and tidy the gaps", function()
		t.eq(RichText.stripEmoji("plain ASCII"), "plain ASCII")
		t.eq(RichText.clean("🚨 HOME"), "HOME")
		t.eq(RichText.clean("Lose the cops first! 🚔"), "Lose the cops first!")
		t.eq(RichText.clean("⏱️ 1:40 left • Chase them 🏏 !"), "1:40 left • Chase them!")
		t.eq(RichText.clean("❤️‍🔥 combo"), "combo", "ZWJ sequences go entirely")
		t.eq(RichText.clean("🇺🇸 flag"), "flag")
		t.eq(RichText.clean("★★☆ ▶ ◀"), "", "stars and play triangles are glyph art, not text")
		t.eq(RichText.clean("café ≈ $5 × 2 — ok"), "café ≈ $5 × 2 — ok", "accents and maths symbols stay")
		t.eq(RichText.stripEmoji(nil), "")
		local bad = "\255\254 broken"
		t.eq(RichText.stripEmoji(bad), bad, "invalid UTF-8 untouched")
	end)

	t.test("RichText.escape / plain / color", function()
		t.eq(RichText.escape("<b>Tom & Jerry</b>"), "&lt;b&gt;Tom &amp; Jerry&lt;/b&gt;")
		t.eq(RichText.plain('<font color="#FF0000">A</font> &amp; <b>B</b>'), "A & B")
		local c = RichText.color("x", H.roblox.Color3.fromRGB(255, 0, 0))
		t.eq(c, '<font color="#FF0000">x</font>')
	end)

	-- HudLayout ---------------------------------------------------------------------------------------------------
	local DESKTOP = { { 1280, 720 }, { 1920 / 1.5, 1080 / 1.5 }, { 1280, 960 }, { 1536, 720 }, { 1280, 800 } }
	-- phone canvases inside CoreUISafeInsets at the 0.72 touch floor (844x390 notched, 800x360, SE, tablets)
	local TOUCH =
		{ { 1042, 461 }, { 1111, 419 }, { 926, 443 }, { 1172, 380 }, { 1280, 720 }, { 1440, 900 }, { 980, 500 } }

	local function allRects(L)
		local list = {
			radar = L.radar,
			bars = L.bars,
			help = L.help,
			stars = L.stars,
			cash = L.cash,
			delta = L.delta,
			ammo = L.ammo,
			arrest = L.arrest,
			objective = L.objective,
			location = L.location,
			locationDriving = L.locationDriving,
			timers = L.timers,
			speed = L.speed,
			radio = L.radio,
			phone = L.phone,
		}
		for k, r in L.buttons do
			list["button_" .. k] = r
		end
		return list
	end

	t.test("HudLayout desktop: GTA V proportions at 1280x720", function()
		local L = HudLayout.compute(1280, 720, false)
		t.eq(L.radar.w, 192, "0.150 W")
		t.eq(L.radar.h, 136, "0.189 H")
		t.eq(L.radar.x, 20, "SAFE")
		t.eq(L.radar.y, 720 - 20 - 14 - 136, "bottom-left")
		t.eq(L.bars.y, L.radar.y + L.radar.h + 4, "bars 4 px under the radar")
		t.eq(L.bars.w, L.radar.w)
		t.eq(L.stars.x + L.stars.w, 1260, "stars right-aligned")
		t.eq(L.stars.y, 24)
		t.ok(L.cash.y >= L.stars.y + L.stars.h, "cash under the stars")
		t.ok(L.objective.y + L.objective.h <= 720 - 30, "objective bottom-centre")
		t.near(L.objective.x + L.objective.w / 2, 640, 1, "centred")
		t.eq(L.help.x, 20)
		t.eq(L.help.y, 20)
		t.ok(L.feed.y + L.feed.h <= L.radar.y, "feed above the radar")
		t.eq(L.timerStep < 0, true, "timer bars stack upward")
		local cy, bh = HudLayout.shardBand(720)
		t.near(cy, 351.36, 1e-6)
		t.near(bh, 140.4, 1e-6)
	end)

	t.test("HudLayout desktop: everything on screen and nothing overlaps", function()
		for _, c in DESKTOP do
			local w, h = c[1], c[2]
			local L = HudLayout.compute(w, h, false)
			local rects = allRects(L)
			for name, r in rects do
				t.ok(HudLayout.inside(r, w, h), ("%s inside %dx%d"):format(name, w, h))
			end
			local groups = {
				-- things that can show at the same time
				{
					"radar",
					"bars",
					"help",
					"stars",
					"cash",
					"delta",
					"ammo",
					"arrest",
					"objective",
					"location",
					"timers",
				},
				{ "radar", "bars", "objective", "locationDriving", "speed", "radio", "stars", "cash" },
			}
			for _, g in groups do
				for i = 1, #g do
					for j = i + 1, #g do
						t.ok(
							not HudLayout.overlaps(rects[g[i]], rects[g[j]]),
							("%s vs %s at %dx%d"):format(g[i], g[j], w, h)
						)
					end
				end
			end
			t.ok(not HudLayout.overlaps(L.feed, L.radar), "feed vs radar")
			t.ok(not HudLayout.overlaps(L.timersDriving, L.speed), "timers above the speed readout")
		end
	end)

	t.test("HudLayout touch: radar top-left, clear of the thumbstick and button zones", function()
		for _, c in TOUCH do
			local w, h = c[1], c[2]
			local L = HudLayout.compute(w, h, true)
			local tag = (" at %dx%d"):format(w, h)
			t.eq(L.radar.x, 10, "top-left" .. tag)
			t.eq(L.radar.y, 10, "top-left" .. tag)
			t.eq(L.radar.w, 168)
			t.ok(L.help.y >= L.bars.y + L.bars.h, "help under the radar" .. tag)
			t.eq(L.feedMax, 2)
			local rects = allRects(L)
			for name, r in rects do
				t.ok(HudLayout.inside(r, w, h), name .. " inside" .. tag)
			end
			local onFoot = { "radar", "bars", "stars", "cash", "delta", "ammo", "arrest", "objective", "location" }
			table.insert(onFoot, "radio")
			table.insert(onFoot, "timers")
			table.insert(onFoot, "button_phone")
			table.insert(onFoot, "button_map")
			local driving = {
				"radar",
				"bars",
				"stars",
				"cash",
				"delta",
				"objective",
				"location",
				"radio",
				"timers",
				"speed",
				"button_nitro",
				"button_drift",
				"button_horn",
				"button_exit",
			}
			for _, g in { onFoot, driving } do
				for i = 1, #g do
					for j = i + 1, #g do
						t.ok(not HudLayout.overlaps(rects[g[i]], rects[g[j]]), ("%s vs %s%s"):format(g[i], g[j], tag))
					end
				end
			end
			-- nothing tappable in the dynamic thumbstick zone (left 40%, from a third of the height down)
			for name, r in L.buttons do
				t.ok(r.x >= w * 0.4, name .. " right of the thumbstick zone" .. tag)
			end
			t.ok(L.speed.x >= w * 0.4, "speed readout off the thumbstick" .. tag)
			-- the Roblox jump button (bottom-right ~ 135 x 125 design px) stays free on foot
			local jump = HudLayout.rect(w - 135, h - 125, 125, 115)
			t.ok(not HudLayout.overlaps(L.buttons.phone, jump), "phone clears jump" .. tag)
			t.ok(not HudLayout.overlaps(L.buttons.map, jump), "map clears jump" .. tag)
			t.ok(L.timerStep > 0, "touch timers stack downward")
			t.ok(L.list.w == w and L.list.y + L.list.h == h, "list menu is a bottom sheet")
			t.ok(L.phone.y >= 0 and L.phone.h <= h, "phone fits")
		end
	end)

	t.test("HudLayout.barSegments splits 50 / 25 / 25", function()
		local a, b, c = HudLayout.barSegments(192, 2)
		t.eq(a + b + c + 4, 192, "fills the width")
		t.eq(a, 94)
		t.eq(b, 47)
		t.eq(c, 47)
		local z1, z2, z3 = HudLayout.barSegments(2, 2)
		t.eq(z1 + z2 + z3, 0, "never negative")
	end)

	t.test("HudLayout guards junk canvases", function()
		local L = HudLayout.compute(0 / 0, -5, false)
		t.eq(L.w, 1280)
		t.eq(L.h, 720)
	end)
end
