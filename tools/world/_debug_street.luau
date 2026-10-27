local Harness = require("../../tests/harness")
local W = Harness.require("src/shared/Config/WorldLayout")
for _, e in W.Edges do
	for k, p in e.points do
		if math.abs(p.X + 2700) < 120 and math.abs(p.Z - 1275) < 60 then
			local a, b = e.points[1], e.points[#e.points]
			print(e.id, e.name, e.class, ("(%d,%d,%d) -> (%d,%d,%d) n=%d"):format(a.X, a.Y, a.Z, b.X, b.Y, b.Z, #e.points))
			local s = {}
			for _, q in e.points do table.insert(s, ("(%d,%d)"):format(q.X, q.Z)) end
			print("   ", table.concat(s, " "))
			break
		end
	end
end
