#!/usr/bin/env python3
"""Sketchfab sourcing helper for Hotwire City (CC0 / CC-BY only).

The API token is read from $SKETCHFAB_TOKEN or ~/.config/hotwire/sketchfab_token.
It is only ever sent as an Authorization header to api.sketchfab.com. It is never printed,
logged, written to meta.json or put in a URL. Signed download URLs are not stored either.

CLI (run with `python3 -I tools/sources/sketchfab.py ...`):
  search  <query> [--license cc0|by|both] [--max-faces N] [--min-faces N] [--count N] [--json]
  meta    <uid>
  download <uid> [--slug S] [--cls CLASS] [--kind vehicle|weapon|...] [--max-mb 60] [--force]

Library:
  search(q, license="both", max_faces=150000, ...) -> list[dict]
  model_meta(uid) -> dict              (normalized: license, author, url, face/vertex counts, archives)
  download(uid, slug=None, cls=None, kind=None) -> dict (meta.json contents) or raises Refused

Downloads land in assets/source/sketchfab/<slug>/ as model.glb + meta.json + thumb.jpg, and the
attribution line is appended to assets/ATTRIBUTION.md (deduplicated by uid). Anything whose license
is not exactly CC0 or CC-BY (e.g. NC, ND, SA, Standard/Editorial) is refused.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import io
import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

API = "https://api.sketchfab.com/v3"
ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = ROOT / "assets" / "source" / "sketchfab"
ATTRIBUTION = ROOT / "assets" / "ATTRIBUTION.md"
ALLOWED_LICENSES = {"cc0", "by"}
LICENSE_SEARCH = {"cc0": ["cc0"], "by": ["by"], "both": ["cc0", "by"]}
UA = "HotwireCity-sourcing/1.0"

_MIN_INTERVAL = 0.6  # seconds between API calls (polite)
_last_call = [0.0]


class Refused(Exception):
    """Raised when a model may not be downloaded (license, size, availability)."""


# --------------------------------------------------------------------------- token / http
def _token() -> str:
    t = os.environ.get("SKETCHFAB_TOKEN")
    if not t:
        p = Path(os.path.expanduser("~/.config/hotwire/sketchfab_token"))
        t = p.read_text().strip()
    if not t:
        raise RuntimeError("no Sketchfab token configured")
    return t


def _sleep_polite():
    dt = time.time() - _last_call[0]
    if dt < _MIN_INTERVAL:
        time.sleep(_MIN_INTERVAL - dt)
    _last_call[0] = time.time()


def api_get(path: str, params: dict | None = None, auth: bool = False, tries: int = 6) -> dict:
    """GET an API path (relative to /v3) or full api.sketchfab.com URL. Retries 429/5xx politely."""
    url = path if path.startswith("https://api.sketchfab.com/") else API + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    delay = 2.0
    for attempt in range(tries):
        _sleep_polite()
        headers = {"User-Agent": UA, "Accept": "application/json"}
        if auth:
            headers["Authorization"] = "Token " + _token()
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            code = e.code
            if code == 429 or 500 <= code < 600:
                ra = e.headers.get("Retry-After") if e.headers else None
                wait = float(ra) if ra and ra.replace(".", "", 1).isdigit() else delay
                wait = min(wait, 120.0)
                print(f"[sketchfab] HTTP {code} on {path.split('?')[0]}; waiting {wait:.0f}s "
                      f"(attempt {attempt + 1}/{tries})", file=sys.stderr)
                time.sleep(wait)
                delay = min(delay * 2, 120.0)
                continue
            body = ""
            try:
                body = e.read().decode("utf-8", "replace")[:300]
            except Exception:
                pass
            raise RuntimeError(f"Sketchfab HTTP {code} for {path.split('?')[0]}: {body}") from None
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            print(f"[sketchfab] network error {type(e).__name__}; retrying in {delay:.0f}s", file=sys.stderr)
            time.sleep(delay)
            delay = min(delay * 2, 120.0)
    raise RuntimeError(f"Sketchfab: giving up on {path.split('?')[0]}")


def _fetch_bytes(url: str, max_bytes: int | None = None, tries: int = 4) -> bytes:
    """Download a public/signed URL (no auth header). Never logs the URL (signed URLs carry credentials)."""
    delay = 3.0
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=180) as r:
                buf = io.BytesIO()
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    buf.write(chunk)
                    if max_bytes and buf.tell() > max_bytes:
                        raise Refused(f"download exceeds {max_bytes / 1e6:.0f} MB")
                return buf.getvalue()
        except Refused:
            raise
        except urllib.error.HTTPError as e:
            if e.code == 429 or 500 <= e.code < 600:
                time.sleep(delay)
                delay *= 2
                continue
            raise RuntimeError(f"file download failed: HTTP {e.code}") from None
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            print(f"[sketchfab] file download error {type(e).__name__}; retry {attempt + 1}", file=sys.stderr)
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("file download failed after retries")


# --------------------------------------------------------------------------- search / meta
def _thumb_url(thumbnails: dict | None, want: int = 640) -> str | None:
    imgs = (thumbnails or {}).get("images") or []
    if not imgs:
        return None
    imgs = sorted(imgs, key=lambda i: abs((i.get("width") or 0) - want))
    return imgs[0].get("url")


def _summ(r: dict, lic: str | None = None) -> dict:
    arch = r.get("archives") or {}
    glb = arch.get("glb") or {}
    gltf = arch.get("gltf") or {}
    lic_obj = r.get("license")
    if isinstance(lic_obj, dict):
        lic = lic_obj.get("slug") or lic
    elif isinstance(lic_obj, str) and lic_obj:
        lic = lic_obj.rstrip("/").split("/")[-1] if lic_obj.startswith("http") else lic_obj
    return {
        "uid": r["uid"],
        "name": r.get("name", ""),
        "author": (r.get("user") or {}).get("username"),
        "faces": r.get("faceCount"),
        "vertices": r.get("vertexCount"),
        "likes": r.get("likeCount"),
        "views": r.get("viewCount"),
        "license_hint": lic,
        "url": r.get("viewerUrl"),
        "thumb": _thumb_url(r.get("thumbnails")),
        "glb_size": glb.get("size"),
        "gltf_size": gltf.get("size"),
        "textures": glb.get("textureCount") or gltf.get("textureCount"),
        "tex_max_res": glb.get("textureMaxResolution") or gltf.get("textureMaxResolution"),
        "animated": bool(r.get("animationCount")),
        "tags": [t.get("slug") for t in (r.get("tags") or []) if isinstance(t, dict)],
        "categories": [c.get("slug") or c.get("name") for c in (r.get("categories") or []) if isinstance(c, dict)],
        "staffpicked": bool(r.get("staffpickedAt")),
    }


def search(q: str, license: str = "both", downloadable: bool = True, max_faces: int | None = 150000,
           min_faces: int | None = None, sort_by: str = "-likeCount", count: int = 24,
           categories: str | None = None, pages: int = 1, user: str | None = None) -> list[dict]:
    """Search downloadable models. license in {cc0, by, both}; user = author username filter.
    Results sorted by likes (desc). Search results carry only a license *hint*: always re-check
    with model_meta()/license_ok() (download() does this) before using a model."""
    if license not in LICENSE_SEARCH:
        raise ValueError("license must be cc0, by or both")
    out: dict[str, dict] = {}
    for lic in LICENSE_SEARCH[license]:
        params = {"type": "models", "q": q, "license": lic, "sort_by": sort_by, "count": min(count, 24)}
        if downloadable:
            params["downloadable"] = "true"
        if max_faces:
            params["max_face_count"] = int(max_faces)
        if min_faces:
            params["min_face_count"] = int(min_faces)
        if categories:
            params["categories"] = categories
        if user:
            params["user"] = user
        nxt = None
        for page in range(pages):
            d = api_get(nxt) if nxt else api_get("/search", params)
            for r in d.get("results", []):
                s = _summ(r, lic)
                if s["uid"] not in out:
                    out[s["uid"]] = s
            nxt = d.get("next")
            if not nxt:
                break
    res = list(out.values())
    if sort_by.lstrip("-") == "likeCount":
        res.sort(key=lambda s: -(s["likes"] or 0))
    return res


def model_meta(uid: str) -> dict:
    """Full normalized metadata for one model (public endpoint)."""
    m = api_get(f"/models/{uid}")
    lic = m.get("license") or {}
    user = m.get("user") or {}
    return {
        "uid": m["uid"],
        "name": m.get("name", ""),
        "license": {
            "slug": lic.get("slug"),
            "label": lic.get("label"),
            "fullName": lic.get("fullName"),
            "url": lic.get("url"),
            "requirements": lic.get("requirements"),
        },
        "author": {
            "username": user.get("username"),
            "displayName": user.get("displayName"),
            "profileUrl": user.get("profileUrl") or (f"https://sketchfab.com/{user.get('username')}" if user.get("username") else None),
        },
        "modelUrl": m.get("viewerUrl"),
        "faceCount": m.get("faceCount"),
        "vertexCount": m.get("vertexCount"),
        "materialCount": m.get("materialCount"),
        "textureCount": m.get("textureCount"),
        "animationCount": m.get("animationCount"),
        "isDownloadable": m.get("isDownloadable"),
        "price": m.get("price"),
        "publishedAt": m.get("publishedAt"),
        "likeCount": m.get("likeCount"),
        "viewCount": m.get("viewCount"),
        "tags": [t.get("slug") for t in (m.get("tags") or []) if isinstance(t, dict)],
        "categories": [c.get("slug") for c in (m.get("categories") or []) if isinstance(c, dict)],
        "description": (m.get("description") or "")[:600],
        "thumb": _thumb_url(m.get("thumbnails"), 1024),
    }


def license_ok(meta: dict) -> bool:
    return (meta.get("license") or {}).get("slug") in ALLOWED_LICENSES


# --------------------------------------------------------------------------- glTF -> GLB
def _pad4(b: bytes, fill: bytes = b"\x00") -> bytes:
    return b + fill * ((4 - len(b) % 4) % 4)


def gltf_dir_to_glb(gltf_path: Path) -> bytes:
    """Losslessly pack a .gltf + external buffers/images into a single GLB (pure Python)."""
    import base64

    base = gltf_path.parent
    js = json.loads(gltf_path.read_text(encoding="utf-8"))

    def load_uri(uri: str) -> bytes:
        if uri.startswith("data:"):
            return base64.b64decode(uri.split(",", 1)[1])
        p = (base / urllib.parse.unquote(uri)).resolve()
        if base.resolve() not in p.parents and p != base.resolve():
            raise Refused("glTF references a file outside its folder")
        return p.read_bytes()

    blob = bytearray()
    buf_offsets = []
    for b in js.get("buffers", []):
        data = load_uri(b["uri"]) if "uri" in b else b""
        while len(blob) % 8:
            blob.append(0)
        buf_offsets.append(len(blob))
        blob += data
    for bv in js.get("bufferViews", []):
        bv["byteOffset"] = bv.get("byteOffset", 0) + buf_offsets[bv["buffer"]]
        bv["buffer"] = 0
    js.setdefault("bufferViews", [])
    for img in js.get("images", []):
        uri = img.get("uri")
        if not uri:
            continue
        data = load_uri(uri)
        mime = img.get("mimeType")
        if not mime:
            low = uri.lower()
            mime = "image/png" if low.endswith(".png") else "image/jpeg" if low.endswith((".jpg", ".jpeg")) else \
                "image/webp" if low.endswith(".webp") else "image/ktx2" if low.endswith(".ktx2") else "image/png"
        while len(blob) % 8:
            blob.append(0)
        js["bufferViews"].append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)})
        blob += data
        img.pop("uri", None)
        img["bufferView"] = len(js["bufferViews"]) - 1
        img["mimeType"] = mime
    js["buffers"] = [{"byteLength": len(blob)}] if blob else []
    jbytes = _pad4(json.dumps(js, separators=(",", ":")).encode("utf-8"), b" ")
    bbytes = _pad4(bytes(blob))
    total = 12 + 8 + len(jbytes) + (8 + len(bbytes) if bbytes else 0)
    out = io.BytesIO()
    out.write(struct.pack("<III", 0x46546C67, 2, total))
    out.write(struct.pack("<II", len(jbytes), 0x4E4F534A))
    out.write(jbytes)
    if bbytes:
        out.write(struct.pack("<II", len(bbytes), 0x004E4942))
        out.write(bbytes)
    return out.getvalue()


def _blender_convert(gltf_path: Path, glb_out: Path) -> bool:
    """Fallback conversion via Blender-as-module."""
    script = (
        "import bpy,sys\n"
        "bpy.ops.wm.read_factory_settings(use_empty=True)\n"
        "bpy.ops.import_scene.gltf(filepath=sys.argv[1])\n"
        "bpy.ops.export_scene.gltf(filepath=sys.argv[2], export_format='GLB')\n"
    )
    r = subprocess.run([sys.executable, "-I", "-c", script, str(gltf_path), str(glb_out)],
                       capture_output=True, text=True, timeout=900)
    return r.returncode == 0 and glb_out.exists()


def gltf_zip_to_glb(zip_bytes: bytes, workdir: Path, glb_out: Path) -> str:
    workdir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        for info in z.infolist():
            name = info.filename
            if name.startswith("/") or ".." in Path(name).parts:
                raise Refused("unsafe path in archive")
        z.extractall(workdir)
    gltfs = sorted(workdir.rglob("*.gltf"), key=lambda p: len(p.parts))
    if not gltfs:
        raise Refused("gltf archive has no .gltf file")
    try:
        glb_out.write_bytes(gltf_dir_to_glb(gltfs[0]))
        return "packed"
    except Refused:
        raise
    except Exception as e:  # pragma: no cover - fallback path
        print(f"[sketchfab] pure-python pack failed ({e}); trying Blender", file=sys.stderr)
        if _blender_convert(gltfs[0], glb_out):
            return "blender"
        try:
            import trimesh  # type: ignore
            sc = trimesh.load(str(gltfs[0]), force="scene")
            glb_out.write_bytes(sc.export(file_type="glb"))
            return "trimesh"
        except Exception as e2:
            raise RuntimeError(f"gltf->glb conversion failed: {e2}") from None


# --------------------------------------------------------------------------- download
def slugify(s: str, n: int = 40) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return (s[:n].rstrip("-")) or "model"


def default_slug(meta: dict) -> str:
    return f"{slugify(meta['name'])}-{meta['uid'][:6]}"


def append_attribution(meta: dict, rel_path: str) -> bool:
    """Append one attribution line for this model (dedup by uid). Returns True if appended."""
    ATTRIBUTION.parent.mkdir(parents=True, exist_ok=True)
    if not ATTRIBUTION.exists():
        ATTRIBUTION.write_text(
            "# Third-party asset attribution\n\n"
            "Every third-party model downloaded for Hotwire City is listed here (sourcing candidates "
            "included). Every model that ships must also appear in the in-game Credits screen; see "
            "docs/v2/sourcing/PICKS.md for which candidates are picked. Only CC0 and CC-BY (4.0) assets are "
            "allowed; CC-BY requires crediting the author as below. Real brand logos/badges are stripped "
            "before use.\n\n"
            "## Sketchfab\n\n"
            "| Model | Author | License | Source | Local | uid |\n"
            "|---|---|---|---|---|---|\n",
            encoding="utf-8")
    text = ATTRIBUTION.read_text(encoding="utf-8")
    if meta["uid"] in text:
        return False
    lic = meta["license"]
    name = meta["name"].replace("|", "/").strip()
    author = meta["author"]
    line = (f"| {name} | [{author.get('displayName') or author['username']}]({author['profileUrl']}) | "
            f"[{lic['label']}]({lic['url']}) | [sketchfab]({meta['modelUrl']}) | `{rel_path}` | {meta['uid']} |\n")
    with ATTRIBUTION.open("a", encoding="utf-8") as f:
        f.write(line)
    return True


def download(uid: str, slug: str | None = None, cls: str | None = None, kind: str | None = None,
             max_mb: float = 60.0, force: bool = False, notes: str | None = None) -> dict:
    """Download a CC0/CC-BY model as GLB with meta.json, thumbnail and attribution."""
    meta = model_meta(uid)
    if not license_ok(meta):
        raise Refused(f"license '{meta['license'].get('slug')}' ({meta['license'].get('label')}) is not CC0/CC-BY")
    if meta.get("isDownloadable") is False:
        raise Refused("model is not downloadable")
    if meta.get("price"):
        raise Refused("model is a paid Store model")
    slug = slug or default_slug(meta)
    out_dir = SRC_DIR / slug
    glb_path = out_dir / "model.glb"
    meta_path = out_dir / "meta.json"
    if glb_path.exists() and meta_path.exists() and not force:
        return json.loads(meta_path.read_text())

    links = api_get(f"/models/{uid}/download", auth=True)
    max_bytes = int(max_mb * 1e6)
    archive_used = None
    conversion = None
    data = None
    for fmt in ("glb", "gltf"):
        info = links.get(fmt) or {}
        if not info.get("url"):
            continue
        size = info.get("size") or 0
        if size and size > max_bytes:
            print(f"[sketchfab] {fmt} archive is {size / 1e6:.1f} MB (> {max_mb:.0f} MB); skipping", file=sys.stderr)
            continue
        data = _fetch_bytes(info["url"], max_bytes=max_bytes)
        archive_used = fmt
        break
    if data is None:
        raise Refused(f"no glb/gltf archive within {max_mb:.0f} MB")

    out_dir.mkdir(parents=True, exist_ok=True)
    if archive_used == "glb":
        if data[:4] != b"glTF":
            raise RuntimeError("glb archive is not a GLB file")
        glb_path.write_bytes(data)
        conversion = "none"
    else:
        work = out_dir / "_gltf"
        conversion = gltf_zip_to_glb(data, work, glb_path)

    thumb_rel = None
    if meta.get("thumb"):
        try:
            (out_dir / "thumb.jpg").write_bytes(_fetch_bytes(meta["thumb"], max_bytes=5_000_000))
            thumb_rel = "thumb.jpg"
        except Exception as e:
            print(f"[sketchfab] thumbnail failed: {e}", file=sys.stderr)

    rel = str(glb_path.relative_to(ROOT))
    glb_bytes = glb_path.read_bytes()
    record = {
        "source": "sketchfab",
        "uid": uid,
        "slug": slug,
        "name": meta["name"],
        "class": cls,
        "kind": kind,
        "license": meta["license"],
        "author": meta["author"],
        "modelUrl": meta["modelUrl"],
        "faceCount": meta["faceCount"],
        "vertexCount": meta["vertexCount"],
        "materialCount": meta["materialCount"],
        "textureCount": meta["textureCount"],
        "animationCount": meta["animationCount"],
        "likeCount": meta["likeCount"],
        "tags": meta["tags"],
        "categories": meta["categories"],
        "description": meta["description"],
        "archive": archive_used,
        "conversion": conversion,
        "file": rel,
        "fileBytes": len(glb_bytes),
        "sha256": hashlib.sha256(glb_bytes).hexdigest(),
        "thumb": thumb_rel,
        "downloadedAt": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "notes": notes,
    }
    meta_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    append_attribution(meta, rel)
    return record


# --------------------------------------------------------------------------- CLI
def _main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search")
    s.add_argument("q")
    s.add_argument("--license", default="both", choices=["cc0", "by", "both"])
    s.add_argument("--max-faces", type=int, default=150000)
    s.add_argument("--min-faces", type=int, default=None)
    s.add_argument("--count", type=int, default=24)
    s.add_argument("--pages", type=int, default=1)
    s.add_argument("--categories", default=None)
    s.add_argument("--user", default=None)
    s.add_argument("--json", action="store_true")
    m = sub.add_parser("meta")
    m.add_argument("uid")
    d = sub.add_parser("download")
    d.add_argument("uid")
    d.add_argument("--slug")
    d.add_argument("--cls")
    d.add_argument("--kind")
    d.add_argument("--max-mb", type=float, default=60.0)
    d.add_argument("--force", action="store_true")
    a = ap.parse_args(argv)

    if a.cmd == "search":
        res = search(a.q, a.license, max_faces=a.max_faces, min_faces=a.min_faces, count=a.count,
                     pages=a.pages, categories=a.categories, user=a.user)
        if a.json:
            print(json.dumps(res, indent=1))
        else:
            for r in res:
                print(f"{r['uid']}  {r['faces'] or 0:>7}f  {r['likes'] or 0:>5}♥  {r['license_hint']:<4} "
                      f"{(r['glb_size'] or 0) / 1e6:6.1f}MB  {r['name'][:60]}  @{r['author']}")
    elif a.cmd == "meta":
        print(json.dumps(model_meta(a.uid), indent=1))
    elif a.cmd == "download":
        try:
            rec = download(a.uid, slug=a.slug, cls=a.cls, kind=a.kind, max_mb=a.max_mb, force=a.force)
        except Refused as e:
            print(f"REFUSED {a.uid}: {e}")
            return 2
        print(f"OK {rec['slug']}  {rec['faceCount']}f  {rec['license']['slug']}  {rec['fileBytes'] / 1e6:.1f}MB  -> {rec['file']}")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
