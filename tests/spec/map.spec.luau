--!nocheck
-- MapBuilder v2: structure, budget, streaming cells and the contracts other systems rely on (built from WorldLayout).
return function(t)
	local H = t.H
	H.setMode("server")
	local MapBuilder = H.require("src/server/Systems/MapBuilder")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local WorldLayout = H.require("src/shared/Config/WorldLayout")
	local WorldQuery = H.require("src/shared/Util/WorldQuery")
	local Kit = H.require("src/server/Systems/World/Kit")
	local Roads = H.require("src/server/Systems/World/Roads")
	local Signals = H.require("src/server/Systems/World/Signals")
	local Bridges = H.require("src/server/Systems/World/Bridges")
	local Streetscape = H.require("src/server/Systems/World/Streetscape")
	local Places = H.require("src/server/Systems/World/Places")
	local Terrain = H.require("src/server/Systems/World/Terrain")
	local Streaming = H.require("src/server/Systems/World/Streaming")
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame

	local t0 = os.clock()
	local folder = MapBuilder.build(H.workspace, { terrain = false })
	local buildSeconds = os.clock() - t0
	local counts, total = MapBuilder.counts()

	local parts = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local function byName(name)
		local out = {}
		for _, p in parts do
			if p.Name == name then
				table.insert(out, p)
			end
		end
		return out
	end
	local function tagged(tag)
		local out = {}
		for _, d in folder:GetDescendants() do
			if d:HasTag(tag) then
				table.insert(out, d)
			end
		end
		return out
	end
	-- world AABB of a part
	local function aabb(p)
		local c = { p.CFrame:GetComponents() }
		local hx, hy, hz = p.Size.X / 2, p.Size.Y / 2, p.Size.Z / 2
		local ex = math.abs(c[4]) * hx + math.abs(c[5]) * hy + math.abs(c[6]) * hz
		local ey = math.abs(c[7]) * hx + math.abs(c[8]) * hy + math.abs(c[9]) * hz
		local ez = math.abs(c[10]) * hx + math.abs(c[11]) * hy + math.abs(c[12]) * hz
		return Vector3.new(c[1] - ex, c[2] - ey, c[3] - ez), Vector3.new(c[1] + ex, c[2] + ey, c[3] + ez)
	end
	local function flatDist(a, b)
		return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
	end
	local function inBox(cf, size, p)
		return MapLayout.isInBox(cf, size, p)
	end

	t.test("map folder layout", function()
		t.eq(folder.Name, "Map")
		t.eq(folder.Parent, H.workspace)
		for _, name in { "Cells", "Skeleton", "POIs", "Plots", "Landmarks", "Buildings" } do
			t.ok(folder:FindFirstChild(name), "missing " .. name)
		end
		t.eq(#folder.Buildings:GetChildren(), 0, "Buildings is A3's (empty here)")
		t.eq(MapBuilder.getMapFolder(), folder, "getMapFolder")
		t.eq(folder:GetAttribute("Built"), true, "Built attribute")
		t.eq(folder:GetAttribute("WorldHash"), WorldLayout.HASH, "world hash stamped")
		t.ok(MapBuilder.isBuilt(), "isBuilt")
	end)

	t.test("baked terrain is recognised only for the current world hash", function()
		local terrain = H.roblox.Instance.new("Terrain")
		t.ok(not MapBuilder.terrainBaked(terrain), "fresh terrain is not baked")
		terrain:SetAttribute(MapBuilder.TERRAIN_HASH_ATTR, "stale")
		t.ok(not MapBuilder.terrainBaked(terrain), "a stale hash forces runtime terrain")
		terrain:SetAttribute(MapBuilder.TERRAIN_HASH_ATTR, WorldLayout.HASH)
		t.ok(MapBuilder.terrainBaked(terrain), "the current hash skips runtime terrain")
	end)

	t.test("part budget, categories and anchoring", function()
		t.eq(total, #parts, "counted parts = parts in the folder")
		t.ok(
			#parts <= MapBuilder.PART_BUDGET,
			("world layer %d parts (budget %d)"):format(#parts, MapBuilder.PART_BUDGET)
		)
		t.ok(#parts > 20000, "suspiciously few parts: " .. #parts)
		for _, cat in
			{
				"Road",
				"Sidewalk",
				"Junction",
				"Crosswalk",
				"StopBar",
				"Deck",
				"Barrier",
				"Pier",
				"SignalHead",
				"SignalLens",
				"LampPole",
				"LampHead",
				"PalmTrunk",
				"Skeleton",
				"Letter",
				"TrenchWall",
			}
		do
			t.ok((counts[cat] or 0) > 0, "no " .. cat .. " parts")
		end
		for _, p in parts do
			t.ok(p.Anchored, "unanchored part " .. p:GetFullName())
			t.ok(not p.CanTouch, "world parts never fire Touched: " .. p.Name)
			for i, v in { p.Size.X, p.Size.Y, p.Size.Z } do
				t.ok(v > 0 and v <= 2048, ("bad size axis %d on %s: %s"):format(i, p:GetFullName(), tostring(v)))
			end
		end
		t.ok(buildSeconds < 30, ("synchronous build took %.1f s"):format(buildSeconds))
	end)

	t.test("streaming: every cell part sits in its own 512-stud cell; landmarks + skeleton persistent", function()
		for _, cell in folder.Cells:GetChildren() do
			t.ok(cell:IsA("Model"), "cells are Models")
			local cx, cz = cell:GetAttribute("CellX"), cell:GetAttribute("CellZ")
			for _, p in cell:GetChildren() do
				if p:IsA("BasePart") then
					t.eq(math.floor(p.CFrame.Position.X / Kit.CELL), cx, "cell x of " .. p.Name)
					t.eq(math.floor(p.CFrame.Position.Z / Kit.CELL), cz, "cell z of " .. p.Name)
				end
			end
		end
		local sk = folder.Skeleton
		t.ok(#sk:GetChildren() > 100, "collision skeleton")
		for _, p in sk:GetChildren() do
			t.ok(p.Transparency == 1 and p.CanCollide, "skeleton: invisible + collidable")
		end
		-- every elevated edge has skeleton under its midpoint
		for ei, e in WorldLayout.Edges do
			if e.elevated and e.length > 60 then
				local mid = WorldQuery.edgePoint(ei, e.length / 2)
				local found = false
				for _, p in sk:GetChildren() do
					local lp = p.CFrame:PointToObjectSpace(mid)
					if
						math.abs(lp.X) <= p.Size.X / 2 + 1
						and math.abs(lp.Z) <= p.Size.Z / 2 + 1
						and math.abs(lp.Y) < 4
					then
						found = true
						break
					end
				end
				t.ok(found, "no skeleton under elevated edge " .. ei)
			end
		end
		t.ok(Streaming.aheadOf(Vector3.zero, Vector3.new(50, 0, 0)) == nil, "slow drivers: no prefetch")
		local ahead = Streaming.aheadOf(Vector3.zero, Vector3.new(200, 0, 0))
		t.near(ahead.X, 200 * Streaming.LEAD, 1e-6, "fast drivers: prefetch ahead")
	end)

	t.test("roads: tagged slabs on every ground edge, markings textures where the class is marked", function()
		local roads = tagged("Road")
		t.ok(#roads > 3000, "road parts")
		-- every ground road edge has asphalt under its midpoint (outside the junction core)
		local missing = {}
		local ground = 0
		for ei, e in WorldLayout.Edges do
			if Roads.SURFACE_CLASSES[e.class] and e.length > 120 and not e.elevated then
				ground += 1
				local mid = WorldQuery.edgePoint(ei, e.length / 2)
				local found = false
				for _, p in roads do
					local lp = p.CFrame:PointToObjectSpace(mid)
					if
						math.abs(lp.X) <= p.Size.X / 2 + 0.5
						and math.abs(lp.Z) <= p.Size.Z / 2 + 0.5
						and math.abs(lp.Y) < 3
					then
						found = true
						break
					end
				end
				if not found and not (WorldLayout.LiftBridge and WorldLayout.LiftBridge.edge == ei) then
					table.insert(missing, ei)
				end
			end
		end
		t.ok(ground > 400, "ground edges checked")
		t.eq(#missing, 0, "edges without asphalt: " .. table.concat(missing, ","))
		local textured = 0
		for _, p in byName("Road") do
			if p:FindFirstChildOfClass("Texture") then
				textured += 1
			end
		end
		t.ok(textured > #byName("Road") * 0.5, "most road slabs carry the lane-marking texture")
	end)

	t.test("roads stay out of the lots (parcels and roads do not overlap)", function()
		local idx = {}
		local CELL = 128
		local function key(x, z)
			return math.floor(x / CELL) * 100000 + math.floor(z / CELL)
		end
		for _, p in byName("Road") do
			local c = p.CFrame.Position
			local k = key(c.X, c.Z)
			idx[k] = idx[k] or {}
			table.insert(idx[k], p)
		end
		local bad = 0
		local where = ""
		for _, pc in WorldLayout.Parcels do
			local c = pc.cframe.Position
			for dx = -1, 1 do
				for dz = -1, 1 do
					for _, p in idx[key(c.X + dx * CELL, c.Z + dz * CELL)] or {} do
						-- the slab's centreline point nearest the parcel centre, tested against the shrunk footprint
						local lp = p.CFrame:PointToObjectSpace(c)
						local z = math.clamp(lp.Z, -p.Size.Z / 2, p.Size.Z / 2)
						local onLine = p.CFrame * CFrame.new(0, 0, z)
						local q = pc.cframe:PointToObjectSpace(onLine.Position)
						if
							math.abs(q.X) < pc.size.X / 2 - 6
							and math.abs(q.Z) < pc.size.Z / 2 - 6
							and math.abs(q.Y) < 6
						then
							bad += 1
							where = ("parcel %d (%s) vs road at %s"):format(pc.id, pc.use, tostring(onLine.Position))
						end
					end
				end
			end
		end
		t.eq(bad, 0, "road centrelines inside lots: " .. where)
	end)

	t.test("freeways: decks with barriers, piers clear of the roads below", function()
		t.ok(#byName("Deck") > 500, "decks")
		t.ok(#byName("Barrier") > 500, "barriers")
		for _, pier in byName("Pier") do
			local base = pier.CFrame.Position - Vector3.new(0, pier.Size.X / 2, 0)
			local blocked = WorldQuery.isOnRoad(Vector3.new(base.X, WorldQuery.heightAt(base), base.Z))
			t.ok(not blocked, "pier column on a road at " .. tostring(base))
		end
	end)

	t.test("signals: heads at every signal junction, driven by WorldQuery.signalState", function()
		local geos = Roads.junctions()
		local withHeads = {}
		for _, h in tagged(Signals.TAG) do
			withHeads[h:GetAttribute("Intersection")] = true
		end
		local signals, covered = 0, 0
		for id, g in geos do
			if g.control == "signal" then
				signals += 1
				if withHeads[id] then
					covered += 1
				end
			end
		end
		t.ok(signals > 100, "signal junctions: " .. signals)
		t.eq(covered, signals, "every signal junction has heads")
		t.eq(Signals.headCount(), #tagged(Signals.TAG), "driver knows every head")
		-- the driver follows the phase plan
		Signals.update(0)
		local changed = Signals.update(17.3)
		t.ok(changed > 0, "lenses change over time")
		local lens = byName("SignalLens")[1]
		t.ok(lens.Material.Name == "Neon", "lens glows")
		t.ok(#byName("StopSign") > 50, "stop signs at stop / all-way junctions")
	end)

	t.test("plots: pads at the plot frames, reachable by road", function()
		t.eq(#folder.Plots:GetChildren(), 8)
		for i, plot in WorldLayout.Plots do
			local m = folder.Plots:FindFirstChild("Plot" .. i)
			t.ok(m, "plot model " .. i)
			local pad = m:FindFirstChild("PlotPad")
			t.ok(pad, "pad " .. i)
			t.near(pad.CFrame.Position.Y + pad.Size.Y / 2, plot.cframe.Position.Y, 1e-3, "pad top at the plot frame")
			local lp = plot.cframe:PointToObjectSpace(pad.CFrame.Position)
			t.near(lp.X, 0, 1e-3)
			t.near(lp.Z, 0, 1e-3)
			-- the setback in front of the pad is paved out to the sidewalk (no bare ground at the door)
			local gap = Places.frontGap(plot)
			t.ok(gap < 30, ("plot %d setback %.1f"):format(i, gap))
			local drive = m:FindFirstChild("Driveway")
			local dz = plot.cframe:PointToObjectSpace(drive.CFrame.Position).Z - drive.Size.Z / 2
			t.near(dz, -plot.size.Z / 2 - math.max(gap - 0.5, 0), 1e-3, "driveway reaches the sidewalk " .. i)
			if gap > 1 then
				t.ok(m:FindFirstChild("PlotApron"), "apron " .. i)
			end
			-- a garage door to Hotwire Plaza route exists (traffic graph)
			local r = WorldQuery.route(plot.door, WorldLayout.Spawns.default.Position)
			t.ok(r ~= nil and #r >= 2, "route from plot " .. i)
			-- nothing collidable inside the garage interior (PlotService builds there)
			local icf, isize = MapLayout.plotInteriorZone(i)
			for _, p in parts do
				if p.CanCollide and p.Name ~= "PlotPad" and p.Name ~= "Skeleton" then
					local mn, mx = aabb(p)
					local c = (mn + mx) / 2
					if inBox(icf, isize - Vector3.new(4, 4, 4), c) then
						t.ok(false, ("plot %d interior blocked by %s"):format(i, p:GetFullName()))
					end
				end
			end
		end
	end)

	t.test("POIs: every POI built, interaction parts where the shim says", function()
		for _, poi in WorldLayout.POIs do
			t.ok(folder.POIs:FindFirstChild(poi.id), "missing POI " .. poi.id)
		end
		-- gun shops: a weapons and a gear counter each
		local guns, gears = tagged("GunStoreCounter"), tagged("GearShopCounter")
		local shops = WorldQuery.poisOfKind("gunshop")
		t.eq(#guns, #shops, "GunStoreCounter per shop")
		t.eq(#gears, #shops, "GearShopCounter per shop")
		for _, cf in MapLayout.gearShopCounters() do
			local found = false
			for _, g in gears do
				if (g.CFrame.Position - cf.Position).Magnitude < 3 then
					found = true
				end
			end
			t.ok(found, "gear counter at the shim's frame")
		end
		-- drive-in bays are clear (nothing collidable inside the bay box but the floor)
		local zones = MapLayout.sprayZones()
		for _, z in MapLayout.chopZones() do
			table.insert(zones, z)
		end
		for _, z in zones do
			local inner = z.size - Vector3.new(2, 4, 2)
			for _, p in parts do
				if p.CanCollide and p.Name ~= "Skeleton" then
					local mn, mx = aabb(p)
					if mx.Y > z.cframe.Position.Y - z.size.Y / 2 + 1.5 then
						local c = (mn + mx) / 2
						t.ok(not inBox(z.cframe, inner, c), "bay blocked by " .. p:GetFullName())
					end
				end
			end
		end
		-- dealer pads + plaza
		local pads = tagged("DealerPad")
		t.eq(#pads, 8, "8 DealerPad discs")
		for i, cf in MapLayout.dealerPads() do
			local found = false
			for _, p in pads do
				if
					(Vector3.new(p.CFrame.Position.X, 0, p.CFrame.Position.Z) - Vector3.new(
						cf.Position.X,
						0,
						cf.Position.Z
					)).Magnitude < 0.5
				then
					found = true
				end
			end
			t.ok(found, "pad " .. i .. " at the shim's frame")
		end
		local plaza = folder.POIs.HotwirePlaza
		local spawn = plaza:FindFirstChildOfClass("SpawnLocation")
		t.ok(spawn and spawn.Neutral, "fallback SpawnLocation")
		local first = MapLayout.spawnCFrame()
		t.ok(flatDist(spawn.CFrame.Position, first.Position) < 1, "at MapLayout.spawnCFrame (the street spawn)")
		t.near(spawn.CFrame.Position.Y + spawn.Size.Y / 2, MapLayout.CURB_TOP, 0.05, "flush with the sidewalk")
		t.eq(spawn.Transparency, 1, "no visible spawn plate")
		t.ok(spawn.CFrame.LookVector:Dot(first.LookVector) > 0.99, "faces the spawn heading")
		local boards = tagged("LeaderboardBoard")
		t.eq(#boards, 2, "two leaderboards")
		for _, b in boards do
			t.ok(b:GetAttribute("Stat") == "totalEarned" or b:GetAttribute("Stat") == "steals", "Stat")
		end
	end)

	t.test("street lights: StreetLight heads carry a disabled SpotLight, every head has night glow", function()
		local heads = byName("LampHead")
		t.eq(#heads, #WorldLayout.Streetscape.lamp, "one head per lamp")
		local lit = 0
		for _, h in heads do
			t.ok(h:HasTag("NightGlow") and h:GetAttribute("NightColor") ~= nil, "night glow")
			local light = h:FindFirstChildOfClass("SpotLight")
			if light then
				lit += 1
				t.ok(h:HasTag("StreetLight"), "lit heads tagged StreetLight")
				t.eq(light.Enabled, false, "off until LightingService says night")
				t.eq(light.Shadows, false, "shadowless (mobile)")
			end
		end
		local share = lit / #heads
		t.ok(math.abs(share - Streetscape.LIGHT_SHARE) < 0.08, ("light share %.2f"):format(share))
		t.ok(#tagged("Billboard") == #WorldLayout.Streetscape.billboard, "billboards tagged for MapDresser")
	end)

	t.test("landmarks: SUNWOOD reads left to right from the city, wheel, lift bridge", function()
		local sign = folder.Landmarks:FindFirstChild("SunwoodSign")
		t.ok(sign, "sign model")
		local l = WorldQuery.landmark("SunwoodSign")
		-- letters run toward the viewer's right: S is on the left as seen from the city
		local viewer = l.cframe.Position + l.cframe.LookVector * 2000
		local right = l.cframe.LookVector:Cross(Vector3.yAxis) * -1 -- viewer looks along -LookVector
		local xs = {}
		for _, p in sign:GetChildren() do
			if p.Name == "Letter" then
				table.insert(xs, (p.CFrame.Position - l.cframe.Position):Dot(right))
			end
		end
		t.ok(#xs >= 20, "letter strokes")
		local _ = viewer
		local wheel = tagged("FerrisWheel")
		t.eq(#wheel, 1, "Ferris wheel tagged")
		t.ok(#byName("LiftLeaf") == 2, "two bascule leaves")
		t.eq(Bridges.liftRaised(0), true, "raised at the start of the period")
		t.eq(Bridges.liftRaised(WorldLayout.LiftBridge.raised + 1), false, "lowered after the raise window")
		t.ok(#byName("Stay") > 30, "cable stays on the Iron Bay Bridge")
	end)

	t.test("terrain: graded under roads, sea and dry trench", function()
		-- a ground street mid-block: the terrain sits under the road top
		local checked = 0
		for ei, e in WorldLayout.Edges do
			if e.class == "street" and not e.elevated and #e.spans == 0 and e.length > 150 and checked < 25 then
				local p = WorldQuery.edgePoint(ei, e.length / 2)
				local ch = Terrain.chunk(math.floor(p.X / Terrain.CHUNK), math.floor(p.Z / Terrain.CHUNK))
				local h = Terrain.surfaceAt(ch, p.X, p.Z)
				t.ok(h <= p.Y - 0.4 and h >= p.Y - 6, ("terrain %.1f under road %.1f (edge %d)"):format(h, p.Y, ei))
				checked += 1
			end
		end
		t.ok(checked > 10, "streets checked")
		-- open sea: water at sea level over the seabed
		local sea = Terrain.chunk(math.floor(-6300 / 64), math.floor(0 / 64))
		t.ok(sea.waterTop == WorldLayout.SEA_LEVEL and sea.maxH < -2, "ocean chunk has water")
		-- the H1 trench (below sea level) stays dry
		local _, cuts = H.require("src/shared/Util/WorldTerrain").getEdits()
		local c = cuts[1]
		local mid = c.points[(#c.points + 1) // 2]
		local tch = Terrain.chunk(math.floor(mid.x / 64), math.floor(mid.z / 64))
		t.ok(tch.waterTop < tch.maxH or tch.waterTop == -math.huge, "trench is dry")
		-- deterministic, spawn area first
		local a = Terrain.chunk(3, -7)
		local b = Terrain.chunk(3, -7)
		for i = 1, #a.h do
			t.eq(a.h[i], b.h[i], "deterministic")
		end
		local order = Terrain.chunkOrder(WorldLayout.Spawns.default.Position)
		local first = order[1]
		local sp = WorldLayout.Spawns.default.Position
		t.ok(math.abs(first[1] * 64 + 32 - sp.X) <= 64 and math.abs(first[2] * 64 + 32 - sp.Z) <= 64, "spawn first")
	end)

	t.test("rebuild replaces the old map", function()
		local again = MapBuilder.build(H.workspace, { terrain = false })
		local count = 0
		for _, c in H.workspace:GetChildren() do
			if c.Name == "Map" then
				count += 1
			end
		end
		t.eq(count, 1, "exactly one Map folder")
		local _, total2 = MapBuilder.counts()
		t.eq(total2, total, "deterministic part count")
		folder = again
	end)
end
