#!/usr/bin/env python3
"""End-to-end driver for the Roblox Creator Store car study.

    python3 -I tools/sources/rbx_cars.py run <id> [...]      # download, inspect, meshes, render, map
    python3 -I tools/sources/rbx_cars.py map <id> [...]      # re-run the mapping analysis only
    python3 -I tools/sources/rbx_cars.py texsheet <id> [...] # contact sheet of every texture a car uses
    python3 -I tools/sources/rbx_cars.py sheet [<id> ...]    # docs/v2/sourcing/roblox_cars_sheet.png

Steps per id (each is cached, re-runs are cheap):
  rbxdl.py <id>  ->  lune run rbxm_inspect.luau  ->  rbxmesh.py model <id>  ->
  rbx_to_blender.py <id> (separate process: Blender-as-module)  ->  rbx_car_map.py <id>
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rbxdl  # noqa: E402

SHORTLIST = [89890547548224, 11881862706, 14746413121, 117276253886376, 73893179863762, 126180570128588,
             113053967699143, 103123587729335, 131180706902259, 97965573521866, 132078381973405]
EXTRAS = [951086064, 3204824887, 16390639371, 10141791793, 71284840505836, 94301391128632]
SHEET = os.path.join(rbxdl.ROOT, "docs", "v2", "sourcing", "roblox_cars_sheet.png")


def run(mid, render=True):
    meta = rbxdl.fetch(mid)
    if not meta.get("ok") or meta.get("kind") not in ("rbxm", "rbxmx"):
        print(f"{mid}: not a model ({meta.get('kind')} {meta.get('error', '')})")
        return False
    d = rbxdl.asset_dir(mid)
    tree = os.path.join(d, "tree.json")
    r = subprocess.run(["lune", "run", os.path.join(HERE, "rbxm_inspect.luau"), meta["path"], tree],
                       capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr.strip()[-300:])
    if r.returncode != 0:
        return False
    import rbxmesh
    rbxmesh.process_model(mid)
    if render:
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "rbx_to_blender.py"), str(mid)],
                           capture_output=True, text=True)
        print((r.stdout.strip().splitlines() or ["(no output)"])[-1][:300])
    import rbx_car_map
    print(rbx_car_map.summary_line(rbx_car_map.analyze(mid)))
    return True


def texsheet(mid, thumb=160):
    from PIL import Image, ImageDraw
    d = rbxdl.asset_dir(mid)
    deps = json.load(open(os.path.join(d, "deps.json")))
    items = [(k, v) for k, v in deps["image"].items() if v.get("ok")]
    if not items:
        return None
    cols = 8
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * thumb, rows * (thumb + 28)), (40, 40, 44))
    dr = ImageDraw.Draw(sheet)
    for i, (k, v) in enumerate(items):
        im = Image.open(os.path.join(rbxdl.ROOT, v["png"])).convert("RGBA")
        im.thumbnail((thumb - 8, thumb - 8))
        bg = Image.new("RGBA", im.size, (128, 128, 128, 255))
        # checker so alpha is visible
        for y in range(0, im.size[1], 8):
            for x in range(0, im.size[0], 8):
                if (x // 8 + y // 8) % 2:
                    bg.paste((160, 160, 160, 255), (x, y, x + 8, y + 8))
        bg.alpha_composite(im)
        x, y = (i % cols) * thumb, (i // cols) * (thumb + 28)
        sheet.paste(bg.convert("RGB"), (x + 4, y + 4))
        use = (v.get("uses") or [""])[0].split("/")[-1][:22]
        dr.text((x + 4, y + thumb - 2), f"{k}", fill=(230, 230, 230))
        dr.text((x + 4, y + thumb + 10), use, fill=(170, 170, 170))
    out = os.path.join(d, "textures_sheet.png")
    sheet.save(out)
    return out


def sheet(ids, cell=(480, 270)):
    from PIL import Image, ImageDraw, ImageFont
    import rbx_car_map
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 17)
        small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 13)
    except OSError:
        font = small = ImageFont.load_default()
    cw, ch = cell
    label_h = 44
    per_row = 2  # cars per row, two views each
    rows = (len(ids) + per_row - 1) // per_row
    W = per_row * 2 * cw + (per_row - 1) * 12
    H = rows * (ch + label_h) + 56
    img = Image.new("RGB", (W, H), (22, 23, 26))
    dr = ImageDraw.Draw(img)
    dr.text((12, 14), "Roblox Creator Store car shortlist - offline rebuild (Blender, Cycles) from asset delivery "
            "downloads. Left: 3/4 front, right: side (ortho). 1 stud = 0.28 m.", fill=(235, 235, 235), font=small)
    for i, mid in enumerate(ids):
        d = rbxdl.asset_dir(mid)
        r, c = divmod(i, per_row)
        x0 = c * (2 * cw + 12)
        y0 = 56 + r * (ch + label_h)
        for j, nm in enumerate(("preview_34.png", "preview_side.png")):
            p = os.path.join(d, nm)
            if os.path.exists(p):
                im = Image.open(p).convert("RGB").resize((cw, ch), Image.LANCZOS)
                img.paste(im, (x0 + j * cw, y0 + label_h))
            else:
                dr.rectangle((x0 + j * cw, y0 + label_h, x0 + (j + 1) * cw - 1, y0 + label_h + ch - 1), outline=(90, 90, 90))
                dr.text((x0 + j * cw + 12, y0 + label_h + ch // 2), "no render", fill=(160, 160, 160), font=small)
        mp = os.path.join(rbx_car_map.OUT_DIR, f"{mid}.json")
        o = json.load(open(mp)) if os.path.exists(mp) else {}
        dims = o.get("dims_studs", {})
        cnt = o.get("counts", {})
        sec = " | BACKDOOR SCRIPT" if o.get("security", {}).get("flaggedScripts") else ""
        title = f"{mid}  {(o.get('depicts') or o.get('name') or '')[:66]}"
        sub = (f"{dims.get('length', '?')} x {dims.get('width', '?')} x {dims.get('height', '?')} studs  "
               f"{cnt.get('visibleParts', '?')} visible parts  ~{cnt.get('approxTris', 0) // 1000}k tris  "
               f"scale x{o.get('suggested_uniform_scale')}{sec}")
        dr.text((x0 + 6, y0 + 4), title, fill=(255, 255, 255), font=font)
        dr.text((x0 + 6, y0 + 25), sub, fill=(255, 120, 110) if sec else (190, 190, 195), font=small)
    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    img.save(SHEET, optimize=True)
    return SHEET


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    cmd, ids = argv[0], [int(a) for a in argv[1:] if a.isdigit()]
    if cmd == "run":
        for mid in ids or SHORTLIST:
            run(mid, render="--no-render" not in argv)
    elif cmd == "map":
        import rbx_car_map
        for mid in ids or SHORTLIST + EXTRAS:
            print(rbx_car_map.summary_line(rbx_car_map.analyze(mid)))
    elif cmd == "texsheet":
        for mid in ids or SHORTLIST:
            print(texsheet(mid))
    elif cmd == "sheet":
        print(sheet(ids or SHORTLIST))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
