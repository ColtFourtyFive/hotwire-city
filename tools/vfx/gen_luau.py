#!/usr/bin/env python3
"""Write the uploaded VFX texture ids (assets/vfx/manifest.json) into src/shared/Config/VFX.luau between the
BEGIN/END GENERATED TEXTURES markers. Keys without an id are left out (VFXLibrary falls back to VFX.Fallback).

Usage: python3 tools/vfx/gen_luau.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MANIFEST = os.path.join(ROOT, "assets", "vfx", "manifest.json")
TARGET = os.path.join(ROOT, "src", "shared", "Config", "VFX.luau")
BEGIN = "-- BEGIN GENERATED TEXTURES"
END = "-- END GENERATED TEXTURES"


def main():
    man = json.load(open(MANIFEST))
    lines = [BEGIN + " (tools/vfx/gen_luau.py from assets/vfx/manifest.json; do not edit by hand)", "VFX.Textures = {"]
    for k in sorted(man):
        e = man[k]
        if e.get("assetId") and e.get("assetType", "Image") == "Image":
            lines.append(f'\t{k} = "rbxassetid://{e["assetId"]}",')
    lines.append("} :: { [string]: string }")
    lines.append(END)
    src = open(TARGET).read()
    a = src.index(BEGIN)
    b = src.index(END) + len(END)
    out = src[:a] + "\n".join(lines) + src[b:]
    open(TARGET, "w").write(out)
    print(f"wrote {len(lines) - 4} texture ids into {os.path.relpath(TARGET, ROOT)}")


if __name__ == "__main__":
    main()
    sys.exit(0)
