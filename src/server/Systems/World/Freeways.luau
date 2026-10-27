--!strict
-- World/Freeways: freeway carriageways, ramps and flyovers (MapBuilder v2).
--
--   decks       one slab per straight run, barrier footprint included, lane markings as one texture per cross-section
--   barriers    Jersey barriers on both edges; cut where they would cross another deck's pavement (gores, merges,
--               the carriageway pairs' shared median), so a ramp opens onto its carriageway
--   piers       every ~90 studs where the deck stands > 8 above the ground: a column + hammerhead cap, moved along
--               the deck (up to 40 studs) until its base clears every road below; none on landmark bridge spans
--   trench      retaining walls along the baked cut corridors (the H1 north leg)
--   gantries    an overhead sign gantry ~260 studs before every diverge gore
--
-- Ground roads, junctions and street bridges are World/Roads; landmark bridge structures World/Bridges.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldTerrain = require(Shared.Util.WorldTerrain)
local WorldGen = require(Shared.Util.WorldGen)
local Kit = require(script.Parent.Kit)
local Markings = require(script.Parent.Markings)
local Roads = require(script.Parent.Roads)
local Spatial = require(script.Parent.Spatial)

type Ctx = Kit.Ctx

local Freeways = {}

local Edges = WorldLayout.Edges

Freeways.CLASSES = { freeway = true, ramp = true } :: { [string]: boolean }

local DECK_T = 4.5 -- a deep slab: its dark underside and edge read as the deck girder (no separate girder part)
local BARRIER_W = 1.6
local BARRIER_H = 3.2
local PIER_STEP = 90
local PIER_D = 7
local LANDMARK_KINDS = { bridge_cable = true, bridge_arch = true, bridge_truss = true, bridge_lift = true }

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function rightOf(h: Vector3): Vector3
	return Vector3.new(-h.Z, 0, h.X)
end

-- Arc-length spans of edge ei carried by a landmark bridge structure (no piers there).
local landmarkSpans: { [number]: { { number } } }? = nil
local function spansOf(ei: number): { { number } }
	local m = landmarkSpans
	if not m then
		local built: { [number]: { { number } } } = {}
		for _, l in WorldLayout.Landmarks do
			if LANDMARK_KINDS[l.kind] and l.edge and l.span then
				local list = built[l.edge] or {}
				table.insert(list, l.span)
				built[l.edge] = list
				-- the carriageway twin of a cable-stayed corridor shares the span
				local e = Edges[l.edge]
				if e.corridor then
					for oi, o in Edges do
						if oi ~= l.edge and o.corridor == e.corridor and #o.spans > 0 then
							local olist = built[oi] or {}
							for _, sp in o.spans do
								table.insert(olist, sp)
							end
							built[oi] = olist
						end
					end
				end
			end
		end
		landmarkSpans = built
		m = built
	end
	return (m :: { [number]: { { number } } })[ei] or {}
end
Freeways.landmarkSpans = spansOf

local function inSpans(spans: { { number } }, s: number, pad: number): boolean
	for _, sp in spans do
		if s >= sp[1] - pad and s <= sp[2] + pad then
			return true
		end
	end
	return false
end

-- Barrier line along pts at lateral offset off: straight pieces, cut where they lie on another pavement.
local function barrierLine(ctx: Ctx, ei: number, pts: { Vector3 }, off: number)
	local style = Kit.style("concrete")
	for k = 1, #pts - 1 do
		local a, b = pts[k], pts[k + 1]
		local d = flat(b - a)
		local len = d.Magnitude
		if len < 0.5 then
			continue
		end
		local r = rightOf(d / len)
		local pa = a + r * off
		local pb = b + r * off
		-- sample every 6 studs: keep the stretches that are not on another deck
		local n = math.max(1, math.ceil(len / 6))
		local runStart: number? = nil
		local function flush(t1: number)
			local t0 = runStart :: number
			if (t1 - t0) * len > 1 then
				local p0 = pa:Lerp(pb, t0) + Vector3.new(0, BARRIER_H, 0)
				local p1 = pa:Lerp(pb, t1) + Vector3.new(0, BARRIER_H, 0)
				Roads.slab(ctx, "Barrier", p0, p1, BARRIER_W, BARRIER_H + DECK_T, 0.4, 0.4, style)
			end
			runStart = nil
		end
		for j = 0, n do
			local t = j / n
			local p = pa:Lerp(pb, t)
			local blocked = Spatial.insideOther(ei, p, 0.5)
			if not blocked and runStart == nil then
				runStart = t
			elseif blocked and runStart ~= nil then
				flush(math.max(t - 0.5 / n, 0))
			end
		end
		if runStart ~= nil then
			flush(1)
		end
	end
