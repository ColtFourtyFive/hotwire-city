--!strict
-- World/Bridges: the landmark bridge structures and the Palmera Pier (MapBuilder v2).
--
--   bridge_cable  Iron Bay Bridge (H2, both carriageways): two H pylons 160 above the deck at 22 % / 78 % of the
--                 span, legs outside both carriageways, a fan of 8 stays per leg and direction
--   bridge_arch   Crown Street Viaduct, Canyon Bridge, Skyline Drive: two parabolic ribs under the deck with spandrel
--                 columns
--   bridge_truss  Mission Truss Bridge: a through truss (top chords, verticals, diagonals, portals)
--   bridge_lift   Harbor Lift Bridge: four towers; the span is two bascule leaves (Roads leaves the span to us) that
--                 rise for LiftBridge.raised seconds every LiftBridge.period (Bridges.start)
--   pier          Palmera Pier: wooden deck on piles with rails; the Ferris wheel (Model tagged "FerrisWheel") beside
--                 the pier head
-- Deck slabs themselves are World/Roads (streets) and World/Freeways (decks).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldTerrain = require(Shared.Util.WorldTerrain)
local Kit = require(script.Parent.Kit)
local Roads = require(script.Parent.Roads)

type Ctx = Kit.Ctx

local Bridges = {}

local Edges = WorldLayout.Edges

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function rightOf(h: Vector3): Vector3
	return Vector3.new(-h.Z, 0, h.X)
end

