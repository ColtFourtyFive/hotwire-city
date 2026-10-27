--!nocheck
-- Lists what a downloaded catalog asset contains: the instance tree (class / name), every content id it references
-- (MeshId, TextureID, ColorMap, CageMeshId, AnimationId...) and whether accessories carry a WrapLayer (layered).
-- usage: lune run tools/characters/asset_refs.luau OUT.json FILE.rbxm [FILE.rbxm ...]
-- Output JSON: { ["<file>"] = { ok, error?, classes = {...}, refs = { {prop, id, path} }, layered, accessoryType? } }

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

-- Newer files store content as *Content properties (Content(Uri=...)); older ones as the string ids.
local CONTENT_PROPS = {
	"MeshContent",
	"TextureContent",
	"ColorMapContent",
	"NormalMapContent",
	"RoughnessMapContent",
	"MetalnessMapContent",
	"CageMeshContent",
	"ReferenceMeshContent",
	"MeshId",
	"TextureID",
	"TextureId",
	"ColorMap",
	"NormalMap",
	"RoughnessMap",
	"MetalnessMap",
	"CageMeshId",
	"ReferenceMeshId",
	"AnimationId",
	"Texture",
	"Image",
	"SoundId",
}

local function contentId(v): string?
	if v == nil then
		return nil
	end
	local s = tostring(v)
	if s == "" then
		return nil
	end
	return s
end

local function idOf(s: string): string?
	return s:match("rbxassetid://(%d+)") or s:match("[?&]id=(%d+)") or s:match("^(%d+)$")
end

local out = {}
local args = process.args
local outPath = args[1]
for i = 2, #args do
	local file = args[i]
	local entry = { ok = false, classes = {}, refs = {}, layered = false }
	local ok, err = pcall(function()
		local bytes = fs.readFile(file)
		local roots = roblox.deserializeModel(bytes)
		local function visit(inst, path)
			local p = path .. "/" .. inst.ClassName .. ":" .. inst.Name
			table.insert(entry.classes, p)
			if inst.ClassName == "WrapLayer" then
				entry.layered = true
			end
			if inst.ClassName == "Accessory" then
				local okT, at = pcall(function()
					return inst.AccessoryType
				end)
				if okT and at then
					entry.accessoryType = tostring(at.Name)
				end
			end
			for _, prop in CONTENT_PROPS do
				local okP, v = pcall(function()
					return inst[prop]
				end)
				if okP then
					local s = contentId(v)
					if s and idOf(s) then
						table.insert(entry.refs, { prop = prop, id = idOf(s), raw = s, path = p })
					elseif s and s:find("rbxasset", 1, true) == nil and s:find("http", 1, true) then
						table.insert(entry.refs, { prop = prop, id = nil, raw = s, path = p })
					end
				end
			end
			for _, c in inst:GetChildren() do
				visit(c, p)
			end
		end
		for _, r in roots do
			visit(r, "")
		end
		entry.ok = true
	end)
	if not ok then
		entry.error = tostring(err)
	end
	out[file] = entry
end
fs.writeFile(outPath, serde.encode("json", out, true))
print(("wrote %s (%d files)"):format(outPath, #args - 1))
