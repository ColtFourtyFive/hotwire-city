# Job 0003: Creator Store realism scout (Edit mode, real engine)

**Goal:** find the most realistic, GTA-grade free assets on the Creator Store by looking at them **in the engine**. Everything runs in **Edit mode**: no Play while scouted assets exist, because free models can contain scripts. **Do not save the place.**

## Procedure (per category)

1. Search with `search_asset` (Creator Store, models). Prefer endorsed or verified creators and highly voted items when filters allow. Take the **top 4 plausible results**, skipping anything clearly cartoony or low-poly.
2. Insert each with `insert_asset`.
3. Move every inserted root into the folder `Workspace.HCScout.<category>`. Create the folder if it's missing.
4. Set an attribute `AssetId` (number) on each root, plus `AssetName` and `Creator` if you know them.
5. **Immediately** run the **SANITIZE+LAYOUT** script below, with `CATEGORY` and `CAT_INDEX` filled in (0, 1, 2… in list order).
   - It deletes all scripts, removes anything over 4000 parts, lines the assets up with labels, and returns JSON that includes a camera.
6. Take a `screen_capture` with the returned `camPos` and `camLook`, and save it as `<category>.png`.
7. Append the returned item metadata to `scout.json`, as an array of `{category, assetId, name, creator, parts, meshParts, textures, scriptsRemoved, size}`. In `report.md`, give each asset a 1-line realism verdict (1–5).

When all categories are done, run **CLEANUP**. It deletes `Workspace.HCScout`.

## Categories (search terms)

| # | Category | Search |
|---|---|---|
| 0 | `cars_sedan` | realistic sedan car |
| 1 | `cars_sports` | realistic sports car |
| 2 | `cars_suv` | realistic SUV |
| 3 | `cars_police` | realistic police car |
| 4 | `cars_truck` | realistic pickup truck |
| 5 | `cars_taxi_van` | realistic taxi / delivery van |
| 6 | `guns_pistol` | pistol |
| 7 | `guns_rifle` | assault rifle |
| 8 | `guns_shotgun_smg` | shotgun, SMG |
| 9 | `props_streetlight` | realistic street light |
| 10 | `props_trafficlight` | realistic traffic light |
| 11 | `props_palm` | realistic palm tree |
| 12 | `props_street_small` | fire hydrant, bus stop, trash can, bench, parking meter |
| 13 | `props_port` | shipping container, crane |
| 14 | `bld_apartment` | realistic apartment building |
| 15 | `bld_skyscraper` | realistic skyscraper |
| 16 | `bld_shop` | realistic convenience store, gas station |
| 17 | `vehicles_air_sea` | police helicopter, boat |

## SANITIZE+LAYOUT (Edit; replace `CATEGORY` and `CAT_INDEX`)

```lua
local CAT, CAT_INDEX = "CATEGORY", CAT_INDEX
local root = workspace:FindFirstChild("HCScout")
local folder = root and root:FindFirstChild(CAT)
assert(folder, "move inserted assets into workspace.HCScout." .. CAT .. " first")
local HttpService = game:GetService("HttpService")
local items, x = {}, 0
local baseZ = 20000 + CAT_INDEX * 700
local floor = root:FindFirstChild("Floor_" .. CAT) or Instance.new("Part")
floor.Name = "Floor_" .. CAT; floor.Anchored = true; floor.Material = Enum.Material.Concrete; floor.Color = Color3.fromRGB(150, 148, 142)
floor.Size = Vector3.new(900, 1, 300); floor.CFrame = CFrame.new(20000 + 380, -0.5, baseZ); floor.Parent = root
local maxH = 0
for _, inst in folder:GetChildren() do
	if inst:IsA("BasePart") and inst.Name:sub(1, 6) == "Floor_" then continue end
	local scripts = 0
	for _, d in inst:GetDescendants() do
		if d:IsA("LuaSourceContainer") then d:Destroy(); scripts += 1 end
	end
	local parts, meshes, tex = 0, 0, 0
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then parts += 1; d.Anchored = true end
		if d:IsA("MeshPart") or d:IsA("SpecialMesh") then meshes += 1 end
		if d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") then tex += 1 end
	end
	if inst:IsA("BasePart") then parts += 1; inst.Anchored = true end
	if parts > 4000 then
		table.insert(items, { assetId = inst:GetAttribute("AssetId"), name = inst.Name, removed = "too many parts: " .. parts })
		inst:Destroy()
		continue
	end
	local model = inst
	if not inst:IsA("Model") then
		model = Instance.new("Model"); model.Name = inst.Name
		for k, v in inst:GetAttributes() do model:SetAttribute(k, v) end
		model.Parent = folder; inst.Parent = model
	end
	local cf, size = model:GetBoundingBox()
	local w = math.max(size.X, size.Z)
	model:PivotTo(CFrame.new(20000 + x + w / 2, size.Y / 2 + (model:GetPivot().Position.Y - cf.Position.Y), baseZ) * (model:GetPivot() - model:GetPivot().Position))
	local _, s2 = model:GetBoundingBox()
	local bb = Instance.new("BillboardGui"); bb.Size = UDim2.fromOffset(260, 46); bb.StudsOffset = Vector3.new(0, s2.Y / 2 + 3, 0); bb.AlwaysOnTop = true
	local tl = Instance.new("TextLabel"); tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 0.3; tl.BackgroundColor3 = Color3.new(0, 0, 0)
	tl.TextColor3 = Color3.new(1, 1, 1); tl.TextScaled = true; tl.Font = Enum.Font.GothamBold
	tl.Text = string.format("#%d %s", #items + 1, tostring(model:GetAttribute("AssetId") or "?")); tl.Parent = bb
	bb.Adornee = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true); bb.Parent = model
	maxH = math.max(maxH, s2.Y)
	table.insert(items, { assetId = model:GetAttribute("AssetId"), name = model:GetAttribute("AssetName") or model.Name, creator = model:GetAttribute("Creator"),
		parts = parts, meshParts = meshes, textures = tex, scriptsRemoved = scripts, size = { math.floor(s2.X), math.floor(s2.Y), math.floor(s2.Z) } })
	x += w + 12
end
local center = Vector3.new(20000 + x / 2, maxH / 2, baseZ)
local dist = math.max(x * 0.75, maxH * 1.6, 40)
local camPos = center + Vector3.new(0, maxH * 0.45 + 6, -dist)
return HttpService:JSONEncode({ category = CAT, items = items, camPos = { camPos.X, camPos.Y, camPos.Z }, camLook = { center.X, center.Y, center.Z } })
```

## CLEANUP (Edit)

```lua
local r = workspace:FindFirstChild("HCScout"); if r then r:Destroy() end
return "scout cleaned"
```

## Notes

- If an inserted asset arrives as a Tool or Accessory (common for guns), the layout wraps it in a Model automatically.
- If `search_asset` supports filters such as endorsed or verified creator, or sorting by votes, use them and say so in the report.
- Expect this job to take a while. Commit and push partial results after every ~6 categories, so the lead sees progress early. Write `DONE` only at the end.
