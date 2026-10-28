# Job 0013: C3 audio check without ears (Play mode, `execute_luau` probes)

> **Lead (2026-10-28): run this on place version 36 or later.** Version 36 is `main` with the C3 audio merge (`v2/audio`, fix pass `b6ee333`), uploaded by the integrator. Its cloud boot had 0 errors. Open it with File → Open from Roblox, and **do not connect Rojo** unless Setup step 2 says so. Never save or publish.

**Goal:** prove in the real engine that the C3 audio runtime works. You cannot hear, so every check reads Sound and SoundGroup state through `execute_luau`:
- the five SoundGroups exist with the expected volumes, and the pause menu ducks them;
- every Config/Sounds id fetches;
- the local car's engine Sounds are loaded and playing, and their PlaybackSpeed follows the throttle;
- sirens play at 2 stars;
- the district ambience bed switches when you teleport between districts (and day ↔ night);
- the radio switches stations, and the car carries the station for other players;
- the number of simultaneous Sounds stays under the 40-voice cap through 60 s of driving and shooting;
- the console has no audio load errors.

**Not in scope:** how anything *sounds*. Loop seams, levels, pitch ranges, the heli, the tyre squeal take and the beds still need a human listening pass: see the open checklist at the end of `docs/v2/evidence/audio_audit.md`. The muffled outside radio needs a second player and is not tested here.

**Where the audio lives** (useful for `inspect_instance`):

| What | Instance |
|---|---|
| Mixer groups | `SoundService.HC_SFX`, `HC_Vehicles`, `HC_Ambience`, `HC_Music`, `HC_UI` |
| 2D loops and 2D one-shots | `SoundService.HC_Voices`: `HC_Bed1Day`, `HC_Bed1Night`, `HC_Bed2Day`, `HC_Bed2Night`, `HC_Freeway`, `HC_Radio1`, `HC_Radio2`, `HC_SirenDistant`, `HC_Wind`; one-shots are named after their Config/Sounds key (`RadioStatic`, `Dispatch_*`…) |
| 3D emitters | `Workspace.HC_ClientSounds.SoundAnchor`: Attachments `HC_LocalCar` (Sounds `EngIdle`, `EngOn`, `EngOff`, `Squeal`, `Rumble`, `Scrape`), `HC_Engine1..6` (`Idle`, `On`, `Off`), `HC_Siren1..3`, `HC_Heli1..2`, `HC_Squeal1..4`, `HC_RadioOut1..2`, `HC_Hotwire`; pooled one-shots on Attachments named `Voice` |

> **Do not `require` the client Audio modules** (`Client.Audio.City`, `Voices`…) from `execute_luau`. It has its own require cache, so you would get a fresh, unstarted copy and meaningless numbers. The snippets below read only Instances, plus pure data modules (`Config/Sounds`, `Config/WorldLayout`, `Shared/Audio/Ambience`).

## Setup

1. Run `git pull --ff-only origin main` and write the commit hash in the report.
2. Close the current place without saving. Open **File → Open from Roblox → Hotwire City** (version 36 or later).
   - **Confirm the content in Edit:**
     - `StarterPlayer.StarterPlayerScripts.Client.Audio` contains `Apply`, `City`, `Engines`, `Groups`, `Hotwire`, `LocalCar`, `Police`, `Radio` and `Voices`;
     - `ServerScriptService.Server.Systems.AudioService` exists;
     - `ReplicatedStorage.Shared.Audio` contains `Ambience`, `EngineClass`, `EngineModel`, `Mix`, `RadioDial` and `Siren`.
   - If any are missing, the place predates the merge. Then run `rojo serve` and connect Rojo from `main`. Rojo disturbs Lighting (jobs 0007, 0009); ignore lighting in this job.
3. Never save or publish. Run only **one** Play session at a time.
4. Start a **Play** test (solo) and wait **60 s**.
5. Run `get_console_output` and save it as `console_start.txt`. Copy the two boot lines (`[Server] Hotwire City booted with …` and `[Client] … ready with …`).
6. In the pause menu (**P**) → SETTINGS, check that sound effects and music are on and every volume slider is at **100 %**. The expected group volumes below assume this. If you must change a slider, say so in the report. Close the menu.

