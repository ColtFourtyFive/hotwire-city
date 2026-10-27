--!nocheck
-- Runs the v2 world generator (tools/world/gen) and BuildingService's placement planner over every parcel, and writes
-- the result as JSON for the Blender evidence renders (render_city.py) and for checking fit coverage.
--
--   lune run tools/blender/buildkit/export_placements.luau [out.json]
--
-- Default output: tools/blender/buildkit/_cache/placements.json (git-ignored):
--   parcels[]    every parcel (id, district, subzone, use, style, seed, floors, tower/podium/crown/stilts, cframe, size)
--   buildings[]  every planned building (parcel index, kind, template, model CFrame, per-axis scale, wall finish, glass
--                tint, lit-window state), exactly what BuildingService places at runtime
--   roads[]      road centrelines near buildings (class, width, sidewalk, points) for the render's street context
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../../tests/harness")
local generate = require("../../world/gen")

local out = process.args[1] or "tools/blender/buildkit/_cache/placements.json"

Harness.setMode("server")
local BuildingService = Harness.require("src/server/Systems/BuildingService")

local W = generate()
local parcels = W.Parcels
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
local reasons = {}
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
	if plan.kind == "massing" then
		local p = parcels[plan.parcel]
		local k = ("%s/%s/%s"):format(plan.family, p.use, p.style)
		reasons[k] = (reasons[k] or 0) + 1
	end
end

-- roads: every ground-level edge (the render crops to its camera boxes)
local roads = {}
for _, e in W.Edges do
	if e.points and #e.points >= 2 then
		local pts = {}
		for _, q in e.points do
			table.insert(pts, { r3(q.X), r3(q.Y), r3(q.Z) })
		end
		table.insert(roads, {
			class = e.class,
			width = e.width,
			sidewalk = e.sidewalk or 0,
			elevated = e.elevated == true,
			bridge = e.bridge == true,
			layer = e.layer or 0,
			points = pts,
		})
	end
end

local dir = out:match("^(.*)/[^/]+$")
if dir and not fs.isDir(dir) then
	fs.writeDir(dir)
end
fs.writeFile(out, serde.encode("json", { parcels = prow, buildings = brow, roads = roads }, false))
local parts = {}
for k, n in counts do
	table.insert(parts, k .. "=" .. n)
end
table.sort(parts)
print(("wrote %s: %d parcels, %d buildings (%s), %d road edges"):format(
	out,
	#prow,
	#brow,
	table.concat(parts, ", "),
	#roads
))
local rk = {}
for k, n in reasons do
	table.insert(rk, { k, n })
end
table.sort(rk, function(a, b)
	return a[2] > b[2]
end)
for _, kv in rk do
	print(("  massing %4d  %s"):format(kv[2], kv[1]))
end
