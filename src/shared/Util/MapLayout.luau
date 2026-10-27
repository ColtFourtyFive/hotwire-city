--!strict
-- MapLayout (v2 compatibility shim): the v1 API every system calls, answered from the v2 world (Config/WorldLayout +
-- Util/WorldQuery). Systems keep compiling and behave sensibly while they migrate to WorldQuery one at a time
-- (docs/v2/world/MIGRATION.md §1, §6). No instances are created here; server and client get the same answers.
--
--   plots       plotOrigin = WorldLayout.Plots[i].cframe (ground centre at curb height, LookVector out of the door):
--               every Config/Map.Garage plot-local offset (slots, drop-off, collect pad, lock button) is unchanged
--   POIs        poiCenter takes v1 names (SpawnPlaza, Dealership, PoliceHQ, GearShop, SprayShopA/B, ChopShop,
--               StuntPark, Park, Pier) or any v2 POI / landmark id
--   zones       the drive-in bays, counters and dealer pads are defined HERE (MapBuilder's World/Places builds them
--               from these same functions): sprayZones (5), chopZones (4), gearShopCounters / gunStores (5),
--               dealerPads (8, Hotwire Motors: v1's showroom layout on the v2 POI)
--   roads       isOnRoad / nearestLane = WorldQuery; laneCFrame / roadCFrame keep the v1 (axis, line, along, dir)
--               signature and snap the grid point to the nearest real lane heading that way; roadSegments feeds
--               RoadGraph (which uses RoadGraph.fromWorld for the v2 world)
--   combat      hospitals / hospitalCFrame / gunStores / safeZones / safeZoneAt (v2/combat's API)
--   grid        blockCenter / blockAt / lineCoord keep v1's 160-stud cells for the systems not migrated yet
--               (NPC wandering); CURB_TOP is the city grade + curb (12.6)

local Config = script.Parent.Parent.Config
local MapConfig = require(Config.Map)
local WorldLayout = require(Config.WorldLayout)
local WorldQuery = require(script.Parent.WorldQuery)

local MapLayout = {}

export type Axis = "X" | "Z" -- v1: road runs ALONG this axis ("X" road: z = line*S constant)
export type NamedSpot = { name: string, cframe: CFrame }
export type SafeZone = { name: string, kind: string, cframe: CFrame, size: Vector3, plotIndex: number? }

local S = MapConfig.GRID_SPACING
local CURB = WorldLayout.Scale.CURB_HEIGHT
local GRADE = WorldLayout.GRADE

MapLayout.WORLD_VERSION = WorldLayout.VERSION
MapLayout.CURB_TOP = GRADE + CURB
MapLayout.ROAD_Y = GRADE

-------------------------------------------------------------------------------------------------------------------------
-- v1 grid cells (kept for the systems not migrated yet)
-------------------------------------------------------------------------------------------------------------------------

function MapLayout.lineCoord(line: number): number
	return line * S
end

function MapLayout.blockCenter(bx: number, bz: number): Vector3
	return Vector3.new((bx + 0.5) * S, MapLayout.CURB_TOP, (bz + 0.5) * S)
end

function MapLayout.blockAt(pos: Vector3): (number, number)
	return math.floor(pos.X / S), math.floor(pos.Z / S)
end

-------------------------------------------------------------------------------------------------------------------------
-- Roads
-------------------------------------------------------------------------------------------------------------------------

-- True if pos is on a road surface (curb to curb, within 6 studs of that road's height).
function MapLayout.isOnRoad(pos: Vector3): boolean
	local on = WorldQuery.isOnRoad(pos)
	return on
end

-- Nearest legal lane CFrame (outer lane, the direction closest to `heading` when given).
function MapLayout.nearestLane(pos: Vector3, heading: Vector3?): CFrame
	local cf = WorldQuery.nearestLane(pos, heading, { maxDistance = 2000, ignoreHeight = true })
	if cf then
		return cf
	end
	local p = WorldLayout.Spawns.default.Position
	return CFrame.lookAt(p, p + Vector3.new(1, 0, 0))
end

-- v1 signature: the grid point (axis, line, along) snapped to the nearest real lane heading +/- along the axis.
function MapLayout.laneCFrame(axis: Axis, line: number, along: number, dir: number): CFrame
	local pos = if axis == "X" then Vector3.new(along, GRADE, line * S) else Vector3.new(line * S, GRADE, along)
	local heading = if axis == "X" then Vector3.new(dir, 0, 0) else Vector3.new(0, 0, dir)
	return MapLayout.nearestLane(pos, heading)
end

-- v1 signature: the road centreline point nearest the grid point, facing +/- along the axis.
function MapLayout.roadCFrame(axis: Axis, line: number, along: number, dir: number): CFrame
	local pos = if axis == "X" then Vector3.new(along, GRADE, line * S) else Vector3.new(line * S, GRADE, along)
	local heading = if axis == "X" then Vector3.new(dir, 0, 0) else Vector3.new(0, 0, dir)
	local p, ei, s = WorldQuery.nearestRoadPoint(pos, { maxDistance = 2000, ignoreHeight = true })
	if not p or not ei then
		return CFrame.lookAt(pos, pos + heading)
	end
	local _, tan = WorldQuery.edgePoint(ei, s)
	local look = if tan:Dot(heading) >= 0 then tan else -tan
	return CFrame.lookAt(p, p + look)
end

-- Road network for RoadGraph (straight pieces of every edge polyline; level = layer).
local segCache: { any }? = nil
function MapLayout.roadSegments(): { any }
	local c = segCache
	if c then
		return c
	end
	local out = {}
	local classMap = {
		freeway = "highway",
		ramp = "highway",
		highway = "highway",
		boulevard = "avenue",
		avenue = "avenue",
		alley = "alley",
		dirt = "alley",
		service = "alley",
		channel = "alley",
	}
	for _, e in WorldLayout.Edges do
		local pts = e.points
		for k = 1, #pts - 1 do
			table.insert(out, {
				a = pts[k],
				b = pts[k + 1],
				width = e.width,
				class = (classMap :: any)[e.class] or "street",
				oneWay = e.oneWay,
				lanes = math.max(e.lanesF, e.lanesB, 1),
				level = e.layer,
				name = e.name,
			})
		end
	end
	segCache = out
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- Plots (v1 plot-local layout on the v2 plot frames)
-------------------------------------------------------------------------------------------------------------------------

function MapLayout.plotCount(): number
	return #WorldLayout.Plots
end

-- Plot origin: ground centre of the garage footprint at curb height; LookVector points OUT of the front door.
function MapLayout.plotOrigin(index: number): CFrame
	local plot = WorldLayout.Plots[index]
	assert(plot, "bad plot index")
	return plot.cframe
end

function MapLayout.plotToWorld(index: number, localOffset: Vector3): CFrame
	return MapLayout.plotOrigin(index) * CFrame.new(localOffset)
end

-- Slot i (1..12) in plot-local space. Slots alternate left/right starting nearest the door; the CFrame is on the floor
-- and its LookVector points toward the centre aisle.
function MapLayout.slotLocal(slot: number): CFrame
	local G = MapConfig.Garage
	local row = math.ceil(slot / 2)
	local left = (slot % 2) == 1
	local z = G.SLOT_ZS[row]
	assert(z, "bad slot index")
	local x = if left then -G.SLOT_X else G.SLOT_X
	local pos = Vector3.new(x, 0, z)
	local facing = Vector3.new(if left then 1 else -1, 0, 0)
	return CFrame.lookAt(pos, pos + facing)
end

function MapLayout.slotWorld(plotIndex: number, slot: number): CFrame
	return MapLayout.plotOrigin(plotIndex) * MapLayout.slotLocal(slot)
end

function MapLayout.maxPhysicalSlots(): number
	return #MapConfig.Garage.SLOT_ZS * 2
end

function MapLayout.plotDropoffZone(plotIndex: number): (CFrame, Vector3)
	local G = MapConfig.Garage
	local size = G.DROPOFF_SIZE
	return MapLayout.plotToWorld(plotIndex, G.DROPOFF_CENTER + Vector3.new(0, size.Y / 2, 0)), size
end

-- The whole garage interior volume ("is this position inside plot N's garage").
function MapLayout.plotInteriorZone(plotIndex: number): (CFrame, Vector3)
	local G = MapConfig.Garage
	local depth = G.BACK_Z - G.FRONT_Z
	local centerZ = (G.BACK_Z + G.FRONT_Z) / 2
	local size = Vector3.new(G.HALF_WIDTH * 2, G.WALL_HEIGHT, depth)
	return MapLayout.plotToWorld(plotIndex, Vector3.new(0, G.WALL_HEIGHT / 2, centerZ)), size
end

function MapLayout.isInBox(boxCFrame: CFrame, boxSize: Vector3, pos: Vector3): boolean
	local p = boxCFrame:PointToObjectSpace(pos)
	return math.abs(p.X) <= boxSize.X / 2 and math.abs(p.Y) <= boxSize.Y / 2 and math.abs(p.Z) <= boxSize.Z / 2
end

-- The plot whose garage interior contains pos, or nil.
function MapLayout.plotAt(pos: Vector3): number?
	for i = 1, #WorldLayout.Plots do
		local cf, size = MapLayout.plotInteriorZone(i)
		if MapLayout.isInBox(cf, size, pos) then
			return i
		end
	end
	return nil
end

-------------------------------------------------------------------------------------------------------------------------
-- POIs and their interaction spots (World/Places builds from these)
-------------------------------------------------------------------------------------------------------------------------

local function poisOf(kind: string): { WorldLayout.POI }
	return WorldQuery.poisOfKind(kind)
end

-- v1 block names -> v2 ids
local V1_NAMES: { [string]: string } = {
	SpawnPlaza = "HotwirePlaza",
	Dealership = "Dealership",
	PoliceHQ = "PoliceHQ",
	ChopShop = "ChopShop",
}

local function plaza(): Vector3
	local p = WorldQuery.poi("HotwirePlaza")
	return if p then p.cframe.Position else WorldLayout.Spawns.default.Position
end

-- The kind's POIs, nearest Hotwire Plaza first (v1 had one or two of each near the spawn).
local function byPlaza(kind: string): { WorldLayout.POI }
	local list = table.clone(poisOf(kind))
	local c = plaza()
	table.sort(list, function(a: WorldLayout.POI, b: WorldLayout.POI): boolean
		local da = (a.cframe.Position - c).Magnitude
		local db = (b.cframe.Position - c).Magnitude
		if da ~= db then
			return da < db
		end
		return a.id < b.id
	end)
	return list
end

-- Centre of a POI at curb height (v1 names or v2 POI / landmark ids).
function MapLayout.poiCenter(name: string): Vector3
	local id = V1_NAMES[name]
	local poi = WorldQuery.poi(id or name)
	if poi then
		return poi.cframe.Position + Vector3.new(0, CURB, 0)
	end
	if name == "GearShop" then
		return byPlaza("gunshop")[1].cframe.Position + Vector3.new(0, CURB, 0)
	elseif name == "SprayShopA" or name == "SprayShopB" then
		local list = byPlaza("spray")
		return list[if name == "SprayShopA" then 1 else 2].cframe.Position + Vector3.new(0, CURB, 0)
	elseif name == "StuntPark" then
		local j = WorldLayout.StuntJumps[1]
		assert(j, "no stunt jumps")
		return j.cframe.Position
	elseif name == "Park" then
		local l = WorldQuery.landmark("EchoPark")
		assert(l, "no Echo Park")
		return l.cframe.Position + Vector3.new(0, CURB, 0)
	elseif name == "Pier" then
		for _, e in WorldLayout.Edges do
			if e.class == "pier" and e.length > 200 then
				return e.points[#e.points]
			end
		end
	end
	local lm = WorldQuery.landmark(name)
	assert(lm, "unknown POI " .. name)
	return lm.cframe.Position
end

function MapLayout.spawnCFrame(): CFrame
	return WorldLayout.Spawns.default
end

-- Drive-in bay of a spray / customs / chop POI: box (0, 13, -D/2 + 30) in the POI frame, size (W - 20, 26, 50); the
-- bay opens to the street (local -Z).
MapLayout.BAY_FRONT = 5
MapLayout.BAY_DEPTH = 50
function MapLayout.bayBox(poi: WorldLayout.POI): (CFrame, Vector3)
	local W, D = poi.size.X, poi.size.Z
	return poi.cframe * CFrame.new(0, 13, -D / 2 + MapLayout.BAY_FRONT + MapLayout.BAY_DEPTH / 2),
		Vector3.new(W - 20, 26, MapLayout.BAY_DEPTH)
end

-- Counter frames of a gun shop: (gun counter, gear counter), on the floor 12 in from the lot front, LookVector toward
-- the door.
function MapLayout.counterFrames(poi: WorldLayout.POI): (CFrame, CFrame)
	local D = poi.size.Z
	local base = poi.cframe * CFrame.new(0, CURB, -D / 2 + 12)
	return base * CFrame.new(-10, 0, 0), base * CFrame.new(10, 0, 0)
end

-- Dealer pads of a dealership POI: two rows of four on the front lot, cars facing the street.
function MapLayout.dealerPadsOf(poi: WorldLayout.POI): { CFrame }
	local W, D = poi.size.X, poi.size.Z
	local out: { CFrame } = {}
	for _, zf in { -D / 2 + 32, -D / 2 + 66 } do
		for _, xf in { -0.375, -0.125, 0.125, 0.375 } do
			table.insert(out, poi.cframe * CFrame.new(xf * (W - 20), CURB, zf))
		end
	end
	return out
end

-- 8 showroom pads of Hotwire Motors: v1's showroom layout (two rows of four, cars facing -Z, the open drive-out)
-- around the POI centre at curb height, so DealershipService's showroom, dressing and sign stay consistent.
function MapLayout.dealerPads(): { CFrame }
	local c = MapLayout.poiCenter("Dealership")
	local pads = {}
	for _, z in { -22, 22 } do
		for _, x in { -36, -12, 12, 36 } do
			local p = c + Vector3.new(x, 0, z)
			table.insert(pads, CFrame.lookAt(p, p + Vector3.new(0, 0, -1)))
		end
	end
	return pads
end

-- Spray shop bays (drive in to clear your wanted level): every Fresh Coat, nearest the plaza first.
function MapLayout.sprayZones(): { { cframe: CFrame, size: Vector3 } }
	local zones = {}
	for _, poi in byPlaza("spray") do
		local cf, size = MapLayout.bayBox(poi)
		table.insert(zones, { cframe = cf, size = size })
	end
	return zones
end

-- Every chop shop bay (Rusty's, Dockside Salvage, ...).
function MapLayout.chopZones(): { { cframe: CFrame, size: Vector3 } }
	local zones = {}
	for _, poi in byPlaza("chop") do
		local cf, size = MapLayout.bayBox(poi)
		table.insert(zones, { cframe = cf, size = size })
	end
	return zones
end

-- v1: the chop shop bay (Rusty's Chop Shop).
function MapLayout.chopZone(): (CFrame, Vector3)
	local poi = WorldQuery.poi("ChopShop") or byPlaza("chop")[1]
	return MapLayout.bayBox(poi)
end

-- Gear counters in every Lock & Load, nearest the plaza first.
function MapLayout.gearShopCounters(): { CFrame }
	local out = {}
	for _, poi in byPlaza("gunshop") do
		local _, gear = MapLayout.counterFrames(poi)
		table.insert(out, gear)
	end
	return out
end

-- v1: the gear shop counter (the Lock & Load nearest the plaza).
function MapLayout.gearShopCounter(): CFrame
	return MapLayout.gearShopCounters()[1]
end

-- Police spawn points: the baked station lanes (server), else a lane at every station's entrance (client).
function MapLayout.policeSpawns(): { CFrame }
	local out = {}
	if WorldLayout.hasServerData() then
		for _, sp in WorldLayout.Spawns.police do
			table.insert(out, sp.cframe)
		end
		return out
	end
	for _, poi in poisOf("police") do
		table.insert(out, MapLayout.nearestLane(poi.entrance))
	end
	return out
end

function MapLayout.bustedReleaseCFrame(): CFrame
	return WorldLayout.Spawns.bustedRelease
end

-- Hot drop landing points: the road point nearest each hot-drop zone centre.
function MapLayout.hotDropCFrames(): { CFrame }
	local out = {}
	for _, z in WorldLayout.HotDrops do
		local c = z.cframe.Position
		local p, ei, s = WorldQuery.nearestRoadPoint(c, { maxDistance = 600, ignoreHeight = true, layer = 0 })
		if p and ei then
			local _, tan = WorldQuery.edgePoint(ei, s)
			table.insert(out, CFrame.lookAt(p, p + tan))
		end
	end
	return out
end

-- Curb parking spots (server: the baked 6k+ spots; client: none).
function MapLayout.parkingSpots(): { CFrame }
	local out = {}
	if not WorldLayout.hasServerData() then
		return out
	end
	for _, sp in WorldLayout.Spawns.parking do
		table.insert(out, sp.cframe)
	end
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- Combat (v2/combat API on the v2 world)
-------------------------------------------------------------------------------------------------------------------------

-- Hospitals (WASTED respawns at the nearest): the baked respawn CFrames, named after the nearest hospital POI.
function MapLayout.hospitals(): { NamedSpot }
	local out: { NamedSpot } = {}
	local list = poisOf("hospital")
	for i, cf in WorldLayout.Spawns.hospital do
		local best, bestD = nil :: WorldLayout.POI?, math.huge
		for _, poi in list do
			local d = (poi.cframe.Position - cf.Position).Magnitude
			if d < bestD then
				best, bestD = poi, d
			end
		end
		table.insert(out, { name = if best then best.name else ("Hospital " .. i), cframe = cf })
	end
	if #out == 0 then
		for _, poi in list do
			table.insert(out, { name = poi.name, cframe = CFrame.new(poi.entrance + Vector3.new(0, 3 + CURB, 0)) })
		end
	end
	return out
end

-- Nearest hospital to a position (where the player went down).
function MapLayout.hospitalCFrame(pos: Vector3?): (CFrame, string)
	local list = MapLayout.hospitals()
	local best = list[1]
	if pos then
		local bestD = math.huge
		for _, h in list do
			local d = (h.cframe.Position - pos).Magnitude
			if d < bestD then
				best, bestD = h, d
			end
		end
	end
	return best.cframe, best.name
end

-- Gun stores (Lock & Load): the gun counter's front, where a player walks up (the map tags it "GunStoreCounter").
function MapLayout.gunStores(): { NamedSpot }
	local out: { NamedSpot } = {}
	for _, poi in byPlaza("gunshop") do
		local gun = MapLayout.counterFrames(poi)
		local front = gun * CFrame.new(0, 3, -3)
		table.insert(out, { name = poi.id, cframe = front })
	end
	return out
end

-- Safe zones (no damage in or out, weapons holstered): garages, gun stores, dealerships and hospitals (the data's
-- SafeZones), spray bays and the busted-release steps.
local safeCache: { SafeZone }? = nil
function MapLayout.safeZones(): { SafeZone }
	local c = safeCache
	if c then
		return c
	end
	local zones: { SafeZone } = {}
	for i = 1, #WorldLayout.Plots do
		local cf, size = MapLayout.plotInteriorZone(i)
		table.insert(zones, { name = "Plot" .. i, kind = "garage", cframe = cf, size = size, plotIndex = i })
	end
	for _, g in MapLayout.gunStores() do
		table.insert(zones, { name = g.name, kind = "gunstore", cframe = g.cframe, size = Vector3.new(30, 16, 30) })
	end
	for _, z in WorldLayout.SafeZones do
		local kind = if string.find(z.id, "Hospital", 1, true) then "hospital" else "dealership"
		table.insert(zones, { name = z.name, kind = kind, cframe = z.cframe, size = z.size })
	end
	for i, z in MapLayout.sprayZones() do
		table.insert(zones, { name = "Spray" .. i, kind = "spray", cframe = z.cframe, size = z.size })
	end
	table.insert(zones, {
		name = "PoliceHQRelease",
		kind = "release",
		cframe = MapLayout.bustedReleaseCFrame(),
		size = Vector3.new(24, 14, 24),
	})
	safeCache = zones
	return zones
end

function MapLayout.safeZoneAt(pos: Vector3): SafeZone?
	for _, z in MapLayout.safeZones() do
		if MapLayout.isInBox(z.cframe, z.size, pos) then
			return z
		end
	end
	return nil
end

return MapLayout
