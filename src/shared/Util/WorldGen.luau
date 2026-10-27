--!strict
-- WorldGen: pure geometry + road-graph algorithms behind Config/WorldLayout (generation) and Util/WorldQuery (runtime).
--
-- Everything works on plain Luau numbers (doubles) and small tables, never on Vector3 / CFrame, so the Lune tests,
-- the exporter and the Roblox server all produce bit-identical layouts. Randomness is a 32-bit integer hash (no
-- Random, whose sequence differs between Roblox and the Lune harness). No Instances, no services.
--
--   hash / rng            deterministic noise
--   polylines             length, point-at-distance, offset, fillet, bezier, resample
--   polygons              point-in-polygon, signed distance, line clipping, area
--   boxes                 oriented rectangle overlap (SAT)
--   planarize             ways (polylines with heights) -> nodes + edges, split where they cross / touch
--   prune / merge         remove short dead-end stubs, merge chains of degree-2 nodes
--   scc / route           strong connectivity (Kosaraju) and A* on the directed road graph
--   EdgeIndex             spatial hash for nearest-point-on-road queries

local WorldGen = {}

export type P2 = { x: number, z: number }
export type P3 = { x: number, y: number, z: number }

-------------------------------------------------------------------------------------------------------------------------
-- Hash / RNG
-------------------------------------------------------------------------------------------------------------------------

local function imul(a: number, b: number): number
	local ah, al = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	local bh, bl = bit32.rshift(b, 16), bit32.band(b, 0xFFFF)
	local mid = bit32.band(ah * bl + al * bh, 0xFFFF)
	return bit32.band(al * bl + bit32.lshift(mid, 16), 0xFFFFFFFF)
end

local function u32(v: number): number
	return math.floor(v) % 4294967296
end

local function mix(h: number, v: number): number
	h = bit32.bxor(h, v)
	h = imul(h, 0x9E3779B1)
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = imul(h, 0x85EBCA77)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = imul(h, 0xC2B2AE3D)
	return bit32.bxor(h, bit32.rshift(h, 16))
end

-- Deterministic hash of up to three integers -> [0, 1).
function WorldGen.hash(a: number, b: number?, c: number?): number
	local h = 0x811C9DC5
	h = mix(h, u32(a))
	h = mix(h, u32(b or 0))
	h = mix(h, u32(c or 0))
	return h / 4294967296
end

-- String -> integer seed.
function WorldGen.seedOf(s: string): number
	local h = 0x811C9DC5
	for i = 1, #s do
		h = mix(h, string.byte(s, i))
	end
	return h
end

export type Rng = {
	state: number,
	next: (self: Rng) -> number,
	range: (self: Rng, a: number, b: number) -> number,
	int: (self: Rng, a: number, b: number) -> number,
	chance: (self: Rng, p: number) -> boolean,
}

local RngMT = {}
RngMT.__index = RngMT
function RngMT.next(self: Rng): number
	self.state = (self.state + 0x6D2B79F5) % 4294967296
	return mix(self.state, 0x27D4EB2F) / 4294967296
end
function RngMT.range(self: Rng, a: number, b: number): number
	return a + (b - a) * self:next()
end
function RngMT.int(self: Rng, a: number, b: number): number
	return math.min(b, a + math.floor(self:next() * (b - a + 1)))
end
function RngMT.chance(self: Rng, p: number): boolean
	return self:next() < p
end

function WorldGen.rng(seed: number): Rng
	return (setmetatable({ state = u32(seed) }, RngMT) :: any) :: Rng
end

