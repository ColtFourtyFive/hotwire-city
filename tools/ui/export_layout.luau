--!nocheck
-- Dump the HUD layout (src/client/UI/HudLayout.luau) plus the pause-menu frame and shard band for the PIL mockups.
--
--   lune run tools/ui/export_layout.luau <out.json>
--
-- Canvases (design px inside CoreUISafeInsets, the same numbers the controllers and tests use):
--   desktop  a 1280 x 720 window at UIScale 1, minus the 58 px Roblox top bar: 1280 x 662 at (0, 58)
--   phone    an 844 x 390 phone (notch insets 47 px each side, top bar 37 px, home bar 21 px) at the 0.72 touch
--            floor: (750 / 0.72) x (332 / 0.72) = 1042 x 461 at (47, 37)
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../tests/harness")

local out = process.args[1] or "build/ui_layout.json"

Harness.setMode("client")
local HudLayout = Harness.require("src/client/UI/HudLayout")
local PauseMenu = Harness.require("src/client/UI/PauseMenu")
Harness.setMode("server")

local canvases = {
	desktop = { w = 1280, h = 662, touch = false, real = { 1280, 720 }, inset = { 0, 58 }, scale = 1 },
	phone = { w = 1042, h = 461, touch = true, real = { 844, 390 }, inset = { 47, 37 }, scale = 0.72 },
}

local result = {}
for name, c in canvases do
	local L = HudLayout.compute(c.w, c.h, c.touch)
	local cy, bh = HudLayout.shardBand(c.h)
	result[name] = {
		canvas = c,
		layout = L,
		-- HUDController.setPhoneOpen: the cash / stars / timer bars step out of the phone's way
		phoneLayout = HudLayout.withPhone(L),
		sheet = { rows = HudLayout.sheetRows(L.list.h), spec = HudLayout.SHEET },
		pause = PauseMenu.frame(c.touch),
		shard = { cy = cy, h = bh },
		bars = { HudLayout.barSegments(L.bars.w, 2) },
	}
end

fs.writeFile(out, serde.encode("json", result, true))
print("wrote " .. out)
