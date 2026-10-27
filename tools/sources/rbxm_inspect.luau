--!nocheck
--[[
	rbxm_inspect.luau - dump the instance tree of a .rbxm / .rbxmx model to JSON (offline, Lune).

	    lune run tools/sources/rbxm_inspect.luau <in.rbxm|rbxmx> <out.json> [--pretty]

	Output: { source, roots, counts = {ClassName = n}, nodes = { {id, parent, depth, path, class,
	name, props = {...}} } }. `parent` is the id of the parent node (0 for roots).

	Captured per class (only when the property exists / is set):
	  BasePart        Size, CFrame (12 numbers: x y z R00..R22), Color [r,g,b], Material, MaterialVariant,
	                  Transparency, Reflectance, Anchored, CanCollide, CastShadow, Massless, Shape
	  MeshPart        MeshId, TextureID (MeshId/MeshContent, TextureID/TextureContent), InitialSize,
	                  DoubleSided, RenderFidelity
	  PartOperation   AssetId, UsePartColor, InitialSize (union geometry)
	  SpecialMesh     MeshType, MeshId, TextureId, Scale, Offset, VertexColor
	  SurfaceAppearance ColorMap, NormalMap, MetalnessMap, RoughnessMap (+ *Content), AlphaMode, Color
	  Decal/Texture   Texture, Face, Color3, Transparency, StudsPerTileU/V, OffsetStudsU/V
	  Lights          Brightness, Color, Range, Angle, Face, Enabled, Shadows
	  Attachment      CFrame (local)
	  JointInstance / WeldConstraint / Constraints  Part0/Part1 or Attachment0/1 (as node ids)
	  Seat/VehicleSeat  CFrame, MaxSpeed, Torque, TurnSpeed
	  Model           PrimaryPart (node id), WorldPivot
	  LuaSourceContainer  only name + class + Disabled (source is never dumped)
	  ValueBase       Value (scalars / strings <= 120 chars)
	Plus Attributes and Tags on any instance.

	Lune never executes scripts from the model; this is a pure data dump.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local args = process.args
if #args < 2 then
	print("usage: lune run rbxm_inspect.luau <in.rbxm|rbxmx> <out.json> [--pretty]")
	process.exit(1)
end
local inPath, outPath = args[1], args[2]
local pretty = args[3] == "--pretty"

local raw = fs.readFile(inPath)
-- Lune's format sniffing wants the document to start with "<roblox"; asset delivery often serves
-- rbxmx with an XML declaration (and CRLF line ends) in front, so strip that prologue.
if string.sub(raw, 1, 5) == "<?xml" then
	local stop = string.find(raw, "?>", 1, true)
	if stop then
		raw = string.gsub(string.sub(raw, stop + 2), "^%s+", "")
	end
end
if string.sub(raw, 1, 8) ~= "<roblox!" then
	-- XML: Studio sometimes writes empty <BinaryString> for Decal.MetalnessMap/NormalMap etc., which
	-- rbx-dom's ContentId->Content migration rejects. Empty values carry no data; drop them.
	raw = string.gsub(raw, '<BinaryString name="[^"]*">%s*</BinaryString>', "")
end
local roots
local okDes, errDes = pcall(function()
	roots = roblox.deserializeModel(raw)
end)
if not okDes then
	print("deserializeModel failed: " .. tostring(errDes))
	process.exit(2)
end

local function round(n: number, d: number?)
	local m = 10 ^ (d or 5)
	return math.floor(n * m + 0.5) / m
end

local function contentToString(v)
	-- Content(Uri=rbxassetid://123) / Content(None) / Content(Object=...)
	local s = tostring(v)
	local uri = string.match(s, "Uri=([^%)]+)")
	if uri then
		return uri
	end
	if string.find(s, "None") then
		return nil
	end
	return s
end

local function conv(v)
	local t = typeof(v)
	if t == "nil" then
		return nil
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return nil
		end
		return round(v)
	elseif t == "boolean" then
		return v
	elseif t == "string" then
		if #v > 300 then
			return nil -- binary blobs (PhysicalConfigData, MeshData, ...) are skipped
		end
		return v
	elseif t == "Vector3" then
		return { round(v.X), round(v.Y), round(v.Z) }
	elseif t == "Vector2" then
		return { round(v.X), round(v.Y) }
	elseif t == "CFrame" then
		local c = { v:GetComponents() }
		for i, x in c do
			c[i] = round(x, 6)
		end
		return c
	elseif t == "Color3" then
		return { round(v.R, 4), round(v.G, 4), round(v.B, 4) }
	elseif t == "BrickColor" then
		return v.Name
	elseif t == "EnumItem" then
		return v.Name
	elseif t == "Content" then
		return contentToString(v)
	elseif t == "UDim2" then
		return { round(v.X.Scale), v.X.Offset, round(v.Y.Scale), v.Y.Offset }
	elseif t == "NumberRange" then
		return { round(v.Min), round(v.Max) }
	elseif t == "Instance" then
		return v -- resolved to an id later
	end
	return tostring(v)
end

local function get(inst, prop)
	local ok, v = pcall(function()
		return inst[prop]
	end)
	if ok then
		return v
	end
	return nil
end

-- property lists by class family ------------------------------------------------------------
local BASEPART = { "Size", "CFrame", "Color", "Material", "MaterialVariant", "Transparency", "Reflectance",
	"Anchored", "CanCollide", "CastShadow", "Massless", "Locked" }
local PER_CLASS = {
	Part = { "Shape" },
	MeshPart = { "InitialSize", "DoubleSided", "RenderFidelity" },
	UnionOperation = { "UsePartColor", "InitialSize", "RenderFidelity", "SmoothingAngle" },
	NegateOperation = { "UsePartColor" },
	IntersectOperation = { "UsePartColor", "InitialSize" },
	SpecialMesh = { "MeshType", "Scale", "Offset", "VertexColor" },
	BlockMesh = { "Scale", "Offset" },
	CylinderMesh = { "Scale", "Offset" },
	SurfaceAppearance = { "AlphaMode", "Color" },
	Decal = { "Face", "Color3", "Transparency", "ZIndex" },
	Texture = { "Face", "Color3", "Transparency", "StudsPerTileU", "StudsPerTileV", "OffsetStudsU", "OffsetStudsV" },
	PointLight = { "Brightness", "Color", "Range", "Enabled", "Shadows" },
	SpotLight = { "Brightness", "Color", "Range", "Angle", "Face", "Enabled", "Shadows" },
	SurfaceLight = { "Brightness", "Color", "Range", "Angle", "Face", "Enabled", "Shadows" },
	Attachment = { "CFrame", "Visible" },
	Bone = { "CFrame" },
	VehicleSeat = { "MaxSpeed", "Torque", "TurnSpeed", "Disabled" },
	Seat = { "Disabled" },
	Model = { "PrimaryPart", "WorldPivot", "LevelOfDetail", "ModelStreamingMode" },
	Weld = { "Part0", "Part1", "C0", "C1", "Enabled" },
	ManualWeld = { "Part0", "Part1", "C0", "C1" },
	Motor6D = { "Part0", "Part1", "C0", "C1" },
	Motor = { "Part0", "Part1", "C0", "C1" },
	Snap = { "Part0", "Part1", "C0", "C1" },
	WeldConstraint = { "Part0", "Part1", "Enabled" },
	NoCollisionConstraint = { "Part0", "Part1" },
	HingeConstraint = { "Attachment0", "Attachment1", "ActuatorType", "Enabled" },
	CylindricalConstraint = { "Attachment0", "Attachment1", "Enabled" },
	PrismaticConstraint = { "Attachment0", "Attachment1", "Enabled" },
	SpringConstraint = { "Attachment0", "Attachment1", "FreeLength", "Stiffness", "Damping" },
	BallSocketConstraint = { "Attachment0", "Attachment1" },
	RopeConstraint = { "Attachment0", "Attachment1" },
	RodConstraint = { "Attachment0", "Attachment1" },
	ParticleEmitter = { "Rate", "Enabled" },
	Beam = { "Attachment0", "Attachment1" },
	Trail = { "Attachment0", "Attachment1" },
	SurfaceGui = { "Face", "Adornee" },
	BillboardGui = { "Adornee" },
	ImageLabel = { "Image", "ImageColor3", "ImageTransparency", "Size" },
	TextLabel = { "Text", "TextColor3" },
	Sound = { "SoundId", "Volume", "Looped", "Playing" },
}
-- content-valued props: list of {canonical name, alternatives...}
local CONTENT = {
	MeshPart = { { "MeshId", "MeshContent", "MeshID" }, { "TextureID", "TextureContent", "TextureId" } },
	SpecialMesh = { { "MeshId", "MeshContent" }, { "TextureId", "TextureContent" } },
	FileMesh = { { "MeshId" }, { "TextureId" } },
	UnionOperation = { { "AssetId" } },
	IntersectOperation = { { "AssetId" } },
	NegateOperation = { { "AssetId" } },
	SurfaceAppearance = {
		{ "ColorMap", "ColorMapContent" },
		{ "NormalMap", "NormalMapContent" },
		{ "MetalnessMap", "MetalnessMapContent" },
		{ "RoughnessMap", "RoughnessMapContent" },
	},
	Decal = { { "Texture", "TextureContent", "ColorMapContent" } },
	Texture = { { "Texture", "TextureContent", "ColorMapContent" } },
	ImageLabel = { { "Image", "ImageContent" } },
	Sky = { { "SkyboxFt" } },
}
local VALUE_CLASSES = { StringValue = true, NumberValue = true, IntValue = true, BoolValue = true,
	Vector3Value = true, CFrameValue = true, Color3Value = true, ObjectValue = true, BrickColorValue = true }

-- walk ---------------------------------------------------------------------------------------
local nodes = {}
local counts = {}
local idOf = {}
local pendingRefs = {}
local nextId = 0

local function isA(inst, cls)
	local ok, r = pcall(function()
		return inst:IsA(cls)
	end)
	return ok and r
end

local function readContent(inst, alts)
	for _, p in alts do
		local v = get(inst, p)
		if v ~= nil then
			local s = conv(v)
			if typeof(s) == "string" and s ~= "" then
				return s
			end
		end
	end
	return nil
end

local function visit(inst, parentId, depth, parentPath)
	nextId += 1
	local id = nextId
	idOf[inst] = id
	local cls = inst.ClassName
	counts[cls] = (counts[cls] or 0) + 1
	local path = parentPath == "" and inst.Name or (parentPath .. "/" .. inst.Name)
	local props = {}

	local function put(p, alias)
		local v = get(inst, p)
		if v == nil then
			return
		end
		local c = conv(v)
		if typeof(c) == "Instance" then
			pendingRefs[#pendingRefs + 1] = { props, alias or p, c }
		elseif c ~= nil then
			props[alias or p] = c
		end
	end

	if isA(inst, "BasePart") then
		for _, p in BASEPART do
			put(p)
		end
	end
	local extra = PER_CLASS[cls]
	if extra then
		for _, p in extra do
			put(p)
		end
	end
	local content = CONTENT[cls]
	if content then
		for _, alts in content do
			local s = readContent(inst, alts)
			if s then
				props[alts[1]] = s
			end
		end
	end
	if VALUE_CLASSES[cls] then
		put("Value")
	end
	if isA(inst, "LuaSourceContainer") then
		local d = get(inst, "Disabled")
		if d ~= nil then
			props.Disabled = d
		end
		local en = get(inst, "Enabled")
		if en ~= nil then
			props.Enabled = en
		end
		-- security scan only: the source itself is never written out
		local src = get(inst, "Source")
		if typeof(src) == "string" then
			local scan = { bytes = #src, flags = {}, requireIds = {} }
			for id in string.gmatch(src, "require%s*%(%s*(%d+)%s*%)") do
				table.insert(scan.requireIds, id)
			end
			local checks = {
				{ "getfenv", "getfenv" }, { "setfenv", "setfenv" }, { "loadstring", "loadstring" },
				{ "HttpService", "HttpService" }, { "HttpGet", "HttpGet" }, { "InsertService", "InsertService" },
				{ "GetObjects", "GetObjects" }, { "MarketplaceService", "MarketplaceService" },
				{ "TeleportService", "TeleportService" }, { "string%.reverse", "string.reverse" },
				{ "\\%d%d%d?\\%d%d%d?\\%d%d%d?", "escaped-bytes" }, { "_G%.", "_G" },
				{ "PromptPurchase", "PromptPurchase" }, { "Players%.%w+:Kick", "Kick" },
				{ "require%s*%([^\n]-GetAttribute", "require-by-attribute" },
				{ "require%s*%(%s*tonumber", "require-tonumber" },
				{ "script%.Parent%s*=%s*nil", "self-hide" }, { "SetCoreGuiEnabled", "coregui-toggle" },
				{ "game%.JobId", "studio-evasion(JobId)" }, { "RunService:IsStudio", "studio-check" },
				{ "TextureConfiguration", "backdoor-family:TextureConfiguration" },
			}
			for _, c in checks do
				if string.find(src, c[1]) then
					table.insert(scan.flags, c[2])
				end
			end
			if #src > 0 and #src > 20000 and not string.find(string.sub(src, 1, 2000), "\n") then
				table.insert(scan.flags, "long-single-line")
			end
			local par = inst.Parent
			if par and (isA(par, "PostEffect") or par.ClassName == "Atmosphere" or par.ClassName == "Sky"
				or isA(par, "Light") or par.ClassName == "Decal" or par.ClassName == "Texture") then
				table.insert(scan.flags, "odd-parent:" .. par.ClassName)
			end
			props.Scan = scan
		end
	end
	local okA, attrs = pcall(function()
		return inst:GetAttributes()
	end)
	if okA and attrs and next(attrs) then
		local a = {}
		for k, v in attrs do
			local c = conv(v)
			if typeof(c) ~= "Instance" then
				a[k] = c
			end
		end
		props.Attributes = a
	end
	local okT, tags = pcall(function()
		return inst:GetTags()
	end)
	if okT and tags and #tags > 0 then
		props.Tags = tags
	end

	local node = { id = id, parent = parentId, depth = depth, path = path, class = cls, name = inst.Name, props = props }
	nodes[#nodes + 1] = node
	for _, ch in inst:GetChildren() do
		visit(ch, id, depth + 1, path)
	end
	node.children = #inst:GetChildren()
end

for _, r in roots do
	visit(r, 0, 0, "")
end
-- resolve instance references to node ids (refs outside the model become nil)
for _, ref in pendingRefs do
	local tbl, key, inst = ref[1], ref[2], ref[3]
	local rid = idOf[inst]
	if rid then
		tbl[key] = rid
	end
end

local out = {
	source = inPath,
	roots = #roots,
	nodeCount = #nodes,
	counts = counts,
	nodes = nodes,
}
fs.writeFile(outPath, serde.encode("json", out, pretty))
print(string.format("rbxm_inspect: %d roots, %d instances -> %s", #roots, #nodes, outPath))
