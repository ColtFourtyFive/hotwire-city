local Harness = require("../../tests/harness")
local W = Harness.require("src/shared/Config/WorldLayout")
local Q = Harness.require("src/shared/Util/WorldQuery")
local V = Harness.roblox.Vector3
local p, ei, s, d = Q.nearestRoadPoint(V.new(320, 12, -300))
print("nearest", p, ei and W.Edges[ei].name, s, d)
print("lane", Q.laneCFrame(ei, 1, 1, s), Q.laneCFrame(ei, 3, 1, s))
print("onroad", Q.isOnRoad(V.new(320, 12, -250)))
print("district", Q.districtAt(V.new(0, 12, 0)).name, Q.districtAt(V.new(-4000, 12, 0)).name)
local par = W.Parcels[100]
print("parcelAt", Q.parcelAt(par.cframe.Position) and Q.parcelAt(par.cframe.Position).id, par.id)
local pts, len = Q.route(W.Plots[1].door, W.Plots[5].door)
print("route plot1->5", pts and #pts, len)
local it
for _, i in W.Intersections do if i.control == "signal" then it = i break end end
local acc = {} for t = 0, it.cycle, 5 do table.insert(acc, Q.signalState(it.id, 1, t)) end print(table.concat(acc, " "), it.cycle)
print("nearestLane", Q.nearestLane(V.new(0, 12, 100)))
print("hospital", Q.nearestPOI(V.new(0,12,0), "hospital").name)
-- crossing times
local function rt(a, b, label)
	local pts, len = Q.route(a, b)
	print(("%-40s %6d studs  %5.0fs @70  %5.0fs @100  %5.0fs @130"):format(label, len, len/70, len/100, len/130))
end
rt(V.new(-4480, 12, -950), V.new(5620, 30, -680), "Palmera Pier -> east coast (Red Mesa Rd)")
rt(V.new(-4480, 12, -950), V.new(2400, 12, -250), "Palmera Pier -> Foundry")
rt(V.new(1560, 80, -4560), V.new(700, 12, 4380), "Northpoint -> Iron Bay port")
rt(V.new(-4500, 12, -2100), V.new(3300, 12, 2550), "NW beach -> Rust Flats chop shop")
rt(W.Plots[1].door, W.Plots[4].door, "Palmera Garage -> Foundry Garage")
