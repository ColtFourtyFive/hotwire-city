#!/usr/bin/env python3
"""Real-engine probe of what the look relies on, via Open Cloud Luau Execution (a headless server of the latest saved
place version; the task only reads and sets Lighting/Terrain properties in that throwaway server, nothing is saved):

  * Lighting:GetSunDirection() / GetMoonDirection() at GeographicLatitude 0, 23.5, 34, 41.733 for 28 ClockTimes
    (the sun model in Config/Look.Sun and LightingService.sunDirectionAt is fitted to and unit-tested against this);
  * which materials Terrain:SetMaterialColor accepts, and the engine's default terrain colours;
  * Clouds.Enabled, MaterialService:SetBaseMaterialOverride with an unknown name, Lighting.LightingStyle,
    PrioritizeLightingQuality and the default water properties of that place version.

Result: tools/look/sun_probe_result.json (tests/spec/look.spec.luau compares the model to every sample).
Usage: python3 tools/look/sun_probe.py [out.json]     (the API key is read by tools/cloud_smoke.py, never printed)
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
local out = { samples = {}, misc = {} }
local function el(d) return math.deg(math.asin(math.clamp(d.Y, -1, 1))) end
local function az(d) return math.deg(math.atan2(d.X, -d.Z)) end
for _, lat in { 34, 0, 23.5, 41.733 } do
	Lighting.GeographicLatitude = lat
	for _, h in { 0, 3, 5.5, 5.95, 6.0, 6.05, 6.5, 7.0, 7.3, 7.5, 8.7, 9, 10, 11, 11.5, 12, 12.5, 13, 14, 15.8, 16.5, 16.7, 17, 17.9, 18.0, 18.1, 19.5, 21 } do
		Lighting.ClockTime = h
		local d = Lighting:GetSunDirection()
		local m = Lighting:GetMoonDirection()
		table.insert(out.samples, { lat = lat, h = h, x = d.X, y = d.Y, z = d.Z, el = el(d), az = az(d), mel = el(m), maz = az(m) })
	end
end
local terrain = workspace.Terrain
for _, name in { "Grass", "Sand", "Ground", "Slate", "Marble", "Pebble", "Plaster", "ClayRoofTiles", "CorrodedMetal", "Concrete", "Asphalt", "Pavement", "Brick", "WoodPlanks", "LeafyGrass", "Rock" } do
	local okg0, col0 = pcall(function() return terrain:GetMaterialColor(Enum.Material[name]) end)
	local ok, err = pcall(function()
		terrain:SetMaterialColor(Enum.Material[name], Color3.fromRGB(10, 20, 30))
	end)
	out.misc["terrain_" .. name] = { ok = ok, err = (not ok) and tostring(err) or nil, default = tostring(col0), okGet = okg0 }
end
local okc, enabled = pcall(function() local c = Instance.new("Clouds"); return c.Enabled end)
out.misc.cloudsEnabledProp = { ok = okc, v = tostring(enabled) }
local MS = game:GetService("MaterialService")
local oks, errs = pcall(function() MS:SetBaseMaterialOverride(Enum.Material.Asphalt, "Nope") end)
out.misc.setOverride = { ok = oks, err = tostring(errs) }
local okr, rs = pcall(function() return Lighting.LightingStyle end)
out.misc.lightingStyleVal = tostring(okr) .. " " .. tostring(rs)
local okq, q = pcall(function() return Lighting.PrioritizeLightingQuality end)
out.misc.prioritize = tostring(okq) .. " " .. tostring(q)
out.misc.water = { tostring(terrain.WaterColor), terrain.WaterTransparency, terrain.WaterReflectance, terrain.WaterWaveSize, terrain.WaterWaveSpeed }
return game:GetService("HttpService"):JSONEncode(out)
'''


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "sun_probe_result.json")
    base = f"https://apis.roblox.com/cloud/v2/universes/{UNIVERSE}/places/{PLACE}"
    st, body = cs.call("POST", f"{base}/luau-execution-session-tasks",
                       json.dumps({"script": LUAU, "timeout": "120s"}).encode(), "application/json")
    print("task:", st, body[:200])
    if st != 200:
        sys.exit(3)
    path = json.loads(body)["path"]
    while True:
        time.sleep(4)
        info = json.loads(cs.call("GET", f"https://apis.roblox.com/cloud/v2/{path}")[1])
        if info.get("state") in ("COMPLETE", "FAILED", "CANCELLED"):
            break
    if info.get("state") != "COMPLETE":
        print(json.dumps(info.get("error", info), indent=1)[:3000])
        sys.exit(4)
    res = json.loads(info["output"]["results"][0])
    res["probe"] = {"task": path, "date": time.strftime("%Y-%m-%d"), "tool": "tools/look/sun_probe.py"}
    with open(out_path, "w") as f:
        json.dump(res, f, indent=1, sort_keys=True)
        f.write("\n")
    print("saved", out_path)


if __name__ == "__main__":
    main()
