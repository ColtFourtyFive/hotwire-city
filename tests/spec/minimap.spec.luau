--!nocheck
-- Minimap / fullscreen map math: world <-> map transforms, radar rotation (camera-up), blip placement + rim clamping,
-- speed zoom, GPS target picking, area names, POI resolution, map-screen pan / zoom, and the generated config
-- (tiles + atlas) staying in sync with assets/minimap/manifest.json.
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local Vector2 = H.roblox.Vector2
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

	t.test("fit view leaves room for the header", function()
		local top = 84
		local s = MapScreen.fitScale(1280, 720, top)
		t.ok(s < MapScreen.fitScale(1280, 720), "smaller than without a header")
		local cz = MapScreen.fitCenterZ(s, top)
		local _, y0 = MapScreen.worldToScreen(0, -MapConfig.BOUNDARY, 0, cz, s, 1280, 720)
		local _, y1 = MapScreen.worldToScreen(0, MapConfig.BOUNDARY, 0, cz, s, 1280, 720)
		t.ok(y0 >= top - 1e-6, "island top below the header")
		t.ok(y1 <= 720 + 1e-6, "island bottom on screen")
		t.near((y0 + y1) / 2, top + (720 - top) / 2, 1e-6, "centered in the free area")
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

	-- Radar runtime (headless): GPS route -> pills, trimming, re-route when straying, arrival clears the waypoint.
	t.test("radar runtime: route, trim, re-route, arrival", function()
		H.setMode("client")
		local lp = H.localPlayer
		local char = H.roblox.Instance.new("Model")
		char.Name = "MinimapTestChar"
		local root = H.roblox.Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.CFrame = H.roblox.CFrame.new(-300, 3, 160)
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		root.Parent = char
		char.Parent = H.workspace
		lp.Character = char
		pcall(function()
			lp.UserId = 4242
		end)
		local Kit = H.require("src/client/UI/Kit")
		-- Lune instances have no engine events: a plain ScreenGui instead of Kit.screen's auto-scaling one
		Kit.screen = function(name, order)
			local g = H.roblox.Instance.new("ScreenGui")
			g.Name = name
			g.DisplayOrder = order
			g.Parent = lp:FindFirstChild("PlayerGui")
			return g
		end
		-- a police car with its siren on near the player, and two owned garages (yours + a rival's)
		local cop = H.roblox.Instance.new("Model")
		cop.Name = "Cop"
		local copBody = H.roblox.Instance.new("Part")
		copBody.CFrame = H.roblox.CFrame.new(-260, 3, 180)
		copBody.Position = Vector3.new(-260, 3, 180) -- Lune parts don't derive Position from CFrame
		copBody.Parent = cop
		cop.PrimaryPart = copBody
		cop:SetAttribute("Siren", true)
		cop:AddTag("Police")
		cop.Parent = H.workspace
		local plots = H.roblox.Instance.new("Folder")
		plots.Name = "Plots"
		for i, owner in { [1] = 4242, [8] = 777 } do
			local plot = H.roblox.Instance.new("Model")
			plot.Name = "Plot" .. i
			plot:SetAttribute("OwnerUserId", owner)
			plot.Parent = plots
		end
		plots.Parent = H.workspace
		local M = H.require("src/client/Controllers/MinimapController")
		local WP = H.require("src/client/Controllers/WaypointController")
		local ok, err = pcall(function()
			M.mount()
			t.eq(#M.getPolice(), 1, "police car tracked")
			local function run(frames)
				for _ = 1, frames do
					M.step(1 / 30)
				end
			end
			WP.set(Cfg.CUSTOM_WAYPOINT.ID, Vector3.new(480, 0, -400), nil, "WAYPOINT")
			run(10)
			local pts = M.getRoute()
			t.ok(pts ~= nil and #pts >= 2, "route to the custom waypoint")
			local id = M.getGpsTarget()
			t.eq(id, Cfg.CUSTOM_WAYPOINT.ID, "GPS follows the custom waypoint")
			local radar = lp.PlayerGui.HC_Minimap.Radar
			local shown = 0
			for _, f in radar.Clip.Spin.World.Route.Core:GetChildren() do
				if f.Visible then
					shown += 1
				end
			end
			t.ok(shown >= 1, "route pills drawn")
			-- blips: the waypoint (sticky), your garage (sticky), the cop; the rival garage is out of range
			local blips = 0
			for _, b in radar.Clip.Blips:GetChildren() do
				if b.Visible then
					blips += 1
				end
			end
			t.ok(blips >= 3, "waypoint + own garage + police blips, got " .. blips)
			t.ok(radar.Distance.Visible, "distance pill shown")
			local before = M.getRemaining()
			t.ok(before > 0, "remaining distance")
			-- drive 200 studs along the first leg: the remaining distance shrinks, same route
			root.CFrame = H.roblox.CFrame.new(-100, 3, 160)
			run(20)
			t.ok(M.getRemaining() < before - 150, "trimmed as you drive")
			-- stray far away: re-routed from the new spot
			root.CFrame = H.roblox.CFrame.new(-700, 3, 700)
			run(40)
			local r2 = M.getRoute()
			t.ok(r2 ~= nil and (r2[1] - Vector3.new(-700, 0, 700)).Magnitude < 80, "re-routed from where you are")
			-- arrive: the custom waypoint clears itself and the route goes away
			root.CFrame = H.roblox.CFrame.new(475, 3, -395)
			run(20)
			t.ok(not WP.has(Cfg.CUSTOM_WAYPOINT.ID), "custom waypoint cleared on arrival")
			t.eq(M.getRoute(), nil, "route cleared")
			t.ok(not radar.Distance.Visible, "distance pill hidden")
		end)
		-- leave the shared harness player as other specs expect it (Destroy clears the Character ref)
		char:Destroy()
		cop:Destroy()
		plots:Destroy()
		local gui = lp.PlayerGui:FindFirstChild("HC_Minimap")
		if gui then
			gui:Destroy()
		end
		H.setMode("server")
		t.ok(ok, tostring(err))
	end)

	-- Phones: HUD layout with the radar in the corner (review: menu into the thumbstick zone, feed into the cash pill)
	local PHONES = { { 844, 390 }, { 667, 375 }, { 640, 360 }, { 896, 414 }, { 932, 430 }, { 736, 414 } }
	local HUD_TOP = 6 -- HUDController.layout: touch buttons start this far below the topbar inset
	local function phoneCanvas(w, h, topbar, floor)
		local s = math.clamp(math.min(w / 1280, h / 720), 0.55, 1.6)
		if floor then
			s = math.max(s, floor)
		end
		return s, w / s, (h - topbar) / s
	end

	t.test("phones: the HUD menu strip stays above the thumbstick zone next to the radar", function()
		H.setMode("client")
		local HUD = H.require("src/client/Controllers/HUDController")
		local M = H.require("src/client/Controllers/MinimapController")
		H.setMode("server")
		local count = #HUD.MENU
		for _, vp in PHONES do
			for _, topbar in { 36, 58 } do
				local s, cw, ch = phoneCanvas(vp[1], vp[2], topbar)
				local tag = ("%dx%d topbar %d"):format(vp[1], vp[2], topbar)
				local m = M.touchMetrics(cw, ch, s)
				local strip = HUD.touchStripLayout(count, cw, ch, m.reserve, HUD_TOP)
				t.ok(strip.fits, tag .. ": strip fits")
				t.ok(
					strip.bottom <= ch / 3 + 1e-6,
					("%s: menu bottom %.1f <= third %.1f"):format(tag, strip.bottom, ch / 3)
				)
				t.ok(strip.cols * strip.rows >= count, tag .. ": every button placed")
				t.ok(strip.left >= 12 + m.diameter + Cfg.RADAR.TOUCH_GAP - 1e-6, tag .. ": buttons right of the radar")
				-- the menu never reaches the top-center cash pill + status stack
				local right = strip.left + strip.cols * (strip.cell + 6) - 6
				t.ok(right <= cw / 2 - 168 + 1e-6, tag .. ": clear of the cash pill")
				-- the radar (a button) ends above the thumbstick zone too
				t.ok(Cfg.RADAR.TOUCH_TOP + m.diameter <= ch / 3, tag .. ": radar above the thumbstick zone")
				-- 16:9 phones get the compact radar; the 844-wide ones keep the big one
				if vp[1] / vp[2] < 1.9 then
					t.eq(m.diameter, Cfg.RADAR.TOUCH_SIZE_COMPACT, tag .. ": compact radar")
				end
			end
		end
		-- a tablet keeps the big radar (no squeeze there)
		local s, cw, ch = phoneCanvas(1024, 768, 36)
		t.eq(M.touchMetrics(cw, ch, s).diameter, Cfg.RADAR.TOUCH_SIZE, "iPad: big radar")
		-- with no radar the strip keeps its old place
		local _, cw2, ch2 = phoneCanvas(844, 390, 36)
		local strip = HUD.touchStripLayout(count, cw2, ch2, 0, 6)
		t.eq(strip.left, 12)
		t.eq(strip.cell, 76, "roomy phone without the radar: big cells")
	end)

	t.test("phones: the event feed hugs the left edge below the radar block and the menu", function()
		H.setMode("client")
		local HUD = H.require("src/client/Controllers/HUDController")
		local M = H.require("src/client/Controllers/MinimapController")
		H.setMode("server")
		for _, vp in PHONES do
			for _, topbar in { 36, 58 } do
				local s, cw, ch = phoneCanvas(vp[1], vp[2], topbar)
				local tag = ("%dx%d topbar %d"):format(vp[1], vp[2], topbar)
				local m = M.touchMetrics(cw, ch, s)
				local strip = HUD.touchStripLayout(#HUD.MENU, cw, ch, m.reserve, HUD_TOP)
				for _, menuShown in { true, false } do
					local x, y = HUD.touchFeedAnchor(strip, menuShown, m.bottom)
					t.eq(x, 12, tag .. ": feed at the left edge")
					t.ok(y >= m.bottom + 8, tag .. ": below the radar block")
					if menuShown then
						t.ok(y >= strip.bottom + 8, tag .. ": below the menu strip")
					end
				end
			end
		end
		-- no radar: the old anchor (under the strip, at its left)
		local strip = HUD.touchStripLayout(#HUD.MENU, 1535, 603, 0, 6)
		local x, y = HUD.touchFeedAnchor(strip, true, 0)
		t.eq(x, strip.left)
		t.eq(y, strip.bottom + 8)
	end)

	t.test("phones: radar text and blips get the touch readability boost, the circle does not", function()
		local R = Cfg.RADAR
		t.eq(Mini.touchBoost(0.55, false), 1, "desktop: none")
		t.eq(Mini.touchBoost(1, true), 1, "big screens: none")
		local b = Mini.touchBoost(0.55, true)
		t.near(b, 0.72 / 0.55, 1e-9, "phones: up to the touch scale floor")
		t.ok(b <= R.TOUCH_BOOST_MAX, "capped")
		t.eq(Mini.touchBoost(0.3, true), R.TOUCH_BOOST_MAX, "cap")
		-- area name ~13 real px, blips ~16 real px on a phone
		t.ok(R.AREA_TEXT_TOUCH * b * 0.55 >= 12.5, "area name readable")
		t.ok(R.BLIP_SIZE * b * 0.55 >= 15, "blips readable")
		t.ok(R.BLIP_SIZE_SMALL * b * 0.55 >= 8.5, "police / player dots readable")
		-- the boost never changes the radar size or its reserve
		local m1 = Mini.touchMetrics(1200, 600, 0.55)
		local m2 = Mini.touchMetrics(1200, 600, 1)
		t.eq(m1.diameter, m2.diameter)
		t.eq(m1.reserve, m2.reserve)
	end)

	t.test("desktop: the HUD keeps clear of what pokes out above the radar", function()
		local R = Cfg.RADAR
		local glow = (1.22 - 1) / 2 * R.DESKTOP_SIZE -- WantedGlow is 1.22x the radar
		local north = 22 / 2 - 3 -- N marker (22 px) centered 3 px inside the rim
		t.ok(R.TOP_CLEARANCE >= glow, "wanted glow")
		t.ok(R.TOP_CLEARANCE >= north + 4, "N marker")
	end)

	t.test("N marker fades only while it passes under the map button", function()
		local R = Cfg.RADAR
		t.near(Mini.northFade(R.MAP_BUTTON_ANGLE), 1, 1e-9, "under the button: hidden")
		t.near(Mini.northFade(R.MAP_BUTTON_ANGLE + 360), 1, 1e-9, "wraps")
		t.eq(Mini.northFade(0), 0, "north up: visible")
		t.eq(Mini.northFade(R.MAP_BUTTON_ANGLE + R.NORTH_FADE_DEG), 0, "edge of the fade")
		t.eq(Mini.northFade(R.MAP_BUTTON_ANGLE - 180), 0, "opposite side")
		local a = Mini.northFade(R.MAP_BUTTON_ANGLE + 8)
		t.near(a, Mini.northFade(R.MAP_BUTTON_ANGLE - 8), 1e-9, "symmetric")
		t.ok(a > 0 and a < 1, "partial")
		-- the button really sits on N's circle at that angle (why the fade exists)
		local x, y = Mini.rotate(0, -1, R.MAP_BUTTON_ANGLE)
		t.near(x, -y, 1e-9, "45 degrees, top-right")
	end)

	t.test("unreachable GPS targets back off", function()
		local G = Cfg.GPS
		t.eq(Mini.retryDelay(0), 0)
		t.eq(Mini.retryDelay(1), G.REROUTE_MIN_INTERVAL)
		t.eq(Mini.retryDelay(2), G.REROUTE_MIN_INTERVAL * 2)
		t.eq(Mini.retryDelay(50), G.FAIL_RETRY_MAX, "capped")
		local prev = 0
		for i = 1, 10 do
			t.ok(Mini.retryDelay(i) >= prev, "never shrinks")
			prev = Mini.retryDelay(i)
		end
	end)

	-- Route renderer: slot 1 is always the head (the per-frame fast path rewrites only that slot)
	t.test("drawRoute keeps the head in slot 1, even when it has no length", function()
		H.setMode("client")
		local M = H.require("src/client/Controllers/MinimapController")
		H.setMode("server")
		local holder = H.roblox.Instance.new("Frame")
		local r = M.newRouteRenderer(holder, 6, 2)
		local white = H.roblox.Color3.new(1, 1, 1)
		local function visible()
			local out = {}
			for i = 1, r.used do
				if r.cores[i].Visible then
					table.insert(out, i)
				end
			end
			return out
		end
		-- standing on the road point closest to an off-road target: route {Q, Q} + a faded line to the target
		local Q = Vector3.new(-640, 0, -240)
		local target = Vector3.new(-686, 0, -240)
		M.drawRoute(r, { Q, Q }, 1, Q.X, Q.Z, white, target)
		t.eq(r.used, 2, "head slot + tail")
		t.ok(not r.cores[1].Visible, "zero-length head hidden (no stray dot)")
		t.ok(r.cores[2].Visible, "tail drawn")
		t.near(r.cores[2].BackgroundTransparency, 0.35, 1e-6, "tail is the faded one")
		-- next frame: the fast path moves the head; the tail must survive
		for _ = 1, 5 do
			M.moveRouteHead(r, Q.X, Q.Z, Q.X, Q.Z)
		end
		t.ok(r.cores[2].Visible, "tail still drawn after moveRouteHead")
		t.eq(#visible(), 1)
		-- normal route: slot 1 runs from the player's spot to the next corner
		local pts = { Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(100, 0, 100) }
		M.drawRoute(r, pts, 1, 40, 0, white, nil)
		t.eq(r.used, 2)
		local u0, v0 = M.worldToMap(70, 0)
		t.near(
			r.cores[1].Position.X.Scale * Cfg.WORLD_SIZE,
			u0,
			1e-3,
			"head centered between the player and the corner"
		)
		t.near(r.cores[1].Position.Y.Scale * Cfg.WORLD_SIZE, v0, 1e-3)
		M.moveRouteHead(r, 90, 0, 100, 0)
		local u1 = M.worldToMap(95, 0)
		t.near(r.cores[1].Position.X.Scale * Cfg.WORLD_SIZE, u1, 1e-3, "fast path moved the head")
		t.ok(r.cores[2].Visible, "rest of the route untouched")
		M.drawRoute(r, nil, 1, 0, 0, white, nil)
		t.eq(#visible(), 0, "cleared")
	end)

	-- Fullscreen map ------------------------------------------------------------------------------------------------------
	t.test("map legend fits phones (two columns above its button, scrolls when short)", function()
		local n = #MapScreen.legendEntries()
		t.ok(n >= 17, "every blip kind explained, got " .. n)
		local top = Cfg.MAP.CHROME_TOP
		for _, vp in PHONES do
			for _, topbar in { 36, 58 } do
				local _, cw, ch = phoneCanvas(vp[1], vp[2], topbar, 0.72)
				local tag = ("%dx%d topbar %d"):format(vp[1], vp[2], topbar)
				local lay = MapScreen.legendLayout(n, cw, ch, true)
				t.eq(lay.cols, 2, tag)
				t.ok(ch - lay.bottom - lay.height >= top - 1e-6, tag .. ": below the title / hint")
				t.ok(lay.bottom >= 18 + 48 + 8, tag .. ": above the LEGEND / HIDE button")
				-- clear of the zoom column (64 px + 18 margin) on the right
				t.ok(18 + lay.width <= cw - 18 - 64 - 18, tag .. ": clear of the zoom buttons")
			end
		end
		-- desktop: one column at the bottom-left; 720p shows every row without scrolling
		local lay = MapScreen.legendLayout(n, 1280, 720, false)
		t.eq(lay.cols, 1)
		t.ok(not lay.scrolls, "720p fits")
		t.ok(720 - lay.bottom - lay.height >= top, "below the header")
		-- a very short window scrolls instead of overflowing
		local short = MapScreen.legendLayout(n, 1280, 400, false)
		t.ok(short.scrolls, "scrolls")
		t.ok(400 - short.bottom - short.height >= top - 1e-6, "still below the header")
	end)

	t.test("district names step aside from blips and each other", function()
		local twelve = { 12, 12, 12, 12, 12 }
		local y = MapScreen.placeLabel(100, 100, 40, 10, {}, {}, {}, {}, 0)
		t.eq(y, 100, "free spot: stays")
		local y2 = MapScreen.placeLabel(100, 100, 40, 10, { 120 }, { 104 }, twelve, twelve, 1)
		t.ok(y2 ~= nil and y2 ~= 100, "moved off the blip")
		t.ok(math.abs(y2 - 104) >= 10 + 12, "box clears the blip")
		local blocked = MapScreen.placeLabel(100, 100, 40, 10, { 100, 100, 100, 100, 100 }, {
			100,
			76,
			124,
			52,
			148,
		}, twelve, twelve, 5)
		t.eq(blocked, nil, "nowhere to go: skipped")
		-- a wide name already placed just above: the next one steps down, not onto it
		local y3 = MapScreen.placeLabel(100, 100, 40, 10, { 130 }, { 90 }, { 60 }, { 12 }, 1)
		t.ok(y3 ~= nil and y3 >= 90 + 12 + 10, "clear of the other name")
		-- the config names sit clear of the garage rows (z = -+681) at the phone fit zoom
		for _, d in Cfg.DISTRICTS do
			if d.name == "THE DOCKS" or d.name == "SOUTH SHORE" then
				t.ok(math.abs(math.abs(d.z) - 681) >= 120, d.name .. " off the garage row")
			end
		end
	end)

	-- shared headless setup for the runtime specs below: a character at `at`, Kit stubs, returns a cleanup function
	local function headless(at, touch)
		H.setMode("client")
		local lp = H.localPlayer
		local char = H.roblox.Instance.new("Model")
		char.Name = "MinimapRuntimeChar"
		local root = H.roblox.Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.CFrame = H.roblox.CFrame.new(at)
		root.Position = at -- Lune parts don't derive Position from CFrame
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		root.Parent = char
		char.Parent = H.workspace
		lp.Character = char
		pcall(function()
			lp.UserId = 4242
		end)
		local Kit = H.require("src/client/UI/Kit")
		Kit.screen = function(name, order)
			local g = H.roblox.Instance.new("ScreenGui")
			g.Name = name
			g.DisplayOrder = order
			g.Parent = lp:FindFirstChild("PlayerGui")
			return g
		end
		Kit.juice = function() end -- Lune buttons have no engine events
		Kit.uiScale = function()
			return 0.72
		end
		Kit.isTouch = function()
			return touch == true
		end
		local extra = {}
		local function cleanup()
			char:Destroy()
			for _, inst in extra do
				inst:Destroy()
			end
			for _, name in { "HC_Minimap", "HC_Map", "HC_MapChrome" } do
				local gui = lp.PlayerGui:FindFirstChild(name)
				if gui then
					gui:Destroy()
				end
			end
			lp:SetAttribute("Wanted", nil)
			H.setMode("server")
		end
		return root, extra, cleanup
	end

	local function visibleCores(radar)
		local out = {}
		for _, f in radar.Clip.Spin.World.Route.Core:GetChildren() do
			if f.Visible then
				table.insert(out, f)
			end
		end
		return out
	end

	t.test("radar runtime: map moves every frame, 30 Hz work keeps an even cadence", function()
		local root, _, cleanup = headless(Vector3.new(-300, 3, 160), false)
		local ok, err = pcall(function()
			local M = H.require("src/client/Controllers/MinimapController")
			M.mount()
			local radar = H.localPlayer.PlayerGui.HC_Minimap.Radar
			t.ok(radar.Clip.Blips.ZIndex > radar.Clip.Vignette.ZIndex, "blips above the edge vignette")
			M.step(1 / 60)
			-- running (4 studs a frame, > 1 px: UDim offsets are whole pixels): the map follows every frame (it used to
			-- step at ~24 Hz)
			local changes, last = 0, radar.Clip.Spin.World.Position
			for i = 1, 60 do
				root.CFrame = H.roblox.CFrame.new(-300 + 4 * i, 3, 160)
				M.step(1 / 60)
				local p = radar.Clip.Spin.World.Position
				if p ~= last then
					changes += 1
				end
				last = p
			end
			t.eq(changes, 60, "map position updated every frame")
			-- wanted visuals run at RADAR.UPDATE_HZ: ~30 updates a second even with frame-time jitter
			H.localPlayer:SetAttribute("Wanted", 2)
			local updates, lastT = 0, -1
			for i = 1, 120 do
				M.step(if i % 2 == 0 then 1 / 60 + 0.0012 else 1 / 60 - 0.0012)
				local tr = radar.Clip.Spin.World.WantedArea.ImageTransparency
				if tr ~= lastT then
					updates += 1
				end
				lastT = tr
			end
			t.ok(updates >= 57 and updates <= 61, "30 Hz cadence over 2 s, got " .. updates)
		end)
		cleanup()
		t.ok(ok, tostring(err))
	end)

	t.test("radar runtime: the faded line to an off-road target survives the per-frame head update", function()
		local MapLayout2 = H.require("src/shared/Util/MapLayout")
		local drop = MapLayout2.plotDropoffZone(1).Position
		local RoadGraph = H.require("src/shared/Util/RoadGraph")
		local Q = RoadGraph.nearestPoint(drop)
		local root, _, cleanup = headless(Vector3.new(Q.X + 3, 3, Q.Z), false)
		local ok, err = pcall(function()
			local M = H.require("src/client/Controllers/MinimapController")
			local WP = H.require("src/client/Controllers/WaypointController")
			M.mount()
			for _ = 1, 5 do
				M.step(1 / 30)
			end
			WP.set("home", drop, nil, "HOME")
			local radar = H.localPlayer.PlayerGui.HC_Minimap.Radar
			for frame = 1, 60 do
				M.step(1 / 30)
				if frame >= 15 and frame % 15 == 0 then
					local faded = 0
					for _, f in visibleCores(radar) do
						if f.BackgroundTransparency > 0.3 and f.Size.X.Scale > 0 then
							faded += 1
						end
					end
					t.eq(faded, 1, "faded line to the drop-off drawn at frame " .. frame)
				end
			end
			t.ok(M.getRemaining() > 40, "distance pill counts the off-road leg")
			root.CFrame = root.CFrame -- keep the root referenced
		end)
		cleanup()
		t.ok(ok, tostring(err))
	end)

	t.test("radar runtime: an unreachable target is not searched again every slow tick", function()
		local _, _, cleanup = headless(Vector3.new(-300, 3, 160), false)
		local RoadGraph = H.require("src/shared/Util/RoadGraph")
		local original = RoadGraph.route
		local calls = 0
		local ok, err = pcall(function()
			local M = H.require("src/client/Controllers/MinimapController")
			local WP = H.require("src/client/Controllers/WaypointController")
			M.mount()
			RoadGraph.route = function()
				calls += 1
				return nil
			end
			WP.set(Cfg.CUSTOM_WAYPOINT.ID, Vector3.new(480, 0, -400), nil, "WAYPOINT")
			for _ = 1, 120 do -- 4 s
				M.step(1 / 30)
			end
			t.ok(calls >= 2 and calls <= 4, "backed off (0, 0.75, 2.25 s), got " .. calls)
			t.eq(M.getRoute(), nil, "no route")
			-- the target moves somewhere new: searched again right away (after the normal throttle)
			calls = 0
			WP.set(Cfg.CUSTOM_WAYPOINT.ID, Vector3.new(-480, 0, 400), nil, "WAYPOINT")
			for _ = 1, 30 do
				M.step(1 / 30)
			end
			t.ok(calls >= 1 and calls <= 2, "moved target: searched again, then backs off afresh; got " .. calls)
			-- the road becomes reachable: the next retry finds it
			RoadGraph.route = original
			for _ = 1, 150 do
				M.step(1 / 30)
			end
			t.ok(M.getRoute() ~= nil, "routed once reachable")
		end)
		RoadGraph.route = original
		cleanup()
		t.ok(ok, tostring(err))
	end)

	t.test("fullscreen map runtime: every blip, names clear of blips, tap sets / clears the waypoint", function()
		local _, extra, cleanup = headless(Vector3.new(-300, 3, 160), true)
		local ok, err = pcall(function()
			-- a police car with its siren on and the police chopper
			for _, spec in { { "Police", Vector3.new(-260, 3, 180) }, { "PoliceHeli", Vector3.new(200, 80, -300) } } do
				local m = H.roblox.Instance.new("Model")
				local body = H.roblox.Instance.new("Part")
				body.CFrame = H.roblox.CFrame.new(spec[2])
				body.Position = spec[2]
				body.Parent = m
				m.PrimaryPart = body
				m:SetAttribute("Siren", true)
				m:AddTag(spec[1])
				m.Parent = H.workspace
				table.insert(extra, m)
			end
			local M = H.require("src/client/Controllers/MinimapController")
			local MS = H.require("src/client/Controllers/MapScreenController")
			M.mount()
			MS.mount()
			MS.open()
			t.ok(MS.isOpen(), "open")
			for _ = 1, 3 do
				MS.step(1 / 30)
			end
			local gui = H.localPlayer.PlayerGui.HC_Map
			local chrome = H.localPlayer.PlayerGui.HC_MapChrome
			t.ok(gui.Enabled and chrome.Enabled, "shown")
			-- blips: every POI + the police car + the chopper
			local poiCount = 0
			for _, def in Cfg.POIS do
				poiCount += #M.poiPositions(def.at)
			end
			local blips = {}
			for _, b in gui.Backdrop.Overlay.Blips:GetChildren() do
				if b.Visible then
					table.insert(blips, b)
				end
			end
			t.eq(#blips, poiCount + 2, "POIs + police + chopper")
			-- district names never sit on a blip
			local labels = 0
			for _, l in gui.Backdrop.Overlay.Labels:GetChildren() do
				if l.Visible then
					labels += 1
					local hw = #l.Text * l.TextSize * 0.31
					local hh = (l.TextSize + 6) / 2
					for _, b in blips do
						local half = b.Size.X.Offset / 2
						local clear = math.abs(b.Position.X.Offset - l.Position.X.Offset) >= hw + half - 2.5
							or math.abs(b.Position.Y.Offset - l.Position.Y.Offset) >= hh + half - 2.5
						t.ok(clear, l.Text .. " clear of every blip")
					end
				end
			end
			t.ok(labels >= 5, "district names shown, got " .. labels)
			-- touch: the legend starts hidden behind its button, sized for the canvas
			t.ok(not chrome.Legend.Visible, "legend hidden on touch")
			t.ok(chrome.LegendToggle.Visible, "LEGEND button")
			local lay = MS.legendLayout(#MS.legendEntries(), 1280, 720, true)
			t.eq(chrome.Legend.Size.X.Offset, lay.width)
			t.eq(chrome.Legend.Size.Y.Offset, lay.height)
			t.eq(chrome.Legend.Position.Y.Offset, -lay.bottom, "opens above its button")
			-- tap an empty spot: the custom waypoint goes there; tap it again: gone
			local top = Cfg.MAP.CHROME_TOP * 0.72
			local sc = MS.fitScale(1280, 720, top)
			local sx, sy = MS.worldToScreen(-400, 220, 0, MS.fitCenterZ(sc, top), sc, 1280, 720)
			MS.tap(Vector2.new(sx, sy))
			local wp = M.getCustomWaypoint()
			t.ok(wp ~= nil and math.abs(wp.X + 400) < 1 and math.abs(wp.Z - 220) < 1, "waypoint where tapped")
			MS.step(1 / 30)
			MS.tap(Vector2.new(sx, sy))
			t.eq(M.getCustomWaypoint(), nil, "second tap clears it")
			MS.close()
			t.ok(not gui.Enabled and not MS.isOpen(), "closed")
		end)
		cleanup()
		t.ok(ok, tostring(err))
	end)

	t.test("tap vs drag", function()
		t.ok(MapScreen.isTap(3, 0.1), "short + still = tap")
		t.ok(not MapScreen.isTap(40, 0.1), "moved = drag")
		t.ok(not MapScreen.isTap(2, 2), "held = not a tap")
	end)
end
