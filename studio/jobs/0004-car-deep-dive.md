# Job 0004: Realistic car deep-dive (Edit mode, real engine)

**Run after 0003.** Same safety rules: Edit mode only, scripts stripped on insert, never Play while these assets exist, never save.

**Goal:** close-up visual verdicts plus a **structure analysis** of the best realistic Creator Store cars. The game will load them at runtime and mount them as cosmetic bodies on our own driving physics, with separate spinning wheels and a repaintable body. That needs a per-model mapping of wheels, paint parts, glass and lights.

## Car list

**A. Shortlist from job 0003:**
- 11881862706 (Jaguar)
- 14746413121 (Patrol)
- 117276253886376 (Sorento)
- 73893179863762 (Murano)
- 89890547548224 (F-150)
- 126180570128588 (Tundra)
- 113053967699143 (police interceptor SUV)
- 103123587729335 (police hatch)
- 131180706902259 (box truck)
- 97965573521866 (Mercedes sedan)
- 132078381973405 (Prius)
- 3204824887 (ME412)
- 951086064 (Maxima)

**B. New searches** with `search_asset` (free models). Take the top 3 *realistic* results for each:
- muscle car
- supercar / hypercar
- hatchback
- coupe
- convertible
- luxury sedan
- motorcycle / sport bike
- city bus
- ambulance
- fire truck
- SWAT van / armored truck
- tow truck
- limousine
- lowrider
- garbage truck
- police sedan (Crown Victoria / Charger style)

Also search the creator **yiypoo1024**, who made the most realistic cars in 0003. Take up to 8 of their best cars.

## For each car

1. Insert it with `insert_asset`, and move it into `Workspace.HCCar` (create the folder; it must hold only this one car at a time).
2. Set the attribute `AssetId`.
3. Run **ANALYZE** (below) and save the returned JSON to `cars/<assetId>.json`.
4. Take two `screen_capture` shots using the `cam34` and `camRear` values that ANALYZE returns. Save them as `cars/<assetId>_front.png` and `cars/<assetId>_rear.png`.
5. Give a 1–5 realism verdict in `report.md`, with one line on looks, scale and any problems: logos or real brand badges, missing interior, cartoon look.
6. Delete `Workspace.HCCar` and move on to the next car.

Push partial results every ~8 cars and ping the lead.

## ANALYZE (Edit)

```lua
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
Lighting.ClockTime = 14.5
local folder = workspace:FindFirstChild("HCCar")
local inst = folder and folder:GetChildren()[1]
assert(inst, "insert the car into workspace.HCCar first")
local removed = 0
for _, d in inst:GetDescendants() do
	if d:IsA("LuaSourceContainer") then d:Destroy(); removed += 1 end
end
local model = inst
if not inst:IsA("Model") then
	model = Instance.new("Model"); model.Name = inst.Name; model.Parent = folder; inst.Parent = model
end
for _, d in model:GetDescendants() do if d:IsA("BasePart") then d.Anchored = true end end
-- normalise: put the car on the ground near (30000, 0, 30000), keeping its own orientation
local cf, size = model:GetBoundingBox()
local pivot = model:GetPivot()
model:PivotTo(CFrame.new(30000, size.Y / 2 + (pivot.Position.Y - cf.Position.Y), 30000) * (pivot - pivot.Position))
cf, size = model:GetBoundingBox()
local parts, meshParts, textures, decals, glass, lights, seats = 0, 0, 0, 0, 0, {}, {}
local colorArea, wheels, names = {}, {}, {}
for _, d in model:GetDescendants() do
	if d:IsA("BasePart") then
		parts += 1
		if d:IsA("MeshPart") then meshParts += 1 end
		local rel = cf:PointToObjectSpace(d.Position)
		local nm = d.Name:lower()
		local pnm = d.Parent and d.Parent.Name:lower() or ""
		if d.Material == Enum.Material.Glass or (d.Transparency > 0.2 and d.Transparency < 0.95) then glass += 1 end
		if nm:find("light") or nm:find("lamp") or d.Material == Enum.Material.Neon then table.insert(lights, d:GetFullName():sub(-60)) end
		if d:IsA("Seat") or d:IsA("VehicleSeat") or nm:find("seat") then table.insert(seats, { d:GetFullName():sub(-60), math.floor(rel.X * 10) / 10, math.floor(rel.Y * 10) / 10, math.floor(rel.Z * 10) / 10 }) end
		local isWheelName = nm:find("wheel") or nm:find("tire") or nm:find("tyre") or nm:find("rim") or pnm:find("wheel")
			or pnm == "fl" or pnm == "fr" or pnm == "rl" or pnm == "rr" or nm == "fl" or nm == "fr" or nm == "rl" or nm == "rr"
		if isWheelName and rel.Y < 0 then
			table.insert(wheels, { path = d:GetFullName():sub(-80), rel = { math.floor(rel.X * 10) / 10, math.floor(rel.Y * 10) / 10, math.floor(rel.Z * 10) / 10 }, size = { math.floor(d.Size.X * 10) / 10, math.floor(d.Size.Y * 10) / 10, math.floor(d.Size.Z * 10) / 10 } })
		end
		local area = d.Size.X * d.Size.Y + d.Size.Y * d.Size.Z + d.Size.X * d.Size.Z
		local hasTex = (d:IsA("MeshPart") and d.TextureID ~= "") or d:FindFirstChildOfClass("SurfaceAppearance") ~= nil
		local key = d.Color:ToHex() .. "|" .. d.Material.Name .. (hasTex and "|tex" or "")
		colorArea[key] = (colorArea[key] or 0) + area
	elseif d:IsA("SurfaceAppearance") or d:IsA("Texture") then textures += 1
	elseif d:IsA("Decal") then decals += 1
	end
end
for _, c in model:GetChildren() do table.insert(names, c.ClassName .. ":" .. c.Name) end
local groups = {}
for k, v in colorArea do table.insert(groups, { k, math.floor(v) }) end
table.sort(groups, function(a, b) return a[2] > b[2] end)
local top = {}
for i = 1, math.min(6, #groups) do top[i] = groups[i] end
-- cameras: front 3/4 and rear 3/4, using the bounding box's long axis as "length"
local long = (size.X > size.Z) and cf.RightVector or cf.LookVector
local side = (size.X > size.Z) and cf.LookVector or cf.RightVector
local L = math.max(size.X, size.Z)
local c = cf.Position
local cam34 = c + long * (L * 0.9) + side * (L * 0.7) + Vector3.new(0, L * 0.28, 0)
local camRear = c - long * (L * 0.9) - side * (L * 0.7) + Vector3.new(0, L * 0.28, 0)
return HttpService:JSONEncode({
	assetId = model:GetAttribute("AssetId") or inst:GetAttribute("AssetId"), name = inst.Name, scriptsRemoved = removed,
	size = { math.floor(size.X * 10) / 10, math.floor(size.Y * 10) / 10, math.floor(size.Z * 10) / 10 },
	parts = parts, meshParts = meshParts, textures = textures, decals = decals, glassParts = glass,
	topLevel = names, wheelCandidates = wheels, seats = seats, lights = lights, colorGroupsByArea = top,
	cam34 = { pos = { cam34.X, cam34.Y, cam34.Z }, look = { c.X, c.Y, c.Z } },
	camRear = { pos = { camRear.X, camRear.Y, camRear.Z }, look = { c.X, c.Y, c.Z } },
})
```

The two camera values are guesses based on the car's bounding box. If a shot comes out bad, for example looking at the roof or clipping inside the car, adjust the camera by hand and say so in the report.