**Admin commands:** use chat `/hc …`, or run this with `execute_luau` on the **Client**, with the command after `/hc`:

```lua
game:GetService("ReplicatedStorage").Remotes.AdminCommand:FireServer("god on")
```

This job uses (all exist in `AdminService`):
- `god on`, `rookie off`;
- `spawn bull_charger`: spawns a muscle car in front of you and seats you in it;
- `weapon pistol`, `ammo pistol`;
- `wanted 2`, `wanted 4`, `wanted 0`;
- `tp spawnplaza`.

Then run **NOON** (Server) and **HELPERS** (Client), both below. Every later check is a one-line `execute_luau` on the **Client** that calls `_G.HCA.<check>()`. Paste each output, unedited, into `outputs.txt` under the step number.
- If a call errors with `attempt to index nil with 'HCA'`, `_G` did not survive between calls: run HELPERS again, then retry.
- If it still fails, paste HELPERS and the call into one `execute_luau`.

## Steps

### A. Ids and mixer (on foot, 0 stars)

1. Run `/hc god on` and `/hc rookie off`.
2. Run **IDS** (Client). It fetches every Config/Sounds id once (about 150 unique ids, radio tracks included) and can take up to 2 min.
   - **Expected:** `0 failed -> PASS`.
   - Copy every failed line exactly. A `Failure` on an id means a moderated or deleted asset.
   - If `execute_luau` times out, set `SKIP_RADIO = true` at the top, run it again, and say so.
3. `return _G.HCA.groups()`.
   - **Expected:** `HC_SFX=1.000`, `HC_Vehicles=0.900`, `HC_Ambience=0.750`, `HC_Music=0.850`, `HC_UI=0.900`, `unrouted=0`, `doppler=0`, and `PASS`.
4. **Pause duck.** Press **P** to open the pause menu, wait 2 s, then run `return _G.HCA.groups(true)`.
   - **Expected:** about `HC_SFX=0.50`, `HC_Vehicles=0.32`, `HC_Ambience=0.26`, `HC_Music=0.30`, `HC_UI=0.90` (each within 0.03 of its target), and `PASS`.
   - Group volumes that stay at the step-3 values mean the pause duck did not follow the menu. That is a FAIL (reviewer fix 1).
   - Close the menu (**P**), wait 3 s, and run `return _G.HCA.groups()` again. **Expected:** back to the step-3 values, `PASS`.

### B. District ambience (on foot)

5. Run **DISTRICT_TP** (Server) with `ID = "downtown"`. It teleports you into that district and anchors your root part, so the old map can't drop you.
   - Wait **8 s** (one scan plus the 3.5 s crossfade), then run `return _G.HCA.beds()`.
   - **Expected:** `district=downtown bed=City`, and the loudest bed is `Amb_City_Day` → `PASS`.
6. Repeat with `ID = "beach"`. **Expected:** `bed=Beach`, loudest `Amb_Beach_Day`, `PASS`.
7. Repeat with `ID = "hills"`. **Expected:** `bed=Wild`, loudest `Amb_Wild_Day`, `PASS`.
8. **Night.** Still in the hills, run `workspace:SetAttribute("TimeOfDayLock", 0)` on the **Server**, wait **20 s**, then run `return _G.HCA.beds()`.
   - **Expected:** `nightFactor` ≥ 0.8, loudest `Amb_Wild_Night`, `PASS`.
   - If it says `AMBIGUOUS`, NightFactor is still moving: wait 20 s more and run it again.
   - Then run **NOON** (Server) again.
9. Run **UNANCHOR** (Server), then `/hc tp spawnplaza`. Wait 5 s.

### C. Engine (local car)

10. Run `/hc spawn bull_charger`. You are seated in a muscle car. Wait **4 s** (key click, starter, engine fade-in).
11. `return _G.HCA.engine()` with the car standing still.
    - **Expected:** `EngIdle[...Eng_Muscle_Idle...] loaded=true playing=true` with a volume above 0. `EngOn` and `EngOff` are `loaded=true`; they may be `playing=false` at rest (silent layers are stopped).
    - The key list in brackets can show several keys that share one id; that is fine.
