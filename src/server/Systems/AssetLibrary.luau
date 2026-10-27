--!strict
-- Loads optional runtime art (Config/Assets) at boot, sanitizes and normalizes it, and publishes the templates:
-- Hero shells to ReplicatedStorage.AssetLibrary.Hero.<key> (client-built Index cars clone them too), city dressing
-- (Props / Buildings: only ever cloned on the server, by MapDresser / PlotService) to ServerStorage.AssetLibrary.<cat>,
-- so joining clients don't download templates they never render.
--
-- Normalized template contract:
--   Model named <key>, PrimaryPart "AssetRoot" (invisible, anchored, 1x1x1) at the asset's bottom-center,
--   identity rotation; the asset's front faces -Z; scaled per its AssetDef; every BasePart Anchored=true,
--   CanCollide = def.collide or false, CanTouch=false, CanQuery = def.collide or false. No scripts/sounds/prompts.
--   Creator Store (source = "store") assets are held to an allowlist (parts, meshes, SurfaceAppearance, containers:
--   no decals / guis / lights / emitters) and at most MAX_STORE_PARTS parts: a creator's update can't push content
--   or a perf bomb into every server.
-- Consumers: model:PivotTo(groundCFrame) places it standing on that point.
--
-- Load order (loadQueue): the police cruiser and the Common / Uncommon Hero shells (the cars that spawn most), then
-- Buildings (the skyline; they collide), then the Props that something places, then the remaining Hero shells. Props
-- in SKIP (no slot or system uses them) or flagged `lazy` are never loaded. The ReplicatedStorage folder gets attribute
-- HeroReady=true once every Hero entry finished and AllReady=true at the end.
-- Late arrival (docs/ART_PASS.md AP1): when a Hero template becomes ready, every car already built with that CarId in
-- Workspace.Vehicles, Workspace.Dealership and Workspace.Plots.*.Display gets CarBuilder.applyShell (clients re-skin
-- their own client-built models: Client/Controllers/AssetClient).

local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Assets = require(Shared.Config.Assets)
local Cars = require(Shared.Config.Cars)
local CarBuilder = require(Shared.Vehicle.CarBuilder)
local Signal = require(Shared.Util.Signal)

local AssetLibrary = {}

AssetLibrary.Ready = Signal.new() -- (category: string, key: string, template: Model)
AssetLibrary.AllReady = Signal.new() -- ()

-- Props nothing places (no MapBuilder / PlotService / DealershipService slot role, no direct get): never loaded. Most
-- are Creator Store models; loading them only delayed the Buildings and shipped dead templates.
-- (tests/spec/assets_shell.spec.luau checks this list against the source.)
AssetLibrary.SKIP = {
	-- v1 MapBuilder's slot roles are gone too: MapBuilder v2 builds procedural props (PropsV2 meshes later) and A3's
	-- BuildingService places owned building models, so the v1 store templates are never cloned.
	Props = {
		beach_chair = true,
		beach_umbrella = true,
		bus_stop = true,
		bush = true,
		car_crusher = true,
		cash_stack = true,
		construction_barrier = true,
		crate_stack = true,
		donut_giant = true,
		dumpster = true,
		ferris_wheel = true,
		fire_hydrant = true,
		flower_bed = true,
		fountain = true,
		garage_door_rollup = true,
		lifeguard_tower = true,
		mailbox = true,
		neon_sign_open = true,
		newspaper_box = true,
		parking_meter = true,
		phone_booth = true,
		police_barricade = true,
		police_helicopter = true,
		road_barrier = true,
		scrap_car = true,
		shipping_container = true,
		spray_can = true,
		street_lamp = true,
		street_lamp_classic = true,
		surfboard_rack = true,
		traffic_cone = true,
		traffic_light = true,
		trash_can = true,
		water_tower = true,
	},
	Buildings = {
		apartment_balcony = true,
		beach_villa = true,
		brick_loft = true,
		chop_shop = true,
		convenience_store = true,
		donut_shop = true,
		gas_station = true,
		gear_shop = true,
		hotel_beach = true,
		office_block = true,
		pizza_shop = true,
		police_hq = true,
		skyscraper_deco = true,
		skyscraper_neon = true,
		skyscraper_twist = true,
		spray_booth = true,
		suburban_house = true,
		surf_shack = true,
	},
} :: { [string]: { [string]: boolean } }
-- Hero tiers loaded ahead of the Buildings (with the police cruiser): the cars traffic / street spawns use most.
AssetLibrary.EARLY_HERO_TIERS = { Common = true, Uncommon = true } :: { [string]: boolean }
-- Categories whose templates stay on the server (ServerStorage.AssetLibrary): clients never clone them.
AssetLibrary.SERVER_ONLY = { Props = true, Buildings = true } :: { [string]: boolean }
AssetLibrary.MAX_STORE_PARTS = 250 -- a Creator Store model with more parts than this is rejected (fallback stays)

