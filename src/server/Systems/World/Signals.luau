--!strict
-- World/Signals: traffic signals and stop signs at ground junctions (MapBuilder v2).
--
--   Signals.build(ctx, geos)   per signal junction, per approach with inbound lanes: a mast-arm pole on the far-right
--                              corner (as the driver sees it) whose arm reaches over the inbound lanes, with one head
--                              per two lanes facing the approaching traffic. A head is a housing + ONE lens part that
--                              moves between the red / amber / green positions (2 parts a head, not 4); heads are
--                              tagged "SignalHead" with attributes Intersection / Approach. Stop and all-way junctions
--                              get a stop sign on the near-right corner of every stop approach.
--   Signals.update(t)          sets every head to WorldQuery.signalState(id, approach, t) (server clock; only heads
--                              whose state changed are touched). Signals.start() runs it every 0.25 s.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldQuery = require(Shared.Util.WorldQuery)
local Kit = require(script.Parent.Kit)
local Roads = require(script.Parent.Roads)

type Ctx = Kit.Ctx

local Signals = {}

Signals.TAG = "SignalHead"
Signals.MAST_H = 19 -- arm height (the heads clear a box truck)
Signals.HEAD = Vector3.new(1.6, 4.6, 1.2)
Signals.LENS = 1.15

local Edges = WorldLayout.Edges
local Intersections = WorldLayout.Intersections

local LENS_COLORS: { [string]: Color3 } = {
	red = Color3.fromRGB(255, 52, 40),
	amber = Color3.fromRGB(255, 170, 30),
	green = Color3.fromRGB(60, 255, 120),
	none = Color3.fromRGB(60, 60, 56),
}
-- lens offset from the housing centre (local Y): red top, amber middle, green bottom
local LENS_Y: { [string]: number } = { red = 1.45, amber = 0, green = -1.45, none = 0 }

type Head = { lens: BasePart, housing: BasePart, id: number, approach: number, state: string }
local heads: { Head } = {}

local function lensCFrame(housing: CFrame, state: string): CFrame
	return housing * CFrame.new(0, LENS_Y[state] or 0, -Signals.HEAD.Z / 2 - 0.05)
end

-- The farthest extent of the junction core along direction d (from the centre).
local function extent(g: Roads.JunctionGeo, d: Vector3): number
	local best = 0
	for _, p in g.core do
		best = math.max(best, (Vector3.new(p.X, 0, p.Z) - Vector3.new(g.center.X, 0, g.center.Z)):Dot(d))
	end
	return best
end

local function buildSignal(ctx: Ctx, g: Roads.JunctionGeo)
	local it = Intersections[g.id]
	local c = g.center
	local cf0 = Vector3.new(c.X, c.Y, c.Z)
	local poleStyle = Kit.style("metal_dark")
	local body = Kit.style("signal_body")
	for _, A in g.apps do
		local ap = it.approaches[A.index]
		if not ap or not ap.inbound or ap.lanesIn <= 0 then
			continue
		end
		local e = Edges[A.edge]
		-- the driver travels -h; their right is -r. Far side: across the core.
		local fwd = -A.h
		local right = -A.r
		local far = extent(g, fwd) + 3
		-- the opposite approach's half width (where the far curb is), else this road's
		local farHalf = A.a
		for _, B in g.apps do
			if B ~= A and B.h:Dot(fwd) > 0.9 then
				farHalf = B.a
			end
		end
		local poleBase = cf0 + fwd * far + right * (farHalf + 3) + Vector3.new(0, WorldLayout.Scale.CURB_HEIGHT, 0)
		Kit.post(ctx, "SignalPole", poleBase, Signals.MAST_H + 2, 1.3, poleStyle)
		-- the inbound lanes span from the centre (median edge) to the right curb: heads over them
		local inner = if e.oneWay then -A.a else e.median / 2
		local outer = A.a
		local lanesIn = ap.lanesIn
		local nHeads = if lanesIn >= 3 then 2 else 1
		local armLen = farHalf + 3 - (inner + (outer - inner) * 0.2)
		armLen = math.clamp(armLen, 8, 42)
		local armY = poleBase.Y + Signals.MAST_H
		local armA = Vector3.new(poleBase.X, armY, poleBase.Z)
		local armB = armA - right * armLen
		Kit.rod(ctx, "SignalArm", armA, armB, 0.7, poleStyle)
		for k = 1, nHeads do
			local t = (k - 0.5) / nHeads
			-- head positions over the lane centres (lateral offset from the pole)
			local lateral = (farHalf + 3) - (inner + (outer - inner) * t)
			local hp = armA - right * math.clamp(lateral, 2, armLen) - Vector3.new(0, Signals.HEAD.Y / 2 + 0.4, 0)
			-- the head faces the approaching driver (+h)
			local hcf = CFrame.lookAt(hp, hp + A.h)
			local housing = Kit.part(ctx, "SignalHead", Signals.HEAD, hcf, body, { tag = Signals.TAG })
			housing:SetAttribute("Intersection", g.id)
			housing:SetAttribute("Approach", A.index)
			local lens = Kit.part(
				ctx,
				"SignalLens",
				Vector3.new(0.2, Signals.LENS, Signals.LENS),
				lensCFrame(hcf, "red") * CFrame.Angles(0, math.pi / 2, 0),
				Kit.style("lens_off"),
				{ collide = false, query = false, shadow = false, shape = Enum.PartType.Cylinder }
			)
			lens.Material = Enum.Material.Neon
			lens.Color = LENS_COLORS.red
			table.insert(heads, { lens = lens, housing = housing, id = g.id, approach = A.index, state = "red" })
		end
	end
