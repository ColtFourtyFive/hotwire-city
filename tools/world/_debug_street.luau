local Harness = require("../../tests/harness")
local W = Harness.require("src/shared/Config/WorldLayout")
for _, e in W.Edges do
	local a = e.points[1]
	local b = e.points[#e.points]
	if (math.abs(a.X + 150) < 30 and math.abs(a.Z + 2142) < 30) or (math.abs(b.X + 150) < 30 and math.abs(b.Z + 2142) < 30) then
		local s = {}
		for k = 1, math.min(5, #e.points) do local q = e.points[k] table.insert(s, ("(%d,%.1f,%d)"):format(q.X, q.Y, q.Z)) end
		print(e.id, e.name, e.a, e.b, table.concat(s, " "), "...", ("(%d,%.1f,%d)"):format(b.X, b.Y, b.Z))
	end
end
