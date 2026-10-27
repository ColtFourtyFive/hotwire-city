--!strict
-- BuildingService (v2, PLAN wave A3): dresses every WorldLayout parcel with a building from Config/Buildings.
--
-- After MapBuilder: for each parcel it picks a template by family (parcel use + style), footprint and height,
-- deterministically from the parcel seed; scales it only within Config/Buildings.Fit (a better-fitting variant, or a
-- composite row of narrower buildings, always beats stretching a facade); turns its front to the street (the parcel
-- CFrame's LookVector) with the lot front on the parcel front; re-skins the walls / curtain glass from the district
-- palette; and places it in Workspace.Map.Buildings as one Model per building. Lit windows (WindowsLit parts) switch
-- on per building over dusk from the Workspace attribute NightFactor; Neon parts glow at night. When no template fits,
-- the asset is missing, or it fails to load, a procedural massing (block + window-band Textures, or parking decks)
-- stands in. The part budget (Config/Buildings.Budget) trims the farthest buildings to their core roles, then to
-- massing.
--
-- Templates: owned Model assets (tools/blender/buildkit) loaded with AssetLibrary.loadRaw (InsertService for owned
-- assets), prepared once into ServerStorage.BuildingTemplates (not replicated), then cloned.
--
-- Harness-friendly: planAll / planParcel / prepareTemplate / place / buildMassing / build are pure Instance work.
-- Public: Built: Signal(count), planAll(parcels), build(parent, parcels, opts), applyNight(nf), getFolder().

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Buildings = require(Shared.Config.Buildings)
local Signal = require(Shared.Util.Signal)

local BuildingService = {}

BuildingService.Built = Signal.new() -- (count: number) once the whole city is dressed

export type Parcel = {
	id: number,
	district: string,
	subzone: string?,
	use: string,
	cframe: CFrame,
	size: Vector3,
	floors: number,
	edge: number,
	style: string,
	seed: number,
	tower: boolean?,
	podium: { number }?,
	crown: string?,
	stilts: boolean?,
}

export type Plan = {
	parcel: number, -- index into the parcel list
	parcelId: number,
	piece: number, -- 1..n in a composite row
	kind: string, -- "template" | "massing" | "parkade"
	family: string,
	template: string?,
	cframe: CFrame, -- model pivot: lot bottom-centre, front -Z toward the street
	scale: Vector3, -- per-axis template scale (1 for massing)
	size: Vector3, -- placed lot / block size (X width, Y height, Z depth)
	score: number,
	reason: string?,
	wall: Buildings.Finish?,
	glass: Buildings.RGB?,
	tint: number, -- palette index used for the walls (0 = template default)
	seed: number,
	priority: number, -- studs from the city centre (budget order: nearest kept richest)
	lite: boolean, -- core roles only (budget)
	foundation: number, -- studs of plinth to add under the body (stilt lots)
	lit: boolean, -- windows light up at night
	litAt: number, -- NightFactor at which they do
	litColor: { number },
	neonAt: number,
}

type Template = Buildings.Template

-- deterministic hashing ------------------------------------------------------------------------------------------

local TWO32 = 4294967296
local function mul32(a: number, b: number): number
	local bl = b % 65536
	local bh = (b - bl) / 65536
	return (a * bl + ((a * bh) % 65536) * 65536) % TWO32
end
local function fmix32(h: number): number
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	return bit32.bxor(h, bit32.rshift(h, 16))
end
-- 0..1, deterministic for (a, b)
function BuildingService.hash(a: number, b: number): number
	local h = fmix32(bit32.bxor(math.floor(a) % TWO32, mul32(math.floor(b) % TWO32, 0x9E3779B1)))
	return h / TWO32
end
local hash = BuildingService.hash

local stringHashes: { [string]: number } = {}
local function strHash(s: string): number
	local cached = stringHashes[s]
	if cached then
		return cached
	end
	local h = 2166136261
	for i = 1, #s do
		h = mul32(bit32.bxor(h, string.byte(s, i)), 16777619)
	end
	stringHashes[s] = h
	return h
end

-- catalog ----------------------------------------------------------------------------------------------------------

local byFamily: { [string]: { Template } }? = nil
local function familyTemplates(family: string): { Template }
	local idx = byFamily
	if not idx then
		local built: { [string]: { Template } } = {}
		local keys = {}
		for key in Buildings.Templates do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			local t = Buildings.Templates[key]
			built[t.family] = built[t.family] or {}
			table.insert(built[t.family], t)
		end
		byFamily = built
		idx = built
	end
	return (idx :: any)[family] or {}
end

-- Clears the family index (tests swap Config/Buildings.Templates).
function BuildingService._resetCatalog()
	byFamily = nil
end

-- The building family for a parcel, or nil for open lots.
function BuildingService.familyFor(p: Parcel): string?
	if Buildings.OpenUses[p.use] or p.size.Y <= 0 then
		return nil
	end
	if p.tower then
		return "tower"
	end
	local fam = Buildings.UseFamily[p.use] or "midtown"
	if fam == "tower" or fam == "office" then
		fam = if p.size.Y >= Buildings.TOWER_HEIGHT then "tower" else "office"
	end
	if p.style == "beach_deco" and (fam == "midtown" or fam == "retail" or fam == "office") then
		fam = "deco"
	end
	if fam == "retail" and Buildings.UrbanStyles[p.style] then
		fam = "midtown" -- street-front shops in a row, not a lot with parking
	end
	return fam
end

-- fit --------------------------------------------------------------------------------------------------------------

export type Fit = { score: number, sx: number, sy: number, sz: number }

-- How well template t fits a lot of frontage w, depth d, target height h. nil = does not fit at all.
function BuildingService.evaluate(t: Template, w: number, d: number, h: number, fill: boolean): Fit?
	local F = Buildings.Fit
	local tw, th, td = t.size[1], t.size[2], t.size[3]
	local sx = if fill then math.clamp(w / tw, F.width[1], F.width[2]) else math.clamp(w / tw, F.width[1], 1)
	if tw * sx > w + 0.5 then
		return nil
	end
	local sz = math.clamp(d / td, F.depth[1], 1)
	if td * sz > d + 0.5 then
		return nil
	end
	local sy = 1
	if h > 0 then
		sy = math.clamp(h / th, F.height[1], F.height[2])
	end
	-- window proportions: the front facade may not stretch more than `anisotropy` in one direction
	local an = math.log(sy / sx)
	if math.abs(an) > F.anisotropy then
		sy = sx * math.exp(if an > 0 then F.anisotropy else -F.anisotropy)
	end
	local score = 0
	if h > 0 then
		score += F.heightWeight * math.abs(math.log(th * sy / h))
	end
	local gap = math.max(0, 1 - tw * sx / w)
	score += F.widthWeight * gap * (if fill then F.gapPenalty else F.gapPenalty * 0.25)
	score += F.depthWeight * math.max(0, 1 - td * sz / d) * 0.5
	score += 0.5 * (math.abs(math.log(sx)) + math.abs(math.log(sy)) + 0.5 * math.abs(math.log(sz)))
	return { score = score, sx = sx, sy = sy, sz = sz }
end

local function wantsFill(family: string, style: string): boolean
	if family == "midtown" or family == "office" or family == "tower" then
		return Buildings.UrbanStyles[style] == true or family ~= "midtown"
	end
	return family == "deco"
end

-- Best template of `families` (first family preferred) for a lot. Returns template, fit, family.
local function choose(
	families: { string },
	w: number,
	d: number,
	h: number,
	p: Parcel,
	salt: number
): (Template?, Fit?, string?)
	local bestT: Template? = nil
	local bestF: Fit? = nil
	local bestFam: string? = nil
	local bestScore = math.huge
	local F = Buildings.Fit
	for fi, fam in families do
		local fill = wantsFill(fam, p.style)
		for _, t in familyTemplates(fam) do
			local fit = BuildingService.evaluate(t, w, d, h, fill)
			if fit then
				local score = fit.score + (fi - 1) * 0.6 + F.variety * hash(p.seed + salt, strHash(t.key))
				if p.tower then
					if t.planned ~= true then
						score += 0.4
					end
					local want = p.crown and Buildings.CrownMap[p.crown]
					if want and t.crown ~= want then
						score += F.crownMismatch
					end
				end
				if score < bestScore then
					bestScore, bestT, bestF, bestFam = score, t, fit, fam
				end
			end
		end
	end
	if bestF then
		bestF.score = bestScore
	end
	return bestT, bestF, bestFam
end

local function palette(style: string, family: string): { Buildings.Finish }?
	local pal = Buildings.Palettes[style]
	local group = Buildings.FamilyGroup[family]
	if not pal or not group then
		return nil
	end
	return pal[group]
end

local CENTER = Vector3.new(150, 0, -300) -- downtown core: buildings nearest it keep the richest detail

local function nightParams(plan: Plan)
	local N = Buildings.Night
	local s = plan.seed
	plan.lit = hash(s, 71) >= N.unlitShare
	plan.litAt = N.litBand[1] + (N.litBand[2] - N.litBand[1]) * hash(s, 72)
	local base = if hash(s, 73) < N.warmShare then N.warm else N.cool
	local k = N.brightness[1] + (N.brightness[2] - N.brightness[1]) * hash(s, 74)
	plan.litColor = { base[1] * k, base[2] * k, base[3] * k }
	plan.neonAt = N.neonOn + 0.08 * (hash(s, 75) - 0.5)
end

local function newPlan(index: number, p: Parcel, piece: number, family: string, seed: number): Plan
	local plan: Plan = {
		parcel = index,
		parcelId = p.id,
		piece = piece,
		kind = "massing",
		family = family,
		template = nil,
		cframe = p.cframe,
		scale = Vector3.one,
		size = p.size,
		score = 0,
		reason = nil,
		wall = nil,
		glass = nil,
		tint = 0,
		seed = seed,
		priority = (Vector3.new(p.cframe.Position.X, 0, p.cframe.Position.Z) - CENTER).Magnitude,
		lite = false,
		foundation = 0,
		lit = true,
		litAt = 0.5,
		litColor = { 255, 196, 136 },
		neonAt = 0.45,
	}
	nightParams(plan)
	return plan
end

-- Splits a frontage into row pieces (composite rows of narrower buildings): widths in parcel-local X order.
function BuildingService.rowPieces(w: number, seed: number): { number }
	local F = Buildings.Fit
	if w <= F.rowMaxPiece then
		return { w }
	end
	local n = math.ceil(w / F.rowMaxPiece)
	while n > 1 and w / n < F.rowMinWidth do
		n -= 1
	end
	local weights = {}
	local sum = 0
	for k = 1, n do
		local r = 0.75 + 0.5 * hash(seed, 300 + k)
		weights[k] = r
		sum += r
	end
	local out = {}
	for k = 1, n do
		out[k] = w * weights[k] / sum
	end
	-- keep every piece buildable (>= rowMinWidth): rebalance toward the mean
	for k = 1, n do
		if out[k] < F.rowMinWidth then
			out[k] = w / n
		end
	end
	local total = 0
	for k = 1, n do
		total += out[k]
	end
	for k = 1, n do
		out[k] *= w / total
	end
	return out
end

-- Plans one parcel: a list of buildings (one, or several for a composite row). Empty for open lots.
function BuildingService.planParcel(p: Parcel, index: number): { Plan }
	local fam = BuildingService.familyFor(p)
	if not fam then
		return {}
	end
	local w, h, d = p.size.X, p.size.Y, p.size.Z
	if fam == "parkade" then
		local plan = newPlan(index, p, 1, "parkade", p.seed)
		plan.kind = "parkade"
		plan.size = Vector3.new(w, h, d)
		plan.cframe = p.cframe
		plan.reason = "parkade"
		return { plan }
	end
	local families = { fam }
	for _, f in Buildings.FamilyFallback[fam] or {} do
		table.insert(families, f)
	end
	local widths = { w }
	if fam == "midtown" and Buildings.UrbanStyles[p.style] then
		widths = BuildingService.rowPieces(w, p.seed)
	end
	local out: { Plan } = {}
	local x = -w / 2
	local pal = nil
	for k, pw in widths do
		local seed = (p.seed + k * 7919) % TWO32
		-- row pieces vary in height around the parcel's target so a row reads as several buildings
		local ph = h
		if #widths > 1 then
			ph = h * (0.78 + 0.32 * hash(seed, 11))
		end
		local plan = newPlan(index, p, k, fam, seed)
		local t, fit, chosenFam = choose(families, pw, d, ph, p, k * 101)
		local cx = x + pw / 2
		x += pw
		if t and fit and chosenFam then
			plan.kind = "template"
			plan.template = t.key
			plan.family = chosenFam
			plan.scale = Vector3.new(fit.sx, fit.sy, fit.sz)
			plan.score = fit.score
			local tw, th, td = t.size[1] * fit.sx, t.size[2] * fit.sy, t.size[3] * fit.sz
			plan.size = Vector3.new(tw, th, td)
			-- lot front on the parcel front (parcel local -Z faces the street), centred in its piece
			plan.cframe = p.cframe * CFrame.new(cx, 0, -d / 2 + td / 2)
			pal = palette(p.style, chosenFam)
			if pal and #pal > 0 then
				local i = 1 + math.floor(hash(seed, 21) * #pal) % #pal
				plan.wall = pal[i]
				plan.tint = i
			end
			if chosenFam == "tower" or chosenFam == "office" then
				local tints = Buildings.GlassTints
				plan.glass = tints[1 + math.floor(hash(seed, 22) * #tints) % #tints]
			end
			if p.stilts and t.baseDepth < 8 then
				plan.foundation = 24
			end
		else
			plan.kind = "massing"
			plan.reason = "no template fits"
			local mw = math.max(8, pw - 2)
			local md = math.clamp(d - 2, 8, 90)
			local mh = if h > 0 then ph else 20
			plan.size = Vector3.new(mw, math.max(mh, 12), md)
			plan.cframe = p.cframe * CFrame.new(cx, 0, -d / 2 + md / 2 + 1)
			pal = palette(p.style, fam)
			if pal and #pal > 0 then
				local i = 1 + math.floor(hash(seed, 21) * #pal) % #pal
				plan.wall = pal[i]
				plan.tint = i
			end
		end
		table.insert(out, plan)
	end
	return out
end

local function templatePartCount(t: Template, lite: boolean): number
	local n = 0
	local core: { [string]: boolean } = {}
	for _, r in Buildings.Budget.coreRoles do
		core[r] = true
	end
	for _, pd in t.parts do
		if not Buildings.Budget.dropRoles[pd.role] and (not lite or core[pd.role]) then
			n += 1
		end
	end
	return n
end

local MASSING_PARTS = 3
local PARKADE_PARTS = 8

-- Estimated BasePart count of a plan (Model instances not counted).
function BuildingService.partCount(plan: Plan): number
	if plan.kind == "template" and plan.template then
		local t = Buildings.Templates[plan.template]
		if t then
			return templatePartCount(t, plan.lite) + (if plan.foundation > 0 then 1 else 0)
		end
	end
	return if plan.kind == "parkade" then PARKADE_PARTS else MASSING_PARTS
end

-- Applies Config/Buildings.Budget: farthest-from-centre buildings drop to core roles, then to massing.
function BuildingService.applyBudget(plans: { Plan }, budget: { maxParts: number, hardParts: number }?): number
	local B = budget or Buildings.Budget
	local total = 0
	for _, plan in plans do
		total += BuildingService.partCount(plan)
	end
	if total <= B.maxParts then
		return total
	end
	local order = table.clone(plans)
	table.sort(order, function(a: Plan, b: Plan): boolean
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.parcelId * 16 + a.piece > b.parcelId * 16 + b.piece
	end)
	for _, plan in order do
		if total <= B.maxParts then
			break
		end
		if plan.kind == "template" and not plan.lite then
			local before = BuildingService.partCount(plan)
			plan.lite = true
			total += BuildingService.partCount(plan) - before
		end
	end
	for _, plan in order do
		if total <= B.hardParts then
			break
		end
		if plan.kind == "template" then
			local before = BuildingService.partCount(plan)
			plan.kind = "massing"
			plan.reason = "budget"
			total += MASSING_PARTS - before
		end
	end
	return total
end

-- Plans every parcel (flat list, parcel order, then row order) and applies the budget.
function BuildingService.planAll(parcels: { Parcel }, budget: { maxParts: number, hardParts: number }?): { Plan }
	local plans: { Plan } = {}
	for i, p in parcels do
		for _, plan in BuildingService.planParcel(p, i) do
			table.insert(plans, plan)
		end
	end
	BuildingService.applyBudget(plans, budget)
	return plans
end

-- surfaces ---------------------------------------------------------------------------------------------------------

local function enumMaterial(name: string, fallback: Enum.Material): Enum.Material
	local ok, m = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and m then m else fallback
end

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function applySurface(part: BasePart, pd: Buildings.PartDef)
	part.Material = enumMaterial(pd.mat, Enum.Material.SmoothPlastic)
	pcall(function()
		part.MaterialVariant = pd.var or ""
	end)
	part.Color = rgb(pd.rgb)
	part.Transparency = pd.alpha or 0
	part.Reflectance = pd.refl or 0
	if pd.tex and part:IsA("MeshPart") then
		local img = Buildings.Images[pd.tex]
		if img and img ~= "" then
			pcall(function()
				(part :: MeshPart).TextureID = img
			end)
		end
	end
	part:SetAttribute("Role", pd.role)
	part:SetAttribute("DayColor", part.Color)
	part:SetAttribute("DayMaterial", part.Material.Name)
end

-- template preparation ---------------------------------------------------------------------------------------------

-- Turns a loaded asset container into a template Model: the template's MeshParts (by name) parented directly to a
-- Model named after the key (importer "<obj>_Node" wrappers dropped), surfaces applied, anchored, collision / shadow
-- by role, WorldPivot at the lot origin. nil when none of the expected parts are present.
function BuildingService.prepareTemplate(raw: Instance, t: Template): Model?
	local wanted: { [string]: Buildings.PartDef } = {}
	for _, pd in t.parts do
		wanted[t.key .. "_" .. pd.name] = pd
	end
	local model = Instance.new("Model")
	model.Name = t.key
	local found = 0
	for _, d in raw:GetDescendants() do
		if d:IsA("BasePart") then
			local pd = wanted[d.Name]
			if pd and not Buildings.Budget.dropRoles[pd.role] then
				wanted[d.Name] = nil
				d.Anchored = true
				d.CanCollide = Buildings.SolidRoles[pd.role] == true
				d.CanQuery = d.CanCollide
				d.CanTouch = false
				d.CastShadow = Buildings.ShadowRoles[pd.role] == true
				d.Massless = true
				applySurface(d, pd)
				d.Parent = model
				found += 1
			end
		end
	end
	if raw.Parent == nil then
		raw:Destroy()
	end
	if found == 0 then
		model:Destroy()
		return nil
	end
	model.WorldPivot = CFrame.new()
	model:SetAttribute("Template", t.key)
	return model
end

-- placement --------------------------------------------------------------------------------------------------------

export type Placed = {
	model: Model,
	plan: Plan,
	windows: { BasePart },
	neon: { BasePart },
	on: boolean?,
	neonOn: boolean?,
}

local placed: { Placed } = {}
local nightFactor = 0

local function setStreaming(model: Model)
	pcall(function()
		(model :: any).ModelStreamingMode = (Enum.ModelStreamingMode :: any)[Buildings.Load.streamingMode]
	end)
end

local function applyWall(part: BasePart, f: Buildings.Finish)
	part.Material = enumMaterial(f.mat, part.Material)
	pcall(function()
		part.MaterialVariant = f.var or ""
	end)
	part.Color = rgb(f.rgb)
	part:SetAttribute("DayColor", part.Color)
	part:SetAttribute("DayMaterial", part.Material.Name)
end

local function foundationPart(model: Model, t: Template, plan: Plan)
	local b = t.body
	local s = plan.scale
	local w = (b[4] - b[1]) * s.X
	local dd = (b[6] - b[3]) * s.Z
	local cx = (b[1] + b[4]) / 2 * s.X
	local cz = (b[3] + b[6]) / 2 * s.Z
	local f = Instance.new("Part")
	f.Name = "Foundation"
	f.Anchored = true
	f.Material = Enum.Material.Concrete
	f.Color = Color3.fromRGB(186, 183, 176)
	f.Size = Vector3.new(math.max(2, w - 1), plan.foundation, math.max(2, dd - 1))
	f.CFrame = CFrame.new(cx, -plan.foundation / 2 - 0.05, cz)
	f.CanTouch = false
	f:SetAttribute("Role", "Foundation")
	f.Parent = model
end

-- Places one template plan: clones the prepared template, re-skins it, scales (in template space), pivots onto the
-- parcel. Returns the Placed record (not parented).
function BuildingService.place(template: Model, plan: Plan): Placed
	local t = Buildings.Templates[plan.template or ""]
	local model = template:Clone()
	model.Name = ("B%d_%d_%s"):format(plan.parcelId, plan.piece, plan.template or "?")
	local core: { [string]: boolean } = {}
	for _, r in Buildings.Budget.coreRoles do
		core[r] = true
	end
	local s = plan.scale
	local uniform = math.abs(s.X - 1) < 1e-3 and math.abs(s.Y - 1) < 1e-3 and math.abs(s.Z - 1) < 1e-3
	local windows: { BasePart } = {}
	local neon: { BasePart } = {}
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			local role = d:GetAttribute("Role")
			if plan.lite and not core[role :: any] then
				d:Destroy()
				continue
			end
			if role == "Walls" and plan.wall then
				applyWall(d, plan.wall)
			elseif role == "Glass" and plan.glass and d.MaterialVariant == "HC_WindowGlass" then
				d.Color = rgb(plan.glass)
				d:SetAttribute("DayColor", d.Color)
			end
			if not uniform then
				local p = d.CFrame.Position
				d.Size = Vector3.new(d.Size.X * s.X, d.Size.Y * s.Y, d.Size.Z * s.Z)
				d.CFrame = CFrame.new(p.X * s.X, p.Y * s.Y, p.Z * s.Z) * d.CFrame.Rotation
			end
			if role == "WindowsLit" then
				table.insert(windows, d)
			elseif role == "Neon" then
				table.insert(neon, d)
			end
		end
	end
	if t and plan.foundation > 0 then
		foundationPart(model, t, plan)
	end
	model.WorldPivot = CFrame.new()
	model:PivotTo(plan.cframe)
	model:SetAttribute("ParcelId", plan.parcelId)
	model:SetAttribute("Family", plan.family)
	model:SetAttribute("Template", plan.template)
	setStreaming(model)
	return { model = model, plan = plan, windows = windows, neon = neon, on = nil, neonOn = nil }
end

-- procedural massing -----------------------------------------------------------------------------------------------

local function windowTexture(part: BasePart, face: Enum.NormalId, image: string, u: number, v: number)
	if image == "" then
		return
	end
	local tex = Instance.new("Texture")
	tex.Face = face
	tex.Texture = image
	tex.StudsPerTileU = u
	tex.StudsPerTileV = v
	tex.Parent = part
end

-- Block (or parking decks) standing in for a building: front -Z at the plan's pivot, base on the lot.
function BuildingService.buildMassing(plan: Plan): Placed
	local model = Instance.new("Model")
	model.Name = ("B%d_%d_%s"):format(plan.parcelId, plan.piece, plan.kind)
	local w, h, d = plan.size.X, math.max(plan.size.Y, 10), plan.size.Z
	local wall = plan.wall or { mat = "Concrete", rgb = { 186, 183, 176 } }
	local function part(name: string, size: Vector3, cf: CFrame, mat: string, color: { number }, var: string?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanTouch = false
		p.Size = size
		p.CFrame = cf
		p.Material = enumMaterial(mat, Enum.Material.Concrete)
		if var then
			pcall(function()
				p.MaterialVariant = var
			end)
		end
		p.Color = rgb(color)
		p:SetAttribute("Role", name)
		p.Parent = model
		return p
	end
	if plan.kind == "parkade" then
		local deck = 10.5
		local n = math.max(2, math.floor(h / deck))
		local core = part(
			"Walls",
			Vector3.new(w - 6, n * deck, d - 6),
			CFrame.new(0, n * deck / 2, 0),
			"SmoothPlastic",
			{ 34, 36, 40 }
		)
		core.CastShadow = false
		for k = 0, math.min(n, PARKADE_PARTS - 2) do
			local slab = part(
				if k == n then "Roof" else "Trim",
				Vector3.new(w, if k == 0 then 1.2 else 3.4, d),
				CFrame.new(0, k * deck + (if k == 0 then 0.6 else 1.7), 0),
				"Concrete",
				{ 196, 192, 184 }
			)
			slab.CastShadow = true
		end
	else
		local body = part("Walls", Vector3.new(w, h, d), CFrame.new(0, h / 2, 0), wall.mat, wall.rgb, wall.var)
		local tall = h >= 120
		local img = Buildings.Images[if tall then "fb_curtain" else "fb_punched"] or ""
		local u, v = if tall then 6 else 8.5, if tall then 13 else 12.5
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right } do
			windowTexture(body, face, img, u, v)
		end
		part("Roof", Vector3.new(w - 1.6, 1, d - 1.6), CFrame.new(0, h + 0.5, 0), "Pebble", { 210, 206, 198 })
		part("Trim", Vector3.new(w + 0.6, 1.2, d + 0.6), CFrame.new(0, h + 0.1, 0), "Concrete", { 196, 192, 184 })
	end
	model.WorldPivot = CFrame.new()
	model:PivotTo(plan.cframe)
	model:SetAttribute("ParcelId", plan.parcelId)
	model:SetAttribute("Family", plan.family)
	model:SetAttribute("Massing", plan.kind)
	setStreaming(model)
	return { model = model, plan = plan, windows = {}, neon = {}, on = nil, neonOn = nil }
end

-- night ------------------------------------------------------------------------------------------------------------

local function applyNightTo(rec: Placed, nf: number)
	local plan = rec.plan
	local on = plan.lit and nf >= plan.litAt
	if on ~= rec.on then
		rec.on = on
		local c = Color3.fromRGB(plan.litColor[1], plan.litColor[2], plan.litColor[3])
		for _, w in rec.windows do
			if w.Parent then
				w.Transparency = if on then 0 else 1
				if on then
					w.Material = Enum.Material.Neon
					w.Color = c
				end
			end
		end
	end
	local neonOn = nf >= plan.neonAt
	if neonOn ~= rec.neonOn then
		rec.neonOn = neonOn
		local t = Buildings.Templates[plan.template or ""]
		local nightColor: { [string]: { number } } = {}
		if t then
			for _, pd in t.parts do
				if pd.night and pd.night.rgb then
					nightColor[pd.name] = pd.night.rgb
				end
			end
		end
		for _, n in rec.neon do
			if n.Parent then
				if neonOn then
					n.Material = Enum.Material.Neon
					local key = string.sub(n.Name, #(plan.template or "") + 2)
					local nc = nightColor[key]
					if nc then
						n.Color = rgb(nc)
					end
				else
					local dc = n:GetAttribute("DayColor")
					if typeof(dc) == "Color3" then
						n.Color = dc
					end
					n.Material = Enum.Material.SmoothPlastic
				end
			end
		end
	end
end

-- Switches every placed building to its state at NightFactor nf (only the ones that change are written).
function BuildingService.applyNight(nf: number)
	nightFactor = nf
	for i = #placed, 1, -1 do
		local rec = placed[i]
		if rec.model.Parent == nil then
			table.remove(placed, i)
		else
			applyNightTo(rec, nf)
		end
	end
end

local function register(rec: Placed)
	table.insert(placed, rec)
	applyNightTo(rec, nightFactor)
end

function BuildingService.placedCount(): number
	return #placed
end

-- build (synchronous; tests / tools) ------------------------------------------------------------------------------

export type BuildOptions = {
	templates: { [string]: Model }?, -- prepared templates by key (missing = massing)
	budget: { maxParts: number, hardParts: number }?,
	plans: { Plan }?,
}

export type BuildStats = { buildings: number, templates: number, massing: number, parts: number, models: number }

-- Builds every parcel's buildings under parent.Buildings (created if missing), synchronously.
function BuildingService.build(parent: Instance, parcels: { Parcel }, opts: BuildOptions?): (Folder, BuildStats)
	local o: BuildOptions = opts or {}
	local folder = parent:FindFirstChild("Buildings")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Buildings"
		folder.Parent = parent
	end
	local plans = o.plans or BuildingService.planAll(parcels, o.budget)
	local templates = o.templates or {}
	local stats: BuildStats = { buildings = 0, templates = 0, massing = 0, parts = 0, models = 0 }
	for _, plan in plans do
		local rec: Placed
		local tpl = plan.template and templates[plan.template]
		if plan.kind == "template" and tpl then
			rec = BuildingService.place(tpl, plan)
			stats.templates += 1
		else
			if plan.kind == "template" then
				plan.kind = "massing"
				plan.reason = "template unavailable"
			end
			rec = BuildingService.buildMassing(plan)
			stats.massing += 1
		end
		rec.model.Parent = folder
		register(rec)
		stats.buildings += 1
		stats.models += 1
		for _, d in rec.model:GetDescendants() do
			if d:IsA("BasePart") then
				stats.parts += 1
			end
		end
	end
	return folder :: Folder, stats
end

-- runtime ----------------------------------------------------------------------------------------------------------

local mapFolder: Folder? = nil
local runtimePlans: { Plan } = {}
local parcelsCache: { Parcel } = {}
local skipped = false

-- The parcel list: the baked v2 world data when present (server-only or shared), else Config/WorldLayout.
function BuildingService.parcels(): { Parcel }
	local sources: { { any } } = {
		{ script.Parent.Parent:FindFirstChild("Config"), "WorldServerData" },
		{ Shared:FindFirstChild("Config"), "WorldData" },
		{ Shared:FindFirstChild("Config"), "WorldLayout" },
	}
	for _, src in sources do
		local config, name = src[1], src[2]
		local m = config and config:FindFirstChild(name)
		if m and m:IsA("ModuleScript") then
			local ok, data = pcall(require, m)
			if ok and type(data) == "table" and type((data :: any).Parcels) == "table" then
				return (data :: any).Parcels
			end
		end
	end
	return {}
end

-- v1 guard: MapBuilder v1 fills Map.Buildings with AssetSlot placeholders; then this system stands down.
function BuildingService.isV1Map(map: Instance): boolean
	local b = map:FindFirstChild("Buildings")
	if not b then
		return false
	end
	for _, c in b:GetChildren() do
		if c:GetAttribute("Category") == "Buildings" or c:GetAttribute("Role") ~= nil then
			return true
		end
	end
	return false
end

function BuildingService.getFolder(): Folder?
	return mapFolder
end

function BuildingService.getPlans(): { Plan }
	return runtimePlans
end

function BuildingService.init()
	if not Buildings.ENABLED then
		skipped = true
		return
	end
	local map = Workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = Workspace
	end
	if BuildingService.isV1Map(map :: Instance) then
		skipped = true
		warn("[BuildingService] v1 map detected (building slots present); v2 buildings not placed")
		return
	end
	local f = (map :: Instance):FindFirstChild("Buildings")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Buildings"
		f.Parent = map
	end
	mapFolder = f :: Folder
	parcelsCache = BuildingService.parcels()
	runtimePlans = BuildingService.planAll(parcelsCache)
	Workspace:GetAttributeChangedSignal("NightFactor"):Connect(function()
		local nf = Workspace:GetAttribute("NightFactor")
		if type(nf) == "number" then
			BuildingService.applyNight(nf)
		end
	end)
	local nf = Workspace:GetAttribute("NightFactor")
	if type(nf) == "number" then
		nightFactor = nf
	end
end

local function templateStore(): Folder
	local s = ServerStorage:FindFirstChild("BuildingTemplates")
	if not s then
		s = Instance.new("Folder")
		s.Name = "BuildingTemplates"
		s.Parent = ServerStorage
	end
	return s :: Folder
end

-- Loads one template (owned Model asset), bounded by Buildings.Load.timeout. Yields.
local function loadTemplate(t: Template): Model?
	if t.assetId <= 0 then
		return nil
	end
	local AssetLibrary = require(script.Parent.AssetLibrary) :: any -- lazy: later in ORDER
	local raw: Instance? = nil
	local done = false
	task.spawn(function()
		local ok, r = pcall(AssetLibrary.loadRaw, t.assetId, "owned")
		raw = if ok then r else nil
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < Buildings.Load.timeout do
		task.wait(0.1)
	end
	local container = raw
	if not container then
		warn(("[BuildingService] %s (%d) failed to load; procedural massing stands in"):format(t.key, t.assetId))
		return nil
	end
	local ok, model = pcall(BuildingService.prepareTemplate, container, t)
	if not ok or not model then
		warn(("[BuildingService] %s: no usable parts (%s)"):format(t.key, tostring(model)))
		return nil
	end
	model.Parent = templateStore()
	return model
end

function BuildingService.start()
	if skipped or not mapFolder then
		return
	end
	local folder = mapFolder :: Folder
	-- nearest the city centre first: the skyline and the spawn districts fill in before the outskirts
	local order = table.clone(runtimePlans)
	table.sort(order, function(a: Plan, b: Plan): boolean
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return a.parcelId * 16 + a.piece < b.parcelId * 16 + b.piece
	end)
	-- load every template in first-use order, a few at a time
	local state: { [string]: string } = {} -- "loading" | "ready" | "failed"
	local templates: { [string]: Model } = {}
	local queue: { string } = {}
	for _, plan in order do
		local key = plan.template
		if plan.kind == "template" and key and not state[key] then
			state[key] = "queued"
			table.insert(queue, key)
		end
	end
	local running = 0
	task.spawn(function()
		for _, key in queue do
			while running >= Buildings.Load.concurrency do
				task.wait(0.05)
			end
			running += 1
			state[key] = "loading"
			task.spawn(function()
				local model = loadTemplate(Buildings.Templates[key])
				if model then
					templates[key] = model
					state[key] = "ready"
				else
					state[key] = "failed"
				end
				running -= 1
			end)
		end
	end)
	local count = 0
	for i, plan in order do
		local rec: Placed
		local key = plan.template
		if plan.kind == "template" and key then
			while state[key] == "queued" or state[key] == "loading" do
				task.wait(0.1)
			end
			local tpl = templates[key]
			if tpl then
				local ok, r = pcall(BuildingService.place, tpl, plan)
				if ok then
					rec = r
				else
					warn(("[BuildingService] place %s failed: %s"):format(key, tostring(r)))
					plan.kind = "massing"
					plan.reason = "place failed"
					rec = BuildingService.buildMassing(plan)
				end
			else
				plan.kind = "massing"
				plan.reason = "template unavailable"
				rec = BuildingService.buildMassing(plan)
			end
		else
			rec = BuildingService.buildMassing(plan)
		end
		rec.model.Parent = folder
		register(rec)
		count += 1
		if i % Buildings.Load.batch == 0 then
			task.wait()
		end
	end
	folder:SetAttribute("BuildingsReady", true)
	folder:SetAttribute("BuildingCount", count)
	BuildingService.Built:Fire(count)
end

return BuildingService
