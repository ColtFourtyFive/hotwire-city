--!strict
-- WorldTerrain: the island's ground as a pure function. Shared by the world generator (tools/world/gen) and the
-- runtime (Util/WorldQuery), so terrain queries on the server and clients agree with the baked road heights.
--
-- Authored here: coastline (segment kinds), islands, inland water, the Rust River channel, and the landforms
-- (Sunwood Hills + summit ridge, Sunwood Canyon, Mount Talon, the Red Mesa buttes and cuesta, foothills, dunes,
-- the north-east cape knoll, flattened town pads). Baked by the generator and installed with setEdits(): level pads
-- under garages / POIs / museum on slopes and cut corridors (the H1 trench). No Instances, no services, no Random.
--
--   gradeAt(x, z)    smooth ground: what roads and lots sit on (pads included, channel / trench / reservoir not carved)
--   heightAt(x, z)   terrain surface (channel, trench and reservoir carved in)
--   shore(x, z)      signed distance to the nearest landmass (positive on land) + coast kind
--   landAtLeast(x, z, m), inWater(x, z)
--
-- Axes: +X east, -Z north (map up), +Y up. Sea level 0, city grade 12.

local WorldGen = require(script.Parent.WorldGen)

type P2 = WorldGen.P2

local WorldTerrain = {}

WorldTerrain.SEA_LEVEL = 0
WorldTerrain.GRADE = 12
local GRADE = 12
local SMOOTH = WorldGen.smoothstep

export type CoastKind = "beach" | "cliff" | "rock" | "quay"
export type CoastPoint = { x: number, z: number, kind: CoastKind } -- kind of the segment that starts here

local function coast(list: { { any } }): { CoastPoint }
	local out: { CoastPoint } = {}
	for _, p in list do
		table.insert(out, { x = p[1], z = p[2], kind = p[3] })
	end
	return out
end

