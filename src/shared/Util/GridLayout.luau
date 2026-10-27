--!strict
-- GridLayout: v1's square street grid (Config/Map: 160-stud spacing, 40-wide roads at Y 0), kept verbatim for the
-- systems whose internal road logic is still grid-based (PoliceService routing helpers, TrafficService's lane
-- machine, NPCService's block wandering). The v2 world does NOT have these roads: positions, zones, plots and POIs
-- come from Util/MapLayout (the v2 shim) and Util/WorldQuery. Delete this module when Police / Traffic / NPC move to
-- WorldQuery (docs/v2/world/MIGRATION.md §3).

local MapConfig = require(script.Parent.Parent.Config.Map)

local GridLayout = {}

local S = MapConfig.GRID_SPACING
local CURB_TOP = MapConfig.ROAD_Y + MapConfig.CURB_HEIGHT

export type Axis = "X" | "Z" -- road runs ALONG this axis ("X" road: z = line*S constant)

GridLayout.CURB_TOP = CURB_TOP

function GridLayout.lineCoord(line: number): number
	return line * S
end

-- Center of block (bx, bz) at curb (sidewalk) height.
function GridLayout.blockCenter(bx: number, bz: number): Vector3
	return Vector3.new((bx + 0.5) * S, CURB_TOP, (bz + 0.5) * S)
end

-- Which block contains world XZ (may be outside the city).
function GridLayout.blockAt(pos: Vector3): (number, number)
	return math.floor(pos.X / S), math.floor(pos.Z / S)
end

-- True if pos is on asphalt (within a road strip, inside the ring road).
function GridLayout.isOnRoad(pos: Vector3): boolean
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

-- Roads / traffic ------------------------------------------------------------------------

-- Base CFrame on a road centerline at road height facing travel direction dir (+1/-1 along axis).
function GridLayout.roadCFrame(axis: Axis, line: number, along: number, dir: number): CFrame
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
function GridLayout.laneCFrame(axis: Axis, line: number, along: number, dir: number): CFrame
	return GridLayout.roadCFrame(axis, line, along, dir) * CFrame.new(MapConfig.LANE_OFFSET, 0, 0)
end

-- Every parking spot in the city (deterministic). CFrames are on the road surface facing along the road.
local parkingCache: { CFrame }? = nil
function GridLayout.parkingSpots(): { CFrame }
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
					local cf = GridLayout.roadCFrame(axis, line, along, dir) * CFrame.new(MapConfig.PARK_OFFSET, 0, 0)
					table.insert(spots, cf)
				end
			end
		end
	end
	parkingCache = spots
	return spots
end

-- Nearest road-lane CFrame to a world position (used to respawn police / place cars legally).
function GridLayout.nearestLane(pos: Vector3): CFrame
	local lineX = math.clamp(math.round(pos.X / S), MapConfig.LINE_MIN, MapConfig.LINE_MAX)
	local lineZ = math.clamp(math.round(pos.Z / S), MapConfig.LINE_MIN, MapConfig.LINE_MAX)
	local dx = math.abs(pos.X - lineX * S)
	local dz = math.abs(pos.Z - lineZ * S)
	local lim = MapConfig.HALF_EXTENT
	if dx < dz then
		-- closest road runs along Z at x = lineX*S
		local along = math.clamp(pos.Z, -lim, lim)
		return GridLayout.laneCFrame("Z", lineX, along, 1)
	else
		local along = math.clamp(pos.X, -lim, lim)
		return GridLayout.laneCFrame("X", lineZ, along, 1)
	end
end

return GridLayout
