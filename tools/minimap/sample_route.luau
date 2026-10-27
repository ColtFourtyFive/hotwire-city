--!nocheck
-- Dump real RoadGraph GPS routes (for tools/minimap/preview_ui.py and debugging).
--
--   lune run tools/minimap/sample_route.luau <out.json> fromX fromZ toX toZ [fromX fromZ toX toZ ...]
--
-- Writes { routes = { { from, to, points = { {x, z}, ... }, length, ms } } }.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../tests/harness")

local RoadGraph = Harness.require("src/shared/Util/RoadGraph")
local Vector3 = Harness.roblox.Vector3

local args = process.args
local out = args[1]
local routes = {}
local i = 2
while args[i + 3] do
	local a = Vector3.new(tonumber(args[i]), 0, tonumber(args[i + 1]))
	local b = Vector3.new(tonumber(args[i + 2]), 0, tonumber(args[i + 3]))
	local t0 = os.clock()
	local pts = RoadGraph.route(a, b)
	local ms = (os.clock() - t0) * 1000
	local list = {}
	for _, p in pts or {} do
		table.insert(list, { p.X, p.Z })
	end
	table.insert(routes, {
		from = { a.X, a.Z },
		to = { b.X, b.Z },
		points = list,
		length = RoadGraph.routeLength(pts),
		ms = ms,
	})
	i += 4
end
fs.writeFile(out, serde.encode("json", { routes = routes }))
print(("wrote %d route(s) -> %s"):format(#routes, out))
