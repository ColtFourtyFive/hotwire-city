--!nocheck
-- Dumps the character creator's orbit camera (Appearance/CreatorModel.framing) over a full turn, for the top-down
-- evidence plot (tools/characters/creator_orbit.py -> docs/v2/evidence/characters_creator_orbit.png): the room box,
-- the lens position and look direction at every yaw (desktop and touch, full body and face close-up), whether the
-- lens had to be pulled in to stay inside the room, the orbit limit and the wall the height chart is on.
-- usage (repo root): lune run tools/characters/creator_orbit.luau OUT.json

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Harness = require("../../tests/harness")

local CreatorModel = Harness.require("src/shared/Appearance/CreatorModel")
local V3 = Harness.roblox.Vector3

local origin = V3.new(0, 0, 0)
local headY = 5.6
local samples = {}
for _, focus in { "body", "face" } do
	for _, touch in { false, true } do
		for deg = -180, 180, 5 do
			local cf = CreatorModel.framing(origin, headY, focus, touch, math.rad(deg))
			local height = headY - origin.Y + 0.7
			local target = if focus == "face" then V3.new(0, headY + 0.1, 0) else V3.new(0, origin.Y + height * 0.5, 0)
			local want = if focus == "face" then CreatorModel.FACE_DIST else CreatorModel.bodyDistance(height, 40)
			local dist = (cf.Position - target).Magnitude
			table.insert(samples, {
				focus = focus,
				touch = touch,
				yaw = deg,
				x = cf.Position.X,
				y = cf.Position.Y,
				z = cf.Position.Z,
				lx = cf.LookVector.X,
				lz = cf.LookVector.Z,
				pulledIn = dist < want * 0.98,
				reachable = math.abs(deg) <= math.deg(CreatorModel.MAX_YAW) + 1e-6,
			})
		end
	end
end
local parts = CreatorModel.studio()
local walls = {}
for _, p in parts do
	table.insert(walls, {
		name = p.name,
		x = p.offset.X,
		y = p.offset.Y,
		z = p.offset.Z,
		sx = p.size.X,
		sy = p.size.Y,
		sz = p.size.Z,
	})
end
local out = {
	room = CreatorModel.ROOM,
	margin = CreatorModel.LENS_MARGIN,
	maxYaw = math.deg(CreatorModel.MAX_YAW),
	chartFace = CreatorModel.CHART_FACE,
	walls = walls,
	samples = samples,
}
fs.writeFile(process.args[1], serde.encode("json", out, true))
print(("dumped %d camera samples -> %s"):format(#samples, process.args[1]))
