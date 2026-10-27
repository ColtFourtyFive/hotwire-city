--!nocheck
-- Dump Config/VFX presets (with Color3 / Vector3 flattened) to JSON for tools/vfx/preview_effects.py.
--   lune run tools/vfx/dump_presets.luau out.json
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../tests/harness")

local VFX = Harness.require("src/shared/Config/VFX")

local function flat(v)
	local t = typeof(v)
	if t == "Color3" then
		return { math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5) }
	elseif t == "Vector3" then
		return { v.X, v.Y, v.Z }
	elseif t == "table" then
		local out = {}
		for k, x in v do
			out[k] = flat(x)
		end
		return out
	end
	return v
end

local out = process.args[1] or "presets.json"
fs.writeFile(
	out,
	serde.encode("json", {
		presets = flat(VFX.Presets),
		trails = flat(VFX.Trails),
		beams = flat(VFX.Beams),
		layouts = VFX.FlipbookLayouts,
		confetti = flat(VFX.CONFETTI_COLORS),
		quality = flat(VFX.Quality),
	})
)
print("wrote " .. out)
