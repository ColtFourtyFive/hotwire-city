#!/usr/bin/env python3
"""Tiny Roblox Open Cloud helper. Reads the API key from $ROBLOX_API_KEY or ~/.config/hotwire/roblox_api_key.
Never prints the key. Usage examples:
  python3 tools/rbxcloud.py get <url>
  python3 tools/rbxcloud.py download <assetId> <outfile>        # asset-delivery-api
  python3 tools/rbxcloud.py upload-model <file.glb|fbx> <name> <userId>
  python3 tools/rbxcloud.py upload-image <file.png> <name> <userId>
  python3 tools/rbxcloud.py operation <operationPath>
"""
import json, os, sys, time, urllib.request, urllib.error, uuid, mimetypes

def key():
    k = os.environ.get("ROBLOX_API_KEY")
    if not k:
        k = open(os.path.expanduser("~/.config/hotwire/roblox_api_key")).read().strip()
    return k

def req(method, url, data=None, headers=None, raw=False):
    h = {"x-api-key": key()}
    if headers: h.update(headers)
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            body = resp.read()
            return resp.status, (body if raw else body.decode("utf-8", "replace")), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers)

def download(asset_id, out):
    st, body, _ = req("GET", f"https://apis.roblox.com/asset-delivery-api/v1/assetId/{asset_id}")
    if st != 200:
        return st, body
    loc = json.loads(body).get("location")
    if not loc:
        return st, body
    with urllib.request.urlopen(loc, timeout=120) as resp:
        data = resp.read()
    # may be gzip
    if data[:2] == b"\x1f\x8b":
        import gzip
        data = gzip.decompress(data)
    open(out, "wb").write(data)
    return 200, f"wrote {out} ({len(data)} bytes)"

def multipart(fields, files):
    boundary = uuid.uuid4().hex
    out = b""
    for name, value in fields.items():
        out += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
    for name, (filename, content, ctype) in files.items():
        out += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\nContent-Type: {ctype}\r\n\r\n".encode() + content + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return out, f"multipart/form-data; boundary={boundary}"

def upload(path, name, user_id, asset_type, ctype):
    request = {"assetType": asset_type, "displayName": name[:50], "description": "Hotwire City asset",
               "creationContext": {"creator": {"userId": str(user_id)}}}
    body, ct = multipart({"request": json.dumps(request)}, {"fileContent": (os.path.basename(path), open(path, "rb").read(), ctype)})
    return req("POST", "https://apis.roblox.com/assets/v1/assets", data=body, headers={"Content-Type": ct})

def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__); return
    if a[0] == "get":
        st, body, _ = req("GET", a[1]); print(st); print(body[:4000])
    elif a[0] == "download":
        print(*download(a[1], a[2]))
    elif a[0] == "upload-model":
        ext = os.path.splitext(a[1])[1].lower()
        ctype = {".fbx": "model/fbx", ".glb": "model/gltf-binary", ".gltf": "model/gltf+json", ".obj": "model/obj"}[ext]
        st, body, _ = upload(a[1], a[2], a[3], "Model", ctype); print(st); print(body[:2000])
    elif a[0] == "upload-image":
        st, body, _ = upload(a[1], a[2], a[3], "Decal", "image/png"); print(st); print(body[:2000])
    elif a[0] == "operation":
        st, body, _ = req("GET", f"https://apis.roblox.com/assets/v1/{a[1]}"); print(st); print(body[:2000])

if __name__ == "__main__":
    main()
