--!strict
-- Ambience (PLAN C3 · audio): the city's sound beds, pure.
--
-- * District -> bed (WORLD_SPEC §4 district ids): downtown / midtown = city traffic hum and distant horns, beach =
--   waves and gulls, hills = wildland birds by day / crickets by night, cactus / mesa = desert air, southgate =
--   suburbs, foundry / rust = industrial hum and clanks, port = harbour, airport = distant traffic and jets.
--   Every bed has a day and a night loop (Config/Sounds Amb_<Bed>_Day / _Night), weighted by the lighting's
--   NightFactor (Workspace attribute from LightingService) with an equal-power crossfade.
-- * Freeway roar: a third layer whose level follows the distance to the nearest freeway segment
--   (buildSegments / nearestDistance: a coarse grid over the WorldLayout freeway polylines, built once).
-- * One-shots: distant sirens, dog barks, car alarms, planes, gulls, coyotes, clanks, train horns, distant horns,
--   each allowed in some beds and times of day, with per-sound cooldowns and a global minimum gap.
-- The caller passes its own random source (() -> number in [0, 1)).

local Ambience = {}

Ambience.DISTRICT_BEDS = {
	downtown = "City",
	midtown = "City",
	beach = "Beach",
	hills = "Wild",
	foundry = "Industrial",
	rust = "Industrial",
	southgate = "Suburb",
	port = "Port",
	airport = "Airport",
	cactus = "Desert",
	mesa = "Desert",
}
Ambience.BEDS = { "City", "Beach", "Wild", "Desert", "Suburb", "Industrial", "Port", "Airport" }
Ambience.DEFAULT_BED = "City"

-- Precomputed Config/Sounds keys per bed (no string building per frame).
Ambience.KEYS = {} :: { [string]: { day: string, night: string } }
for _, bed in Ambience.BEDS do
	Ambience.KEYS[bed] = { day = "Amb_" .. bed .. "_Day", night = "Amb_" .. bed .. "_Night" }
end
Ambience.FREEWAY_KEY = "Amb_Freeway"

Ambience.CROSSFADE = 3.5 -- s for a district change
Ambience.FREEWAY_NEAR = 40 -- full roar this close to a freeway centreline
Ambience.FREEWAY_FAR = 280 -- silent beyond
Ambience.GLOBAL_GAP = 5 -- s between any two ambient one-shots

function Ambience.bedFor(districtId: any): string
	if typeof(districtId) == "string" then
		return Ambience.DISTRICT_BEDS[districtId] or Ambience.DEFAULT_BED
	end
	return Ambience.DEFAULT_BED
end

-- (day weight, night weight) for a NightFactor 0..1, equal power.
function Ambience.dayNight(nightFactor: number): (number, number)
	local n = math.clamp(nightFactor, 0, 1)
	return math.cos(n * math.pi / 2), math.sin(n * math.pi / 2)
end

function Ambience.isNight(nightFactor: number): boolean
	return nightFactor >= 0.5
end

-- Freeway roar level for a distance to the nearest freeway (1 near .. 0 far, smooth).
function Ambience.freewayLevel(distance: number): number
	local t = math.clamp((distance - Ambience.FREEWAY_NEAR) / (Ambience.FREEWAY_FAR - Ambience.FREEWAY_NEAR), 0, 1)
	return 1 - t * t * (3 - 2 * t)
end

-------------------------------------------------------------------------------------------------------------------------
-- Freeway segment grid
-------------------------------------------------------------------------------------------------------------------------

export type SegGrid = {
	cell: number,
	ax: { number },
	az: { number },
	bx: { number },
	bz: { number },
	cells: { [number]: { number } },
}

local function key(cx: number, cz: number): number
	return cx * 65536 + cz
end

-- Build a grid from road edges ({ points: {Vector3}, class: string }) of the given classes (default: freeway).
function Ambience.buildSegments(edges: { any }, classes: { [string]: boolean }?, cellSize: number?): SegGrid
	local cell = cellSize or 256
	local want = classes or { freeway = true }
	local grid: SegGrid = { cell = cell, ax = {}, az = {}, bx = {}, bz = {}, cells = {} }
	for _, e in edges do
		if typeof(e) == "table" and want[e.class] and typeof(e.points) == "table" then
			local pts = e.points
			for i = 1, #pts - 1 do
				local a, b = pts[i], pts[i + 1]
				table.insert(grid.ax, a.X)
				table.insert(grid.az, a.Z)
				table.insert(grid.bx, b.X)
				table.insert(grid.bz, b.Z)
				local id = #grid.ax
				local x0, x1 = math.floor(math.min(a.X, b.X) / cell), math.floor(math.max(a.X, b.X) / cell)
				local z0, z1 = math.floor(math.min(a.Z, b.Z) / cell), math.floor(math.max(a.Z, b.Z) / cell)
				for cx = x0, x1 do
					for cz = z0, z1 do
						local k = key(cx, cz)
						local list = grid.cells[k]
						if not list then
							list = {}
							grid.cells[k] = list
						end
						table.insert(list, id)
					end
				end
			end
		end
	end
	return grid
