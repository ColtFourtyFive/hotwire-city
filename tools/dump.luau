--!nocheck
-- Build game geometry headlessly in Lune and dump parts to JSON for tools/render.py.
--
--   lune run tools/dump.luau car <carId|police|all> [mutation] out.json
--   lune run tools/dump.luau map out.json
--   lune run tools/dump.luau plot <index> out.json
--
-- Contracts used: Shared/Vehicle/CarBuilder.build(carId, mutation, {forDisplay=true}) / .buildDef(def, ...)
--                 Server/Systems/MapBuilder.build(parent) -> Folder
--                 Server/Systems/PlotService.buildGarageModel(index) -> Model
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../tests/harness")

local args = process.args
local kind = args[1]
local Instance = Harness.roblox.Instance

local function writeGroups(groups, out)
	fs.writeFile(out, serde.encode("json", { groups = groups }))
	print("wrote " .. out)
end

if kind == "car" then
	local which, mutation, out = args[2], args[3] or "None", args[4] or args[3]
	if args[4] == nil then
		mutation = "None"
		out = args[3]
	end
	local CarBuilder = Harness.require("src/shared/Vehicle/CarBuilder")
	local Cars = Harness.require("src/shared/Config/Cars")
	local ids = {}
	if which == "all" then
		for _, def in Cars.List do
			table.insert(ids, def.id)
		end
		table.insert(ids, "police")
	else
		ids = string.split(which, ",")
	end
	local groups = {}
	for _, id in ids do
		local model
		if id == "police" then
			model = CarBuilder.buildDef(Cars.Police, mutation, { forDisplay = true })
		else
			model = CarBuilder.build(id, mutation, { forDisplay = true })
		end
		local parts = Harness.dumpParts(model)
		table.insert(groups, {
			title = ("%s (%d parts, ride %.2f, wheel r %.2f)"):format(
				id,
				#parts,
				model:GetAttribute("RideHeight") or -1,
				model:GetAttribute("WheelRadius") or -1
			),
			parts = parts,
		})
	end
	writeGroups(groups, out)
elseif kind == "map" then
	local out = args[2]
	local MapBuilder = Harness.require("src/server/Systems/MapBuilder")
	local folder = MapBuilder.build(Harness.workspace)
	local parts = Harness.dumpParts(folder)
	print(("map parts: %d"):format(#parts))
	writeGroups({ { title = ("map (%d parts)"):format(#parts), parts = parts } }, out)
elseif kind == "plot" then
	local index = tonumber(args[2])
	local out = args[3]
	local PlotService = Harness.require("src/server/Systems/PlotService")
	local model = PlotService.buildGarageModel(index)
	local parts = Harness.dumpParts(model)
	writeGroups({ { title = ("plot %d (%d parts)"):format(index, #parts), parts = parts } }, out)
else
	print("usage: see header")
	process.exit(1)
end
