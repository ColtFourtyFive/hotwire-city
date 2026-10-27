#!/usr/bin/env python3
"""Writes the GENERATED block of src/shared/Config/Buildings.luau from assets/buildings/catalog.json (produce.py) and
assets/buildings/manifest.json (upload.py: Model / Image asset ids). Surfaces come from rbxmat.surface.

    python3 -I tools/blender/buildkit/gen_config.py            # rewrite the block
    python3 -I tools/blender/buildkit/gen_config.py --check    # exit 1 if the file would change
"""
import argparse, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rbxmat  # noqa: E402

ROOT = rbxmat.ROOT
CONFIG = os.path.join(ROOT, "src", "shared", "Config", "Buildings.luau")
CATALOG = os.path.join(ROOT, "assets", "buildings", "catalog.json")
MANIFEST = os.path.join(ROOT, "assets", "buildings", "manifest.json")
BEGIN = "-- BEGIN GENERATED (tools/blender/buildkit/gen_config.py) - do not edit by hand"
END = "-- END GENERATED"
IMAGE_KEYS = ["windows_day", "signs", "brands", "awnings", "fb_punched", "fb_curtain", "fb_ribbon"]


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def rgb(c):
    return "{ %d, %d, %d }" % tuple(int(x) for x in c)


def num(x):
    x = round(float(x), 2)
    return str(int(x)) if x == int(x) else repr(x)


def part_entry(key, pname, p, arch):
    s = rbxmat.surface(p["role"], p["material"], arch)
    if s is None:
        return None
    suffix = pname[len(key) + 1:]
    f = [f"name = {lua_str(suffix)}", f"role = {lua_str(p['role'])}", f"mat = {lua_str(s['material'])}"]
    if s["variant"]:
        f.append(f"var = {lua_str(s['variant'])}")
    f.append(f"rgb = {rgb(s['color'])}")
    if s["texture"]:
        f.append(f"tex = {lua_str(s['texture'])}")
    if s["transparency"]:
        f.append(f"alpha = {num(s['transparency'])}")
    if s["reflectance"]:
        f.append(f"refl = {num(s['reflectance'])}")
    if s["night"]:
        n = s["night"]
        f.append("night = { mat = %s%s }" % (lua_str(n["material"]), (", rgb = " + rgb(n["color"])) if n.get("color") else ""))
    f.append(f"tris = {p['tris']}")
    return "{ " + ", ".join(f) + " }"


def generate():
    cat = json.load(open(CATALOG))["variants"]
    man = json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {"models": {}, "images": {}}
    out = [BEGIN, "-" * 117, "", "-- Shared Images (assetType Image) for MeshPart.TextureID / Texture.Texture.", "Buildings.Images = {"]
    for k in IMAGE_KEYS:
        aid = man.get("images", {}).get(k, {}).get("assetId")
        out.append(f"\t{k} = {lua_str('rbxassetid://%d' % aid if aid else '')},")
    out.append("} :: { [string]: string }")
    out.append("")
    out.append("-- %d templates: tools/blender/buildkit/variants.py -> produce.py -> upload.py." % len(cat))
    out.append("Buildings.Templates = {")
    for key in sorted(cat):
        v = cat[key]
        aid = man.get("models", {}).get(key, {}).get("assetId") or 0
        W, D = v["footprint"]
        b = v["body"]
        tags = v.get("tags", {})
        out.append(f"\t{key} = {{")
        out.append(f"\t\tkey = {lua_str(key)},")
        out.append(f"\t\tfamily = {lua_str(v['family'])},")
        out.append(f"\t\tarch = {lua_str(v['arch'])},")
        out.append(f"\t\tassetId = {aid},")
        out.append(f"\t\tsize = {{ {num(W)}, {num(v['height'])}, {num(D)} }},")
        out.append("\t\tbody = { %s },", )
        out[-1] = "\t\tbody = { %s }," % ", ".join(num(x) for x in (b["min"] + b["max"]))
        out.append(f"\t\tbaseDepth = {num(v.get('base_depth', 0))},")
        if isinstance(tags.get("floors"), (int, float)):
            out.append(f"\t\tfloors = {int(tags['floors'])},")
        if v["arch"] == "tower" and tags.get("crown"):
            out.append(f"\t\tcrown = {lua_str(tags['crown'])},")
        if v.get("kw", {}).get("planned"):
            out.append("\t\tplanned = true,")
        out.append(f"\t\ttris = {v['total_tris']},")
        out.append("\t\tparts = {")
        for pname in sorted(v["parts"]):
            e = part_entry(key, pname, v["parts"][pname], v["arch"])
            if e:
                out.append(f"\t\t\t{e},")
        out.append("\t\t},")
        out.append("\t},")
    out.append("} :: { [string]: Template }")
    out.append("")
    out.append("-" * 117)
    out.append(END)
    return "\n".join(out)


def stylua(text):
    import subprocess
    r = subprocess.run(["stylua", "--stdin-filepath", CONFIG, "-"], input=text, capture_output=True, text=True,
                       cwd=ROOT)
    if r.returncode != 0:
        raise SystemExit("stylua failed: " + r.stderr)
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    src = open(CONFIG).read()
    i = src.index(BEGIN)
    j = src.index(END) + len(END)
    new = stylua(src[:i] + generate() + src[j:])
    if a.check:
        if new != src:
            print("Config/Buildings.luau is out of date (run gen_config.py)")
            sys.exit(1)
        print("OK")
        return
    open(CONFIG, "w").write(new)
    n = len(json.load(open(CATALOG))["variants"])
    print("wrote", CONFIG, n, "templates")


if __name__ == "__main__":
    main()
