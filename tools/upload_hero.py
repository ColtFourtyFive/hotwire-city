#!/usr/bin/env python3
"""Upload a GLB to Roblox (Open Cloud) as a Model asset and record it in a manifest JSON.
Usage: python3 tools/upload_hero.py <key> <file.glb> "<Display Name>" <yawDegrees> <targetSizeStuds> [userId] [--manifest path] [--fit length|height|maxDim|footprint] [--role role]
Default manifest: assets/hero/manifest.json. Use a separate manifest per parallel worker.
"""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from rbxcloud import upload, req

args = sys.argv[1:]
opts = {}
for flag in ("--manifest", "--fit", "--role"):
    if flag in args:
        i = args.index(flag)
        opts[flag] = args[i + 1]
        del args[i:i + 2]
key_, path, name, yaw, length = args[0:5]
user = args[5] if len(args) > 5 else "11686693147"
st, body, _ = upload(path, name, user, "Model", "model/gltf-binary")
print("upload", st, body[:200])
op = json.loads(body)["path"]
asset = None
for _ in range(40):
    st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/{op}")
    d = json.loads(body)
    if d.get("done"):
        asset = d["response"]
        break
    time.sleep(4)
print(json.dumps(asset)[:400])
mpath = opts.get("--manifest", "assets/hero/manifest.json")
os.makedirs(os.path.dirname(mpath), exist_ok=True)
m = json.load(open(mpath)) if os.path.exists(mpath) else {}
m[key_] = {"assetId": int(asset["assetId"]), "file": path, "name": name, "yaw": float(yaw), "length": float(length),
           "fit": opts.get("--fit", "length"), "role": opts.get("--role", key_),
           "moderation": asset.get("moderationResult", {}).get("moderationState")}
json.dump(m, open(mpath, "w"), indent=2)
print("recorded", key_, m[key_])
