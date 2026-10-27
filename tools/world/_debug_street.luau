local Harness = require("../../tests/harness")
local W = Harness.require("src/shared/Config/WorldLayout")
local name = ({...})[1] or "Dover Street"
for _, e in W.Edges do
	if e.name == "Dover Street" or e.name == "Elm Street" or e.name == "Sunwood Boulevard" then
		local a, b = e.points[1], e.points[#e.points]
		if math.min(a.Z, b.Z) < -1700 then
			print(e.id, e.name, e.class, ("(%d,%d,%d) -> (%d,%d,%d)"):format(a.X, a.Y, a.Z, b.X, b.Y, b.Z), #e.points)
		end
	end
end
