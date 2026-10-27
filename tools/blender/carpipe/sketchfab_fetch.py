#!/usr/bin/env python3
"""Search and download freely-licensed cars from Sketchfab, then hand them to carpipe.

Search needs no account:
    python3 -I tools/blender/carpipe/sketchfab_fetch.py search "police car" --license by --max-faces 60000

Download needs a Sketchfab API token (free account -> https://sketchfab.com/settings/password -> "API Token"):
    export SKETCHFAB_API_TOKEN=xxxxxxxx        # or put it in ~/.config/hotwire/sketchfab_token (chmod 600)
    python3 -I tools/blender/carpipe/sketchfab_fetch.py get 61766c1e6e1e4b2b803c174f33433a74 --id fairheaven_cop
    python3 -I tools/blender/carpipe/build_car.py --model fairheaven_cop

`get` calls GET /v3/models/{uid} (licence, author) and GET /v3/models/{uid}/download (Authorization: Token ...),
which returns short-lived signed URLs for 'glb' and/or 'gltf' (zip).  The file is saved to
_cache/models/<id>/, SOURCE.json records licence + attribution, and an entry is added to models_local.json
(merged over models.json by build_car.py --model).  Only CC0 / CC-BY licences are accepted unless --any-license.
The token is never printed or written into outputs.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://api.sketchfab.com/v3"
UA = {"User-Agent": "HotwireCity-carpipe/1.0"}
OK_LICENSES = {"cc0", "by"}  # CC0 1.0, CC-BY 4.0 (also accept 'by-sa' only with --any-license)


def _get(url, token=None):
    h = dict(UA)
    if token:
        h["Authorization"] = f"Token {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=60) as r:
        return json.load(r)


def token():
    t = os.environ.get("SKETCHFAB_API_TOKEN")
    if not t:
        p = os.path.expanduser("~/.config/hotwire/sketchfab_token")
        if os.path.exists(p):
            t = open(p).read().strip()
    return t


def search(q, license="by", max_faces=80000, count=24, category="cars-vehicles"):
    params = {"type": "models", "q": q, "downloadable": "true", "count": count, "sort_by": "-likeCount",
              "max_face_count": max_faces}
    if license:
        params["license"] = license
    if category:
        params["categories"] = category
    d = _get(f"{API}/search?" + urllib.parse.urlencode(params))
    out = []
    for r in d.get("results", []):
        out.append({"uid": r["uid"], "name": r["name"], "faces": r.get("faceCount"),
                    "license": (r.get("license") or {}).get("label"), "author": r["user"]["username"],
                    "likes": r.get("likeCount"), "url": r.get("viewerUrl")})
    return out


def get_model(uid, mid, any_license=False):
    info = _get(f"{API}/models/{uid}")
    lic = info.get("license") or {}
    if lic.get("slug") not in OK_LICENSES and not any_license:
        sys.exit(f"refusing licence {lic.get('label')!r} (use --any-license to override)")
    tok = token()
    if not tok:
        sys.exit("no Sketchfab API token: set SKETCHFAB_API_TOKEN or ~/.config/hotwire/sketchfab_token")
    try:
        dl = _get(f"{API}/models/{uid}/download", tok)
    except urllib.error.HTTPError as e:
        sys.exit(f"download refused: HTTP {e.code} (token invalid, model not downloadable, or rate limited)")
    d = os.path.join(HERE, "_cache", "models", mid)
    os.makedirs(d, exist_ok=True)
    fmt = "glb" if "glb" in dl else "gltf"
    url = dl[fmt]["url"]
    dst = os.path.join(d, f"{mid}.glb" if fmt == "glb" else f"{mid}_gltf.zip")
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=300) as r, open(dst, "wb") as f:
        f.write(r.read())
    file_rel = os.path.basename(dst)
    if fmt == "gltf":
        src = os.path.join(d, "src")
        with zipfile.ZipFile(dst) as z:
            for m in z.namelist():
                if not os.path.realpath(os.path.join(src, m)).startswith(os.path.realpath(src)):
                    sys.exit(f"unsafe path in zip: {m}")
            z.extractall(src)
        for root, _ds, fs in os.walk(src):
            for fn in fs:
                if fn.endswith(".gltf"):
                    file_rel = os.path.relpath(os.path.join(root, fn), d)
    user = info.get("user", {})
    source = {"title": info.get("name"), "url": info.get("viewerUrl"), "download": f"sketchfab:{uid}",
              "license": lic.get("label") + (f" ({lic.get('url')})" if lic.get("url") else ""),
              "attribution": f"\"{info.get('name')}\" by {user.get('displayName') or user.get('username')} "
                             f"({user.get('profileUrl')}) on Sketchfab, licensed {lic.get('label')}"}
    with open(os.path.join(d, "SOURCE.json"), "w") as f:
        json.dump(source, f, indent=2)
    reg_p = os.path.join(HERE, "models_local.json")
    reg = json.load(open(reg_p)) if os.path.exists(reg_p) else {}
    reg[mid] = {"file": file_rel, "length": "auto", "source": source, "sketchfab_uid": uid}
    with open(reg_p, "w") as f:
        json.dump(reg, f, indent=2)
    print(f"saved {dst} ({fmt}); registered '{mid}' in models_local.json")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search")
    s.add_argument("query")
    s.add_argument("--license", default="by", help="by | cc0 | '' (any)")
    s.add_argument("--max-faces", type=int, default=80000)
    s.add_argument("--count", type=int, default=24)
    g = sub.add_parser("get")
    g.add_argument("uid")
    g.add_argument("--id", required=True, help="local model id")
    g.add_argument("--any-license", action="store_true")
    a = ap.parse_args()
    if a.cmd == "search":
        for r in search(a.query, a.license, a.max_faces, a.count):
            print(f"{r['uid']}  {r['faces'] or 0:7d} faces  {r['likes'] or 0:5d} likes  {r['license']:<22}  "
                  f"{r['name'][:50]}  by {r['author']}")
    else:
        get_model(a.uid, a.id, a.any_license)


if __name__ == "__main__":
    main()
