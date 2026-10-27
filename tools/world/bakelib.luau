--!nocheck
-- Bake library (tools/world/bake.luau is the CLI): turns the generator's output into two data modules the game loads
-- instantly (MIGRATION.md §5, tech critique 8):
--
--   src/shared/Config/WorldData.luau      core (server + clients): terrain edits, districts, the road graph,
--                                          junctions, POIs, plots, landmarks, zones, jumps, routes, rails, paths...
--   src/server/Config/WorldDataLots.luau  server only (never replicated), loaded lazily: lots (parcels), parking /
--                                          police / off-street spawns, streetscape placements, roadblocks, ETA fields
--
-- Config/WorldLayout (hand-written) loads them and rebuilds the runtime tables. Each file carries a content hash; the
-- worldlayout spec regenerates the world and checks the hashes, so the baked data can never drift from the code.
--
--   lune run tools/world/bake.luau            (bake)
--   lune run tools/world/bake.luau --check    (exit 1 when the baked files are out of date)
local Harness = require("../../tests/harness")
local WorldGen = Harness.require("src/shared/Util/WorldGen")
local WorldTerrain = Harness.require("src/shared/Util/WorldTerrain")

local Bake = {}
Bake.CORE_PATH = "src/shared/Config/WorldData.luau"
Bake.LOTS_PATH = "src/server/Config/WorldDataLots.luau"

---------------------------------------------------------------------------------------------------------------------
-- Luau literal serializer: numbers (3 decimals), strings, booleans, Vector3 -> V(x, y, z), horizontal CFrames ->
-- C(x, y, z, yaw) (yaw in degrees, CFrame.Angles convention), other CFrames -> F(12 components), tables (arrays and
-- maps with sorted keys).
---------------------------------------------------------------------------------------------------------------------

local function num(x: number, dec: number?): string
	if x ~= x then
		return "0"
	end
	if x == math.huge then
		return "math.huge"
	elseif x == -math.huge then
		return "-math.huge"
	end
	local d = dec or 3
	local m = 10 ^ d
	local r = math.floor(x * m + 0.5) / m
	if r == math.floor(r) and math.abs(r) < 1e15 then
		return string.format("%d", r)
	end
	local s = string.format("%." .. d .. "f", r)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	if s == "-0" then
		s = "0"
	end
	return s
end

local function isIdent(k: string): boolean
	return k:match("^[%a_][%w_]*$") ~= nil
		and k ~= "end"
		and k ~= "and"
		and k ~= "or"
		and k ~= "not"
		and k ~= "local"
		and k ~= "function"
		and k ~= "return"
		and k ~= "nil"
		and k ~= "true"
		and k ~= "false"
		and k ~= "then"
		and k ~= "else"
		and k ~= "elseif"
		and k ~= "if"
		and k ~= "for"
		and k ~= "in"
		and k ~= "do"
		and k ~= "while"
		and k ~= "repeat"
		and k ~= "until"
		and k ~= "break"
		and k ~= "continue"
end

local ser

local function serCFrame(cf): string
	local up = cf.UpVector
	local p = cf.Position
	if math.abs(up.Y - 1) < 1e-5 then
		local look = cf.LookVector
		local yaw = math.deg(math.atan2(-look.X, -look.Z))
		return "C(" .. num(p.X) .. "," .. num(p.Y) .. "," .. num(p.Z) .. "," .. num(yaw, 4) .. ")"
	end
	local c = { cf:GetComponents() }
	local parts = {}
	for i, v in c do
		parts[i] = num(v, if i <= 3 then 3 else 6)
	end
	return "F(" .. table.concat(parts, ",") .. ")"
end

local function isArray(t): boolean
	local n = #t
	local count = 0
	for _ in t do
		count += 1
	end
	return count == n
end

