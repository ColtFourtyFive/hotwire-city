--!strict
--!native
-- World/Terrain: the island's Terrain written at runtime from Util/WorldTerrain, in 64 x 64-stud chunks.
--
--   natural ground   WorldTerrain.heightAt sampled on a 32-stud lattice (memoized), bilinear between lattice points;
--                    the carved strips (Rust River channel, the H1 trench cut) use the exact heightAt per column,
--                    deep sea (> 1150 off the coast) is the -58 shelf without sampling
--   road grading     every ground road corridor (curb to curb + sidewalks + 2) is graded to 0.9 under the road top,
--                    blending back to natural ground on a 2:1 batter (cut or fill); bridge spans and decks are not
--   sink             all other ground sits SINK under the baked grade, so lots, floors and sidewalks at grade never
--                    z-fight with the terrain surface
--   water            the ocean (outside the coast, and the channel mouth south of its flood gate) up to sea level,
--                    the reservoir up to its level; the H1 trench and the dry channel stay dry
--   materials        district + height + slope: sand at the shore, grass / leafy grass / rock in the hills,
--                    sand / sandstone / ground in the desert, concrete in the channel and the cut, ground in the city
--
-- Terrain.chunk(cx, cz) is pure (column heights, materials, water) so tools/blender/preview renders the same ground;
-- Terrain.write(terrain, chunk) does the voxel work: one FillBlock under the surface band, one WriteVoxels for the band
-- (FillBlock-only for deep sea). Terrain.build(terrain, order?, yield?) writes every chunk, spawn-first when an origin
-- is given. Measured cost: see Terrain.stats (columns, exact samples, lattice samples, seconds).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldTerrain = require(Shared.Util.WorldTerrain)
local WorldGen = require(Shared.Util.WorldGen)

local Terrain = {}

Terrain.CHUNK = 64
Terrain.RES = 4
Terrain.LATTICE = 32
Terrain.BOTTOM = -72
Terrain.SINK = 0.4
Terrain.ROAD_SINK = 0.9
Terrain.SEABED = -58
-- Roblox draws (and collides with) the terrain surface half a voxel above the occupancy we write, for FillBlock and
-- WriteVoxels alike: a fill to 11.6 at RES 4 surfaces at 13.594 (engine probe 2026-10-28, matching job 0018's buried
-- roads). Terrain.write subtracts this so the surface lands on the heights Terrain.chunk computes.
Terrain.ENGINE_LIFT = Terrain.RES / 2

local N = Terrain.CHUNK // Terrain.RES -- columns per chunk side (16)
local LAT = Terrain.LATTICE
local SEA = WorldLayout.SEA_LEVEL
local Edges = WorldLayout.Edges
local Channel = WorldTerrain.Channel

Terrain.stats = { chunks = 0, uniform = 0, columns = 0, exact = 0, lattice = 0, seconds = 0, writes = 0, fills = 0 }

-------------------------------------------------------------------------------------------------------------------------
-- natural ground
-------------------------------------------------------------------------------------------------------------------------

local latticeMemo: { [number]: number } = {}

local function latticeAt(ix: number, iz: number): number
	local key = WorldGen.cellKey(ix, iz)
	local v = latticeMemo[key]
	if v ~= nil then
		return v
	end
	local x, z = ix * LAT, iz * LAT
	local h: number
	if not WorldTerrain.landAtLeast(x, z, -1150) then
		h = Terrain.SEABED
	else
		h = WorldTerrain.heightAt(x, z)
		Terrain.stats.lattice += 1
	end
	latticeMemo[key] = h
	return h
end

local function bilinear(x: number, z: number): number
	local fx, fz = x / LAT, z / LAT
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	local a = latticeAt(ix, iz)
	local b = latticeAt(ix + 1, iz)
	local c = latticeAt(ix, iz + 1)
	local d = latticeAt(ix + 1, iz + 1)
	return (a * (1 - tx) + b * tx) * (1 - tz) + (c * (1 - tx) + d * tx) * tz
