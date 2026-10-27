--!nocheck
-- v2 buildings (PLAN A3): Config/Buildings catalog sanity, BuildingService's deterministic placement over the real
-- WorldLayout parcels (fit tolerances, orientation, front alignment, coverage), composite rows, the procedural
-- fallback path, template preparation + placement on a stand-in asset, lit windows / neon from NightFactor, the part
-- budget and the v1-map guard.
return function(t)
	local H = t.H
	H.setMode("server")
	local Vector3, CFrame, Instance, Enum = H.roblox.Vector3, H.roblox.CFrame, H.roblox.Instance, H.roblox.Enum
	local Buildings = H.require("src/shared/Config/Buildings")
	local Look = H.require("src/shared/Config/Look")
	local WorldLayout = H.require("src/shared/Config/WorldLayout")
	local BS = H.require("src/server/Systems/BuildingService")
	local parcels = WorldLayout.Parcels

	local ROLES = {}
	for _, r in
		{
			"Walls",
			"Walls2",
			"Walls3",
			"Trim",
			"Accent",
			"Frames",
			"Glass",
			"Clear",
			"Roof",
			"Roof2",
			"Details",
			"Doors",
			"Awning",
			"Sign",
			"Brand",
			"Site",
			"Asphalt",
			"Paint",
			"Lawn",
			"Water",
			"Neon",
			"WindowsLit",
		}
	do
		ROLES[r] = true
	end
	local FAMILIES =
		{ tower = 1, office = 1, midtown = 1, deco = 1, retail = 1, house = 1, villa = 1, mansion = 1, industrial = 1 }

	local function templateCount()
		local n = 0
		for _ in Buildings.Templates do
			n += 1
		end
		return n
	end

	-- Config ---------------------------------------------------------------------------------------------------------
	t.test(
		"catalog: every template is complete, within MeshPart limits, with known roles / materials / images",
		function()
			t.ok(templateCount() >= 100, "production set has at least 100 variants: " .. templateCount())
			local perFamily = {}
			for key, tpl in Buildings.Templates do
				t.eq(tpl.key, key, "key field")
				t.ok(FAMILIES[tpl.family], key .. " unknown family " .. tostring(tpl.family))
				perFamily[tpl.family] = (perFamily[tpl.family] or 0) + 1
				t.ok(tpl.size[1] > 0 and tpl.size[2] > 0 and tpl.size[3] > 0, key .. " size")
				t.ok(#tpl.body == 6 and tpl.body[5] > tpl.body[2], key .. " body box")
				t.ok(#tpl.parts >= 4, key .. " has parts")
				t.ok(type(tpl.assetId) == "number", key .. " assetId")
				local names, walls, lit = {}, 0, 0
				for _, pd in tpl.parts do
					t.ok(ROLES[pd.role], key .. " unknown role " .. tostring(pd.role))
					t.ok(not names[pd.name], key .. " duplicate part " .. pd.name)
					names[pd.name] = true
					t.ok(pd.tris > 0 and pd.tris <= 20000, key .. "_" .. pd.name .. " tris " .. pd.tris)
					t.ok((Enum.Material :: any)[pd.mat] ~= nil, key .. " material " .. pd.mat)
					t.eq(#pd.rgb, 3, key .. " rgb")
					if pd.var then
						t.ok(Look.Materials[pd.var] ~= nil, key .. " variant not in Look: " .. pd.var)
						t.eq(Look.Materials[pd.var].baseMaterial, pd.mat, key .. " variant base material " .. pd.var)
					end
					if pd.tex then
						t.ok(Buildings.Images[pd.tex] ~= nil, key .. " image key " .. pd.tex)
					end
					if pd.role == "WindowsLit" then
						lit += 1
						t.eq(pd.alpha, 1, key .. " lit windows hidden by day")
					end
					if pd.role == "Walls" or pd.role == "Walls2" then
						walls += 1
					end
				end
				t.ok(walls > 0 or tpl.family == "retail", key .. " has walls")
				t.ok(lit <= 1, key .. " one WindowsLit part")
			end
			for fam in FAMILIES do
				t.ok((perFamily[fam] or 0) >= 4, "family " .. fam .. " has variants: " .. tostring(perFamily[fam]))
			end
			for _, k in { "windows_day", "signs", "brands", "awnings", "fb_punched", "fb_curtain", "fb_ribbon" } do
				t.ok(Buildings.Images[k] ~= nil, "image slot " .. k)
			end
		end
	)

	t.test("catalog: palettes use Look materials (variants exist with the right base material)", function()
		for style, groups in Buildings.Palettes do
			for group, list in groups do
				t.ok(#list > 0, style .. "/" .. group)
				for _, f in list do
					t.ok((Enum.Material :: any)[f.mat] ~= nil, style .. " material " .. f.mat)
					if f.var then
						t.eq(Look.Materials[f.var].baseMaterial, f.mat, style .. " " .. f.var)
					end
				end
			end
		end
		for fam, group in Buildings.FamilyGroup do
			t.ok(FAMILIES[fam], "family group for known family " .. fam)
			t.ok(group == "panel" or group == "masonry" or group == "stucco" or group == "industrial", group)
		end
	end)

	-- Families -------------------------------------------------------------------------------------------------------
	t.test("familyFor: open lots get nothing, towers / deco / urban retail / parkades route correctly", function()
		local function P(use, style, h, extra)
			local p = {
				id = 1,
				district = "x",
				use = use,
				style = style,
				cframe = CFrame.new(),
				size = Vector3.new(80, h, 80),
				floors = 1,
				edge = 1,
				seed = 1,
			}
			for k, v in extra or {} do
				p[k] = v
			end
			return p
		end
		t.eq(BS.familyFor(P("parking_lot", "glass_towers", 0)), nil)
		t.eq(BS.familyFor(P("plaza", "glass_towers", 0)), nil)
		t.eq(BS.familyFor(P("office_tower", "glass_towers", 300)), "tower")
		t.eq(BS.familyFor(P("office_tower", "glass_towers", 120)), "office")
		t.eq(BS.familyFor(P("hotel", "commercial_midrise", 90)), "office")
		t.eq(BS.familyFor(P("residential_tower", "beach_deco", 300, { tower = true })), "tower")
		t.eq(BS.familyFor(P("beach_hotel", "beach_deco", 60)), "deco")
		t.eq(BS.familyFor(P("apartment", "beach_deco", 60)), "deco")
		t.eq(BS.familyFor(P("retail", "commercial_midrise", 25)), "midtown")
		t.eq(BS.familyFor(P("retail", "suburb_stucco", 25)), "retail")
		t.eq(BS.familyFor(P("house", "suburb_stucco", 25)), "house")
		t.eq(BS.familyFor(P("villa", "hills_mansion", 30)), "villa")
		t.eq(BS.familyFor(P("parking_garage", "glass_towers", 50)), "parkade")
	end)

	-- Placement over the real parcels -------------------------------------------------------------------------------
	local plans = BS.planAll(parcels)

	t.test("placement: deterministic (same plans twice, and per parcel independent of the others)", function()
		local again = BS.planAll(parcels)
		t.eq(#again, #plans, "plan count")
		for i, a in plans do
			local b = again[i]
			t.eq(a.template, b.template, "template " .. i)
			t.eq(a.kind, b.kind, "kind " .. i)
			local ca, cb = { a.cframe:GetComponents() }, { b.cframe:GetComponents() }
			for k = 1, 12 do
				t.near(ca[k], cb[k], 1e-9, "cframe " .. i)
			end
			t.near(a.scale.X, b.scale.X, 1e-12)
			t.near(a.scale.Y, b.scale.Y, 1e-12)
			t.eq(a.tint, b.tint, "palette pick " .. i)
		end
		-- planning one parcel alone gives the same buildings as inside the whole city
		local byParcel = {}
		for _, p in plans do
			byParcel[p.parcel] = byParcel[p.parcel] or {}
			table.insert(byParcel[p.parcel], p)
		end
		for i = 1, #parcels, 37 do
			local solo = BS.planParcel(parcels[i], i)
			local city = byParcel[i] or {}
			t.eq(#solo, #city, "pieces of parcel " .. i)
			for k, s in solo do
				t.eq(s.template, city[k].template, "solo template " .. i)
			end
		end
	end)

	t.test("placement: fit tolerances, inside the lot, front on the parcel front, facing the street", function()
		local F = Buildings.Fit
		local n = 0
		for _, plan in plans do
			if plan.kind ~= "template" then
				continue
			end
			n += 1
			local p = parcels[plan.parcel]
			local s = plan.scale
			t.ok(s.X >= F.width[1] - 1e-9 and s.X <= F.width[2] + 1e-9, "sx " .. s.X)
			t.ok(s.Z >= F.depth[1] - 1e-9 and s.Z <= F.depth[2] + 1e-9, "sz " .. s.Z)
			t.ok(s.Y >= F.height[1] - 0.15 and s.Y <= F.height[2] + 1e-9, "sy " .. s.Y)
			t.ok(math.abs(math.log(s.Y / s.X)) <= F.anisotropy + 1e-6, "facade anisotropy " .. plan.template)
			-- same orientation as the parcel: the model's front (-Z) faces the street
			t.ok(plan.cframe.LookVector:Dot(p.cframe.LookVector) > 0.9999, "faces the street")
			-- lot inside the parcel (local frame), front edges coincide
			local lp = p.cframe:PointToObjectSpace(plan.cframe.Position)
			t.ok(math.abs(lp.X) + plan.size.X / 2 <= p.size.X / 2 + 0.6, "inside the frontage " .. plan.template)
			t.ok(lp.Z + plan.size.Z / 2 <= p.size.Z / 2 + 0.6, "inside the depth " .. plan.template)
			t.near(lp.Z - plan.size.Z / 2, -p.size.Z / 2, 0.01, "lot front on the parcel front")
			t.near(lp.Y, 0, 1e-3, "on the parcel grade")
		end
		t.ok(n > 500, "most buildings are templates: " .. n)
	end)

	t.test("placement: coverage, variety and the height target", function()
		local buildable, fitted, massing = 0, 0, 0
		local used = {}
		local errs = {}
		for _, plan in plans do
			if plan.kind == "parkade" then
				continue
			end
			buildable += 1
			if plan.kind == "template" then
				fitted += 1
				used[plan.template] = (used[plan.template] or 0) + 1
				local p = parcels[plan.parcel]
				if plan.piece == 1 and p.size.Y > 0 then
					table.insert(errs, math.abs(math.log(plan.size.Y / p.size.Y)))
				end
			else
				massing += 1
			end
		end
		t.ok(fitted / buildable >= 0.9, ("templates dress >= 90%% of buildings: %d / %d"):format(fitted, buildable))
		local kinds, maxUse = 0, 0
		for _, c in used do
			kinds += 1
			maxUse = math.max(maxUse, c)
		end
		t.ok(kinds >= 80, "variety: distinct templates used " .. kinds)
		t.ok(maxUse <= fitted * 0.06, "no template dominates: " .. maxUse)
		table.sort(errs)
		t.ok(errs[math.floor(#errs / 2) + 1] < 0.05, "median height error < 5%")
		t.ok(errs[math.floor(#errs * 0.9)] < 0.2, "p90 height error < 20%")
		-- planned skyline towers get planned (160 x 160) templates
		for _, plan in plans do
			local p = parcels[plan.parcel]
			if p.tower and plan.kind == "template" then
				t.eq(Buildings.Templates[plan.template].family, "tower", "planned tower family")
			end
		end
	end)

	t.test("rows: wide urban frontage splits into buildable pieces that tile it exactly", function()
		for _, w in { 60, 84, 85, 120, 170, 202 } do
			local pieces = BS.rowPieces(w, 12345)
			local sum = 0
			for _, pw in pieces do
				sum += pw
				t.ok(pw >= Buildings.Fit.rowMinWidth - 1e-6, "piece width " .. pw)
				t.ok(pw <= Buildings.Fit.rowMaxPiece * 1.5, "piece not too wide " .. pw)
			end
			t.near(sum, w, 1e-6, "pieces tile the frontage")
			if w <= Buildings.Fit.rowMaxPiece then
				t.eq(#pieces, 1)
			end
		end
		local p = {
			id = 7,
			district = "midtown",
			use = "apartment",
			style = "commercial_midrise",
			cframe = CFrame.new(100, 12, 50) * CFrame.Angles(0, math.rad(30), 0),
			size = Vector3.new(170, 80, 70),
			floors = 6,
			edge = 1,
			seed = 999,
		}
		local row = BS.planParcel(p, 1)
		t.ok(#row >= 2, "a 170-wide midtown lot is a row of buildings")
		local prevRight = -math.huge
		for _, plan in row do
			local lp = p.cframe:PointToObjectSpace(plan.cframe.Position)
			t.ok(lp.X - plan.size.X / 2 >= prevRight - 0.6, "pieces do not overlap")
			prevRight = lp.X + plan.size.X / 2
		end
	end)

	t.test("fit: a template never stretches past tolerance; better variants win", function()
		local tpl = Buildings.Templates.midtown_w60f4
		t.ok(tpl ~= nil, "midtown_w60f4 exists")
		t.eq(BS.evaluate(tpl, tpl.size[1] * 0.5, 200, tpl.size[2], true), nil, "too narrow: rejected")
		t.eq(BS.evaluate(tpl, 200, tpl.size[3] * 0.5, tpl.size[2], true), nil, "too shallow: rejected")
		local exact = BS.evaluate(tpl, tpl.size[1], tpl.size[3], tpl.size[2], true)
		t.near(exact.sx, 1, 1e-9)
		t.near(exact.sy, 1, 1e-9)
		t.ok(exact.score < 0.01, "exact fit scores ~0")
		local tall = BS.evaluate(tpl, tpl.size[1], tpl.size[3], tpl.size[2] * 3, true)
		t.ok(tall.sy <= Buildings.Fit.height[2] + 1e-9, "height clamp")
		t.ok(tall.score > exact.score + 1, "a 3x height miss is penalised")
	end)

	-- Budget ---------------------------------------------------------------------------------------------------------
	t.test("budget: the city fits; a tight budget trims the farthest buildings to core roles, then massing", function()
		local total = 0
		for _, plan in plans do
			total += BS.partCount(plan)
		end
		t.ok(total <= Buildings.Budget.maxParts, "default budget holds the city: " .. total)
		local small = BS.planAll(parcels, { maxParts = math.floor(total * 0.8), hardParts = math.floor(total * 0.8) })
		local after, lite, massing = 0, 0, 0
		local nearestLite, farthestFull = math.huge, 0
		for _, plan in small do
			after += BS.partCount(plan)
			if plan.lite then
				lite += 1
				nearestLite = math.min(nearestLite, plan.priority)
			elseif plan.kind == "template" then
				farthestFull = math.max(farthestFull, plan.priority)
			end
			if plan.reason == "budget" then
				massing += 1
			end
		end
		t.ok(lite > 0, "some buildings went lite")
		t.ok(after <= math.floor(total * 0.8), "trimmed under budget: " .. after)
		t.ok(nearestLite >= farthestFull - 1e-6 or massing > 0, "the farthest buildings are trimmed first")
		local hard = math.floor(total * 0.45)
		local tiny = BS.planAll(parcels, { maxParts = hard, hardParts = hard })
		local tinyTotal, budgetMassing = 0, 0
		for _, plan in tiny do
			tinyTotal += BS.partCount(plan)
			if plan.reason == "budget" then
				budgetMassing += 1
			end
		end
		t.ok(budgetMassing > 0, "hard budget converts buildings to massing")
		t.ok(tinyTotal <= hard, "hard budget respected: " .. tinyTotal .. " <= " .. hard)
	end)

	-- Build: fallback, templates, night --------------------------------------------------------------------------------
	local function standIn(key)
		-- a stand-in for the uploaded asset: the importer's shape (container > Model > <part>_Node > MeshPart)
		local tpl = Buildings.Templates[key]
		local container = Instance.new("Model")
		local root = Instance.new("Model")
		root.Name = key
		root.Parent = container
		for i, pd in tpl.parts do
			local node = Instance.new("Model")
			node.Name = key .. "_" .. pd.name .. "_Node"
			node.Parent = root
			local mp = Instance.new("MeshPart")
			mp.Name = key .. "_" .. pd.name
			mp.Size = Vector3.new(tpl.size[1] * 0.9, tpl.size[2] * 0.9, tpl.size[3] * 0.9)
			mp.CFrame = CFrame.new(i * 0.01, tpl.size[2] / 2, -tpl.size[3] / 4)
			mp.Parent = node
		end
		local junk = Instance.new("Part")
		junk.Name = "NotOurs"
		junk.Parent = root
		return container
	end

	t.test("fallback: with no templates loaded every building is procedural massing, parented and sized", function()
		local parent = Instance.new("Folder")
		local sample = {}
		for i = 1, #parcels, 9 do
			table.insert(sample, parcels[i])
		end
		local folder, stats = BS.build(parent, sample, {})
		t.eq(folder.Name, "Buildings")
		t.eq(folder.Parent, parent)
		t.eq(stats.templates, 0)
		t.ok(stats.massing > 50, "massing stood in: " .. stats.massing)
		t.eq(#folder:GetChildren(), stats.buildings, "one Model per building")
		for _, m in folder:GetChildren() do
			t.ok(m:IsA("Model"), "model per building")
			t.ok(m:GetAttribute("ParcelId") ~= nil, "ParcelId attribute")
			local parts = 0
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then
					parts += 1
					t.ok(d.Anchored, "anchored")
				end
			end
			t.ok(parts >= 2 and parts <= 8, "massing part count " .. parts)
		end
		t.ok(stats.parts <= stats.buildings * 8, "massing is cheap")
	end)

	t.test(
		"templates: prepareTemplate flattens the import, applies surfaces / collision / roles; place scales + pivots",
		function()
			local key = "midtown_w60f4"
			local tpl = Buildings.Templates[key]
			local prepared = BS.prepareTemplate(standIn(key), tpl)
			t.ok(prepared ~= nil, "prepared")
			t.eq(prepared.Name, key)
			local n = 0
			for _, d in prepared:GetChildren() do
				t.ok(d:IsA("MeshPart"), "parts are direct children (no _Node wrappers)")
				t.ok(d.Anchored and not d.CanTouch, "anchored, no touch")
				local role = d:GetAttribute("Role")
				t.ok(role ~= nil, "Role attribute")
				t.eq(d.CanCollide, Buildings.SolidRoles[role] == true, "collision by role " .. role)
				n += 1
			end
			t.eq(n, #tpl.parts, "every template part kept, the stray part dropped")
			local walls = prepared:FindFirstChild(key .. "_Walls")
			t.ok(walls ~= nil, "walls")
			-- a matching parcel: place it and check scale / pivot / reskin
			local p = {
				id = 42,
				district = "midtown",
				use = "apartment",
				style = "commercial_midrise",
				cframe = CFrame.new(500, 12, -800) * CFrame.Angles(0, math.rad(90), 0),
				size = Vector3.new(tpl.size[1] * 1.05, tpl.size[2] * 1.1, tpl.size[3] * 1.4),
				floors = 5,
				edge = 1,
				seed = 4242,
			}
			local plan = BS.planParcel(p, 1)[1]
			plan.kind, plan.template = "template", key
			plan.scale = Vector3.new(1.05, 1.1, 1)
			plan.wall = { mat = "Brick", var = "HC_BrickTan", rgb = { 220, 197, 171 } }
			local rec = BS.place(prepared, plan)
			local w2 = rec.model:FindFirstChild(key .. "_Walls")
			t.near(w2.Size.X, walls.Size.X * 1.05, 1e-4, "scaled X")
			t.near(w2.Size.Y, walls.Size.Y * 1.1, 1e-4, "scaled Y")
			t.eq(w2.Material, Enum.Material.Brick, "wall re-skinned")
			t.eq(w2.MaterialVariant, "HC_BrickTan")
			local pivot = rec.model:GetPivot()
			t.near((pivot.Position - plan.cframe.Position).Magnitude, 0, 1e-4, "pivot at the plan cframe")
			t.ok(pivot.LookVector:Dot(p.cframe.LookVector) > 0.9999, "faces the street")
			t.ok(#rec.windows == 1, "lit-window part registered")
			t.eq(rec.model:GetAttribute("Template"), key)
		end
	)

	t.test("night: WindowsLit hidden by day, lit per building past its threshold; Neon switches", function()
		local key = "office_w90f7"
		local tpl = Buildings.Templates[key]
		local prepared = BS.prepareTemplate(standIn(key), tpl)
		local hasNeon = false
		for _, pd in tpl.parts do
			hasNeon = hasNeon or pd.role == "Neon"
		end
		local plans = {}
		for i = 1, 40 do
			local p = {
				id = 1000 + i,
				district = "downtown",
				use = "office_midrise",
				style = "glass_towers",
				cframe = CFrame.new(i * 200, 12, 0),
				size = Vector3.new(tpl.size[1], tpl.size[2], tpl.size[3]),
				floors = 7,
				edge = 1,
				seed = 7000 + i * 13,
			}
			local plan = BS.planParcel(p, i)[1]
			plan.kind, plan.template, plan.scale = "template", key, Vector3.one
			table.insert(plans, plan)
		end
		local parent = Instance.new("Folder")
		local folder, stats = BS.build(parent, {}, { plans = plans, templates = { [key] = prepared } })
		t.eq(stats.templates, 40, "all placed from the template")
		BS.applyNight(0)
		local byModel = {}
		for _, m in folder:GetChildren() do
			for _, d in m:GetChildren() do
				local role = d:GetAttribute("Role")
				if role == "WindowsLit" then
					byModel[m] = d
					t.eq(d.Transparency, 1, "hidden by day")
				elseif role == "Neon" then
					t.eq(d.Material, Enum.Material.SmoothPlastic, "neon tubes unlit by day")
				end
			end
		end
		BS.applyNight(1)
		local on, dark = 0, 0
		for m, d in byModel do
			if d.Transparency == 0 then
				on += 1
				t.eq(d.Material, Enum.Material.Neon, "lit windows glow")
			else
				dark += 1
			end
			for _, c in m:GetChildren() do
				if c:GetAttribute("Role") == "Neon" then
					t.eq(c.Material, Enum.Material.Neon, "neon on at night")
				end
			end
		end
		t.ok(on >= 28, "most buildings light up at full night: " .. on)
		t.ok(dark >= 1, "a few stay dark (Night.unlitShare)")
		-- dusk: a NightFactor in the middle of the band lights some but not all
		BS.applyNight(0.5)
		local mid = 0
		for _, d in byModel do
			if d.Transparency == 0 then
				mid += 1
			end
		end
		t.ok(mid > 0 and mid < on, "the city fills in over dusk: " .. mid .. " of " .. on)
		BS.applyNight(0)
		for _, d in byModel do
			t.eq(d.Transparency, 1, "off again at dawn")
		end
		t.ok(hasNeon, "the template has Neon parts (canopy downlights)")
		local lo, hi = math.huge, -math.huge
		for _, plan in plans do
			lo = math.min(lo, plan.litAt)
			hi = math.max(hi, plan.litAt)
		end
		t.ok(lo >= Buildings.Night.litBand[1] and hi <= Buildings.Night.litBand[2], "thresholds in the band")
		t.ok(hi - lo > 0.3, "thresholds spread over dusk")
	end)

	t.test("v1 guard: a map whose Buildings folder holds v1 slots is left alone", function()
		local map = Instance.new("Folder")
		t.eq(BS.isV1Map(map), false, "no Buildings folder")
		local b = Instance.new("Folder")
		b.Name = "Buildings"
		b.Parent = map
		t.eq(BS.isV1Map(map), false, "empty Buildings folder is v2")
		local slot = Instance.new("Model")
		slot:SetAttribute("Category", "Buildings")
		slot:SetAttribute("Role", "office_block")
		slot.Parent = b
		t.eq(BS.isV1Map(map), true, "v1 slot present")
	end)

	t.test("server ORDER: BuildingService right after MapBuilder", function()
		local fs = require("@lune/fs")
		local src = fs.readFile("src/server/init.server.luau")
		local a = string.find(src, '"MapBuilder"', 1, true)
		local b = string.find(src, '"BuildingService"', 1, true)
		local c = string.find(src, '"AssetLibrary"', 1, true)
		t.ok(a and b and c and a < b and b < c, "MapBuilder < BuildingService < AssetLibrary")
	end)
end
