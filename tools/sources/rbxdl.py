#!/usr/bin/env python3
"""Download Roblox assets through Open Cloud asset delivery and cache them locally.

    python3 -I tools/sources/rbxdl.py <assetId|content-url> [...] [--force] [--version N] [-j 8]

Each asset lands in assets/source/roblox/<id>/:
    asset.<ext>   the decompressed payload (rbxm / rbxmx / mesh / png / jpg / ...)
    meta.json     {id, kind, ext, bytes, sha256, assetTypeId, mesh_version, fetched_at, ...}

Kinds detected from magic bytes: rbxm, rbxmx, mesh (Roblox FileMesh, any version), png, jpg,
webp, gif, bmp, tga, dds, ktx, ogg, mp3, unknown.

Used as a library by rbxmesh.py / rbx_to_blender.py:
    from rbxdl import fetch, parse_asset_id, asset_dir

Security: the API key comes from tools/rbxcloud.py key() and only ever travels in the
x-api-key header. It is never printed or written to disk. The signed CDN `location` URL is
not stored either (meta.json keeps only the request id).
"""
import concurrent.futures as cf
import gzip
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CACHE = os.path.join(ROOT, "assets", "source", "roblox")
sys.path.insert(0, os.path.join(ROOT, "tools"))

import rbxcloud  # noqa: E402  (key() only; never print it)

API = "https://apis.roblox.com/asset-delivery-api/v1/assetId/{id}"
API_VER = "https://apis.roblox.com/asset-delivery-api/v1/assetId/{id}/version/{ver}"
MAX_BYTES = 60 * 1024 * 1024

ASSET_TYPES = {1: "Image", 2: "TShirt", 3: "Audio", 4: "Mesh", 8: "Hat", 10: "Model", 11: "Shirt",
               12: "Pants", 13: "Decal", 24: "Animation", 38: "Plugin", 39: "SolidModel",
               40: "MeshPart", 61: "EmoteAnimation", 62: "Video", 63: "TexturePack"}

_ID_PATTERNS = [
    re.compile(r"^\s*(\d+)\s*$"),
    re.compile(r"rbxassetid://(\d+)", re.I),
    re.compile(r"[?&]id=(\d+)", re.I),
    re.compile(r"/asset/(\d+)", re.I),
    re.compile(r"/library/(\d+)", re.I),
    re.compile(r"/catalog/(\d+)", re.I),
]


def parse_asset_id(content):
    """'rbxassetid://123' / 'http://www.roblox.com/asset/?id=123' / '123' / 123 -> 123 (int) or None.
    Built-in content (rbxasset://, rbxthumb://, rbxhttp://) returns None."""
    if content is None:
        return None
    if isinstance(content, int):
        return content if content > 0 else None
    s = str(content).strip()
    if not s or s.lower().startswith(("rbxasset://", "rbxthumb://", "rbxhttp://")):
        return None
    for p in _ID_PATTERNS:
        m = p.search(s)
        if m:
            v = int(m.group(1))
            return v if v > 0 else None
    return None


def asset_dir(asset_id):
    return os.path.join(CACHE, str(int(asset_id)))


def detect(data):
    """Return (kind, ext, extra) for a decompressed payload."""
    head = data[:64]
    if head.startswith(b"<roblox!"):
        return "rbxm", "rbxm", {}
    if head.lstrip().startswith(b"<roblox") or head.lstrip().startswith(b"<?xml"):
        return "rbxmx", "rbxmx", {}
    if head.startswith(b"version "):
        ver = head[8:12].decode("ascii", "replace")
        return "mesh", "mesh", {"mesh_version": ver}
    if head.startswith(b"\x89PNG"):
        return "png", "png", {}
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg", "jpg", {}
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp", "webp", {}
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "gif", "gif", {}
    if head.startswith(b"BM"):
        return "bmp", "bmp", {}
    if head.startswith(b"DDS "):
        return "dds", "dds", {}
    if head.startswith(b"\xabKTX"):
        return "ktx", "ktx", {}
    if head.startswith(b"OggS"):
        return "ogg", "ogg", {}
    if head.startswith(b"ID3") or head[:2] in (b"\xff\xfb", b"\xff\xf3"):
        return "mp3", "mp3", {}
    if head.startswith(b"CSGMDL") or head.startswith(b"CSGPHS"):
        return "csg", "csg", {}
    # TGA has no magic; Roblox occasionally serves it for old decals
    if len(data) > 18 and data[2] in (2, 10) and data[1] == 0 and data[16] in (24, 32):
        return "tga", "tga", {}
    return "unknown", "bin", {}


def _decompress(data):
    for _ in range(3):  # payloads are sometimes double-wrapped
        if data[:2] == b"\x1f\x8b":
            data = gzip.decompress(data)
        elif data[:4] == b"\x28\xb5\x2f\xfd":
            try:
                import zstandard  # optional
                data = zstandard.ZstdDecompressor().decompress(data, max_output_size=MAX_BYTES * 4)
            except ImportError:
                raise RuntimeError("zstd payload but python 'zstandard' module missing")
        elif data[:2] in (b"\x78\x9c", b"\x78\x01", b"\x78\xda"):
            try:
                data = zlib.decompress(data)
            except zlib.error:
                break
        else:
            break
    return data


def _api_get(url, tries=6):
    delay = 1.5
    for i in range(tries):
        st, body, hdr = rbxcloud.req("GET", url)
        if st == 429 or st >= 500:
            ra = hdr.get("Retry-After") or hdr.get("retry-after")
            time.sleep(float(ra) if ra and ra.replace(".", "").isdigit() else delay)
            delay = min(delay * 2, 30)
            continue
        return st, body
    return st, body


