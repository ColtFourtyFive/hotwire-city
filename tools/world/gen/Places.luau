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
				or e.bridge
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
		{ name = "Pinnacle Garage", at = { 1300, -680 }, face = PINNACLE, maxAngle = 25 },
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
			brand = "Second Gear",
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
			size = { 176, 150, 180 },
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

	--@@PART2@@
end
