#!/usr/bin/env python3
"""Real-engine probe of uploaded car Models (Open Cloud Luau Execution on the latest saved place version, read-only:
nothing is uploaded or saved). Loads each car with InsertService (the runtime path, Shared/Vehicle/CarTemplates) and
records what the GLB importer made of it: every instance's class / name / parent, every BasePart's CFrame, Size,
PivotOffset, Material, Color, Transparency, MeshPart TextureID, SurfaceAppearance (and its AlphaMode), and whether
the runtime writes CarBuilder v2 relies on work (Body.TextureID = the body image, Body.Color, MeshPart.Size scaling).

    python3 tools/blender/carpipe/cloud_probe.py [vid ...]      # default: every car in the manifest

Writes docs/v2/early/vehicles/cloud_probe.json (tests/spec/vehicles_v2.spec.luau rebuilds the imported trees from it).
The API key is never printed.
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import cloud_smoke as cs  # noqa: E402

UNIVERSE, PLACE = "10773288390", "106226892419530"

LUAU = r'''
local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local SAMPLES = HttpService:JSONDecode([==[__SAMPLES__]==])
local function v3(v) return { v.X, v.Y, v.Z } end
local function cf(c)
	local rx, ry, rz = c:ToOrientation()
	return { pos = v3(c.Position), right = v3(c.RightVector), up = v3(c.UpVector), look = v3(c.LookVector),
		orientationDeg = { math.deg(rx), math.deg(ry), math.deg(rz) } }
end
local report = { cars = {} }
for _, s in SAMPLES do
	local t0 = os.clock()
	local ok, res = pcall(function() return InsertService:LoadAsset(s.id) end)
	local car = { vid = s.vid, id = s.id, ok = ok, seconds = os.clock() - t0, instances = {} }
	if ok and res then
		for _, d in res:GetDescendants() do
			local e = { class = d.ClassName, name = d.Name, parent = d.Parent and (d.Parent.ClassName .. ":" .. d.Parent.Name) }
			if d:IsA("BasePart") then
				e.cframe = cf(d.CFrame)
				e.size = v3(d.Size)
				e.pivotOffset = cf(d.PivotOffset)
				e.material = d.Material.Name
				e.color = { d.Color.R, d.Color.G, d.Color.B }
				e.transparency = d.Transparency
				e.anchored = d.Anchored
				e.canCollide = d.CanCollide
				if d:IsA("MeshPart") then
					e.textureId = d.TextureID
					local okM, mid = pcall(function() return d.MeshId end)
					e.meshId = okM and mid or nil
					local okD, ds = pcall(function() return d.DoubleSided end)
					e.doubleSided = okD and ds or nil
					local okF, fid = pcall(function() return d.CollisionFidelity.Name end)
					e.collisionFidelity = okF and fid or nil
				end
				local sa = d:FindFirstChildOfClass("SurfaceAppearance")
				if sa then
					local okA, am = pcall(function() return sa.AlphaMode.Name end)
					e.surfaceAppearance = { alphaMode = okA and am or "?" }
				end
			elseif d:IsA("Model") then
				local okP, piv = pcall(function() return d.WorldPivot end)
				if okP then e.worldPivot = cf(piv) end
			end
			table.insert(car.instances, e)
		end
		-- runtime writes CarBuilder v2 relies on
		local body
		for _, d in res:GetDescendants() do
			if d:IsA("MeshPart") and d.Name == "Body" then body = d end
		end
		if body then
			local w = {}
			w.textureSet = pcall(function() body.TextureID = s.bodyImage end)
			w.textureRead = body.TextureID
			w.colorSet = pcall(function() body.Color = Color3.fromRGB(200, 30, 30) end)
			local before = body.Size
			w.sizeSet = pcall(function() body.Size = before * 1.5 end)
			w.sizeRatio = body.Size.X / math.max(before.X, 1e-6)
			w.materialSet = pcall(function() body.Material = Enum.Material.SmoothPlastic end)
			car.writes = w
		end
		res:Destroy()
	else
		car.error = tostring(res)
	end
	table.insert(report.cars, car)
end
return HttpService:JSONEncode(report)
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    a = ap.parse_args()
    man = json.load(open(os.path.join(ROOT, "assets", "vehicles", "manifest.json")))
    ids = a.ids or sorted(k for k, v in man["models"].items() if v.get("assetId"))
    samples = []
    for vid in ids:
        m = man["models"].get(vid, {})
        if not m.get("assetId"):
            continue
        img = man["images"].get(vid, {}).get("assetId", 0)
        samples.append({"vid": vid, "id": m["assetId"], "bodyImage": "rbxassetid://%d" % img if img else ""})
    script = LUAU.replace("__SAMPLES__", json.dumps(samples))
    url = f"https://apis.roblox.com/cloud/v2/universes/{UNIVERSE}/places/{PLACE}/luau-execution-session-tasks"
    st, body = cs.call("POST", url, json.dumps({"script": script, "timeout": "300s"}).encode(), "application/json")
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
    report["probedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    out = os.path.join(ROOT, "docs", "v2", "early", "vehicles", "cloud_probe.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(report, open(out, "w"), indent=1, sort_keys=True)
    for c in report["cars"]:
        parts = [i for i in c["instances"] if "size" in i]
        print("%-22s ok=%s %.2fs parts=%d writes=%s" % (c["vid"], c["ok"], c["seconds"], len(parts), c.get("writes")))
    print("wrote", out)


if __name__ == "__main__":
    main()
