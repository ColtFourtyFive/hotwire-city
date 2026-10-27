--!nocheck
-- Builds the v2 world layer (MapBuilder v2, no terrain) through the Lune harness and prints the part counts by
-- category and by part name, plus the build time. Used for WORLD_SPEC.md §9.
--
--   lune run tools/world/map_counts.luau
local H = require("../../tests/harness")
H.setMode("server")
local MapBuilder = H.require("src/server/Systems/MapBuilder")

local GROUPS = {
	{ "roads", "Road Sidewalk SidewalkCorner Junction Crosswalk StopBar Median ParkingLot Driveway" },
	{ "freeways", "Deck Barrier Pier PierCap FwLampHead FwLampArm FwLampPole Gantry GantrySign TrenchWall Parapet" },
	{ "signals + signs", "SignalHead SignalLens SignalPole SignalArm StopSign StopPost SignBoard SignPole" },
	{
		"streetscape",
		"LampHead LampPole PalmFrond PalmCrown PalmTrunk PalmSkirt TreeTrunk TreeCanopy PoleArm UtilityPole Wire "
			.. "Hydrant Bin BusShelter BusShelterBack BusBench BillboardPole Billboard PowerLine Pylon PylonArm PylonBeam",
	},
	{ "collision skeleton", "Skeleton" },
}

local t0 = os.clock()
MapBuilder.build(H.workspace, { terrain = false })
local seconds = os.clock() - t0
local counts, total = MapBuilder.counts()

print(("world layer: %d parts (budget %d), built in %.1f s"):format(total, MapBuilder.PART_BUDGET, seconds))
local used = {}
for _, g in GROUPS do
	local n = 0
	for name in g[2]:gmatch("%S+") do
		n += counts[name] or 0
		used[name] = true
	end
	print(("  %-34s %6d"):format(g[1], n))
end
local rest = 0
for name, n in counts do
	if not used[name] then
		rest += n
	end
end
print(("  %-34s %6d"):format("places, landmarks, bridges, plots", rest))

local names = {}
for name in counts do
	table.insert(names, name)
end
table.sort(names, function(a, b)
	return counts[a] > counts[b]
end)
local line = {}
for _, name in names do
	table.insert(line, ("%s=%d"):format(name, counts[name]))
end
print(table.concat(line, " "))