local root: Folder
local serverRoot: Folder? = nil
local templates: { [string]: { [string]: Model } } = {}
local pending = 0
local allDone = false

local REMOVE_CLASSES = {
	"LuaSourceContainer",
	"Sound",
	"ProximityPrompt",
	"ClickDetector",
	"Humanoid",
	"Tool",
	"BillboardGui",
	"ScreenGui",
	"Explosion",
	"Fire",
	"Smoke",
	"ForceField",
	"BodyMover",
	"JointInstance",
	"Constraint",
	"Attachment",
	"Camera",
	"Configuration",
	"ValueBase",
	"Script",
}

-- Creator Store models keep only these (and lose everything else, Decals / SurfaceGuis / lights / emitters included).
local STORE_KEEP = {
	"BasePart",
	"DataModelMesh",
	"SurfaceAppearance",
	"Model",
	"Folder",
}

local function isAny(inst: Instance, classes: { string }): boolean
	for _, cls in classes do
		if inst:IsA(cls) then
			return true
		end
	end
	return false
end

local function sanitize(model: Instance, store: boolean?)
	for _, d in model:GetDescendants() do
		local remove = if store then not isAny(d, STORE_KEEP) else isAny(d, REMOVE_CLASSES)
		if remove then
			pcall(function()
				d:Destroy()
			end)
		end
	end
end

local function worldBounds(model: Instance): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local cf, half = d.CFrame, d.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local w = cf * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
						minV = if minV then minV:Min(w) else w
						maxV = if maxV then maxV:Max(w) else w
					end
				end
			end
		end
	end
	return minV, maxV
end

local function loadRaw(id: number, source: string): Instance?
	local function viaInsert(): Instance?
		local ok, result = pcall(function()
			return InsertService:LoadAsset(id)
		end)
		return if ok then result else nil
	end
	local function viaAssetService(): Instance?
		local ok, result = pcall(function()
			return (AssetService :: any):LoadAssetAsync(id)
		end)
		return if ok then result else nil
	end
	if source == "owned" then
		return viaInsert() or viaAssetService()
	end
	return viaAssetService() or viaInsert()
end

-- Raw load of one asset (owned: InsertService first) with no normalization, for systems with their own template
-- contract (BuildingService). Yields; nil on failure.
function AssetLibrary.loadRaw(id: number, source: string): Instance?
	return loadRaw(id, source)
end

-- Turns a raw loaded container into a normalized template Model (or nil if it has no visible parts).
function AssetLibrary._normalize(raw: Instance, key: string, def: Assets.AssetDef): Model?
	local store = def.source == "store"
	sanitize(raw, store)
	if store then
		local count = 0
		for _, d in raw:GetDescendants() do
			if d:IsA("BasePart") then
				count += 1
			end
		end
		if count > AssetLibrary.MAX_STORE_PARTS then
			warn(
				("[AssetLibrary] %s: store model has %d parts (> %d); rejected"):format(
					key,
					count,
					AssetLibrary.MAX_STORE_PARTS
				)
			)
			raw:Destroy()
			return nil
		end
	end
	local model = Instance.new("Model")
	model.Name = key
	for _, child in raw:GetChildren() do
		child.Parent = model
	end
	raw:Destroy()

	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			d.Anchored = true
			d.CanCollide = def.collide == true
			d.CanQuery = def.collide == true
			d.CanTouch = false
			d.Massless = true
			d.CastShadow = def.castShadow ~= false
		end
	end
	if #parts == 0 then
		model:Destroy()
		return nil
	end

	-- root at bottom-center with identity rotation
	local minV, maxV = worldBounds(model)
	if not minV or not maxV then
		model:Destroy()
		return nil
	end
	local rootPart = Instance.new("Part")
	rootPart.Name = "AssetRoot"
	rootPart.Size = Vector3.one
	rootPart.Transparency = 1
	rootPart.Anchored = true
	rootPart.CanCollide = false
	rootPart.CanQuery = false
	rootPart.CanTouch = false
	local center = (minV + maxV) / 2
	rootPart.CFrame = CFrame.new(center.X, minV.Y, center.Z)
	rootPart.Parent = model
	model.PrimaryPart = rootPart

	-- orient so the front faces -Z, then re-center on the new bounds
	local yaw = math.rad(def.yaw or 0)
	model:PivotTo(CFrame.Angles(0, yaw, 0))
	minV, maxV = worldBounds(model)
	assert(minV and maxV, "asset has no visible parts after rotation")
	local size = maxV - minV
	local c2 = (minV + maxV) / 2
	-- move parts so the root sits exactly at the new bottom-center
	local offset = Vector3.new(-c2.X, -minV.Y, -c2.Z)
	for _, p in parts do
		p.CFrame = p.CFrame + offset
	end
	rootPart.CFrame = CFrame.new()

	local current: number
	if def.fit == "length" then
		current = math.max(size.Z, 0.01)
	elseif def.fit == "height" then
		current = math.max(size.Y, 0.01)
	elseif def.fit == "footprint" then
		current = math.max(size.X, size.Z, 0.01)
	else
		current = math.max(size.X, size.Y, size.Z, 0.01)
	end
	local factor = def.size / current
	if factor > 0 and math.abs(factor - 1) > 1e-3 then
		pcall(function()
			model:ScaleTo(model:GetScale() * factor)
		end)
	end
	model:SetAttribute("AssetKey", key)
	return model
