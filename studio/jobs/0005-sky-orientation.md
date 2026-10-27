# Job 0005: Sky face orientation diagnostic (Edit mode)

**Goal:** Roblox does not document which way each `Sky` face points, or whether faces get mirrored. Realistic HDRI skyboxes need this exactly.

The six test faces below each show their face name as readable text, plus axis arrows. **Do not save the place.**

| Face | Image ID |
|---|---|
| `SkyboxFt` | `rbxassetid://110545387398867` |
| `SkyboxRt` | `rbxassetid://100921678463069` |
| `SkyboxBk` | `rbxassetid://130148372369598` |
| `SkyboxLf` | `rbxassetid://122707222733111` |
| `SkyboxUp` | `rbxassetid://80504084352862` |
| `SkyboxDn` | `rbxassetid://78838948585368` |

## Steps

1. Run SETUP with `execute_luau` (Edit).
2. Take six `screen_capture` shots, each with camera position `(0, 60, 0)`. Use look-at targets close to these directions; a pure vertical look can be unstable, so `up` and `down` are tilted slightly:

   | Shot | Look at |
   |---|---|
   | `look_negZ` | `(0, 60, -100)` |
   | `look_posZ` | `(0, 60, 100)` |
   | `look_posX` | `(100, 60, 0)` |
   | `look_negX` | `(-100, 60, 0)` |
   | `look_up` | `(0, 160, -1)` |
   | `look_down` | `(0, -40, -1)` |

3. In `report.md`, list for each shot:
   - which face label is visible;
   - whether its text reads normally or mirrored;
   - its rotation (0, 90, 180 or 270°).
4. Run CLEANUP.

## SETUP

```lua
local Lighting = game:GetService("Lighting")
_G.HCSkySaved = {}
for _, c in Lighting:GetChildren() do
	if c:IsA("Sky") or c:IsA("Atmosphere") or c:IsA("Clouds") then table.insert(_G.HCSkySaved, c); c.Parent = nil end
end
local bp = workspace:FindFirstChild("Baseplate"); if bp then _G.HCSkyBase = bp.Transparency; bp.Transparency = 1 end
local s = Instance.new("Sky"); s.Name = "HCSkyTest"
s.SkyboxFt = "rbxassetid://110545387398867"; s.SkyboxRt = "rbxassetid://100921678463069"
s.SkyboxBk = "rbxassetid://130148372369598"; s.SkyboxLf = "rbxassetid://122707222733111"
s.SkyboxUp = "rbxassetid://80504084352862"; s.SkyboxDn = "rbxassetid://78838948585368"
s.CelestialBodiesShown = false; s.StarCount = 0
s.Parent = Lighting
return "sky test set"
```

## CLEANUP

```lua
local Lighting = game:GetService("Lighting")
local t = Lighting:FindFirstChild("HCSkyTest"); if t then t:Destroy() end
for _, c in _G.HCSkySaved or {} do c.Parent = Lighting end
local bp = workspace:FindFirstChild("Baseplate"); if bp and _G.HCSkyBase then bp.Transparency = _G.HCSkyBase end
_G.HCSkySaved = nil; _G.HCSkyBase = nil
return "sky restored"
```
