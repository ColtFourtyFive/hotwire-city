--!nocheck
-- Dump the C4b polish layout numbers for tools/ui/polish_mockups.py (same canvases as export_layout.luau):
--   lune run tools/ui/export_polish.luau <out.json>
-- Shard band / title metrics (UI/Shard), PromptStyle touch buttons and help text (UI/PromptStyle), the event-row and
-- help texts the game builds (EventsClient, DeathScreenController), so the PIL mocks use the game's own numbers/copy.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../tests/harness")

local out = process.args[1] or "build/ui_polish.json"

Harness.setMode("client")
local HudLayout = Harness.require("src/client/UI/HudLayout")
local Shard = Harness.require("src/client/UI/Shard")
local PromptStyle = Harness.require("src/client/UI/PromptStyle")
local RichText = Harness.require("src/client/UI/RichText")
local DeathScreen = Harness.require("src/client/Controllers/DeathScreenController")
local EventsClient = Harness.require("src/client/Controllers/EventsClient")
local VehicleClient = Harness.require("src/client/Controllers/VehicleClient")
Harness.setMode("server")

local canvases = {
	desktop = { w = 1280, h = 662, touch = false, real = { 1280, 720 }, input = "keyboard" },
	phone = { w = 1042, h = 461, touch = true, real = { 844, 390 }, input = "touch" },
}

-- a RowView with its Color3 as an [r, g, b] list (serde cannot encode userdata)
local function plainRow(v)
	return {
		label = v.label,
		value = v.value,
		urgent = v.urgent,
		color = {
			math.floor(v.color.R * 255 + 0.5),
			math.floor(v.color.G * 255 + 0.5),
			math.floor(v.color.B * 255 + 0.5),
		},
	}
end

local steal = { action = "Hotwire", object = "Halden Wren", hold = 1.8, key = "E", pad = "ButtonX" }
local drive = { action = "Drive", object = "Kronberg K8", hold = 0, key = "E", pad = "ButtonX" }
local sell = { action = "Sell $4,250", object = "Kronberg K8", hold = 1, key = "F", pad = "ButtonY" }

local result = {
	shard = {
		frameHeight = Shard.bandHeight("frame"),
		keystoneHeight = Shard.bandHeight("keystone"),
		centre = 0.488,
		titleY = 0.468,
		subtitleY = 0.538,
		alpha = { wasted = Shard.style("wasted").alpha, busted = Shard.style("busted").alpha },
		vignetteEdge = DeathScreen.VIGNETTE_EDGE,
		wastedSubtitle = DeathScreen._wastedSubtitle({ by = "Officer Reyes", bill = 1240 }),
		wastedSubtitleAlone = DeathScreen._wastedSubtitle({}),
		bustedSubtitle = DeathScreen._bustedSubtitle(3600, "Halden Wren"),
		grade = {
			saturation = Shard.GRADE.Saturation,
			contrast = Shard.GRADE.Contrast,
			brightness = Shard.GRADE.Brightness,
		},
	},
	events = {
		rushHour = plainRow(EventsClient.rowView("rushHour", 72)),
		doubleCash = plainRow(EventsClient.rowView("doubleCash", 270)),
		distance = EventsClient.distanceText(3950),
		timedAsBarsTouch = EventsClient.timedAsBars(true, true),
		timer = { h = HudLayout.TIMER.h, gap = HudLayout.TIMER.gap },
	},
	prompt = {
		steal = PromptStyle.helpText({ steal }, "keyboard"),
		stealPad = PromptStyle.helpText({ steal }, "gamepad"),
		stealTouch = PromptStyle.helpText({ steal }, "touch"),
		garage = PromptStyle.helpText({ drive, sell }, "keyboard"),
		calm = RichText.calm("Your garage is full! Sell a car first!"),
	},
	vehicleNameHold = VehicleClient.VEHICLE_NAME_HOLD,
	vehicleNameSize = VehicleClient.NAME_SIZE,
}

for name, c in canvases do
	local L = HudLayout.compute(c.w, c.h, c.touch)
	local scale, subtitleMax = Shard.textMetrics(c.real[1], c.real[2])
	result[name] = {
		shardTitleScale = scale,
		shardSubtitleMax = subtitleMax,
		promptRects = PromptStyle.touchRects(L, 2, false),
		vehicleNameRect = VehicleClient.nameRect(L.locationDriving, L.locationLines),
	}
end

fs.writeFile(out, serde.encode("json", result, true))
print("wrote " .. out)