end

-- Column + hammerhead cap under deck point p (deck top), deck width w, heading h.
local function pier(ctx: Ctx, top: Vector3, h: Vector3, w: number, ground: number)
	local capY = top.Y - DECK_T
	local colTop = capY - 3
	local height = colTop - ground
	if height < 2 then
		return
	end
	Kit.post(ctx, "Pier", Vector3.new(top.X, ground - 2, top.Z), height + 2, PIER_D, Kit.style("concrete"))
	local cf = CFrame.lookAt(Vector3.new(top.X, capY - 1.5, top.Z), Vector3.new(top.X, capY - 1.5, top.Z) + h)
	Kit.part(ctx, "PierCap", Vector3.new(math.max(w * 0.8, 12), 3, 7), cf, Kit.style("concrete"))
end

local function buildPiers(ctx: Ctx, ei: number)
	local e = Edges[ei]
	local L = Roads.cumOf(ei)[#e.points]
	local skip = spansOf(ei)
	local s = PIER_STEP / 2
	while s < L - 10 do
		if not inSpans(skip, s, 12) then
			-- try the nominal station first, then step along the deck until the base clears the roads below
			for _, shift in { 0, 10, -10, 20, -20, 30, -30, 40, -40 } do
				local ss = math.clamp(s + shift, 4, L - 4)
				local p = Roads.pointAt(ei, ss)
				local g = WorldTerrain.heightAt(p.X, p.Z)
				local ground = math.max(g, WorldLayout.SEA_LEVEL - 20)
				if p.Y - ground < 8 then
					break -- low deck: the fill carries it
				end
				local blocked = Spatial.roadAt(p.X, p.Z, { yMax = p.Y - 6, pad = PIER_D / 2 + 1 }) ~= nil
				if not blocked then
					local q = Roads.pointAt(ei, math.min(ss + 2, L))
					local h = flat(q - p)
					if h.Magnitude < 1e-3 then
						h = Vector3.new(0, 0, 1)
					end
					pier(ctx, p, h.Unit, e.width, ground)
					break
				end
			end
		end
		s += PIER_STEP
	end
end

local function buildEdge(ctx: Ctx, ei: number)
	local e = Edges[ei]
	local L = Roads.cumOf(ei)[#e.points]
	local pts = Roads.runPoints(ei, 0, L)
	local image = Markings.imageFor(e)
	local style = Kit.style("asphalt")
	-- deck slab (curb to curb) with the lane markings; the barriers are its side walls
	Roads.strip(
		ctx,
		"Deck",
		pts,
		0,
		e.width,
		0,
		DECK_T,
		style,
		{ tag = "Road" },
		function(p: Part, _sa: number, sb: number)
			if image then
				Kit.texture(p, image, Enum.NormalId.Top, e.width, Markings.PERIOD, 0, -sb % Markings.PERIOD)
			end
		end
	)
	-- barriers both sides
	for _, side in { 1, -1 } do
		barrierLine(ctx, ei, pts, side * (e.width / 2 + BARRIER_W / 2))
	end
	-- piers under elevated decks
	if e.elevated then
		buildPiers(ctx, ei)
	end
	Kit.tick(ctx)
end

-- Retaining walls along the baked cut corridors (the H1 trench).
local function buildCuts(ctx: Ctx)
	local _, cuts = WorldTerrain.getEdits()
	local style = Kit.style("concrete_modern")
	for _, c in cuts do
		local cum = WorldGen.polyCum(c.points)
		local L = cum[#cum]
		local s = 0
		while s < L - 1 do
			local s1 = math.min(L, s + 40)
			local x0, z0 = WorldGen.polyAtCum(c.points, cum, s)
			local x1, z1 = WorldGen.polyAtCum(c.points, cum, s1)
			local k0 = math.clamp(math.floor(s / 40) + 1, 1, #c.floorY)
			local k1 = math.clamp(math.floor(s1 / 40) + 1, 1, #c.floorY)
			local floor = math.min(c.floorY[k0], c.floorY[k1])
			local dx, dz = x1 - x0, z1 - z0
			local len = math.sqrt(dx * dx + dz * dz)
			if len > 0.5 then
				local rx, rz = -dz / len, dx / len
				for _, side in { 1, -1 } do
					local ax, az = x0 + rx * side * (c.half + 1), z0 + rz * side * (c.half + 1)
					local bx, bz = x1 + rx * side * (c.half + 1), z1 + rz * side * (c.half + 1)
					local top = math.max(WorldTerrain.gradeAt(ax, az), WorldTerrain.gradeAt(bx, bz)) + 3
					if top - floor > 4 then
						local mid = Vector3.new((ax + bx) / 2, (top + floor - 2) / 2, (az + bz) / 2)
						local cf = CFrame.lookAt(mid, mid + Vector3.new(dx, 0, dz))
						Kit.part(ctx, "TrenchWall", Vector3.new(2, top - floor + 2, len + 0.6), cf, style)
					end
				end
			end
			s = s1
		end
	end
end

-- Overhead sign gantries ~260 studs before each diverge (on the carriageway feeding the gore node).
local function buildGantries(ctx: Ctx)
	local metal = Kit.style("metal_grey")
	local green = Kit.style("sign_green")
	for _, g in WorldLayout.Gores do
		if g.kind ~= "diverge" then
			continue
		end
		local node = WorldLayout.Nodes[g.node]
		-- the incoming carriageway: a freeway edge ending at the gore node
		local feed: number? = nil
		for _, ei in node.edges do
			local e = Edges[ei]
			if e.class == "freeway" and e.b == g.node and ei ~= g.ramp then
				feed = ei
				break
			end
		end
		if not feed then
			continue
		end
		local e = Edges[feed]
		local L = Roads.cumOf(feed)[#e.points]
		local s = L - 260
		if s < 20 then
			continue
		end
		local p = Roads.pointAt(feed, s)
		local q = Roads.pointAt(feed, s + 4)
		local h = flat(q - p)
		if h.Magnitude < 1e-3 then
			continue
		end
		h = h.Unit
		local r = rightOf(h)
		local half = e.width / 2 + BARRIER_W + 1
		local top = p.Y + 22
		for _, side in { 1, -1 } do
			local base = p + r * (side * half)
			Kit.post(ctx, "Gantry", base, 22, 1.4, metal)
		end
		local beamC = Vector3.new(p.X, top, p.Z)
		Kit.part(ctx, "Gantry", Vector3.new(half * 2 + 2, 1.6, 1.6), CFrame.lookAt(beamC, beamC + h), metal)
		-- the exit sign over the right lanes, facing oncoming traffic (-h)
		local signC = beamC + r * (e.width / 2 - 12) - Vector3.new(0, 4.5, 0)
		Kit.part(ctx, "GantrySign", Vector3.new(20, 8, 0.6), CFrame.lookAt(signC, signC - h), green)
	end
end

function Freeways.build(ctx: Ctx, filter: ((number) -> boolean)?)
	for ei, e in Edges do
		if Freeways.CLASSES[e.class] and (filter == nil or filter(ei)) then
			buildEdge(ctx, ei)
		end
	end
	if filter == nil then
		buildCuts(ctx)
		buildGantries(ctx)
	end
end

Freeways.buildCuts = buildCuts
Freeways.buildGantries = buildGantries

return Freeways