end

-- carved strips: the channel and the cut corridors (exact heightAt inside)
type Strip = { pts: { WorldGen.P2 }, half: number, x0: number, z0: number, x1: number, z1: number, concrete: boolean }
local strips: { Strip }? = nil
local function carveStrips(): { Strip }
	local s = strips
	if s then
		return s
	end
	local list: { Strip } = {}
	local function add(pts: { WorldGen.P2 }, half: number, concrete: boolean)
		local x0, z0, x1, z1 = WorldGen.polyBounds(pts)
		table.insert(list, {
			pts = pts,
			half = half,
			x0 = x0 - half,
			z0 = z0 - half,
			x1 = x1 + half,
			z1 = z1 + half,
			concrete = concrete,
		})
	end
	add(Channel.points, Channel.floorHalfWidthSouth + Channel.wallRun + 10, true)
	local _, cuts = WorldTerrain.getEdits()
	for _, c in cuts do
		add(c.points, c.half + 14, true)
	end
	strips = list
	return list
end

-------------------------------------------------------------------------------------------------------------------------
-- road grading index (ground roads, bridge spans excluded)
-------------------------------------------------------------------------------------------------------------------------

type Seg = {
	ax: number,
	az: number,
	ay: number,
	bx: number,
	bz: number,
	by: number,
	core: number,
	x0: number,
	z0: number,
	x1: number,
	z1: number,
}
local gradeIdx: { [number]: { Seg } }? = nil
local GCELL = 64

local function inSpan(e: WorldLayout.Edge, s: number): boolean
	for _, sp in e.spans do
		if s >= sp[1] - 4 and s <= sp[2] + 4 then
			return true
		end
	end
	return false
end

local function gradeIndex(): { [number]: { Seg } }
	local g = gradeIdx
	if g then
		return g
	end
	local cells: { [number]: { Seg } } = {}
	for _, e in Edges do
		if e.elevated or e.layer < 0 or e.class == "pier" then
			continue
		end
		local core = e.width / 2 + e.sidewalk + 2
		local pts = e.points
		local acc = 0
		for k = 1, #pts - 1 do
			local a, b = pts[k], pts[k + 1]
			local len = math.sqrt((b.X - a.X) ^ 2 + (b.Z - a.Z) ^ 2)
			local mid = acc + len / 2
			acc += len
			if inSpan(e, mid) then
				continue
			end
			local reach = core + 60
			local seg: Seg = {
				ax = a.X,
				az = a.Z,
				ay = a.Y,
				bx = b.X,
				bz = b.Z,
				by = b.Y,
				core = core,
				x0 = math.min(a.X, b.X) - reach,
				z0 = math.min(a.Z, b.Z) - reach,
				x1 = math.max(a.X, b.X) + reach,
				z1 = math.max(a.Z, b.Z) + reach,
			}
			local pad = core + 40
			local cx0 = math.floor((math.min(a.X, b.X) - pad) / GCELL)
			local cx1 = math.floor((math.max(a.X, b.X) + pad) / GCELL)
			local cz0 = math.floor((math.min(a.Z, b.Z) - pad) / GCELL)
			local cz1 = math.floor((math.max(a.Z, b.Z) + pad) / GCELL)
			for cx = cx0, cx1 do
				for cz = cz0, cz1 do
					local key = WorldGen.cellKey(cx, cz)
					local list = cells[key]
					if not list then
						list = {}
						cells[key] = list
					end
					table.insert(list, seg)
				end
			end
		end
	end
	gradeIdx = cells
	return cells
end

-------------------------------------------------------------------------------------------------------------------------
-- materials
-------------------------------------------------------------------------------------------------------------------------

local M = Enum.Material
local URBAN: { [string]: boolean } =
	{ downtown = true, midtown = true, foundry = true, rust = true, port = true, airport = true, cactus = true }

