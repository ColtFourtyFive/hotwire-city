--!nocheck
-- Export the road cross-section signatures MapBuilder v2 paints (one marking texture per signature) to JSON for
-- tools/world/markings.py.   lune run tools/world/markings_export.luau build/world/markings.json
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local H = require("../../tests/harness")
local W = H.require("src/shared/Config/WorldLayout")
local Markings = H.require("src/server/Systems/World/Markings")

local out = process.args[1] or "build/world/markings.json"
local sigs = {}
local list = {}
for _, e in W.Edges do
	local key, spec = Markings.signature(e)
	if key and not sigs[key] then
		sigs[key] = true
		spec.key = key
		table.insert(list, spec)
	end
end
table.sort(list, function(a, b)
	return a.key < b.key
end)
fs.writeDir(out:match("^(.*)/[^/]+$") or ".")
fs.writeFile(out, serde.encode("json", { lane = W.Scale.LANE, period = Markings.PERIOD, signatures = list }, true))
print(("wrote %s: %d signatures"):format(out, #list))