12. **Throttle trace.** Run `return _G.HCA.engineTrace(14)`, then **immediately**:
    1. hold **W** for **6 s** on a straight road;
    2. release and coast for **4 s**;
    3. wait until 14 s have passed.

    Then run `return _G.HCA.engineRead()`.
    - **Expected:** `samples` ≥ 40, the dominant pitch spans at least 0.20 (for example `0.70..1.65`), the on-load max volume is above 0.01, and `PASS`.
    - In the per-sample lines, while W is held, `on` must carry volume and its pitch (`@x.xx`) must climb, with dips at the gear shifts. After release, `off` must take over.
    - **Fallback** if `samples=0` (the background thread did not run): run `return _G.HCA.engine()` once at rest, once **while holding W** after 3 s, and once 1 s after releasing. Paste all three. The `EngOn` PlaybackSpeed while holding must be at least 0.2 higher than the idle one.

### D. Radio

13. `return _G.HCA.radio()`.
    - A new car starts on a random station. **Expected:** one `HC_Radio` deck has `loaded=true playing=true` and a `Radio_…` key, on `group=HC_Music`. `playing=` names the station, and `carAttr=` names the same station.
    - If it says `playing=- ` (RADIO OFF), press **T** once and wait 3 s first.
14. Press **T** (next station), wait **1 s**, and run `return _G.HCA.radio()`. **Expected:** a `RadioStatic` one-shot on `group=HC_Music` (the tuning burst).
15. Wait **3 s** more and run `return _G.HCA.radio()`.
    - **Expected:** `playing=` is a **different** station than in step 13, and `carAttr=` equals it: the server accepted the `RadioTune` and wrote the car's `RadioStation` attribute. The verdict reads `PASS`.
16. Press **R** (previous station), wait 4 s, and run `return _G.HCA.radio()`. **Expected:** back on the step-13 station, `carAttr` equal, `PASS`.

### E. Sirens and the voice cap (60 s of driving and shooting)

17. Run `/hc weapon pistol` and `/hc ammo pistol` now, so no command interrupts the minute.
18. Run `/hc wanted 2`. Wait **15 s** sitting in the car: police units spawn and come for you.
19. Run `return _G.HCA.sampler(80)`. From here, keep the game busy for the full minute:
    1. **Drive for 40 s:** W with A/D on the roads, at least one hard turn with Space (handbrake) to squeal the tyres. Let the police follow you.
    2. At about 20 s, while still driving, run `return _G.HCA.sirens()`.
       - **Expected:** `stars=2`, `units<=320` ≥ 1, `playingSlots` ≥ 1 with a `Siren_Tone` key, and `PASS`.
       - `remote engines` ≥ 1 if a police car or traffic car is within 250 studs.
       - If it says `NO UNIT IN RANGE`, stop and wait for a unit to reach you, then run it again.
    3. At 40 s, press **F** to get out. Press **1** to draw the pistol and fire **about 20 shots over 20 s**, at the police cars and the ground near them.
20. When 80 s have passed, run `return _G.HCA.samplerRead()`.
    - **Expected:** `samples` ≥ 60, `peak` ≤ **40**, and `PASS`.
    - Copy the whole per-second line: the lead wants the shape.
    - `other playing sounds` counts Sounds outside our pools (character footsteps, CoreGui). It is information only.
    - **Fallback** if `samples` is under 50: run `return _G.HCA.count()` six times during a repeat of step 19, about every 10 s. Paste all six.
21. Run `return _G.HCA.sirens()` once more, on foot.
22. *(Extra: the heli.)* Run `/hc wanted 4`, wait **40 s** in the open, then run `return _G.HCA.heli()`.
    - **Expected:** `helis tagged` ≥ 1 and `playing rotor loops` ≥ 1 → `PASS`.
    - `NO HELI` is not an audio failure; just report it.
    - Then run `/hc wanted 0`.

### F. Load state and console

