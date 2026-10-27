#!/usr/bin/env python3
"""Real-engine probe of the uploaded building Models (Open Cloud Luau Execution, read-only: no place upload, nothing
saved). On the latest saved version of the game place it loads a sample of building assets with InsertService (the
runtime path: AssetLibrary.loadRaw -> InsertService:LoadAsset for owned assets), checks every expected MeshPart
("<key>_<part>") is there with sane sizes and the front at -Z, applies the runtime surfaces (Material,
MaterialVariant, Color, TextureID) to one model and reads them back, and times the loads.

    python3 tools/blender/buildkit/cloud_probe.py [--keys tower_hero640 midtown_w60f4 ...]

Writes docs/v2/early/buildings/cloud_probe.json. The API key is never printed.
"""
import argparse, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import cloud_smoke as cs  # noqa: E402

UNIVERSE, PLACE = "10773288390", "106226892419530"
DEFAULT_KEYS = ["tower_hero640", "tower_p290a", "office_w90f7", "midtown_w60f4", "midtown_w44f0b", "deco_w66f4",
                "retail_store50", "house_spanish58", "mansion_w130a", "house_villa96", "industrial_wh130"]

LUAU = r'''
local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local MaterialService = game:GetService("MaterialService")
local SAMPLES = HttpService:JSONDecode([==[__SAMPLES__]==])
local IMAGE = "__IMAGE__"
local report = { models = {}, surface = {}, materialService = {} }
for _, mv in MaterialService:GetDescendants() do
	if mv:IsA("MaterialVariant") then
		table.insert(report.materialService, mv.Name .. ":" .. mv.BaseMaterial.Name)
	end
end
local first = nil
for _, s in SAMPLES do
	local t0 = os.clock()
	local ok, res = pcall(function() return InsertService:LoadAsset(s.id) end)
	local entry = { key = s.key, id = s.id, ok = ok, seconds = os.clock() - t0 }
	if ok and res then
		local byName, meshParts, models, other = {}, 0, 0, {}
		for _, d in res:GetDescendants() do
			if d:IsA("MeshPart") then
				meshParts += 1
				byName[d.Name] = d
			elseif d:IsA("Model") then
				models += 1
			else
				other[d.ClassName] = (other[d.ClassName] or 0) + 1
			end
		end
		local missing = {}
		for _, n in s.parts do
			if not byName[s.key .. "_" .. n] then table.insert(missing, n) end
		end
		entry.meshParts, entry.models, entry.otherClasses, entry.missing = meshParts, models, other, missing
		local walls = byName[s.key .. "_Walls"] or byName[s.key .. "_Walls2"]
		local front = byName[s.key .. "_Awning"] or byName[s.key .. "_Sign"] or byName[s.key .. "_Brand"]
		if walls then entry.wallsSize = { walls.Size.X, walls.Size.Y, walls.Size.Z } end
		if front then entry.frontZ = front.Position.Z end
		local glass = byName[s.key .. "_Glass"]
		if glass then
			entry.glassMaterial = glass.Material.Name
			entry.glassTexture = glass.TextureID
			entry.hasSurfaceAppearance = glass:FindFirstChildOfClass("SurfaceAppearance") ~= nil
		end
		if not first and walls and glass then first = { walls = walls, glass = glass } end
	else
		entry.error = tostring(res)
	end
	table.insert(report.models, entry)
end
if first then
	local w, g = first.walls, first.glass
	local okW, errW = pcall(function()
		w.Material = Enum.Material.Brick
		w.MaterialVariant = "HC_BrickTan"
		w.Color = Color3.fromRGB(220, 197, 171)
	end)
	local okG, errG = pcall(function() g.TextureID = IMAGE end)
	report.surface = {
		wallsSet = okW, wallsErr = errW and tostring(errW) or nil,
		wallsMaterial = w.Material.Name, wallsVariant = w.MaterialVariant,
		glassSet = okG, glassErr = errG and tostring(errG) or nil, glassTexture = g.TextureID,
	}
end
return HttpService:JSONEncode(report)
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", nargs="*", default=DEFAULT_KEYS)
    a = ap.parse_args()
    man = json.load(open(os.path.join(ROOT, "assets", "buildings", "manifest.json")))
    cat = json.load(open(os.path.join(ROOT, "assets", "buildings", "catalog.json")))["variants"]
    samples = []
    for k in a.keys:
        parts = [pn[len(k) + 1:] for pn in cat[k]["parts"]]
        samples.append({"key": k, "id": man["models"][k]["assetId"], "parts": parts})
    image = "rbxassetid://%d" % man["images"]["windows_day"]["assetId"]
    script = LUAU.replace("__SAMPLES__", json.dumps(samples)).replace("__IMAGE__", image)
    url = f"https://apis.roblox.com/cloud/v2/universes/{UNIVERSE}/places/{PLACE}/luau-execution-session-tasks"
    st, body = cs.call("POST", url, json.dumps({"script": script, "timeout": "240s"}).encode(), "application/json")
    if st != 200:
        print("task:", st, body[:400])
        sys.exit(3)
    task_path = json.loads(body)["path"]
    while True:
        time.sleep(5)
        info = json.loads(cs.call("GET", f"https://apis.roblox.com/cloud/v2/{task_path}")[1])
        if info.get("state") in ("COMPLETE", "FAILED", "CANCELLED"):
            break
    if info.get("state") != "COMPLETE":
        print(info.get("state"), json.dumps(info.get("error", info), indent=1)[:2000])
        sys.exit(4)
    report = json.loads(info["output"]["results"][0])
    report["taskVersion"] = task_path.split("/versions/")[1].split("/")[0] if "/versions/" in task_path else None
    report["probedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    out = os.path.join(ROOT, "docs", "v2", "early", "buildings", "cloud_probe.json")
    json.dump(report, open(out, "w"), indent=1, sort_keys=True)
    for m in report["models"]:
        print("%-20s ok=%s %.2fs meshParts=%s missing=%s frontZ=%s glass=%s/%s SA=%s" % (
            m["key"], m["ok"], m["seconds"], m.get("meshParts"), m.get("missing"), m.get("frontZ"),
            m.get("glassMaterial"), m.get("glassTexture"), m.get("hasSurfaceAppearance")))
    print("surface:", report["surface"])
    print("MaterialService variants:", len(report["materialService"]))
    print("wrote", out)


if __name__ == "__main__":
    main()
