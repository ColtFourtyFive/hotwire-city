--!nocheck
-- Minimap / fullscreen map math: world <-> map transforms, radar rotation (camera-up), blip placement + rim clamping,
-- speed zoom, GPS target picking, area names, POI resolution, map-screen pan / zoom, and the generated config
-- (tiles + atlas) staying in sync with assets/minimap/manifest.json.
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")

	H.setMode("client")
	local Mini = H.require("src/client/Controllers/MinimapController")
	local MapScreen = H.require("src/client/Controllers/MapScreenController")
	H.setMode("server")
	local Cfg = H.require("src/shared/Config/Minimap")
	local MapConfig = H.require("src/shared/Config/Map")
	local MapLayout = H.require("src/shared/Util/MapLayout")

	-- Config -----------------------------------------------------------------------------------------------------
	t.test("map image covers the whole island", function()
		local lo, size = Cfg.WORLD_MIN, Cfg.WORLD_SIZE
		t.ok(lo.X <= -MapConfig.BOUNDARY and lo.Y <= -MapConfig.BOUNDARY, "min corner outside the walls")
		t.ok(lo.X + size >= MapConfig.BOUNDARY and lo.Y + size >= MapConfig.BOUNDARY, "max corner outside the walls")
		t.eq(#Cfg.TILES, Cfg.TILE_COUNT, "tile rows")
		for _, row in Cfg.TILES do
			t.eq(#row, Cfg.TILE_COUNT, "tile columns")
			for _, id in row do
				t.ok(id == "" or id:match("^rbxassetid://%d+$") ~= nil, "tile id format " .. tostring(id))
			end
		end
		t.ok(Cfg.TILE_PIXELS <= 1024, "tiles fit Roblox's 1024 px image limit")
	end)

	t.test("generated config matches the uploaded manifest", function()
		local path = "assets/minimap/manifest.json"
		if not fs.isFile(path) then
			return -- art not built in this checkout
		end
		local manifest = serde.decode("json", fs.readFile(path))
		for r = 1, Cfg.TILE_COUNT do
			for c = 1, Cfg.TILE_COUNT do
				local e = manifest[("tile_%d_%d"):format(r - 1, c - 1)]
				if e and e.assetId then
					t.eq(Cfg.TILES[r][c], "rbxassetid://" .. tostring(e.assetId), ("tile %d,%d"):format(r, c))
				end
			end
		end
		if manifest.blips and manifest.blips.assetId then
			t.eq(Cfg.ATLAS, "rbxassetid://" .. tostring(manifest.blips.assetId), "atlas id")
		end
	end)

	t.test("every icon the config names has an atlas cell", function()
		local function has(icon)
			t.ok(Cfg.ATLAS_CELLS[icon] ~= nil, "missing atlas cell " .. icon)
			local c = Cfg.ATLAS_CELLS[icon]
			t.ok(c[1] + c[3] <= 512 and c[2] + c[4] <= 512, "cell inside the 512 atlas: " .. icon)
		end
		for _, def in Cfg.POIS do
			has(def.icon)
		end
		for _, def in Cfg.BLIPS do
			has(def.icon)
		end
		for _, icon in Cfg.WAYPOINT_ICONS do
			has(icon)
		end
		has(Cfg.DEFAULT_WAYPOINT_ICON)
		for _, overlay in { "_vignette", "_glow", "_ring", "_arrow", "_disc" } do
			has(overlay)
		end
	end)

	t.test("the player's own waypoint wins the GPS", function()
		t.eq(Cfg.GPS.PRIORITY[1], Cfg.CUSTOM_WAYPOINT.ID, "custom waypoint first")
	end)

	-- Transforms --------------------------------------------------------------------------------------------------
	t.test("world <-> map round trip", function()
		local u, v = Mini.worldToMap(Cfg.WORLD_MIN.X, Cfg.WORLD_MIN.Y)
		t.near(u, 0, 1e-9, "min corner u")
		t.near(v, 0, 1e-9, "min corner v")
		u, v = Mini.worldToMap(0, 0)
		t.near(u, -Cfg.WORLD_MIN.X, 1e-9, "center u")
		local rng = H.Random.new(5)
		for _ = 1, 100 do
			local x, z = rng:NextNumber(-1000, 1000), rng:NextNumber(-1000, 1000)
			local a, b = Mini.mapToWorld(Mini.worldToMap(x, z))
			t.near(a, x, 1e-9, "x")
			t.near(b, z, 1e-9, "z")
		end
	end)

	t.test("headingOf: clockwise degrees from north (-Z)", function()
		t.near(Mini.headingOf(0, -1), 0, 1e-9, "north")
		t.near(Mini.headingOf(1, 0), 90, 1e-9, "east")
		t.near(math.abs(Mini.headingOf(0, 1)), 180, 1e-9, "south")
		t.near(Mini.headingOf(-1, 0), -90, 1e-9, "west")
		t.eq(Mini.headingOf(0, 0), 0, "degenerate")
	end)

	t.test("rotate is clockwise in screen space and invertible", function()
		local x, y = Mini.rotate(1, 0, 90)
		t.near(x, 0, 1e-9, "x")
		t.near(y, 1, 1e-9, "right turns to down")
		local rng = H.Random.new(9)
		for _ = 1, 50 do
			local px, py, deg = rng:NextNumber(-50, 50), rng:NextNumber(-50, 50), rng:NextNumber(-360, 360)
			local a, b = Mini.rotate(px, py, deg)
			local c, d = Mini.rotate(a, b, -deg)
			t.near(c, px, 1e-9, "x back")
			t.near(d, py, 1e-9, "y back")
			t.near(math.sqrt(a * a + b * b), math.sqrt(px * px + py * py), 1e-9, "length kept")
		end
	end)

	t.test("camera-up radar: whatever the camera faces is straight up", function()
		local scale = 0.6
		for _, look in { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0.6, -0.8 }, { -0.28, 0.96 } } do
			local rot = -Mini.headingOf(look[1], look[2])
			-- a point 100 studs ahead of the camera
			local x, y = Mini.radarOffset(look[1] * 100, look[2] * 100, scale, rot)
			t.near(x, 0, 1e-6, "ahead is centered")
			t.near(y, -100 * scale, 1e-6, "ahead is up")
			-- a point to the camera's right (look rotated 90 degrees clockwise: (-lz, lx))
			local rx, ry = Mini.radarOffset(-look[2] * 100, look[1] * 100, scale, rot)
			t.near(rx, 100 * scale, 1e-6, "right is right")
			t.near(ry, 0, 1e-6, "right is level")
			-- the player arrow points up when the character faces where the camera looks
			t.near(Mini.headingOf(look[1], look[2]) + rot, 0, 1e-9, "arrow up")
		end
	end)

	t.test("north-up radar keeps east to the right", function()
		local x, y = Mini.radarOffset(50, 0, 1, 0)
		t.near(x, 50, 1e-9, "east right")
		t.near(y, 0, 1e-9, "level")
		local _, y2 = Mini.radarOffset(0, -50, 1, 0)
		t.near(y2, -50, 1e-9, "north up")
	end)

	t.test("radarToWorld inverts radarOffset", function()
		local rng = H.Random.new(17)
		for _ = 1, 50 do
			local dx, dz = rng:NextNumber(-400, 400), rng:NextNumber(-400, 400)
			local scale, rot = rng:NextNumber(0.2, 2), rng:NextNumber(-180, 180)
			local sx, sy = Mini.radarOffset(dx, dz, scale, rot)
			local a, b = Mini.radarToWorld(sx, sy, scale, rot)
			t.near(a, dx, 1e-6, "dx")
			t.near(b, dz, 1e-6, "dz")
		end
	end)

	t.test("sticky blips clamp onto the rim", function()
		local x, y, out = Mini.clampToCircle(30, 40, 100)
		t.ok(not out, "inside stays")
		t.eq(x, 30)
		t.eq(y, 40)
		x, y, out = Mini.clampToCircle(300, 400, 100)
		t.ok(out, "outside clamps")
		t.near(x, 60, 1e-9, "direction kept x")
		t.near(y, 80, 1e-9, "direction kept y")
	end)

	-- Zoom ----------------------------------------------------------------------------------------------------------
	t.test("zoom eases out with speed while driving", function()
		local R = Cfg.RADAR
		t.eq(Mini.zoomFor(false, 300), R.ZOOM_FOOT, "on foot ignores speed")
		t.near(Mini.zoomFor(true, 0), R.ZOOM_DRIVE_MIN, 1e-9, "parked")
		t.near(Mini.zoomFor(true, R.ZOOM_SPEED_FULL * 3), R.ZOOM_DRIVE_MAX, 1e-9, "flat out")
		local prev = -1
		for s = 0, R.ZOOM_SPEED_FULL, 5 do
			local z = Mini.zoomFor(true, s)
			t.ok(z >= prev, "monotonic")
			prev = z
		end
		t.near(Mini.zoomFor(true, 0 / 0), R.ZOOM_DRIVE_MIN, 1e-9, "NaN speed")
	end)

	t.test("smooth is frame-rate independent", function()
		local a = Mini.smooth(100, 200, 0.1, 3)
		local b = Mini.smooth(Mini.smooth(100, 200, 0.05, 3), 200, 0.05, 3)
		t.near(a, b, 1e-9, "two half steps = one step")
		t.ok(a > 100 and a < 200, "moves toward the target")
		t.near(Mini.smooth(100, 200, 100, 3), 200, 1e-6, "converges")
	end)

	-- GPS -------------------------------------------------------------------------------------------------------------
	t.test("waypoint icons: exact id, prefix, default", function()
		t.eq(Mini.waypointIcon("hotdrop"), "flame")
		t.eq(Mini.waypointIcon("map"), "pin")
		t.eq(Mini.waypointIcon("dealer_rare3"), "car", "prefix match")
		t.eq(Mini.waypointIcon("something_new"), Cfg.DEFAULT_WAYPOINT_ICON)
	end)

	t.test("GPS target priority", function()
		local P = Vector3.new(1, 0, 1)
		local id = Mini.pickTarget({ { id = "hotdrop", pos = P }, { id = "home", pos = P }, { id = "map", pos = P } })
		t.eq(id, "map", "custom waypoint first")
		id = Mini.pickTarget({ { id = "hotdrop", pos = P }, { id = "home", pos = P } })
		t.eq(id, "home", "deliver before chasing a drop")
		id = Mini.pickTarget({ { id = "dealer_rare2", pos = P } })
		t.eq(id, nil, "informational waypoints never route")
		t.ok(not Mini.routable("dealer_rare7"), "dealer_rare not routable")
		id = Mini.pickTarget({ { id = "zeta", pos = P }, { id = "alpha", pos = P } })
		t.eq(id, "alpha", "unknown ids: deterministic id order")
		t.ok(Mini.priorityOf("zeta") > Mini.priorityOf("cashrain"), "unknown ids rank last")
	end)

	t.test("wanted search radius grows with stars", function()
		t.eq(Mini.wantedRadius(0), 0)
		local prev = 0
		for s = 1, 5 do
			local r = Mini.wantedRadius(s)
			t.ok(r > prev, "grows")
			prev = r
		end
		t.eq(Mini.wantedRadius(9), Mini.wantedRadius(5), "capped")
	end)

	t.test("police lights alternate", function()
		local hz = 2
		t.ok(Mini.flashOn(0, hz), "phase 0 on")
		t.ok(not Mini.flashOn(0.26, hz), "a quarter period later off")
		t.ok(Mini.flashOn(0.26, hz, 1), "the next unit is out of phase")
	end)

	-- Places ---------------------------------------------------------------------------------------------------------
	t.test("area names", function()
		t.eq(Mini.areaAt(Vector3.new(-240, 0, -240)), "DOWNTOWN")
		t.eq(Mini.areaAt(Vector3.new(400, 0, 20)), "MIDTOWN")
		t.eq(Mini.areaAt(Vector3.new(560, 0, 20)), "MARKET ROW")
		t.eq(Mini.areaAt(Vector3.new(-560, 0, 20)), "PALM SUBURBS")
		t.eq(Mini.areaAt(Vector3.new(720, 0, 20)), "SUNSET BEACH")
		t.eq(Mini.areaAt(Vector3.new(20, 0, -720)), "THE DOCKS")
		t.eq(Mini.areaAt(Vector3.new(20, 0, 720)), "SOUTH SHORE")
		t.eq(Mini.areaAt(Vector3.new(720, 0, 720)), "STUNT PARK")
		t.eq(Mini.areaAt(Vector3.new(-720, 0, 720)), "CITY PARK")
		t.eq(Mini.areaAt(Vector3.new(720, 0, -900)), "OCEAN PIER")
		t.eq(Mini.areaAt(Vector3.new(-720, 0, -720)), "CHOP YARD")
		t.eq(Mini.areaAt(MapLayout.poiCenter("Dealership")), "DEALERSHIP")
		t.eq(Mini.areaAt(MapLayout.poiCenter("SpawnPlaza")), "SPAWN PLAZA")
		t.eq(Mini.areaAt(Vector3.new(3000, 0, 0)), Cfg.AREA_DEFAULT)
	end)

	t.test("every POI blip resolves to a spot on the island", function()
		for _, def in Cfg.POIS do
			local list = Mini.poiPositions(def.at)
			t.ok(#list >= 1, def.id .. " has a position")
			for _, p in list do
				t.ok(math.abs(p.X) < MapConfig.BOUNDARY and math.abs(p.Z) < MapConfig.BOUNDARY, def.id .. " on island")
			end
		end
		t.eq(#Mini.poiPositions("spray"), #MapLayout.sprayZones(), "one blip per spray shop")
		t.eq(#Mini.poiPositions("poi:NoSuchPlace"), 0, "unknown POI resolves to nothing")
	end)

	t.test("route segment geometry", function()
		local cu, cv, len, angle = Mini.segmentGeometry(0, 0, 100, 0)
		local u0, v0 = Mini.worldToMap(50, 0)
		t.near(cu, u0, 1e-9, "center u")
		t.near(cv, v0, 1e-9, "center v")
		t.near(len, 100, 1e-9, "length")
		t.near(angle, 0, 1e-9, "east = 0 degrees")
		local _, _, _, a2 = Mini.segmentGeometry(0, 0, 0, 100)
		t.near(a2, 90, 1e-9, "south = 90 degrees (screen y down)")
	end)

	-- Fullscreen map ---------------------------------------------------------------------------------------------------
	t.test("fit view shows the whole island", function()
		for _, vp in { { 1280, 720 }, { 844, 390 }, { 1024, 768 }, { 2560, 1440 } } do
			local s = MapScreen.fitScale(vp[1], vp[2])
			local x0, y0 = MapScreen.worldToScreen(-MapConfig.BOUNDARY, -MapConfig.BOUNDARY, 0, 0, s, vp[1], vp[2])
			local x1, y1 = MapScreen.worldToScreen(MapConfig.BOUNDARY, MapConfig.BOUNDARY, 0, 0, s, vp[1], vp[2])
			t.ok(y0 >= 0 and y1 <= vp[2], "island fits vertically")
			t.ok(x0 >= 0 and x1 <= vp[1], "island fits horizontally")
		end
	end)

	t.test("screen <-> world round trip", function()
		local rng = H.Random.new(23)
		for _ = 1, 50 do
			local cx, cz, s = rng:NextNumber(-500, 500), rng:NextNumber(-500, 500), rng:NextNumber(0.2, 3)
			local x, z = rng:NextNumber(-900, 900), rng:NextNumber(-900, 900)
			local sx, sy = MapScreen.worldToScreen(x, z, cx, cz, s, 1280, 720)
			local a, b = MapScreen.screenToWorld(sx, sy, cx, cz, s, 1280, 720)
			t.near(a, x, 1e-6, "x")
			t.near(b, z, 1e-6, "z")
		end
	end)

	t.test("zoom keeps the point under the cursor fixed and respects limits", function()
		local cx, cz, s = 0, 0, 0.5
		local sx, sy = 900, 200
		local wx, wz = MapScreen.screenToWorld(sx, sy, cx, cz, s, 1280, 720)
		local ncx, ncz, ns = MapScreen.zoomAround(cx, cz, s, 1.5, sx, sy, 1280, 720, 0.3, 3)
		t.near(ns, 0.75, 1e-9, "zoomed")
		local ax, az = MapScreen.screenToWorld(sx, sy, ncx, ncz, ns, 1280, 720)
		t.near(ax, wx, 1e-6, "anchor x fixed")
		t.near(az, wz, 1e-6, "anchor z fixed")
		local _, _, capped = MapScreen.zoomAround(cx, cz, s, 100, sx, sy, 1280, 720, 0.3, 3)
		t.eq(capped, 3, "max zoom")
		local _, _, floor = MapScreen.zoomAround(cx, cz, s, 0.001, sx, sy, 1280, 720, 0.3, 3)
		t.eq(floor, 0.3, "min zoom")
		local fx, fz = MapScreen.clampCenter(1e6, -1e6)
		t.ok(fx < 1100 and fz > -1100, "pan stays near the island")
	end)

	t.test("tap vs drag", function()
		t.ok(MapScreen.isTap(3, 0.1), "short + still = tap")
		t.ok(not MapScreen.isTap(40, 0.1), "moved = drag")
		t.ok(not MapScreen.isTap(2, 2), "held = not a tap")
	end)
end
