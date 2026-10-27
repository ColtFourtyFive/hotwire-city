--!strict
-- World/Roads: ground roads from the WorldLayout graph (MapBuilder v2).
--
--   Roads.junctions()            junction geometry for every ground intersection: per approach the asphalt trim T (where
--                                the approach's own asphalt starts), per side the sidewalk trim, the curb corners, the
--                                core polygon. Pure (no Instances); Signals / Streetscape reuse it.
--   Roads.build(ctx, geo)        asphalt (Enum.Material.Asphalt + HC_Asphalt, lane markings as one texture per
--                                cross-section), sidewalks (Pavement, the slab's road-side face is the curb), raised
--                                medians, junction cores and sidewalk corners, crosswalks and stop bars, street bridges
--                                (girder + parapets) over the Rust River, the trench and the canyon
--
-- Freeways / ramps (World/Freeways), the channel floor and the pier deck (World/Places) are built elsewhere.
-- Geometry: every polyline is simplified into straight runs; each run is one slab, extended at its joints by
-- (half width) x tan(turn / 2) so curves close on the outside (they overlap a little on the inside).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local Look = require(Shared.Config.Look)
local Kit = require(script.Parent.Kit)
local Markings = require(script.Parent.Markings)

type Ctx = Kit.Ctx
type Edge = WorldLayout.Edge

local Roads = {}

local Edges = WorldLayout.Edges
local Nodes = WorldLayout.Nodes
local S = WorldLayout.Scale
local CURB = S.CURB_HEIGHT
local SLAB = 2 -- road slab thickness (the terrain is graded 0.3 under the top)

Roads.SURFACE_CLASSES = {
	boulevard = true,
	avenue = true,
	street = true,
	alley = true,
	highway = true,
	rural = true,
	dirt = true,
	service = true,
	runway = true,
} :: { [string]: boolean }

local CROSSWALK_DEPTH = 10.7
local CROSSWALK_GAP = 1.5 -- from the core edge to the crosswalk
local STOP_BAR_DEPTH = 1.6

-------------------------------------------------------------------------------------------------------------------------
-- Small vector helpers (XZ)
-------------------------------------------------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function rightOf(h: Vector3): Vector3
	return Vector3.new(-h.Z, 0, h.X)
end

-- Intersection of p + t*d and q + u*e in XZ; nil when parallel.
local function lineHit(p: Vector3, d: Vector3, q: Vector3, e: Vector3): Vector3?
	local den = d.X * e.Z - d.Z * e.X
	if math.abs(den) < 1e-6 then
		return nil
	end
	local wx, wz = q.X - p.X, q.Z - p.Z
	local t = (wx * e.Z - wz * e.X) / den
	return Vector3.new(p.X + d.X * t, 0, p.Z + d.Z * t)
end

-------------------------------------------------------------------------------------------------------------------------
-- Edge sampling
-------------------------------------------------------------------------------------------------------------------------

local cumCache: { [number]: { number } } = {}
local function cumOf(ei: number): { number }
	local c = cumCache[ei]
	if c then
		return c
	end
	local pts = Edges[ei].points
	local out = table.create(#pts, 0)
	for k = 2, #pts do
		local a, b = pts[k - 1], pts[k]
		out[k] = out[k - 1] + math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2)
	end
	cumCache[ei] = out
	return out
end
Roads.cumOf = cumOf

-- Point (3D) at XZ arc length s along edge ei.
local function pointAt(ei: number, s: number): Vector3
	local pts = Edges[ei].points
	local cum = cumOf(ei)
	local n = #pts
	if s <= 0 then
		return pts[1]
	elseif s >= cum[n] then
		return pts[n]
	end
	local lo, hi = 1, n - 1
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if cum[mid] <= s then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local seg = cum[lo + 1] - cum[lo]
	local t = if seg > 1e-9 then (s - cum[lo]) / seg else 0
	return pts[lo]:Lerp(pts[lo + 1], t)
end
Roads.pointAt = pointAt

-- The polyline of edge ei between arc lengths s0 < s1 (endpoints interpolated), simplified into straight runs:
-- consecutive points merge while every skipped point stays within 0.35 studs (XZ) / 0.2 (Y) of the chord.
local function runPoints(ei: number, s0: number, s1: number): { Vector3 }
	local pts = Edges[ei].points
	local cum = cumOf(ei)
	local raw: { Vector3 } = { pointAt(ei, s0) }
	for k = 1, #pts do
		if cum[k] > s0 + 0.05 and cum[k] < s1 - 0.05 then
			table.insert(raw, pts[k])
		end
	end
	table.insert(raw, pointAt(ei, s1))
	-- long straight segments (runways, the pier) are split: a part may not exceed 2048 studs, and shorter slabs keep
	-- the streaming cells balanced
	local dense: { Vector3 } = { raw[1] }
	for k = 2, #raw do
		local a, b = raw[k - 1], raw[k]
		local n = math.ceil((b - a).Magnitude / 400)
		for j = 1, n - 1 do
			table.insert(dense, a:Lerp(b, j / n))
		end
		table.insert(dense, b)
	end
	raw = dense
	local out: { Vector3 } = { raw[1] }
	local i = 1
	while i < #raw do
		local j = i + 1
		while j + 1 <= #raw do
			local a, b = raw[i], raw[j + 1]
			local ab = b - a
			local len = ab.Magnitude
			if len > 420 then
				break
			end
			local ok = true
			for k = i + 1, j do
				local p = raw[k]
				local t = math.clamp((p - a):Dot(ab) / math.max(len * len, 1e-9), 0, 1)
				local q = a + ab * t
				local dxz = math.sqrt((p.X - q.X) ^ 2 + (p.Z - q.Z) ^ 2)
				if dxz > 0.35 or math.abs(p.Y - q.Y) > 0.2 then
					ok = false
					break
				end
			end
			if not ok then
				break
			end
			j += 1
		end
		table.insert(out, raw[j])
		i = j
	end
	return out
end
Roads.runPoints = runPoints

-------------------------------------------------------------------------------------------------------------------------
-- Junction geometry
-------------------------------------------------------------------------------------------------------------------------

export type ApproachGeo = {
	edge: number,
	atA: boolean, -- the edge starts at this node
	h: Vector3, -- unit XZ heading away from the node
	r: Vector3, -- right of h
	a: number, -- half width (curb to curb / 2)
	s: number, -- sidewalk
	T: number, -- asphalt trim (distance from the node where the approach's own slab starts)
	sideTrim: { [number]: number }, -- [+1] / [-1] (sides of h): where its sidewalks start
	index: number, -- index in Intersection.approaches
}

export type Corner = { quad: { Vector3 }?, tri: { Vector3 }? }

export type JunctionGeo = {
	id: number,
	node: number,
	center: Vector3,
	control: string,
	apps: { ApproachGeo },
	core: { Vector3 }, -- convex polygon (XZ, Y = node height)
	corners: { Corner },
}

-- Per edge end: asphalt trim + sidewalk trims (edge sides: +1 = right of a -> b).
export type EdgeTrim = { a: number, b: number, swA: { [number]: number }, swB: { [number]: number } }

local function convexHull(pts: { Vector3 }): { Vector3 }
	local list = table.clone(pts)
	table.sort(list, function(p: Vector3, q: Vector3): boolean
		if p.X ~= q.X then
			return p.X < q.X
		end
		return p.Z < q.Z
	end)
	local function cross(o: Vector3, a: Vector3, b: Vector3): number
		return (a.X - o.X) * (b.Z - o.Z) - (a.Z - o.Z) * (b.X - o.X)
	end
	local lower: { Vector3 } = {}
	for _, p in list do
		while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 1e-6 do
			table.remove(lower)
		end
		table.insert(lower, p)
	end
	local upper: { Vector3 } = {}
	for i = #list, 1, -1 do
		local p = list[i]
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 1e-6 do
			table.remove(upper)
		end
		table.insert(upper, p)
	end
	table.remove(lower)
	table.remove(upper)
	for _, p in upper do
		table.insert(lower, p)
	end
	return lower
end

local GROUND_CONTROLS: { [string]: boolean } = { signal = true, stop = true, allway = true, yield = true, none = true }

-- Is this junction drawn as a street junction (ground, with surface roads)?
local function isStreetJunction(it: WorldLayout.Intersection): boolean
	if not GROUND_CONTROLS[it.control] then
		return false
	end
	local surface = 0
	for _, a in it.approaches do
		if Roads.SURFACE_CLASSES[Edges[a.edge].class] then
			surface += 1
		end
	end
	return surface >= 2
end

function Roads.junctions(): ({ [number]: JunctionGeo }, { [number]: EdgeTrim })
	local geos: { [number]: JunctionGeo } = {}
	local trims: { [number]: EdgeTrim } = {}
	for ei in Edges do
		trims[ei] = { a = 0, b = 0, swA = { [1] = 0, [-1] = 0 }, swB = { [1] = 0, [-1] = 0 } }
	end
	for _, it in WorldLayout.Intersections do
		if not isStreetJunction(it) then
			continue
		end
		local c = it.pos
		local cf = flat(c)
		local apps: { ApproachGeo } = {}
		for idx, ap in it.approaches do
			local e = Edges[ap.edge]
			if not Roads.SURFACE_CLASSES[e.class] and e.class ~= "ramp" then
				continue
			end
			local h = Vector3.new(ap.heading.X, 0, ap.heading.Z).Unit
			table.insert(apps, {
				edge = ap.edge,
				atA = e.a == it.node,
				h = h,
				r = rightOf(h),
				a = e.width / 2,
				s = if Roads.SURFACE_CLASSES[e.class] then e.sidewalk else 0,
				T = 0,
				sideTrim = { [1] = 0, [-1] = 0 },
				index = idx,
			})
		end
		if #apps < 2 then
			continue
		end
		table.sort(apps, function(p: ApproachGeo, q: ApproachGeo): boolean
			return math.atan2(p.h.Z, p.h.X) < math.atan2(q.h.Z, q.h.X)
		end)
		local corners: { Corner } = {}
		local n = #apps
		local cap = it.radius + 30
		for i = 1, n do
			local A = apps[i]
			local B = apps[i % n + 1]
			if A == B then
				continue
			end
			local angA = math.atan2(A.h.Z, A.h.X)
			local angB = math.atan2(B.h.Z, B.h.X)
			local theta = (angB - angA) % (2 * math.pi)
			-- side of A facing B, side of B facing A
			local sA = if A.r:Dot(B.h) >= 0 then 1 else -1
			local sB = if B.r:Dot(A.h) >= 0 then 1 else -1
			if math.abs(theta - math.pi) < 0.2 or theta > math.pi then
				-- straight (or reflex) side: no corner; the curbs run on through the node
				continue
			end
			local pA = cf + A.r * (sA * A.a)
			local pB = cf + B.r * (sB * B.a)
			local C = lineHit(pA, A.h, pB, B.h)
			if not C then
				continue
			end
			local tA = math.clamp((C - cf):Dot(A.h), 0, cap)
			local tB = math.clamp((C - cf):Dot(B.h), 0, cap)
			A.T = math.max(A.T, tA)
			B.T = math.max(B.T, tB)
			A.sideTrim[sA] = math.max(A.sideTrim[sA], tA)
			B.sideTrim[sB] = math.max(B.sideTrim[sB], tB)
			if A.s > 0 and B.s > 0 then
				local Cy = Vector3.new(C.X, c.Y, C.Z)
				local Ai = cf + A.h * tA + A.r * (sA * (A.a + A.s))
				local Bi = cf + B.h * tB + B.r * (sB * (B.a + B.s))
				local O = lineHit(cf + A.r * (sA * (A.a + A.s)), A.h, cf + B.r * (sB * (B.a + B.s)), B.h)
				local corner: Corner = {}
				if O and theta > math.rad(55) and (flat(O) - flat(C)).Magnitude < (A.s + B.s) * 2.2 then
					corner.quad = {
						Cy,
						Vector3.new(Ai.X, c.Y, Ai.Z),
						Vector3.new(O.X, c.Y, O.Z),
						Vector3.new(Bi.X, c.Y, Bi.Z),
					}
				else
					corner.tri = { Cy, Vector3.new(Ai.X, c.Y, Ai.Z), Vector3.new(Bi.X, c.Y, Bi.Z) }
				end
				table.insert(corners, corner)
			end
		end
		-- every approach is trimmed at least to the widest crossing half width it meets (T junction stems etc.)
		local corePts: { Vector3 } = {}
		for _, A in apps do
			local e = Edges[A.edge]
			A.T = math.min(A.T, e.length * 0.45)
			for _, sgn in { 1, -1 } do
				local p = cf + A.h * A.T + A.r * (sgn * A.a)
				table.insert(corePts, Vector3.new(p.X, c.Y, p.Z))
			end
		end
		local core = convexHull(corePts)
		geos[it.id] = {
			id = it.id,
			node = it.node,
			center = c,
			control = it.control,
			apps = apps,
			core = core,
			corners = corners,
		}
		for _, A in apps do
			local tr = trims[A.edge]
			if A.atA then
				tr.a = A.T
				tr.swA[1] = A.sideTrim[1]
				tr.swA[-1] = A.sideTrim[-1]
			else
				-- at the b end the approach heading runs against the edge: approach side +1 = edge side -1
				tr.b = A.T
				tr.swB[-1] = A.sideTrim[1]
				tr.swB[1] = A.sideTrim[-1]
			end
		end
	end
	return geos, trims
end

-------------------------------------------------------------------------------------------------------------------------
-- Surfaces
-------------------------------------------------------------------------------------------------------------------------

local function styleOf(e: Edge): Kit.Style
	if e.class == "alley" or e.class == "service" then
		return Kit.style("asphalt_worn")
	elseif e.class == "dirt" then
		return Kit.style("grass_dry")
	elseif e.class == "runway" then
		return Kit.style("concrete_dark")
	elseif e.class == "highway" or e.class == "rural" then
		return Kit.style("asphalt_dark")
	end
	return Kit.style("asphalt")
end

-- One straight slab from a to b (top at the line), width w, thickness t; extA / extB extend it past a / b.
local function slab(
	ctx: Ctx,
	cat: string,
	a: Vector3,
	b: Vector3,
	w: number,
	t: number,
	extA: number,
	extB: number,
	style: Kit.Style,
	opts: Kit.PartOpts?
): Part?
	local d = b - a
	local len = d.Magnitude
	if len < 0.05 then
		return nil
	end
	local u = d / len
	local a2 = a - u * extA
	local b2 = b + u * extB
	local mid = (a2 + b2) / 2
	local L = len + extA + extB
	local cf = CFrame.lookAt(mid, b2)
	cf = cf * CFrame.new(0, -t / 2, 0)
	return Kit.part(ctx, cat, Vector3.new(w, t, L), cf, style, opts)
end

-- Turn angle (radians, XZ) at joint k of a run, with the sign of the turn (+ = turning right).
local function turnAt(pts: { Vector3 }, k: number): (number, number)
	if k <= 1 or k >= #pts then
		return 0, 0
	end
	local d1 = flat(pts[k] - pts[k - 1])
	local d2 = flat(pts[k + 1] - pts[k])
	if d1.Magnitude < 1e-6 or d2.Magnitude < 1e-6 then
		return 0, 0
	end
	d1, d2 = d1.Unit, d2.Unit
	local cosA = math.clamp(d1:Dot(d2), -1, 1)
	local ang = math.acos(cosA)
	local sideSign = if rightOf(d1):Dot(d2) >= 0 then 1 else -1
	return ang, sideSign
end

-- Extension of a strip whose outer edge sits `outer` studs from the centerline, on side `side` (+1 right / -1 left),
-- at a joint turning by ang toward turnSide: the outside of the turn opens a gap of outer * tan(ang / 2).
local function jointExt(ang: number, turnSide: number, side: number, outer: number): number
	if ang < 1e-3 then
		return 0
	end
	local t = math.tan(math.min(ang, math.rad(80)) / 2)
	if side == 0 then
		return math.min(outer * t, 30)
	end
	-- turning right opens the left side
	if turnSide == side then
		return 0.2
	end
	return math.min(outer * t, 30)
end

-- Builds a run of strips along pts with lateral offset `off` (studs, + = right), width w, top at line + raise.
local function strip(
	ctx: Ctx,
	cat: string,
	pts: { Vector3 },
	off: number,
	w: number,
	raise: number,
	t: number,
	style: Kit.Style,
	opts: Kit.PartOpts?,
	onPart: ((Part, number, number) -> ())?
)
	local side = if off > 0.01 then 1 elseif off < -0.01 then -1 else 0
	local outer = math.abs(off) + w / 2
	local sAcc = 0
	for k = 1, #pts - 1 do
		local a, b = pts[k], pts[k + 1]
		local d = flat(b - a)
		local len = d.Magnitude
		if len < 0.05 then
			continue
		end
		local r = rightOf(d / len)
		local angA, sideA = turnAt(pts, k)
		local angB, sideB = turnAt(pts, k + 1)
		local extA = if k == 1 then 0 else jointExt(angA, sideA, side, outer)
		local extB = if k + 1 == #pts then 0 else jointExt(angB, sideB, side, outer)
		local lift = Vector3.new(0, raise + (k % 2) * 0.006, 0)
		local p = slab(ctx, cat, a + r * off + lift, b + r * off + lift, w, t, extA, extB, style, opts)
		if p and onPart then
			onPart(p, sAcc, sAcc + len + extB)
		end
		sAcc += len
	end
end

Roads.strip = strip
Roads.slab = slab
Roads.styleOf = styleOf
Roads.SLAB = SLAB

-- Edge sides that get sidewalks (+1 right / -1 left of a -> b).
local SIDES = { 1, -1 }

local function buildEdge(ctx: Ctx, ei: number, trim: EdgeTrim)
	local e = Edges[ei]
	local L = cumOf(ei)[#e.points]
	local s0, s1 = trim.a, L - trim.b
	if s1 - s0 < 0.5 then
		return
	end
	local style = styleOf(e)
	local image = Markings.imageFor(e)
	local roadOpts: Kit.PartOpts = { tag = "Road" }
	-- runs split at bridge spans (spans get a girder and parapets)
	local cuts: { { number } } = {}
	local cursor = s0
	-- the Harbor lift span is World/Bridges' bascule leaves: no slab there
	local lift = WorldLayout.LiftBridge
	local spans: { { number } } = e.spans
	if lift and lift.edge == ei and lift.span then
		spans = {}
		for _, sp in e.spans do
			table.insert(spans, sp)
		end
		table.insert(spans, { lift.span[1], lift.span[2], 2 })
		table.sort(spans, function(p: { number }, q: { number }): boolean
			return p[1] < q[1]
		end)
	end
	for _, sp in spans do
		local a, b = math.max(sp[1], s0, cursor), math.min(sp[2], s1)
		if b > a + 0.5 then
			if a > cursor + 0.5 then
				table.insert(cuts, { cursor, a, 0 })
			end
			table.insert(cuts, { a, b, sp[3] or 1 })
			cursor = b
		end
	end
	if s1 > cursor + 0.5 then
		table.insert(cuts, { cursor, s1, 0 })
	end
	for _, run in cuts do
		if run[3] == 2 then
			continue
		end
		local pts = runPoints(ei, run[1], run[2])
		local isBridge = run[3] == 1
		local runStart = run[1]
		strip(ctx, "Road", pts, 0, e.width, 0, SLAB, style, roadOpts, function(p: Part, sa: number, sb: number)
			if image then
				local sEnd = runStart + sb
				Kit.texture(p, image, Enum.NormalId.Top, e.width, Markings.PERIOD, 0, -sEnd % Markings.PERIOD)
			end
			local _ = sa
		end)
		-- raised median (two-way roads with a real median): planted when wide
		if not e.oneWay and e.median >= 6 and e.class ~= "highway" then
			local mStyle = if e.median >= 10 then Kit.style("grass") else Kit.style("curb")
			strip(ctx, "Median", pts, 0, e.median - 1.2, CURB, SLAB + CURB, mStyle)
		elseif e.class == "highway" and e.median >= 6 then
			strip(ctx, "Median", pts, 0, e.median - 2, 0.4, SLAB + 0.4, Kit.style("grass_dry"))
		end
		if isBridge then
			-- girder under the deck (and the curb-side parapets below)
			strip(ctx, "BridgeGirder", pts, 0, e.width * 0.7, -SLAB, 5, Kit.style("concrete"))
		end
	end
	-- sidewalks, each side with its own trims
	if e.sidewalk > 0 and Roads.SURFACE_CLASSES[e.class] then
		for _, side in SIDES do
			local a = math.max(trim.swA[side], 0)
			local b = L - math.max(trim.swB[side], 0)
			if b - a < 0.5 then
				continue
			end
			local pts = runPoints(ei, a, b)
			local off = side * (e.width / 2 + e.sidewalk / 2)
			strip(ctx, "Sidewalk", pts, off, e.sidewalk, CURB, SLAB + CURB, Kit.style("sidewalk"))
			-- parapets on the bridge spans
			for _, sp in e.spans do
				local pa, pb = math.max(sp[1], a), math.min(sp[2], b)
				if pb > pa + 1 then
					local bp = runPoints(ei, pa, pb)
					local roff = side * (e.width / 2 + e.sidewalk + 0.5)
					strip(ctx, "Parapet", bp, roff, 1, CURB + 3.2, 3.2 + CURB, Kit.style("concrete"))
				end
			end
		end
	elseif #e.spans > 0 then
		for _, sp in e.spans do
			local pts = runPoints(ei, sp[1], sp[2])
			for _, side in SIDES do
				strip(ctx, "Parapet", pts, side * (e.width / 2 + 0.6), 1.2, 3.2, 3.2, Kit.style("concrete"))
			end
		end
	end
	Kit.tick(ctx)
end

-- The smallest rectangle (aligned with one of the polygon's sides) around a convex polygon, when the polygon fills
-- at least 94 % of it: one slab instead of a triangle fan. Corners it overshoots sit under the sidewalk corners.
local function fitRect(poly: { Vector3 }): { cframe: CFrame, size: Vector3 }?
	local n = #poly
	if n < 3 then
		return nil
	end
	local area = 0
	for i = 1, n do
		local p, q = poly[i], poly[i % n + 1]
		area += p.X * q.Z - q.X * p.Z
	end
	area = math.abs(area) / 2
	local best: { number }? = nil
	for i = 1, n do
		local d = flat(poly[i % n + 1] - poly[i])
		if d.Magnitude < 1 then
			continue
		end
		local u = d.Unit
		local v = rightOf(u)
		local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge
		for _, p in poly do
			local a, b = p.X * u.X + p.Z * u.Z, p.X * v.X + p.Z * v.Z
			u0, u1 = math.min(u0, a), math.max(u1, a)
			v0, v1 = math.min(v0, b), math.max(v1, b)
		end
		local ra = (u1 - u0) * (v1 - v0)
		if best == nil or ra < best[1] then
			best = { ra, u.X, u.Z, u0, u1, v0, v1 }
		end
	end
	if best == nil or area / best[1] < 0.94 then
		return nil
	end
	local b = best :: { number }
	local u = Vector3.new(b[2], 0, b[3])
	local v = rightOf(u)
	local cu, cv = (b[4] + b[5]) / 2, (b[6] + b[7]) / 2
	local c = u * cu + v * cv
	local y = poly[1].Y
	local center = Vector3.new(c.X, y - SLAB / 2, c.Z)
	return {
		cframe = CFrame.fromMatrix(center, u, Vector3.yAxis),
		size = Vector3.new(b[5] - b[4], SLAB, b[7] - b[6]),
	}
end

local function buildJunction(ctx: Ctx, g: JunctionGeo)
	local c = g.center
	local core = g.core
	local y = c.Y + 0.02
	local style = Kit.style("asphalt")
	local opts: Kit.PartOpts = { tag = "Road" }
	-- core polygon: a rectangle is one slab, anything else a fan of triangles from the centroid
	local lifted: { Vector3 } = {}
	for _, p in core do
		table.insert(lifted, Vector3.new(p.X, y, p.Z))
	end
	local rect = fitRect(lifted)
	if rect then
		Kit.part(ctx, "Junction", rect.size, rect.cframe, style, opts)
	elseif #lifted >= 3 then
		-- fan from the first vertex: n - 2 triangles (2 wedges each)
		for i = 2, #lifted - 1 do
			Kit.triangle(ctx, "Junction", lifted[1], lifted[i], lifted[i + 1], SLAB, style, opts)
		end
	end
	-- sidewalk corners
	local sw = Kit.style("sidewalk")
	for _, corner in g.corners do
		local q = corner.quad
		local tri = corner.tri
		if q then
			local up = Vector3.new(0, CURB + 0.004, 0)
			Kit.quad(ctx, "SidewalkCorner", q[1] + up, q[2] + up, q[3] + up, q[4] + up, SLAB + CURB, sw)
		elseif tri then
			local up = Vector3.new(0, CURB + 0.004, 0)
			Kit.triangle(ctx, "SidewalkCorner", tri[1] + up, tri[2] + up, tri[3] + up, SLAB + CURB, sw)
		end
	end
	-- crosswalks + stop bars at signals and all-way stops
	if g.control == "signal" or g.control == "allway" then
		local it = WorldLayout.Intersections[g.id]
		local cw = Look.Decals.crosswalk_bars_white
		for _, A in g.apps do
			local e = Edges[A.edge]
			if e.sidewalk <= 0 or not Roads.SURFACE_CLASSES[e.class] then
				continue
			end
			local L = cumOf(A.edge)[#e.points]
			local function at(t: number): Vector3
				local s = if A.atA then t else L - t
				return pointAt(A.edge, math.clamp(s, 0, L))
			end
			local tc = A.T + CROSSWALK_GAP + CROSSWALK_DEPTH / 2
			if tc + CROSSWALK_DEPTH > L * 0.5 then
				continue
			end
			local pc = at(tc)
			local cf = CFrame.lookAt(pc + Vector3.new(0, 0.04, 0), pc + Vector3.new(0, 0.04, 0) + A.h)
			local stripe = Kit.part(
				ctx,
				"Crosswalk",
				Vector3.new(e.width - 1, 0.05, CROSSWALK_DEPTH),
				cf,
				Kit.style("asphalt"),
				{ collide = false, query = false, shadow = false, transparency = 1 }
			)
			Kit.texture(
				stripe,
				cw.image,
				Enum.NormalId.Top,
				cw.studsPerTileU or 4.3,
				cw.studsPerTileV or CROSSWALK_DEPTH,
				0,
				0
			)
			-- stop bar across the inbound half (inbound traffic runs toward the node: its lanes lie on -r of h)
			local inbound = it.approaches[A.index].inbound
			if inbound then
				local tb = tc + CROSSWALK_DEPTH / 2 + 2 + STOP_BAR_DEPTH / 2
				local pb = at(tb)
				local x0, x1
				if e.oneWay then
					x0, x1 = -e.width / 2 + 0.5, e.width / 2 - 0.5
				else
					x0, x1 = -e.width / 2 + 0.5, -e.median / 2 - 0.3
				end
				local mid = pb + A.r * ((x0 + x1) / 2) + Vector3.new(0, 0.045, 0)
				Kit.part(
					ctx,
					"StopBar",
					Vector3.new(math.max(x1 - x0, 1), 0.05, STOP_BAR_DEPTH),
					CFrame.lookAt(mid, mid + A.h),
					Kit.style("paint_white"),
					{ collide = false, query = false, shadow = false }
				)
			end
		end
	end
	Kit.tick(ctx)
end

function Roads.build(
	ctx: Ctx,
	geos: { [number]: JunctionGeo },
	trims: { [number]: EdgeTrim },
	filter: ((number) -> boolean)?
)
	for ei, e in Edges do
		if Roads.SURFACE_CLASSES[e.class] and (filter == nil or filter(ei)) then
			buildEdge(ctx, ei, trims[ei])
		end
	end
	for id, g in geos do
		if filter == nil or filter(-id) then
			buildJunction(ctx, g)
		end
	end
	local _ = Nodes
end

return Roads
