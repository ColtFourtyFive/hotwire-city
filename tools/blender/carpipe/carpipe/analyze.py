"""Geometry analysis of an imported car: one joined working mesh, per-face/per-island numpy tables,
auto-orientation, wheel detection and role classification.

Canonical frame used inside the pipeline (Blender): +X = car's right, +Y = forward (front), +Z = up,
origin on the ground between the wheel contact patches.  glTF export (+Y up) turns that into
Roblox/glTF: +X right, +Y up, -Z forward.
"""
from __future__ import annotations

import math
import re

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

from . import matinfo
from .util import faces_np, kw_match, log, norm_name, rgb_to_hsv, select_only, verts_np

# ---------------------------------------------------------------------------------------------- roles
UNK, BODY, BODY2, GLASS, LIGHT_F, LIGHT_R, TRIM, INTERIOR, DISCARD = range(9)
WHEEL0 = 16  # WHEEL0 + i for wheel i
ROLE_NAMES = {UNK: "Unknown", BODY: "Body", BODY2: "Body2", GLASS: "Glass", LIGHT_F: "LightsFront",
              LIGHT_R: "LightsRear", TRIM: "Trim", INTERIOR: "Interior", DISCARD: "Discard"}

# keyword regexes are matched against "_" + normalised name + "_"  (normalised = lowercase, words joined by _)
KW_DISCARD = [r"shadow", r"_collision", r"collider", r"_col_", r"_lod_?[1-9]", r"proxy", r"_floor_", r"_ground",
              r"backdrop", r"_studio", r"_ao_plane", r"_plane_shadow", r"_hitbox", r"_bounds_"]
KW_INTERIOR = [r"interior", r"_seat", r"seats?_", r"_dash", r"steer", r"stering", r"leather", r"carpet", r"cabin",
               r"cockpit", r"pedal", r"gauge", r"console", r"seatbelt", r"fabric", r"upholst", r"floor_?mat",
               r"innen", r"sitz", r"lenkrad", r"armatur", r"speedo", r"shifter", r"gear_?stick", r"headliner",
               r"_rear_?view_", r"rearview", r"dashboard", r"_inside", r"_inner_"]
KW_GLASS = [r"glass", r"window", r"windshield", r"windscreen", r"scheibe", r"_glas_", r"vidrio", r"vitre",
            r"_windows?_", r"_wind_?shield"]
KW_LIGHT = [r"head_?light", r"head_?lamp", r"tail_?light", r"tailight", r"brake_?light", r"rear_?lights?",
            r"front_?lights?", r"reverse", r"indicator", r"blinker", r"turn_?signal", r"signal_?light", r"fog_?l",
            r"_lamps?_", r"_lights?_", r"lights_", r"_led_", r"xenon", r"angel_?eye", r"_emit", r"emissive",
            r"_neon", r"_lens", r"light_?glass", r"headlight", r"taillight", r"brakelight", r"stop_?light"]
KW_TRIM = [r"chrome", r"metal", r"plastic", r"rubber", r"grill", r"trim", r"badge", r"logo", r"emblem",
           r"_plate", r"licen[cs]e", r"mirror", r"exhaust", r"black", r"matte", r"carbon", r"under", r"chassis",
           r"_frame", r"engine", r"suspension", r"axle", r"brake", r"_disc", r"_disk", r"caliper", r"mud", r"wiper",
           r"antenna", r"handle", r"gasket", r"_seal", r"hardware", r"mechanical", r"bolt", r"_nut", r"vent",
           r"intake", r"diffuser", r"roundel", r"kidney", r"splitter", r"_net_", r"mesh_grill", r"_hinge",
           r"blocker", r"_pipe", r"muffler", r"_tank", r"bumper_?black", r"_cladding"]
KW_TRIM_STRONG = [r"wiper", r"gasket", r"_seal", r"handle", r"chrome", r"rubber", r"_trim", r"trim_", r"weather_?strip",
                  r"_frame", r"mirror", r"badge", r"emblem", r"logo", r"licen[cs]e", r"_plate"]
KW_PAINT_STRONG = [r"paint", r"lack", r"karosserie", r"car_?paint", r"carbody", r"body_?colou?r", r"_coat"]
KW_PAINT = KW_PAINT_STRONG + [r"_body", r"body_", r"bodywork", r"car_?shell", r"_shell", r"exterior", r"_hood_",
                              r"_door_?[lr]?_", r"fender", r"_roof"]
KW_WHEEL = [r"wheel", r"tire", r"tyre", r"_rim", r"rims?_", r"rubber", r"reifen", r"felge", r"_rad_", r"_whl",
            r"alloy", r"_hub", r"spoke", r"lug_?nut", r"wheel_?view"]
KW_CALIPER = [r"caliper", r"brake_?pad", r"bremssattel"]
KW_FRONT = [r"front", r"head", r"_fl_", r"_fr_", r"_lf_", r"_rf_", r"bonnet", r"_hood", r"grill", r"windshield",
            r"windscreen", r"kidney", r"vorne", r"_nose", r"splitter"]
KW_REAR = [r"rear", r"_back", r"tail", r"_rl_", r"_rr_", r"_lb_", r"_rb_", r"_lr_", r"trunk", r"_boot", r"exhaust",
           r"brake_?light", r"brakelight", r"reverse", r"diffuser", r"hinten", r"muffler"]
