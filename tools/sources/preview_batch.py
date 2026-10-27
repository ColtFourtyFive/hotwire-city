#!/usr/bin/env python3
"""Render studio previews for every downloaded Sketchfab model and merge analysis into meta.json.

Usage: python3 -I tools/sources/preview_batch.py [--kind vehicle|weapon] [--only slug-substr] [--force]

Each model is rendered in its own Blender process (crash isolation, 5 min timeout) via
tools/sources/render_preview.py -> <dir>/preview.png + preview_inset.png; stats go to meta.json["analysis"].
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SRC = ROOT / "assets" / "source" / "sketchfab"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind")
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--samples", default="24")
    a = ap.parse_args()
    metas = sorted(SRC.glob("*/meta.json"))
    for mp in metas:
        meta = json.loads(mp.read_text())
        d = mp.parent
        if a.kind and meta.get("kind") != a.kind:
            continue
        if a.only and a.only not in d.name:
            continue
        glb = d / "model.glb"
        out = d / "preview.png"
        if not glb.exists() or (out.exists() and meta.get("analysis") and not a.force):
            continue
        stats = d / "_stats.json"
        t0 = time.time()
        cmd = [sys.executable, "-I", str(HERE / "render_preview.py"), str(glb), str(out), str(stats),
               "--kind", meta.get("kind") or "vehicle", "--cls", meta.get("class") or "", "--samples", a.samples]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            ok = r.returncode == 0 and stats.exists()
        except subprocess.TimeoutExpired:
            ok, r = False, None
        if ok:
            st = json.loads(stats.read_text())
            st.pop("renders", None)
            meta["analysis"] = st
            mp.write_text(json.dumps(meta, indent=2) + "\n")
            stats.unlink()
            print(f"OK  {d.name}  {st['triangles']}tris  dims={st['dims_m']}  wheels={st['wheels_separate']}  "
                  f"front={st.get('front_evidence')}  {time.time() - t0:.0f}s", flush=True)
        else:
            err = (r.stderr[-600:] if r else "timeout")
            meta["analysis"] = {"error": err[-300:]}
            mp.write_text(json.dumps(meta, indent=2) + "\n")
            print(f"ERR {d.name}: {err}", flush=True)


if __name__ == "__main__":
    main()
