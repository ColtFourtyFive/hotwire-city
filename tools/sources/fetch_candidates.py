#!/usr/bin/env python3
"""Download every candidate in docs/v2/sourcing/candidates.json through tools/sources/sketchfab.py.

Usage: python3 -I tools/sources/fetch_candidates.py [--only class1,class2] [--kind vehicle|weapon]

Slug = "<v|w>-<class>--<model-name>-<uid6>". Already-downloaded models are skipped (resumable).
Results (ok / refused / error, never URLs or tokens) go to docs/v2/sourcing/fetch_log.json.
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sketchfab as sf  # noqa: E402

CAND = sf.ROOT / "docs" / "v2" / "sourcing" / "candidates.json"
LOG = sf.ROOT / "docs" / "v2" / "sourcing" / "fetch_log.json"


def slug_for(c):
    return f"{c['kind'][0]}-{c['class'].replace('_', '-')}--{sf.slugify(c['name'], 34)}-{c['uid'][:6]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--kind", default=None)
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    cands = json.loads(CAND.read_text())
    log = json.loads(LOG.read_text()) if LOG.exists() else {}
    for c in cands:
        if only and c["class"] not in only:
            continue
        if a.kind and c["kind"] != a.kind:
            continue
        slug = slug_for(c)
        t0 = time.time()
        try:
            rec = sf.download(c["uid"], slug=slug, cls=c["class"], kind=c["kind"])
            log[c["uid"]] = {"status": "ok", "slug": slug, "class": c["class"], "kind": c["kind"],
                             "name": c["name"], "mb": round(rec["fileBytes"] / 1e6, 1),
                             "license": rec["license"]["slug"], "conversion": rec["conversion"]}
            print(f"OK   {slug}  {rec['fileBytes'] / 1e6:.1f}MB  {rec['license']['slug']}  {time.time() - t0:.0f}s", flush=True)
        except sf.Refused as e:
            log[c["uid"]] = {"status": "refused", "slug": slug, "class": c["class"], "kind": c["kind"],
                             "name": c["name"], "reason": str(e)}
            print(f"SKIP {slug}: {e}", flush=True)
        except Exception as e:  # keep going; record the failure
            log[c["uid"]] = {"status": "error", "slug": slug, "class": c["class"], "kind": c["kind"],
                             "name": c["name"], "reason": f"{type(e).__name__}: {str(e)[:200]}"}
            print(f"ERR  {slug}: {type(e).__name__}: {str(e)[:200]}", flush=True)
        LOG.write_text(json.dumps(log, indent=1))
    n = {s: sum(1 for v in log.values() if v["status"] == s) for s in ("ok", "refused", "error")}
    print("DONE", n)


if __name__ == "__main__":
    main()
