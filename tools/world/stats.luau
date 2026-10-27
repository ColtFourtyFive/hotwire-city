--!nocheck
-- Print the v2 world's headline numbers (used by docs/v2/world/WORLD_SPEC.md):  lune run tools/world/stats.luau
local Harness = require("../../tests/harness")
local t0 = os.clock()
local W = Harness.require("src/shared/Config/WorldLayout")
local build = os.clock() - t0
local Q = Harness.require("src/shared/Util/WorldQuery")
local V = Harness.roblox.Vector3

print(("build %.2fs (Lune)"):format(build))
for k, v in W.Stats do
	print(("  %-14s %s"):format(k, tostring(v)))
end

-- road length by class, elevated length, bridges
local byClass, elevated, bridges, segs = {}, 0, 0, 0
for _, e in W.Edges do
	byClass[e.class] = (byClass[e.class] or 0) + e.length
	if e.elevated then
		elevated += e.length
	end
	if e.bridge then
		bridges += 1
	end
	segs += #e.points - 1
end
print("road length by class (studs):")
local keys = {}
for k in byClass do
	table.insert(keys, k)
end
table.sort(keys)
for _, k in keys do
	print(("  %-10s %7d"):format(k, byClass[k]))
end
print(("elevated %d studs, bridge edges %d, polyline segments %d"):format(elevated, bridges, segs))

-- intersections by control
local ctl = {}
for _, i in W.Intersections do
	ctl[i.control] = (ctl[i.control] or 0) + 1
end
for k, v in ctl do
	print("  control", k, v)
end

-- parcels by district / use
local byD, byUse, tall = {}, {}, 0
for _, p in W.Parcels do
	byD[p.district] = (byD[p.district] or 0) + 1
	byUse[p.use] = (byUse[p.use] or 0) + 1
	if p.size.Y >= 250 then
		tall += 1
	end
end
print("parcels by district:")
for k, v in byD do
	print(("  %-10s %d"):format(k, v))
end
local uses = {}
for k, v in byUse do
	table.insert(uses, k .. "=" .. v)
end
table.sort(uses)
print("parcels by use: " .. table.concat(uses, ", "))
print("towers >= 250 studs (20+ floors):", tall)

-- POIs by kind
local kinds = {}
for _, p in W.POIs do
	kinds[p.kind] = (kinds[p.kind] or 0) + 1
end
local ks = {}
for k, v in kinds do
	table.insert(ks, k .. "=" .. v)
end
table.sort(ks)
print("POIs: " .. table.concat(ks, ", "))

-- plots
print("plots:")
for _, p in W.Plots do
	print(
		("  %d %-22s %-10s (%5d, %5d)  on-ramp %4d"):format(
			p.index,
			p.name,
			p.district,
			p.cframe.Position.X,
			p.cframe.Position.Z,
			p.nearestOnRamp
		)
	)
end
local minD, maxD = math.huge, 0
for i, a in W.Plots do
	for j, b in W.Plots do
		if i < j then
			local _, len = Q.route(a.door, b.door)
			minD = math.min(minD, len)
			maxD = math.max(maxD, len)
		end
	end
end
print(("garage-to-garage road distance: min %d, max %d studs"):format(minD, maxD))

-- travel
local function rt(a, b, label)
	local _, len = Q.route(a, b)
	print(("  %-44s %6d studs  %4.0fs@70  %4.0fs@100  %4.0fs@140"):format(label, len, len / 70, len / 100, len / 140))
end
print("travel (road distance; avg speed incl. turns/traffic):")
rt(V.new(-4480, 12, -950), V.new(5620, 30, -680), "Palmera Pier -> east coast (W-E crossing)")
rt(V.new(-150, 12, -2140), V.new(-150, 12, 2900), "Sunwood Blvd -> Southgate shore (N-S core)")
rt(V.new(1560, 80, -4560), V.new(700, 12, 4380), "Northpoint -> Iron Bay port (N-S island)")
rt(
	W.POIs[1].entrance,
	Q.poi("HCI Terminal") and Q.poi("Terminal").entrance or V.new(-4100, 12, 2330),
	"Hotwire Plaza -> airport terminal"
)
local ring = 0
for _, e in W.Edges do
	if e.corridor == "H1 Ring Freeway" and e.class == "freeway" and e.name:find("counter") == nil then
		ring += e.length
	end
end
print(("H1 ring lap (one carriageway) %d studs = %.0fs at 120"):format(ring, ring / 120))
for _, r in W.Routes do
	print(("  route %-14s %-40s %6d studs"):format(r.id, r.name, r.length))
end

-- island extents
local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
for _, p in W.Coast do
	minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
	minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
end
print(("mainland extents X %d..%d (%d), Z %d..%d (%d)"):format(minX, maxX, maxX - minX, minZ, maxZ, maxZ - minZ))

-- part budget estimate (before meshes): see WORLD_SPEC section 9
local PER_USE = {
	office_tower = 34,
	residential_tower = 30,
	hotel = 26,
	beach_hotel = 22,
	apartment = 16,
	office_midrise = 18,
	retail = 9,
	restaurant = 9,
	nightclub = 10,
	parking_garage = 14,
	parking_lot = 3,
	plaza = 6,
	park = 4,
	house = 9,
	duplex = 10,
	corner_store = 8,
	retail_strip = 10,
	church = 10,
	mansion = 16,
	villa = 12,
	loft = 12,
	warehouse = 8,
	brewery = 10,
	gallery = 9,
	factory = 14,
	yard = 4,
	shed = 5,
	container_yard = 6,
	hangar = 8,
	farmhouse = 9,
	barn = 7,
	shop = 8,
	diner = 9,
	motel = 12,
}
local lots = 0
for _, p in W.Parcels do
	lots += PER_USE[p.use] or 10
end
local roads = 0
for _, e in W.Edges do
	local n = #e.points - 1
	if e.elevated then
		roads += n * 3 + math.ceil(e.length / 90) -- deck + 2 barriers per segment, a pier every 90 studs
	elseif e.sidewalk > 0 then
		roads += n * 5 -- asphalt, 2 curbs, 2 sidewalks
	else
		roads += n * 1
	end
end
local junctions = #W.Intersections * 5
local pois = #W.POIs * 40
local props = math.floor((byClass.street or 0) / 60 + (byClass.avenue or 0) / 45 + (byClass.boulevard or 0) / 45)
print(
	("part estimate: roads %d, junctions %d, lots %d, POIs %d, street props (lamps/signals/hydrants, part-built) %d  => %d"):format(
		roads,
		junctions,
		lots,
		pois,
		props,
		roads + junctions + lots + pois + props
	)
)