-- n: low-frequency noise in [-1, 1] per column, so slope / height boundaries break into patches instead of running
-- as contour stripes along a hillside
local function materialFor(
	district: string,
	h: number,
	slope: number,
	carve: boolean,
	road: boolean,
	n: number
): Enum.Material
	slope += n * 0.3
	if carve then
		return M.Concrete
	end
	if h < 2.5 then
		return M.Sand
	end
	if road then
		return M.Ground
	end
	if district == "mesa" or district == "cactus" then
		if slope > 0.6 then
			return M.Sandstone
		elseif h > 60 then
			return M.Ground
		end
		return M.Sand
	end
	if slope > 1.0 then
		return if h + n * 20 > 380 then M.Slate else M.Rock
	end
	if district == "hills" or h > 40 then
		if h + n * 40 > 520 then
			return M.Rock
		elseif slope > 0.55 then
			return M.LeafyGrass
		end
		return M.Grass
	end
	if district == "beach" or district == "driftwood" then
		return if h < 14.5 then M.Sand else M.Grass
	end
	if URBAN[district] then
		-- leftover ground between lots: paved in the core and the container port, verge grass on the airfield, dirt
		-- with grass patches elsewhere (a basin of bare tan dirt read as desert in the previews)
		if district == "downtown" or district == "port" then
			-- Asphalt, not Concrete: Concrete, Pavement, Rock, Basalt, Slate and Cobblestone mesh with displaced, blocky
			-- surfaces that snap up to a voxel boundary at low occupancy (engine probe 2026-10-28: a column written to
			-- 11.6 surfaces at 12.0, flush with the road tops, so the asphalt z-fought). Asphalt, Ground, Grass, Sand,
			-- Mud and Limestone land on the written height to within 0.01.
			return M.Asphalt
		elseif district == "airport" then
			return if n > -0.35 then M.Grass else M.Ground
		elseif district == "midtown" then
			return if n > 0.05 then M.Grass else M.Ground
		end
		return if n > 0.4 then M.Grass else M.Ground
	end
	return M.Grass
end

-------------------------------------------------------------------------------------------------------------------------
-- chunks
-------------------------------------------------------------------------------------------------------------------------

export type Chunk = {
	cx: number,
	cz: number,
	x0: number,
	z0: number,
	h: { number }, -- N * N surface heights (row-major: i = ix * N + iz + 1)
	mat: { Enum.Material },
	water: { number }, -- water surface per column (-math.huge = none)
	minH: number,
	maxH: number,
	waterTop: number,
	deepSea: boolean, -- uniform chunk (open sea or flat ground): FillBlocks only
}

local reservoir = WorldTerrain.Water[1]
local resBox: { number }? = if reservoir then { WorldGen.polyBounds(reservoir.points) } else nil

