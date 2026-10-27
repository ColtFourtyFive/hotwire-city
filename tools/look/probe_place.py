#!/usr/bin/env python3
"""Real-engine probe of the look settings a place VERSION actually loads with, via Open Cloud Luau Execution (a
throwaway headless server of that version; nothing is saved).

Reads, as the engine loaded the file (the place's own scripts do not run in a Luau Execution task):
  * Lighting.LightingStyle, PrioritizeLightingQuality, Lighting attributes (RBX_* migration markers), Technology
    (RobloxScript-only: usually unreadable);
  * MaterialService: MaterialVariant count and GetBaseMaterialOverride for every Look.Overrides base material.
Then emulates the server boot of the look (ReplicatedStorage.Shared.Util.MaterialOverrides.apply + LightingService.init)
and reads back:
  * GetBaseMaterialOverride after the runtime apply (job 0009: the file properties alone are not honoured);
  * Atmosphere / exposure / brightness / tint / Sky.MoonAngularSize at noon, golden hour (17.6) and night (22.5).

Usage:
  rojo build -o build/HotwireCity.rbxl
  python3 tools/look/probe_place.py --upload build/HotwireCity.rbxl     # upload a Saved version, then probe it
  python3 tools/look/probe_place.py --version 31                        # probe an existing version
Result: build/probe_place.json (+ a summary on stdout). The API key is read by tools/cloud_smoke.py, never printed.
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import cloud_smoke as cs  # noqa: E402

UNIVERSE, PLACE = "10773288390", "106226892419530"

LUAU = r'''
local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local out = { file = {}, runtime = {}, look = {}, errors = {} }
local function try(label, fn)
	local ok, v = pcall(fn)
	if not ok then
		table.insert(out.errors, label .. ": " .. tostring(v))
		return nil
	end
	return v
end
local function c3(c)
	return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
end

-- 1. as loaded from the file
out.file.placeVersion = game.PlaceVersion
out.file.lightingStyle = try("LightingStyle", function() return tostring(Lighting.LightingStyle) end)
out.file.prioritizeLightingQuality = try("Prioritize", function() return Lighting.PrioritizeLightingQuality end)
out.file.technology = try("Technology", function() return tostring(Lighting.Technology) end)
out.file.lightingAttributes = {}
for k, v in Lighting:GetAttributes() do
	out.file.lightingAttributes[k] = tostring(v)
end
local variants = 0
for _, c in MaterialService:GetChildren() do
	if c:IsA("MaterialVariant") then variants += 1 end
end
out.file.materialVariants = variants
local Look = require(ReplicatedStorage.Shared.Config.Look)
local function readOverrides()
	local t, active, total = {}, 0, 0
	for base, variant in Look.Overrides do
		total += 1
		local got = try("Get " .. base, function()
			return MaterialService:GetBaseMaterialOverride((Enum.Material :: any)[base])
		end)
		t[base] = got
		if got == variant then active += 1 end
	end
	return t, active, total
end
local fileOverrides, fileActive, total = readOverrides()
out.file.overrides = fileOverrides
out.file.overridesActive = fileActive
out.file.overridesWanted = total
local sky = Lighting:FindFirstChildOfClass("Sky")
out.file.moonAngularSize = sky and sky.MoonAngularSize
local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
out.file.atmosphereDensity = atmo and atmo.Density

-- 2. the runtime apply (what LightingService.init / LookClient.init do; versions before look-fix3 have no module)
local MO = try("require MaterialOverrides", function()
	return require(ReplicatedStorage.Shared.Util.MaterialOverrides)
end)
if MO then
	local r = MO.apply("probe", nil, true)
	out.runtime.summary = MO.summary("probe", r)
	out.runtime.attribute = MaterialService:GetAttribute(MO.ATTRIBUTE)
end
local rtOverrides, rtActive = readOverrides()
out.runtime.overrides = rtOverrides
out.runtime.overridesActive = rtActive
out.runtime.moonZeroAccepted = try("MoonAngularSize 0", function()
	local s = Instance.new("Sky")
	s.MoonAngularSize = 0
	return s.MoonAngularSize
end)

-- 3. LightingService look at a few game hours
local server = game:GetService("ServerScriptService"):FindFirstChild("Server")
local LS = try("require LightingService", function() return require(server.Systems.LightingService) end)
if LS then
	try("LightingService.init", function() LS.init() end)
	out.runtime.overridesAfterInit = select(2, readOverrides())
	for _, h in { 12, 17.6, 22.5 } do
		Workspace:SetAttribute("TimeOfDayLock", h)
		try("setClockTime " .. h, function() LS.setClockTime(h) end)
		local a = Lighting:FindFirstChildOfClass("Atmosphere")
		local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
		local s = Lighting:FindFirstChildOfClass("Sky")
		out.look[tostring(h)] = {
			clock = Lighting.ClockTime,
			sunElevation = math.deg(math.asin(Lighting:GetSunDirection().Y)),
			brightness = Lighting.Brightness,
			exposure = Lighting.ExposureCompensation,
			outdoorAmbient = c3(Lighting.OutdoorAmbient),
			density = a and a.Density,
			haze = a and a.Haze,
			tint = cc and c3(cc.TintColor),
			saturation = cc and cc.Saturation,
			moon = s and s.MoonAngularSize,
			sky = Lighting:GetAttribute("Sky"),
		}
	end
	Workspace:SetAttribute("TimeOfDayLock", nil)
end
out.lightingStyleAtEnd = tostring(Lighting.LightingStyle)
return game:GetService("HttpService"):JSONEncode(out)
'''


def main():
    args = sys.argv[1:]
    version = args[args.index("--version") + 1] if "--version" in args else None
    if "--upload" in args:
        path = args[args.index("--upload") + 1]
        ctype = "application/xml" if path.endswith(".rbxlx") else "application/octet-stream"
        st, body = cs.call("POST", f"https://apis.roblox.com/universes/v1/{UNIVERSE}/places/{PLACE}/versions"
                           "?versionType=Saved", open(path, "rb").read(), ctype)
        print("upload:", st, body[:200])
        if st != 200:
            sys.exit(2)
        version = str(json.loads(body)["versionNumber"])
    base = f"https://apis.roblox.com/cloud/v2/universes/{UNIVERSE}/places/{PLACE}"
    url = f"{base}/versions/{version}/luau-execution-session-tasks" if version else f"{base}/luau-execution-session-tasks"
    st, body = cs.call("POST", url, json.dumps({"script": LUAU, "timeout": "180s"}).encode(), "application/json")
    if st != 200:
        print("task:", st, body[:400])
        sys.exit(3)
    task_path = json.loads(body)["path"]
    print("task version:", task_path.split("/versions/")[1].split("/")[0])
    while True:
        time.sleep(5)
        info = json.loads(cs.call("GET", f"https://apis.roblox.com/cloud/v2/{task_path}")[1])
        if info.get("state") in ("COMPLETE", "FAILED", "CANCELLED"):
            break
    if info.get("state") != "COMPLETE":
        print(info.get("state"), json.dumps(info.get("error", info), indent=1)[:3000])
        sys.exit(4)
    res = json.loads(info["output"]["results"][0])
    res["probe"] = {"task": task_path, "date": time.strftime("%Y-%m-%d"), "tool": "tools/look/probe_place.py"}
    os.makedirs("build", exist_ok=True)
    with open("build/probe_place.json", "w") as f:
        json.dump(res, f, indent=1, sort_keys=True)
        f.write("\n")
    fl, rt = res["file"], res["runtime"]
    print("file:    LightingStyle %s, PrioritizeLightingQuality %s, Technology %s, attributes %s" % (
        fl.get("lightingStyle"), fl.get("prioritizeLightingQuality"), fl.get("technology"),
        fl.get("lightingAttributes")))
    print("file:    %s MaterialVariants, overrides active %s/%s (Asphalt reads %s)" % (
        fl.get("materialVariants"), fl.get("overridesActive"), fl.get("overridesWanted"),
        (fl.get("overrides") or {}).get("Asphalt")))
    print("runtime: overrides active %s/%s after apply (Asphalt reads %s), %s" % (
        rt.get("overridesActive"), fl.get("overridesWanted"), (rt.get("overrides") or {}).get("Asphalt"),
        rt.get("summary")))
    for h, v in sorted(res.get("look", {}).items(), key=lambda kv: float(kv[0])):
        print("look %5s: %s" % (h, json.dumps(v, sort_keys=True)))
    if res.get("errors"):
        print("errors:", res["errors"])
    print("saved build/probe_place.json")


if __name__ == "__main__":
    main()
