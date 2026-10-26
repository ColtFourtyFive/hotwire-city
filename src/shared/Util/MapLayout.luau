--!strict
-- Pure geometry derived from Config/Map. Both server and client use this so every system agrees on
-- where roads, plots, parking spots and points of interest are. No instances are created here.

local MapConfig = require(script.Parent.Parent.Config.Map)

local MapLayout = {}

local S = MapConfig.GRID_SPACING
local CURB_TOP = MapConfig.ROAD_Y + MapConfig.CURB_HEIGHT

export type Axis = "X" | "Z" -- road runs ALONG this axis ("X" road: z = line*S constant)

MapLayout.CURB_TOP = CURB_TOP

function MapLayout.lineCoord(line: number): number
	return line * S
end

-- Center of block (bx, bz) at curb (sidewalk) height.
function MapLayout.blockCenter(bx: number, bz: number): Vector3
	return Vector3.new((bx + 0.5) * S, CURB_TOP, (bz + 0.5) * S)
end

-- Which block contains world XZ (may be outside the city).
function MapLayout.blockAt(pos: Vector3): (number, number)
	return math.floor(pos.X / S), math.floor(pos.Z / S)
end

-- True if pos is on asphalt (within a road strip, inside the ring road).
function MapLayout.isOnRoad(pos: Vector3): boolean
	local half = MapConfig.ROAD_WIDTH / 2
	local ext = MapConfig.HALF_EXTENT + half
	if math.abs(pos.X) > ext or math.abs(pos.Z) > ext then
		return false
	end
	local function near(v: number): boolean
		local r = v - math.round(v / S) * S
		return math.abs(r) <= half
	end
	return near(pos.X) or near(pos.Z)
end

-- Plots -------------------------------------------------------------------------------

function MapLayout.plotCount(): number
	return #MapConfig.Plots
end

-- Plot origin: block center at curb height. LookVector (-Z local) points OUT of the front door.
function MapLayout.plotOrigin(index: number): CFrame
	local def = MapConfig.Plots[index]
	assert(def, "bad plot index")
	local c = MapLayout.blockCenter(def.block.x, def.block.z)
	return CFrame.lookAt(c, c + def.face)
end

-- World CFrame from plot-local offset.
function MapLayout.plotToWorld(index: number, localOffset: Vector3): CFrame
	return MapLayout.plotOrigin(index) * CFrame.new(localOffset)
end

-- Slot i (1..12) in plot-local space. Slots alternate left/right starting nearest the door.
-- The returned CFrame is on the floor; its LookVector points toward the center aisle.
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

-- Region helpers: returns (CFrame, Size) of a box in world space.
function MapLayout.plotDropoffZone(plotIndex: number): (CFrame, Vector3)
	local G = MapConfig.Garage
	local size = G.DROPOFF_SIZE
	return MapLayout.plotToWorld(plotIndex, G.DROPOFF_CENTER + Vector3.new(0, size.Y / 2, 0)), size
end

-- The whole garage interior volume (used for "is this position inside plot N's garage").
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

-- Returns the plot index whose garage interior contains pos, or nil.
function MapLayout.plotAt(pos: Vector3): number?
	for i = 1, #MapConfig.Plots do
		local cf, size = MapLayout.plotInteriorZone(i)
		if MapLayout.isInBox(cf, size, pos) then
			return i
		end
	end
	return nil
end

-- Roads / traffic ------------------------------------------------------------------------

-- Base CFrame on a road centerline at road height facing travel direction dir (+1/-1 along axis).
function MapLayout.roadCFrame(axis: Axis, line: number, along: number, dir: number): CFrame
	local c = line * S
	local pos, facing
	if axis == "X" then
		pos = Vector3.new(along, MapConfig.ROAD_Y, c)
		facing = Vector3.new(dir, 0, 0)
	else
		pos = Vector3.new(c, MapConfig.ROAD_Y, along)
		facing = Vector3.new(0, 0, dir)
	end
	return CFrame.lookAt(pos, pos + facing)
end

-- Traffic lane CFrame (right-hand traffic: lane is to the right of the centerline).
function MapLayout.laneCFrame(axis: Axis, line: number, along: number, dir: number): CFrame
	return MapLayout.roadCFrame(axis, line, along, dir) * CFrame.new(MapConfig.LANE_OFFSET, 0, 0)
end