end

-- ServerStorage.AssetLibrary (server-only templates).
local function serverFolder(): Folder
	local existing = serverRoot
	if existing and existing.Parent then
		return existing
	end
	local found = ServerStorage:FindFirstChild("AssetLibrary")
	local f: Folder
	if found and found:IsA("Folder") then
		f = found
	else
		f = Instance.new("Folder")
		f.Name = "AssetLibrary"
		f.Parent = ServerStorage
	end
	serverRoot = f
	return f
end

local function category(name: string): Folder
	local parent: Instance = if AssetLibrary.SERVER_ONLY[name] then serverFolder() else root
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f :: Folder
end

local function loadEntry(cat: string, key: string, def: Assets.AssetDef)
	for _, id in def.ids do
		local raw: Instance? = nil
		local done = false
		task.spawn(function()
			raw = loadRaw(id, def.source)
			done = true
		end)
		local t0 = os.clock()
		while not done and os.clock() - t0 < Assets.LOAD_TIMEOUT do
			task.wait(0.1)
		end
		if raw then
			local ok, result = pcall(AssetLibrary._normalize, raw, key, def)
			if ok and result then
				result.Parent = category(cat)
				templates[cat] = templates[cat] or {}
				templates[cat][key] = result
				AssetLibrary.Ready:Fire(cat, key, result)
				return
			elseif not ok then
				warn(("[AssetLibrary] normalize %s/%s (%d) failed: %s"):format(cat, key, id, tostring(result)))
			end
		end
	end
	warn(("[AssetLibrary] %s/%s unavailable; using procedural fallback"):format(cat, key))
end

-- Hero load priority (lower first): the police cruiser, then catalog order (Common first = the most spawned cars).
function AssetLibrary.heroPriority(key: string): number
	if key == Cars.Police.id then
		return 0
	end
	for i, def in Cars.List do
		if def.id == key then
			return i
		end
	end
	return math.huge
end

export type QueueItem = { cat: string, key: string, def: Assets.AssetDef }

-- Is this entry loaded at all? (SKIP list, or a def flagged lazy = true)
function AssetLibrary.wanted(cat: string, key: string, def: Assets.AssetDef): boolean
	local skip = AssetLibrary.SKIP[cat]
	if skip and skip[key] then
		return false
	end
	return (def :: any).lazy ~= true
end

local function isEarlyHero(key: string): boolean
	if key == Cars.Police.id then
		return true
	end
	local def = Cars.get(key)
	return def ~= nil and AssetLibrary.EARLY_HERO_TIERS[def.rarity] == true
end

-- Load queue (deterministic): the police cruiser + Common / Uncommon Hero shells (by heroPriority), then Buildings,
-- then the wanted Props (each alphabetical), then the remaining Hero shells (by heroPriority).
function AssetLibrary.loadQueue(): { QueueItem }
	local queue: { QueueItem } = {}
	local heroes: { QueueItem } = {}
	for key, def in Assets.Hero do
		if AssetLibrary.wanted("Hero", key, def) then
			table.insert(heroes, { cat = "Hero", key = key, def = def })
		end
	end
	table.sort(heroes, function(a, b)
		local pa, pb = AssetLibrary.heroPriority(a.key), AssetLibrary.heroPriority(b.key)
		if pa ~= pb then
			return pa < pb
		end
		return a.key < b.key
	end)
	for _, item in heroes do
		if isEarlyHero(item.key) then
			table.insert(queue, item)
		end
	end
	for _, cat in { "Buildings", "Props" } do
		local defs: { [string]: Assets.AssetDef } = (Assets :: any)[cat]
		local keys = {}
		for key, def in defs do
			if AssetLibrary.wanted(cat, key, def) then
				table.insert(keys, key)
			end
		end
		table.sort(keys)
		for _, key in keys do
			table.insert(queue, { cat = cat, key = key, def = defs[key] })
		end
	end
	for _, item in heroes do
		if not isEarlyHero(item.key) then
			table.insert(queue, item)
		end
	end
	return queue