-- out: string buffer (table of chunks); depth: indentation (tabs)
function ser(v, out: { string }, depth: number)
	local tv = typeof(v)
	if tv == "number" then
		table.insert(out, num(v))
	elseif tv == "string" then
		table.insert(out, string.format("%q", v))
	elseif tv == "boolean" then
		table.insert(out, if v then "true" else "false")
	elseif tv == "Vector3" then
		table.insert(out, "V(" .. num(v.X) .. "," .. num(v.Y) .. "," .. num(v.Z) .. ")")
	elseif tv == "CFrame" then
		table.insert(out, serCFrame(v))
	elseif tv == "table" then
		if next(v) == nil then
			table.insert(out, "{}")
			return
		end
		local ind = string.rep("\t", depth + 1)
		local close = string.rep("\t", depth)
		if isArray(v) then
			-- arrays of scalars / vectors pack many per line
			local scalar = true
			for _, x in v do
				local tx = typeof(x)
				if tx == "table" then
					scalar = false
					break
				end
			end
			if scalar then
				local parts = {}
				local total = 0
				for _, x in v do
					local chunk = {}
					ser(x, chunk, depth + 1)
					local s1 = table.concat(chunk)
					table.insert(parts, s1)
					total += #s1 + 2
					if total > 100 then
						break
					end
				end
				if total <= 100 and #parts == #v then
					table.insert(out, "{ " .. table.concat(parts, ", ") .. " }")
					return
				end
				table.insert(out, "{")
				local line = 0
				for i, x in v do
					local chunk = {}
					ser(x, chunk, depth + 1)
					local s = table.concat(chunk)
					if line == 0 then
						table.insert(out, "\n" .. ind)
					elseif line + #s > 110 then
						table.insert(out, "\n" .. ind)
						line = 0
					else
						table.insert(out, " ")
					end
					table.insert(out, s)
					table.insert(out, ",")
					line += #s + 2
					local _ = i
				end
				table.insert(out, "\n" .. close .. "}")
			else
				table.insert(out, "{\n")
				for _, x in v do
					table.insert(out, ind)
					ser(x, out, depth + 1)
					table.insert(out, ",\n")
				end
				table.insert(out, close .. "}")
			end
		else
			local keys = {}
			for k in v do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				if type(a) == type(b) then
					return a < b
				end
				return type(a) == "number"
			end)
			-- small maps of scalars on one line
			local inline = #keys <= 12
			for _, k in keys do
				local tv2 = typeof(v[k])
				if tv2 == "table" then
					inline = false
					break
				end
			end
			if inline then
				local parts = {}
				for _, k in keys do
					local chunk = {}
					ser(v[k], chunk, depth + 1)
					local key = if type(k) == "string" and isIdent(k) then k else "[" .. (if type(k) == "string" then string.format("%q", k) else num(k)) .. "]"
					table.insert(parts, key .. " = " .. table.concat(chunk))
				end
				local s = "{ " .. table.concat(parts, ", ") .. " }"
				if #s < 110 then
					table.insert(out, s)
					return
				end
			end
			table.insert(out, "{\n")
			for _, k in keys do
				local key = if type(k) == "string" and isIdent(k) then k else "[" .. (if type(k) == "string" then string.format("%q", k) else num(k)) .. "]"
				table.insert(out, ind .. key .. " = ")
				ser(v[k], out, depth + 1)
				table.insert(out, ",\n")
			end
			table.insert(out, close .. "}")
		end
	elseif tv == "nil" then
		table.insert(out, "nil")
	else
		error("bake: cannot serialize " .. tv)
	end
end

---------------------------------------------------------------------------------------------------------------------
-- What goes where
---------------------------------------------------------------------------------------------------------------------

local function r2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

-- defaults are omitted (false / empty / zero / nil); Config/WorldLayout fills them back in
local function compact(t)
	local out = {}
	for k, v in t do
		if v == false or v == 0 or (type(v) == "table" and next(v) == nil) then
			continue
		end
		out[k] = v
	end
	return out
end

local function stripEdge(e)
	local flat = {}
	for _, p in e.points do
		table.insert(flat, r2(p.X))
		table.insert(flat, r2(p.Y))
		table.insert(flat, r2(p.Z))
	end
	return compact({
		a = e.a,
		b = e.b,
		p = flat,
		len = e.length,
		class = e.class,
		name = e.name,
		oneWay = e.oneWay,
		lanesF = e.lanesF,
		lanesB = e.lanesB,
		median = e.median,
		parking = e.parking,
		width = e.width,
		sidewalk = e.sidewalk,
		shoulder = e.shoulder,
		shoulderOut = e.shoulderOut,
		shoulderIn = e.shoulderIn,
		speed = e.speed,
		layer = e.layer,
		elevated = e.elevated,
		sunken = e.sunken,
		fill = e.fill,
		spans = e.spans,
		tunnel = e.tunnel,
		corridor = e.corridor,
		district = e.district,
		traffic = e.traffic,
		aux = e.aux,
		tags = e.tags,
		way = e.way,
	})
end

local function stripIntersection(it)
	-- positional: approach = { edge, flags (1 inbound + 2 outbound), heading x, heading z, lanes in };
	-- phase = { green, movement, approach indices... }
	local apps = {}
	for _, a in it.approaches do
		table.insert(apps, {
			a.edge,
			(if a.inbound then 1 else 0) + (if a.outbound then 2 else 0),
			math.floor(a.heading.X * 10000 + 0.5) / 10000,
			math.floor(a.heading.Z * 10000 + 0.5) / 10000,
			a.lanesIn,
		})
	end
	local phases = {}
	for _, ph in it.phases do
		local row = { ph.green, ph.movement }
		for _, k in ph.approaches do
			table.insert(row, k)
		end
		table.insert(phases, row)
	end
	return {
		node = it.node,
		control = it.control,
		radius = it.radius,
		approaches = apps,
		stopApproaches = it.stopApproaches,
		phases = phases,
		cycle = it.cycle,
		amber = it.amber,
		allRed = it.allRed,
		offset = it.offset,
		district = it.district,
	}
end

local function polyOut(poly)
	local out = {}
	for _, p in poly do
		table.insert(out, p.x)
		table.insert(out, p.z)
	end
	return out
