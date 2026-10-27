--!nocheck
-- Dump Config/Sounds as JSON (for tools/audio/audit.py): every key with its id and playback fields.
--
--   lune run tools/audio/dump_sounds.luau out.json
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../tests/harness")

local out = process.args[1] or "sounds.json"
local Sounds = Harness.require("src/shared/Config/Sounds")

local rows = {}
for key, def in Sounds do
	if type(def) == "table" and type(def.id) == "string" then
		local row = {}
		for k, v in def do
			local tv = typeof(v)
			if tv == "string" or tv == "number" or tv == "boolean" then
				row[k] = v
			end
		end
		row.key = key
		table.insert(rows, row)
	end
end
table.sort(rows, function(a, b)
	return a.key < b.key
end)
fs.writeFile(out, serde.encode("json", rows, true))
print(("wrote %s (%d sounds)"):format(out, #rows))
