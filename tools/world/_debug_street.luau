local Harness = require("../../tests/harness")
local W = Harness.require("src/shared/Config/WorldLayout")
for _, e in W.Edges do
	if e.name == "Kingsley Dr" or e.name == "Vista Avenue" then
		local a, b = e.points[1], e.points[#e.points]
		if (e.name == "Kingsley Dr" and math.max(a.X, b.X) > 900) or (e.name == "Vista Avenue" and math.min(a.Z,b.Z) < -900 and math.max(a.Z,b.Z) > -1600) then
			print(e.id, e.name, ("(%d,%d) -> (%d,%d)"):format(a.X, a.Z, b.X, b.Z), e.width)
		end
	end
end
for _, p in W.POIs do if p.id == "Arena" or p.id == "Casino" then print(p.id, p.cframe.Position, p.cframe.LookVector) end end
