# Job 0018: v2 preview first look and the GTA vibe audit (Play mode)

**Why this job matters.** The owner's verdict on the current game: neon pink colours and other things in the world don't feel like GTA at all. The players, map, buildings, surroundings and UX are all still far off.

Place **version 33** is the first build with the **v2 world**. It is branch `v2/preview`, which combines:
- MapBuilder v2: the island city from WorldLayout (roads, freeway, terrain, water);
- the A3 building models;
- the A4 realistic cars.

All three are on top of `main`, so they include the GTA HUD, combat and lighting. Characters are still the default Roblox avatars; a separate package is replacing them.

**Your two outputs:**
1. An honest picture of the new city.
2. A **precise kill list** of everything that still reads as a "cartoonish standard Roblox game" rather than GTA V, each item tied to the instance and system that creates it.

## Setup

1. Close the current place without saving.
2. Open it with **File → Open from Roblox → Hotwire City** and confirm **version 33 or later**.
3. Do not connect Rojo. Never save or publish.
4. Start a **Play** test (solo) and wait **90 s**. The v2 world builds in chunks.
5. Run `get_console_output` and save it as `console_start.txt`. Flag every error and every warning that mentions MapBuilder, World, BuildingService, AssetLibrary, CarBuilder, Vehicle, MapLayout, PlotService, Dealership or Leaderboard.

## A. Screenshot tour at noon

Run `workspace:SetAttribute("TimeOfDayLock", 13)` on the **Server**. Take each shot from the **player camera at street level** unless it says otherwise. Use a teleport through `execute_luau` (Server) to reach each place: read `MapLayout.poiCenter`, `MapLayout.spawnCFrame()`, `MapLayout.hospitals()` and `MapLayout.gunStores()`, and use the `WorldLayout` POIs or districts for the rest. Write the coordinates you used in the report.

| Shot | Where |
|---|---|
| `t01_spawn` | The spawn, exactly what a new player sees first |
| `t02_downtown_street` | Downtown, mid-block, looking down an avenue |
| `t03_downtown_intersection` | A downtown intersection with its signals |
| `t04_freeway` | On the ring freeway, looking along it |
| `t05_beach` | The west beach |
| `t06_hills_houses` | A hillside residential street |
| `t07_port_industrial` | The port or industrial district |
| `t08_garage_plot` | The player's garage plot |
| `t09_dealership` | The dealership |
| `t10_gunstore` | A gun store |
| `t11_police_station` | The police station (or the police spawn area) |
| `t12_hospital` | A hospital |
| `t13_overview_low_sw` | An aerial view from the low south-west, as in jobs 0001 and 0009 |
| `t14_overview_high` | A high aerial view of the whole island |
| `t15_car_closeup` | Spawn or find a v2 car (`/hc` admin; read AdminService) and frame it like a GTA showroom shot |
| `t16_driving` | Driving down an avenue, chase camera |

Then take two lighting variants:
- **Golden hour.** Set `TimeOfDayLock` to 17.6 and take `g02_downtown_street` and `g13_overview_low_sw`.
- **Night.** Set `TimeOfDayLock` to 22.5 and take `n02_downtown_street`, `n03_downtown_intersection` and `n04_freeway`.

## B. The neon and "Roblox-y" scan

Run this on the **Server** with `execute_luau` at noon. Save the whole output as `scan.txt`.

```lua
local Players = game:GetService("Players")
local function topOf(d)
	local t = d
	while t.Parent and t.Parent ~= workspace do t = t.Parent end
	return t
end
local function loud(c: Color3): boolean
	local h, s, v = c:ToHSV()
	local deg = h * 360
	local pink = deg >= 285 or deg <= 12
	local cyan = deg >= 165 and deg <= 205
	local lime = deg >= 70 and deg <= 140
	return s >= 0.55 and v >= 0.65 and (pink or cyan or lime)
end
local groups = {}
local function bump(key, path, why)
	local g = groups[key] or { n = 0, why = {}, sample = path }
	g.n += 1
	g.why[why] = (g.why[why] or 0) + 1
	groups[key] = g
end
for _, d in workspace:GetDescendants() do
	if d:IsA("BasePart") and not Players:GetPlayerFromCharacter(topOf(d)) then
		local key = topOf(d):GetFullName()
		if d.Material == Enum.Material.Neon then bump(key, d:GetFullName(), "Neon") end
		if loud(d.Color) then bump(key, d:GetFullName(), "loudColor") end
		if d.Material == Enum.Material.SmoothPlastic and d.Size.Magnitude > 20 then bump(key, d:GetFullName(), "bigSmoothPlastic") end
	elseif d:IsA("TextLabel") or d:IsA("TextButton") then
		local gui = d:FindFirstAncestorWhichIsA("SurfaceGui") or d:FindFirstAncestorWhichIsA("BillboardGui")
		if gui then
			local key = topOf(gui):GetFullName()
			if d.FontFace.Family:find("Fredoka") or d.FontFace.Family:find("Luckiest") or d.FontFace.Family:find("Bangers") then bump(key, d:GetFullName(), "cartoonFont") end
			if d.Text:find("!") then bump(key, d:GetFullName(), "exclaim:" .. d.Text:sub(1, 24)) end
			if utf8.len(d.Text) ~= #d.Text then bump(key, d:GetFullName(), "nonAscii/emoji:" .. d.Text:sub(1, 24)) end
			if loud(d.TextColor3) then bump(key, d:GetFullName(), "loudText") end
		end
	elseif d:IsA("ParticleEmitter") and loud(d.Color.Keypoints[1].Value) then
		bump(topOf(d):GetFullName(), d:GetFullName(), "loudParticles")
	end
end
local list = {}
for k, g in groups do table.insert(list, { k = k, g = g }) end
table.sort(list, function(a, b) return a.g.n > b.g.n end)
local out = {}
for i = 1, math.min(60, #list) do
	local e = list[i]
	local whys = {}
	for w, n in e.g.why do table.insert(whys, w .. "=" .. n) end
	table.insert(out, string.format("%4d  %s  [%s]  e.g. %s", e.g.n, e.k, table.concat(whys, ", "), e.g.sample))
end
print(table.concat(out, "\n"))
```

Next, for the top 25 groups, find **which script made them**:
- read the group's attributes and name prefix;
- search `src/` in your checkout of `v2/preview` (`git fetch origin v2/preview` first) for that name.

Then take one screenshot of each of the 10 worst groups: `k01_<shortname>.png` to `k10_<shortname>.png`.

## C. A UX first-10-seconds run

Stop Play. Start Play again and capture what a brand-new player sees: the loading screen (`u01_loading`), the first frame in the world (`u02_first_frame`), and the help text or objective (`u03_first_objective`).

Press **Esc** and take `u04_pause` (the pause menu). Open the phone and take `u05_phone`.

Note anything that says "Roblox game" rather than "GTA":
- Roblox top-bar clutter, the player list, chat bubbles, name tags;
- the default avatar, the default jump, the default camera;
- UI fonts and colours.

## D. The report (`report.md`)

1. **A GTA vibe score from 1 to 10 for each tour shot,** with one line on why. Be blunt.
2. **The top 20 things breaking the GTA vibe,** most damaging first. For each, give:
   - what it is;
   - where (shot and instance path);
   - the owning script or system, if you found it;
   - what GTA V would show there instead.
3. **The scan table,** top 25 groups with their owning scripts.
4. **Errors** from both console captures.
5. **What already works** and should be protected.

Push to `studio-results` under `studio/results/0018/`, then write `DONE`.