23. `return _G.HCA.unloaded()`. **Expected:** `0 -> PASS`. A radio deck that is still streaming may show here; run it again 10 s later before you report it.
24. Run `get_console_output` and save it as `console_end.txt`. Stop play.
    - Search both console files, case-insensitively, for `sound`, `audio`, `rbxassetid`, `Failed to load`, `Unable to download`, `[SoundController]`, `[AudioService]`, `Client.Audio` and `RadioTune`.
    - Quote **every** matching error or warning exactly. Expected: none.
    - `[Admin]` lines and the known `[Monetization]`, `[AssetLibrary] Props/flower_bed` and `[ShopService] … GunStoreCounter` boot warnings are not audio. Ignore them.

## Report (`report.md`)

A table with one row per check and **PASS / FAIL / CHECK / BLOCKED**, followed by anything odd:

| # | Check | Result | Note |
|---|---|---|---|
| A2 | All ids fetch | | failed ids |
| A3 | Groups at rest | | |
| A4 | Pause duck down and back | | |
| B5–7 | District beds downtown / beach / hills | | coordinates used |
| B8 | Night bed | | NightFactor |
| C11 | Engine loaded and idling | | engine keys |
| C12 | Pitch follows the throttle | | pitch range |
| D13–16 | Radio switches, static on music, car attribute follows | | stations seen |
| E19 | Sirens at 2 stars | | units, slots |
| E20 | Voice cap over 60 s+ | | peak, loops + one-shots |
| E22 | Heli rotor (extra) | | |
| F23 | Nothing left unloaded | | |
| F24 | Console clean of audio errors | | quotes |

Attach `outputs.txt`, `console_start.txt` and `console_end.txt`. Never save or publish.

## Snippets

### NOON (Server)

```lua
workspace:SetAttribute("TimeOfDayLock", 13)
return "TimeOfDayLock=13"
```

### HELPERS (Client, once per Play session)