end

local function segDist(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = if len2 > 1e-9 then math.clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1) else 0
	local qx, qz = ax + dx * t - px, az + dz * t - pz
	return math.sqrt(qx * qx + qz * qz)
end

-- Distance (XZ) from (x, z) to the nearest segment within maxDistance, or math.huge.
function Ambience.nearestDistance(grid: SegGrid, x: number, z: number, maxDistance: number): number
	local cell = grid.cell
	local r = math.ceil(maxDistance / cell)
	local cx, cz = math.floor(x / cell), math.floor(z / cell)
	local best = math.huge
	for ix = cx - r, cx + r do
		for iz = cz - r, cz + r do
			local list = grid.cells[key(ix, iz)]
			if list then
				for _, id in list do
					local d = segDist(x, z, grid.ax[id], grid.az[id], grid.bx[id], grid.bz[id])
					if d < best then
						best = d
					end
				end
			end
		end
	end
	return if best <= maxDistance then best else math.huge
end

-------------------------------------------------------------------------------------------------------------------------
-- One-shots
-------------------------------------------------------------------------------------------------------------------------

export type OneShot = {
	keys: { string }, -- Config/Sounds variants
	beds: { [string]: boolean },
	when: string, -- "day" | "night" | "any"
	gap: { number }, -- { min, max } s between two of this kind
	dist: { number }, -- { min, max } studs from the listener (0, 0 = overhead / 2D)
}

local ALL: { [string]: boolean } = {}
for _, bed in Ambience.BEDS do
	ALL[bed] = true
end

Ambience.ONESHOTS = {
	{
		keys = { "Amb_SirenFar1", "Amb_SirenFar2" },
		beds = { City = true, Suburb = true, Industrial = true, Port = true, Airport = true },
		when = "any",
		gap = { 45, 110 },
		dist = { 220, 420 },
	},
	{
		keys = { "Amb_Horn1", "Amb_Horn2", "Amb_Horn3" },
		beds = { City = true },
		when = "day",
		gap = { 10, 30 },
		dist = { 70, 200 },
	},
	{
		keys = { "Amb_Dog1", "Amb_Dog2", "Amb_Dog3" },
		beds = { Suburb = true, Wild = true, Desert = true },
		when = "any",
		gap = { 25, 70 },
		dist = { 60, 200 },
	},
	{
		keys = { "Amb_CarAlarm" },
		beds = { City = true, Suburb = true, Industrial = true },
		when = "any",
		gap = { 90, 200 },
		dist = { 90, 220 },
	},
	{ keys = { "Amb_Plane1", "Amb_Plane2" }, beds = ALL, when = "any", gap = { 80, 180 }, dist = { 0, 0 } },
	{
		keys = { "Amb_Gull1", "Amb_Gull2", "Amb_Gull3" },
		beds = { Beach = true, Port = true },
		when = "day",
		gap = { 8, 24 },
		dist = { 30, 120 },
	},
	{
		keys = { "Amb_Coyote" },
		beds = { Wild = true, Desert = true },
		when = "night",
		gap = { 45, 110 },
		dist = { 150, 300 },
	},
	{
		keys = { "Amb_Clank1", "Amb_Clank2" },
		beds = { Industrial = true, Port = true },
		when = "any",
		gap = { 9, 26 },
		dist = { 80, 220 },
	},
	{
		keys = { "Amb_TrainHorn" },
		beds = { Industrial = true, Desert = true, Port = true },
		when = "any",
		gap = { 100, 220 },
		dist = { 0, 0 },
	},
} :: { OneShot }

export type Scheduler = { nextAt: { [number]: number }, globalAt: number }

function Ambience.newScheduler(now: number, rand: () -> number): Scheduler
	local s: Scheduler = { nextAt = {}, globalAt = now + 8 }
	for i, o in Ambience.ONESHOTS do
		-- stagger the first ones so a fresh session does not fire everything at once
		s.nextAt[i] = now + o.gap[1] * (0.3 + rand() * 0.7)
	end
	return s
end

-- The next one-shot due now in this bed / time of day: (sound key, distance) or nil. Arms the cooldowns.
function Ambience.pickOneShot(s: Scheduler, now: number, bed: string, night: boolean, rand: () -> number): (string?, number)
	if now < s.globalAt then
		return nil, 0
	end
	local count = #Ambience.ONESHOTS
	local start = math.floor(rand() * count)
	for k = 0, count - 1 do
		local i = (start + k) % count + 1
		local o = Ambience.ONESHOTS[i]
		local okTime = o.when == "any" or (o.when == "night") == night
		if okTime and o.beds[bed] and now >= (s.nextAt[i] or 0) then
			s.nextAt[i] = now + o.gap[1] + rand() * (o.gap[2] - o.gap[1])
			s.globalAt = now + Ambience.GLOBAL_GAP
			local variant = o.keys[math.floor(rand() * #o.keys) + 1] or o.keys[1]
			local d = o.dist[1] + rand() * (o.dist[2] - o.dist[1])
			return variant, d
		end
	end
	return nil, 0
end

return Ambience
