--!nocheck
-- Optional evidence context: plans package A3's buildings (BuildingService.planAll, on its own branch) over THIS
-- world's baked parcels, so the world previews can show the real building set instead of massing stand-ins.
-- Nothing here ships; A3 owns BuildingService and the building assets.
--
-- Run it from a checkout of the A3 branch whose world data is replaced by this one (tools/blender/preview/README.md):
--   git archive v2/buildings src tests/harness.luau tools/blender/buildkit assets/buildings | tar -x -C build/a3
--   cp <this world's Config/WorldLayout, WorldData, Map, server Config/WorldDataLots, Util/World*> into build/a3
--   (cd build/a3 && lune run ../../tools/blender/preview/a3_placements.luau ../preview/a3_placements.json)
-- Output (the shape of A3's tools/blender/buildkit/export_placements.luau, which render_city.py places):
--   parcels[]    every parcel (id, district, use, style, cframe, size, family)
--   buildings[]  every planned building (parcel index, kind, template, model CFrame, per-axis scale, finish, glass)
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../../tests/harness")

local out = process.args[1] or "a3_placements.json"
Harness.setMode("server")
local WorldLayout = Harness.require("src/shared/Config/WorldLayout")
local BuildingService = Harness.require("src/server/Systems/BuildingService")

local parcels = WorldLayout.Parcels
local t0 = os.clock()
local plans = BuildingService.planAll(parcels)

local function r3(v)
	return math.floor(v * 1000 + 0.5) / 1000
end
local function cfArr(cf)
	local c = { cf:GetComponents() }
	for i, v in c do
		c[i] = r3(v)
	end
	return c
end

local prow = {}
for _, p in parcels do
	local pos = p.cframe.Position
	table.insert(prow, {
		id = p.id,
		district = p.district,
		subzone = p.subzone,
		use = p.use,
		style = p.style,
		seed = p.seed,
		floors = p.floors,
		tower = p.tower,
		podium = p.podium,
		crown = p.crown,
		stilts = p.stilts,
		center = { r3(pos.X), r3(pos.Y), r3(pos.Z) },
		size = { r3(p.size.X), r3(p.size.Y), r3(p.size.Z) },
		cframe = cfArr(p.cframe),
		family = BuildingService.familyFor(p),
	})
end

local brow = {}
local counts = {}
for _, plan in plans do
	table.insert(brow, {
		parcel = plan.parcel,
		parcelId = plan.parcelId,
		piece = plan.piece,
		kind = plan.kind,
		family = plan.family,
		template = plan.template,
		cframe = cfArr(plan.cframe),
		scale = { r3(plan.scale.X), r3(plan.scale.Y), r3(plan.scale.Z) },
		size = { r3(plan.size.X), r3(plan.size.Y), r3(plan.size.Z) },
		score = r3(plan.score),
		reason = plan.reason,
		wall = plan.wall,
		glass = plan.glass,
		lite = plan.lite,
		foundation = plan.foundation,
		lit = plan.lit,
		litAt = r3(plan.litAt),
		litColor = plan.litColor,
	})
	counts[plan.kind] = (counts[plan.kind] or 0) + 1
end

fs.writeFile(out, serde.encode("json", { parcels = prow, buildings = brow }, false))
local parts = {}
for k, n in counts do
	table.insert(parts, k .. "=" .. n)
end
table.sort(parts)
print(
	("wrote %s: %d parcels, %d buildings (%s) in %.1f s"):format(
		out,
		#prow,
		#brow,
		table.concat(parts, ", "),
		os.clock() - t0
	)
)