-- Smooth 2D value noise in [-1, 1] (bilinear over hashed lattice with smoothstep weights).
function WorldGen.noise2(x: number, z: number, scale: number, seed: number): number
	local fx, fz = x / scale, z / scale
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	tx = tx * tx * (3 - 2 * tx)
	tz = tz * tz * (3 - 2 * tz)
	local a = WorldGen.hash(ix, iz, seed)
	local b = WorldGen.hash(ix + 1, iz, seed)
	local c = WorldGen.hash(ix, iz + 1, seed)
	local d = WorldGen.hash(ix + 1, iz + 1, seed)
	local v = (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * tz
	return v * 2 - 1
end

function WorldGen.smoothstep(e0: number, e1: number, x: number): number
	if e0 == e1 then
		return if x < e0 then 0 else 1
	end
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

function WorldGen.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-------------------------------------------------------------------------------------------------------------------------
-- Points / segments
-------------------------------------------------------------------------------------------------------------------------

function WorldGen.dist(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	return math.sqrt(dx * dx + dz * dz)
end

-- Closest point on segment a-b to p: (t, x, z, distance).
function WorldGen.projectSeg(
	px: number,
	pz: number,
	ax: number,
	az: number,
	bx: number,
	bz: number
): (number, number, number, number)
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = if len2 > 1e-12 then math.clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1) else 0
	local x, z = ax + dx * t, az + dz * t
	return t, x, z, WorldGen.dist(px, pz, x, z)
end

-- Proper/touching intersection of segments p1-p2 and q1-q2: (t, u) params or nil. tol = slack in studs.
function WorldGen.segIntersect(
	p1x: number,
	p1z: number,
	p2x: number,
	p2z: number,
	q1x: number,
	q1z: number,
	q2x: number,
	q2z: number,
	tol: number
): (number?, number?)
	local rx, rz = p2x - p1x, p2z - p1z
	local sx, sz = q2x - q1x, q2z - q1z
	local denom = rx * sz - rz * sx
	local lr = math.sqrt(rx * rx + rz * rz)
	local ls = math.sqrt(sx * sx + sz * sz)
	if lr < 1e-9 or ls < 1e-9 then
		return nil, nil
	end
	if math.abs(denom) < 1e-9 * lr * ls then
		return nil, nil -- parallel (collinear overlaps are an authoring error, handled by endpoint snapping only)
	end
	local qpx, qpz = q1x - p1x, q1z - p1z
	local t = (qpx * sz - qpz * sx) / denom
	local u = (qpx * rz - qpz * rx) / denom
	local tt, tu = tol / lr, tol / ls
	if t >= -tt and t <= 1 + tt and u >= -tu and u <= 1 + tu then
		return math.clamp(t, 0, 1), math.clamp(u, 0, 1)
	end
	return nil, nil
end

-- Right-hand perpendicular of a heading in Roblox axes (LookVector x UpVector): (x, z) -> (-z, x).
function WorldGen.right(dx: number, dz: number): (number, number)
	return -dz, dx
end

-------------------------------------------------------------------------------------------------------------------------
-- Polylines ({P2} or {P3}; only x / z are read unless stated)
-------------------------------------------------------------------------------------------------------------------------

function WorldGen.polyLength(pts: { any }): number
	local total = 0
	for i = 2, #pts do
		total += WorldGen.dist(pts[i - 1].x, pts[i - 1].z, pts[i].x, pts[i].z)
	end
	return total
end

-- Point at arc length s: (x, z, unit tangent x, unit tangent z, segment index, t on segment). Clamped to the ends.
function WorldGen.polyAt(pts: { any }, s: number): (number, number, number, number, number, number)
	local n = #pts
	if n == 1 then
		return pts[1].x, pts[1].z, 1, 0, 1, 0
	end
	local acc = 0
	for i = 1, n - 1 do
		local a, b = pts[i], pts[i + 1]
		local len = WorldGen.dist(a.x, a.z, b.x, b.z)
		if len > 1e-9 and (s <= acc + len or i == n - 1) then
			local t = math.clamp((s - acc) / len, 0, 1)
			return a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t, (b.x - a.x) / len, (b.z - a.z) / len, i, t
		end
		acc += len
	end
	local a, b = pts[n - 1], pts[n]
	local len = math.max(WorldGen.dist(a.x, a.z, b.x, b.z), 1e-9)
	return b.x, b.z, (b.x - a.x) / len, (b.z - a.z) / len, n - 1, 1
end

-- Height (y) at arc length s of a {P3} polyline (linear between vertices).
function WorldGen.polyYAt(pts: { P3 }, s: number): number
	local _, _, _, _, i, t = WorldGen.polyAt(pts, s)
	local a, b = pts[i], pts[i + 1] or pts[i]
	return a.y + (b.y - a.y) * t
end

-- Closest point on a polyline: (distance, arc length s, x, z, segment index).
function WorldGen.polyProject(pts: { any }, px: number, pz: number): (number, number, number, number, number)
	local best, bestS, bx, bz, bi = math.huge, 0, pts[1].x, pts[1].z, 1
	local acc = 0
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local len = WorldGen.dist(a.x, a.z, b.x, b.z)
		local t, x, z, d = WorldGen.projectSeg(px, pz, a.x, a.z, b.x, b.z)
		if d < best then
			best, bestS, bx, bz, bi = d, acc + t * len, x, z, i
		end
		acc += len
	end
	return best, bestS, bx, bz, bi
end

-- Sub-polyline between arc lengths s0 < s1.
function WorldGen.polySlice(pts: { P2 }, s0: number, s1: number): { P2 }
	local out: { P2 } = {}
	local x0, z0 = WorldGen.polyAt(pts, s0)
	table.insert(out, { x = x0, z = z0 })
	local acc = 0
	for i = 1, #pts - 1 do
		local len = WorldGen.dist(pts[i].x, pts[i].z, pts[i + 1].x, pts[i + 1].z)
		acc += len
		if acc > s0 + 1e-6 and acc < s1 - 1e-6 then
			table.insert(out, { x = pts[i + 1].x, z = pts[i + 1].z })
		end
	end
	local x1, z1 = WorldGen.polyAt(pts, s1)
	table.insert(out, { x = x1, z = z1 })
	return out
end

-- Offset a polyline to its right (d > 0) or left (d < 0) with mitred joins (miter capped at 3x).
function WorldGen.polyOffset(pts: { P2 }, d: number): { P2 }
	local n = #pts
	local out: { P2 } = table.create(n)
	for i = 1, n do
		local px, pz = pts[i].x, pts[i].z
		local ax, az, bx, bz = 0, 0, 0, 0
		if i > 1 then
			local l = math.max(WorldGen.dist(pts[i - 1].x, pts[i - 1].z, px, pz), 1e-9)
			ax, az = (px - pts[i - 1].x) / l, (pz - pts[i - 1].z) / l
		end
		if i < n then
			local l = math.max(WorldGen.dist(px, pz, pts[i + 1].x, pts[i + 1].z), 1e-9)
			bx, bz = (pts[i + 1].x - px) / l, (pts[i + 1].z - pz) / l
		end
		if i == 1 then
			ax, az = bx, bz
		elseif i == n then
			bx, bz = ax, az
		end
		local tx, tz = ax + bx, az + bz
		local tl = math.sqrt(tx * tx + tz * tz)
		if tl < 1e-9 then
			tx, tz, tl = bx, bz, 1
		end
		tx, tz = tx / tl, tz / tl
		local rx, rz = WorldGen.right(tx, tz)
		local cosHalf = rx * (-bz) + rz * bx -- dot(miter normal, segment normal)
		local m = d / math.max(math.abs(cosHalf), 1 / 3) * (if cosHalf < 0 then -1 else 1)
		table.insert(out, { x = px + rx * m, z = pz + rz * m })
	end
	return out
end

-- Arc points around (cx, cz) radius r from angle a0 to a1 (radians, Roblox XZ: angle 0 = +X, pi/2 = +Z).
function WorldGen.arc(cx: number, cz: number, r: number, a0: number, a1: number, step: number?): { P2 }
	local n = math.max(2, math.ceil(math.abs(a1 - a0) * r / (step or 40)))
	local out: { P2 } = table.create(n + 1)
	for i = 0, n do
		local a = a0 + (a1 - a0) * i / n
		table.insert(out, { x = cx + math.cos(a) * r, z = cz + math.sin(a) * r })
	end
	return out
end

-- Cubic Bezier sampled into ~step-stud pieces.
function WorldGen.bezier(p0: P2, p1: P2, p2: P2, p3: P2, step: number?): { P2 }
	local approx = WorldGen.dist(p0.x, p0.z, p1.x, p1.z)
		+ WorldGen.dist(p1.x, p1.z, p2.x, p2.z)
		+ WorldGen.dist(p2.x, p2.z, p3.x, p3.z)
	local n = math.max(2, math.ceil(approx / (step or 30)))
	local out: { P2 } = table.create(n + 1)
	for i = 0, n do
		local t = i / n
		local u = 1 - t
		local a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
		table.insert(out, {
			x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
			z = a * p0.z + b * p1.z + c * p2.z + d * p3.z,
		})
	end
	return out
end

-- Round the corners of a control polygon with circular fillets of radius r (or radii[i] per interior vertex).
-- The result passes through the first and last control points.
function WorldGen.fillet(ctrl: { P2 }, r: number, radii: { number }?, step: number?): { P2 }
	local n = #ctrl
	if n < 3 then
		local out = {}
		for _, p in ctrl do
			table.insert(out, { x = p.x, z = p.z })
		end
		return out
	end
	local out: { P2 } = { { x = ctrl[1].x, z = ctrl[1].z } }
	for i = 2, n - 1 do
		local p, a, b = ctrl[i], ctrl[i - 1], ctrl[i + 1]
		local l1 = WorldGen.dist(a.x, a.z, p.x, p.z)
		local l2 = WorldGen.dist(p.x, p.z, b.x, b.z)
		local d1x, d1z = (p.x - a.x) / l1, (p.z - a.z) / l1
		local d2x, d2z = (b.x - p.x) / l2, (b.z - p.z) / l2
		local cosT = math.clamp(d1x * d2x + d1z * d2z, -1, 1)
		local theta = math.acos(cosT) -- turn angle
		local radius = if radii and radii[i] then radii[i] else r
		if theta < 1e-3 or radius <= 0 then
			table.insert(out, { x = p.x, z = p.z })
			continue
		end
		local tlen = radius * math.tan(theta / 2)
		local maxT = math.min(l1, l2) * 0.49
		if tlen > maxT then
			tlen = maxT
			radius = tlen / math.tan(theta / 2)
		end
		local sx, sz = p.x - d1x * tlen, p.z - d1z * tlen
		local cross = d1x * d2z - d1z * d2x
		local nx, nz = WorldGen.right(d1x, d1z) -- right of travel
		if cross < 0 then
			nx, nz = -nx, -nz
		end
		local cx, cz = sx + nx * radius, sz + nz * radius
		local a0 = math.atan2(sz - cz, sx - cx)
		local ex, ez = p.x + d2x * tlen, p.z + d2z * tlen
		local a1 = math.atan2(ez - cz, ex - cx)
		local da = a1 - a0
		while da > math.pi do
			da -= 2 * math.pi
		end
		while da < -math.pi do
			da += 2 * math.pi
		end
		for _, q in WorldGen.arc(cx, cz, radius, a0, a0 + da, step or 30) do
			table.insert(out, q)
		end
	end
	table.insert(out, { x = ctrl[n].x, z = ctrl[n].z })
	-- drop near-duplicates
	local clean: { P2 } = {}
	for _, q in out do
		local last = clean[#clean]
		if not last or WorldGen.dist(last.x, last.z, q.x, q.z) > 0.5 then
			table.insert(clean, q)
		end
	end
	return clean
end

-- Resample a polyline so no piece is longer than maxLen (keeps every original vertex).
function WorldGen.densify(pts: { P2 }, maxLen: number): { P2 }
	local out: { P2 } = { { x = pts[1].x, z = pts[1].z } }
	for i = 2, #pts do
		local a, b = pts[i - 1], pts[i]
		local len = WorldGen.dist(a.x, a.z, b.x, b.z)
		local n = math.max(1, math.ceil(len / maxLen))
		for k = 1, n do
			local t = k / n
			table.insert(out, { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t })
		end
	end
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- Polygons ({P2}, implicitly closed)
-------------------------------------------------------------------------------------------------------------------------

function WorldGen.pointInPoly(poly: { P2 }, x: number, z: number): boolean
	local inside = false
	local n = #poly
	local j = n
	for i = 1, n do
		local a, b = poly[i], poly[j]
		if (a.z > z) ~= (b.z > z) and x < (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x then
			inside = not inside
		end
		j = i
	end
	return inside
end

-- Distance to the polygon outline: (distance, nearest edge index i = poly[i] -> poly[i % n + 1]).
function WorldGen.polyEdgeDistance(poly: { P2 }, x: number, z: number): (number, number)
	local best, bestI = math.huge, 1
	local n = #poly
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		local _, _, _, d = WorldGen.projectSeg(x, z, a.x, a.z, b.x, b.z)
		if d < best then
			best, bestI = d, i
		end
	end
	return best, bestI
end

-- Signed distance: positive inside.
function WorldGen.polySigned(poly: { P2 }, x: number, z: number): (number, number)
	local d, i = WorldGen.polyEdgeDistance(poly, x, z)
	return if WorldGen.pointInPoly(poly, x, z) then d else -d, i
end

function WorldGen.polyArea(poly: { P2 }): number
	local a = 0
	local n = #poly
	for i = 1, n do
		local p, q = poly[i], poly[i % n + 1]
		a += p.x * q.z - q.x * p.z
	end
	return math.abs(a) / 2
end

function WorldGen.polyCentroid(poly: { P2 }): (number, number)
	local sx, sz = 0, 0
	for _, p in poly do
		sx += p.x
		sz += p.z
	end
	return sx / #poly, sz / #poly
end

function WorldGen.polyBounds(poly: { any }): (number, number, number, number)
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, p in poly do
		minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
		minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
	end
	return minX, minZ, maxX, maxZ
end

-- Parameter intervals {t0, t1} (0..1) of segment a-b that lie inside the polygon.
function WorldGen.clipSegToPoly(ax: number, az: number, bx: number, bz: number, poly: { P2 }): { { number } }
	local ts = { 0, 1 }
	local n = #poly
	for i = 1, n do
		local p, q = poly[i], poly[i % n + 1]
		local t = WorldGen.segIntersect(ax, az, bx, bz, p.x, p.z, q.x, q.z, 0)
		if t then
			table.insert(ts, t)
		end
	end
	table.sort(ts)
	local out: { { number } } = {}
	for i = 1, #ts - 1 do
		local t0, t1 = ts[i], ts[i + 1]
		if t1 - t0 > 1e-6 then
			local tm = (t0 + t1) / 2
			if WorldGen.pointInPoly(poly, ax + (bx - ax) * tm, az + (bz - az) * tm) then
				local last = out[#out]
				if last and math.abs(last[2] - t0) < 1e-9 then
					last[2] = t1
				else
					table.insert(out, { t0, t1 })
				end
			end
		end
	end
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- Oriented rectangles: { cx, cz, ux, uz (unit width axis), hw (half width), hd (half depth) }
-------------------------------------------------------------------------------------------------------------------------

export type OBB = { cx: number, cz: number, ux: number, uz: number, hw: number, hd: number }

function WorldGen.obbCorners(b: OBB): { P2 }
	local vx, vz = -b.uz, b.ux
	return {
		{ x = b.cx - b.ux * b.hw - vx * b.hd, z = b.cz - b.uz * b.hw - vz * b.hd },
		{ x = b.cx + b.ux * b.hw - vx * b.hd, z = b.cz + b.uz * b.hw - vz * b.hd },
		{ x = b.cx + b.ux * b.hw + vx * b.hd, z = b.cz + b.uz * b.hw + vz * b.hd },
		{ x = b.cx - b.ux * b.hw + vx * b.hd, z = b.cz - b.uz * b.hw + vz * b.hd },
	}
end

function WorldGen.obbOverlap(a: OBB, b: OBB, margin: number?): boolean
	local m = margin or 0
	local axes = { { a.ux, a.uz }, { -a.uz, a.ux }, { b.ux, b.uz }, { -b.uz, b.ux } }
	local dx, dz = b.cx - a.cx, b.cz - a.cz
	for _, ax in axes do
		local x, z = ax[1], ax[2]
		local ra = a.hw * math.abs(a.ux * x + a.uz * z) + a.hd * math.abs(-a.uz * x + a.ux * z)
		local rb = b.hw * math.abs(b.ux * x + b.uz * z) + b.hd * math.abs(-b.uz * x + b.ux * z)
		if math.abs(dx * x + dz * z) >= ra + rb + m then
			return false
		end
	end
	return true
end

function WorldGen.obbContains(b: OBB, x: number, z: number, margin: number?): boolean
	local m = margin or 0
	local dx, dz = x - b.cx, z - b.cz
	return math.abs(dx * b.ux + dz * b.uz) <= b.hw + m and math.abs(-dx * b.uz + dz * b.ux) <= b.hd + m
end

-------------------------------------------------------------------------------------------------------------------------
-- Spatial hash (cell -> list of ids)
-------------------------------------------------------------------------------------------------------------------------

local KEY_SPAN = 2 ^ 20
local function cellKey(cx: number, cz: number): number
	return (cx + KEY_SPAN) * (KEY_SPAN * 2) + (cz + KEY_SPAN)
end
WorldGen.cellKey = cellKey

function WorldGen.hashBox(
	cells: { [number]: { number } },
	cell: number,
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	id: number
)
	for cx = math.floor(minX / cell), math.floor(maxX / cell) do
		for cz = math.floor(minZ / cell), math.floor(maxZ / cell) do
			local k = cellKey(cx, cz)
			local list = cells[k]
			if list then
				table.insert(list, id)
			else
				cells[k] = { id }
			end
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Planarize: ways -> nodes + edges
-------------------------------------------------------------------------------------------------------------------------

export type GWay = {
	pts: { P3 },
	layer: number, -- crossings only join ways of the same layer
	noCross: boolean?, -- ramps / flyovers: joined only at their own endpoints, never split by crossings
}

export type GNode = { x: number, y: number, z: number }
export type GEdge = { a: number, b: number, way: number, pts: { P3 }, length: number }

local function polyLen3(pts: { P3 }): number
	local total = 0
	for i = 2, #pts do
		total += WorldGen.dist(pts[i - 1].x, pts[i - 1].z, pts[i].x, pts[i].z)
	end
	return total
end
WorldGen.polyLen3 = polyLen3

-- snap: XZ merge radius; ySnap: max height difference for two ways to join. Splits are recorded as vertex-index
-- params (segment i + t) so the original vertices between splits are kept as the edge's polyline.
function WorldGen.planarize(ways: { GWay }, snap: number, ySnap: number): ({ GNode }, { GEdge })
	local BROAD = 192
	type Seg = { w: number, i: number }
	local segs: { Seg } = {}
	local cells: { [number]: { number } } = {}
	for w, way in ways do
		for i = 1, #way.pts - 1 do
			local a, b = way.pts[i], way.pts[i + 1]
			table.insert(segs, { w = w, i = i })
			WorldGen.hashBox(
				cells,
				BROAD,
				math.min(a.x, b.x) - snap,
				math.min(a.z, b.z) - snap,
				math.max(a.x, b.x) + snap,
				math.max(a.z, b.z) + snap,
				#segs
			)
		end
	end
	local splits: { { number } } = {}
	for w, way in ways do
		splits[w] = { 1, #way.pts } -- params are 1-based vertex positions (vertex k = param k)
	end
	local function yOn(w: number, i: number, t: number): number
		local a, b = ways[w].pts[i], ways[w].pts[i + 1]
		return a.y + (b.y - a.y) * t
	end
	local checked: { [number]: boolean } = {}
	local nseg = #segs
	local keys: { number } = {}
	for k in cells do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		local list = cells[k]
		for x = 1, #list do
			for y = x + 1, #list do
				local s1, s2 = math.min(list[x], list[y]), math.max(list[x], list[y])
				local pair = s1 * (nseg + 1) + s2
				if checked[pair] then
					continue
				end
				checked[pair] = true
				local A, B = segs[s1], segs[s2]
				local wa, wb = ways[A.w], ways[B.w]
				if A.w == B.w and math.abs(A.i - B.i) <= 1 then
					continue
				end
				local a1, a2 = wa.pts[A.i], wa.pts[A.i + 1]
				local b1, b2 = wb.pts[B.i], wb.pts[B.i + 1]
				-- interior crossings: same layer, both crossable, same height
				if wa.layer == wb.layer and not wa.noCross and not wb.noCross then
					local t, u = WorldGen.segIntersect(a1.x, a1.z, a2.x, a2.z, b1.x, b1.z, b2.x, b2.z, snap)
					if t and u and math.abs(yOn(A.w, A.i, t) - yOn(B.w, B.i, u)) <= ySnap then
						table.insert(splits[A.w], A.i + t)
						table.insert(splits[B.w], B.i + u)
					end
				end
				-- way endpoints touching the other segment (any layer): T-junctions, ramp terminals
				local function endpointOn(wE: number, segE: Seg, wS: number, segS: Seg)
					local way = ways[wE]
					local n = #way.pts
					local p1, p2 = ways[wS].pts[segS.i], ways[wS].pts[segS.i + 1]
					for _, vi in { 1, n } do
						if (vi == 1 and segE.i == 1) or (vi == n and segE.i == n - 1) then
							local e = way.pts[vi]
							local t, _, _, d = WorldGen.projectSeg(e.x, e.z, p1.x, p1.z, p2.x, p2.z)
							if d <= snap and math.abs(yOn(wS, segS.i, t) - e.y) <= ySnap then
								table.insert(splits[wS], segS.i + t)
							end
						end
					end
				end
				endpointOn(A.w, A, B.w, B)
				endpointOn(B.w, B, A.w, A)
			end
		end
	end

	-- nodes (deduplicated within snap, same height band)
	local nodes: { GNode } = {}
	local nodeCells: { [number]: { number } } = {}
	local NC = math.max(snap * 2, 1)
	local function nodeAt(x: number, y: number, z: number): number
		local cx, cz = math.floor(x / NC), math.floor(z / NC)
		for dx = -1, 1 do
			for dz = -1, 1 do
				local list = nodeCells[cellKey(cx + dx, cz + dz)]
				if list then
					for _, id in list do
						local n = nodes[id]
						if WorldGen.dist(n.x, n.z, x, z) <= snap and math.abs(n.y - y) <= ySnap then
							return id
						end
					end
				end
			end
		end
		table.insert(nodes, { x = x, y = y, z = z })
		local id = #nodes
		local key = cellKey(cx, cz)
		local list = nodeCells[key]
		if list then
			table.insert(list, id)
		else
			nodeCells[key] = { id }
		end
		return id
	end

	local edges: { GEdge } = {}
	local seen: { [string]: boolean } = {}
	for w, way in ways do
		local ps = splits[w]
		table.sort(ps)
		local pts = way.pts
		local function pointAt(param: number): P3
			local i = math.clamp(math.floor(param), 1, #pts - 1)
			local t = param - i
			local a, b = pts[i], pts[i + 1]
			return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
		end
		local prevNode: number? = nil
		local prevParam = 0
		for _, param in ps do
			if prevNode ~= nil and param - prevParam < 1e-7 then
				continue
			end
			local p = pointAt(param)
			local node = nodeAt(p.x, p.y, p.z)
			if prevNode and node ~= prevNode then
				local poly: { P3 } = { nodes[prevNode] :: any }
				for v = math.floor(prevParam) + 1, math.ceil(param) - 1 do
					if v > prevParam + 1e-7 and v < param - 1e-7 then
						table.insert(poly, { x = pts[v].x, y = pts[v].y, z = pts[v].z })
					end
				end
				table.insert(poly, nodes[node] :: any)
				local key = w .. ":" .. math.min(prevNode, node) .. ":" .. math.max(prevNode, node)
				if not seen[key] then
					seen[key] = true
					local clean: { P3 } = {}
					for _, q in poly do
						table.insert(clean, { x = q.x, y = q.y, z = q.z })
					end
					table.insert(edges, { a = prevNode, b = node, way = w, pts = clean, length = polyLen3(clean) })
				end
			end
			if prevNode == nil or node ~= prevNode then
				prevNode = node
				prevParam = param
			else
				prevParam = param
			end
		end
	end
	return nodes, edges
end

-------------------------------------------------------------------------------------------------------------------------
-- Cleanup
-------------------------------------------------------------------------------------------------------------------------

local function degreeOf(nNodes: number, edges: { GEdge }, alive: { boolean }): { number }
	local deg = table.create(nNodes, 0)
	for i, e in edges do
		if alive[i] then
			deg[e.a] += 1
			deg[e.b] += 1
		end
	end
	return deg
end

-- Remove dead-end edges shorter than minLen (repeatedly), unless keep(edge) says otherwise. Returns kept edges.
function WorldGen.pruneStubs(
	nNodes: number,
	edges: { GEdge },
	minLen: number,
	keep: ((GEdge) -> boolean)?
): { GEdge }
	local alive = table.create(#edges, true)
	local changed = true
	while changed do
		changed = false
		local deg = degreeOf(nNodes, edges, alive)
		for i, e in edges do
			if alive[i] and (deg[e.a] == 1 or deg[e.b] == 1) and e.length < minLen and not (keep and keep(e)) then
				alive[i] = false
				changed = true
				deg[e.a] -= 1
				deg[e.b] -= 1
			end
		end
	end
	local out = {}
	for i, e in edges do
		if alive[i] then
			table.insert(out, e)
		end
	end
	return out
end

-- Merge pairs of edges of the same way that meet at a node with exactly two edges (and is not pinned), so a road
-- reads as one edge between real junctions. Direction is preserved (first.b == n == second.a).
function WorldGen.mergeChains(nNodes: number, edges: { GEdge }, pinned: { [number]: boolean }?): { GEdge }
	local alive = table.create(#edges, true)
	local inc: { { number } } = table.create(nNodes)
	for i = 1, nNodes do
		inc[i] = {}
	end
	for i, e in edges do
		table.insert(inc[e.a], i)
		table.insert(inc[e.b], i)
	end
	for n = 1, nNodes do
		if pinned and pinned[n] then
			continue
		end
		local list = {}
		for _, i in inc[n] do
			if alive[i] and not table.find(list, i) then
				table.insert(list, i)
			end
		end
		if #list ~= 2 then
			continue
		end
		local i1, i2 = list[1], list[2]
		local e1, e2 = edges[i1], edges[i2]
		if e1.way ~= e2.way then
			continue
		end
		local iFirst, iSecond = i1, i2
		if not (e1.b == n and e2.a == n) then
			if e2.b == n and e1.a == n then
				iFirst, iSecond = i2, i1
			else
				continue -- opposing directions meet here (should not happen within one way)
			end
		end
		local first, second = edges[iFirst], edges[iSecond]
		if first.a == second.b then
			continue -- would close a loop onto itself
		end
		local pts: { P3 } = {}
		for _, p in first.pts do
			table.insert(pts, p)
		end
		for k = 2, #second.pts do
			table.insert(pts, second.pts[k])
		end
		edges[iFirst] = { a = first.a, b = second.b, way = first.way, pts = pts, length = first.length + second.length }
		alive[iSecond] = false
		local farList = inc[second.b]
		for k, v in farList do
			if v == iSecond then
				farList[k] = iFirst
			end
		end
	end
	local out = {}
	for i, e in edges do
		if alive[i] then
			table.insert(out, e)
		end
	end
	return out
end

-- Drop nodes no edge uses and renumber. Returns (nodes, edges, oldToNew).
function WorldGen.compact(nodes: { GNode }, edges: { GEdge }): ({ GNode }, { GEdge }, { number })
	local used = table.create(#nodes, false)
	for _, e in edges do
		used[e.a] = true
		used[e.b] = true
	end
	local map = table.create(#nodes, 0)
	local out: { GNode } = {}
	for i, n in nodes do
		if used[i] then
			table.insert(out, n)
			map[i] = #out
		end
	end
	for _, e in edges do
		e.a = map[e.a]
		e.b = map[e.b]
	end
	return out, edges, map
end

-------------------------------------------------------------------------------------------------------------------------
-- Directed graph helpers. arcs: node -> list of { to, edge, cost }
-------------------------------------------------------------------------------------------------------------------------

export type Arc = { to: number, edge: number, cost: number }

function WorldGen.arcs(nNodes: number, edges: { any }, oneWay: (number) -> boolean, usable: ((number) -> boolean)?): { { Arc } }
	local out: { { Arc } } = table.create(nNodes)
	for i = 1, nNodes do
		out[i] = {}
	end
	for i, e in edges do
		if usable == nil or usable(i) then
			table.insert(out[e.a], { to = e.b, edge = i, cost = e.length })
			if not oneWay(i) then
				table.insert(out[e.b], { to = e.a, edge = -i, cost = e.length })
			end
		end
	end
	return out
end

-- Strongly connected components (iterative Kosaraju). Returns (componentOf, count, sizeOfLargest, idOfLargest).
function WorldGen.scc(nNodes: number, arcs: { { Arc } }): ({ number }, number, number, number)
	local order: { number } = {}
	local visited = table.create(nNodes, false)
	for s = 1, nNodes do
		if not visited[s] then
			local stack = { s }
			local iter = { 1 }
			visited[s] = true
			while #stack > 0 do
				local v = stack[#stack]
				local k = iter[#iter]
				local list = arcs[v]
				if k <= #list then
					iter[#iter] = k + 1
					local w = list[k].to
					if not visited[w] then
						visited[w] = true
						table.insert(stack, w)
						table.insert(iter, 1)
					end
				else
					table.insert(order, v)
					table.remove(stack)
					table.remove(iter)
				end
			end
		end
	end
	local rev: { { number } } = table.create(nNodes)
	for i = 1, nNodes do
		rev[i] = {}
	end
	for v = 1, nNodes do
		for _, a in arcs[v] do
			table.insert(rev[a.to], v)
		end
	end
	local comp = table.create(nNodes, 0)
	local count = 0
	local sizes = {}
	for idx = #order, 1, -1 do
		local s = order[idx]
		if comp[s] == 0 then
			count += 1
			sizes[count] = 0
			local stack = { s }
			comp[s] = count
			while #stack > 0 do
				local v = table.remove(stack) :: number
				sizes[count] += 1
				for _, w in rev[v] do
					if comp[w] == 0 then
						comp[w] = count
						table.insert(stack, w)
					end
				end
			end
		end
	end
	local best, bestId = 0, 0
	for id, sz in sizes do
		if sz > best then
			best, bestId = sz, id
		end
	end
	return comp, count, best, bestId
end

-- A* from node s to node t. nodePos(i) -> (x, z). Returns (list of arcs' edge ids (signed), cost) or nil.
function WorldGen.astar(
	nNodes: number,
	arcs: { { Arc } },
	nodePos: (number) -> (number, number),
	s: number,
	t: number
): ({ number }?, number)
	if s == t then
		return {}, 0
	end
	local g: { [number]: number } = { [s] = 0 }
	local parentEdge: { [number]: number } = {}
	local parentNode: { [number]: number } = {}
	local closed: { [number]: boolean } = {}
	local heapN: { number } = {}
	local heapF: { number } = {}
	local tx, tz = nodePos(t)
	local function push(n: number, f: number)
		table.insert(heapN, n)
		table.insert(heapF, f)
		local i = #heapN
		while i > 1 do
			local p = i // 2
			if heapF[p] > heapF[i] or (heapF[p] == heapF[i] and heapN[p] > heapN[i]) then
				heapN[p], heapN[i] = heapN[i], heapN[p]
				heapF[p], heapF[i] = heapF[i], heapF[p]
				i = p
			else
				break
			end
		end
	end
	local function pop(): number
		local top = heapN[1]
		local lastN, lastF = table.remove(heapN) :: number, table.remove(heapF) :: number
		local size = #heapN
		if size > 0 then
			heapN[1], heapF[1] = lastN, lastF
			local i = 1
			while true do
				local l, r = i * 2, i * 2 + 1
				local m = i
				if l <= size and (heapF[l] < heapF[m] or (heapF[l] == heapF[m] and heapN[l] < heapN[m])) then
					m = l
				end
				if r <= size and (heapF[r] < heapF[m] or (heapF[r] == heapF[m] and heapN[r] < heapN[m])) then
					m = r
				end
				if m == i then
					break
				end
				heapN[m], heapN[i] = heapN[i], heapN[m]
				heapF[m], heapF[i] = heapF[i], heapF[m]
				i = m
			end
		end
		return top
	end
	local _ = nNodes -- (kept for API symmetry with scc)
	local sx, sz = nodePos(s)
	push(s, WorldGen.dist(sx, sz, tx, tz))
	while #heapN > 0 do
		local n = pop()
		if closed[n] then
			continue
		end
		closed[n] = true
		if n == t then
			local path: { number } = {}
			local cur = t
			while cur ~= s do
				table.insert(path, 1, parentEdge[cur])
				cur = parentNode[cur]
			end
			return path, g[t]
		end
		for _, arc in arcs[n] do
			local w = arc.to
			if not closed[w] then
				local ng = g[n] + arc.cost
				if g[w] == nil or ng < g[w] then
					g[w] = ng
					parentEdge[w] = arc.edge
					parentNode[w] = n
					local wx, wz = nodePos(w)
					push(w, ng + WorldGen.dist(wx, wz, tx, tz))
				end
			end
		end
	end
	return nil, math.huge
end

-------------------------------------------------------------------------------------------------------------------------
-- Edge spatial index (nearest point on any road centerline)
-------------------------------------------------------------------------------------------------------------------------

export type EdgeIndex = { cell: number, cells: { [number]: { number } }, edges: { { pts: { P3 } } } }

function WorldGen.edgeIndex(edges: { { pts: { P3 } } }, cell: number, pad: (number) -> number): EdgeIndex
	local cells: { [number]: { number } } = {}
	for i, e in edges do
		local minX, minZ, maxX, maxZ = WorldGen.polyBounds(e.pts)
		local p = pad(i)
		WorldGen.hashBox(cells, cell, minX - p, minZ - p, maxX + p, maxZ + p, i)
	end
	return { cell = cell, cells = cells, edges = edges }
end

-- Nearest edge to (x, z) among edges accepted by filter: (edge, s along it, px, pz, distance) or nil.
function WorldGen.nearestEdge(
	index: EdgeIndex,
	x: number,
	z: number,
	maxDist: number,
	filter: ((number) -> boolean)?
): (number?, number, number, number, number)
	local cell = index.cell
	local cx, cz = math.floor(x / cell), math.floor(z / cell)
	local rings = math.ceil(maxDist / cell) + 1
	local best: number? = nil
	local bestS, bestX, bestZ, bestD = 0, x, z, math.huge
	local seen: { [number]: boolean } = {}
	local function visit(key: number)
		local list = index.cells[key]
		if not list then
			return
		end
		for _, e in list do
			if not seen[e] then
				seen[e] = true
				if filter == nil or filter(e) then
					local d, s, px, pz = WorldGen.polyProject(index.edges[e].pts, x, z)
					if d < bestD - 1e-9 or (math.abs(d - bestD) <= 1e-9 and best ~= nil and e < best) then
						best, bestS, bestX, bestZ, bestD = e, s, px, pz, d
					end
				end
			end
		end
	end
	for r = 0, rings do
		if bestD <= (r - 1) * cell then
			break
		end
		if r == 0 then
			visit(cellKey(cx, cz))
		else
			for i = -r, r do
				visit(cellKey(cx + i, cz - r))
				visit(cellKey(cx + i, cz + r))
			end
			for i = -r + 1, r - 1 do
				visit(cellKey(cx - r, cz + i))
				visit(cellKey(cx + r, cz + i))
			end
		end
	end
	if best == nil or bestD > maxDist then
		return nil, 0, x, z, math.huge
	end
	return best, bestS, bestX, bestZ, bestD
end

return WorldGen