-- Mainland, clockwise on the map, starting at the Palmera north headland.
WorldTerrain.Coast = coast({
	{ -5500, -2050, "cliff" }, -- Palmera north headland (the crescent bay's north horn)
	{ -5230, -2560, "cliff" },
	{ -4760, -3050, "cliff" },
	{ -4360, -3620, "cliff" },
	{ -3760, -4010, "rock" },
	{ -3150, -4180, "beach" }, -- Hidden Cove
	{ -2650, -4200, "cliff" },
	{ -1600, -4300, "cliff" },
	{ -450, -4340, "rock" },
	{ 650, -4430, "rock" },
	{ 1500, -4720, "rock" }, -- Northpoint cape (lighthouse)
	{ 2150, -4700, "beach" }, -- Sandpiper Bay
	{ 3100, -4520, "rock" },
	{ 4100, -4560, "cliff" },
	{ 4750, -4470, "cliff" },
	{ 5180, -4330, "cliff" }, -- north-east cape (Coast Highway tunnel)
	{ 5470, -3900, "rock" },
	{ 5750, -3400, "rock" },
	{ 6050, -2200, "beach" }, -- Driftwood Beach
	{ 5980, -800, "rock" },
	{ 6060, 400, "cliff" },
	{ 5900, 1700, "rock" },
	{ 5550, 2900, "rock" },
	{ 4850, 3650, "rock" },
	{ 3950, 3850, "quay" },
	{ 3350, 3380, "quay" }, -- Iron Bay channel, north bank
	{ 2600, 3060, "quay" },
	{ 1200, 3020, "quay" },
	{ -200, 3060, "quay" },
	{ -1500, 3040, "quay" },
	{ -2250, 3260, "quay" }, -- airport sea wall
	{ -2750, 4060, "quay" },
	{ -3050, 4330, "quay" }, -- reclaimed airfield sea wall (second runway)
	{ -4400, 4450, "quay" },
	{ -5650, 4430, "quay" },
	{ -5960, 4150, "rock" },
	{ -5960, 3350, "rock" },
	{ -5600, 2720, "quay" }, -- marina south mole
	{ -4780, 2650, "quay" },
	{ -4730, 1840, "quay" }, -- marina east quay
	{ -5200, 1790, "quay" }, -- marina north quay
	{ -5470, 1720, "beach" }, -- south breakwater root: the crescent bay begins
	{ -5330, 1100, "beach" },
	{ -5190, 400, "beach" },
	{ -5100, -300, "beach" },
	{ -5120, -900, "beach" },
	{ -5230, -1450, "beach" },
	{ -5390, -1800, "rock" },
})

-- Iron Bay port island (container terminal), all quay walls.
WorldTerrain.Islands = {
	{
		name = "Iron Bay",
		points = coast({
			{ -1750, 3430, "quay" },
			{ 2750, 3420, "quay" },
			{ 3050, 3820, "quay" },
			{ 2780, 4470, "quay" },
			{ -1200, 4560, "quay" },
			{ -1920, 4060, "quay" },
		}),
	},
}

-- Inland water (level = water surface Y).
WorldTerrain.Water = {
	{
		name = "Mesa Reservoir",
		level = 74,
		points = {
			{ x = 2550, z = -2950 },
			{ x = 3050, z = -3150 },
			{ x = 3450, z = -2950 },
			{ x = 3400, z = -2600 },
			{ x = 2950, z = -2470 },
			{ x = 2600, z = -2600 },
		} :: { P2 },
	},
}

-- Rust River: a concrete storm channel (drivable floor) from the foothills to Iron Bay, bending like the LA River.
-- Floor Y falls north -> south. South of Z 1000 the floor widens (low-flow trough down the middle).
do
	local ctrl: { P2 } = {
		{ x = 2180, z = -2700 },
		{ x = 2070, z = -2300 },
		{ x = 1990, z = -1900 },
		{ x = 1880, z = -1300 },
		{ x = 1855, z = -900 },
		{ x = 1905, z = -300 },
		{ x = 2050, z = 400 },
		{ x = 2150, z = 1100 },
		{ x = 2155, z = 1700 },
		{ x = 2070, z = 2400 },
		{ x = 1960, z = 3060 },
	}
	WorldTerrain.Channel = {
		name = "Rust River",
		points = WorldGen.fillet(ctrl, 700, nil, 40),
		floorHalfWidth = 44, -- north reach
		floorHalfWidthSouth = 76, -- south of widenZ (180-200 wide at the top)
		widenZ = 1000,
		widenBlend = 300,
		troughHalfWidth = 7, -- low-flow trough cut 1.5 studs into the floor
		troughDepth = 1.5,
		wallRun = 18, -- horizontal run of the sloped concrete wall
		floorNorthY = -6, -- 18 deep under the city grade; dry: a flood gate closes the mouth
		floorSouthY = -9,
		gateZ = 2860, -- flood gate across the channel mouth (water beyond)
		startOpenAt = -1950, -- north of this Z the channel is a natural creek bed in the foothills
	}
end
local Channel = WorldTerrain.Channel
local channelLength = WorldGen.polyLength(Channel.points)

-- Floor half width of the channel at a given Z (widens toward the bay).
function WorldTerrain.channelFloorHalf(z: number): number
	local t = SMOOTH(Channel.widenZ - Channel.widenBlend, Channel.widenZ + Channel.widenBlend, z)
	return Channel.floorHalfWidth + (Channel.floorHalfWidthSouth - Channel.floorHalfWidth) * t
end

-- Channel floor height at arc length s along Channel.points.
function WorldTerrain.channelFloorY(s: number): number
	return Channel.floorNorthY + (Channel.floorSouthY - Channel.floorNorthY) * (s / channelLength)
end
WorldTerrain.channelLength = channelLength

-- Polylines the terrain is shaped around (also used by the road network).
WorldTerrain.CANYON_AXIS = { -- H9 Sunwood Canyon
	{ x = -2600, z = -1800 },
	{ x = -2600, z = -2330 },
	{ x = -2720, z = -2800 },
	{ x = -2900, z = -3250 },
	{ x = -2960, z = -3700 },
} :: { P2 }
local CANYON_AXIS = WorldTerrain.CANYON_AXIS
local canyonLength = WorldGen.polyLength(CANYON_AXIS)

local coastPoly: { P2 } = WorldTerrain.Coast :: any
local islandPoly: { P2 } = WorldTerrain.Islands[1].points :: any

-------------------------------------------------------------------------------------------------------------------------
-- Landforms
-------------------------------------------------------------------------------------------------------------------------

-- Sunwood Hills front-range crest height along X (piecewise linear).
local HILL_CREST = {
	{ -5200, 30 },
	{ -4600, 70 },
	{ -4000, 120 },
	{ -3200, 150 },
	{ -2200, 230 },
	{ -1300, 250 },
	{ -300, 215 },
	{ 700, 170 },
	{ 1500, 130 },
	{ 2300, 120 },
}
local function crestAt(x: number): number
	if x <= HILL_CREST[1][1] then
		return HILL_CREST[1][2]
	end
	for i = 2, #HILL_CREST do
		local a, b = HILL_CREST[i - 1], HILL_CREST[i]
		if x <= b[1] then
			return a[2] + (b[2] - a[2]) * (x - a[1]) / (b[1] - a[1])
		end
	end
	return HILL_CREST[#HILL_CREST][2]
end

-- Sunwood summit ridge: the backdrop behind the front range (+300 at Z ~ -3600, X -2300..700). It is zero south of
-- Z -3290 (Skyline Drive and the Observatory keep their grades) and north of Z -3930 (the Coast Highway shelf).
WorldTerrain.RIDGE = { x0 = -2300, x1 = 700, taper = 420, height = 300, south = -3290, north = -3930 }
local RIDGE = WorldTerrain.RIDGE
local function ridgeCrestZ(x: number): number
	return -3610 + 45 * math.sin(x / 650 + 0.4)
end
local function ridgeAt(x: number, z: number): number
	if z > RIDGE.south or z < RIDGE.north or x < RIDGE.x0 - RIDGE.taper or x > RIDGE.x1 + RIDGE.taper then
		return 0
	end
	local wx = SMOOTH(RIDGE.x0 - RIDGE.taper, RIDGE.x0, x) * SMOOTH(RIDGE.x1 + RIDGE.taper, RIDGE.x1, x)
	local zc = ridgeCrestZ(x)
	local t = if z > zc then SMOOTH(RIDGE.south, zc, z) else SMOOTH(RIDGE.north, zc, z)
	local rough = 1 + 0.1 * WorldGen.noise2(x, z, 320, 51) + 0.05 * WorldGen.noise2(x, z, 110, 52)
	return RIDGE.height * wx * t * rough
end

-- Mount Talon: the island's peak (a Chiliad-style backdrop), north-east of the reservoir. Concave flanks with ridged
-- spurs; the builder paints rock above Y 400. Its foot reaches the Mesa Reservoir (south-west) and the cape.
WorldTerrain.PEAK = { name = "Mount Talon", x = 4300, z = -3030, radius = 1300, height = 960 }
local PEAK = WorldTerrain.PEAK
local function peakAt(x: number, z: number): number
	local dx, dz = x - PEAK.x, z - PEAK.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d >= PEAK.radius then
		return 0
	end
	local t = d / PEAK.radius
	local base = (1 - t) ^ 1.55
	local ang = math.atan2(dz, dx)
	-- five ridged spurs + noise
	local spur = math.abs(math.sin(ang * 2.5 + 0.7 + 0.6 * WorldGen.noise2(x, z, 700, 61)))
	local ridged = 1 + 0.16 * (spur - 0.5) * 4 * t * (1 - t)
	local rough = 1 + 0.06 * WorldGen.noise2(x, z, 160, 62)
	return PEAK.height * base * ridged * rough
end

-- Red Mesa buttes: oriented ellipses (NE-SW grain) with a caprock cliff, a ledge and a talus apron.
-- { x, z, semi-major, semi-minor, major-axis bearing (degrees from +X toward -Z, i.e. 45 = NE), height }
WorldTerrain.MESAS = {
	{ 3760, 1960, 360, 110, 45, 90 },
	{ 4620, -1700, 430, 130, 40, 120 },
	{ 5480, 2280, 300, 95, 50, 80 },
	{ 3520, 2560, 260, 85, 35, 70 },
}
local MESAS = WorldTerrain.MESAS
local function mesaAt(x: number, z: number): number
	local best = 0
	for _, m in MESAS do
		local a = math.rad(m[5])
		local ux, uz = math.cos(a), -math.sin(a)
		local dx, dz = x - m[1], z - m[2]
		local u = dx * ux + dz * uz
		local v = -dx * uz + dz * ux
		local q = math.sqrt((u / m[3]) ^ 2 + (v / m[4]) ^ 2)
		local e = (q - 1) * m[4] -- approximate distance outside the rim (minor-axis units)
		if e < 210 then
			local H = m[6] * (1 + 0.04 * WorldGen.noise2(x, z, 70, 41))
			local h
			if e <= 0 then
				h = H
			elseif e < 16 then
				h = H - 0.32 * H * SMOOTH(0, 16, e) -- caprock cliff
			elseif e < 46 then
				h = 0.68 * H - 0.06 * H * (e - 16) / 30 -- ledge (terrace)
			elseif e < 64 then
				h = 0.62 * H - 0.2 * H * SMOOTH(46, 64, e) -- second step
			else
				h = 0.42 * H * (1 - SMOOTH(64, 210, e)) -- talus apron
			end
			best = math.max(best, h)
		end
	end
	return best
end

-- Red Mesa cuesta: a 3.3k-stud escarpment along X ~ 5200 (gentle dip slope from the west, steep face to the east),
-- broken by gaps where Red Mesa Road / the freight line and the Desert Freeway pass.
WorldTerrain.CUESTA = {
	x = 5200,
	z0 = -2300,
	z1 = 1150,
	height = 70,
	dip = 430, -- west slope run
	face = 90, -- east face run
	gaps = { { z = -690, half = 150 }, { z = 120, half = 150 } },
}
local CUESTA = WorldTerrain.CUESTA
local function cuestaAt(x: number, z: number): number
	if z < CUESTA.z0 or z > CUESTA.z1 then
		return 0
	end
	local xc = CUESTA.x + 40 * math.sin(z / 500)
	local h
	if x <= xc then
		h = SMOOTH(xc - CUESTA.dip, xc, x)
	else
		h = 1 - SMOOTH(xc, xc + CUESTA.face, x)
	end
	if h <= 0 then
		return 0
	end
	local along = SMOOTH(CUESTA.z0, CUESTA.z0 + 800, z) * SMOOTH(CUESTA.z1, CUESTA.z1 - 650, z)
	for _, g in CUESTA.gaps do
		along *= SMOOTH(g.half, g.half + 140, math.abs(z - g.z))
	end
	return CUESTA.height * h * along * (1 + 0.08 * WorldGen.noise2(x, z, 140, 71))
end

-- North-east cape knoll (the Coast Highway tunnels through it).
WorldTerrain.KNOLL = { x = 5090, z = -4215, radius = 250, height = 92 }
local KNOLL = WorldTerrain.KNOLL
local function knollAt(x: number, z: number): number
	local d = WorldGen.dist(x, z, KNOLL.x, KNOLL.z)
	if d >= KNOLL.radius then
		return 0
	end
	return KNOLL.height * SMOOTH(KNOLL.radius, KNOLL.radius * 0.25, d) * (1 + 0.1 * WorldGen.noise2(x, z, 60, 81))
end

export type Flatten = { name: string, poly: { P2 }, y: number, blend: number }

-- Authored flattened areas: { polygon, target Y, blend distance }.
local FLATTEN: { Flatten } = {
	{
		name = "Cactus Junction",
		poly = { { x = 3900, z = -950 }, { x = 4750, z = -950 }, { x = 4750, z = -150 }, { x = 3900, z = -150 } },
		y = 24,
		blend = 260,
	},
	{
		name = "Dustbowl Speedway",
		poly = { { x = 3950, z = 2500 }, { x = 4900, z = 2500 }, { x = 4900, z = 3150 }, { x = 3950, z = 3150 } },
		y = 20,
		blend = 220,
	},
	{
		name = "Red Mesa State Prison",
		poly = { { x = 4200, z = 1000 }, { x = 5150, z = 1000 }, { x = 5150, z = 1800 }, { x = 4200, z = 1800 } },
		y = 22,
		blend = 200,
	},
	{
		name = "Starview Observatory summit",
		poly = { { x = -700, z = -3220 }, { x = -320, z = -3220 }, { x = -320, z = -2950 }, { x = -700, z = -2950 } },
		y = 224,
		blend = 140,
	},
}
WorldTerrain.FLATTEN = FLATTEN

-- Generated terrain edits (baked into WorldData, installed at boot / by the generator).
export type Pad = {
	name: string,
	cx: number,
	cz: number,
	ux: number,
	uz: number,
	hw: number,
	hd: number,
	y: number,
	blend: number,
}
export type Cut = { name: string, points: { P2 }, half: number, floorY: { number } }

local pads: { Pad } = {}
local cuts: { Cut } = {}
local padBoxes: { { number } } = {}
local cutBoxes: { { number } } = {}

function WorldTerrain.setEdits(newPads: { Pad }, newCuts: { Cut })
	pads = newPads
	cuts = newCuts
	padBoxes = {}
	for i, p in pads do
		local r = math.sqrt(p.hw * p.hw + p.hd * p.hd) + p.blend
		padBoxes[i] = { p.cx - r, p.cz - r, p.cx + r, p.cz + r }
	end
	cutBoxes = {}
	for i, c in cuts do
		local x0, z0, x1, z1 = WorldGen.polyBounds(c.points)
		cutBoxes[i] = { x0 - c.half, z0 - c.half, x1 + c.half, z1 + c.half }
	end
end

function WorldTerrain.getEdits(): ({ Pad }, { Cut })
	return pads, cuts
end

-- Height of the island before shoreline shaping (hills, desert, canyon, pads).
local function inlandHeight(x: number, z: number): number
	local h = GRADE
	-- Sunwood Hills: rise north of the hill foot (z ~ -2000) to the front-range crest (z ~ -3050), plateau beyond,
	-- with the summit ridge on top
	if x < 2600 and z < -1900 then
		local crest = crestAt(x)
		local foot = -1980 + 70 * math.sin(x / 700)
		local ridge = -3050 + 120 * math.sin(x / 900 + 1.3)
		local up = SMOOTH(foot, ridge, z)
		local down = 1 - 0.45 * SMOOTH(ridge, -4100, z)
		local edge = SMOOTH(2600, 1800, x)
		local base = crest * up * down
		local rough = (WorldGen.noise2(x, z, 420, 11) * 0.65 + WorldGen.noise2(x, z, 170, 12) * 0.35) * 34 * up
		h += (math.max(0, base + rough) + ridgeAt(x, z)) * edge
	end
	-- Red Mesa foothills (north-east)
	if x > 1500 and z < -1950 then
		local w = SMOOTH(1500, 2300, x) * SMOOTH(-1950, -2650, z)
		local f = 70 + 55 * WorldGen.noise2(x, z, 650, 21) + 22 * WorldGen.noise2(x, z, 230, 22)
		h = math.max(h, GRADE + math.max(0, f) * w)
	end
	-- Desert floor east (gentle dunes + rise toward the east coast)
	if x > 3000 then
		local w = SMOOTH(3000, 3700, x)
		local dunes = 8 * WorldGen.noise2(x, z, 260, 31) + 5 * WorldGen.noise2(x, z, 90, 32)
		local rise = 14 * SMOOTH(3400, 5600, x)
		h = math.max(h, GRADE + (math.max(0, dunes) + rise) * w)
	end
	-- Mount Talon
	if math.abs(x - PEAK.x) < PEAK.radius and math.abs(z - PEAK.z) < PEAK.radius then
		h = math.max(h, GRADE + peakAt(x, z))
	end
	-- Buttes, cuesta, cape knoll
	if x > 3000 then
		local m = mesaAt(x, z)
		if m > 0 then
			h = math.max(h, GRADE + m + 0.6 * (h - GRADE)) -- the butte sits on the local ground
		end
		local c = cuestaAt(x, z)
		if c > 0 then
			h += c
		end
		local k = knollAt(x, z)
		if k > 0 then
			h = math.max(h, GRADE + 20 + k)
		end
	end
	-- Sunwood Canyon (H9): a valley whose floor climbs gently to the pass and falls to Hidden Cove
	do
		local d, s = WorldGen.polyProject(CANYON_AXIS, x, z)
		if d < 520 then
			local pass = 0.72 * canyonLength
			local floorY = if s < pass
				then GRADE + 46 * SMOOTH(450, pass, s)
				else GRADE + 46 - 38 * SMOOTH(pass, canyonLength + 250, s)
			local v = SMOOTH(110, 520, d)
			if h > floorY then
				h = floorY + (h - floorY) * v
			end
		end
	end
	-- Authored flatten zones
	for _, f in FLATTEN do
		local sd = WorldGen.polySigned(f.poly, x, z)
		if sd > -f.blend then
			local t = SMOOTH(-f.blend, 0, sd)
			h = h + (f.y - h) * t
		end
	end
	-- Generated level pads (garages, POIs and landmarks on slopes): oriented rectangles with a blend apron
	for i, p in pads do
		local bb = padBoxes[i]
		if x >= bb[1] and x <= bb[3] and z >= bb[2] and z <= bb[4] then
			local dx, dz = x - p.cx, z - p.cz
			local u = math.abs(dx * p.ux + dz * p.uz) - p.hw
			local v = math.abs(-dx * p.uz + dz * p.ux) - p.hd
			local outside = math.sqrt(math.max(u, 0) ^ 2 + math.max(v, 0) ^ 2)
			if outside < p.blend then
				local t = SMOOTH(p.blend, 0, outside)
				h = h + (p.y - h) * t
			end
		end
	end
	return h
end

local COAST_BAND: { [string]: number } = { beach = 300, rock = 140, cliff = 55, quay = 4 }
local SHORE_Y: { [string]: number } = { beach = 0.8, rock = 1.5, cliff = 2.5, quay = GRADE }

-- Signed distance to the nearest landmass (positive on land) and the kind of the nearest coast segment.
local function shore(x: number, z: number): (number, CoastKind)
	local d1, i1 = WorldGen.polySigned(coastPoly, x, z)
	local d2, i2 = WorldGen.polySigned(islandPoly, x, z)
	if d2 > d1 then
		return d2, WorldTerrain.Islands[1].points[i2].kind
	end
	return d1, WorldTerrain.Coast[i1].kind
end
WorldTerrain.shore = shore

-- Memoized signed shore distance at the center of a 32-stud cell. The distance is 1-Lipschitz, so a point in the
-- cell is within 23 studs (half diagonal) of this value: callers use it to skip the exact test far from the coast.
local SHORE_CELL = 32
local SHORE_SLACK = SHORE_CELL * 0.7072
local shoreMemo: { [number]: number } = {}
local function shoreCoarse(x: number, z: number): number
	local cx, cz = math.floor(x / SHORE_CELL), math.floor(z / SHORE_CELL)
	local key = WorldGen.cellKey(cx, cz)
	local v = shoreMemo[key]
	if v == nil then
		v = shore((cx + 0.5) * SHORE_CELL, (cz + 0.5) * SHORE_CELL)
		shoreMemo[key] = v
	end
	return v :: number
end

-- shore(x, z) >= m, using the coarse memo when it is conclusive.
local function landAtLeast(x: number, z: number, m: number): boolean
	local c = shoreCoarse(x, z)
	if c - SHORE_SLACK >= m then
		return true
	elseif c + SHORE_SLACK < m then
		return false
	end
	return (shore(x, z)) >= m
end
WorldTerrain.landAtLeast = landAtLeast

local function inWater(x: number, z: number): (boolean, number)
	for _, w in WorldTerrain.Water do
		if WorldGen.pointInPoly(w.points, x, z) then
			return true, w.level
		end
	end
	return false, 0
end
WorldTerrain.inWater = inWater

-- Smooth ground grade (shoreline + landforms + pads; no channel / trench / reservoir carve).
local function gradeAt(x: number, z: number): number
	if shoreCoarse(x, z) - SHORE_SLACK >= 300 then
		return inlandHeight(x, z) -- deep inland: no shoreline shaping (widest band is 300)
	end
	local d, kind = shore(x, z)
	if d <= 0 then
		-- seabed: one smooth shelf everywhere; quays drop straight to 26
		if kind == "quay" then
			return math.max(-58, -26 - 0.03 * -d)
		end
		return math.max(-58, -0.6 - 0.05 * -d)
	end
	local inland = inlandHeight(x, z)
	local band = COAST_BAND[kind]
	if d >= band then
		return inland
	end
	local t = SMOOTH(0, band, d)
	return SHORE_Y[kind] + (inland - SHORE_Y[kind]) * t
end

-- Terrain surface: grade with the Rust River channel, the cut corridors and the reservoir carved in.
local function heightAt(x: number, z: number): number
	local h = gradeAt(x, z)
	if x > 1700 and x < 2400 then
		local d, s = WorldGen.polyProject(Channel.points, x, z)
		local _, cz = WorldGen.polyAt(Channel.points, s)
		local floorHalf = WorldTerrain.channelFloorHalf(cz)
		local half = floorHalf + Channel.wallRun
		if d < half + 40 then
			local floorY = WorldTerrain.channelFloorY(s)
			if cz < Channel.startOpenAt then
				-- natural creek in the foothills: a softer, wider cut
				local creekY = math.max(floorY, h - 18)
				local t = SMOOTH(half + 40, floorHalf * 0.5, d)
				h = h + (creekY - h) * t
			elseif d <= Channel.troughHalfWidth then
				h = math.min(h, floorY - Channel.troughDepth)
			elseif d <= floorHalf then
				h = math.min(h, floorY)
			elseif d <= half then
				h = math.min(h, floorY + (GRADE - floorY) * (d - floorHalf) / Channel.wallRun)
			end
		end
	end
	for i, c in cuts do
		local bb = cutBoxes[i]
		if x >= bb[1] and x <= bb[3] and z >= bb[2] and z <= bb[4] then
			local d, s = WorldGen.polyProject(c.points, x, z)
			if d <= c.half then
				-- floorY is sampled every 40 studs of arc length along the cut
				local k = math.clamp(s / 40, 0, #c.floorY - 1)
				local k0 = math.floor(k)
				local f0, f1 = c.floorY[k0 + 1], c.floorY[math.min(#c.floorY, k0 + 2)]
				h = math.min(h, f0 + (f1 - f0) * (k - k0))
			end
		end
	end
	local wet, level = inWater(x, z)
	if wet then
		local sd = WorldGen.polySigned(WorldTerrain.Water[1].points, x, z)
		h = math.min(h, level - 2 - math.min(26, sd * 0.12))
	end
	return h
end

WorldTerrain.gradeAt = gradeAt
WorldTerrain.heightAt = heightAt

-- Named terrain zones (for the terrain builder's material painting and the spec).
WorldTerrain.TerrainZones = {
	{ name = "City Basin", kind = "flat", y = GRADE, material = "Asphalt/Concrete", note = "graded flat at Y 12" },
	{ name = "Palmera Beach", kind = "beach", material = "Sand", note = "crescent bay: 300-stud sand band" },
	{
		name = "Sunwood Hills",
		kind = "hills",
		material = "Grass/LeafyGrass/Rock",
		note = "front range crest 230-250 at Z ~ -3050; summit ridge +300 at Z ~ -3610 (the SUNWOOD sign)",
	},
	{ name = "Sunwood Canyon", kind = "canyon", material = "Ground/Rock", note = "H9 valley, pass at Y 58" },
	{
		name = "Mount Talon",
		kind = "peak",
		material = "Rock above Y 400, Ground/Grass below",
		note = "960-stud peak at (4300, -3030), base radius 1300, ridged spurs; Talon Summit Trail",
	},
	{ name = "Red Mesa Foothills", kind = "hills", material = "Ground/Sandstone", note = "rolling 70-140 hills" },
	{
		name = "Red Mesa Desert",
		kind = "desert",
		material = "Sand/Sandstone",
		note = "dunes, NE-SW butte ellipses with caprock + talus, the 3.3k cuesta at X ~ 5200",
	},
	{ name = "Iron Bay", kind = "quay", material = "Concrete", note = "quays at Y 12, 26-deep water" },
	{ name = "Rust River", kind = "channel", material = "Concrete", note = "concrete storm channel, trough" },
	{ name = "H1 trench", kind = "cut", material = "Concrete walls", note = "north leg 26 below grade" },
	{ name = "Ocean", kind = "ocean", material = "Water", note = "sea level 0" },
}

return WorldTerrain
