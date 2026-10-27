--!strict
-- World/Spatial: road footprint queries for the builders (pier bases, barrier gore cuts, prop clearance).
--
--   Spatial.roadAt(x, z, y?, opts?)   the edge whose footprint (curb to curb + pad) covers (x, z), optionally only
--                                     roads within dy of height y, or below yMax; nil when clear
--   Spatial.insideOther(ei, p, slack) p lies on another deck / road pavement at about p's height (|dy| < 4)
--
-- One segment index over every WorldLayout edge (64-stud cells), built on first use.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldGen = require(Shared.Util.WorldGen)

local Spatial = {}

local Edges = WorldLayout.Edges
local idx: WorldGen.SegIndex? = nil
local y0: { number } = {}
local y1: { number } = {}

local function index(): WorldGen.SegIndex
	local built = idx
	if built then
		return built
	end
	local nb = WorldGen.segIndex(64)
	for ei, e in Edges do
		local pts = e.points
		local pad = e.width / 2 + e.sidewalk + 8
		for k = 1, #pts - 1 do
			local a, b = pts[k], pts[k + 1]
			WorldGen.segAdd(nb, a.X, a.Z, b.X, b.Z, ei, k, pad)
			local id = #nb.ax
			y0[id] = a.Y
			y1[id] = b.Y
		end
	end
	idx = nb
	return nb
end

export type RoadOpts = {
	pad: number?, -- extra studs past the footprint (default 0)
	sidewalk: boolean?, -- include the sidewalks (default true)
	yMax: number?, -- only roads whose surface there is below this
	yNear: number?, -- only roads within dy of this height
	dy: number?, -- default 4
	skip: number?, -- ignore this edge
	classes: { [string]: boolean }?,
}

-- The edge covering (x, z), or nil.
function Spatial.roadAt(x: number, z: number, opts: RoadOpts?): number?
	local ix = index()
	local pad = if opts and opts.pad then opts.pad else 0
	local withSw = not (opts and opts.sidewalk == false)
	local hit: number? = nil
	WorldGen.segQuery(ix, x, z, 0, function(id: number)
		if hit then
			return
		end
		local ei = ix.owner[id]
		if opts and opts.skip == ei then
			return
		end
		local e = Edges[ei]
		if opts and opts.classes and not opts.classes[e.class] then
			return
		end
		local t, _, _, d = WorldGen.projectSeg(x, z, ix.ax[id], ix.az[id], ix.bx[id], ix.bz[id])
		local half = e.width / 2 + (if withSw then e.sidewalk else 0) + pad
		if d > half then
			return
		end
		local py = y0[id] + (y1[id] - y0[id]) * t
		if opts and opts.yMax and py >= opts.yMax then
			return
		end
		if opts and opts.yNear and math.abs(py - opts.yNear) > (opts.dy or 4) then
			return
		end
		hit = ei
	end)
	return hit
end

-- Does p (at its own height) lie on the pavement of another edge than ei (shrunk by slack)?
function Spatial.insideOther(ei: number, p: Vector3, slack: number): boolean
	local ix = index()
	local hit = false
	WorldGen.segQuery(ix, p.X, p.Z, 0, function(id: number)
		if hit then
			return
		end
		local other = ix.owner[id]
		if other == ei then
			return
		end
		local e = Edges[other]
		local t, _, _, d = WorldGen.projectSeg(p.X, p.Z, ix.ax[id], ix.az[id], ix.bx[id], ix.bz[id])
		if d > e.width / 2 - slack then
			return
		end
		local py = y0[id] + (y1[id] - y0[id]) * t
		if math.abs(py - p.Y) < 4 then
			hit = true
		end
	end)
	return hit
end

return Spatial