-- Pure: the surface of chunk (cx, cz) (world x0 = cx * CHUNK).
function Terrain.chunk(cx: number, cz: number): Chunk
	local t0 = os.clock()
	local C = Terrain.CHUNK
	local x0, z0 = cx * C, cz * C
	local h = table.create(N * N, 0)
	local mat = table.create(N * N, M.Ground)
	local water = table.create(N * N, -math.huge)
	Terrain.stats.chunks += 1
	-- lattice corners of the chunk
	local lo, hi, sum, cnt = math.huge, -math.huge, 0, 0
	for ix = math.floor(x0 / LAT), math.floor((x0 + C) / LAT) + 1 do
		for iz = math.floor(z0 / LAT), math.floor((z0 + C) / LAT) + 1 do
			local v = latticeAt(ix, iz)
			lo, hi = math.min(lo, v), math.max(hi, v)
			sum += v
			cnt += 1
		end
	end
	-- strips touching this chunk
	local touching: { Strip } = {}
	for _, s in carveStrips() do
		if s.x1 >= x0 and s.x0 <= x0 + C and s.z1 >= z0 and s.z0 <= z0 + C then
			table.insert(touching, s)
		end
	end
	-- road segments near this chunk
	local segs: { Seg } = {}
	do
		local seen: { [Seg]: boolean } = {}
		local gi = gradeIndex()
		for gx = math.floor(x0 / GCELL), math.floor((x0 + C - 1) / GCELL) do
			for gz = math.floor(z0 / GCELL), math.floor((z0 + C - 1) / GCELL) do
				for _, sg in gi[WorldGen.cellKey(gx, gz)] or {} do
					if not seen[sg] then
						seen[sg] = true
						table.insert(segs, sg)
					end
				end
			end
		end
	end
	local midX, midZ = x0 + C / 2, z0 + C / 2
	-- fast paths: open sea (every corner under -4, nothing carved, no roads) and flat ground (corners within 0.3,
	-- every road at that height): one uniform column, written with FillBlocks
	local uniform: number? = nil
	local uniformMat = M.Sand
	local uniformWater = -math.huge
	if #touching == 0 and #segs == 0 and hi < -4 then
		uniform = sum / cnt
		uniformWater = SEA
	elseif #touching == 0 and hi - lo < 0.3 and lo > 1.5 then
		local flatY = sum / cnt
		local ok = true
		for _, sg in segs do
			if math.abs(sg.ay - flatY) > 1.5 or math.abs(sg.by - flatY) > 1.5 then
				ok = false
				break
			end
		end
		if ok and resBox ~= nil then
			local rb = resBox :: { number }
			if rb[1] <= x0 + C and rb[3] >= x0 and rb[2] <= z0 + C and rb[4] >= z0 then
				ok = false
			end
		end
		if ok then
			uniform = flatY - Terrain.SINK
			uniformMat = materialFor(WorldLayout.districtAt(midX, midZ), flatY, 0, false, false, 0)
		end
	end
	if uniform ~= nil then
		local u = uniform :: number
		for i = 1, N * N do
			h[i] = u
			mat[i] = uniformMat
			water[i] = uniformWater
		end
		Terrain.stats.uniform += 1
		Terrain.stats.seconds += os.clock() - t0
		return {
			cx = cx,
			cz = cz,
			x0 = x0,
			z0 = z0,
			h = h,
			mat = mat,
			water = water,
			minH = u,
			maxH = u,
			waterTop = uniformWater,
			deepSea = true,
		}
	end
	local district = WorldLayout.districtAt(midX, midZ)
	local resHit = resBox ~= nil
		and (resBox :: { number })[1] <= x0 + C
		and (resBox :: { number })[3] >= x0
		and (resBox :: { number })[2] <= z0 + C
		and (resBox :: { number })[4] >= z0
	local carveFlag = table.create(N * N, false)
	local roadFlag = table.create(N * N, false)
	local minH, maxH, wTop = math.huge, -math.huge, -math.huge
	for ix = 0, N - 1 do
		local x = x0 + (ix + 0.5) * Terrain.RES
		for iz = 0, N - 1 do
			local z = z0 + (iz + 0.5) * Terrain.RES
			local i = ix * N + iz + 1
			local hv: number
			local carve = false
			for _, s in touching do
				if x >= s.x0 and x <= s.x1 and z >= s.z0 and z <= s.z1 then
					local d = WorldGen.polyProject(s.pts, x, z)
					if d <= s.half then
						carve = true
						break
					end
				end
			end
			if carve then
				hv = WorldTerrain.heightAt(x, z)
				Terrain.stats.exact += 1
				-- only the carved floor / walls read as concrete; the strip's margin is natural ground
				carve = hv < WorldTerrain.gradeAt(x, z) - 1.5
			else
				hv = bilinear(x, z)
			end
			hv -= Terrain.SINK
			-- road grading: the strongest corridor wins
			local bestW, bestY = 0, 0
			for _, sg in segs do
				if x < sg.x0 or x > sg.x1 or z < sg.z0 or z > sg.z1 then
					continue
				end
				local t, _, _, d = WorldGen.projectSeg(x, z, sg.ax, sg.az, sg.bx, sg.bz)
				if d < sg.core + 60 then
					local y = sg.ay + (sg.by - sg.ay) * t - Terrain.ROAD_SINK
					local w: number
					if d <= sg.core then
						w = 1
					else
						local reach = math.max(4, math.abs(hv - y) * 2)
						w = 1 - (d - sg.core) / reach
					end
					if w > bestW then
						bestW, bestY = w, y
					end
				end
			end
			if bestW > 0 then
				-- under the road: never above the road bed; beside it: blend
				if bestW >= 1 then
					hv = bestY
					roadFlag[i] = true
				else
					hv = hv + (bestY - hv) * bestW
				end
			end
			h[i] = hv
			carveFlag[i] = carve
			minH = math.min(minH, hv)
			maxH = math.max(maxH, hv)
			-- water
			local wl = -math.huge
			if hv < SEA then
				local sea = not WorldTerrain.landAtLeast(x, z, 0)
				if not sea and z > Channel.gateZ and carve then
					sea = true -- the channel mouth below the flood gate
				end
				if sea then
					wl = SEA
				end
			end
			if resHit then
				local wet, level = WorldTerrain.inWater(x, z)
				if wet and hv < level then
					wl = level
				end
			end
			water[i] = wl
			if wl > wTop then
				wTop = wl
			end
		end
	end
	-- materials (slope from the neighbouring columns)
	for ix = 0, N - 1 do
		for iz = 0, N - 1 do
			local i = ix * N + iz + 1
			local ax, bx = math.max(ix - 1, 0), math.min(ix + 1, N - 1)
			local az, bz = math.max(iz - 1, 0), math.min(iz + 1, N - 1)
			local sx = math.abs(h[bx * N + iz + 1] - h[ax * N + iz + 1]) / ((bx - ax) * Terrain.RES)
			local sz = math.abs(h[ix * N + bz + 1] - h[ix * N + az + 1]) / ((bz - az) * Terrain.RES)
			local wx, wz = x0 + ix * Terrain.RES, z0 + iz * Terrain.RES
			local n = math.clamp(math.noise(wx / 37.3, wz / 37.3, 0.37) * 2, -1, 1)
			mat[i] = materialFor(district, h[i], math.max(sx, sz), carveFlag[i], roadFlag[i], n)
		end
	end
	Terrain.stats.columns += N * N
	Terrain.stats.seconds += os.clock() - t0
	return {
		cx = cx,
		cz = cz,
		x0 = x0,
		z0 = z0,
		h = h,
		mat = mat,
		water = water,
		minH = minH,
		maxH = maxH,
		waterTop = wTop,
		deepSea = false,
	}