```lua
-- Job 0013 helpers: read-only probes over the audio Instances. Results go to _G.HCA.
local Players = game:GetService("Players")
local SS = game:GetService("SoundService")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local Sounds = require(RS.Shared.Config.Sounds)
local Ambience = require(RS.Shared.Audio.Ambience)
local lp = Players.LocalPlayer
local HCA = {}
_G.HCA = HCA

-- SoundId -> "KeyA/KeyB" (several keys can share one id)
local byId = {}
for key, def in Sounds do
	if type(def) == "table" and type(def.id) == "string" then
		byId[def.id] = if byId[def.id] then byId[def.id] .. "/" .. key else key
	end
end
local function keyOf(s)
	return byId[s.SoundId] or ("?" .. s.SoundId)
end
local function fmt(s)
	if not s then
		return "nil"
	end
	return ("%s[%s] loaded=%s playing=%s vol=%.3f speed=%.3f t=%.1f group=%s"):format(
		s.Name,
		keyOf(s),
		tostring(s.IsLoaded),
		tostring(s.IsPlaying),
		s.Volume,
		s.PlaybackSpeed,
		s.TimePosition,
		if s.SoundGroup then s.SoundGroup.Name else "none"
	)
end
local function voices()
	return SS:FindFirstChild("HC_Voices")
end
local function anchor()
	local h = workspace:FindFirstChild("HC_ClientSounds")
	return h and h:FindFirstChild("SoundAnchor")
end
local function roots()
	local list = {}
	local v, a = voices(), anchor()
	if v then
		table.insert(list, v)
	end
	if a then
		table.insert(list, a)
	end
	return list
end
local function carModel()
	local ch = lp.Character
	local h = ch and ch:FindFirstChildOfClass("Humanoid")
	local seat = h and h.SeatPart
	local node, top = seat, nil
	while node and node ~= workspace do
		if node:IsA("Model") then
			top = node
			if node:GetAttribute("RadioStation") ~= nil then
				return node, seat
			end
		end
		node = node.Parent
	end
	return top, seat
end

local EXPECT = { HC_SFX = 1, HC_Vehicles = 0.9, HC_Ambience = 0.75, HC_Music = 0.85, HC_UI = 0.9 }
local PAUSED = { HC_SFX = 0.5, HC_Vehicles = 0.315, HC_Ambience = 0.2625, HC_Music = 0.2975, HC_UI = 0.9 }
local ORDER = { "HC_SFX", "HC_Vehicles", "HC_Ambience", "HC_Music", "HC_UI" }

function HCA.groups(paused)
	local want = if paused then PAUSED else EXPECT
	local parts, bad = {}, 0
	for _, name in ORDER do
		local g = SS:FindFirstChild(name)
		if not (g and g:IsA("SoundGroup")) then
			bad += 1
			table.insert(parts, name .. "=MISSING")
		else
			local ok = math.abs(g.Volume - want[name]) <= 0.03
			if not ok then
				bad += 1
			end
			table.insert(parts, ("%s=%.3f(want %.3f)%s"):format(name, g.Volume, want[name], if ok then "" else " DIFF"))
		end
	end
	local unrouted = {}
	for _, root in roots() do
		for _, s in root:GetDescendants() do
			if s:IsA("Sound") and s.IsPlaying and not (s.SoundGroup and EXPECT[s.SoundGroup.Name]) then
				table.insert(unrouted, s:GetFullName())
			end
		end
	end
	return ("[GROUPS] %s | unrouted=%d %s | reverb=%s doppler=%s -> %s"):format(
		table.concat(parts, " "),
		#unrouted,
		table.concat(unrouted, ","),
		tostring(SS.AmbientReverb),
		tostring(SS.DopplerScale),
		if bad == 0 and #unrouted == 0 and SS.DopplerScale == 0 then "PASS" else "CHECK"
	)
end

local WL = nil
function HCA.beds()
	WL = WL or require(RS.Shared.Config.WorldLayout)
	local pos = workspace.CurrentCamera.CFrame.Position
	local id = WL.districtAt(pos.X, pos.Z)
	local bed = Ambience.bedFor(id)
	local nf = workspace:GetAttribute("NightFactor")
	local nfv = if typeof(nf) == "number" then nf else -1
	local want = Ambience.KEYS[bed][if nfv >= 0.5 then "night" else "day"]
	local v = voices()
	local lines, loudest, lv = {}, nil, 0
	if v then
		for _, s in v:GetChildren() do
			if s:IsA("Sound") and (string.sub(s.Name, 1, 6) == "HC_Bed" or s.Name == "HC_Freeway") then
				table.insert(lines, "  " .. fmt(s))
				if s.Name ~= "HC_Freeway" and s.IsPlaying and s.Volume > lv then
					loudest, lv = s, s.Volume
				end
			end
		end
	end
	table.sort(lines)
	local got = if loudest then keyOf(loudest) else "none"
	local verdict
	if nfv > 0.2 and nfv < 0.8 then
		verdict = "AMBIGUOUS (NightFactor between 0.2 and 0.8)"
	elseif string.find("/" .. got .. "/", "/" .. want .. "/", 1, true) then
		verdict = "PASS"
	else
		verdict = "FAIL (want " .. want .. ")"
	end
	return ("[BEDS] camera=(%.0f, %.0f) district=%s bed=%s nightFactor=%.2f reverb=%s loudest=%s -> %s\n%s"):format(
		pos.X,
		pos.Z,
		tostring(id),
		bed,
		nfv,
		tostring(SS.AmbientReverb),
		got,
		verdict,
		table.concat(lines, "\n")
	)
end

local function localCar()
	local a = anchor()
	local e = a and a:FindFirstChild("HC_LocalCar")
	if not e then
		return nil
	end
	return e:FindFirstChild("EngIdle"), e:FindFirstChild("EngOn"), e:FindFirstChild("EngOff")
end
local function speed()
	local m, seat = carModel()
	if not seat then
		return -1
	end
	local root = (m and m.PrimaryPart) or seat
	return root.AssemblyLinearVelocity.Magnitude
end
function HCA.engine()
	local i, o, f = localCar()
	if not (i and o and f) then
		return "[ENGINE] no HC_LocalCar emitter yet (not driven a car this session?)"
	end
	return ("[ENGINE] speed=%.0f\n  %s\n  %s\n  %s"):format(speed(), fmt(i), fmt(o), fmt(f))
end
function HCA.engineTrace(seconds)
	_G.HC_EngTrace = {}
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < seconds do
			local i, o, f = localCar()
			if i and o and f then
				table.insert(_G.HC_EngTrace, {
					t = os.clock() - t0,
					v = speed(),
					iv = if i.IsPlaying then i.Volume else 0,
					ip = i.PlaybackSpeed,
					ov = if o.IsPlaying then o.Volume else 0,
					op = o.PlaybackSpeed,
					fv = if f.IsPlaying then f.Volume else 0,
					fp = f.PlaybackSpeed,
				})
			end
			task.wait(0.25)
		end
	end)
	return "engine trace started for " .. seconds .. " s"
end
function HCA.engineRead()
	local tr = _G.HC_EngTrace or {}
	local lines = {}
	local minP, maxP, onMax = math.huge, -math.huge, 0
	for k, r in tr do
		local p, best = r.ip, r.iv
		if r.ov > best then
			p, best = r.op, r.ov
		end
		if r.fv > best then
			p, best = r.fp, r.fv
		end
		if best > 0.003 then
			minP = math.min(minP, p)
			maxP = math.max(maxP, p)
		end
		onMax = math.max(onMax, r.ov)
		if k % 2 == 1 then
			table.insert(
				lines,
				("  t=%4.1f v=%3.0f idle %.2f@%.2f on %.2f@%.2f off %.2f@%.2f"):format(r.t, r.v, r.iv, r.ip, r.ov, r.op, r.fv, r.fp)
			)
		end
	end
	local pass = #tr >= 40 and maxP - minP >= 0.2 and onMax > 0.01
	return ("[ENGINE TRACE] samples=%d dominant pitch %.2f..%.2f on-load max vol %.3f -> %s\n%s"):format(
		#tr,
		if minP == math.huge then 0 else minP,
		if maxP == -math.huge then 0 else maxP,
		onMax,
		if pass then "PASS" else "CHECK",
		table.concat(lines, "\n")
	)
end

local function stationOf(s)
	for _, def in Sounds do
		if type(def) == "table" and def.id == s.SoundId and type(def.station) == "string" then
			return def.station, tostring(def.title)
		end
	end
	return nil, nil
end
function HCA.radio()
	local v = voices()
	local lines, cur = {}, nil
	for i = 1, 2 do
		local s = v and v:FindFirstChild("HC_Radio" .. i)
		if s then
			table.insert(lines, "  " .. fmt(s))
			if s.IsPlaying and s.Volume > 0.001 and (not cur or s.Volume > cur.Volume) then
				cur = s
			end
		end
	end
	if v then
		for _, s in v:GetChildren() do
			if s:IsA("Sound") and s.Name == "RadioStatic" then
				table.insert(lines, "  " .. fmt(s))
			end
		end
	end
	local station, title = nil, nil
	if cur then
		station, title = stationOf(cur)
	end
	local m = carModel()
	local attr = m and m:GetAttribute("RadioStation")
	local verdict = if station and attr == station then "PASS" elseif station then "CHECK (attribute differs)" else "OFF"
	return ("[RADIO] playing=%s%s carAttr=%s -> %s\n%s"):format(
		station or "-",
		if title then " / " .. title else "",
		tostring(attr),
		verdict,
		table.concat(lines, "\n")
	)
end

function HCA.sirens()
	local cam = workspace.CurrentCamera.CFrame.Position
	local near, nearest = 0, math.huge
	for _, m in CS:GetTagged("Police") do
		if m:IsA("Model") and m:IsDescendantOf(workspace) then
			local d = (m:GetPivot().Position - cam).Magnitude
			if m:GetAttribute("Siren") ~= false and m:GetAttribute("SirenOn") ~= false and d <= 320 then
				near += 1
			end
			nearest = math.min(nearest, d)
		end
	end
	local a = anchor()
	local lines, playing = {}, 0
	for i = 1, 3 do
		local e = a and a:FindFirstChild("HC_Siren" .. i)
		local s = e and e:FindFirstChildOfClass("Sound")
		if s then
			if s.IsPlaying and s.Volume > 0.001 then
				playing += 1
			end
			table.insert(lines, ("  %s dist=%.0f"):format(fmt(s), (e.WorldPosition - cam).Magnitude))
		else
			table.insert(lines, "  HC_Siren" .. i .. " not created yet")
		end
	end
	local engines = 0
	for i = 1, 6 do
		local e = a and a:FindFirstChild("HC_Engine" .. i)
		if e then
			for _, s in e:GetChildren() do
				if s:IsA("Sound") and s.IsPlaying and s.Volume > 0.001 then
					engines += 1
					break
				end
			end
		end
	end
	local v = voices()
	local dispatch = 0
	if v then
		for _, s in v:GetChildren() do
			if s:IsA("Sound") and string.sub(s.Name, 1, 9) == "Dispatch_" then
				dispatch += 1
			end
		end
	end
	local verdict = if near == 0 then "NO UNIT IN RANGE" elseif playing >= 1 then "PASS" else "FAIL"
	return ("[SIRENS] stars=%s units<=320=%d nearest=%.0f playingSlots=%d remote engines=%d dispatch sounds=%d -> %s\n%s\n  distant: %s"):format(
		tostring(lp:GetAttribute("Wanted")),
		near,
		nearest,
		playing,
		engines,
		dispatch,
		verdict,
		table.concat(lines, "\n"),
		fmt(v and v:FindFirstChild("HC_SirenDistant"))
	)
end

function HCA.heli()
	local tagged = #CS:GetTagged("PoliceHeli") + #CS:GetTagged("Helicopter")
	local a = anchor()
	local lines, playing = {}, 0
	for i = 1, 2 do
		local e = a and a:FindFirstChild("HC_Heli" .. i)
		local s = e and e:FindFirstChildOfClass("Sound")
		if s then
			if s.IsPlaying and s.Volume > 0.001 then
				playing += 1
			end
			table.insert(lines, "  " .. fmt(s))
		end
	end
	local verdict = if tagged == 0 then "NO HELI" elseif playing > 0 then "PASS" else "FAIL"
	return ("[HELI] stars=%s helis tagged=%d playing rotor loops=%d -> %s\n%s"):format(
		tostring(lp:GetAttribute("Wanted")),
		tagged,
		playing,
		verdict,
		table.concat(lines, "\n")
	)
end

-- Playing, audible Sounds in our pools: loops (HC_* names or HC_* emitters) and one-shots.
local function census()
	local loops, shots = 0, 0
	for _, root in roots() do
		for _, s in root:GetDescendants() do
			if s:IsA("Sound") and s.IsPlaying and s.Volume > 0.001 then
				local p = s.Parent
				if string.sub(s.Name, 1, 3) == "HC_" or (p and p:IsA("Attachment") and string.sub(p.Name, 1, 3) == "HC_") then
					loops += 1
				else
					shots += 1
				end
			end
		end
	end
	return loops, shots
end
-- Playing Sounds anywhere else the client sees (footsteps, CoreGui...): information only.
local function others()
	local n = 0
	local v, a = voices(), anchor()
	for _, root in { workspace, SS, lp:FindFirstChild("PlayerGui") } do
		for _, s in root:GetDescendants() do
			if
				s:IsA("Sound")
				and s.IsPlaying
				and s.Volume > 0.001
				and not ((v and s:IsDescendantOf(v)) or (a and s:IsDescendantOf(a)))
			then
				n += 1
			end
		end
	end
	return n
end
function HCA.count()
	local l, s = census()
	return ("[COUNT] loops=%d one-shots=%d total=%d (cap 40) other=%d"):format(l, s, l + s, others())
end
function HCA.sampler(seconds)
	_G.HC_Samples = {}
	task.spawn(function()
		local t0 = os.clock()
		local k = 0
		while os.clock() - t0 < seconds do
			k += 1
			local l, s = census()
			local o = if k % 5 == 1 then others() else nil
			table.insert(_G.HC_Samples, { t = os.clock() - t0, loops = l, shots = s, other = o })
			task.wait(1)
		end
	end)
	return "sampler started for " .. seconds .. " s"
end
function HCA.samplerRead()
	local tr = _G.HC_Samples or {}
	local peak, at, maxOther = -1, nil, 0
	local hist = {}
	for _, r in tr do
		local n = r.loops + r.shots
		if n > peak then
			peak, at = n, r
		end
		if r.other and r.other > maxOther then
			maxOther = r.other
		end
		table.insert(hist, tostring(n))
	end
	local verdict = if #tr < 50 then "TOO FEW SAMPLES" elseif peak <= 40 then "PASS" else "OVER CAP"
	return ("[CAP] samples=%d peak=%d (loops %d + one-shots %d at t=%.0f s) cap=40, other playing sounds max=%d -> %s\n  per-second: %s"):format(
		#tr,
		peak,
		if at then at.loops else 0,
		if at then at.shots else 0,
		if at then at.t else 0,
		maxOther,
		verdict,
		table.concat(hist, " ")
	)
end

function HCA.unloaded()
	local bad = {}
	for _, root in roots() do
		for _, s in root:GetDescendants() do
			if s:IsA("Sound") and s.SoundId ~= "" and not s.IsLoaded then
				table.insert(bad, s:GetFullName() .. " " .. keyOf(s))
			end
		end
	end
	return ("[UNLOADED] %d%s"):format(#bad, if #bad > 0 then ":\n  " .. table.concat(bad, "\n  ") else " -> PASS")
end

return "HCA ready: groups, beds, engine, engineTrace, engineRead, radio, sirens, heli, count, sampler, samplerRead, unloaded"
```