end

local function buildStop(ctx: Ctx, g: Roads.JunctionGeo)
	local it = Intersections[g.id]
	local c = g.center
	for _, A in g.apps do
		local ap = it.approaches[A.index]
		if not ap or not ap.inbound then
			continue
		end
		if g.control == "stop" and not table.find(it.stopApproaches, A.index) then
			continue
		end
		local e = Edges[A.edge]
		if e.class == "alley" or e.class == "service" or e.class == "dirt" then
			continue
		end
		-- near-right corner of the approach (driver's right = -r), just before the core
		local base = Vector3.new(c.X, c.Y + 0.6, c.Z) + A.h * (A.T + 4) - A.r * (A.a + math.min(A.s, 6) * 0.5 + 1)
		Kit.post(ctx, "StopPost", base, 8.5, 0.35, Kit.style("metal_grey"))
		local sc = base + Vector3.new(0, 8.6, 0)
		local sign = Kit.part(
			ctx,
			"StopSign",
			Vector3.new(0.15, 2.6, 2.6),
			CFrame.lookAt(sc, sc + A.h) * CFrame.Angles(0, math.pi / 2, 0),
			Kit.style("paint_red"),
			{ shape = Enum.PartType.Cylinder, collide = false }
		)
		local _ = sign
	end
end

function Signals.build(ctx: Ctx, geos: { [number]: Roads.JunctionGeo }, filter: ((number) -> boolean)?)
	for id, g in geos do
		if filter and not filter(id) then
			continue
		end
		if g.control == "signal" then
			buildSignal(ctx, g)
		elseif g.control == "stop" or g.control == "allway" then
			buildStop(ctx, g)
		end
		Kit.tick(ctx)
	end
end

-- Sets every head to the state at time t. Returns how many heads changed.
function Signals.update(t: number): number
	local changed = 0
	for _, h in heads do
		local st = WorldQuery.signalState(h.id, h.approach, t)
		if st ~= h.state then
			h.state = st
			if h.lens.Parent then
				h.lens.CFrame = lensCFrame(h.housing.CFrame, st) * CFrame.Angles(0, math.pi / 2, 0)
				h.lens.Color = LENS_COLORS[st] or LENS_COLORS.none
			end
			changed += 1
		end
	end
	return changed
end

function Signals.headCount(): number
	return #heads
end

function Signals.reset()
	table.clear(heads)
end

local running = false
function Signals.start()
	if running then
		return
	end
	running = true
	task.spawn(function()
		while running do
			Signals.update(Workspace:GetServerTimeNow())
			task.wait(0.25)
		end
	end)
	local _ = CollectionService
end

function Signals.stop()
	running = false
end

return Signals
