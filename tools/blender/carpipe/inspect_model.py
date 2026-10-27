#!/usr/bin/env python3
"""Print what a car model file contains (objects, materials, tris, bbox) after carpipe's import+flatten.

    python3 -I tools/blender/carpipe/inspect_model.py path/to/car.glb
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import numpy as np  # noqa: E402

from carpipe import importer, util  # noqa: E402


def main(path):
    util.reset_scene()
    importer.import_any(path)
    objs = importer.flatten()
    importer.discover_textures(os.path.dirname(path))
    allv = np.concatenate([util.verts_np(o.data) for o in objs])
    print("BBOX min", util.fmt3(allv.min(0)), "max", util.fmt3(allv.max(0)), "size", util.fmt3(allv.ptp(0) if hasattr(allv, 'ptp') else allv.max(0) - allv.min(0)))
    tot = 0
    for o in sorted(objs, key=lambda o: -util.tri_count(o)):
        t = util.tri_count(o)
        tot += t
        v = util.verts_np(o.data)
        c = (v.min(0) + v.max(0)) / 2
        mats = [s.material.name if s.material else "-" for s in o.material_slots]
        print(f"{t:7d} tris  {o.name[:40]:40s} c={util.fmt3(c, 2)} size={util.fmt3(v.max(0) - v.min(0), 2)} mats={mats[:6]} path={o.get('cp_path', '')[:60]}")
    print("TOTAL tris", tot)
    for m in bpy.data.materials:
        b = importer._principled(m)
        if b is None:
            print("MAT", m.name, "(no principled)")
            continue
        def val(n):
            i = b.inputs.get(n)
            if i is None:
                return None
            if i.is_linked:
                return "tex:" + i.links[0].from_node.bl_idname
            d = i.default_value
            try:
                return [round(x, 2) for x in d]
            except TypeError:
                return round(d, 2)
        print("MAT", m.name, "base", val("Base Color"), "met", val("Metallic"), "rough", val("Roughness"),
              "trans", val("Transmission Weight"), "alpha", val("Alpha"), "emis", val("Emission Color"), val("Emission Strength"))


if __name__ == "__main__":
    main(sys.argv[1])
