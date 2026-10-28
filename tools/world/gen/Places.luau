--!strict
-- WorldLayout generator, phase 2 (AUTHORING TOOL, runs in Lune via tools/world/gen.luau; never shipped).
--
-- Phase 1 (gen/WorldLayout.luau) built the road graph. This phase places everything that hangs off it: POIs and the 8
-- garage plots (by address: nearest clear frontage), the downtown tower plan, lots, terrain pads / cuts, landmarks,
-- Hot Drops, ballistic stunt jumps, zones, spawns (parking tiers, off-street rare spots, police lanes), time-weighted
-- routing (armored runs, races, ETA fields), roadblock anchors, the Harbor lift bridge, heist drop-offs, car swaps,
-- onboarding scores, streetscape rules, the streaming skeleton / skyline proxies / terrain silhouettes and the stats.
-- Pure and deterministic, like phase 1. Section numbers continue phase 1's.
local Shared = game:GetService("ReplicatedStorage").Shared
local WorldGen = require(Shared.Util.WorldGen)
local WorldTerrain = require(Shared.Util.WorldTerrain)

type P2 = WorldGen.P2
type P3 = WorldGen.P3
type OBB = WorldGen.OBB

return function(WorldLayout: any)
	local ctx = WorldLayout._ctx
	local S = WorldLayout.Scale
	local LANE: number = S.LANE
	local GRADE: number = WorldLayout.GRADE
	local SPEED: { [string]: number } = WorldLayout.Speed
	local DELAY: { [string]: number } = WorldLayout.JunctionDelay
	local Nodes: { any } = WorldLayout.Nodes
	local Edges: { any } = WorldLayout.Edges
	local Intersections: { any } = WorldLayout.Intersections
	local districtAt: (number, number) -> string = WorldLayout.districtAt
	local subzoneAt: (number, number) -> any = WorldLayout.subzoneAt
	local districtById: { [string]: any } = ctx.districtById
	local gradeAt = WorldTerrain.gradeAt
	local heightAt = WorldTerrain.heightAt
	local landAtLeast = WorldTerrain.landAtLeast
	local poly: ({ { number } }) -> { P2 } = ctx.poly
	local DECK_Y: number = ctx.DECK_Y

	local pads: { WorldTerrain.Pad } = {}
	local cuts: { WorldTerrain.Cut } = {}
	local function installEdits()
		WorldTerrain.setEdits(pads, cuts)
	end

	-- The H1 north-leg trench is a terrain cut (heightAt only; gradeAt stays the natural grade lots stand on). Its
	-- floor sits 2 below the carriageway so smooth terrain never pokes through the slab (tech critique 7).
	do
		local ringCenter: { P2 } = ctx.ringCenter
		local ringY: (number) -> number = ctx.ringY
		local cum = WorldGen.polyCum(ringCenter)
		local s0, s1 = ctx.trench[1], ctx.trench[2]
		local pts: { P2 } = WorldGen.polySlice(ringCenter, s0, s1)
		local floorY: { number } = {}
		local L = WorldGen.polyLength(pts)
		local s = 0
		while s <= L + 40 do
			table.insert(floorY, ringY(s0 + math.min(s, L)) - 2)
			s += 40
		end
		local _ = cum
		table.insert(cuts, { name = "H1 trench", points = pts, half = 68, floorY = floorY })
		installEdits()
	end

	-- Bridge spans again, now that the trench is cut: every street over the H1 north leg crosses it on a bridge.
	do
		local ways = ctx.ways
		for _, e in Edges do
			local pts3: { P3 } = {}
			for _, p in e.points do
				table.insert(pts3, { x = p.X, y = p.Y, z = p.Z })
			end
			e.spans = ctx.bridgeSpansOf(ways[e.way], pts3)
			e.bridge = #e.spans > 0
		end
	end

	---------------------------------------------------------------------------------------------------------------------
	-- 11. Spatial helpers (edge index, road / deck footprints, frontage geometry)
	---------------------------------------------------------------------------------------------------------------------

	local edgePts: { { pts: { P3 } } } = {}
	local edgeCum: { { number } } = {}
	local roadSegs = WorldGen.segIndex(96) -- every edge segment, padded by its half width + sidewalk
	local elevSegs = WorldGen.segIndex(96) -- elevated decks / flyovers only (for lots, POIs, jumps)
	local MAX_EXTRA = 12
	for i, e in Edges do
		local pts: { P3 } = {}
		for _, p in e.points do
			table.insert(pts, { x = p.X, y = p.Y, z = p.Z })
		end
		edgePts[i] = { pts = pts }
		edgeCum[i] = WorldGen.polyCum(pts)
		local pad = e.width / 2 + e.sidewalk + MAX_EXTRA
		for k = 1, #pts - 1 do
			WorldGen.segAdd(roadSegs, pts[k].x, pts[k].z, pts[k + 1].x, pts[k + 1].z, i, k, pad)
			if e.elevated then
				WorldGen.segAdd(elevSegs, pts[k].x, pts[k].z, pts[k + 1].x, pts[k + 1].z, i, k, e.width / 2 + 16)
			end
		end
	end
	local edgeIndex = WorldGen.edgeIndex(edgePts, 128, function(i: number): number
		return Edges[i].width / 2 + Edges[i].sidewalk + 4
	end)

	-- Is (x, z) on a road's footprint (curb-to-curb + sidewalks + extra)? Elevated decks count only when asked (lots
	-- may stand under a high deck only as open uses; buildings never do).
	local function roadClearance(x: number, z: number, extra: number, withElevated: boolean?): (boolean, number?)
		local hit: number? = nil
		WorldGen.segQuery(roadSegs, x, z, 0, function(id: number)
			if hit then
				return
			end
			local ei = roadSegs.owner[id]
			local e = Edges[ei]
			if e.elevated and not withElevated then
				return
			end
			local _, _, _, d =
				WorldGen.projectSeg(x, z, roadSegs.ax[id], roadSegs.az[id], roadSegs.bx[id], roadSegs.bz[id])
			if d < e.width / 2 + e.sidewalk + math.min(extra, MAX_EXTRA) then
				hit = ei
			end
		end)
		return hit ~= nil, hit
	end

	-- Lowest elevated deck whose footprint (+ margin) touches the rectangle, or nil (gta critique 10: lots must not
	-- pierce decks; tested on the full footprint, not on sample points).
	local function deckOver(b: OBB, margin: number): (number?, number?)
		local r = math.sqrt(b.hw * b.hw + b.hd * b.hd)
		local low: number?, lowEdge: number? = nil, nil
		WorldGen.segQuery(elevSegs, b.cx, b.cz, r, function(id: number)
			local ei = elevSegs.owner[id]
			local e = Edges[ei]
			local d = WorldGen.obbSegDistance(b, elevSegs.ax[id], elevSegs.az[id], elevSegs.bx[id], elevSegs.bz[id])
			if d <= e.width / 2 + margin then
				local k = elevSegs.segNo[id]
				local pts = edgePts[ei].pts
				local y = math.min(pts[k].y, pts[k + 1].y)
				if low == nil or y < (low :: number) then
					low, lowEdge = y, ei
				end
			end
		end)
		return low, lowEdge
	end

	-- Is arc length s (+- margin) on edge ei inside one of its bridge spans (no ground under the road)?
	local function onBridge(ei: number, s: number, margin: number): boolean
		for _, sp in Edges[ei].spans do
			if s + margin >= sp[1] and s - margin <= sp[2] then
				return true
			end
		end
		return false
	end

	-- Point / height / tangent at arc length s along edge ei.
	local function edgeAt(ei: number, s: number): (number, number, number, number, number)
		local pts = edgePts[ei].pts
		local px, pz, tx, tz, i, t = WorldGen.polyAtCum(pts, edgeCum[ei], s)
		local a, b = pts[i], pts[math.min(i + 1, #pts)]
		return px, a.y + (b.y - a.y) * t, pz, tx, tz
	end

	-- Clearance needed at node `nodeId` along edge `ei`: half width + sidewalk of the roads crossing it there.
	local function endClear(ei: number, nodeId: number): number
		local n = Nodes[nodeId]
		local name = Edges[ei].name
		local c = 0
		for _, other in n.edges do
			local o = Edges[other]
			if other ~= ei and o.name ~= name and o.layer == Edges[ei].layer then
				c = math.max(c, o.width / 2 + o.sidewalk)
			end
		end
		return c
	end

	local function nodeRadius(nodeId: number): number
		local n = Nodes[nodeId]
		if n.intersection then
			return Intersections[n.intersection].radius
		end
		return 0
	end

	-- Terrain relief (max - min grade) over a footprint, 5 x 5 samples.
	local function relief(b: OBB): (number, number)
		local lo, hi = math.huge, -math.huge
		local vx, vz = -b.uz, b.ux
		for i = -2, 2 do
			for j = -2, 2 do
				local x = b.cx + b.ux * b.hw * i / 2 + vx * b.hd * j / 2
				local z = b.cz + b.uz * b.hw * i / 2 + vz * b.hd * j / 2
				local g = gradeAt(x, z)
				lo = math.min(lo, g)
				hi = math.max(hi, g)
			end
		end
		return hi - lo, lo
	end

	-- Level pad under a footprint (+ apron) at height y: the terrain is graded flat there (tech critique 13).
	local function addPad(name: string, b: OBB, y: number, apron: number, blend: number)
		table.insert(pads, {
			name = name,
			cx = b.cx,
			cz = b.cz,
			ux = b.ux,
			uz = b.uz,
			hw = b.hw + apron,
			hd = b.hd + apron,
			y = y,
			blend = blend,
		})
		installEdits()
	end

	---------------------------------------------------------------------------------------------------------------------
	-- 12. POIs and plots (placed by "address": the nearest clear frontage of an allowed road class)
	---------------------------------------------------------------------------------------------------------------------

	type Reserved = { obb: OBB, what: string }
	local reserved: { Reserved } = {}
	local PlacementErrors: { string } = {}
	WorldLayout.PlacementErrors = PlacementErrors

	local FRONTAGE_CLASSES: { [string]: boolean } =
		{ boulevard = true, avenue = true, street = true, rural = true, highway = true }

	type PlaceOpts = {
		classes: { [string]: boolean }?,
		setback: number?,
		side: number?,
		road: string?,
		face: { number }?, -- the front (LookVector) must point within maxAngle of this point (from the door)
		maxAngle: number?,
		maxRelief: number?, -- steeper footprints are skipped; anything over 1.5 gets a level pad
		curb: boolean?, -- base at street + curb height (garages, v1 plot frame)
		site: string?, -- a reserved hero site (phase 1 RESERVED_AREAS) this footprint may stand in
		atEnd: boolean?, -- stand at the dead end of the road, facing back down it (museum, lookouts)
	}

	-- First road whose footprint (curb-to-curb + sidewalks + extra) touches the rectangle (exact, segment vs box).
	local function roadHit(b: OBB, extra: number): number?
		local r = math.sqrt(b.hw * b.hw + b.hd * b.hd)
		local hit: number? = nil
		WorldGen.segQuery(roadSegs, b.cx, b.cz, r, function(id: number)
			if hit then
				return
			end
			local ei = roadSegs.owner[id]
			local e = Edges[ei]
			if e.elevated then
				return
			end
			local d = WorldGen.obbSegDistance(b, roadSegs.ax[id], roadSegs.az[id], roadSegs.bx[id], roadSegs.bz[id])
			if d < e.width / 2 + e.sidewalk + extra then
				hit = ei
			end
		end)
		return hit
	end

	local function inReservedArea(x: number, z: number, except: string?): string?
		for _, area in WorldLayout.ReservedAreas do
			if area.name ~= except and WorldGen.pointInPoly(area.poly, x, z) then
				return area.name
			end
		end
		return nil
	end

	-- A footprint is clear when it touches no road footprint (the front face may sit on the back of the sidewalk), no
	-- deck passes over it (+8), it does not overlap another reserved footprint or a reserved area and stands on land.
	local function footprintClear(obb: OBB, site: string?): (boolean, string?)
		local inset: OBB = { cx = obb.cx, cz = obb.cz, ux = obb.ux, uz = obb.uz, hw = obb.hw - 1.5, hd = obb.hd - 1.5 }
		local ei = roadHit(inset, 0.5)
		if ei then
			return false, "road " .. Edges[ei].name
		end
		if deckOver(obb, 8) then
			return false, "under a deck"
		end
		for _, c in WorldGen.obbCorners(obb) do
			if not landAtLeast(c.x, c.z, 12) then
				return false, "water"
			end
			local area = inReservedArea(c.x, c.z, site)
			if area then
				return false, "reserved " .. area
			end
		end
		local area = inReservedArea(obb.cx, obb.cz, site)
		if area then
			return false, "reserved " .. area
		end
		for _, r in reserved do
			if WorldGen.obbOverlap(obb, r.obb, 4) then
				return false, "overlaps " .. r.what
			end
		end
		return true, nil
	end

	-- The run of same-named road through edge ei (continuing through junctions where exactly one edge carries the
	-- name on), up to ~900 studs each way: frontages are not cut at T junctions on the far side.
	type Chain = { pts: { P3 }, cum: { number }, seg: { number }, key: number }
	local chainOf: { [number]: Chain } = {}
	local function roadChain(ei: number): Chain
		local cached = chainOf[ei]
		if cached then
			return cached
		end
		local e0 = Edges[ei]
		local function walk(node: number, from: number, budget: number): { { any } }
			local out: { { any } } = {}
			local seen: { [number]: boolean } = { [from] = true }
			while budget > 0 do
				local nextE: number? = nil
				local count = 0
				for _, o in Nodes[node].edges do
					local oe = Edges[o]
					if not seen[o] and oe.name == e0.name and oe.layer == e0.layer then
						count += 1
						nextE = o
					end
				end
				if count ~= 1 then
					break
				end
				local o = nextE :: number
				seen[o] = true
				local oe = Edges[o]
				local fwd = oe.a == node
				table.insert(out, { o, fwd })
				budget -= oe.length
				node = if fwd then oe.b else oe.a
			end
			return out
		end
		local back = walk(e0.a, ei, 900)
		local ahead = walk(e0.b, ei, 900)
		local pts: { P3 } = {}
		local seg: { number } = {}
		local function push(edgeId: number, fwd: boolean)
			local ep = edgePts[edgeId].pts
			local n = #ep
			for k = 1, n do
				local p = if fwd then ep[k] else ep[n + 1 - k]
				if #pts == 0 or k > 1 then
					table.insert(pts, p)
					if #pts > 1 then
						table.insert(seg, edgeId)
					end
				end
			end
		end
		for i = #back, 1, -1 do
			push(back[i][1], not back[i][2])
		end
		push(ei, true)
		for _, it in ahead do
			push(it[1], it[2])
		end
		local key = ei
		for _, id in seg do
			key = math.min(key, id)
		end
		local chain: Chain = { pts = pts, cum = WorldGen.polyCum(pts), seg = seg, key = key }
		chainOf[ei] = chain
		return chain
	end

	-- Place a w x d footprint fronting a road near (x, z): the nearest allowed roads are tried in order, sliding along
	-- each (both sides) until the footprint is clear. Returns cframe, entrance, edge, obb, relief (nil cframe if none).
	local function placeOnFrontage(
		x: number,
		z: number,
		w: number,
		d: number,
		o: PlaceOpts?,
		label: string
	): (CFrame?, Vector3, number, OBB?, number)
		local opts: PlaceOpts = o or {}
		local classes = opts.classes or FRONTAGE_CLASSES
		local cands: { { number } } = {}
		local seen: { [number]: boolean } = {}
		WorldGen.segQuery(roadSegs, x, z, 900, function(id: number)
			local ei = roadSegs.owner[id]
			local e = Edges[ei]
			if
				seen[ei]
				or classes[e.class] ~= true
				or e.layer ~= 0
				or e.elevated
				or (opts.road ~= nil and e.name ~= opts.road)
			then
				return
			end
			seen[ei] = true
			local dist = WorldGen.polyProject(edgePts[ei].pts, x, z)
			table.insert(cands, { dist, ei })
		end)
		table.sort(cands, function(p: { number }, q: { number }): boolean
			if p[1] ~= q[1] then
				return p[1] < q[1]
			end
			return p[2] < q[2]
		end)
		local maxRelief = opts.maxRelief or 40
		local setback = opts.setback or 6
		local firstWhy: string? = nil
		local function try(
			ei: number,
			px: number,
			py: number,
			pz: number,
			tx: number,
			tz: number,
			nx: number,
			nz: number,
			frontDist: number,
			curb: number
		): (CFrame?, Vector3, OBB?, number)
			local cx, cz = px + nx * (frontDist + d / 2), pz + nz * (frontDist + d / 2)
			if opts.face then
				local face = opts.face :: { number }
				local doorX, doorZ = cx - nx * d / 2, cz - nz * d / 2
				local fx, fz = face[1] - doorX, face[2] - doorZ
				local fl = math.sqrt(fx * fx + fz * fz)
				local cosA = (-nx * fx - nz * fz) / math.max(fl, 1e-6)
				if cosA < math.cos(math.rad(opts.maxAngle or 40)) then
					firstWhy = firstWhy or "facing"
					return nil, Vector3.zero, nil, 0
				end
			end
			local obb: OBB = { cx = cx, cz = cz, ux = tx, uz = tz, hw = w / 2, hd = d / 2 }
			local clear, why = footprintClear(obb, opts.site)
			local rel = 0
			if clear then
				rel = relief(obb)
				if rel > maxRelief then
					clear, why = false, ("slope %.0f"):format(rel)
				end
			end
			if not clear then
				firstWhy = firstWhy or why
				return nil, Vector3.zero, nil, 0
			end
			local baseY = py + (if opts.curb then S.CURB_HEIGHT else 0)
			local center = Vector3.new(cx, baseY, cz)
			local cf = CFrame.lookAt(center, center + Vector3.new(-nx, 0, -nz))
			local entrance = Vector3.new(px + nx * curb, py, pz + nz * curb)
			if rel > 1.5 or math.abs(gradeAt(cx, cz) - baseY) > 1.5 then
				addPad(label, obb, baseY, 10, 60)
			end
			local _ = ei
			return cf, entrance, obb, rel
		end
		local triedChain: { [number]: boolean } = {}
		for ci = 1, math.min(#cands, if opts.face then 16 else 8) do
			local ei = cands[ci][2]
			local e = Edges[ei]
			if opts.atEnd then
				-- dead end: the end node with a single edge
				for _, endNode in { e.b, e.a } do
					if #Nodes[endNode].edges == 1 then
						local pts = edgePts[ei].pts
						local p, q
						if endNode == e.b then
							p, q = pts[#pts], pts[#pts - 1]
						else
							p, q = pts[1], pts[2]
						end
						local tx, tz = p.x - q.x, p.z - q.z
						local tl = math.sqrt(tx * tx + tz * tz)
						tx, tz = tx / tl, tz / tl
						local rx, rz = WorldGen.right(tx, tz)
						local cf, entrance, obb, rel = try(ei, p.x, p.y, p.z, rx, rz, tx, tz, setback, 0)
						if cf then
							return cf, entrance, ei, obb, rel
						end
					end
				end
				continue
			end
			local chain = roadChain(ei)
			if triedChain[chain.key] then
				continue
			end
			triedChain[chain.key] = true
			local L = chain.cum[#chain.cum]
			local _, s0 = WorldGen.polyProject(chain.pts, x, z)
			local lo, hi = w / 2 + 1, L - w / 2 - 1
			if hi < lo then
				continue
			end
			local px0, pz0, tx0, tz0 = WorldGen.polyAtCum(chain.pts, chain.cum, math.clamp(s0, lo, hi))
			local rx0, rz0 = WorldGen.right(tx0, tz0)
			local pref = opts.side or (if (x - px0) * rx0 + (z - pz0) * rz0 >= 0 then 1 else -1)
			for _, side in { pref, -pref } do
				for k = 0, 36 do
					local off = (if k % 2 == 1 then 1 else -1) * math.ceil(k / 2) * 30
					local s = s0 + off
					if s < lo or s > hi then
						continue
					end
					local px, pz, tx, tz, si, st = WorldGen.polyAtCum(chain.pts, chain.cum, s)
					local a, b = chain.pts[si], chain.pts[math.min(si + 1, #chain.pts)]
					local py = a.y + (b.y - a.y) * st
					local segEdge = chain.seg[math.min(si, #chain.seg)]
					local se = Edges[segEdge]
					if se.bridge then
						local _, es = WorldGen.polyProject(edgePts[segEdge].pts, px, pz)
						if onBridge(segEdge, es, w / 2 + 10) then
							continue
						end
					end
					local rx, rz = WorldGen.right(tx, tz)
					local nx, nz = rx * side, rz * side
					local curb = se.width / 2
					local cf, entrance, obb, rel =
						try(segEdge, px, py, pz, tx, tz, nx, nz, curb + se.sidewalk + setback, curb)
					if cf then
						return cf, entrance, segEdge, obb, rel
					end
				end
			end
		end
		table.insert(PlacementErrors, ("%s near %d, %d (%s)"):format(label, x, z, firstWhy or "no frontage"))
		return nil, Vector3.zero, 0, nil, 0
	end

	type POI = {
		id: string,
		name: string,
		kind: string,
		brand: string?,
		district: string,
		cframe: CFrame, -- footprint center at ground; LookVector faces the street (front door side)
		size: Vector3, -- X frontage width, Y height, Z depth
		entrance: Vector3, -- curb point in front of the door
		edge: number, -- frontage edge
		tags: { string },
	}

	local POIs: { POI } = {}
	local poiById: { [string]: POI } = {}

	type PoiDef = {
		id: string,
		name: string,
		kind: string,
		brand: string?,
		at: { number },
		size: { number }, -- w, h, d
		setback: number?,
		road: string?,
		tags: { string }?,
		face: { number }?,
		maxAngle: number?,
		maxRelief: number?,
		site: string?,
		atEnd: boolean?,
	}

	local function addPOI(def: PoiDef): POI?
		local cf, entrance, ei, obb = placeOnFrontage(def.at[1], def.at[2], def.size[1], def.size[3], {
			setback = def.setback,
			road = def.road,
			face = def.face,
			maxAngle = def.maxAngle,
			maxRelief = def.maxRelief,
			site = def.site,
			atEnd = def.atEnd,
		}, def.id)
		if not cf or not obb then
			return nil
		end
		local poi: POI = {
			id = def.id,
			name = def.name,
			kind = def.kind,
			brand = def.brand,
			district = districtAt(cf.Position.X, cf.Position.Z),
			cframe = cf,
			size = Vector3.new(def.size[1], def.size[2], def.size[3]),
			entrance = entrance,
			edge = ei,
			tags = def.tags or {},
		}
		table.insert(POIs, poi)
		poiById[def.id] = poi
		table.insert(reserved, { obb = obb, what = def.id })
		return poi
	end

	-- Pinnacle Tower stands at the centre of the tower plan; garage doors and the skyline tests aim at it.
	local PINNACLE = { 75, -430 }

	-- Plots (8 player garages) first: they get the best frontages. Doors face the core so the first frame from every
	-- garage (except Palmera, which faces the ocean) frames the skyline (gta critique 9); each is >= 1,000 road studs from
	-- every police entrance and inside the Active Core (gameplay critiques 1, 5, 8).
	type Plot = {
		index: number,
		name: string,
		district: string,
		cframe: CFrame, -- garage origin (v1 plot frame): ground centre at curb height, LookVector out of the door
		size: Vector3,
		door: Vector3,
		curbSpot: CFrame, -- right-hand curb spot just past the driveway (newbie car)
		edge: number,
		nearestOnRamp: number, -- straight-line studs to the closest on-ramp terminal
		onRampSeconds: number, -- time-weighted drive to the nearest on-ramp (filled in section 16)
		doorToPinnacle: number, -- degrees between the door heading and Pinnacle Tower
	}
	type PlotDef = { name: string, at: { number }, road: string?, face: { number }, maxAngle: number }
	local PLOT_DEFS: { PlotDef } = {
		{ name = "Palmera Garage", at = { -3960, -120 }, road = "Breaker Street", face = { -6000, -120 }, maxAngle = 30 },
		{ name = "Sunwood Garage", at = { -420, -2280 }, road = "Sunwood Boulevard", face = PINNACLE, maxAngle = 30 },
		{ name = "Pinnacle Garage", at = { 1320, 20 }, road = "Flower Street", face = PINNACLE, maxAngle = 30 },
		{ name = "Foundry Garage", at = { 2150, -760 }, road = "Riverside Drive", face = PINNACLE, maxAngle = 30 },
		{ name = "Rust Flats Garage", at = { 2420, 860 }, road = "Riverside Drive", face = PINNACLE, maxAngle = 38 },
		{ name = "Southgate East Garage", at = { 300, 1840 }, face = PINNACLE, maxAngle = 20 },
		{ name = "Southgate West Garage", at = { -1150, 1900 }, face = PINNACLE, maxAngle = 39 },
		{ name = "Midtown Garage", at = { -3000, 1000 }, face = PINNACLE, maxAngle = 30 },
	}
	local PLOT_W, PLOT_D = 140, 150
	local Plots: { Plot } = {}

	for i, def in PLOT_DEFS do
		local cf, entrance, ei, obb = placeOnFrontage(def.at[1], def.at[2], PLOT_W, PLOT_D, {
			setback = 14,
			road = def.road,
			classes = { street = true, avenue = true, boulevard = true },
			face = def.face,
			maxAngle = def.maxAngle,
			maxRelief = 120,
			curb = true,
		}, def.name)
		assert(cf and obb, "plot " .. def.name .. " found no frontage: " .. tostring(PlacementErrors[#PlacementErrors]))
		local look = cf.LookVector
		local door = cf.Position + look * (PLOT_D / 2)
		local rightOfStreet = Vector3.new(-look.Z, 0, look.X)
		local spot = entrance + look * (S.PARKING_LANE / 2 + 0.5) - rightOfStreet * (PLOT_W / 2 + 14)
		local tp = Vector3.new(PINNACLE[1], door.Y, PINNACLE[2]) - door
		local ang = math.deg(math.acos(math.clamp(tp.Unit:Dot(look), -1, 1)))
		table.insert(Plots, {
			index = i,
			name = def.name,
			district = districtAt(cf.Position.X, cf.Position.Z),
			cframe = cf,
			size = Vector3.new(PLOT_W, 40, PLOT_D),
			door = door,
			curbSpot = CFrame.lookAt(spot, spot + rightOfStreet),
			edge = ei,
			nearestOnRamp = 0,
			onRampSeconds = 0,
			doorToPinnacle = ang,
		})
		table.insert(reserved, { obb = obb, what = "plot" .. i })
	end

	-- POIs (parody brands of our own; never Rockstar names). at = rough position, snapped to a frontage.
	local POI_DEFS: { PoiDef } = {
		-- Hub / onboarding
		{
			id = "HotwirePlaza",
			name = "Hotwire Plaza",
			kind = "plaza",
			at = { 526, -400 },
			size = { 330, 0, 196 },
			road = "Crown Boulevard",
			setback = 0,
			site = "Hotwire Plaza",
			tags = { "events", "cashRain", "defaultSpawn" },
		},
		{
			id = "PinnacleTower",
			name = "Pinnacle Tower",
			kind = "landmark",
			at = PINNACLE,
			size = { 200, 760, 200 },
			road = "Crown Boulevard",
			setback = 10,
			site = "Pinnacle Tower",
			tags = { "tallest", "helipad", "skyline", "crown:spire" },
		},
		-- Cars
		{
			id = "Dealership",
			name = "Hotwire Motors",
			kind = "dealership",
			at = { -1700, 700 },
			size = { 220, 40, 170 },
			setback = 10,
			tags = { "showroom" },
		},
		{
			id = "LuxuryDealer",
			name = "Legendaire Autos",
			kind = "dealership",
			brand = "Legendaire",
			at = { -2650, -950 },
			size = { 200, 36, 150 },
			road = "Gilded Mile",
			setback = 10,
			tags = { "showroom", "luxury" },
		},
		{
			id = "UsedCars",
			name = "Second Gear Motors",
			kind = "dealership",
			-- no `brand`: a one-site lot, not a chain (Config/CityArt has no sign for it; the POI's text sign reads its name)
			at = { 2600, 300 },
			size = { 200, 24, 150 },
			setback = 8,
			tags = { "showroom", "used" },
		},
		{
			id = "CustomsRust",
			name = "Hotwire Customs",
			kind = "customs",
			brand = "Hotwire Customs",
			at = { 2600, 1700 },
			size = { 150, 30, 130 },
			setback = 12,
		},
		{
			id = "CustomsBeach",
			name = "Hotwire Customs Palmera",
			kind = "customs",
			brand = "Hotwire Customs",
			at = { -3950, 1250 },
			size = { 140, 30, 120 },
			setback = 12,
		},
		{
			id = "CustomsCactus",
			name = "Hotwire Customs Red Mesa",
			kind = "customs",
			brand = "Hotwire Customs",
			at = { 4600, -420 },
			size = { 130, 28, 110 },
			setback = 12,
		},
		{
			id = "SprayMidtown",
			name = "Fresh Coat Midtown",
			kind = "spray",
			brand = "Fresh Coat",
			at = { -2900, -500 },
			size = { 90, 26, 90 },
			setback = 8,
		},
		{
			id = "SpraySouthgate",
			name = "Fresh Coat Southgate",
			kind = "spray",
			brand = "Fresh Coat",
			at = { 800, 2650 },
			size = { 90, 26, 90 },
			setback = 8,
		},
		{
			id = "SprayFoundry",
			name = "Fresh Coat Foundry",
			kind = "spray",
			brand = "Fresh Coat",
			at = { 3000, -1250 },
			size = { 90, 26, 90 },
			setback = 8,
		},
		{
			id = "SprayHills",
			name = "Fresh Coat Sunwood",
			kind = "spray",
			brand = "Fresh Coat",
			at = { -1800, -2150 },
			size = { 90, 26, 90 },
			road = "Sunwood Boulevard",
			setback = 8,
		},
		{
			id = "SprayMesa",
			name = "Fresh Coat Coastside",
			kind = "spray",
			brand = "Fresh Coat",
			at = { 5450, 1700 },
			size = { 90, 26, 90 },
			road = "Coast Highway",
			setback = 20,
		},
		{
			id = "ChopShop",
			name = "Rusty's Chop Shop",
			kind = "chop",
			at = { 3300, 2150 },
			size = { 220, 30, 200 },
			setback = 16,
			tags = { "junkyard" },
		},
		{
			id = "ChopPort",
			name = "Dockside Salvage",
			kind = "chop",
			at = { 2300, 4250 },
			size = { 160, 28, 140 },
			road = "Terminal Way",
			setback = 16,
		},
		{
			id = "ChopSunwood",
			name = "Canyon Auto Salvage",
			kind = "chop",
			at = { -1300, -2000 },
			size = { 150, 26, 130 },
			road = "Sunwood Boulevard",
			setback = 12,
		},
		{
			id = "ChopAirport",
			name = "Runway Salvage",
			kind = "chop",
			at = { -2500, 2650 },
			size = { 160, 28, 140 },
			setback = 14,
		},
		-- Weapons
		{
			id = "GunSouthgate",
			name = "Lock & Load Southgate",
			kind = "gunshop",
			brand = "Lock & Load",
			at = { -600, 2350 },
			size = { 70, 22, 80 },
			setback = 4,
		},
		{
			id = "GunFoundry",
			name = "Lock & Load Foundry",
			kind = "gunshop",
			brand = "Lock & Load",
			at = { 2350, -300 },
			size = { 70, 22, 80 },
			setback = 4,
		},
		{
			id = "GunBeach",
			name = "Lock & Load Palmera",
			kind = "gunshop",
			brand = "Lock & Load",
			at = { -4150, 900 },
			size = { 70, 22, 80 },
			setback = 4,
		},
		{
			id = "GunCactus",
			name = "Lock & Load Red Mesa",
			kind = "gunshop",
			brand = "Lock & Load",
			at = { 4200, -680 },
			size = { 70, 22, 80 },
			setback = 6,
		},
		{
			id = "GunSunwood",
			name = "Lock & Load Sunwood",
			kind = "gunshop",
			brand = "Lock & Load",
			at = { -1200, -2150 },
			size = { 70, 22, 80 },
			road = "Sunwood Boulevard",
			setback = 4,
		},
		-- Money
		{
			id = "Bank",
			name = "Pinnacle Reserve Bank",
			kind = "bank",
			at = { -500, -250 },
			size = { 180, 160, 170 },
			road = "Crown Boulevard",
			setback = 10,
			tags = { "heist", "vault" },
		},
		{
			id = "BranchMidtown",
			name = "Coinstack Savings Midtown",
			kind = "bank_branch",
			brand = "Coinstack",
			at = { -2600, 320 },
			size = { 80, 26, 80 },
			tags = { "armoredStop", "robbable" },
		},
		{
			id = "BranchBeach",
			name = "Coinstack Savings Palmera",
			kind = "bank_branch",
			brand = "Coinstack",
			at = { -4100, 450 },
			size = { 80, 26, 80 },
			road = "Breaker Street",
			tags = { "armoredStop", "robbable" },
		},
		{
			id = "BranchSouthgate",
			name = "Coinstack Savings Southgate",
			kind = "bank_branch",
			brand = "Coinstack",
			at = { -1000, 1900 },
			size = { 80, 26, 80 },
			tags = { "armoredStop", "robbable" },
		},
		{
			id = "BranchFoundry",
			name = "Coinstack Savings Foundry",
			kind = "bank_branch",
			brand = "Coinstack",
			at = { 2650, -650 },
			size = { 80, 26, 80 },
			tags = { "armoredStop", "robbable" },
		},
		{
			id = "BranchCactus",
			name = "Coinstack Savings Red Mesa",
			kind = "bank_branch",
			brand = "Coinstack",
			at = { 4420, -450 },
			size = { 70, 22, 70 },
			tags = { "armoredStop", "robbable" },
		},
		{
			id = "BranchSunwood",
			name = "Coinstack Savings Sunwood",
			kind = "bank_branch",
			brand = "Coinstack",
			at = { -1500, -2150 },
			size = { 80, 26, 80 },
			road = "Sunwood Boulevard",
			tags = { "armoredStop", "robbable" },
		},
		{
			id = "Jewelry",
			name = "Glitter & Gold Jewelers",
			kind = "jewelry",
			at = { -2250, -680 },
			size = { 90, 40, 90 },
			road = "Gilded Mile",
			setback = 4,
			tags = { "heist", "robbable" },
		},
		{
			id = "ArmoredDepot",
			name = "Stackhouse Security Depot",
			kind = "armored_depot",
			at = { 2950, 1900 },
			size = { 220, 30, 180 },
			setback = 16,
			tags = { "armoredStart" },
		},
		-- Convenience stores (robbable)
		{
			id = "StoreSouthgate",
			name = "QuikStop 24 Southgate",
			kind = "convenience",
			brand = "QuikStop 24",
			at = { 100, 2600 },
			size = { 70, 18, 70 },
			tags = { "robbable" },
		},
		{
			id = "StoreBeach",
			name = "Sip-N-Go Palmera",
			kind = "convenience",
			brand = "Sip-N-Go",
			at = { -4200, 300 },
			size = { 70, 18, 70 },
			tags = { "robbable" },
		},
		{
			id = "StoreMidtown",
			name = "Lucky Mart Midtown",
			kind = "convenience",
			brand = "Lucky Mart",
			at = { -3200, -900 },
			size = { 70, 18, 70 },
			tags = { "robbable" },
		},
		{
			id = "StoreRust",
			name = "QuikStop 24 Rust Flats",
			kind = "convenience",
			brand = "QuikStop 24",
			at = { 2900, 2200 },
			size = { 70, 18, 70 },
			tags = { "robbable" },
		},
		{
			id = "StoreFoundry",
			name = "Sip-N-Go Foundry",
			kind = "convenience",
			brand = "Sip-N-Go",
			at = { 2300, -1500 },
			size = { 70, 18, 70 },
			tags = { "robbable" },
		},
		{
			id = "StoreCactus",
			name = "Lucky Mart Red Mesa",
			kind = "convenience",
			brand = "Lucky Mart",
			at = { 4150, -400 },
			size = { 70, 18, 70 },
			tags = { "robbable" },
		},
		{
			id = "StoreHills",
			name = "QuikStop 24 Sunwood",
			kind = "convenience",
			brand = "QuikStop 24",
			at = { -850, -2150 },
			size = { 70, 18, 70 },
			road = "Sunwood Boulevard",
			tags = { "robbable" },
		},
		{
			id = "StoreDowntown",
			name = "Sip-N-Go Pinnacle",
			kind = "convenience",
			brand = "Sip-N-Go",
			at = { 900, 900 },
			size = { 60, 18, 60 },
			tags = { "robbable" },
		},
		-- Gas stations (robbable kiosk, fuel = cosmetic for now)
		{
			id = "GasMidtown",
			name = "Petrolux Midtown",
			kind = "gas",
			brand = "Petrolux",
			at = { -1700, 1000 },
			size = { 140, 20, 120 },
			setback = 4,
		},
		{
			id = "GasSouthgate",
			name = "Sunburst Gas Southgate",
			kind = "gas",
			brand = "Sunburst",
			at = { -2200, 2700 },
			size = { 140, 20, 120 },
			setback = 4,
		},
		{
			id = "GasFoundry",
			name = "Petrolux Foundry",
			kind = "gas",
			brand = "Petrolux",
			at = { 3100, -1650 },
			size = { 140, 20, 120 },
			setback = 4,
		},
		{
			id = "GasRust",
			name = "Sunburst Gas Rust Flats",
			kind = "gas",
			brand = "Sunburst",
			at = { 3350, 700 },
			size = { 140, 20, 120 },
			setback = 4,
		},
		{
			id = "GasBeach",
			name = "Petrolux Palmera",
			kind = "gas",
			brand = "Petrolux",
			at = { -4250, 1450 },
			size = { 140, 20, 120 },
			setback = 4,
		},
		{
			id = "GasCoastNorth",
			name = "Sunburst Gas Hidden Cove",
			kind = "gas",
			brand = "Sunburst",
			at = { -2300, -3900 },
			size = { 140, 20, 120 },
			road = "Coast Highway",
			setback = 20,
		},
		{
			id = "GasRedMesa",
			name = "Petrolux Red Mesa",
			kind = "gas",
			brand = "Petrolux",
			at = { 5100, -500 },
			size = { 140, 20, 120 },
			road = "Red Mesa Road",
			setback = 20,
		},
		{
			id = "GasCoastEast",
			name = "Sunburst Gas Dustbowl",
			kind = "gas",
			brand = "Sunburst",
			at = { 5150, 2750 },
			size = { 140, 20, 120 },
			road = "Coast Highway",
			setback = 20,
		},
		{
			id = "GasCactus",
			name = "Fuel Rush Cactus Junction",
			kind = "gas",
			brand = "Fuel Rush",
			at = { 4600, -620 },
			size = { 120, 20, 110 },
			setback = 6,
		},
		-- Police (HCPD). Stations sit >= 1,000 road studs from every garage door.
		{
			id = "PoliceHQ",
			name = "HCPD Headquarters",
			kind = "police",
			at = { -700, 350 },
			size = { 206, 90, 170 },
			setback = 10,
			tags = { "policeSpawn", "jail", "bustedRelease", "helipad" },
		},
		{
			id = "PoliceBeach",
			name = "HCPD Palmera Precinct",
			kind = "police",
			at = { -4000, -1350 },
			size = { 120, 34, 110 },
			tags = { "policeSpawn" },
		},
		{
			id = "PoliceSouthgate",
			name = "HCPD Southgate Precinct",
			kind = "police",
			at = { -650, 2750 },
			size = { 120, 34, 110 },
			tags = { "policeSpawn" },
		},
		{
			id = "PoliceHills",
			name = "HCPD Sunwood Precinct",
			kind = "police",
			at = { -2700, -2200 },
			size = { 120, 34, 110 },
			road = "Sunwood Boulevard",
			tags = { "policeSpawn" },
		},
		{
			id = "PoliceFoundry",
			name = "HCPD Eastside Precinct",
			kind = "police",
			at = { 3300, 500 },
			size = { 120, 34, 110 },
			tags = { "policeSpawn" },
		},
		{
			id = "PoliceSheriff",
			name = "Red Mesa Sheriff",
			kind = "police",
			at = { 4400, -250 },
			size = { 110, 26, 100 },
			tags = { "policeSpawn" },
		},
		{
			id = "PolicePort",
			name = "Port Authority Police",
			kind = "police",
			at = { 1500, 3650 },
			size = { 120, 30, 100 },
			road = "Terminal Way",
			tags = { "policeSpawn" },
		},
		{
			id = "PoliceAirport",
			name = "Airport Police",
			kind = "police",
			at = { -3700, 2050 },
			size = { 110, 30, 100 },
			road = "Terminal Drive",
			tags = { "policeSpawn" },
		},
		-- Hospitals (WASTED respawn)
		{
			id = "HospitalCentral",
			name = "Mount Mercy Medical Center",
			kind = "hospital",
			at = { 1000, -900 },
			size = { 160, 150, 200 },
			setback = 12,
			tags = { "respawn", "helipad" },
		},
		{
			id = "HospitalSouthgate",
			name = "Southgate Community Hospital",
			kind = "hospital",
			at = { -1500, 2650 },
			size = { 200, 70, 160 },
			setback = 12,
			tags = { "respawn" },
		},
		{
			id = "HospitalBeach",
			name = "Palmera Beach Clinic",
			kind = "hospital",
			at = { -4150, -1800 },
			size = { 140, 50, 120 },
			setback = 10,
			tags = { "respawn" },
		},
		{
			id = "HospitalMesa",
			name = "Red Mesa Medical",
			kind = "hospital",
			at = { 4100, -820 },
			size = { 120, 30, 110 },
			setback = 10,
			tags = { "respawn" },
		},
		{
			id = "HospitalFoundry",
			name = "Foundry Urgent Care",
			kind = "hospital",
			at = { 2700, -1500 },
			size = { 140, 50, 120 },
			setback = 10,
			tags = { "respawn" },
		},
		-- Landmark buildings with a frontage
		{
			id = "CityHall",
			name = "Hotwire City Hall",
			kind = "city_hall",
			at = { 80, 780 },
			size = { 220, 380, 170 },
			road = "Mission Avenue",
			setback = 6,
			site = "City Hall",
			tags = { "skyline", "crown:pyramid", "civic" },
		},
		{
			id = "Casino",
			name = "Lucky Seven Casino",
			kind = "landmark",
			at = { -2700, -700 },
			size = { 190, 120, 150 },
			setback = 12,
			tags = { "futureHeist" },
		},
		{
			id = "Arena",
			name = "Iron Bay Arena",
			kind = "landmark",
			at = { 1240, 2450 },
			road = "Southgate Avenue",
			size = { 320, 60, 300 },
			setback = 30,
			site = "Iron Bay Arena",
		},
		{
			id = "Theater",
			name = "Starlight Theater",
			kind = "theater",
			at = { -2050, -2150 },
			size = { 120, 50, 140 },
			road = "Sunwood Boulevard",
			setback = 2,
			tags = { "marquee", "billboards" },
		},
		{
			id = "ParkingDeck",
			name = "Crown Street Parking",
			kind = "parking_garage",
			at = { -900, -420 },
			size = { 150, 48, 150 },
			road = "Crown Boulevard",
			setback = 6,
			tags = { "stuntRoof" },
		},
		{
			id = "Observatory",
			name = "Starview Observatory",
			kind = "landmark",
			at = { -520, -3080 },
			size = { 160, 50, 120 },
			road = "Starview Road",
			setback = 20,
			maxRelief = 80,
			tags = { "lookout" },
		},
		{
			id = "Museum",
			name = "Vantage Museum",
			kind = "museum",
			at = { -3300, -2950 },
			size = { 300, 50, 200 },
			road = "Museum Drive",
			setback = 30,
			atEnd = true,
			maxRelief = 120,
			tags = { "lookout", "pad" },
		},
		{
			id = "CountryClub",
			name = "Sunwood Country Club",
			kind = "golf_club",
			at = { -3950, -2280 },
			size = { 160, 30, 120 },
			road = "Sunwood Boulevard",
			setback = 20,
			maxRelief = 80,
			tags = { "golf" },
		},
		{
			id = "Prison",
			name = "Red Mesa State Prison",
			kind = "prison",
			at = { 4500, 1400 },
			size = { 900, 40, 700 },
			road = "Dustbowl Road",
			setback = 40,
			maxRelief = 30,
			tags = { "jailbreak", "guardTowers", "restricted" },
		},
		{
			id = "Motel",
			name = "Sleepy Cactus Motel",
			kind = "motel",
			at = { 3980, -560 },
			size = { 160, 22, 90 },
			road = "Red Mesa Road",
			setback = 16,
		},
		{
			id = "Diner",
			name = "Rattlesnake Diner",
			kind = "diner",
			at = { 4560, -520 },
			size = { 70, 18, 60 },
			road = "Red Mesa Road",
			setback = 12,
		},
		{
			id = "Terminal",
			name = "HCI Terminal",
			kind = "airport_terminal",
			at = { -4100, 2700 },
			size = { 900, 70, 250 },
			road = "Terminal Drive",
			setback = 52,
			face = { -4100, 1800 },
			maxAngle = 10,
			tags = { "rareSpawns", "twoLevelDropoff" },
		},
		{
			id = "PortOffice",
			name = "Iron Bay Harbor Master",
			kind = "port_office",
			at = { -900, 3620 },
			size = { 120, 40, 100 },
			road = "Terminal Way",
			setback = 10,
		},
		{
			id = "MuscleBeach",
			name = "Muscle Beach Gym",
			kind = "gym",
			at = { -4520, 100 },
			size = { 120, 6, 90 },
			road = "Palmera Drive",
			setback = 4,
		},
	}
	for _, def in POI_DEFS do
		addPOI(def)
	end

	-- On-ramp terminals (ground end of every on-ramp) for the plots' escape-route metric.
	local onRampTerminals: { Vector3 } = {}
	for _, e in Edges do
		if e.class == "ramp" and math.abs(e.points[1].Y - gradeAt(e.points[1].X, e.points[1].Z)) < 3 then
			table.insert(onRampTerminals, e.points[1])
		end
	end
	for _, plot in Plots do
		local best = math.huge
		for _, p in onRampTerminals do
			best = math.min(best, (Vector3.new(p.X, 0, p.Z) - Vector3.new(plot.door.X, 0, plot.door.Z)).Magnitude)
		end
		plot.nearestOnRamp = best
	end

	WorldLayout.POIs = POIs
	WorldLayout.Plots = Plots

	---------------------------------------------------------------------------------------------------------------------
	-- 13. Tower plan + parcels (lots)
	---------------------------------------------------------------------------------------------------------------------

	type Parcel = {
		id: number,
		district: string,
		subzone: string?,
		use: string,
		cframe: CFrame, -- ground centre (Y = street level at the frontage), LookVector faces the street
		size: Vector3, -- X frontage width, Y height (0 = open lot), Z depth
		floors: number,
		edge: number,
		style: string,
		seed: number,
		tower: boolean?, -- part of the tower plan (skyline)
		podium: { number }?, -- { height, tower setback } for planned towers
		crown: string?, -- spire | slant | stepped | helipad | lit_band | machinery | flat
		stilts: boolean?, -- hills: the lot falls away from the street (house on stilts / cantilevered)
	}
	local Parcels: { Parcel } = {}

	local PCELL = 160
	local parcelCells: { [number]: { number } } = {}
	local parcelObbs: { OBB } = {}
	local function obbBounds(b: OBB): (number, number, number, number)
		local r = math.sqrt(b.hw * b.hw + b.hd * b.hd)
		return b.cx - r, b.cz - r, b.cx + r, b.cz + r
	end
	local function overlapsAny(b: OBB, margin: number): boolean
		local x0, z0, x1, z1 = obbBounds(b)
		for cx = math.floor(x0 / PCELL), math.floor(x1 / PCELL) do
			for cz = math.floor(z0 / PCELL), math.floor(z1 / PCELL) do
				local list = parcelCells[WorldGen.cellKey(cx, cz)]
				if list then
					for _, id in list do
						if WorldGen.obbOverlap(b, parcelObbs[id], margin) then
							return true
						end
					end
				end
			end
		end
		return false
	end
	local function insertObb(b: OBB): number
		table.insert(parcelObbs, b)
		local id = #parcelObbs
		local x0, z0, x1, z1 = obbBounds(b)
		WorldGen.hashBox(parcelCells, PCELL, x0, z0, x1, z1, id)
		return id
	end
	for _, r in reserved do
		insertObb(r.obb)
	end

	-- Open areas that never get lots: every reserved area (parks, plazas, hero sites, rail yard, golf, channel) plus the
	-- palm park / sand west of Palmera Drive, the airfield and the container terminal interior (yards placed below).
	local NO_LOTS: { { P2 } } = {}
	for _, area in WorldLayout.ReservedAreas do
		table.insert(NO_LOTS, area.poly)
	end
	table.insert(NO_LOTS, poly({ { -6000, -2400 }, { -4560, -2400 }, { -4560, 1720 }, { -6000, 1720 } }))
	table.insert(NO_LOTS, poly({ { -6000, 3100 }, { -2400, 3100 }, { -2400, 4500 }, { -6000, 4500 } }))
	table.insert(NO_LOTS, poly({ { -1800, 3540 }, { 2900, 3540 }, { 2900, 4500 }, { -1800, 4500 } }))
	local noLotBoxes: { { number } } = {}
	for i, area in NO_LOTS do
		local x0, z0, x1, z1 = WorldGen.polyBounds(area)
		noLotBoxes[i] = { x0, z0, x1, z1 }
	end
	local function inNoLot(x: number, z: number): boolean
		for ai, area in NO_LOTS do
			local bb = noLotBoxes[ai]
			if x >= bb[1] and x <= bb[3] and z >= bb[2] and z <= bb[4] and WorldGen.pointInPoly(area, x, z) then
				return true
			end
		end
		return false
	end

	local OPEN_USES: { [string]: boolean } =
		{ plaza = true, parking_lot = true, park = true, yard = true, container_yard = true }
	local LOW_USES: { [string]: number } = {
		retail = 26,
		restaurant = 22,
		corner_store = 18,
		retail_strip = 20,
		house = 24,
		duplex = 28,
		church = 40,
		shop = 18,
		diner = 16,
		motel = 24,
		shed = 18,
		barn = 30,
		farmhouse = 24,
		gallery = 30,
		brewery = 34,
		nightclub = 34,
		theater = 46,
		mansion = 34,
		villa = 30,
		warehouse = 40,
		factory = 56,
		hangar = 50,
		parking_garage = 48,
		civic = 60,
	}
	local function useWeights(uses: { { any } }, r: number): string
		local total = 0
		for _, u in uses do
			total += u[2]
		end
		local acc = 0
		for _, u in uses do
			acc += u[2] / total
			if r <= acc then
				return u[1]
			end
		end
		return uses[#uses][1]
	end

	-- Planned towers: Pinnacle (POI, 760) + 3 at 560-650, 8 at 380-520 and 20 at 220-350 within 650 of (150, -300);
	-- Palmera North condo towers; the Gilded Mile x Crown hotel cluster (gta critique 1). Footprints >= 160 x 160 on
	-- 40-70 podiums with a 10-20 tower setback, each with a crown so the top 12 read differently against the sky.
	local CROWNS = { "spire", "slant", "stepped", "helipad", "lit_band", "machinery" }
	type Cluster = {
		id: string,
		center: { number },
		radius: number,
		box: { number }?,
		outer: number?, -- the 220-350 group may spill to this radius (whole half-blocks are scarce inside the core)
		heights: { number },
		uses: { string },
		minW: number,
	}
	local function spread(n: number, lo: number, hi: number, seed: number): { number }
		local out: { number } = {}
		for i = 1, n do
			local t = if n == 1 then 0.5 else (i - 1) / (n - 1)
			local j = (WorldGen.hash(i, seed, 401) - 0.5) * (hi - lo) / math.max(n, 2) * 0.8
			table.insert(out, math.floor(hi - (hi - lo) * t + j + 0.5))
		end
		return out
	end
	local CLUSTERS: { Cluster } = {
		{
			id = "core",
			center = { 150, -300 },
			radius = 650,
			outer = 900,
			heights = (function(): { number }
				local h: { number } = {}
				for _, list in { spread(3, 560, 650, 1), spread(8, 380, 520, 2), spread(20, 220, 350, 3) } do
					for _, v in list do
						table.insert(h, v)
					end
				end
				return h
			end)(),
			uses = { "office_tower", "office_tower", "residential_tower", "hotel", "office_tower" },
			minW = 160,
		},
		{
			id = "palmera_north",
			center = { -4100, -1580 },
			radius = 520,
			box = { -4350, -2000, -3850, -1150 },
			heights = spread(5, 220, 360, 4),
			uses = { "residential_tower" },
			minW = 160,
		},
		{
			id = "gilded",
			center = { -1960, -300 },
			radius = 480,
			outer = 650,
			heights = spread(5, 260, 380, 5),
			uses = { "hotel", "residential_tower", "office_tower" },
			minW = 160,
		},
	}
	local TowerPlan: { { any } } = {}
	local pinnacle = poiById.PinnacleTower
	if pinnacle then
		table.insert(TowerPlan, {
			id = "PinnacleTower",
			cluster = "core",
			height = pinnacle.size.Y,
			pos = pinnacle.cframe.Position,
			crown = "spire",
		})
	end
	do
		local seqT = 0
		for _, cl in CLUSTERS do
			-- candidate footprints: every frontage slot in the cluster, 3 widths, depth to the next road behind
			type Cand = { obb: OBB, cf: CFrame, edge: number, dist: number, w: number, d: number }
			local cands: { Cand } = {}
			local cx0, cz0 = cl.center[1], cl.center[2]
			for ei, e in Edges do
				if
					e.layer ~= 0
					or e.elevated
					or not (e.class == "boulevard" or e.class == "avenue" or e.class == "street")
				then
					continue
				end
				local pts = edgePts[ei].pts
				local near = false
				for _, p in pts do
					if WorldGen.dist(p.x, p.z, cx0, cz0) < (cl.outer or cl.radius) + 150 then
						near = true
						break
					end
				end
				if not near then
					continue
				end
				local ra = endClear(ei, e.a) + 4
				local rb = endClear(ei, e.b) + 4
				local s = ra + cl.minW / 2
				while s <= e.length - rb - cl.minW / 2 do
					local px, py, pz, tx, tz = edgeAt(ei, s)
					local rx, rz = WorldGen.right(tx, tz)
					for _, side in { 1, -1 } do
						local nx, nz = rx * side, rz * side
						local front = e.width / 2 + e.sidewalk + 4
						for _, wd in { { 200, 220 }, { 200, 190 }, { 180, 190 }, { 180, 165 }, { 160, 165 }, { 160, 160 } } do
							local w, d = wd[1], wd[2]
							local ccx, ccz = px + nx * (front + d / 2), pz + nz * (front + d / 2)
							local dist = WorldGen.dist(ccx, ccz, cx0, cz0)
							if dist > (cl.outer or cl.radius) then
								continue
							end
							if cl.box then
								local bx = cl.box :: { number }
								if ccx < bx[1] or ccx > bx[3] or ccz < bx[2] or ccz > bx[4] then
									continue
								end
							end
							local obb: OBB = { cx = ccx, cz = ccz, ux = tx, uz = tz, hw = w / 2, hd = d / 2 }
							local inset: OBB = { cx = ccx, cz = ccz, ux = tx, uz = tz, hw = w / 2 - 1.5, hd = d / 2 - 1.5 }
							if roadHit(inset, 0.5) or deckOver(obb, 8) or inNoLot(ccx, ccz) then
								continue
							end
							local center = Vector3.new(ccx, py, ccz)
							table.insert(cands, {
								obb = obb,
								cf = CFrame.lookAt(center, center + Vector3.new(-nx, 0, -nz)),
								edge = ei,
								dist = dist,
								w = w,
								d = d,
							})
						end
					end
					s += 10
				end
			end
			-- tallest first, each at the free candidate closest to its target ring (tallest nearest the centre)
			local n = #cl.heights
			for i, h in cl.heights do
				local target = cl.radius * 0.85 * math.sqrt((i - 0.5) / n)
				local best: Cand? = nil
				local bestScore = math.huge
				local slim = h < 360 -- the 220-350 group packs on 160 x 160-165 sites; taller towers take the big ones
				for _, c in cands do
					if (slim and c.w > 160) or (not slim and c.dist > cl.radius) then
						continue
					end
					local score = math.abs(c.dist - target) - (if slim then 0 else (c.w + c.d) * 0.15)
					if score < bestScore and not overlapsAny(c.obb, 8) then
						bestScore = score
						best = c
					end
				end
				if not best then
					table.insert(PlacementErrors, ("tower %s #%d (%d): no site"):format(cl.id, i, h))
					continue
				end
				local c = best :: Cand
				insertObb(c.obb)
				table.insert(reserved, { obb = c.obb, what = "tower " .. cl.id .. i })
				seqT += 1
				local did = districtAt(c.obb.cx, c.obb.cz)
				local sz = subzoneAt(c.obb.cx, c.obb.cz)
				local use = cl.uses[(i - 1) % #cl.uses + 1]
				local rank = #TowerPlan + 1
				local crown = if rank <= 12
					then CROWNS[(rank - 1) % #CROWNS + 1]
					else (if WorldGen.hash(i, seqT, 403) < 0.5 then "machinery" else "flat")
				local podiumH = 40 + math.floor(30 * WorldGen.hash(i, seqT, 404))
				local setback = 10 + math.floor(10 * WorldGen.hash(i, seqT, 405))
				local style = if sz and sz.style then sz.style else districtById[did].style
				table.insert(Parcels, {
					id = #Parcels + 1,
					district = did,
					subzone = sz and sz.id or nil,
					use = use,
					cframe = c.cf,
					size = Vector3.new(c.w, h, c.d),
					floors = math.floor(h / S.STOREY),
					edge = c.edge,
					style = style,
					seed = math.floor(WorldGen.hash(seqT, 7, 406) * 2 ^ 31),
					tower = true,
					podium = { podiumH, setback },
					crown = crown,
				})
				table.insert(TowerPlan, {
					id = cl.id .. "_" .. i,
					cluster = cl.id,
					height = h,
					pos = c.cf.Position,
					crown = crown,
					parcel = #Parcels,
				})
			end
		end
	end
	WorldLayout.TowerPlan = TowerPlan

	local LOT_CLASSES: { [string]: number } = { boulevard = 1, avenue = 2, street = 3, rural = 4 }
	local FILL: { [string]: boolean } = { downtown = true, midtown = true, beach = true, foundry = true }
	local LOT_GAP: { [string]: number } = {
		downtown = 2,
		midtown = 3,
		beach = 4,
		foundry = 3,
		southgate = 8,
		rust = 18,
		hills = 22,
		port = 20,
		airport = 30,
		cactus = 10,
		driftwood = 10,
		mesa = 160,
	}
	local FLAT_DISTRICT: { [string]: boolean } = {
		downtown = true,
		midtown = true,
		beach = true,
		foundry = true,
		rust = true,
		southgate = true,
		port = true,
		airport = true,
	}

	-- Distance from a lot's front face along the inward normal to the next road footprint behind it (capped).
	local function backDistance(fx: number, fz: number, nx: number, nz: number, cap: number): number
		local d = 12
		while d < cap do
			if roadClearance(fx + nx * d, fz + nz * d, 1) then
				local lo = d - 12
				while d - lo > 3 do
					local mid = (lo + d) / 2
					if roadClearance(fx + nx * mid, fz + nz * mid, 1) then
						d = mid
					else
						lo = mid
					end
				end
				return d
			end
			d += 12
		end
		return cap
	end

	-- Style of a lot: its sub-zone's (or district's), dithered with the neighbour's within 200 studs of a border so
	-- styles blend over ~400-stud bands instead of switching at a line (gta critique 8).
	local function zoneKey(x: number, z: number): (string, any)
		local sz = subzoneAt(x, z)
		local did = districtAt(x, z)
		return did .. "/" .. (if sz then sz.id else ""), sz
	end
	local function styleRules(x: number, z: number, seq: number): (any, any, boolean)
		local key, sz = zoneKey(x, z)
		local did = districtAt(x, z)
		for _, r in { 100, 200 } do
			for _, o in { { r, 0 }, { -r, 0 }, { 0, r }, { 0, -r } } do
				local nk, nsz = zoneKey(x + o[1], z + o[2])
				if nk ~= key then
					local p = if r == 100 then 0.4 else 0.2
					if WorldGen.hash(seq, math.floor(x), 410) < p then
						return districtById[districtAt(x + o[1], z + o[2])], nsz, true
					end
					return districtById[did], sz, false
				end
			end
		end
		return districtById[did], sz, false
	end

	local function parcelHeight(rangeH: { number }, peak: any, use: string, x: number, z: number, r: number): number
		if OPEN_USES[use] then
			return 0
		end
		local lowH = LOW_USES[use]
		if lowH then
			return math.floor(lowH * (0.85 + 0.4 * r))
		end
		local h0, h1 = rangeH[1], rangeH[2]
		local f = r
		if peak then
			local d = WorldGen.dist(x, z, peak[1], peak[2])
			local near = 1 - math.clamp(d / peak[3], 0, 1)
			f = math.clamp(near * near * (0.55 + 0.45 * r) + 0.12 * r, 0, 1)
		end
		if use == "hotel" or use == "beach_hotel" then
			f = math.max(f, 0.35)
		end
		return math.floor(h0 + (h1 - h0) * f)
	end

	local LotsUnderDecks = 0
	do
		local seq = #Parcels
		local order: { number } = {}
		for ei, e in Edges do
			if LOT_CLASSES[e.class] and e.layer == 0 and not e.elevated then
				table.insert(order, ei)
			end
		end
		table.sort(order, function(a: number, b: number): boolean
			local ra, rb = LOT_CLASSES[Edges[a].class], LOT_CLASSES[Edges[b].class]
			if ra ~= rb then
				return ra < rb
			end
			return a < b
		end)

		local function tryPlace(
			ei: number,
			did: string,
			cs: number,
			side: number,
			width: number,
			depth: number,
			setback: number,
			useRule: { { any } },
			heightRange: { number },
			peak: any,
			style: string,
			szId: string?
		): boolean
			local e = Edges[ei]
			if e.bridge and onBridge(ei, cs, width / 2 + 10) then
				return false
			end
			local px, py, pz, tx, tz = edgeAt(ei, cs)
			local rx, rz = WorldGen.right(tx, tz)
			local nx, nz = rx * side, rz * side
			local front = e.width / 2 + e.sidewalk + setback
			local cx, cz = px + nx * (front + depth / 2), pz + nz * (front + depth / 2)
			local obb: OBB = { cx = cx, cz = cz, ux = tx, uz = tz, hw = width / 2, hd = depth / 2 }
			if overlapsAny(obb, 1) or districtAt(cx, cz) ~= did then
				return false
			end
			local inset: OBB = { cx = cx, cz = cz, ux = tx, uz = tz, hw = width / 2 - 1.5, hd = depth / 2 - 1.5 }
			if roadHit(inset, 0.5) then
				return false
			end
			for _, c in WorldGen.obbCorners(obb) do
				if not landAtLeast(c.x, c.z, 30) or inNoLot(c.x, c.z) then
					return false
				end
			end
			if inNoLot(cx, cz) then
				return false
			end
			local stilts = false
			if not FLAT_DISTRICT[did] then
				local rel, lo = relief(obb)
				if rel > 46 then
					return false
				end
				-- hills: ground falling away behind the frontage -> stilts / cantilever
				if did == "hills" and rel > 14 then
					local back = gradeAt(cx + nx * depth / 2, cz + nz * depth / 2)
					stilts = back < py - 8
				end
				local _ = lo
			end
			seq += 1
			local use = useWeights(useRule, WorldGen.hash(seq, ei, 77))
			-- gta critique 10: nothing but open lots under a deck (+8 margin); buildings would pierce it and the
			-- deck needs pier sites
			if deckOver(obb, 8) then
				if not OPEN_USES[use] then
					LotsUnderDecks += 1
					use = "parking_lot"
				end
			end
			local height = parcelHeight(heightRange, peak, use, cx, cz, WorldGen.hash(seq, 5, 78))
			local center = Vector3.new(cx, py, cz)
			insertObb(obb)
			table.insert(Parcels, {
				id = #Parcels + 1,
				district = did,
				subzone = szId,
				use = use,
				cframe = CFrame.lookAt(center, center + Vector3.new(-nx, 0, -nz)),
				size = Vector3.new(width, height, depth),
				floors = if height > 0 then math.max(1, math.floor(height / S.STOREY)) else 0,
				edge = ei,
				style = style,
				seed = math.floor(WorldGen.hash(seq, 3, 79) * 2 ^ 31),
				stilts = if stilts then true else nil,
			})
			return true
		end

		for _, ei in order do
			local e = Edges[ei]
			for sideIdx, side in { 1, -1 } do
				local s0 = endClear(ei, e.a) + 2
				local s1 = e.length - endClear(ei, e.b) - 2
				local F = s1 - s0
				if F < 40 then
					continue
				end
				local mx, _, mz, mtx, mtz = edgeAt(ei, (s0 + s1) / 2)
				local mrx, mrz = WorldGen.right(mtx, mtz)
				local probe = e.width / 2 + e.sidewalk + 40
				local qx, qz = mx + mrx * side * probe, mz + mrz * side * probe
				local did = districtAt(qx, qz)
				local dist, sz, blended = styleRules(qx, qz, ei * 2 + sideIdx)
				local rule = dist.lot
				if e.class == "rural" and not (did == "hills" or did == "mesa" or did == "cactus") then
					continue
				end
				local width = (sz and sz.width) or rule.width
				local setbackR = (sz and sz.setback) or rule.setback
				local uses = (sz and sz.uses) or rule.uses
				local heightR = (sz and sz.height) or dist.height
				local style = (sz and sz.style) or dist.style
				local szId = if sz then sz.id else nil
				local _ = blended
				local gap = LOT_GAP[did] or 6
				local avg = (width[1] + width[2]) / 2
				local n = math.max(1, math.floor((F + gap) / (avg + gap) + 0.5))
				local weights: { number } = {}
				local wsum = 0
				for k = 1, n do
					local r = 0.75 + 0.5 * WorldGen.hash(ei * 2 + sideIdx, k, 9001)
					weights[k] = r
					wsum += r
				end
				local usable = F - gap * (n - 1)
				if usable / n < width[1] * 0.55 then
					continue
				end
				local s = s0
				for k = 1, n do
					local wdt = usable * weights[k] / wsum
					local cs = s + wdt / 2
					s += wdt + gap
					local h2 = WorldGen.hash(ei, k, 9002 + sideIdx)
					if h2 > rule.density then
						continue
					end
					local h3 = WorldGen.hash(ei, k, 9003 + sideIdx)
					local setback = setbackR[1] + (setbackR[2] - setbackR[1]) * h3
					local px, _, pz, tx, tz = edgeAt(ei, cs)
					local rx, rz = WorldGen.right(tx, tz)
					local nx, nz = rx * side, rz * side
					local front = e.width / 2 + e.sidewalk + setback
					local back = backDistance(px + nx * front, pz + nz * front, nx, nz, rule.depth[2] * 2 + 60)
					local base = rule.depth[1] + (rule.depth[2] - rule.depth[1]) * h2
					local depth
					if FILL[did] then
						depth = math.clamp(back / 2 - 3, rule.depth[1] * 0.55, rule.depth[2] * 1.5)
					else
						depth = math.min(base, back / 2 - 3)
					end
					if depth < rule.depth[1] * 0.45 then
						continue
					end
					local function tp(c: number, w: number, d: number): boolean
						return tryPlace(ei, did, c, side, w, d, setback, uses, heightR, dist.peak, style, szId)
					end
					local placed = tp(cs, wdt, depth) or tp(cs, wdt, depth * 0.7) or tp(cs, wdt, depth * 0.5)
					if not placed and wdt > width[1] * 1.1 then
						local half = wdt * 0.55
						placed = tp(cs + (wdt - half) / 2, half, depth)
							or tp(cs - (wdt - half) / 2, half, depth)
							or tp(cs + (wdt - half) / 2, half, depth * 0.6)
							or tp(cs - (wdt - half) / 2, half, depth * 0.6)
					end
				end
			end
		end
	end
	WorldLayout.LotsUnderDecks = LotsUnderDecks

	-- Port container yards + warehouses (two rows inside the terminal), airport hangars along Hangar Road and the
	-- terminal parking structures inside the Terminal Drive loop (gta critique 11).
	do
		local seq = #Parcels
		local function add(did: string, use: string, x: number, z: number, w: number, d: number, h: number, yaw: number)
			local center = Vector3.new(x, gradeAt(x, z), z)
			local cf = CFrame.new(center) * CFrame.Angles(0, math.rad(yaw), 0)
			local ux, uz = cf.RightVector.X, cf.RightVector.Z
			local obb: OBB = { cx = x, cz = z, ux = ux, uz = uz, hw = w / 2, hd = d / 2 }
			for _, c in WorldGen.obbCorners(obb) do
				if not landAtLeast(c.x, c.z, 30) then
					return
				end
			end
			if roadHit(obb, 2) or overlapsAny(obb, 3) then
				return
			end
			if deckOver(obb, 8) and not OPEN_USES[use] then
				return
			end
			insertObb(obb)
			seq += 1
			table.insert(Parcels, {
				id = #Parcels + 1,
				district = did,
				use = use,
				cframe = cf,
				size = Vector3.new(w, h, d),
				floors = if h > 0 then math.max(1, math.floor(h / S.STOREY)) else 0,
				edge = 0,
				style = districtById[did].style,
				seed = math.floor(WorldGen.hash(seq, 4, 80) * 2 ^ 31),
			})
		end
		for _, row in { 3760, 4200 } do
			local x = -1450
			while x < 2550 do
				local r = WorldGen.hash(x, row, 81)
				local w = 220 + 100 * r
				local use = if r < 0.62 then "container_yard" elseif r < 0.88 then "warehouse" else "shed"
				add("port", use, x + w / 2, row, w - 24, 240, if use == "container_yard" then 0 else 44, 0)
				x += w
			end
		end
		local hx = -3560
		while hx < -2350 do
			add("airport", "hangar", hx, 3010, 150, 130, 52, 0)
			hx += 175
		end
		add("airport", "parking_garage", -4330, 2390, 300, 170, 48, 0)
		add("airport", "parking_garage", -3890, 2390, 300, 170, 48, 0)
	end

	WorldLayout.Parcels = Parcels

	---------------------------------------------------------------------------------------------------------------------
	-- 14. Landmarks, prop clusters, vistas, zones, Hot Drops, ballistic stunt jumps, helipads, safe / restricted zones
	---------------------------------------------------------------------------------------------------------------------

	type Landmark = {
		id: string,
		name: string,
		kind: string,
		cframe: CFrame,
		size: Vector3,
		district: string,
		note: string?,
	}
	local function lm(
		id: string,
		name: string,
		kind: string,
		x: number,
		z: number,
		yaw: number,
		size: { number },
		note: string?,
		y: number?
	): Landmark
		local gy = y or gradeAt(x, z)
		local cf = CFrame.new(Vector3.new(x, gy, z)) * CFrame.Angles(0, math.rad(yaw), 0)
		return {
			id = id,
			name = name,
			kind = kind,
			cframe = cf,
			size = Vector3.new(size[1], size[2], size[3]),
			district = districtAt(x, z),
			note = note,
		}
	end

	-- First edge with this name (and an optional predicate).
	local function edgeNamed(name: string, pred: ((any) -> boolean)?): number?
		for i, e in Edges do
			if e.name == name and (pred == nil or pred(e)) then
				return i
			end
		end
		return nil
	end
	local function midOf(ei: number): (number, number, number, number, number)
		return edgeAt(ei, Edges[ei].length / 2)
	end
	local function bridgeLandmark(
		id: string,
		name: string,
		kind: string,
		road: string,
		size: { number },
		note: string
	): Landmark?
		local ei = edgeNamed(road, function(e: any): boolean
			return e.bridge
		end)
		if not ei then
			table.insert(PlacementErrors, "landmark " .. id .. ": no bridge edge on " .. road)
			return nil
		end
		local e = Edges[ei]
		local best = { 0, e.length }
		for _, sp in e.spans do
			if sp[2] - sp[1] > best[2] - best[1] or best[1] == 0 and best[2] == e.length then
				best = sp
			end
		end
		local x, y, z, tx, tz = edgeAt(ei, (best[1] + best[2]) / 2)
		local yaw = math.deg(math.atan2(-tx, -tz))
		local l = lm(id, name, kind, x, z, yaw, { size[1], size[2], best[2] - best[1] }, note, y)
		l.edge = ei
		l.span = { best[1], best[2] }
		return l
	end

	-- SUNWOOD sign: on the summit ridge on Liberty Avenue's axis above the observatory, base >= 450, facing the city
	-- (LookVector ~ (0.09, 0, 0.996): gta critique 3). The 9 sample points across the letters feed the vista test.
	local SIGN_W, SIGN_H = 720, 125
	local signCf: CFrame
	do
		-- the highest seat on the ridge along Liberty's axis: every letter footing at least 520 if the ridge allows,
		-- else the line where the lowest footing is highest (the sign is visible over the downtown towers from the
		-- freeway decks and Liberty Avenue)
		local sx = -150
		local best: number? = nil
		local bestLo, bestZ = -math.huge, -3560
		local z = -3440
		while z >= -3820 do
			local lo = math.huge
			for k = -4, 4 do
				lo = math.min(lo, gradeAt(sx + k * SIGN_W / 8 * 0.996, z - k * SIGN_W / 8 * 0.09))
			end
			if lo >= 520 then
				best = z
				break
			end
			if lo > bestLo then
				bestLo, bestZ = lo, z
			end
			z -= 10
		end
		local bz = best or bestZ
		local base = gradeAt(sx, bz)
		local pos = Vector3.new(sx, base, bz)
		signCf = CFrame.lookAt(pos, pos + Vector3.new(0.09, 0, 0.996))
	end
	local signSamples: { Vector3 } = {}
	for k = -4, 4 do
		local off = signCf.RightVector * (k * SIGN_W / 8 * 0.94)
		local p = signCf.Position + off
		table.insert(signSamples, Vector3.new(p.X, gradeAt(p.X, p.Z) + SIGN_H * 0.55, p.Z))
	end

	local Landmarks: { Landmark } = {
		{
			id = "SunwoodSign",
			name = "SUNWOOD sign",
			kind = "hill_sign",
			cframe = signCf,
			size = Vector3.new(SIGN_W, SIGN_H, 20),
			district = "hills",
			note = "giant white letters on the summit ridge, each on its own footing; lit at night; faces the city",
		},
		lm("Lighthouse", "Northpoint Lighthouse", "lighthouse", 1540, -4600, 0, { 40, 120, 40 }),
		lm(
			"WindFarm",
			"Red Mesa Wind Farm",
			"wind_farm",
			5300,
			-2900,
			0,
			{ 700, 160, 500 },
			"12 turbines on Mount Talon's east shoulder (see PropClusters)"
		),
		lm("Reservoir", "Mesa Reservoir Dam", "dam", 2950, -2440, 0, { 520, 70, 50 }),
		lm("Speedway", "Dustbowl Speedway", "race_track", 4420, 2820, 0, { 900, 30, 600 }, "dirt oval with grandstand"),
		lm("Quarry", "Talon Quarry", "quarry", 4930, -2700, 20, { 420, 60, 320 }, "benched pit on the peak's flank"),
		lm("MountTalon", "Mount Talon", "peak", 4300, -3030, 0, { 2600, 960, 2600 }, "summit lookout at the trail end"),
		lm("OilField", "Derrick Flats Oil Field", "oil_field", 3650, -1550, 0, { 500, 30, 700 }, "20 pumpjacks"),
		lm("TrailerPark", "Sundown Trailer Park", "trailer_park", 3700, -900, 0, { 260, 14, 200 }),
		lm("Substation", "Red Mesa Substation", "substation", 3560, 220, 0, { 160, 30, 120 }, "pylons run north"),
		lm("Prison", "Red Mesa State Prison", "prison", 4650, 1400, 0, { 900, 40, 700 }, "walled; 6 guard towers"),
		lm(
			"RailYard",
			"Rust Flats Rail Yard",
			"rail_yard",
			3015,
			1350,
			0,
			{ 1370, 10, 340 },
			"8 tracks, boxcars, a gantry"
		),
		lm(
			"Cranes",
			"Iron Bay Gantry Cranes",
			"cranes",
			700,
			4480,
			0,
			{ 2600, 220, 80 },
			"8 ship-to-shore cranes along the south quay"
		),
		lm(
			"CargoShip",
			"MV Rust Bucket",
			"ship",
			600,
			4680,
			90,
			{ 70, 90, 900 },
			"container ship docked at the south quay",
			0
		),
		lm("ControlTower", "HCI Control Tower", "tower", -3750, 2990, 0, { 40, 160, 40 }),
		lm("Runway09R", "Runway 09R/27L", "runway", -4065, 3330, 0, { 2570, 1, 150 }),
		lm("Runway09L", "Runway 09L/27R", "runway", -4170, 3790, 0, { 2960, 1, 150 }, "reclaimed land"),
		lm("Marina", "Palmera Marina", "marina", -5100, 2250, 0, { 720, 4, 900 }, "4 jetties + breakwater"),
		lm("Breakwater", "Marina Breakwater", "breakwater", -5450, 1720, 80, { 40, 8, 520 }, nil, 4),
		lm("Driftwood", "Driftwood", "hamlet", 5780, -2200, 0, { 400, 20, 500 }, "beach shacks below the Coast Hwy"),
		lm("LibertySquare", "Liberty Square", "park", 80, 427, 0, { 351, 2, 350 }, "City Hall's park square"),
		lm(
			"EchoPark",
			"Echo Park",
			"park",
			-1750,
			1870,
			0,
			{ 600, 30, 380 },
			"lake, ballfield and palms (Southgate Little League)"
		),
		lm("ObservatoryDome", "Starview Dome", "observatory", -520, -3150, 0, { 90, 60, 90 }),
		lm("CoveBeach", "Hidden Cove", "beach", -2900, -4120, 0, { 500, 2, 120 }, "secret beach under the cliffs"),
		lm(
			"GolfCourse",
			"Sunwood Country Club course",
			"golf",
			-4035,
			-2510,
			0,
			{ 770, 2, 540 },
			"9 holes, clubhouse on Sunwood Blvd"
		),
		lm("Mesas", "Red Mesa Buttes", "mesa", 4620, -1700, 40, { 860, 120, 260 }),
		lm("Cuesta", "Red Mesa Escarpment", "escarpment", 5200, -575, 0, { 200, 70, 3450 }),
	}
	for _, b in {
		{ "CrownViaduct", "Crown Street Viaduct", "bridge_arch", "Crown Boulevard", { 110, 30 }, "lit concrete arches" },
		{ "MissionTruss", "Mission Truss Bridge", "bridge_truss", "Mission Avenue", { 90, 40 }, "steel truss" },
		{ "CanyonBridge", "Canyon Bridge", "bridge_arch", "Skyline Drive", { 90, 40 }, "arch over Sunwood Canyon" },
		{ "HarborBridge", "Harbor Lift Bridge", "bridge_lift", "Harbor Avenue", { 90, 30 }, "raised 25 s / 4 min" },
		{ "IronBayBridge", "Iron Bay Bridge", "bridge_cable", "H2 Port Expressway (southbound)", { 120, 160 }, "pylons" },
	} do
		local l = bridgeLandmark(b[1], b[2], b[3], b[4], b[5], b[6])
		if l then
			table.insert(Landmarks, l)
		end
	end
	WorldLayout.Landmarks = Landmarks

	-- Prop clusters the builders scatter (one MeshPart / model kind each).
	local PropClusters: { { kind: string, name: string, points: { Vector3 } } } = {}
	local function cluster(kind: string, name: string, list: { { number } })
		local pts: { Vector3 } = {}
		for _, p in list do
			table.insert(pts, Vector3.new(p[1], gradeAt(p[1], p[2]), p[2]))
		end
		table.insert(PropClusters, { kind = kind, name = name, points = pts })
	end
	do
		local pump: { { number } } = {}
		for i = 0, 19 do
			local x = 3470 + (i % 4) * 110 + (WorldGen.hash(i, 1, 420) - 0.5) * 40
			local z = -1850 + (i // 4) * 130 + (WorldGen.hash(i, 2, 420) - 0.5) * 40
			if not roadClearance(x, z, 10) then
				table.insert(pump, { x, z })
			end
		end
		cluster("pumpjack", "Derrick Flats Oil Field", pump)
		local turb: { { number } } = {}
		for i = 0, 11 do
			table.insert(turb, { 5050 + (i % 4) * 170, -3150 + (i // 4) * 170 })
		end
		cluster("wind_turbine", "Red Mesa Wind Farm", turb)
		local pyl: { { number } } = {}
		local line = WorldGen.densify(poly({ { 3560, 220 }, { 3900, -900 }, { 4300, -1900 }, { 5100, -2800 } }), 300)
		for _, p in line do
			table.insert(pyl, { p.x, p.z })
		end
		cluster("pylon", "Substation line", pyl)
		cluster("guard_tower", "Red Mesa State Prison", {
			{ 4210, 1060 },
			{ 4650, 1060 },
			{ 5090, 1060 },
			{ 4210, 1740 },
			{ 4650, 1740 },
			{ 5090, 1740 },
		})
		local jetties: { { number } } = {}
		for _, z in { 1960, 2160, 2360, 2560 } do
			table.insert(jetties, { -4950, z })
		end
		cluster("jetty", "Palmera Marina (400-stud jetties, west from the east quay)", jetties)
		local trailers: { { number } } = {}
		for i = 0, 13 do
			table.insert(trailers, { 3620 + (i % 7) * 34, -960 + (i // 7) * 60 })
		end
		cluster("trailer", "Sundown Trailer Park", trailers)
	end
	WorldLayout.PropClusters = PropClusters

	-- Protected view (gta critique 3): the SUNWOOD sign seen up Liberty Avenue from Crown. Lots under the sight lines
	-- (from Liberty at Crown to each letter) are capped 10 studs under the line, like a real city's view corridor;
	-- planned towers never stand there.
	do
		local eye = Vector3.new(-150, GRADE + 6, -250)
		local capped = 0
		for _, p in Parcels do
			if p.size.Y <= 0 or p.tower then
				continue
			end
			local c = p.cframe.Position
			local r = math.sqrt(p.size.X * p.size.X + p.size.Z * p.size.Z) / 2
			local cap = math.huge
			for _, sp in signSamples do
				-- closest approach of the sight line (XZ) to the lot centre
				local ax, az = eye.X, eye.Z
				local bx, bz = sp.X, sp.Z
				local t, _, _, d = WorldGen.projectSeg(c.X, c.Z, ax, az, bx, bz)
				if d <= r and t > 0.02 and t < 0.98 then
					-- the lowest line height over the lot (toward the eye side)
					local tLow = math.max(0, t - r / math.max(1, (sp - eye).Magnitude))
					local y = eye.Y + (sp.Y - eye.Y) * tLow
					cap = math.min(cap, y - 10 - c.Y)
				end
			end
			if cap < p.size.Y then
				local h = math.max(math.floor(cap), 24)
				p.size = Vector3.new(p.size.X, h, p.size.Z)
				p.floors = math.max(1, math.floor(h / S.STOREY))
				capped += 1
			end
		end
		WorldLayout.ViewCorridorCapped = capped
	end

	-- Line-of-sight occluders: lots, POIs, plots (boxes) and the terrain.
	type Box = { obb: OBB, base: number, top: number, what: string }
	local boxes: { Box } = {}
	local boxCells: { [number]: { number } } = {}
	local BCELL = 160
	local function addBox(b: OBB, base: number, top: number, what: string)
		table.insert(boxes, { obb = b, base = base, top = top, what = what })
		local x0, z0, x1, z1 = obbBounds(b)
		WorldGen.hashBox(boxCells, BCELL, x0, z0, x1, z1, #boxes)
	end
	local function cfObb(cf: CFrame, size: Vector3): OBB
		return {
			cx = cf.Position.X,
			cz = cf.Position.Z,
			ux = cf.RightVector.X,
			uz = cf.RightVector.Z,
			hw = size.X / 2,
			hd = size.Z / 2,
		}
	end
	for _, p in Parcels do
		if p.size.Y > 0 then
			addBox(cfObb(p.cframe, p.size), p.cframe.Position.Y, p.cframe.Position.Y + p.size.Y, "lot " .. p.use)
		end
	end
	for _, p in POIs do
		if p.size.Y > 0 then
			addBox(cfObb(p.cframe, p.size), p.cframe.Position.Y, p.cframe.Position.Y + p.size.Y, p.id)
		end
	end
	for _, p in Plots do
		addBox(cfObb(p.cframe, p.size), p.cframe.Position.Y, p.cframe.Position.Y + p.size.Y, p.name)
	end
	local function boxAt(x: number, y: number, z: number, margin: number): string?
		local list = boxCells[WorldGen.cellKey(math.floor(x / BCELL), math.floor(z / BCELL))]
		if not list then
			return nil
		end
		for _, id in list do
			local b = boxes[id]
			if y >= b.base - 1 and y <= b.top + margin and WorldGen.obbContains(b.obb, x, z, margin) then
				return b.what
			end
		end
		return nil
	end
	local function deckAt(x: number, y: number, z: number, ignore: string?): string?
		local hit: string? = nil
		WorldGen.segQuery(elevSegs, x, z, 0, function(id: number)
			if hit then
				return
			end
			local ei = elevSegs.owner[id]
			local e = Edges[ei]
			if e.name == ignore then
				return
			end
			local t, _, _, d =
				WorldGen.projectSeg(x, z, elevSegs.ax[id], elevSegs.az[id], elevSegs.bx[id], elevSegs.bz[id])
			if d <= e.width / 2 + 2 then
				local k = elevSegs.segNo[id]
				local pts = edgePts[ei].pts
				local dy = pts[k].y + (pts[k + 1].y - pts[k].y) * t
				if y > dy - 6 and y < dy + 4 then
					hit = "deck " .. e.name
				end
			end
		end)
		return hit
	end
	local function visible(a: Vector3, b: Vector3): boolean
		local d = (b - a).Magnitude
		local n = math.ceil(d / 20)
		for i = 1, n - 1 do
			local p = a:Lerp(b, i / n)
			if heightAt(p.X, p.Z) > p.Y or boxAt(p.X, p.Y, p.Z, 0) then
				return false
			end
		end
		return true
	end
	WorldLayout._visible = visible

	-- Named vista points (eye height 6 above the road / deck). The sign must show >= 5 of its 9 samples from each.
	local Vistas: { { name: string, pos: Vector3 } } = {}
	local function vista(name: string, x: number, z: number, y: number?)
		table.insert(Vistas, { name = name, pos = Vector3.new(x, (y or gradeAt(x, z)) + 6, z) })
	end
	do
		local pierEdge = edgeNamed("Palmera Pier")
		if pierEdge then
			local e = Edges[pierEdge]
			local far = if e.points[1].X < e.points[#e.points].X then e.points[1] else e.points[#e.points]
			vista("Palmera Pier end", far.X, far.Z, far.Y)
		end
		vista("H1 west deck", -3650, -900, DECK_Y)
		vista("H1 north-west deck", -2500, ctx.ringCenter[1].z - 3315 + 1515, DECK_Y)
		vista("H1 south deck", -150, 1385, DECK_Y)
		vista("Echo Park", -1750, 1870)
		vista("Liberty at Crown", -150, -250)
	end
	-- the north-west deck vista sits on the ring centerline near (-2500, -1800)
	do
		local _, _, px, pz = WorldGen.polyProject(ctx.ringCenter, -2500, -1800)
		Vistas[3].pos = Vector3.new(px, DECK_Y + 6, pz)
		local _, _, sx, sz = WorldGen.polyProject(ctx.ringCenter, -150, 1385)
		Vistas[4].pos = Vector3.new(sx, DECK_Y + 6, sz)
	end
	local SignVisibility: { [string]: number } = {}
	for _, v in Vistas do
		local n = 0
		for _, sp in signSamples do
			if visible(v.pos, sp) then
				n += 1
			end
		end
		SignVisibility[v.name] = n
	end
	WorldLayout.Vistas = Vistas
	WorldLayout.SignSamples = signSamples
	WorldLayout.SignVisibility = SignVisibility

	type Zone = {
		id: string,
		name: string,
		cframe: CFrame,
		size: Vector3,
		district: string,
		note: string?,
		pool: string?,
		heat: number?,
		exempt: { string }?,
		respawns: { CFrame }?,
	}
	local function zone(id: string, name: string, x: number, z: number, size: { number }, note: string?, y: number?): Zone
		local gy = y or gradeAt(x, z)
		return {
			id = id,
			name = name,
			cframe = CFrame.new(x, gy + size[2] / 2, z),
			size = Vector3.new(size[1], size[2], size[3]),
			district = districtAt(x, z),
			note = note,
		}
	end

	-- Restricted zones: entering raises the wanted level (GTA airport / port rule). Activities inside carry an explicit
	-- flag (exempt list here, or `heat` on the drop / jump) so stars never stack by accident (gameplay critique 14).
	local RestrictedZones: { Zone } = {
		zone("rz_airside", "HCI Airside", -4170, 3560, { 3300, 300, 760 }, "1 star on entry, 3 if you stay 10 s"),
		zone("rz_port", "Iron Bay Container Terminal", 500, 3960, { 4200, 300, 840 }, "1 star on entry after the gate"),
		zone("rz_prison", "Red Mesa State Prison", 4650, 1400, { 900, 300, 700 }, "3 stars inside the walls"),
	}
	RestrictedZones[1].exempt = { "race_airport" }
	WorldLayout.RestrictedZones = RestrictedZones
	local function inRestricted(p: Vector3): Zone?
		for _, rz in RestrictedZones do
			local lp = rz.cframe:PointToObjectSpace(p)
			if math.abs(lp.X) <= rz.size.X / 2 and math.abs(lp.Z) <= rz.size.Z / 2 then
				return rz
			end
		end
		return nil
	end

	-- Hot Drop zones. Normal pool: inside the Active Core, each within 60 s at 100 studs/s of >= 5 garages (checked by
	-- the tests on the road graph). Long Haul pool: the far-flung ones, with a 60 s warning and a rarer roll
	-- (gameplay critiques 5, 6). Respawns (filled in section 16) put players WASTED at a drop back 600-900 away.
	local HotDrops: { Zone } = {}
	local function drop(id: string, name: string, x: number, z: number, size: { number }, pool: string, heat: number?)
		local zz = zone(id, name, x, z, size)
		zz.pool = pool
		zz.heat = heat
		table.insert(HotDrops, zz)
	end
	drop("hd_plaza", "Hotwire Plaza", 526, -410, { 160, 40, 160 }, "normal")
	drop("hd_liberty", "Liberty Square", 80, 427, { 180, 40, 180 }, "normal")
	drop("hd_gilded", "Gilded Mile lot", -2250, -520, { 140, 40, 140 }, "normal")
	drop("hd_echo", "Echo Park", -1750, 1870, { 180, 40, 160 }, "normal")
	drop("hd_arena", "Iron Bay Arena lot", 1240, 2300, { 200, 40, 160 }, "normal")
	drop("hd_underring", "Under the Ring", 760, 1460, { 200, 40, 120 }, "normal")
	drop("hd_foundry", "Brewery lot", 2800, -400, { 140, 40, 140 }, "normal")
	drop("hd_railyard", "Rail Yard", 2900, 1350, { 200, 40, 160 }, "normal")
	drop("hd_pier", "Palmera Pier lot", -4620, -950, { 140, 40, 140 }, "longhaul")
	drop("hd_strip", "Sunwood Strip", -1650, -2150, { 160, 40, 140 }, "normal")
	drop("hd_port", "Container Yard", 1200, 4000, { 200, 40, 200 }, "longhaul", 1)
	drop("hd_airport", "Hangar Apron", -2900, 3150, { 220, 40, 180 }, "longhaul")
	drop("hd_observatory", "Observatory lot", -520, -2980, { 140, 40, 140 }, "longhaul")
	drop("hd_cactus", "Cactus Junction", 4330, -560, { 160, 40, 160 }, "longhaul")
	drop("hd_speedway", "Speedway infield", 4420, 2820, { 240, 40, 160 }, "longhaul")
	drop("hd_cove", "Hidden Cove lookout", -2700, -3800, { 140, 40, 140 }, "longhaul")
	WorldLayout.HotDrops = HotDrops
	WorldLayout.HotDropRules = {
		normalWarning = 20, -- seconds; the event service uses max(20, 0.8 x median active-player ETA)
		longHaulWarning = 60,
		longHaulWeight = 0.25, -- relative roll weight vs a normal drop
		minPlayersWithin = 3, -- pick the zone / run with the tightest ETA spread and >= 3 players within 45 s
		withinSeconds = 45,
		firstDropAt = 210, -- a first drop near the newest player at ~3:30 (gameplay critique 12)
		respawnMin = 600,
		respawnMax = 900,
	}

	-- Stunt jumps: lip CFrame (LookVector = jump direction), the landing computed from a ballistic arc at minSpeed with
	-- Scale.GRAVITY (gameplay critiques 3, 4). Kinds: kicker (ramp on a road), drop (off a deck / roof / cliff edge),
	-- splash (lands in the water; the car is returned automatically).
	type Jump = {
		id: string,
		name: string,
		kind: string,
		cframe: CFrame,
		size: Vector3,
		angle: number, -- launch angle (degrees)
		minSpeed: number,
		landing: Vector3,
		airtime: number,
		apex: number,
		runup: number, -- straight run-up behind the lip (road / deck / roof / ground)
		heat: number?,
		note: string?,
	}
	local G = S.GRAVITY
	-- Flight from lip along (dx, dz): returns landing point, airtime, apex, what blocked it (nil = clean landing).
	local function fly(
		lip: Vector3,
		dx: number,
		dz: number,
		angle: number,
		v: number,
		ignoreDeck: string?
	): (Vector3, number, number, string?)
		local a = math.rad(angle)
		local vh, vy = v * math.cos(a), v * math.sin(a)
		local dt = 1 / 120
		local t = 0
		local apex = lip.Y
		while t < 8 do
			t += dt
			local x = lip.X + dx * vh * t
			local z = lip.Z + dz * vh * t
			local y = lip.Y + vy * t - 0.5 * G * t * t
			apex = math.max(apex, y)
			local ground = heightAt(x, z)
			local water = not landAtLeast(x, z, 0)
			if water then
				ground = math.max(ground, 0)
			end
			if y <= ground then
				return Vector3.new(x, ground, z), t, apex, nil
			end
			if t > 0.05 then
				local what = boxAt(x, y, z, 1) or deckAt(x, y, z, ignoreDeck)
				if what then
					return Vector3.new(x, y, z), t, apex, what
				end
			end
		end
		return lip, 0, apex, "never lands"
	end
	WorldLayout._fly = fly
	-- Straight run-up behind a point along a road chain (studs where the heading stays within 15 degrees).
	local function runupOnRoads(x: number, z: number, dx: number, dz: number): number
		local ei, _ = WorldGen.nearestEdge(edgeIndex, x, z, 25, function(i: number): boolean
			return not Edges[i].elevated or Edges[i].class == "ramp"
		end)
		if not ei then
			return 0
		end
		local chain = roadChain(ei)
		local _, s0 = WorldGen.polyProject(chain.pts, x, z)
		local _, _, tx, tz = WorldGen.polyAtCum(chain.pts, chain.cum, s0)
		local sign = if tx * dx + tz * dz >= 0 then 1 else -1
		local cos15 = math.cos(math.rad(15))
		local run = 0
		while run < 400 do
			local s = s0 - sign * (run + 10)
			if s < 0 or s > chain.cum[#chain.cum] then
				break
			end
			local _, _, ux, uz = WorldGen.polyAtCum(chain.pts, chain.cum, s)
			if (ux * dx + uz * dz) * sign < cos15 then
				break
			end
			run += 10
		end
		return run
	end
	WorldLayout._runup = runupOnRoads
	local StuntJumps: { Jump } = {}
	local function jump(
		id: string,
		name: string,
		kind: string,
		lip: Vector3,
		dx: number,
		dz: number,
		angle: number,
		minSpeed: number,
		size: { number },
		runup: number?,
		note: string?,
		ignoreDeck: string?
	): Jump?
		local l = math.sqrt(dx * dx + dz * dz)
		dx, dz = dx / l, dz / l
		local landing, airtime, apex, blocked = fly(lip, dx, dz, angle, minSpeed, ignoreDeck)
		if blocked then
			table.insert(PlacementErrors, ("jump %s: %s"):format(id, blocked))
		end
		local j: Jump = {
			id = id,
			name = name,
			kind = kind,
			cframe = CFrame.lookAt(lip, lip + Vector3.new(dx, 0, dz)),
			size = Vector3.new(size[1], size[2], size[3]),
			angle = angle,
			minSpeed = minSpeed,
			landing = landing,
			airtime = airtime,
			apex = apex,
			runup = runup or runupOnRoads(lip.X, lip.Z, dx, dz),
			note = note,
		}
		if inRestricted(lip) or inRestricted(landing) then
			j.heat = 1
		end
		table.insert(StuntJumps, j)
		return j
	end
	-- a kicker on a road: lip = road point + ramp height, heading along the road's tangent (sign toward (hx, hz))
	local function roadKicker(
		id: string,
		name: string,
		road: string,
		x: number,
		z: number,
		hx: number,
		hz: number,
		lift: number,
		angle: number,
		v: number,
		size: { number }
	)
		local ei = WorldGen.nearestEdge(edgeIndex, x, z, 400, function(i: number): boolean
			return Edges[i].name == road
		end)
		if not ei then
			table.insert(PlacementErrors, "jump " .. id .. ": no road " .. road)
			return
		end
		local _, s = WorldGen.polyProject(edgePts[ei].pts, x, z)
		local px, py, pz, tx, tz = edgeAt(ei, s)
		if tx * hx + tz * hz < 0 then
			tx, tz = -tx, -tz
		end
		jump(id, name, "kicker", Vector3.new(px, py + lift, pz), tx, tz, angle, v, size)
	end

	-- Pier Plunge: off the end of the pier into the bay (splash: VehicleService returns the car).
	do
		local ei = edgeNamed("Palmera Pier")
		if ei then
			local e = Edges[ei]
			local far, near = e.points[#e.points], e.points[#e.points - 1]
			if e.points[1].X < far.X then
				far, near = e.points[1], e.points[2]
			end
			local d = (far - near) * Vector3.new(1, 0, 1)
			local j = jump(
				"sj_pier",
				"Pier Plunge",
				"splash",
				far + Vector3.new(0, 4, 0),
				d.X,
				d.Z,
				12,
				90,
				{ 16, 4, 24 },
				nil,
				"off the end of the pier into the bay (the car is returned)",
				"Palmera Pier"
			)
			if j then
				j.runup = e.length
			end
		end
	end
	-- Channel Drop: off the east wall top of the Rust River at the end of an east-west street, onto the channel floor.
	do
		local CH = WorldTerrain.Channel
		local _, s = WorldGen.polyProject(CH.points, 2045, -1636)
		local cx, cz, tx, tz = WorldGen.polyAt(CH.points, s)
		local rx, rz = WorldGen.right(tx, tz) -- channel runs north -> south; right = west
		local half = WorldTerrain.channelFloorHalf(cz) + CH.wallRun
		local lipX, lipZ = cx - rx * half, cz - rz * half -- east wall top
		jump(
			"sj_channel",
			"Channel Drop",
			"drop",
			Vector3.new(lipX, GRADE + 3, lipZ),
			rx,
			rz,
			8,
			90,
			{ 16, 3, 20 },
			runupOnRoads(lipX + 60 * -rx, lipZ + 60 * -rz, rx, rz),
			"run up Brass St, across Riverside Drive, off the wall onto the floor"
		)
	end
	-- Boxcar Hop: north off the end of Boxcar Ave over the first boxcar line into the yard.
	do
		local best: Vector3?, dir: Vector3? = nil, nil
		for _, e in Edges do
			if e.name == "Boxcar Ave" then
				for _, k in { 1, #e.points } do
					local p = e.points[k]
					if best == nil or p.Z < (best :: Vector3).Z then
						local q = e.points[if k == 1 then 2 else #e.points - 1]
						best, dir = p, (p - q) * Vector3.new(1, 0, 1)
					end
				end
			end
		end
		if best and dir then
			local d = (dir :: Vector3).Unit
			jump("sj_railyard", "Boxcar Hop", "kicker", (best :: Vector3) + d * 6 + Vector3.new(0, 6, 0), d.X, d.Z, 16, 100, {
				16,
				6,
				30,
			})
		end
	end
	-- Container Stack: a 28-high ramp of containers on Container Road, landing back on the road (restricted: heat 1).
	roadKicker("sj_port", "Container Stack", "Container Road", 1700, 3995, 1, 0, 28, 10, 110, { 16, 28, 80 })
	-- Skyline Drop: off the outside of a Sunwood Canyon Road hairpin, down the fall line onto the leg below.
	do
		local best: { any }? = nil
		for ei, e in Edges do
			if e.name ~= "Sunwood Canyon Road" then
				continue
			end
			local pts = edgePts[ei].pts
			local cum = edgeCum[ei]
			local L = cum[#cum]
			local s = 40
			while s < L - 40 do
				local _, _, ax, az = WorldGen.polyAtCum(pts, cum, s - 35)
				local _, _, bx, bz = WorldGen.polyAtCum(pts, cum, s + 35)
				if ax * bx + az * bz < -0.5 then
					-- hairpin apex near s; try both travel directions
					for _, sgn in { 1, -1 } do
						local ix, iz = if sgn > 0 then ax else -bx, if sgn > 0 then az else -bz
						local px, py, pz = edgeAt(ei, s)
						local lip = Vector3.new(px + ix * 14, py + 4, pz + iz * 14)
						if heightAt(lip.X + ix * 30, lip.Z + iz * 30) < py - 6 then
							local landing, airtime, _, blocked = fly(lip, ix, iz, 10, 90)
							local onRoad = roadClearance(landing.X, landing.Z, 0)
							if not blocked and onRoad then
								local score = airtime - math.abs(px + 1450) / 2000
								if best == nil or score > (best :: { any })[1] then
									best = { score, lip, ix, iz }
								end
							end
						end
					end
				end
				s += 10
			end
		end
		if best then
			local b = best :: { any }
			jump(
				"sj_hills",
				"Skyline Drop",
				"drop",
				b[2],
				b[3],
				b[4],
				10,
				90,
				{ 16, 4, 24 },
				nil,
				"outside of a hairpin, down the fall line onto the leg below"
			)
		else
			-- no hairpin falls away steeply enough: use a crest kicker on the steepest downhill hill road instead (lands
			-- back on the road further down; the run-up is the straight approach to the crest)
			local crest: { any }? = nil
			for ei, e in Edges do
				if e.district ~= "hills" or not (e.class == "rural" or e.class == "street") or e.length < 260 then
					continue
				end
				local pts = edgePts[ei].pts
				local cum = edgeCum[ei]
				local L = cum[#cum]
				local s = 200
				while s < L - 40 do
					local px, py, pz, tx, tz = edgeAt(ei, s)
					local _, py2 = edgeAt(ei, s + 40)
					for _, sgn in { 1, -1 } do
						local fall = (py - py2) * sgn
						if fall > 3 then
							local dx, dz = tx * sgn, tz * sgn
							local lip = Vector3.new(px, py + 5, pz)
							local landing, airtime, _, blocked = fly(lip, dx, dz, 14, 100)
							local nearRoad = WorldGen.nearestEdge(edgeIndex, landing.X, landing.Z, 40)
							if not blocked and airtime > 0.55 and nearRoad ~= nil then
								local run = runupOnRoads(px, pz, dx, dz)
								if run >= 160 then
									local score = airtime + run / 1000
									if crest == nil or score > (crest :: { any })[1] then
										crest = { score, lip, dx, dz, run }
									end
								end
							end
						end
					end
					s += 10
				end
				local _ = pts
			end
			if crest then
				local c = crest :: { any }
				jump(
					"sj_hills",
					"Skyline Drop",
					"kicker",
					c[2],
					c[3],
					c[4],
					14,
					100,
					{ 16, 5, 26 },
					c[5],
					"crest kicker on the steepest downhill run in Sunwood Hills; lands on the road below"
				)
			else
				table.insert(PlacementErrors, "jump sj_hills: no hairpin or crest with a clean landing")
			end
		end
	end
	-- Unfinished Ramp: off the end of the dead-end flyover stub (layer 2) toward the Rust River.
	do
		local stubName = ctx.stubWay.name
		for ei, e in Edges do
			if e.name == stubName then
				local endNode = if #Nodes[e.b].edges == 1 then e.b else e.a
				local pts = edgePts[ei].pts
				local p, q
				if endNode == e.b then
					p, q = pts[#pts], pts[#pts - 1]
				else
					p, q = pts[1], pts[2]
				end
				local dx, dz = p.x - q.x, p.z - q.z
				local j = jump(
					"sj_construction",
					"Unfinished Ramp",
					"drop",
					Vector3.new(p.x, p.y + 1, p.z),
					dx,
					dz,
					4,
					110,
					{ 16, 2, 20 },
					e.length,
					"dead-end flyover stub off the H1 east leg; lands in the channel",
					stubName
				)
				local _ = j
				break
			end
		end
	end
	-- Mesa Launch: off the butte rim at the top of Mesa Track (the dead end, not the Cactus Junction end).
	do
		local ei = edgeNamed("Mesa Track", function(e: any): boolean
			return #Nodes[e.a].edges == 1 or #Nodes[e.b].edges == 1
		end)
		if ei then
			local e = Edges[ei]
			local endNode = if #Nodes[e.b].edges == 1 then e.b else e.a
			local pts = edgePts[ei].pts
			local p, q
			if endNode == e.b then
				p, q = pts[#pts], pts[#pts - 3]
			else
				p, q = pts[1], pts[4]
			end
			local dx, dz = p.x - q.x, p.z - q.z
			local l = math.sqrt(dx * dx + dz * dz)
			local lip = Vector3.new(p.x + dx / l * 20, heightAt(p.x + dx / l * 20, p.z + dz / l * 20) + 4, p.z + dz / l * 20)
			jump("sj_mesa", "Mesa Launch", "drop", lip, dx, dz, 12, 100, { 16, 4, 24 }, nil, "off the caprock rim")
		end
	end
	roadKicker("sj_dunes", "Dune Kicker", "Dustbowl Road", 4150, 1700, 0, -1, 6, 16, 100, { 16, 6, 30 })
	-- Parking Deck: off the roof edge of Crown Street Parking onto Crown Boulevard.
	do
		local p = poiById.ParkingDeck
		if p then
			local look = p.cframe.LookVector
			local lip = p.cframe.Position + look * (p.size.Z / 2) + Vector3.new(0, p.size.Y + 1, 0)
			jump(
				"sj_garage",
				"Parking Deck",
				"drop",
				lip,
				look.X,
				look.Z,
				6,
				80,
				{ 16, 2, 16 },
				p.size.Z - 10,
				"up the ramps, across the roof, over the parapet kicker onto Crown Boulevard"
			)
		end
	end
	-- Cove Cliff: north off the cliff edge onto the Hidden Cove sand.
	do
		local x, z = -2900, -3960
		local lip = Vector3.new(x, heightAt(x, z) + 3, z)
		local run = 0
		while run < 300 and math.abs(heightAt(x, z + run + 10) - heightAt(x, z + run)) < 4 do
			run += 10
		end
		jump("sj_cove", "Cove Cliff", "drop", lip, 0, -1, 8, 90, { 16, 3, 20 }, run, "off-road run-up from the H9 end")
	end
	-- Speedway Tabletop: a dirt tabletop on the oval's back straight.
	jump(
		"sj_speedway",
		"Speedway Tabletop",
		"kicker",
		Vector3.new(4420, gradeAt(4420, 2700) + 8, 2700),
		-1,
		0,
		14,
		90,
		{ 30, 8, 40 },
		400,
		"on the speedway's back straight (flat pad, 400 run-up)"
	)
	WorldLayout.StuntJumps = StuntJumps

	-- Helipads: roof pads follow their buildings.
	local Helipads: { Zone } = {
		zone("heli_mercy", "Mount Mercy roof", 0, 0, { 40, 4, 40 }, "on HospitalCentral roof"),
		zone("heli_hcpd", "HCPD HQ roof", 0, 0, { 40, 4, 40 }, "on PoliceHQ roof"),
		zone("heli_pinnacle", "Pinnacle Tower roof", 0, 0, { 40, 4, 40 }, "on PinnacleTower roof"),
		zone("heli_airport1", "HCI Helipad 1", -3450, 2810, { 50, 4, 50 }),
		zone("heli_airport2", "HCI Helipad 2", -3370, 2810, { 50, 4, 50 }),
		zone("heli_port", "Iron Bay Helipad", 2600, 4150, { 50, 4, 50 }),
		zone("heli_hills", "Sunwood Estate Helipad", -2200, -3350, { 50, 4, 50 }),
	}
	do
		local roof = { heli_mercy = "HospitalCentral", heli_hcpd = "PoliceHQ", heli_pinnacle = "PinnacleTower" }
		for _, h in Helipads do
			local poiId = (roof :: any)[h.id]
			local p = poiId and poiById[poiId]
			if p then
				h.cframe = p.cframe + Vector3.new(0, p.size.Y + 2, 0)
				h.district = p.district
			end
		end
		-- every planned tower with a helipad crown gets one too
		for _, t in TowerPlan do
			if t.crown == "helipad" and t.parcel then
				local pc = Parcels[t.parcel]
				table.insert(
					Helipads,
					{
						id = "heli_" .. t.id,
						name = t.id .. " roof",
						cframe = pc.cframe + Vector3.new(0, pc.size.Y + 2, 0),
						size = Vector3.new(40, 4, 40),
						district = pc.district,
					}
				)
			end
		end
	end
	WorldLayout.Helipads = Helipads

	-- Safe zones: hospital doors (spawn protection) and dealership floors.
	local SafeZones: { Zone } = {}
	for _, p in POIs do
		if p.kind == "hospital" then
			table.insert(SafeZones, {
				id = "safe_" .. p.id,
				name = p.name,
				cframe = p.cframe + Vector3.new(0, 20, 0),
				size = Vector3.new(p.size.X + 40, 40, p.size.Z + 60),
				district = p.district,
				note = "5 s spawn protection, no weapons",
			})
		elseif p.kind == "dealership" then
			table.insert(SafeZones, {
				id = "safe_" .. p.id,
				name = p.name,
				cframe = p.cframe + Vector3.new(0, 20, 0),
				size = Vector3.new(p.size.X, 40, p.size.Z),
				district = p.district,
				note = "no weapons inside the showroom",
			})
		end
	end
	WorldLayout.SafeZones = SafeZones

	-- Hand-off to phase 3 (gen/Routes.luau: spawns, routing, routes, roadblocks, streetscape, stats). Stripped before
	-- the bake like _ctx.
	WorldLayout._ctx2 = {
		edgePts = edgePts,
		edgeCum = edgeCum,
		roadSegs = roadSegs,
		elevSegs = elevSegs,
		edgeIndex = edgeIndex,
		roadClearance = roadClearance,
		deckOver = deckOver,
		edgeAt = edgeAt,
		onBridge = onBridge,
		endClear = endClear,
		nodeRadius = nodeRadius,
		relief = relief,
		addPad = addPad,
		installEdits = installEdits,
		pads = pads,
		cuts = cuts,
		roadHit = roadHit,
		roadChain = roadChain,
		inReservedArea = inReservedArea,
		poiById = poiById,
		inNoLot = inNoLot,
		overlapsAny = overlapsAny,
		inRestricted = inRestricted,
		edgeNamed = edgeNamed,
		visible = visible,
		boxAt = boxAt,
		onRampTerminals = onRampTerminals,
		PINNACLE = PINNACLE,
		OPEN_USES = OPEN_USES,
	}
end
