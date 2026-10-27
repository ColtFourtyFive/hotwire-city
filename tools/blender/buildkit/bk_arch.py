"""Building archetype core. Each generator fills one Building with per-role MeshBufs; every role becomes
ONE mesh object on export (= one Roblox MeshPart), split into <Role>_1, <Role>_2 ... only if it passes the
20k-triangle MeshPart limit.

  Walls    main facade material (brick / stucco / curtain spandrel / corrugated)  tiling PBR, tintable
  Walls2   secondary facade material (wood slats, stone base, block, marble)       tiling PBR
  Walls3   tertiary facade material (timber slats on the hills mansion)          tiling PBR
  Trim     sills, lintels, cornices, belts, slabs, copings, fascias                tiling PBR, tintable
  Accent   deco stripes / eyebrows / shutters / canopies                           plain colour (recolourable)
  Frames   window frames, mullions, storefront aluminium                           plain colour (recolourable)
  Glass    all glazing, UV'd into the 4x4 window-interior atlas                    atlas + low roughness
  Roof     roof surfaces (tar, gravel, clay tile, shingle, metal)                  tiling PBR
  Roof2    secondary roof (clay mansard over a tar roof, garage roof ...)         tiling PBR
  Details  AC units, fire escapes, rails, tanks, pumps, vents, pipes                tiling metal PBR
  Doors    roller / garage / service doors                                         tiling PBR (shutter)
  Awning   striped canvas                                                          awning atlas
  Sign     storefront signs (signs.png)                                            atlas
  Brand    blades, name boards, price boards, posters (brands.png)                 atlas
  Grime    alpha dirt decals (rising damp, rain streaks, rust leaks)               RGBA atlas, alpha blend
  Site     lot paving: walks, forecourt, driveway, pool deck (concrete / pavers)  tiling PBR
  Asphalt  parking lots and drive aisles                                           tiling PBR
  Paint    parking stripes / kerb paint                                            plain colour
  Lawn     lot grass (drop it if the world uses terrain grass)                     tiling PBR
  Water    pool water                                                              colour, Glass material
  Neon     tubes, canopy downlights, wall packs: Neon at night                     plain colour
  WindowsLit  copies of ~35% of the glass quads, for night (hidden by day)         lit atlas / Neon

Building-local space: front faces -Y, origin bottom-centre of the lot, 1 unit = 1 stud.
"""
import json, math, os, random, zlib
import bk_geo as G
import bk_mat as M

HERE = os.path.dirname(os.path.abspath(__file__))
ATLAS = json.load(open(os.path.join(HERE, "out", "textures", "atlas.json")))

PASTELS = {"pink": (0.96, 0.66, 0.70), "mint": (0.62, 0.90, 0.78), "lavender": (0.76, 0.70, 0.92),
           "peach": (0.99, 0.76, 0.58), "sky": (0.60, 0.82, 0.96), "lemon": (0.98, 0.91, 0.58),
           "white": (0.96, 0.95, 0.92), "coral": (0.97, 0.56, 0.48), "aqua": (0.50, 0.86, 0.88),
           "sand": (0.93, 0.84, 0.68), "terracotta": (0.80, 0.48, 0.36), "olive": (0.70, 0.72, 0.52)}
# muted, sun-bleached versions used for LA stucco (GTA V Los Santos palette, not candy pastels)
STUCCO = {"bone": (0.93, 0.90, 0.82), "cream": (0.95, 0.88, 0.72), "sand": (0.86, 0.77, 0.62),
          "adobe": (0.80, 0.62, 0.48), "sage": (0.70, 0.74, 0.62), "grey": (0.78, 0.78, 0.76),
          "salmon": (0.90, 0.68, 0.58), "butter": (0.95, 0.86, 0.60), "white": (0.95, 0.95, 0.93),
          "slate": (0.58, 0.62, 0.64), "taupe": (0.70, 0.64, 0.56), "mint": (0.74, 0.86, 0.78)}
ACCENTS = {"teal": (0.0, 0.52, 0.55), "coral": (0.93, 0.36, 0.33), "navy": (0.10, 0.18, 0.40),
           "flamingo": (0.95, 0.35, 0.58), "sea": (0.10, 0.62, 0.62), "sun": (0.98, 0.72, 0.12),
           "white": (0.96, 0.96, 0.94), "aqua": (0.25, 0.78, 0.82)}
FRAMES = {"white": (0.92, 0.92, 0.9), "black": (0.05, 0.05, 0.055), "bronze": (0.22, 0.16, 0.11),
          "green": (0.06, 0.2, 0.14), "silver": (0.62, 0.64, 0.66), "red": (0.45, 0.06, 0.06)}

TILES = {"Walls": 8.0, "Walls2": 8.0, "Walls3": 8.0, "Clear": 8.0, "Trim": 6.0, "Accent": 6.0, "Frames": 8.0, "Glass": 8.0, "Roof": 16.0, "Roof2": 10.0,
         "Details": 6.0, "Doors": 10.0, "Awning": 20.8, "Sign": 8.0, "Brand": 8.0, "Grime": 24.0, "Site": 16.0,
         "Asphalt": 24.0,
         "Paint": 8.0, "Lawn": 20.0, "Water": 16.0, "Neon": 8.0, "WindowsLit": 8.0}