end

-- Surface height of the built terrain at (x, z) (the chunk's column), for the previews and tests.
function Terrain.surfaceAt(ch: Chunk, x: number, z: number): number
	local ix = math.clamp(math.floor((x - ch.x0) / Terrain.RES), 0, N - 1)
	local iz = math.clamp(math.floor((z - ch.z0) / Terrain.RES), 0, N - 1)
	return ch.h[ix * N + iz + 1]
end

-------------------------------------------------------------------------------------------------------------------------
-- voxels
-------------------------------------------------------------------------------------------------------------------------

function Terrain.write(terrain: Terrain, ch: Chunk)
	local C = Terrain.CHUNK
	local R = Terrain.RES
	local LIFT = Terrain.ENGINE_LIFT
	local cxw, czw = ch.x0 + C / 2, ch.z0 + C / 2
	if ch.deepSea then
		local hTop = ch.h[1] - LIFT
		local waterTop = ch.waterTop - LIFT
		terrain:FillBlock(
			CFrame.new(cxw, (Terrain.BOTTOM + hTop) / 2, czw),
			Vector3.new(C, hTop - Terrain.BOTTOM, C),
			ch.mat[1]
		)
		Terrain.stats.fills += 1
		if waterTop > hTop then
			terrain:FillBlock(CFrame.new(cxw, (hTop + waterTop) / 2, czw), Vector3.new(C, waterTop - hTop, C), M.Water)
			Terrain.stats.fills += 1
		end
		return
	end
	local yLow = math.max(Terrain.BOTTOM, math.floor((ch.minH - LIFT - R) / R) * R)
	local top = math.max(ch.maxH, ch.waterTop) - LIFT
	local yHigh = math.ceil(top / R) * R + R
	if yLow > Terrain.BOTTOM then
		terrain:FillBlock(
			CFrame.new(cxw, (Terrain.BOTTOM + yLow) / 2, czw),
			Vector3.new(C, yLow - Terrain.BOTTOM, C),
			M.Rock
		)
		Terrain.stats.fills += 1
	end
	local ny = math.max(1, (yHigh - yLow) // R)
	local mats = table.create(N)
	local occs = table.create(N)
	for ix = 1, N do
		local mx = table.create(ny)
		local ox = table.create(ny)
		for iy = 1, ny do
			mx[iy] = table.create(N, M.Air)
			ox[iy] = table.create(N, 0)
		end
		mats[ix] = mx
		occs[ix] = ox
	end
	for ix = 0, N - 1 do
		for iz = 0, N - 1 do
			local i = ix * N + iz + 1
			local hv = ch.h[i] - LIFT
			local wl = ch.water[i] - LIFT
			local m = ch.mat[i]
			for iy = 0, ny - 1 do
				local vy = yLow + iy * R
				local occ = (hv - vy) / R
				if occ >= 1 then
					mats[ix + 1][iy + 1][iz + 1] = m
					occs[ix + 1][iy + 1][iz + 1] = 1
				elseif occ > 0.02 then
					mats[ix + 1][iy + 1][iz + 1] = m
					occs[ix + 1][iy + 1][iz + 1] = occ
				elseif vy < wl then
					mats[ix + 1][iy + 1][iz + 1] = M.Water
					occs[ix + 1][iy + 1][iz + 1] = math.clamp((wl - vy) / R, 0, 1)
				end
			end
		end
	end
	local region = Region3.new(Vector3.new(ch.x0, yLow, ch.z0), Vector3.new(ch.x0 + C, yLow + ny * R, ch.z0 + C))
	terrain:WriteVoxels(region, R, mats, occs)
	Terrain.stats.writes += 1
end

-- Chunk coordinates covering the bounds, nearest `origin` first (spawn area before the outskirts).
function Terrain.chunkOrder(origin: Vector3?): { { number } }
	local B = WorldLayout.Bounds
	local C = Terrain.CHUNK
	local list: { { number } } = {}
	for cx = math.floor(B.min.X / C), math.floor(B.max.X / C) - 1 do
		for cz = math.floor(B.min.Z / C), math.floor(B.max.Z / C) - 1 do
			local d = 0
			if origin then
				d = (cx * C + C / 2 - origin.X) ^ 2 + (cz * C + C / 2 - origin.Z) ^ 2
			end
			table.insert(list, { cx, cz, d })
		end
	end
	table.sort(list, function(a: { number }, b: { number }): boolean
		if a[3] ~= b[3] then
			return a[3] < b[3]
		end
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2] < b[2]
	end)
	return list
end

-- Writes every chunk (yield() between chunks when given). Returns the chunk count.
function Terrain.build(terrain: Terrain, origin: Vector3?, yieldFn: (() -> ())?, budget: number?): number
	local order = Terrain.chunkOrder(origin)
	local sliceStart = os.clock()
	local n = 0
	for _, c in order do
		local ch = Terrain.chunk(c[1], c[2])
		Terrain.write(terrain, ch)
		n += 1
		if yieldFn and os.clock() - sliceStart > (budget or 0.012) then
			yieldFn()
			sliceStart = os.clock()
		end
	end
	return n
end

return Terrain
