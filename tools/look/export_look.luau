--!nocheck
-- Prints src/shared/Config/Look.luau as JSON (Look is pure data). Used by tools/look/gen_project.py.
-- Usage: lune run tools/look/export_look.luau
local serde = require("@lune/serde")

local Look = require("../../src/shared/Config/Look")

print(serde.encode("json", {
	Cycle = Look.Cycle,
	Sun = Look.Sun,
	Night = Look.Night,
	Caps = Look.Caps,
	Presets = Look.Presets,
	Keys = Look.Keys,
	SkySchedule = Look.SkySchedule,
	SkyStyle = Look.SkyStyle,
}, false))