end

-- Display cars (garage pads, dealership, built with forDisplay: no DriverSeat) wear their shell without shadows: a
-- ~9k-tri shell per pad, mostly under a roof, only adds shadow-pass cost. Drivable cars keep theirs. Returns the
-- number of shell parts changed.
function AssetLibrary.unshadowDisplay(model: Model): number
	if model:FindFirstChild("DriverSeat") then
		return 0
	end
	local shell = model:FindFirstChild(CarBuilder.SHELL_NAME)
	if not shell then
		return 0
	end
	local n = 0
	for _, d in shell:GetDescendants() do
		if d:IsA("BasePart") then
			d.CastShadow = false
			n += 1
		end
	end
	return n
end

-- Re-skin every already-built car wearing CarId `key` (police: "police_unit") with its new Hero template.
-- Returns how many models got a shell. Display folders hold the cars directly; one nested folder level is tolerated.
function AssetLibrary.reskin(key: string): number
	local count = 0
	local function visit(container: Instance?, depth: number)
		if not container then
			return
		end
		for _, child in container:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("CarId") ~= nil then
				if
					child.Parent ~= nil
					and child:GetAttribute("HeroMesh") ~= true
					and CarBuilder.shellKey(child) == key
				then
					local ok, applied = pcall(CarBuilder.applyShell, child)
					if not ok then
						warn(("[AssetLibrary] re-skin %s (%s) failed: %s"):format(child.Name, key, tostring(applied)))
					elseif applied then
						count += 1
						AssetLibrary.unshadowDisplay(child)
					end
				end
			elseif depth > 0 and (child:IsA("Folder") or child:IsA("Model")) then
				visit(child, depth - 1)
			end
		end
	end
	visit(Workspace:FindFirstChild("Vehicles"), 1)
	visit(Workspace:FindFirstChild("Dealership"), 1)
	local plots = Workspace:FindFirstChild("Plots")
	if plots then
		for _, plot in plots:GetChildren() do
			visit(plot:FindFirstChild("Display"), 1)
		end
	end
	return count
end

function AssetLibrary.init()
	local existing = ReplicatedStorage:FindFirstChild("AssetLibrary")
	if existing then
		root = existing :: Folder
	else
		root = Instance.new("Folder")
		root.Name = "AssetLibrary"
		root.Parent = ReplicatedStorage
	end
	-- late arrival: cars built before their shell loaded get it now (the template is parented before Ready fires)
	AssetLibrary.Ready:Connect(function(cat: string, key: string)
		if cat == "Hero" then
			AssetLibrary.reskin(key)
		end
	end)
end

function AssetLibrary.start()
	local queue = AssetLibrary.loadQueue()
	pending = #queue
	local heroPending = 0
	for _, item in queue do
		if item.cat == "Hero" then
			heroPending += 1
		end
	end
	if heroPending == 0 then
		root:SetAttribute("HeroReady", true)
	end
	local running = 0
	for _, item in queue do
		while running >= Assets.LOAD_CONCURRENCY do
			task.wait(0.05)
		end
		running += 1
		task.spawn(function()
			loadEntry(item.cat, item.key, item.def)
			running -= 1
			pending -= 1
			if item.cat == "Hero" then
				heroPending -= 1
				if heroPending == 0 then
					root:SetAttribute("HeroReady", true)
				end
			end
		end)
	end
	while pending > 0 do
		task.wait(0.1)
	end
	allDone = true
	root:SetAttribute("HeroReady", true)
	root:SetAttribute("AllReady", true)
	AssetLibrary.AllReady:Fire()
end

-- Template (do not modify) or nil when unavailable.
function AssetLibrary.get(cat: string, key: string): Model?
	local byCat = templates[cat]
	return byCat and byCat[key] or nil
end

-- A placed clone standing on groundCFrame (nil when unavailable).
function AssetLibrary.clone(cat: string, key: string, groundCFrame: CFrame?, parent: Instance?): Model?
	local template = AssetLibrary.get(cat, key)
	if not template then
		return nil
	end
	local c = template:Clone()
	if groundCFrame then
		c:PivotTo(groundCFrame)
	end
	if parent then
		c.Parent = parent
	end
	return c
end

function AssetLibrary.isAllReady(): boolean
	return allDone
end

-- Waits (yields) until every asset finished loading or `timeout` seconds pass.
function AssetLibrary.waitAll(timeout: number?): boolean
	local t0 = os.clock()
	while not allDone and os.clock() - t0 < (timeout or 30) do
		task.wait(0.1)
	end
	return allDone
end

return AssetLibrary