### IDS (Client)

```lua
local SKIP_RADIO = false
local CP = game:GetService("ContentProvider")
local Sounds = require(game:GetService("ReplicatedStorage").Shared.Config.Sounds)
local keyById, list = {}, {}
for key, def in Sounds do
	if
		type(def) == "table"
		and type(def.id) == "string"
		and not keyById[def.id]
		and not (SKIP_RADIO and string.sub(key, 1, 6) == "Radio_")
	then
		keyById[def.id] = key
		local s = Instance.new("Sound")
		s.SoundId = def.id
		table.insert(list, s)
	end
end
local failed = {}
CP:PreloadAsync(list, function(id, status)
	if status ~= Enum.AssetFetchStatus.Success then
		table.insert(failed, ("%s %s %s"):format(keyById[id] or "?", id, status.Name))
	end
end)
for _, s in list do
	s:Destroy()
end
return ("[IDS] %d unique ids%s, %d failed%s"):format(
	#list,
	if SKIP_RADIO then " (radio skipped)" else "",
	#failed,
	if #failed > 0 then ":\n  " .. table.concat(failed, "\n  ") else " -> PASS"
)
```

### DISTRICT_TP (Server)

```lua
local ID = "downtown" -- then "beach", then "hills"
local WL = require(game:GetService("ReplicatedStorage").Shared.Config.WorldLayout)
local plr = game:GetService("Players"):GetPlayers()[1]
local char = plr and plr.Character
local root = char and char:FindFirstChild("HumanoidRootPart")
assert(root, "no character")
local target = nil
for _, d in WL.Districts do
	if d.id == ID then
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		local sx, sz = 0, 0
		for _, p in d.polygon do
			sx += p.X
			sz += p.Z
			x0, z0 = math.min(x0, p.X), math.min(z0, p.Z)
			x1, z1 = math.max(x1, p.X), math.max(z1, p.Z)
		end
		local cx, cz = sx / #d.polygon, sz / #d.polygon
		if WL.districtAt(cx, cz) == ID then
			target = Vector2.new(cx, cz)
		end
		for i = 1, 9 do
			for j = 1, 9 do
				if not target then
					local x, z = x0 + (x1 - x0) * i / 10, z0 + (z1 - z0) * j / 10
					if WL.districtAt(x, z) == ID then
						target = Vector2.new(x, z)
					end
				end
			end
		end
	end
end
assert(target, "no point found inside " .. ID)
local y = WL.heightAt(target.X, target.Y) + 8
root.Anchored = true
char:PivotTo(CFrame.new(target.X, y, target.Y))
return ("tp %s -> (%.0f, %.0f, %.0f) districtAt=%s"):format(ID, target.X, y, target.Y, WL.districtAt(target.X, target.Y))
```

### UNANCHOR (Server)

```lua
local plr = game:GetService("Players"):GetPlayers()[1]
local root = plr and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
if root then
	root.Anchored = false
end
return "unanchored"
```
