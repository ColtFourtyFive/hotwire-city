--!nocheck
-- Wave B integration (combat v2 + UI v2 on one main): the combat touch cluster laid out from the shared HUD layout,
-- D-pad down shared between the expanded radar and surrender, CombatStyle = the Theme v2 tokens, the weapon icon under
-- HUDController's ammo line, WASTED / BUSTED through the shared UI/Shard, and every cursor screen suspending the
-- shoulder camera.
local fs = require("@lune/fs")

return function(t)
	local H = t.H
	H.setMode("client")
	local HudLayout = H.require("src/client/UI/HudLayout")
	local Theme = H.require("src/client/UI/Theme")
	local CombatStyle = H.require("src/client/UI/CombatStyle")
	local Shard = H.require("src/client/UI/Shard")
	local WC = H.require("src/client/Controllers/WeaponClient")
	local CombatHUD = H.require("src/client/Controllers/CombatHUD")
	local Mini = H.require("src/client/Controllers/MinimapController")
	H.setMode("server")

	-- real screens (w, h at UIScale `s`), as in ui_v2_fix2.spec: phones (small jump button) and tablets (big)
	local SCREENS = {
		{ 844, 390, 0.72 },
		{ 667, 375, 0.72 },
		{ 932, 430, 0.72 },
		{ 1280, 720, 1 },
		{ 1440, 900, 1.125 },
		{ 1024, 768, 0.8 },
		{ 1024, 768, 1 },
		{ 1180, 820, 0.92 },
		{ 1366, 1024, 1.067 },
	}
	local NAMES = { "fire", "aim", "reload", "swap", "surrender", "weapon" }

	t.test("WeaponClient touch cluster: clear of the HUD's buttons, the jump button and the top-right block", function()
		for _, sc in SCREENS do
			for _, topbar in { 36, 58 } do
				local s = sc[3]
				local w, h = sc[1] / s, (sc[2] - topbar) / s
				local tag = (" @ %dx%d at %.2f, top bar %d"):format(sc[1], sc[2], s, topbar)
				for _, phoneOpen in { false, true } do
					local L = HudLayout.compute(w, h, true, { scale = s })
					if phoneOpen then
						L = HudLayout.withPhone(L)
					end
					local jump = HudLayout.jumpButton(w, h, s)
					local rects = WC.touchRects(L, jump)
					local tg = tag .. (if phoneOpen then " (phone up)" else "")
					for _, name in NAMES do
						local r = rects[name]
						t.ok(HudLayout.inside(r, w, h), name .. " on screen" .. tg)
						if name ~= "weapon" then
							t.ok(r.x >= w * 0.5, name .. " on the right half (the thumbstick owns the left)" .. tg)
						end
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
								{ "radar", L.radar },
							}
						do
							t.ok(not HudLayout.overlaps(r, other[2]), name .. " clear of " .. other[1] .. tg)
						end
					end
					for i = 1, #NAMES do
						for j = i + 1, #NAMES do
							t.ok(
								not HudLayout.overlaps(rects[NAMES[i]], rects[NAMES[j]]),
								NAMES[i] .. " vs " .. NAMES[j] .. tg
							)
						end
					end
					-- the weapon button follows the ammo line (it steps left of the phone with it)
					t.near(rects.weapon.x + rects.weapon.w, L.ammo.x + L.ammo.w, 1e-6, "weapon under ammo" .. tg)
				end
			end
		end
	end)

	t.test("D-pad down: the expanded radar yields to a possible surrender; Z always expands", function()
		local KeyCode = H.roblox.Enum.KeyCode
		local Z, PAD = KeyCode.Z, KeyCode.DPadDown
		t.eq(Mini.EXPAND_KEY, Z)
		t.eq(Mini.EXPAND_PAD_KEY, PAD)
		t.ok(Mini.padKeyExpands(Z, false))
		t.ok(Mini.padKeyExpands(Z, true), "Z is never shared (surrender is H on a keyboard)")
		t.ok(Mini.padKeyExpands(PAD, false), "no cops near: D-pad down is the radar")
		t.ok(not Mini.padKeyExpands(PAD, true), "surrender possible: D-pad down belongs to it")
		t.ok(not Mini.padKeyExpands(KeyCode.H, false))
		-- and the surrender side really listens to D-pad down
		local src = fs.readFile("src/client/Controllers/WeaponClient.luau")
		t.ok(string.find(src, "Enum.KeyCode.DPadDown", 1, true) ~= nil, "WeaponClient holds D-pad down to surrender")
	end)

	t.test("CombatStyle is the Theme v2 token set (no fallback copies)", function()
		t.ok(CombatStyle.isThemeV2)
		t.ok(rawequal(CombatStyle.Colors, Theme.Colors), "colours")
		t.ok(rawequal(CombatStyle.Fonts, Theme.Fonts), "fonts")
		t.ok(rawequal(CombatStyle.Layers, Theme.Layers), "layers")
		t.eq(CombatStyle.SAFE, Theme.SAFE)
		t.eq(CombatStyle.Transparency.Panel, Theme.Alpha.Panel)
		t.eq(CombatStyle.Transparency.Row, Theme.Alpha.Row)
		t.eq(CombatStyle.font("Display"), Theme.Fonts.Display)
		t.ok(CombatStyle.font("NoSuchRole") ~= nil, "unknown roles still get a font")
		local src = fs.readFile("src/client/UI/CombatStyle.luau")
		t.ok(not string.find(src, "TODO(integrate)", 1, true), "the integration TODO is resolved")
		t.ok(not string.find(src, "fromHex", 1, true), "no hard-coded palette left")
	end)

	t.test("CombatHUD: ammo through HUDController, the weapon icon under its ammo line", function()
		local p = CombatHUD._iconPosition({ x = 1040, y = 112, w = 220, h = 30 })
		t.eq(p.X.Scale, 0)
		t.eq(p.X.Offset, 1260)
		t.eq(p.Y.Offset, 144)
		local fallback = CombatHUD._iconPosition(nil)
		t.eq(fallback.X.Scale, 1)
		t.eq(fallback.Y.Offset, 124)
		local src = fs.readFile("src/client/Controllers/CombatHUD.luau")
		t.ok(string.find(src, "hudCtl.setAmmo", 1, true) ~= nil, "ammo goes through HUDController.setAmmo")
		t.ok(string.find(src, "hudCtl.setAbility", 1, true) ~= nil, "setAbility is forwarded")
		-- the HUD side of the contract: the bars CombatHUD looks for, and setAmmo / setAbility exist
		local hudSrc = fs.readFile("src/client/Controllers/HUDController.luau")
		t.ok(string.find(hudSrc, 'Name = "Minimap"', 1, true) ~= nil and string.find(hudSrc, 'Name = "Bars"', 1, true))
		t.ok(string.find(hudSrc, "function HUDController.setAmmo", 1, true) ~= nil)
		t.ok(string.find(hudSrc, "function HUDController.setAbility", 1, true) ~= nil)
	end)

	t.test("WASTED / BUSTED render through the shared UI/Shard; one HC_Shard / HC_Fade", function()
		t.eq(typeof(Shard.currentToken), "function")
		t.eq(typeof(Shard.currentToken()), "number")
		local src = fs.readFile("src/client/Controllers/DeathScreenController.luau")
		t.ok(string.find(src, 'require(UI:WaitForChild("Shard"))', 1, true) ~= nil, "uses UI/Shard")
		t.ok(not string.find(src, '"HC_Shard"', 1, true), "no second HC_Shard ScreenGui")
		t.ok(not string.find(src, '"HC_Fade"', 1, true), "no second HC_Fade ScreenGui")
		t.ok(string.find(src, "grade = false", 1, true) ~= nil, "the death grade stays this controller's")
		t.ok(string.find(src, "sound = false", 1, true) ~= nil, "no double sting")
		-- HUDController still leaves the Busted remote to the combat package
		local hudSrc = fs.readFile("src/client/Controllers/HUDController.luau")
		t.ok(string.find(hudSrc, 'FindFirstChild("DeathScreenController")', 1, true) ~= nil)
	end)

	t.test("every cursor screen suspends the shoulder camera while it is up", function()
		local cases = {
			{
				"src/client/Controllers/MenuController.luau",
				{
					'suspendShoulderCamera("pause", true)',
					'suspendShoulderCamera("pause", false)',
					'suspendShoulderCamera("gear", true)',
					'suspendShoulderCamera("gear", false)',
				},
			},
			{
				"src/client/Controllers/PhoneController.luau",
				{ "suspendShoulderCamera(true)", "suspendShoulderCamera(false)", '"phone"' },
			},
			{
				"src/client/Controllers/GunShopUI.luau",
				{ "suspendShoulderCamera(true)", "suspendShoulderCamera(false)", '"gunshop"' },
			},
			{
				"src/client/Controllers/WeaponWheel.luau",
				{ 'setSuspended("wheel", true)', 'setSuspended("wheel", false)' },
			},
		}
		for _, c in cases do
			local src = fs.readFile(c[1])
			for _, needle in c[2] do
				t.ok(string.find(src, needle, 1, true) ~= nil, c[1] .. ": " .. needle)
			end
		end
	end)
end
