#!/usr/bin/env python3
"""Run carpipe on the Vehicles v2 roster (roster.json): one subprocess per car, outputs to assets/vehicles/<id>/.

    python3 -I tools/blender/carpipe/build_roster.py                 # every car not built yet
    python3 -I tools/blender/carpipe/build_roster.py nami wren       # just these (rebuilds them)
    python3 -I tools/blender/carpipe/build_roster.py --force         # everything
    python3 -I tools/blender/carpipe/build_roster.py --no-bake nami  # fast geometry check

Sources: assets/source/sketchfab/<source>/model.glb (re-fetchable, not in git; the main checkout's copy is used when
this is a worktree). Logs: assets/vehicles/_logs/<id>.log. Runs niced (the machine is shared).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(REPO, "assets", "vehicles")


def source_path(slug):
    cands = [os.path.join(REPO, "assets", "source", "sketchfab", slug, "model.glb")]
    # git worktrees (.claude/worktrees/<name>) share the main checkout's untracked downloads
    parts = REPO.split(os.sep)
    if ".claude" in parts:
        main = os.sep.join(parts[: parts.index(".claude")])
        cands.append(os.path.join(main, "assets", "source", "sketchfab", slug, "model.glb"))
    for c in cands:
        if os.path.exists(c):
            return c
    return None


def load_roster():
    r = json.load(open(os.path.join(HERE, "roster.json")))
    defaults = r.get("_defaults", {})
    cars = {k: v for k, v in r.items() if not k.startswith("_")}
    return cars, defaults


def car_config(entry, defaults, slug_meta):
    cfg = json.loads(json.dumps(defaults))
    for k, v in (entry.get("config") or {}).items():
        if k == "roles":
            cfg.setdefault("roles", {}).update(v)
        else:
            cfg[k] = v
    if slug_meta:
        lic = slug_meta.get("license", {})
        au = slug_meta.get("author", {})
        cfg["source"] = {
            "title": slug_meta.get("name"),
            "url": slug_meta.get("modelUrl"),
            "license": f"{lic.get('label')} ({lic.get('url')})",
            "attribution": f"\"{slug_meta.get('name')}\" by {au.get('displayName')} ({au.get('profileUrl')}) on "
                           f"Sketchfab, licensed {lic.get('label')}",
            "sketchfab_uid": slug_meta.get("uid"),
        }
    return cfg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--no-bake", action="store_true")
    a = ap.parse_args()
    cars, defaults = load_roster()
    ids = a.ids or list(cars)
    os.makedirs(os.path.join(OUT, "_logs"), exist_ok=True)
    results = {}
    for vid in ids:
        e = cars[vid]
        glb = os.path.join(OUT, vid, vid + ".glb")
        if os.path.exists(glb) and not a.force and not a.ids:
            results[vid] = "skip (built)"
            continue
        src = source_path(e["source"])
        if not src:
            results[vid] = "missing source " + e["source"]
            print(vid, results[vid], flush=True)
            continue
        meta_p = os.path.join(REPO, "assets", "source", "sketchfab", e["source"], "meta.json")
        meta = json.load(open(meta_p)) if os.path.exists(meta_p) else None
        cfg = car_config(e, defaults, meta)
        cfg_path = os.path.join(OUT, "_logs", vid + ".config.json")
        json.dump(cfg, open(cfg_path, "w"), indent=1)
        # a clean output folder: stale textures from an earlier source would be picked up as this car's body image
        if os.path.isdir(os.path.join(OUT, vid)):
            shutil.rmtree(os.path.join(OUT, vid))
        cmd = ["nice", "-n", "10", sys.executable, "-I", os.path.join(HERE, "build_car.py"), "--in", src,
               "--name", vid, "--out", OUT, "--config", cfg_path]
        if a.no_bake:
            cmd.append("--no-bake")
        t0 = time.time()
        with open(os.path.join(OUT, "_logs", vid + ".log"), "w") as log:
            rc = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT)
        results[vid] = f"rc={rc} {time.time() - t0:.0f}s"
        print(vid, results[vid], flush=True)
    print(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