end

function Bake.build(W)
	local pads, cuts = WorldTerrain.getEdits()
	local cutsOut = {}
	for _, c in cuts do
		table.insert(cutsOut, { name = c.name, points = polyOut(c.points), half = c.half, floorY = c.floorY })
	end
	local edges = {}
	for _, e in W.Edges do
		table.insert(edges, stripEdge(e))
	end
	local nodes = {}
	for _, n in W.Nodes do
		table.insert(nodes, n.pos)
	end
	local inters = {}
	for _, it in W.Intersections do
		table.insert(inters, stripIntersection(it))
	end
	local districts = {}
	for _, d in W.Districts do
		local poly = {}
		for _, p in d.polygon do
			table.insert(poly, p.X)
			table.insert(poly, p.Z)
		end
		table.insert(districts, {
			id = d.id,
			name = d.name,
			style = d.style,
			materials = d.materials,
			poly = poly,
			priority = d.priority,
			height = d.height,
			density = d.density,
			heat = d.heat,
			carTier = d.carTier,
			color = d.color,
			lot = d.lot,
			sidewalk = d.sidewalk,
		})
	end
	local subzones = {}
	for _, z in W.SubZones do
		local copy = {}
		for k, v in z do
			copy[k] = v
		end
		copy.poly = polyOut(z.poly)
		table.insert(subzones, copy)
	end
	local reserved = {}
	for _, r in W.ReservedAreas do
		table.insert(reserved, { name = r.name, poly = polyOut(r.poly) })
	end
	local spawnsCore = {
		hospital = W.Spawns.hospital,
		default = W.Spawns.default,
		bustedRelease = W.Spawns.bustedRelease,
	}
	local core = {
		version = W.VERSION,
		pads = pads,
		cuts = cutsOut,
		districts = districts,
		subzones = subzones,
		activeCore = polyOut(W.ActiveCore),
		reserved = reserved,
		nodes = nodes,
		edges = edges,
		intersections = inters,
		gores = W.Gores,
		weaves = W.Weaves,
		droppedEdges = W.DroppedEdges,
		pois = W.POIs,
		plots = W.Plots,
		landmarks = W.Landmarks,
		hotDrops = W.HotDrops,
		hotDropRules = W.HotDropRules,
		stuntJumps = W.StuntJumps,
		helipads = W.Helipads,
		safeZones = W.SafeZones,
		restrictedZones = W.RestrictedZones,
		routes = W.Routes,
		armoredRules = W.ArmoredRules,
		liftBridge = W.LiftBridge,
		heistDropoffs = W.HeistDropoffs,
		carSwaps = W.CarSwaps,
		onboardingOrder = W.OnboardingOrder,
		rails = W.Rails,
		paths = W.Paths,
		bridges = W.Bridges,
		levelCrossings = W.LevelCrossings,
		spawns = spawnsCore,
		stats = W.Stats,
		maxSpeed = W.MaxSpeed,
		pierDir = W.PierDir,
		ringTrench = W.RingTrench,
	}
	local lots = {
		parcels = W.Parcels,
		parking = W.Spawns.parking,
		offstreet = W.Spawns.offstreet,
		police = W.Spawns.police,
		streetscape = W.Streetscape,
		roadblocks = W.Roadblocks,
		etaFields = W.EtaFields,
		towerPlan = W.TowerPlan,
		propClusters = W.PropClusters,
		vistas = W.Vistas,
		signSamples = W.SignSamples,
		signVisibility = W.SignVisibility,
		lotsUnderDecks = W.LotsUnderDecks,
	}
	return core, lots
end

local HEADER = [[
--!strict
-- GENERATED by tools/world/bake.luau from the world generator (tools/world/gen). DO NOT EDIT BY HAND: edit the
-- generator, then run `lune run tools/world/bake.luau` (the worldlayout spec checks the hash below against a fresh
-- build). Loaded by Config/WorldLayout, which rebuilds the runtime tables (see docs/v2/world/WORLD_SPEC.md).
-- %s
local V = Vector3.new
local function C(x: number, y: number, z: number, yaw: number): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0)
end
local F = CFrame.new
local _ = F

]]

function Bake.render(data, what: string): (string, string)
	local out = {}
	ser(data, out, 0)
	local body = table.concat(out)
	local hash = string.format("%08x", WorldGen.fnv32(body))
	local text = string.format(HEADER, what)
		.. "local DATA = "
		.. body
		.. "\nDATA.hash = "
		.. string.format("%q", hash)
		.. "\nreturn (DATA :: any)\n"
	return text, hash
end

function Bake.bake(W)
	local core, lots = Bake.build(W)
	local coreText, coreHash = Bake.render(core, "Core world data (server + clients).")
	local lotsText, lotsHash = Bake.render(lots, "Heavy world data, loaded lazily by Config/WorldLayout (in practice: server).")
	return coreText, coreHash, lotsText, lotsHash
end

return Bake