-- Point, heading and right vector at arc length s of edge ei.
local function frame(ei: number, s: number): (Vector3, Vector3, Vector3)
	local L = Roads.cumOf(ei)[#Edges[ei].points]
	local p = Roads.pointAt(ei, math.clamp(s, 0, L))
	local q = Roads.pointAt(ei, math.clamp(s + 3, 0, L))
	local r0 = Roads.pointAt(ei, math.clamp(s - 3, 0, L))
	local h = flat(q - r0)
	h = if h.Magnitude > 1e-4 then h.Unit else Vector3.new(0, 0, -1)
	return p, h, rightOf(h)
end

local function groundAt(p: Vector3): number
	return math.max(WorldTerrain.heightAt(p.X, p.Z), WorldLayout.SEA_LEVEL - 24)
end

-------------------------------------------------------------------------------------------------------------------------
-- cable-stayed
-------------------------------------------------------------------------------------------------------------------------

-- Lateral extent (min, max offset along r) of the edge and its corridor twin at point p.
local function corridorExtent(ei: number, p: Vector3, r: Vector3): (number, number)
	local e = Edges[ei]
	local lo, hi = -e.width / 2, e.width / 2
	if e.corridor then
		for oi, o in Edges do
			if oi ~= ei and o.corridor == e.corridor then
				-- nearest point of the twin within 120 studs
				local best, bestOff = math.huge, 0
				local pts = o.points
				for k = 1, #pts - 1 do
					local a, b = pts[k], pts[k + 1]
					local ab = flat(b - a)
					local len2 = ab:Dot(ab)
					if len2 > 1e-6 then
						local t = math.clamp(flat(p - a):Dot(ab) / len2, 0, 1)
						local q = a + (b - a) * t
						local d = flat(q - p).Magnitude
						if d < best then
							best, bestOff = d, flat(q - p):Dot(r)
						end
					end
				end
				if best < 120 then
					lo = math.min(lo, bestOff - o.width / 2)
					hi = math.max(hi, bestOff + o.width / 2)
				end
			end
		end
	end
	return lo, hi
end

local function cableStayed(ctx: Ctx, l: WorldLayout.Landmark)
	local ei = l.edge :: number
	local span = l.span :: { number }
	local s0, s1 = span[1], span[2]
	local L = s1 - s0
	local concrete = Kit.style("concrete_modern")
	local cable = Kit.style("steel_white")
	for _, f in { 0.22, 0.78 } do
		local s = s0 + L * f
		local p, h, r = frame(ei, s)
		local lo, hi = corridorExtent(ei, p, r)
		local legs = { lo - 6, hi + 6 }
		local deckY = p.Y
		local topY = deckY + 160
		local g = groundAt(p)
		for _, off in legs do
			local base = p + r * off
			Kit.part(
				ctx,
				"Pylon",
				Vector3.new(7, topY - g + 4, 9),
				CFrame.lookAt(
					Vector3.new(base.X, (topY + g - 4) / 2, base.Z),
					Vector3.new(base.X, (topY + g - 4) / 2, base.Z) + h
				),
				concrete
			)
		end
		-- cross beams: under the deck and at the top
		for _, y in { deckY - 6, topY - 8 } do
			local c = p + r * ((lo + hi) / 2)
			Kit.part(
				ctx,
				"PylonBeam",
				Vector3.new(hi - lo + 18, 6, 7),
				CFrame.lookAt(Vector3.new(c.X, y, c.Z), Vector3.new(c.X, y, c.Z) + h),
				concrete
			)
		end
		-- stays: 8 per leg per direction, from the upper leg to the deck edge
		for _, off in legs do
			local edgeOff = if off < 0 then lo - 1 else hi + 1
			for _, dir in { -1, 1 } do
				for k = 1, 8 do
					local along = dir * (24 + (L * 0.2 - 24) * (k / 8))
					local sa = math.clamp(s + along, 0, Roads.cumOf(ei)[#Edges[ei].points])
					local anchorP, _, ar = frame(ei, sa)
					local anchor = anchorP + ar * edgeOff + Vector3.new(0, 0.5, 0)
					local top = Vector3.new((p + r * off).X, topY - 14 - k * 5.5, (p + r * off).Z)
					Kit.rod(ctx, "Stay", top, anchor, 0.7, cable, { collide = false, query = false, shadow = false })
				end
			end
		end
		Kit.tick(ctx)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- arch, truss, lift
-------------------------------------------------------------------------------------------------------------------------

local function deckArch(ctx: Ctx, l: WorldLayout.Landmark)
	local ei = l.edge :: number
	local e = Edges[ei]
	local span = l.span :: { number }
	local s0, s1 = span[1], span[2]
	local L = s1 - s0
	local style = Kit.style("concrete")
	local pa = Roads.pointAt(ei, s0)
	local pb = Roads.pointAt(ei, s1)
	local springY = math.max(groundAt(pa), groundAt(pb), math.min(pa.Y, pb.Y) - 220) + 2
	local n = 12
	for _, side in { -1, 1 } do
		local prev: Vector3? = nil
		for k = 0, n do
			local t = k / n
			local s = s0 + L * t
			local p, _, r = frame(ei, s)
			local crown = p.Y - 4
			local y = springY + (crown - springY) * (1 - (2 * t - 1) ^ 2)
			local pt = Vector3.new(p.X, y, p.Z) + r * side * (e.width / 2 - 3)
			if prev then
				Kit.beam(ctx, "ArchRib", prev, pt, 3, 5, style)
				-- spandrel column from the rib to the deck
				local gap = p.Y - 2 - y
				if gap > 4 and k < n then
					Kit.part(ctx, "Spandrel", Vector3.new(2.5, gap, 2.5), CFrame.new(pt.X, y + gap / 2, pt.Z), style)
				end
			end
			prev = pt
		end
	end
	Kit.tick(ctx)
end

local function throughTruss(ctx: Ctx, l: WorldLayout.Landmark)
	local ei = l.edge :: number
	local e = Edges[ei]
	local span = l.span :: { number }
	local s0, s1 = span[1], span[2]
	local L = s1 - s0
	local steel = Kit.style("steel_red")
	local H = 22
	local n = math.max(4, math.floor(L / 16))
	for _, side in { -1, 1 } do
		local off = side * (e.width / 2 + e.sidewalk + 1.5)
		local pa, _, ra = frame(ei, s0)
		local pb, _, rb = frame(ei, s1)
		local topA = pa + ra * off + Vector3.new(0, H, 0)
		local topB = pb + rb * off + Vector3.new(0, H, 0)
		Kit.beam(ctx, "TrussChord", topA, topB, 1.8, 2.2, steel)
		for k = 0, n do
			local s = s0 + L * k / n
			local p, _, r = frame(ei, s)
			local bot = p + r * off
			Kit.beam(ctx, "TrussPost", bot, bot + Vector3.new(0, H, 0), 1.4, 1.4, steel)
			if k < n then
				local q, _, rq = frame(ei, s0 + L * (k + 1) / n)
				local nxt = q + rq * off + Vector3.new(0, H, 0)
				if k % 2 == 0 then
					Kit.beam(ctx, "TrussDiagonal", bot, nxt, 1, 1, steel)
				else
					Kit.beam(ctx, "TrussDiagonal", bot + Vector3.new(0, H, 0), q + rq * off, 1, 1, steel)
				end
			end
		end
	end
	-- portal beams over the road at both ends
	for _, s in { s0, s1 } do
		local p, h, _ = frame(ei, s)
		local c = p + Vector3.new(0, H, 0)
		Kit.part(ctx, "TrussPortal", Vector3.new(e.width + 2 * e.sidewalk + 4, 2, 2), CFrame.lookAt(c, c + h), steel)
	end
	Kit.tick(ctx)
end

type Leaf = { part: BasePart, closed: CFrame, open: CFrame }
local leaves: { Leaf } = {}

local function liftBridge(ctx: Ctx, l: WorldLayout.Landmark)
	local ei = l.edge :: number
	local e = Edges[ei]
	local span = l.span :: { number }
	local s0, s1 = span[1], span[2]
	local L = s1 - s0
	local steel = Kit.style("metal_green")
	local half = e.width / 2 + e.sidewalk + 2
	for _, s in { s0, s1 } do
		local p, h, r = frame(ei, s)
		for _, side in { -1, 1 } do
			local base = p + r * side * (half + 3)
			local g = groundAt(base)
			Kit.part(
				ctx,
				"LiftTower",
				Vector3.new(6, p.Y + 48 - g, 6),
				CFrame.new(base.X, (p.Y + 48 + g) / 2, base.Z),
				steel
			)
		end
		local c = p + Vector3.new(0, 46, 0)
		Kit.part(ctx, "LiftBeam", Vector3.new(half * 2 + 12, 4, 6), CFrame.lookAt(c, c + h), steel)
	end
	-- bascule leaves: hinged at the span ends, meeting in the middle (when LiftBridge names this edge)
	local lift = WorldLayout.LiftBridge
	if lift and lift.edge == ei then
		local angle = math.rad(lift.leafAngle or 70)
		for _, endS in { s0, s1 } do
			local hinge, _, _ = frame(ei, endS)
			local mid = Roads.pointAt(ei, (s0 + s1) / 2)
			local toMid = flat(mid - hinge)
			local len = toMid.Magnitude
			if len < 1 then
				continue
			end
			local dir = toMid / len
			local w = e.width + 2 * e.sidewalk
			-- the leaf frame: hinge on the pivot, leaf extends along dir
			local pivot = CFrame.lookAt(hinge, hinge + dir)
			local closed = pivot * CFrame.new(0, -1, -len / 2)
			local open = pivot * CFrame.Angles(angle, 0, 0) * CFrame.new(0, -1, -len / 2)
			local leaf =
				Kit.part(ctx, "LiftLeaf", Vector3.new(w, 2, len - 0.4), closed, Kit.style("asphalt"), { tag = "Road" })
			table.insert(leaves, { part = leaf, closed = closed, open = open })
		end
	end
	local _ = L
	Kit.tick(ctx)
end

-------------------------------------------------------------------------------------------------------------------------
-- Palmera Pier + Ferris wheel
-------------------------------------------------------------------------------------------------------------------------

local function ferrisWheel(ctx: Ctx, hub: Vector3, axle: Vector3)
	local m = Instance.new("Model")
	m.Name = "FerrisWheel"
	m.Parent = Kit.folder(ctx, "Landmarks")
	m:AddTag("FerrisWheel")
	local R = 40
	local steel = Kit.style("steel_white")
	local inPlane = rightOf(axle)
	local o: Kit.PartOpts = { parent = m }
	-- A-frame legs on both sides of the wheel
	for _, side in { -1, 1 } do
		local top = hub + axle * side * 5
		for _, k in { -1, 1 } do
			local foot = Vector3.new(hub.X, hub.Y - R - 6, hub.Z) + inPlane * k * 22 + axle * side * 9
			Kit.beam(ctx, "WheelLeg", foot, top, 2, 2, steel, o)
		end
	end
	Kit.rod(ctx, "WheelAxle", hub - axle * 6, hub + axle * 6, 3, steel, o)
	local n = 16
	local prev: Vector3? = nil
	local first: Vector3? = nil
	for k = 0, n - 1 do
		local a = k / n * math.pi * 2
		local p = hub + inPlane * (math.cos(a) * R) + Vector3.new(0, math.sin(a) * R, 0)
		if prev then
			Kit.beam(ctx, "WheelRim", prev, p, 1.2, 1.2, steel, o)
		else
			first = p
		end
		prev = p
		if k % 2 == 0 then
			Kit.beam(ctx, "WheelSpoke", hub, p, 0.6, 0.6, steel, o)
			local car = Kit.part(
				ctx,
				"Gondola",
				Vector3.new(4, 4, 5),
				CFrame.new(p - Vector3.new(0, 3, 0)),
				Kit.style("paint_red"),
				o
			)
			car.Color =
				Color3.fromRGB(math.floor(120 + 120 * Kit.hash(k, 1, 5)), 60, math.floor(80 + 150 * Kit.hash(k, 2, 5)))
			Kit.nightGlow(car, car.Color:Lerp(Color3.new(1, 1, 1), 0.3))
		end
	end
	if prev and first then
		Kit.beam(ctx, "WheelRim", prev, first, 1.2, 1.2, steel, o)
	end
end

local function pier(ctx: Ctx, ei: number)
	local e = Edges[ei]
	local L = Roads.cumOf(ei)[#e.points]
	local pts = Roads.runPoints(ei, 0, L)
	local w = e.width + 2 * math.max(e.sidewalk, 4)
	Roads.strip(ctx, "PierDeck", pts, 0, w, 0, 1.6, Kit.style("wood"), { tag = "Road" })
	for _, side in { -1, 1 } do
		Roads.strip(ctx, "PierRail", pts, side * (w / 2 - 0.3), 0.5, 3.6, 3.6, Kit.style("wood"))
	end
	-- piles every 40 studs (two per row)
	local s = 20
	while s < L - 5 do
		local p, _, r = frame(ei, s)
		for _, side in { -1, 1 } do
			local base = p + r * side * (w / 2 - 2)
			local g = groundAt(base)
			if p.Y - g > 2 then
				Kit.post(
					ctx,
					"PierPile",
					Vector3.new(base.X, g - 2, base.Z),
					p.Y - g + 0.4,
					1.8,
					Kit.style("pole_wood")
				)
			end
		end
		s += 40
	end
	-- the Ferris wheel beside the pier head (wheel plane facing the beach)
	local headS = L - 90
	local p, h, r = frame(ei, headS)
	local hub = p + r * (w / 2 + 16) + Vector3.new(0, 48, 0)
	ferrisWheel(ctx, hub, h)
end

-------------------------------------------------------------------------------------------------------------------------

function Bridges.build(ctx: Ctx)
	table.clear(leaves)
	for _, l in WorldLayout.Landmarks do
		if not (l.edge and l.span) then
			continue
		end
		if l.kind == "bridge_cable" then
			cableStayed(ctx, l)
		elseif l.kind == "bridge_arch" then
			deckArch(ctx, l)
		elseif l.kind == "bridge_truss" then
			throughTruss(ctx, l)
		elseif l.kind == "bridge_lift" then
			liftBridge(ctx, l)
		end
	end
	for ei, e in Edges do
		if e.class == "pier" and e.length > 200 then
			pier(ctx, ei)
		end
	end
end

-- The lift span of World/Roads (left out of the road slab): { s0, s1 } on LiftBridge.edge, or nil.
function Bridges.liftSpan(): (number?, { number }?)
	local lift = WorldLayout.LiftBridge
	if not lift then
		return nil, nil
	end
	return lift.edge, lift.span
end

-- Is the bascule raised at server time t? (period / raised seconds from WorldLayout.LiftBridge)
function Bridges.liftRaised(t: number): boolean
	local lift = WorldLayout.LiftBridge
	if not lift then
		return false
	end
	return (t % (lift.period or 240)) < (lift.raised or 25)
end

local running = false
function Bridges.start()
	if running or #leaves == 0 then
		return
	end
	running = true
	task.spawn(function()
		local raised = false
		while running do
			local want = Bridges.liftRaised(Workspace:GetServerTimeNow())
			if want ~= raised then
				raised = want
				for _, lf in leaves do
					if lf.part.Parent then
						TweenService:Create(
							lf.part,
							TweenInfo.new(6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
							{ CFrame = if want then lf.open else lf.closed }
						):Play()
					end
				end
			end
			task.wait(0.5)
		end
	end)
end

function Bridges.stop()
	running = false
end

return Bridges