ROLE_ORDER = ["Walls", "Walls2", "Walls3", "Trim", "Accent", "Frames", "Glass", "Clear", "Roof", "Roof2", "Details", "Doors", "Awning", "Sign",
              "Brand", "Site", "Asphalt", "Paint", "Lawn", "Water", "Neon", "Grime", "WindowsLit"]
NIGHT_ONLY = {"WindowsLit"}


class Building:
    def __init__(self, kind, seed, name=None):
        self.kind, self.seed = kind, seed
        self.rng = random.Random(zlib.crc32(f"{kind}:{seed}".encode()))   # stable across processes
        self.name = name or f"{kind}_{seed:02d}"
        self.bufs = {}
        self.spec = {}
        self.lit_ratio = 0.38
        self.footprint = (0, 0)
        self.height = 0
        self.base_depth = 0.0          # how far below z=0 the model reaches (hillside plinths)
        self.tags = {}
        self.spawns = []               # parked-car spawn points [(x, y, heading_deg)] in lot space (manifest)

    def b(self, role):
        if role not in self.bufs:
            self.bufs[role] = G.MeshBuf(f"{self.name}_{role}", tile=TILES.get(role, 8.0))
        return self.bufs[role]

    # -- atlas helpers --------------------------------------------------------------------------------
    def cell(self, group):
        names = [k for k in ATLAS["windows"] if k.startswith(group)]
        return ATLAS["windows"][self.rng.choice(names)]

    def glass(self, F, u0, u1, z0, z1, n, group, lit=None):
        rect = self.cell(group) if isinstance(group, str) else group
        F.quad(self.b("Glass"), u0, u1, z0, z1, n, uv=rect)
        if lit is None:
            lit = self.rng.random() < self.lit_ratio
        if lit:
            F.quad(self.b("WindowsLit"), u0, u1, z0, z1, n + 0.03, uv=rect)

    # -- standard elements ----------------------------------------------------------------------------
    def window(self, F, u0, u1, z0, z1, st, openings, wall_role="Walls"):
        """Recessed punched window with frame, mullions, sill, header... st: style dict."""
        d = st.get("depth", 0.8)
        fw, fd = st.get("frame_w", 0.32), st.get("frame_d", 0.35)
        openings.append((u0, u1, z0, z1))
        has_sill = st.get("sill", True)
        F.reveal(self.b(wall_role), u0, u1, z0, z1, d, sides=(not has_sill, True, True, True))
        self.glass(F, u0, u1, z0, z1, -d, st.get("cells", "res"))
        fr = self.b("Frames")
        nb, nf = -d, -d + fd
        F.box(fr, u0, u0 + fw, nb, nf, z0, z1, skip=("back",))
        F.box(fr, u1 - fw, u1, nb, nf, z0, z1, skip=("back",))
        F.box(fr, u0 + fw, u1 - fw, nb, nf, z0, z0 + fw * 1.4, skip=("back",))
        F.box(fr, u0 + fw, u1 - fw, nb, nf, z1 - fw, z1, skip=("back",))
        mul = st.get("mullion", "v")
        uc, h = (u0 + u1) / 2, z1 - z0
        if mul in ("v", "cross", "grid"):
            F.box(fr, uc - fw * 0.4, uc + fw * 0.4, nb, nf - 0.05, z0, z1, skip=("back",))
        if mul in ("t", "cross"):
            zt = z0 + h * 0.66
            F.box(fr, u0, u1, nb, nf - 0.05, zt - fw * 0.4, zt + fw * 0.4, skip=("back",))
        if mul == "dh":   # double hung: meeting rail
            zt = z0 + h * 0.5
            F.box(fr, u0, u1, nb, nf + 0.05, zt - fw * 0.55, zt + fw * 0.55, skip=("back",))
        if mul == "grid":
            for t in (0.33, 0.66):
                zt = z0 + h * t
                F.box(fr, u0, u1, nb, nf - 0.08, zt - fw * 0.3, zt + fw * 0.3, skip=("back",))
        tr = self.b(st.get("trim_role", "Trim"))
        if has_sill:
            F.box(tr, u0 - 0.4, u1 + 0.4, -d, 0.6, z0 - 0.5, z0 + 0.05)
        hd = st.get("header")
        if hd == "lintel":
            F.box(tr, u0 - 0.5, u1 + 0.5, -0.05, 0.22, z1, z1 + 1.0, skip=("back",))
        elif hd == "keystone":
            F.box(tr, u0 - 0.5, u1 + 0.5, -0.05, 0.22, z1, z1 + 0.9, skip=("back",))
            F.box(tr, uc - 0.55, uc + 0.55, -0.05, 0.42, z1 - 0.25, z1 + 1.25, skip=("back",))
        elif hd == "eyebrow":
            F.box(self.b(st.get("eyebrow_role", "Accent")), u0 - 0.9, u1 + 0.9, -0.05, 1.5, z1 + 0.35, z1 + 0.7, bevel=0.1)
        if st.get("surround"):
            s = st["surround"]
            F.box(tr, u0 - s, u0, -0.05, 0.25, z0, z1 + s, skip=("back",))
            F.box(tr, u1, u1 + s, -0.05, 0.25, z0, z1 + s, skip=("back",))
            F.box(tr, u0, u1, -0.05, 0.25, z1, z1 + s, skip=("back",))
        if st.get("shutters"):
            sw = (u1 - u0) * 0.5
            ac = self.b("Accent")
            for a, b_ in ((u0 - sw - 0.15, u0 - 0.15), (u1 + 0.15, u1 + sw + 0.15)):
                F.box(ac, a, b_, -0.05, 0.22, z0 + 0.1, z1 - 0.1, bevel=0.05)
                for k in range(1, 6):   # louvre lines
                    zz = z0 + (z1 - z0) * k / 6
                    F.box(ac, a + 0.12, b_ - 0.12, 0.2, 0.3, zz - 0.06, zz + 0.06, skip=("back",))
        if st.get("ac", 0) > 0 and self.rng.random() < st["ac"]:
            dt = self.b("Details")
            w2 = min(1.3, (u1 - u0) * 0.35)
            F.box(dt, uc - w2, uc + w2, -d + 0.15, 1.3, z0 + 0.05, z0 + 1.55, bevel=0.1)
            F.box(dt, uc - w2 + 0.25, uc + w2 - 0.25, 1.3, 1.36, z0 + 0.3, z0 + 1.3, skip=("back",))
            self.grime(F, uc - w2, uc + w2, z0 - 5.5, z0 + 0.05, "leak", n=0.03)

    def storefront(self, F, u0, u1, z0, z1, st, openings, door=None):
        """Big shop window wall with aluminium mullions, transom, kick plate and optional door."""
        d = st.get("depth", 1.0)
        openings.append((u0, u1, z0, z1))
        F.reveal(self.b(st.get("reveal_role", "Trim")), u0, u1, z0, z1, d, sides=(False, True, True, True))
        fr = self.b("Frames")
        tr = self.b("Trim")
        kick = st.get("kick", 1.6)
        F.box(tr, u0, u1, -d - 0.2, -d + 0.35, z0, z0 + kick, skip=("back", "bottom"))
        zt = z1 - st.get("transom", 2.6)
        mw = 0.3
        cell = self.cell(st.get("cells", "shop"))
        # door bay
        segs = []
        if door is not None:
            dw = st.get("door_w", 4.5)
            du0, du1 = door - dw / 2, door + dw / 2
            segs = [(u0, du0), (du1, u1)]
            self.glass(F, du0, du1, z0, zt, -d, cell, lit=True)
            F.box(fr, du0, du0 + 0.45, -d, -d + 0.45, z0, zt, skip=("back",))
            F.box(fr, du1 - 0.45, du1, -d, -d + 0.45, z0, zt, skip=("back",))
            F.box(fr, du0, du1, -d, -d + 0.45, z0, z0 + 0.9, skip=("back",))
            F.box(fr, (du0 + du1) / 2 - 0.2, (du0 + du1) / 2 + 0.2, -d, -d + 0.4, z0, zt, skip=("back",))
            F.box(self.b("Details"), du0 + 0.8, (du0 + du1) / 2 - 0.5, -d + 0.4, -d + 0.65, z0 + 3.4, z0 + 3.7)
        else:
            segs = [(u0, u1)]
        for a, b_ in segs:
            if b_ - a < 0.5:
                continue
            self.glass(F, a, b_, z0 + kick, zt, -d, cell, lit=True)
            n = max(1, round((b_ - a) / st.get("bay", 5.5)))
            for k in range(n + 1):
                u = a + (b_ - a) * k / n
                F.box(fr, max(a, u - mw), min(b_, u + mw), -d, -d + 0.4, z0 + kick, z1, skip=("back",))
            F.box(fr, a, b_, -d, -d + 0.4, z0 + kick, z0 + kick + 0.35, skip=("back",))
        self.glass(F, u0, u1, zt, z1, -d, cell, lit=True)
        F.box(fr, u0, u1, -d, -d + 0.45, zt - 0.3, zt + 0.3, skip=("back",))
        F.box(fr, u0, u1, -d, -d + 0.4, z1 - 0.35, z1, skip=("back",))

    def awning(self, F, u0, u1, z_top, proj=4.5, drop=2.4, valance=0.9, color=None):
        color = color or self.rng.choice(list(ATLAS["awnings"].keys())[:6])
        u_0, v0, u_1, v1 = ATLAS["awnings"][color]
        a = self.b("Awning")
        per = TILES["Awning"]
        uu0, uu1 = u0 / per, u1 / per
        vm = v0 + (v1 - v0) * 0.22
        A, B = F.p(u0, z_top, 0.05), F.p(u1, z_top, 0.05)
        C, D = F.p(u1, z_top - drop, proj), F.p(u0, z_top - drop, proj)
        E, Fv = F.p(u1, z_top - drop - valance, proj), F.p(u0, z_top - drop - valance, proj)
        G.quad(a, D, C, B, A, uv=[(uu0, vm), (uu1, vm), (uu1, v1), (uu0, v1)])
        G.quad(a, A, B, C, D, uv=[(uu0, v1), (uu1, v1), (uu1, vm), (uu0, vm)])   # underside
        G.quad(a, Fv, E, C, D, uv=[(uu0, v0), (uu1, v0), (uu1, vm), (uu0, vm)])
        G.quad(a, D, C, E, Fv, uv=[(uu0, vm), (uu1, vm), (uu1, v0), (uu0, v0)])
        # side cheeks (triangles as degenerate quads are avoided: add proper tris)
        for (P0, P1, P2) in ((A, D, Fv), (B, E, C)):
            a.add([P0, P1, P2], [(0, 1, 2)], [[(uu0, v1), (uu0, vm), (uu0, v0)]])
            a.add([P0, P2, P1], [(0, 1, 2)], [[(uu0, v1), (uu0, v0), (uu0, vm)]])
        # metal frame arms
        dt = self.b("Details")
        for u in (u0 + 0.2, u1 - 0.2):
            G.hcylinder(dt, F.p(u, z_top - drop - 0.05, proj - 0.1), F.p(u, z_top - drop - 1.6, 0.1), 0.08, seg=5)

    def sign(self, F, uc, z0, key, height=2.4, n=0.0, frame="Frames", lit_border=False):
        u0_, v0, u1_, v1 = ATLAS["signs"][key]
        aspect = (u1_ - u0_) / (v1 - v0)
        w = height * aspect
        u0, u1 = uc - w / 2, uc + w / 2
        F.box(self.b(frame), u0 - 0.25, u1 + 0.25, n, n + 0.45, z0 - 0.25, z0 + height + 0.25, bevel=0.08)
        F.quad(self.b("Sign"), u0, u1, z0, z0 + height, n + 0.47, uv=(u0_, v0, u1_, v1))
        return w

    def cornice(self, loop, z, size=1.0, role="Trim"):
        s = size
        prof = [(0.0, z - 1.4 * s), (0.18 * s, z - 1.4 * s), (0.18 * s, z - 1.1 * s), (0.55 * s, z - 0.8 * s),
                (0.6 * s, z - 0.55 * s), (1.15 * s, z - 0.3 * s), (1.2 * s, z), (0.0, z)]
        G.sweep(self.b(role), loop, prof, closed=True)

    def belt(self, loop, z, h=0.8, out=0.35, role="Trim"):
        prof = [(0.0, z), (out, z), (out, z + h), (0.0, z + h)]
        G.sweep(self.b(role), loop, prof, closed=True)

    def parapet(self, loop, z, h=3.0, t=0.9, coping=True, roof=True, wall_role="Walls"):
        G.sweep(self.b(wall_role), loop, [(0.0, z), (0.0, z + h)], closed=True)
        inner = [(-t, z + h), (-t, z)]
        if coping:
            G.sweep(self.b("Trim"), loop, [(0.0, z + h), (0.25, z + h), (0.25, z + h + 0.45), (-t - 0.2, z + h + 0.45),
                                           (-t - 0.2, z + h)], closed=True)
            G.sweep(self.b(wall_role), loop, [(-t, z + h), (-t, z)], closed=True)
        else:
            G.sweep(self.b(wall_role), loop, [(0.0, z + h), (-t, z + h), (-t, z)], closed=True)
        if roof:
            G.cap(self.b("Roof"), G.offset_loop(loop, -t), z + 0.02)

    def hvac(self, x, y, z, w=5, d=3.5, h=3.0):
        dt = self.b("Details")
        G.box(dt, x - w / 2, y - d / 2, z, x + w / 2, y + d / 2, z + h, bevel=0.15, skip=("bottom",))
        G.cylinder(dt, x + w * 0.2, y, z + h, z + h + 0.4, min(w, d) * 0.3, seg=12, caps=(False, True))
        G.box(dt, x - w / 2 + 0.3, y - d / 2 - 0.05, z + 0.4, x - 0.2, y - d / 2 + 0.1, z + h - 0.4, skip=("back",))

    def water_tank(self, x, y, z, r=4.0, h=7.0):
        dt = self.b("Details")
        for sx in (-1, 1):
            for sy in (-1, 1):
                G.box(dt, x + sx * r * 0.6 - 0.25, y + sy * r * 0.6 - 0.25, z, x + sx * r * 0.6 + 0.25, y + sy * r * 0.6 + 0.25, z + 4, skip=("bottom", "top"))
        G.box(dt, x - r * 0.8, y - r * 0.8, z + 4, x + r * 0.8, y + r * 0.8, z + 4.4, skip=())
        wt = self.b("Trim")
        G.cylinder(wt, x, y, z + 4.4, z + 4.4 + h, r, seg=16, caps=(True, False), tile=6)
        G.cylinder(dt, x, y, z + 4.4 + h, z + 4.4 + h + 2.2, r + 0.15, seg=16, caps=(False, True), r1=0.3)
        for k in range(3):
            zz = z + 5.4 + k * (h - 1.5) / 2
            G.cylinder(dt, x, y, zz, zz + 0.2, r + 0.08, seg=16, caps=(False, False))

    def bulkhead(self, x, y, z, w=10, d=8, h=9, wall_role="Walls"):
        G.box(self.b(wall_role), x - w / 2, y - d / 2, z, x + w / 2, y + d / 2, z + h, skip=("bottom",))
        G.box(self.b("Trim"), x - w / 2 - 0.3, y - d / 2 - 0.3, z + h, x + w / 2 + 0.3, y + d / 2 + 0.3, z + h + 0.5, bevel=0.1)
        G.cap(self.b("Roof"), [(x - w / 2, y - d / 2), (x + w / 2, y - d / 2), (x + w / 2, y + d / 2), (x - w / 2, y + d / 2)], z + h + 0.52)
        F = G.Facade((x - w / 2, y - d / 2, 0), (1, 0, 0), (0, -1, 0), w)
        F.box(self.b("Details"), w / 2 - 2, w / 2 + 2, -0.2, 0.15, z, z + 7.2)

    def rect_loop(self, W, D, x0=None, y0=None):
        x0 = -W / 2 if x0 is None else x0
        y0 = -D / 2 if y0 is None else y0
        return [(x0, y0), (x0 + W, y0), (x0 + W, y0 + D), (x0, y0 + D)]

    def facades(self, W, D, x0=None, y0=None):
        x0 = -W / 2 if x0 is None else x0
        y0 = -D / 2 if y0 is None else y0
        return {"front": G.Facade((x0, y0, 0), (1, 0, 0), (0, -1, 0), W),
                "right": G.Facade((x0 + W, y0, 0), (0, 1, 0), (1, 0, 0), D),
                "back": G.Facade((x0 + W, y0 + D, 0), (-1, 0, 0), (0, 1, 0), W),
                "left": G.Facade((x0, y0 + D, 0), (0, -1, 0), (-1, 0, 0), D)}

    def columns(self, width, spacing, margin, win_w):
        n = max(1, int((width - 2 * margin + spacing - win_w) // spacing))
        span = (n - 1) * spacing
        start = width / 2 - span / 2
        return [start + k * spacing for k in range(n)]

    # -- decals / lot ---------------------------------------------------------------------------------
    def grime(self, F, u0, u1, z0, z1, kind="base", n=0.04):
        """Alpha dirt quad in front of a facade (kind: base|streak|soot|leak). u tiles every 24 studs."""
        gu0, gv0, gu1, gv1 = ATLAS["grime"][kind]
        t = TILES["Grime"]
        off = self.rng.random()
        F.quad(self.b("Grime"), u0, u1, z0, z1, n, uv=[(u0 / t + off, gv0), (u1 / t + off, gv0), (u1 / t + off, gv1), (u0 / t + off, gv1)])

    def grime_base(self, Fs, h=7.0, z=0.0, sides=None, n=0.04):
        for side, F in Fs.items():
            if sides is None or side in sides:
                self.grime(F, 0.0, F.W, z, z + h, "base", n)

    def brand(self, F, uc, z0, key, height, n=0.0, frame="Frames", depth=0.45, border=0.25):
        u0_, v0, u1_, v1 = ATLAS["brands"][key]
        w = height * (u1_ - u0_) / (v1 - v0)
        u0, u1 = uc - w / 2, uc + w / 2
        if depth > 0:
            F.box(self.b(frame), u0 - border, u1 + border, n, n + depth, z0 - border, z0 + height + border)
        F.quad(self.b("Brand"), u0, u1, z0, z0 + height, n + depth + 0.02, uv=(u0_, v0, u1_, v1))
        return w

    def parking(self, x0, y0, x1, y1, stall_w=10.0, stall_d=19.0, rows=("-y",), z=0.05, stops=True, aisle_lines=False):
        """Asphalt lot (Asphalt) with painted stalls (Paint) along the given edges ('-y' = stalls touch y0 ...)."""
        G.quad(self.b("Asphalt"), (x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z))
        pt, dt = self.b("Paint"), self.b("Trim")
        zz = z + 0.03
        for edge in rows:
            if edge in ("-y", "+y"):
                yb = y0 if edge == "-y" else y1
                sgn = 1 if edge == "-y" else -1
                n = int((x1 - x0 - 2) // stall_w)
                xs = x0 + (x1 - x0 - n * stall_w) / 2
                for i in range(n + 1):
                    x = xs + i * stall_w
                    ya, yb2 = sorted((yb + sgn * 1.0, yb + sgn * stall_d))
                    G.quad(pt, (x - 0.2, ya, zz), (x + 0.2, ya, zz), (x + 0.2, yb2, zz), (x - 0.2, yb2, zz))
                    if stops and i < n:
                        yc = yb + sgn * 3.0
                        G.box(dt, x + 2.0, yc - 0.4, z, x + stall_w - 2.0, yc + 0.4, z + 0.55)
                    if i < n:
                        self.spawns.append((round(x + stall_w / 2, 2), round(yb + sgn * (stall_d / 2 + 0.5), 2), 90.0 if sgn < 0 else -90.0))
            else:
                xb = x0 if edge == "-x" else x1
                sgn = 1 if edge == "-x" else -1
                n = int((y1 - y0 - 2) // stall_w)
                ys = y0 + (y1 - y0 - n * stall_w) / 2
                for i in range(n + 1):
                    y = ys + i * stall_w
                    xa, xb2 = sorted((xb + sgn * 1.0, xb + sgn * stall_d))
                    G.quad(pt, (xa, y - 0.2, zz), (xb2, y - 0.2, zz), (xb2, y + 0.2, zz), (xa, y + 0.2, zz))
                    if stops and i < n:
                        xc = xb + sgn * 3.0
                        G.box(dt, xc - 0.4, y + 2.0, z, xc + 0.4, y + stall_w - 2.0, z + 0.55)
                    if i < n:
                        self.spawns.append((round(xb + sgn * (stall_d / 2 + 0.5), 2), round(y + stall_w / 2, 2), 180.0 if sgn > 0 else 0.0))

    def lot_light(self, x, y, h=24.0, arms=2):
        dt = self.b("Details")
        G.box(dt, x - 0.9, y - 0.9, 0, x + 0.9, y + 0.9, 2.4)
        G.box(dt, x - 0.3, y - 0.3, 2.4, x + 0.3, y + 0.3, h)
        for k in range(arms):
            sx = 1 if k == 0 else -1
            G.box(dt, x + sx * 0.3 if sx > 0 else x - 3.4, y - 0.7, h - 0.6, x + 3.4 if sx > 0 else x - 0.3, y + 0.7, h)
            G.box(self.b("Neon"), x + sx * 2.0 - 0.8, y - 0.6, h - 0.7, x + sx * 2.0 + 0.8, y + 0.6, h - 0.6, skip=("top",))

    def bollard(self, x, y, h=3.2, role="Accent"):
        G.cylinder(self.b(role), x, y, 0, h, 0.45, seg=8, caps=(False, True))

    def translate(self, dx=0.0, dy=0.0, dz=0.0):
        """Shift everything (e.g. to re-centre a lot after building a terrace or yard in front)."""
        for b in self.bufs.values():
            b.v = [(p[0] + dx, p[1] + dy, p[2] + dz) for p in b.v]
        self.spawns = [(x + dx, y + dy, h) for (x, y, h) in self.spawns]

    def slab(self, role, x0, y0, x1, y1, z, t=0.3, skip=("bottom",)):
        G.box(self.b(role), x0, y0, z - t, x1, y1, z, skip=skip)

    # -- output ---------------------------------------------------------------------------------------
    def stats(self):
        return {r: b.tris() for r, b in self.bufs.items() if not b.empty()}


# =====================================================================================================
def midtown(seed=0, **kw):
    """Brick / stucco apartment block with storefronts, fire escape or balconies, cornice, rooftop kit."""
    B = Building("midtown", seed, kw.get("name"))
    r = B.rng
    W = kw.get("W", r.choice([40, 44, 48, 52]))
    D = kw.get("D", r.choice([34, 38, 42]))
    floors = kw.get("floors", r.randint(5, 8))
    gf, fh = 16.0, 12.0
    top = gf + floors * fh
    party = set(kw.get("party", []))          # sides that abut neighbours: blank walls, no windows
    wall = kw.get("wall", r.choice(["brick_red", "brick_red", "brick_tan", "stucco", "brick_painted"]))
    tint = (1, 1, 1)
    if wall in ("stucco", "brick_painted"):
        tint = PASTELS[kw.get("pastel", r.choice(["sand", "peach", "mint", "sky", "terracotta", "white", "olive"]))]
    trim_t = PASTELS["white"] if wall.startswith("brick") else (0.93, 0.91, 0.86)
    frame = FRAMES[kw.get("frame", r.choice(["white", "black", "green", "bronze"] if wall.startswith("brick") else ["white", "bronze", "black"]))]
    B.spec = {"Walls": ("tex", wall, tint), "Trim": ("tex", "plaster", trim_t), "Frames": ("color", frame, 0.35, 0.1),
              "Glass": ("glass",), "Roof": ("tex", "roof_tar", (1, 1, 1)), "Details": ("tex", "metal", (0.55, 0.57, 0.6)),
              "Awning": ("atlas", "awnings.png"), "Sign": ("atlas", "signs.png"), "Accent": ("color", ACCENTS["navy"], 0.5, 0),
              "WindowsLit": ("lit",), "Grime": ("grime",), "Walls2": ("tex", "granite", (0.9, 0.9, 0.9)),
              "Doors": ("tex", "shutter", (0.75, 0.75, 0.75))}
    B.footprint, B.height = (W, D), top + 3.5
    B.tags = {"district": "midtown", "floors": floors, "wall": wall}
    loop = B.rect_loop(W, D)
    Fs = B.facades(W, D)
    brick = wall.startswith("brick")
    st = {"depth": 0.9 if brick else 0.7, "mullion": "dh" if brick else r.choice(["v", "cross"]),
          "header": "keystone" if brick and r.random() < 0.5 else ("lintel" if brick else None),
          "surround": None if brick else 0.55, "ac": 0.18, "cells": "res", "shutters": (not brick) and r.random() < 0.4}
    ww, wh, sp = 4.0, 6.6, 7.4
    escape_side = "right" if brick else None
    balconies = (not brick) or r.random() < 0.3
    for side, F in Fs.items():
        ops_up, ops_gf = [], []
        cols = B.columns(F.W, sp, 3.5, ww)
        if side in party:
            F.wall(B.b("Walls"), 0, top)
            F.wall(B.b("Trim"), 0, gf)
            B.grime(F, 0, F.W, top - 10, top, "soot")
            continue
        for fi in range(floors):
            z0 = gf + fi * fh + 2.4
            for ci, uc in enumerate(cols):
                s2 = dict(st)
                if side == "back":
                    s2["ac"], s2["shutters"] = 0.08, False
                is_bal = balconies and side == "front" and fi % 1 == 0 and ci % 2 == 1 and fi < floors
                if is_bal:   # french door + balcony
                    s2 = dict(s2, sill=False, mullion="v", ac=0, shutters=False)
                    B.window(F, uc - 2.4, uc + 2.4, gf + fi * fh + 0.4, z0 + wh, s2, ops_up)
                    balcony(B, F, uc - 3.6, uc + 3.6, gf + fi * fh + 0.4, 4.0)
                else:
                    B.window(F, uc - ww / 2, uc + ww / 2, z0, z0 + wh, s2, ops_up)
                    if r.random() < 0.35:
                        B.grime(F, uc - ww / 2 - 0.3, uc + ww / 2 + 0.3, z0 - 5.0, z0 - 0.5, "streak", n=0.03)
        # ground floor
        if side == "front":
            n_shops = 2 if W >= 44 else 1
            pier = 2.4
            sw = (W - pier * (n_shops + 1)) / n_shops
            for k in range(n_shops):
                u0 = pier + k * (sw + pier)
                door = u0 + (sw - 3.0 if k % 2 == 0 else 3.0)
                B.storefront(F, u0, u0 + sw, 0.0, gf - 3.4, {"cells": r.choice(["shop", "diner"]), "depth": 1.1}, ops_gf, door=door)
                B.awning(F, u0 - 0.2, u0 + sw + 0.2, gf - 2.2, proj=4.2, drop=2.2)
                key = r.choice([k_ for k_ in ATLAS["signs"] if k_.startswith("h")])
                B.sign(F, u0 + sw / 2, gf - 1.9, key, height=1.55, n=0.15)
        elif side in ("left", "right"):
            for uc in B.columns(F.W, 11, 5, 6)[:2]:
                B.window(F, uc - 3, uc + 3, 3.0, gf - 4.0, dict(st, mullion="t", cells="shop", ac=0, header=None, shutters=False), ops_gf, wall_role="Trim")
        else:
            F.box(B.b("Doors"), F.W / 2 - 2.2, F.W / 2 + 2.2, -0.3, 0.1, 0, 8.0)   # service door
            F.box(B.b("Doors"), F.W / 2 + 5, F.W / 2 + 15, -0.3, 0.1, 0, 10.0)   # loading roller door
        F.wall(B.b("Trim"), 0, gf, ops_gf)
        B.grime(F, 0, F.W, 0, 7.0, "base")
        B.grime(F, 0, F.W, top - 7.5, top - 1.4, "soot")
        F.wall(B.b("Walls"), gf, top, ops_up)
        if side == escape_side:
            fire_escape(B, F, gf, fh, floors, cols, ww)
    # horizontal articulation
    B.belt(loop, gf - 0.8, h=1.0, out=0.45)
    B.cornice(loop, top, size=1.3 if brick else 1.0)
    if brick:
        quoins(B, Fs, gf, top)
    B.parapet(loop, top, h=2.6, t=0.9)
    # roof kit
    rz = top + 0.02
    B.bulkhead(-W / 2 + 9, D / 2 - 8, rz, w=9, d=7, h=8)
    if brick and r.random() < 0.8:
        B.water_tank(W / 2 - 9, D / 2 - 10, rz, r=3.6, h=6.5)
    for k in range(r.randint(2, 4)):
        B.hvac(r.uniform(-W / 2 + 6, W / 2 - 6), r.uniform(-D / 2 + 6, 0), rz, w=r.choice([4, 5, 6]), d=3.5, h=r.choice([2.5, 3.2]))
    return B


def quoins(B, Fs, z0, z1, size=2.2):
    tr = B.b("Trim")
    for side, F in Fs.items():
        z, k = z0, 0
        while z + 1.4 <= z1 - 1.2:
            w = size if k % 2 == 0 else size * 0.62
            F.box(tr, 0, w, -0.02, 0.28, z + 0.06, z + 1.34, skip=("back",))
            F.box(tr, F.W - w, F.W, -0.02, 0.28, z + 0.06, z + 1.34, skip=("back",))
            z += 1.4
            k += 1


def balcony(B, F, u0, u1, zf, depth):
    tr, dt = B.b("Trim"), B.b("Details")
    F.box(tr, u0, u1, 0, depth, zf - 0.7, zf, bevel=0.1)
    rail_h = 3.4
    F.box(dt, u0 + 0.1, u1 - 0.1, depth - 0.25, depth - 0.05, zf + rail_h - 0.25, zf + rail_h, bevel=0.05)
    for u in (u0 + 0.15, u1 - 0.35):
        F.box(dt, u, u + 0.2, 0.1, depth - 0.1, zf + rail_h - 0.22, zf + rail_h, skip=("back",))
    n = int((u1 - u0) / 0.7)
    for k in range(n + 1):
        u = u0 + 0.2 + (u1 - u0 - 0.4) * k / n
        F.box(dt, u - 0.07, u + 0.07, depth - 0.2, depth - 0.07, zf, zf + rail_h - 0.2, skip=("top", "bottom"))
    for side_u in (u0 + 0.2, u1 - 0.2):
        m = int((depth - 0.4) / 0.7)
        for k in range(1, m + 1):
            nn = 0.15 + (depth - 0.4) * k / (m + 1)
            F.box(dt, side_u - 0.07, side_u + 0.07, nn - 0.07, nn + 0.07, zf, zf + rail_h - 0.2, skip=("top", "bottom"))


def fire_escape(B, F, gf, fh, floors, cols, ww):
    """Classic NYC-style escape over two window columns: grated landings, rails, zig-zag stairs, drop ladder."""
    if len(cols) < 2:
        return
    dt = B.b("Details")
    c0 = cols[len(cols) // 2 - 1]
    c1 = cols[len(cols) // 2]
    u0, u1 = c0 - ww / 2 - 1.5, c1 + ww / 2 + 1.5
    dep = 4.2
    for fi in range(floors):
        zf = gf + fi * fh + 1.6
        F.box(dt, u0, u1, 0.2, dep, zf - 0.25, zf, skip=())
        # rails
        F.box(dt, u0, u1, dep - 0.15, dep, zf + 3.2, zf + 3.4, skip=("back",))
        F.box(dt, u0, u1, dep - 0.15, dep, zf + 1.6, zf + 1.72, skip=("back",))
        for u in (u0, u1 - 0.18):
            F.box(dt, u, u + 0.18, 0.2, dep, zf + 3.2, zf + 3.4)
            F.box(dt, u, u + 0.18, dep - 0.18, dep, zf - 0.25, zf + 3.4, skip=("top", "bottom"))
        n = int((u1 - u0) / 1.8)
        for k in range(1, n):
            u = u0 + (u1 - u0) * k / n
            F.box(dt, u - 0.07, u + 0.07, dep - 0.12, dep - 0.02, zf, zf + 3.2, skip=("top", "bottom"))
        # brackets
        for u in (u0 + 0.6, u1 - 0.6):
            G.hcylinder(dt, F.p(u, zf - 0.25, dep - 0.3), F.p(u, zf - 2.6, 0.1), 0.1, seg=5)
        # stairs to the floor above (inside the landing footprint)
        if fi < floors - 1:
            za, zb = zf, zf + fh
            ua, ub = u0 + 1.0, u1 - 1.0
            n_steps = 9
            for s in range(n_steps):
                t = (s + 0.5) / n_steps
                u = ua + (ub - ua) * t
                z = za + (zb - za) * t
                F.box(dt, u - 0.55, u + 0.55, 0.6, 2.4, z - 0.12, z, skip=())
            for nn in (0.5, 2.5):
                G.hcylinder(dt, F.p(ua, za, nn), F.p(ub, zb, nn), 0.12, seg=5)
                G.hcylinder(dt, F.p(ua, za + 3.0, nn), F.p(ub, zb + 3.0, nn), 0.07, seg=5)
    # drop ladder from first landing
    zf = gf + 1.6
    ux = u1 - 2.5
    for uu in (ux - 0.7, ux + 0.7):
        F.box(dt, uu - 0.08, uu + 0.08, dep - 0.6, dep - 0.44, zf - 9.5, zf, skip=("top", "bottom"))
    for k in range(12):
        z = zf - 9.0 + k * 0.75
        F.box(dt, ux - 0.7, ux + 0.7, dep - 0.58, dep - 0.46, z - 0.05, z + 0.05, skip=("left", "right"))