def _cdn_get(url, tries=4):
    delay = 1.0
    last = None
    for i in range(tries):
        try:
            r = urllib.request.Request(url, headers={"User-Agent": "HotwireCity-rbxdl/1.0", "Accept-Encoding": "gzip"})
            with urllib.request.urlopen(r, timeout=120) as resp:
                cl = resp.headers.get("Content-Length")
                if cl and int(cl) > MAX_BYTES:
                    raise RuntimeError(f"payload too large ({int(cl) / 1e6:.1f} MB)")
                return resp.read(MAX_BYTES + 1)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = e
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"CDN download failed: {type(last).__name__}")


def cached(asset_id):
    d = asset_dir(asset_id)
    mp = os.path.join(d, "meta.json")
    if os.path.exists(mp):
        try:
            meta = json.load(open(mp))
        except Exception:
            return None
        if meta.get("ok") and os.path.exists(os.path.join(d, meta.get("file", ""))):
            return meta
        if not meta.get("ok") and meta.get("status") in (403, 404, 409):
            return meta  # remember permanent failures
    return None


def fetch(asset_id, force=False, version=None, quiet=True):
    """Download (or reuse cache) asset_id. Returns meta dict; meta['ok'] tells success and
    meta['path'] is the absolute payload path."""
    aid = parse_asset_id(asset_id)
    if aid is None:
        return {"ok": False, "error": f"not a downloadable asset id: {asset_id!r}"}
    d = asset_dir(aid)
    if not force and version is None:
        m = cached(aid)
        if m is not None:
            if m.get("ok"):
                m["path"] = os.path.join(d, m["file"])
            return m
    os.makedirs(d, exist_ok=True)
    url = API_VER.format(id=aid, ver=version) if version else API.format(id=aid)
    meta_name = f"meta_v{version}.json" if version else "meta.json"  # pinned versions never replace the cache entry
    meta = {"id": aid, "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        st, body = _api_get(url)
        meta["status"] = st
        if st != 200:
            meta.update(ok=False, error=(body or "")[:300])
            json.dump(meta, open(os.path.join(d, meta_name), "w"), indent=1)
            return meta
        j = json.loads(body)
        meta["assetTypeId"] = j.get("assetTypeId")
        meta["assetType"] = ASSET_TYPES.get(j.get("assetTypeId"), str(j.get("assetTypeId")))
        meta["requestId"] = j.get("requestId")
        for k in ("isArchived", "isRecordable", "IsCopyrightProtected", "isCopyrightProtected"):
            if k in j:
                meta[k] = j[k]
        loc = j.get("location")
        if not loc:
            errs = j.get("errors") or []
            if errs and isinstance(errs, list) and isinstance(errs[0], dict):
                # e.g. 403 "Asset is not approved for the requester" = moderated / pending asset
                meta["status"] = errs[0].get("code", st)
                meta.update(ok=False, error=f"{errs[0].get('code')}: {errs[0].get('message', '')}"[:300])
            else:
                meta.update(ok=False, error="no location in response: " + ",".join(sorted(j.keys())))
            json.dump(meta, open(os.path.join(d, meta_name), "w"), indent=1)
            return meta
        raw = _cdn_get(loc)
        if len(raw) > MAX_BYTES:
            raise RuntimeError("payload exceeds 60 MB cap")
        data = _decompress(raw)
        kind, ext, extra = detect(data)
        meta.update(extra)
        fname = f"asset.{ext}" if not version else f"asset_v{version}.{ext}"
        with open(os.path.join(d, fname), "wb") as f:
            f.write(data)
        meta.update(ok=True, kind=kind, ext=ext, file=fname, bytes=len(data),
                    sha256=hashlib.sha256(data).hexdigest())
    except Exception as e:  # noqa: BLE001
        meta.update(ok=False, error=f"{type(e).__name__}: {str(e)[:200]}")
    json.dump(meta, open(os.path.join(d, meta_name), "w"), indent=1)
    if meta.get("ok"):
        meta["path"] = os.path.join(d, meta["file"])
    if not quiet:
        print(_line(meta))
    return meta


def fetch_many(ids, force=False, jobs=8, quiet=True):
    ids = [i for i in dict.fromkeys(parse_asset_id(x) for x in ids) if i]
    out = {}
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(fetch, i, force): i for i in ids}
        for f in cf.as_completed(futs):
            m = f.result()
            out[futs[f]] = m
            if not quiet:
                print(_line(m), flush=True)
    return out


def _line(m):
    if m.get("ok"):
        extra = f" mesh v{m['mesh_version']}" if m.get("mesh_version") else ""
        return f"OK   {m['id']:>16}  {m.get('assetType', '?'):<10} {m['kind']:<6} {m['bytes']:>10,d} B{extra}"
    return f"FAIL {m.get('id', '?'):>16}  status={m.get('status')} {m.get('error', '')[:120]}"


def main(argv):
    force = "--force" in argv
    version = None
    jobs = 8
    ids = []
    it = iter(argv)
    for a in it:
        if a == "--force":
            continue
        if a == "--version":
            version = int(next(it))
            continue
        if a == "-j":
            jobs = int(next(it))
            continue
        ids.append(a)
    if not ids:
        print(__doc__)
        return 1
    if version is not None:
        for i in ids:
            print(_line(fetch(i, force=True, version=version)))
    else:
        fetch_many(ids, force=force, jobs=jobs, quiet=False)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