-- Every parking spot in the city (deterministic). CFrames are on the road surface facing along the road.
local parkingCache: { CFrame }? = nil
function MapLayout.parkingSpots(): { CFrame }
	if parkingCache then
		return parkingCache
	end
	local spots = {}
	for _, axis in { "X", "Z" } :: { Axis } do
		for line = MapConfig.LINE_MIN, MapConfig.LINE_MAX do
			for seg = MapConfig.BLOCK_MIN, MapConfig.BLOCK_MAX do
				local h = (line * 7 + seg * 3 + (if axis == "X" then 1 else 0)) % 3
				if h == 0 then
					local mid = (seg + 0.5) * S
					local flip = ((line + seg) % 2 == 0)
					local along = mid + (if flip then 38 else -38)
					local dir = if flip then 1 else -1
					local cf = MapLayout.roadCFrame(axis, line, along, dir) * CFrame.new(MapConfig.PARK_OFFSET, 0, 0)
					table.insert(spots, cf)
				end
			end
		end
	end
	parkingCache = spots
	return spots
end

-- Points of interest -------------------------------------------------------------------------

function MapLayout.poiCenter(name: string): Vector3
	local b = MapConfig.Blocks[name]
	assert(b, "unknown POI " .. name)
	return MapLayout.blockCenter(b.x, b.z)
end

function MapLayout.spawnCFrame(): CFrame
	local c = MapLayout.poiCenter("SpawnPlaza")
	-- face the Dealership (east)
	return CFrame.lookAt(c, c + Vector3.new(1, 0, 0))
end

-- 8 dealership showroom pads (world CFrames on the showroom floor, cars face -Z / north road).
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

-- Spray shop booths: drive in to clear your wanted level. Returns list of (CFrame, Size) boxes.
-- Each booth sits at the north edge of its block; cars enter from the road at the block's north side.
function MapLayout.sprayZones(): { { cframe: CFrame, size: Vector3 } }
	local zones = {}
	for _, name in { "SprayShopA", "SprayShopB" } do
		local c = MapLayout.poiCenter(name)
		local pos = c + Vector3.new(0, 7, -40)
		table.insert(zones, { cframe = CFrame.new(pos), size = Vector3.new(26, 14, 26) })
	end
	return zones
end

-- Chop shop: drive any non-owned car in for instant cash. Entrance from the road on the block's south side.
function MapLayout.chopZone(): (CFrame, Vector3)
	local c = MapLayout.poiCenter("ChopShop")
	return CFrame.new(c + Vector3.new(0, 7, 40)), Vector3.new(30, 14, 30)
end

-- Gear shop counter (players walk up and open the shop UI).
function MapLayout.gearShopCounter(): CFrame
	local c = MapLayout.poiCenter("GearShop")
	local p = c + Vector3.new(0, 0, 30)
	return CFrame.lookAt(p, p + Vector3.new(0, 0, 1)) -- faces the south road / sidewalk
end

-- Police spawn points: on the roads around Police HQ.
function MapLayout.policeSpawns(): { CFrame }
	local c = MapLayout.poiCenter("PoliceHQ")
	return {
		MapLayout.laneCFrame("Z", math.round((c.X - 80) / S), c.Z, 1),
		MapLayout.laneCFrame("Z", math.round((c.X + 80) / S), c.Z, -1),
		MapLayout.laneCFrame("X", math.round((c.Z - 80) / S), c.X, -1),
		MapLayout.laneCFrame("X", math.round((c.Z + 80) / S), c.X, 1),
	}
end

-- Where a busted player is released (in front of Police HQ, on the sidewalk).
function MapLayout.bustedReleaseCFrame(): CFrame
	local c = MapLayout.poiCenter("PoliceHQ")
	local p = c + Vector3.new(-50, 3, 0)
	return CFrame.lookAt(p, p + Vector3.new(-1, 0, 0))
end

function MapLayout.hotDropCFrames(): { CFrame }
	local out = {}
	for _, p in MapConfig.HotDropPoints do
		local pos = Vector3.new(p.X, MapConfig.ROAD_Y, p.Z)
		table.insert(out, CFrame.lookAt(pos, pos + Vector3.new(1, 0, 0)))
	end
	return out
end

-- Nearest road-lane CFrame to a world position (used to respawn police / place cars legally).
function MapLayout.nearestLane(pos: Vector3): CFrame
	local lineX = math.clamp(math.round(pos.X / S), MapConfig.LINE_MIN, MapConfig.LINE_MAX)
	local lineZ = math.clamp(math.round(pos.Z / S), MapConfig.LINE_MIN, MapConfig.LINE_MAX)
	local dx = math.abs(pos.X - lineX * S)
	local dz = math.abs(pos.Z - lineZ * S)
	local lim = MapConfig.HALF_EXTENT
	if dx < dz then
		-- closest road runs along Z at x = lineX*S
		local along = math.clamp(pos.Z, -lim, lim)
		return MapLayout.laneCFrame("Z", lineX, along, 1)
	else
		local along = math.clamp(pos.X, -lim, lim)
		return MapLayout.laneCFrame("X", lineZ, along, 1)
	end
end

return MapLayout