KW_SEAT = [r"seat", r"sitz"]


def _fib_dirs(n=40, min_z=-0.35):
    out = []
    ga = math.pi * (3 - math.sqrt(5))
    for i in range(n):
        z = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(max(0.0, 1 - z * z))
        a = ga * i
        if z >= min_z:
            out.append(Vector((r * math.cos(a), r * math.sin(a), z)))
    return out


def connected_components(n, a, b):
    lab = np.arange(n, dtype=np.int64)
    if len(a) == 0:
        return lab
    for _ in range(200):
        m = np.minimum(lab[a], lab[b])
        np.minimum.at(lab, a, m)
        np.minimum.at(lab, b, m)
        while True:
            nl = lab[lab]
            if np.array_equal(nl, lab):
                break
            lab = nl
        if np.array_equal(lab[a], lab[b]):
            break
    return lab


class Car:
    """Holds the working mesh object and all analysis tables."""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.obj = None
        self.obj_paths: list[str] = []
        self.mats: list[dict] = []
        self.warnings: list[str] = []
        self.report: dict = {}

    # ------------------------------------------------------------------------------------- build
    def build(self, objs):
        objs = self._drop_backdrops(objs)
        for i, o in enumerate(objs):
            me = o.data
            self.obj_paths.append(o.get("cp_path", o.name))
            a = me.attributes.get("cp_obj") or me.attributes.new("cp_obj", "INT", "FACE")
            a.data.foreach_set("value", np.full(len(me.polygons), i, dtype=np.int32))
            self._normalise_uvs(o)
        select_only(objs, objs[0])
        if len(objs) > 1:
            bpy.ops.object.join()
        self.obj = bpy.context.view_layer.objects.active
        self.obj.name = "CarWork"
        me = self.obj.data
        if me.uv_layers:
            me.uv_layers["UVMap"].active = True
            me.uv_layers["UVMap"].active_render = True
        self.mats = [matinfo.material_info(s.material) for s in self.obj.material_slots] or [matinfo.material_info(None)]
        self.refresh()
        log(f"work mesh: {len(me.polygons)} faces, {len(me.vertices)} verts, {len(self.mats)} materials, "
            f"{self.n_isl} islands")

    def _drop_backdrops(self, objs):
        keep = []
        boxes = []
        for o in objs:
            v = verts_np(o.data)
            boxes.append((v.min(0), v.max(0)))
        for i, o in enumerate(objs):
            if kw_match(o.get("cp_path", o.name), KW_DISCARD) and not kw_match(o.get("cp_path", o.name), KW_WHEEL):
                log("drop (name):", o.name)
                bpy.data.objects.remove(o, do_unlink=True)
                continue
            others = [b for j, b in enumerate(boxes) if j != i]
            if others:
                omin = np.min([b[0] for b in others], 0)
                omax = np.max([b[1] for b in others], 0)
                oext = omax - omin
                ext = boxes[i][1] - boxes[i][0]
                flatish = ext.min() < 0.05 * ext.max()
                if (ext[0] > 1.6 * oext[0] and ext[1] > 1.6 * oext[1]) or \
                   (flatish and ext[0] > 1.25 * oext[0] and ext[1] > 1.25 * oext[1]):
                    log("drop (ground/backdrop):", o.name)
                    bpy.data.objects.remove(o, do_unlink=True)
                    continue
            keep.append(o)
        return keep

    @staticmethod
    def _normalise_uvs(o):
        me = o.data
        if not me.uv_layers:
            me.uv_layers.new(name="UVMap")
            return
        old = [l.name for l in me.uv_layers]
        rename = {}
        for i, l in enumerate(me.uv_layers):
            new = "UVMap" if i == 0 else f"UVMap{i + 1}"
            rename[l.name] = new
        for l in list(me.uv_layers):
            l.name = "tmp_" + l.name
        for l in me.uv_layers:
            l.name = rename[l.name[4:]]
        for s in o.material_slots:
            m = s.material
            if m and m.use_nodes:
                for n in m.node_tree.nodes:
                    if n.type == "UVMAP" and n.uv_map in rename:
                        n.uv_map = rename[n.uv_map]
                    elif n.type == "NORMAL_MAP" and n.uv_map in rename:
                        n.uv_map = rename[n.uv_map]
        _ = old

    # ------------------------------------------------------------------------------------- tables
    def refresh(self, islands=True):
        """Re-read geometry. Island ids are only recomputed when islands=True (topology changes);
        transforms keep them stable so wheel/role tables stay valid."""
        me = self.obj.data
        self.co = verts_np(me)
        ls, lt, lv, cen, nor, area, mi = faces_np(me)
        self.ls, self.lt, self.lv, self.fc, self.fn, self.fa, self.fm = ls, lt, lv, cen, nor, area, mi
        self.fm = np.clip(self.fm, 0, len(self.mats) - 1)
        nf = len(ls)
        fo = np.empty(nf, dtype=np.int32)
        me.attributes["cp_obj"].data.foreach_get("value", fo)
        self.fo = fo
        if not islands and getattr(self, "fi", None) is not None and len(self.fi) == nf:
            self._island_tables()
            return
        # islands (welded by position, never crossing source objects)
        diag = float(np.linalg.norm(self.co.max(0) - self.co.min(0))) or 1.0
        tol = diag * 2e-5
        vobj = np.zeros(len(self.co), dtype=np.int64)
        vobj[lv] = np.repeat(fo, lt)
        q = np.round(self.co / tol).astype(np.int64)
        keys = np.column_stack([vobj, q])
        _, weld = np.unique(keys, axis=0, return_inverse=True)
        weld = weld.ravel()
        lw = weld[lv]
        nxt = np.arange(len(lv)) + 1
        nxt[ls + lt - 1] = ls
        lab = connected_components(int(weld.max()) + 1, lw, lw[nxt])
        fi = lab[lw[ls]]
        _, fi = np.unique(fi, return_inverse=True)
        self.fi = fi.ravel()
        self.n_isl = int(self.fi.max()) + 1
        self._island_tables()
        self._face_colors()

    def _island_tables(self):
        n = self.n_isl
        fi, fa = self.fi, self.fa
        self.ia = np.bincount(fi, weights=fa, minlength=n)
        self.inf = np.bincount(fi, minlength=n)
        w = np.maximum(self.ia, 1e-12)
        self.ic = np.stack([np.bincount(fi, weights=fa * self.fc[:, k], minlength=n) / w for k in range(3)], 1)
        loop_isl = np.repeat(fi, self.lt)
        pts = self.co[self.lv]
        self.imin = np.full((n, 3), np.inf)
        self.imax = np.full((n, 3), -np.inf)
        for k in range(3):
            np.minimum.at(self.imin[:, k], loop_isl, pts[:, k])
            np.maximum.at(self.imax[:, k], loop_isl, pts[:, k])
        # dominant material and object per island
        nm = len(self.mats)
        acc = np.zeros((n, nm))
        np.add.at(acc, (fi, self.fm), fa)
        self.imat = acc.argmax(1)
        self.iobj = np.zeros(n, dtype=np.int64)
        self.iobj[fi] = self.fo

    def _face_colors(self):
        """Per-face sRGB colour: material base colour, or the base-colour texture sampled at the face's UV centroid."""
        me = self.obj.data
        fcol = np.array([m["base"] for m in self.mats])[self.fm]
        if me.uv_layers:
            uv = np.empty(len(self.lv) * 2)
            me.uv_layers["UVMap"].data.foreach_get("uv", uv)
            uv = uv.reshape(-1, 2)
            fuv = np.add.reduceat(uv, self.ls, axis=0) / self.lt[:, None]
            for mi, m in enumerate(self.mats):
                if not m["base_tex"]:
                    continue
                img = bpy.data.images.get(m["base_tex"])
                arr = matinfo.image_small(img, 128) if img else None
                if arr is None:
                    continue
                sel = np.where(self.fm == mi)[0]
                u = np.mod(fuv[sel, 0], 1.0)
                v = np.mod(fuv[sel, 1], 1.0)
                h, w = arr.shape[:2]
                px = arr[np.clip((v * h).astype(int), 0, h - 1), np.clip((u * w).astype(int), 0, w - 1), :3]
                fcol[sel] = px
        self.fcol = fcol
        n = self.n_isl
        wa = np.maximum(self.ia, 1e-12)
        self.icol = np.stack([np.bincount(self.fi, weights=self.fa * fcol[:, k], minlength=n) / wa for k in range(3)], 1)

    def island_name(self, i) -> str:
        m = self.mats[self.imat[i]]
        return m["name"] + " | " + self.obj_paths[self.iobj[i]]

    # ------------------------------------------------------------------------------------- transform
    def transform(self, M: Matrix):
        me = self.obj.data
        me.transform(M)
        if M.determinant() < 0:
            me.flip_normals()
        me.update()
        self.refresh(islands=False)

    def bbox(self):
        return self.co.min(0), self.co.max(0)

    # ------------------------------------------------------------------------------------- orientation
    def orient(self):
        """Rotate so the car's length is along Y, front at +Y, up +Z.  Returns a report dict."""
        cfg = self.cfg
        rep = {}
        up = cfg.get("up", "+z").lower()
        if up != "+z":
            R = _axis_to_z(up)
            self.transform(R)
            rep["up_override"] = up
        lo, hi = self.bbox()
        ext = hi - lo
        length_axis = 0 if ext[0] > ext[1] else 1
        rep["length_axis"] = "XY"[length_axis]
        # move bbox centre to origin (XY), ground to z=0 for the voting below
        c = (lo + hi) / 2
        self.transform(Matrix.Translation(Vector((-c[0], -c[1], -lo[2]))))
        if length_axis == 0:  # rotate +90 about Z: X -> Y
            self.transform(Matrix.Rotation(math.pi / 2, 4, "Z"))
        votes = self._front_votes()
        rep["votes"] = {k: round(v, 3) for k, v in votes.items()}
        score = sum(votes.values())
        forced = cfg.get("front")
        if forced:
            # 'front' is given in the ORIGINAL file's Blender axes, e.g. "-y" for glTF assets (glTF front = +Z)
            ax = forced.lower()
            vec = {"+x": (1, 0, 0), "-x": (-1, 0, 0), "+y": (0, 1, 0), "-y": (0, -1, 0)}[ax]
            # after the optional rotation, where did that vector go?
            v = Vector(vec)
            if length_axis == 0:
                v = Matrix.Rotation(math.pi / 2, 3, "Z") @ v
            flip = v.y < 0
            rep["front_override"] = forced
        else:
            flip = score < 0
        if flip:
            self.transform(Matrix.Rotation(math.pi, 4, "Z"))
        rep["confidence"] = round(abs(score), 3)
        if not forced and abs(score) < 0.5:
            self.warnings.append(f"front/back detection is uncertain (score {score:.2f}); set 'front' in models.json")
        log("orientation:", rep)
        self.report["orientation"] = rep
        return rep

    def _front_votes(self):
        """Positive = front is at +Y.  Uses names, red tail-light colours, deck height, mirrors, cabin."""
        lo, hi = self.bbox()
        L = hi[1] - lo[1]
        H = hi[2] - lo[2]
        votes = {"names": 0.0, "red_lights": 0.0, "white_lights": 0.0, "deck_height": 0.0, "cabin": 0.0,
                 "mirrors": 0.0}
        # 1) names (per island, area weighted, normalised)
        tot = 0.0
        for i in range(self.n_isl):
            nm = self.island_name(i)
            f = kw_match(nm, KW_FRONT)
            r = kw_match(nm, KW_REAR)
            if bool(f) == bool(r):
                continue
            y = self.ic[i, 1] / (L / 2)
            w = math.sqrt(self.ia[i]) * min(1.0, abs(y) * 2)
            votes["names"] += (w if f else -w) * np.sign(y)
            tot += w
        if tot > 0:
            votes["names"] = 3.0 * votes["names"] / tot
        # 2) colours at the ends: red/amber-red light colours => rear ; bright white/blue-white emissive => front
        y = self.fc[:, 1] / (L / 2)
        end = np.abs(y) > 0.70
        z_ok = (self.fc[:, 2] > 0.25 * H) & (self.fc[:, 2] < 0.85 * H)
        emis = np.array([m["emission"] for m in self.mats])[self.fm]
        erg = np.array([m["emission_rgb"] for m in self.mats])[self.fm]
        col = self.fcol.copy()
        lit = emis > 0.1
        col[lit] = erg[lit] / np.maximum(erg[lit].max(1, keepdims=True), 1e-6)
        mx = col.max(1)
        mn = col.min(1)
        sat = (mx - mn) / np.maximum(mx, 1e-6)
        red = (col[:, 0] > 0.35) & (sat > 0.55) & (col[:, 1] < 0.45 * col[:, 0]) & (col[:, 2] < 0.5 * col[:, 0])
        # a red car makes this vote meaningless: ignore materials covering >20% of the surface, and skip
        # entirely when the dominant (area-weighted) colour is itself red
        mat_area = np.bincount(self.fm, weights=self.fa, minlength=len(self.mats))
        big = (mat_area / max(mat_area.sum(), 1e-9))[self.fm] > 0.2
        dom = np.median(self.fcol[np.argsort(-self.fa)[: max(10, len(self.fa) // 4)]], axis=0)
        dom_red = dom[0] > 0.3 and dom[1] < 0.5 * dom[0] and dom[2] < 0.6 * dom[0]
        sel = end & z_ok & red & (~big | lit)
        a = self.fa[sel]
        if a.sum() > 0 and not (dom_red and not lit[sel].any()):
            s = (a * np.sign(y[sel])).sum() / a.sum()
            frac = a.sum() / max(self.fa[end & z_ok].sum(), 1e-9)
            votes["red_lights"] = -2.5 * s * min(1.0, frac * 20)
        whit = end & z_ok & (emis > 0.5) & ~red
        if self.fa[whit].sum() > 0:
            votes["white_lights"] = 1.5 * (self.fa[whit] * np.sign(y[whit])).sum() / self.fa[whit].sum()
        # 3) deck height: the taller end is usually the rear (sedans, hatches, vans, mid-engine cars)
        hf = self._end_height(+1)
        hr = self._end_height(-1)
        if hf and hr:
            d = (hr - hf) / H  # >0 means -Y end taller -> front at +Y
            votes["deck_height"] = float(np.clip(d * 6, -0.8, 0.8))
        # 4) cabin/roof peak sits behind the middle on front-engine cars
        top = self.fc[:, 2] > 0.92 * H
        if self.fa[top].sum() > 0:
            ry = (self.fa[top] * self.fc[top, 1]).sum() / self.fa[top].sum() / (L / 2)
            votes["cabin"] = float(np.clip(-ry * 3, -0.6, 0.6))
        # 5) side mirrors: widest points above the beltline sit at the front of the side windows
        W = hi[0] - lo[0]
        band = (self.fc[:, 2] > 0.55 * H) & (self.fc[:, 2] < 0.85 * H)
        if band.sum() > 10:
            xs = np.abs(self.fc[band, 0])
            thr = np.quantile(xs, 0.995)
            far = band.copy()
            far[band] = xs >= thr
            if far.sum() > 0 and thr > 0.40 * W:
                my = self.fc[far, 1].mean() / (L / 2)
                cab = self.fc[band, 1].mean() / (L / 2)
                if abs(my - cab) > 0.05:
                    votes["mirrors"] = float(np.clip((my - cab) * 4, -1.2, 1.2))
        return votes

    def _end_height(self, sign):
        lo, hi = self.bbox()
        L = hi[1] - lo[1]
        y = self.fc[:, 1] * sign
        sel = y > (L / 2) * 0.80
        if sel.sum() < 3:
            return None
        return float(np.quantile(self.fc[sel, 2], 0.95))

    # ------------------------------------------------------------------------------------- scale + wheels
    def find_wheels(self):
        """Detect wheels in the canonical frame. Returns list of dicts (center, radius, width, islands, name)."""
        lo, hi = self.bbox()
        W, L, H = hi - lo  # canonical frame: x = width, y = length, z = height
        ext = self.imax - self.imin
        cen = (self.imax + self.imin) / 2
        named = np.array([bool(kw_match(self.island_name(i), KW_WHEEL)) and
                          not kw_match(self.island_name(i), KW_INTERIOR) for i in range(self.n_isl)])
        dia = np.maximum(ext[:, 1], ext[:, 2])
        disc = (np.abs(ext[:, 1] - ext[:, 2]) < 0.2 * dia) & (ext[:, 0] < 0.9 * dia) & \
               (dia > 0.08 * L) & (dia < 0.34 * L) & (cen[:, 2] < 0.5 * H) & (np.abs(cen[:, 0]) > 0.18 * W) & \
               (np.abs(cen[:, 1]) > 0.12 * L)
        # steered front wheels: y extent inflated, use z extent as the diameter
        cand = np.where(disc | (named & (ext[:, 2] > 0.06 * L) & (cen[:, 2] < 0.5 * H) &
                                (ext[:, 1] < 1.35 * ext[:, 2]) & (np.abs(cen[:, 0]) > 0.15 * W)))[0]
        if len(cand) == 0:
            self.warnings.append("no wheel-like geometry found")
            return []
        # group candidates by side and by axle (y clusters)
        wheels = []
        for side in (-1, 1):
            cs = [i for i in cand if np.sign(cen[i, 0]) == side]
            cs.sort(key=lambda i: -ext[i, 2])
            used = []
            for i in cs:
                c = cen[i]
                if any(abs(c[1] - w["center"][1]) < 0.6 * w["radius"] * 2 for w in used):
                    continue
                r = ext[i, 2] / 2
                used.append({"center": c.copy(), "radius": float(r), "side": side, "seed": int(i)})
            wheels += used
        # keep wheels whose radius is close to the biggest (drops spare wheels / steering wheels / odd discs)
        if not wheels:
            return []
        rmax = max(w["radius"] for w in wheels)
        wheels = [w for w in wheels if w["radius"] > 0.6 * rmax and w["center"][2] < 1.6 * w["radius"] + 0.02 * H]
        # need a pair on each side; pair up axles by y
        ys = sorted(set(round(float(w["center"][1]) / (0.25 * L)) for w in wheels))
        _ = ys
        wheels.sort(key=lambda w: (-w["center"][1], w["side"]))
        # assign wheel islands: anything fully inside the wheel's cylinder
        for wi, w in enumerate(wheels):
            c = w["center"]
            r = w["radius"]
            seed = w["seed"]
            # axle direction: x (after orient).  Measure true width from the seed island
            half_w = ext[seed, 0] / 2
            inner_margin = max(0.35 * r, half_w)
            xin = c[0] - side_sign(w) * (half_w + inner_margin)
            xout = c[0] + side_sign(w) * (half_w + 0.15 * r)
            x0, x1 = min(xin, xout), max(xin, xout)
            dy = np.maximum(np.abs(self.imin[:, 1] - c[1]), np.abs(self.imax[:, 1] - c[1]))
            dz = np.maximum(np.abs(self.imin[:, 2] - c[2]), np.abs(self.imax[:, 2] - c[2]))
            inside = (self.imin[:, 0] >= x0) & (self.imax[:, 0] <= x1) & (dy <= 1.08 * r) & (dz <= 1.08 * r) & \
                     (np.hypot(cen[:, 1] - c[1], cen[:, 2] - c[2]) < 0.9 * r)
            isl = set(np.where(inside)[0].tolist()) | {seed}
            # calipers do not spin: leave them on the body
            isl = {i for i in isl if not kw_match(self.island_name(i), KW_CALIPER)}
            w["islands"] = sorted(isl)
            w["width"] = float(2 * half_w)
        # name them
        if len(wheels) >= 2:
            ys = sorted({round(float(w["center"][1]), 3) for w in wheels}, reverse=True)
            front_y = max(w["center"][1] for w in wheels)
            rear_y = min(w["center"][1] for w in wheels)
            for w in wheels:
                lr = "L" if w["side"] < 0 else "R"
                if abs(w["center"][1] - front_y) < 0.25 * w["radius"] * 2:
                    w["name"] = "WheelF" + lr
                elif abs(w["center"][1] - rear_y) < 0.25 * w["radius"] * 2:
                    w["name"] = "WheelR" + lr
                else:
                    w["name"] = "WheelM" + lr
            names = [w["name"] for w in wheels]
            for nm in set(names):
                dup = [w for w in wheels if w["name"] == nm]
                if len(dup) > 1:
                    dup.sort(key=lambda w: -w["center"][1])
                    for k, w in enumerate(dup):
                        w["name"] = f"{nm}{k + 1}"
        if len(wheels) != 4:
            self.warnings.append(f"found {len(wheels)} wheels (expected 4)" +
                                 ("; several cars in one file? set 'select' in the model config" if len(wheels) > 6 else ""))
        for w in wheels:
            log(f"wheel {w.get('name')}: c={np.round(w['center'], 3)} r={w['radius']:.3f} w={w['width']:.3f} "
                f"islands={len(w['islands'])}")
        self.wheels = wheels
        return wheels

    def unsteer_wheels(self):
        """Front wheels are often modelled steered.  Measure each wheel's axle with PCA and rotate it straight."""
        me = self.obj.data
        fixed = 0
        for w in self.wheels:
            fsel = np.isin(self.fi, w["islands"])
            vids = np.unique(self.lv[np.repeat(fsel, self.lt)])
            if len(vids) < 12:
                continue
            p = self.co[vids] - w["center"]
            # axle = direction of least spread of the (ring-shaped) wheel in the ground plane
            cov = np.cov(p[:, :2].T)
            ev, evec = np.linalg.eigh(cov)
            ax = evec[:, 0]
            ang = math.atan2(ax[1], ax[0])
            if ang > math.pi / 2:
                ang -= math.pi
            if ang < -math.pi / 2:
                ang += math.pi
            if abs(math.degrees(ang)) < 1.5 or abs(math.degrees(ang)) > 40 or ev[1] < 1.5 * ev[0]:
                continue
            R = Matrix.Rotation(-ang, 3, "Z")
            Rn = np.array(R)
            q = (Rn @ p.T).T + w["center"]
            self.co[vids] = q
            fixed += 1
            log(f"unsteered {w['name']} by {math.degrees(ang):.1f} deg")
        if fixed:
            me.vertices.foreach_set("co", self.co.astype(np.float32).ravel())
            me.update()
            self.refresh(islands=False)
            for w in self.wheels:  # recompute centres/extents from the straightened islands
                isl = w["islands"]
                mn = self.imin[isl].min(0)
                mx = self.imax[isl].max(0)
                w["center"] = (mn + mx) / 2 if w["seed"] not in isl else (self.imin[w["seed"]] + self.imax[w["seed"]]) / 2
                w["width"] = float(self.imax[w["seed"], 0] - self.imin[w["seed"], 0])

    def ground_and_scale(self, target_length: float):
        """Translate so wheel contact = z0 and wheelbase centre = origin; uniform scale to target length."""
        lo, hi = self.bbox()
        if getattr(self, "wheels", None):
            ground = float(np.mean([w["center"][2] - w["radius"] for w in self.wheels]))
            cx = float(np.mean([w["center"][0] for w in self.wheels]))
            cy = float((max(w["center"][1] for w in self.wheels) + min(w["center"][1] for w in self.wheels)) / 2)
        else:
            ground, cx, cy = float(lo[2]), float((lo[0] + hi[0]) / 2), float((lo[1] + hi[1]) / 2)
        L = hi[1] - lo[1]
        s = target_length / L
        M = Matrix.Scale(s, 4) @ Matrix.Translation(Vector((-cx, -cy, -ground)))
        self.transform(M)
        for w in getattr(self, "wheels", []):
            c = Vector(w["center"])
            w["center"] = np.array(M @ c)
            w["radius"] *= s
            w["width"] *= s
        self.report["scale"] = {"source_length": float(L), "factor": float(s), "target_length": target_length}
        log(f"scaled x{s:.4f} (source length {L:.3f} -> {target_length} studs)")
        return s

    # ------------------------------------------------------------------------------------- visibility
    def _drop_overlay_shells(self, role, why):
        """Two big islands with (almost) the same bounding box and area but different materials: the one whose
        material is black/transparent & glossy is a clear-coat or reflection overlay -> discard."""
        big = np.where(self.ia > 0.01 * self.ia.sum())[0]
        for a in big:
            for b in big:
                if a >= b or self.imat[a] == self.imat[b] or role[a] == DISCARD or role[b] == DISCARD:
                    continue
                if not (0.75 < self.ia[a] / self.ia[b] < 1.33):
                    continue
                ea = self.imax[a] - self.imin[a]
                diff = np.abs(self.imax[a] - self.imax[b]) + np.abs(self.imin[a] - self.imin[b])
                if diff.max() > 0.03 * ea.max():
                    continue
                for k in (a, b):
                    m = self.mats[self.imat[k]]
                    lum = sum(m["base"]) / 3
                    if (m["alpha"] < 0.9 or m["transmission"] > 0.3 or (lum < 0.06 and m["roughness"] < 0.12)
                            or kw_match(m["name"], [r"clear_?coat", r"reflect", r"overlay", r"_shell_?fx"])):
                        role[k] = DISCARD
                        why[k] = "overlay-shell"
                        log(f"overlay shell dropped: {self.island_name(k)}")
                        break

    def visibility(self, glass_mask_faces, gone_mask_faces=None):
        """Per island: 2 = visible from outside, 1 = only visible through glass, 0 = hidden."""
        lo, hi = self.bbox()
        diag = float(np.linalg.norm(hi - lo))
        verts = [tuple(v) for v in self.co.tolist()]
        polys_all = np.split(self.lv, self.ls[1:])
        polys_all = [p.tolist() for p in polys_all]
        gone = np.zeros(len(polys_all), bool) if gone_mask_faces is None else gone_mask_faces
        bvh_all = BVHTree.FromPolygons(verts, [polys_all[i] for i in np.where(~gone)[0]], all_triangles=False,
                                       epsilon=0.0)
        keep = np.where(~glass_mask_faces & ~gone)[0]
        bvh_ng = BVHTree.FromPolygons(verts, [polys_all[i] for i in keep], all_triangles=False, epsilon=0.0)
        dirs = _fib_dirs(40)
        rng = np.random.default_rng(7)
        eps = diag * 2e-4
        vis = np.zeros(self.n_isl, dtype=np.int8)
        order = np.argsort(self.fi, kind="stable")
        starts = np.searchsorted(self.fi[order], np.arange(self.n_isl))
        ends = np.append(starts[1:], len(order))
        tot_area = self.ia.sum()
        for i in range(self.n_isl):
            faces = order[starts[i]:ends[i]]
            if len(faces) == 0:
                continue
            k = int(np.clip(round(self.ia[i] / tot_area * 3000), 4, 40))
            k = min(k, len(faces))
            p = self.fa[faces] / max(self.fa[faces].sum(), 1e-12)
            pick = rng.choice(faces, size=k, replace=False, p=p) if len(faces) > k else faces
            seen_ng = False
            seen_all = False
            for f in pick:
                c = Vector(self.fc[f])
                n = Vector(self.fn[f])
                for d in dirs:
                    side = 1.0 if d.dot(n) >= 0 else -1.0
                    o = c + n * (eps * side) + d * eps
                    if not seen_all:
                        if bvh_all.ray_cast(o, d, diag * 2)[0] is None:
                            seen_all = seen_ng = True
                            break
                    if not seen_ng:
                        if bvh_ng.ray_cast(o, d, diag * 2)[0] is None:
                            seen_ng = True
                if seen_all:
                    break
            vis[i] = 2 if seen_all else (1 if seen_ng else 0)
        return vis

    # ------------------------------------------------------------------------------------- classification
    def classify(self):
        n = self.n_isl
        role = np.full(n, UNK, dtype=np.int32)
        why = [""] * n
        cfg_roles = self.cfg.get("roles", {})  # {"regex": "Body"|"Glass"|...}
        inv = {v.lower(): k for k, v in ROLE_NAMES.items()}
        # wheels first
        for wi, w in enumerate(getattr(self, "wheels", [])):
            for i in w["islands"]:
                role[i] = WHEEL0 + wi
                why[i] = "wheel-cylinder"
        lo, hi = self.bbox()
        W, L, H = hi - lo  # canonical frame: x = width, y = length, z = height
        for i in range(n):
            if role[i] >= WHEEL0:
                continue
            m = self.mats[self.imat[i]]
            nm_mat = m["name"]
            nm_obj = self.obj_paths[self.iobj[i]]
            full = nm_mat + " " + nm_obj
            hit = None
            for rx, rn in cfg_roles.items():
                if re.search(rx, full, re.I):
                    hit = inv.get(rn.lower())
                    why[i] = f"cfg:{rx}"
                    break
            if hit is None:
                rm = self._role_from_name(nm_mat) if not m["generic"] else None
                ro = self._role_from_name(nm_obj)
                if rm is not None and not (rm == BODY and not kw_match(nm_mat, KW_PAINT_STRONG)
                                           and ro in (INTERIOR, GLASS, LIGHT_F, DISCARD)):
                    hit, why[i] = rm, f"mat:{nm_mat[:30]}"
                elif ro is not None:
                    hit, why[i] = ro, f"obj:{nm_obj[:30]}"
                elif rm is not None:
                    hit, why[i] = rm, f"mat:{nm_mat[:30]}"
            if hit is None:
                hit = self._role_from_props(m)
                if hit is not None:
                    why[i] = "props"
            if hit is not None:
                role[i] = hit
        # props override: a "light" island whose material is clearly transparent stays light (lens);
        # a "glass" island with strong emission becomes light
        for i in range(n):
            m = self.mats[self.imat[i]]
            if role[i] == GLASS and m["emission"] > 1.0:
                role[i] = LIGHT_F
        # overlay shells (clear-coat / reflection duplicates of the body) would hide the real paint
        self._drop_overlay_shells(role, why)
        # visibility pass (named discards are not occluders)
        glass_faces = np.isin(self.fi, np.where(role == GLASS)[0])
        gone = np.isin(self.fi, np.where(role == DISCARD)[0])
        vis = self.visibility(glass_faces, gone)
        self.vis = vis
        for i in range(n):
            if role[i] >= WHEEL0:
                continue
            if vis[i] == 0 and role[i] not in (GLASS,):
                role[i] = DISCARD
                why[i] += " hidden"
            elif vis[i] == 1 and role[i] in (UNK, TRIM, BODY):
                if role[i] == BODY and self.ia[i] > 0.02 * self.ia.sum():
                    continue
                role[i] = INTERIOR
                why[i] += " behind-glass"
            elif vis[i] == 0 and role[i] == GLASS:
                role[i] = DISCARD
        # front/rear lights
        for i in range(n):
            if role[i] == LIGHT_F:
                role[i] = LIGHT_F if self.ic[i, 1] >= 0 else LIGHT_R
        # paint selection
        self._choose_paint(role, why)
        # leftovers -> trim
        role[role == UNK] = TRIM
        self.irole = role
        self.iwhy = why
        self.frole = role[self.fi]
        # stats
        stats = {}
        for r in np.unique(role):
            sel = role == r
            stats[self.role_name(r)] = {"islands": int(sel.sum()), "faces": int(self.inf[sel].sum()),
                                        "area": round(float(self.ia[sel].sum()), 3)}
        self.report["classes"] = stats
        log("classes:", {k: (v["islands"], v["faces"]) for k, v in stats.items()})

    def role_name(self, r):
        if r >= WHEEL0:
            return self.wheels[r - WHEEL0]["name"]
        return ROLE_NAMES[r]

    @staticmethod
    def _role_from_name(s):
        if kw_match(s, KW_DISCARD):
            return DISCARD
        if kw_match(s, KW_INTERIOR):
            return INTERIOR
        if kw_match(s, KW_TRIM_STRONG):
            return TRIM
        if kw_match(s, KW_GLASS) and not kw_match(s, KW_LIGHT):
            return GLASS
        if kw_match(s, KW_LIGHT):
            return LIGHT_F
        if kw_match(s, KW_TRIM) or kw_match(s, KW_WHEEL):
            return TRIM
        if kw_match(s, KW_PAINT):
            return BODY
        return None

    @staticmethod
    def _role_from_props(m):
        if m["transmission"] >= 0.5 or m["alpha"] <= 0.6:
            return GLASS
        if m["emission"] >= 0.6:
            return LIGHT_F
        lum = 0.2126 * m["base"][0] + 0.7152 * m["base"][1] + 0.0722 * m["base"][2]
        if m["metallic"] >= 0.8 and m["roughness"] <= 0.35 and lum > 0.45 and not m["base_tex"]:
            return TRIM
        return None

    def _choose_paint(self, role, why):
        """Primary paint = the BODY-named (or, failing that, the largest UNKNOWN) material by visible area."""
        nm = len(self.mats)
        area_by_mat = np.zeros(nm)
        cand = (role == BODY)
        if self.ia[cand].sum() < 0.05 * self.ia[role < WHEEL0].sum():
            cand = cand | (role == UNK)
        cand_isl = np.where(cand & (self.vis == 2))[0]
        np.add.at(area_by_mat, self.imat[cand_isl], self.ia[cand_isl])
        if area_by_mat.max() <= 0:
            self.warnings.append("no paint surface found")
            return
        order = np.argsort(-area_by_mat)
        primary = int(order[0])
        secondary = None
        if len(order) > 1 and area_by_mat[order[1]] > 0.10 * area_by_mat[primary]:
            m2 = self.mats[order[1]]
            if kw_match(m2["name"], KW_PAINT) and not m2["generic"]:
                secondary = int(order[1])
        for i in range(self.n_isl):
            if role[i] in (BODY, UNK):
                if self.imat[i] == primary:
                    role[i] = BODY
                elif secondary is not None and self.imat[i] == secondary:
                    role[i] = BODY2
                else:
                    role[i] = TRIM
        pm = self.mats[primary]
        self.paint = {"material": pm["name"], "color_srgb": [round(c, 4) for c in pm["base"]],
                      "textured": bool(pm["base_tex"]), "metallic": pm["metallic"], "roughness": pm["roughness"]}
        if secondary is not None:
            sm = self.mats[secondary]
            self.paint2 = {"material": sm["name"], "color_srgb": [round(c, 4) for c in sm["base"]],
                           "textured": bool(sm["base_tex"]), "metallic": sm["metallic"], "roughness": sm["roughness"]}
        else:
            self.paint2 = None
        log("paint:", self.paint, "secondary:", self.paint2 and self.paint2["material"])

    def debug_dump(self, path):
        lines = []
        for i in np.argsort(-self.ia):
            lines.append(f"{self.role_name(self.irole[i]):12s} vis={self.vis[i]} faces={self.inf[i]:6d} "
                         f"area={self.ia[i]:8.3f} c={np.round(self.ic[i], 2)} why={self.iwhy[i]} :: {self.island_name(i)}")
        with open(path, "w") as f:
            f.write("\n".join(lines))


def side_sign(w):
    return w["side"]


def _axis_to_z(up):
    up = up.lower()
    if up == "+y":
        return Matrix.Rotation(math.pi / 2, 4, "X")
    if up == "-y":
        return Matrix.Rotation(-math.pi / 2, 4, "X")
    if up == "+x":
        return Matrix.Rotation(-math.pi / 2, 4, "Y")
    if up == "-x":
        return Matrix.Rotation(math.pi / 2, 4, "Y")
    if up == "-z":
        return Matrix.Rotation(math.pi, 4, "X")
    return Matrix.Identity(4)
