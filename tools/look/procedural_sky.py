#!/usr/bin/env python3
"""Procedural night and blue-hour skies, pre-compensated for what the engine does to a skybox at the held night clock
(backlog item 14; the diagnosis is in docs/v2/research/lighting_lab.md, round 5).

Why procedural and why pre-compensated
  LightingService holds Lighting.ClockTime at 18.2 / 5.8 (engine sun -3 deg) all night and fakes the night with the
  presets (Look.EngineClock). At that clock the engine renders the skybox about 50x darker than by day and strongly red.
  Measured on job 0009's diag_night_exposure2_overview (night faces loaded, Exposure +2; `calibrate` below), after
  undoing that shot's ColorCorrection:  rendered_lin = g * face_lin  with  g ~ (R 0.20, G 0.077, B 0.073):
    * R/G ~2.7 on the anti-sun side, falling to ~1.75 at 100 deg from the sun;
    * B/G ~1.08 near the horizon, ~0.77 at 20-30 deg (less blue higher up);
    * G is flat (0.075-0.087) everywhere it was measured.
  So the navy-grey HDRI (faces R < G < B) rendered reddish-brown, and the blue grade cannot pull it back without turning
  the whole city blue. Here every face is the INVERSE of that transfer applied to the look we want on screen (the
  target, display sRGB after the preset's ColorCorrection). A deep blue night therefore needs a face that looks icy
  cyan-blue on its own; the engine's red cast turns it back into blue. A clean gradient, not a photo: the engine dims the
  sky so far that photo detail (clouds) is lost anyway, and a gradient has no colour noise to go muddy.

  The ceiling: a white face renders at most ~(60, 35, 40) at the night state and ~(55, 40, 42) at the blue hour (G and
  B are the limits). Targets stay under it; a pixel that would still clip is scaled down as a whole (hue kept).

Skies (six 1024 px faces each, the engine-verified mapping of hdri_to_skybox.py; one shared Dn face):
  night      clear night: blue-black zenith, cool blue-grey horizon, subtle stars, faint warm city glow at sky azimuth 90
             (= +X: the night sky does not follow the sun; LightingService parks horizonGlowAzimuth on +X, inland)
  nightMild  the same target, compensated at MILD_STRENGTH (A/B in job 0012: Workspace "SkyOverride" = "nightMild")
  blue       dusk: amber glow on the sun side (sky azimuth 0 = glowAzimuth, kept on the engine sun), pink belt opposite,
             deep blue zenith, a few first stars
  dawn       dawn: the same build, peach / pink instead of amber

Commands
  python3 -I tools/look/procedural_sky.py [--only night,blue] [--evidence]
      faces -> assets/sky/<sky>/{ft,bk,lf,rt,up,dn}.png (dn = assets/sky/shared/dn_twilight.png for every sky here),
      metadata -> assets/sky/skies.json (other skies untouched), previews -> docs/v2/evidence/look_night/
  python3 -I tools/look/procedural_sky.py calibrate --shot <png> --faces <dir> --yaw <deg> --exposure <EV>
      --tint R,G,B --contrast C --saturation S [--camera x,y,z,lx,ly,lz] [--clock 18.2]
      refits the engine transfer from a real-engine screenshot of a known sky (job 0012 can re-run it on new shots).
"""

import argparse
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

import hdri_to_skybox as hs  # noqa: E402
import lookcommon as lc  # noqa: E402

FACE = 1024
EVIDENCE_DIR = os.path.join(lc.ROOT, "docs", "v2", "evidence", "look_night")
SHARED_DN = os.path.join(lc.SKY_DIR, "shared", "dn_twilight.png")

# ---------------------------------------------------------------------------------------------------------------
# The engine transfer at the held clock (sun -3 deg), measured (see the docstring and `calibrate`)
# ---------------------------------------------------------------------------------------------------------------

# rendered_lin_c = A_c * face_lin_c ** gamma, with A_c = A_c(ref_ev) * 2 ** (gamma * (EV - ref_ev)) (the exposure acts
# before the tone curve that makes gamma > 1) and A = G * (rg, 1, bg). Fitted on job 0009's diag shot (`calibrate`):
# gamma 1.2-1.35 fits the brightness bins best and also covers part of the chroma gain the shot shows (inside narrow
# windows the rendered log R/G moves ~1.5x as much as the face's). Measured over 3-26 deg elevation and 115-175 deg from
# the sun only: the zenith and the sun side are extrapolated (they are what job 0012 must look at).
ENGINE = dict(
    ref_ev=2.0,  # the calibration shot's ExposureCompensation
    gamma=1.35,
    # s = smoothstep(psi0, psi1, degrees from the engine sun): 0 on the sun's side, 1 anti-sun
    psi0=90.0,
    psi1=150.0,
    g_high=0.142,  # G well above the horizon, anti-sun (0.143-0.151 at 16-26 deg, 125-180 deg from the sun)
    g_low=0.022,  # extra G at the horizon (0.161-0.172 at 2-8 deg), fading over g_scale deg above 4 deg
    g_scale=10.0,
    g_sun=0.45,  # G x (1 + g_sun) on the sun's side (0.19 at 100-125 deg, 0.23 at 60-100 deg)
    rg_near=1.85,  # R/G on the sun's side (1.81 at 60-100 deg, 2.27-2.34 at 100-125 deg) ...
    rg_far=2.80,  # ... and anti-sun (2.71-2.85)
    bg_near=0.70,  # B/G well above the horizon, sun's side (0.71-0.72) ...
    bg_far=0.85,  # ... and anti-sun (0.88)
    bg_low=0.22,  # extra B/G at the horizon (1.01-1.08 at 2-8 deg), fading over bg_scale deg above 4 deg
    bg_scale=13.0,
)
MILD_STRENGTH = 0.7  # nightMild: the cast's colour ratios raised to this power (70 % of the compensation, in log space)
HOLD_ELEVATION = -3.0  # deg, both engine-clock holds (Look.EngineClock)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def sun_dir(clock, latitude=34.0, tilt=23.5):
    """The engine sun at an ENGINE ClockTime (Look.Sun model, measured)."""
    phi = math.radians(latitude - tilt)
    th = math.radians(15.0 * (clock - 6.0))
    return np.array([math.cos(phi) * math.cos(th), math.cos(phi) * math.sin(th), math.sin(phi)], np.float32)


def dir_from(az_deg, el_deg):
    """Unit direction from azimuth (0 = -Z, 90 = +X) and elevation, degrees."""
    a, e = np.radians(az_deg), np.radians(el_deg)
    return np.stack([np.cos(e) * np.sin(a), np.sin(e) * np.ones_like(a), -np.cos(e) * np.cos(a)], -1).astype(np.float32)


def elevation(dirs):
    return np.degrees(np.arcsin(np.clip(dirs[..., 1], -1, 1)))


def azimuth(dirs):
    return np.degrees(np.arctan2(dirs[..., 0], -dirs[..., 2]))


def engine_gain(dirs, sun, ev, strength=1.0):
    """Per-channel A_c of the engine transfer (rendered_lin = A_c * face_lin ** gamma, before the ColorCorrection) for
    face texels seen in `dirs` (sun = engine sun direction, ev = ExposureCompensation). strength < 1 keeps only that
    share of the colour cast (log space): used to build a less compensated variant, never to simulate."""
    E = ENGINE
    psi = np.degrees(np.arccos(np.clip((dirs * sun).sum(-1), -1, 1)))
    above = np.clip(elevation(dirs) - 4.0, 0, None)
    s = smoothstep(E["psi0"], E["psi1"], psi)
    g = (E["g_high"] + E["g_low"] * np.exp(-above / E["g_scale"])) * (1 + E["g_sun"] * (1 - s))
    rg = E["rg_near"] + (E["rg_far"] - E["rg_near"]) * s
    bg = E["bg_near"] + (E["bg_far"] - E["bg_near"]) * s + E["bg_low"] * np.exp(-above / E["bg_scale"])
    ratio = np.stack([rg, np.ones_like(rg), bg], -1) ** strength
    return (g[..., None] * 2.0 ** (E["gamma"] * (ev - E["ref_ev"])) * ratio).astype(np.float32)


# ---------------------------------------------------------------------------------------------------------------
# ColorCorrection (assumed order: tint, saturation, contrast about 0.5, all in display space; the calibration used the
# same order, so it is self-consistent)
# ---------------------------------------------------------------------------------------------------------------

LUMA601 = np.array([0.299, 0.587, 0.114], np.float32)


def grade(x, g):
    x = x * (np.array(g["tint"], np.float32) / 255.0)
    lum = (x * LUMA601).sum(-1, keepdims=True)
    x = lum + (x - lum) * (1 + g["saturation"])
    x = (x - 0.5) * (1 + g["contrast"]) + 0.5
    return np.clip(x, 0, 1)


def ungrade(d, g):
    x = (d - 0.5) / (1 + g["contrast"]) + 0.5
    lum = (x * LUMA601).sum(-1, keepdims=True)
    x = lum + (x - lum) / (1 + g["saturation"])
    return x / (np.array(g["tint"], np.float32) / 255.0)


def forward(face_srgb, gain, g):
    """Face texels (sRGB 0..1) -> what the frame shows (display sRGB 0..1)."""
    lin = gain * lc.srgb_to_linear(face_srgb) ** ENGINE["gamma"]
    return grade(lc.linear_to_srgb(np.clip(lin, 0, 1)), g)


def inverse(target_srgb, gain, g):
    """Wanted display sRGB -> face sRGB, and the share of pixels over the ceiling (a white face). Those are scaled down
    as a whole in face space, which scales the rendered colour uniformly too: the hue is kept, only darker."""
    need = (lc.srgb_to_linear(np.clip(ungrade(target_srgb, g), 0, 1)) / gain) ** (1.0 / ENGINE["gamma"])
    peak = need.max(-1, keepdims=True)
    over = peak > 1.0
    need = np.where(over, need / np.maximum(peak, 1e-6), need)
    return lc.linear_to_srgb(np.clip(need, 0, 1)), float(over.mean())


# ---------------------------------------------------------------------------------------------------------------
# Render states (the presets at a reference GAME hour, from Config/Look via tools/look/export_look.luau)
# ---------------------------------------------------------------------------------------------------------------

_LOOK = None


def look_data():
    global _LOOK
    if _LOOK is None:
        out = subprocess.run(["lune", "run", "tools/look/export_look.luau"], cwd=lc.ROOT, capture_output=True,
                             text=True, check=True)
        _LOOK = json.loads(out.stdout)
    return _LOOK


def _lerp(a, b, t):
    if isinstance(a, (int, float)):
        return a + (b - a) * t
    if isinstance(a, list):
        return [_lerp(x, y, t) for x, y in zip(a, b)]
    return {k: _lerp(a[k], b[k], t) for k in a}


def preset_at(hour):
    """LightingService.lookAt without the caps / overrides, plus the swap dip (same maths)."""
    L = look_data()
    keys = L["Keys"]
    a, b = keys[0], keys[-1]
    for i in range(len(keys) - 1):
        if keys[i]["hour"] <= hour <= keys[i + 1]["hour"]:
            a, b = keys[i], keys[i + 1]
            break
    span = b["hour"] - a["hour"]
    t = (hour - a["hour"]) / span if span > 0 else 0.0
    t = t * t * (3 - 2 * t)
    p = _lerp(L["Presets"][a["preset"]], L["Presets"][b["preset"]], t)
    swap = L["SkySwap"]
    dips = [(swap["exposureDip"], L["EngineClock"]["jumpHour"])]
    dips += [(e.get("dip", swap["exposureDip"]), e["hour"]) for e in L["SkySchedule"]]
    best = 0.0
    for depth, at in dips:
        d = abs(hour - at % 24)
        d = min(d, 24 - d)
        best = max(best, depth * math.exp(-(d / swap["width"]) ** 2))
    p["exposure"] -= best
    return p


def state(hour, clock):
    """Exposure + grade at a game hour, the engine sun at an engine clock."""
    p = preset_at(hour)
    cc = p["colorCorrection"]
    return dict(ev=p["exposure"], sun=sun_dir(clock), grade=dict(tint=cc["tint"], saturation=cc["saturation"],
                                                                 contrast=cc["contrast"]), hour=hour, clock=clock)


# ---------------------------------------------------------------------------------------------------------------
# Targets (display sRGB 0..255 control colours, blended in linear light)
# ---------------------------------------------------------------------------------------------------------------


def L(c):
    return lc.srgb_to_linear(np.array(c, np.float32) / 255.0)


def two_scale(el, zen, mid, hor, a=4.0, b=24.0, at=12.0):
    """Smooth vertical gradient in linear light: c(el) = zen + A e^(-el/a) + B e^(-el/b), with c(0) = hor and
    c(at) = mid (per channel). zen / mid / hor are linear colours broadcastable to el."""
    ea, eb = math.exp(-at / a), math.exp(-at / b)
    # solve A + B = hor - zen ; A ea + B eb = mid - zen. A negative B (a bright horizon over a darker `mid`, e.g. the
    # amber glow under a blue sky) would dip below the zenith colour above the glow: clamp it (mid is then approximate)
    B = np.clip(((mid - zen) - (hor - zen) * ea) / (eb - ea), 0, None)
    A = (hor - zen) - B
    e = np.clip(el, 0, None)[..., None]
    return zen + A * np.exp(-e / a) + B * np.exp(-e / b)


def soft_noise(dirs, seed, waves=14, fmin=0.8, fmax=3.0):
    """Smooth, isotropic, low-frequency variation of a direction (seamless on the cube by construction; no lattice, so
    no blocky cells or blob outlines), about -1..1: a sum of random plane waves over the unit sphere."""
    rng = np.random.default_rng(seed)
    k = rng.normal(size=(waves, 3)).astype(np.float32)
    k /= np.linalg.norm(k, axis=1, keepdims=True)
    f = rng.uniform(fmin, fmax, waves).astype(np.float32) * 2 * np.pi
    ph = rng.uniform(0, 2 * np.pi, waves).astype(np.float32)
    out = np.zeros(dirs.shape[:-1], np.float32)
    for i in range(waves):
        out += np.cos(f[i] * (dirs @ k[i]) + ph[i])
    return out * math.sqrt(2.0 / waves)


def stars(n, seed):
    rng = np.random.default_rng(seed)
    v = rng.normal(size=(n, 3)).astype(np.float32)
    v /= np.linalg.norm(v, axis=1, keepdims=True)
    m = rng.random(n) ** 3  # mostly faint, a few bright
    amp = 0.0012 + 0.020 * m  # linear display add at the peak texel
    kind = rng.random(n)
    col = np.where(kind[:, None] < 0.5, np.array([0.86, 0.93, 1.0]),
                   np.where(kind[:, None] < 0.85, np.array([1.0, 1.0, 1.0]), np.array([1.0, 0.93, 0.82])))
    return v, (amp[:, None] * col).astype(np.float32)


def splat_stars(face, sv, samp, n=FACE, sigma=0.62):
    """Star layer (linear display add) for one face: gaussians at each star's projected texel (stars near an edge are
    splatted on both faces, so seams stay clean)."""
    f = hs.FACES[face]
    c, r, d = (np.array(f[k], np.float32) for k in ("c", "r", "d"))
    dc = sv @ c
    keep = dc > 0.4
    sv, samp, dc = sv[keep], samp[keep], dc[keep]
    px = ((sv @ r) / dc + 1) / 2 * n - 0.5
    py = ((sv @ d) / dc + 1) / 2 * n - 0.5
    inside = (px > -3) & (px < n + 2) & (py > -3) & (py < n + 2)
    px, py, samp = px[inside], py[inside], samp[inside]
    layer = np.zeros((n, n, 3), np.float32)
    ix, iy = np.floor(px).astype(int), np.floor(py).astype(int)
    for oy in range(-2, 4):
        for ox in range(-2, 4):
            x, y = ix + ox, iy + oy
            ok = (x >= 0) & (x < n) & (y >= 0) & (y < n)
            w = np.exp(-((x - px) ** 2 + (y - py) ** 2) / (2 * sigma * sigma))[:, None]
            np.add.at(layer, (y[ok], x[ok]), (samp * w)[ok])
    return layer


# Control colours (display sRGB 0..255: what the frame should show at the sky's reference state).
NIGHT = dict(
    zenith=(6, 9, 21),  # blue-black
    mid=(11, 16, 30),  # at 12 deg
    horizon=(22, 29, 41),  # cool blue-grey
    glow=(58, 44, 34),  # warm sodium city glow the horizon blends toward, centred on glow_az ...
    glow_mix=0.6,  # ... at most this much
    glow_az=90.0,
)
TWILIGHT = {
    "blue": dict(
        # deep blue overhead, ~1.5x the night's zenith: bluer than the night, but close enough that the blue -> night
        # swap at 19:30 (under its exposure dip) is a small step, not a pop
        zenith=(8, 14, 34),
        mid=(13, 22, 40),  # 12 deg, away from the sun
        mid_sun=(22, 32, 48),  # 12 deg on the sun's side: a paler, slightly teal blue above the glow
        anti=(28, 33, 45),  # anti-sun horizon: blue-grey earth shadow
        belt=(37, 31, 44),  # the pink belt just above it
        sun=(80, 50, 27),  # sun-side horizon: amber / orange (the R ceiling there is ~80)
        core=(84, 54, 28),  # right under the sun
        warm=(64, 50, 42),  # sun side at ~7 deg: peach, between the amber and the blue
    ),
    "dawn": dict(
        zenith=(7, 13, 32),
        mid=(12, 21, 39),
        mid_sun=(22, 33, 49),  # a touch more cyan than dusk
        anti=(27, 32, 44),
        belt=(35, 30, 43),
        sun=(74, 54, 40),  # pale peach: softer and less orange than dusk (pink reads maroon this dark)
        core=(80, 60, 43),
        warm=(58, 50, 48),
    ),
}


def night_target(dirs):
    el, az = elevation(dirs), azimuth(dirs)
    T = NIGHT
    c = two_scale(el, L(T["zenith"]), L(T["mid"]), L(T["horizon"]))
    d = np.abs((az - T["glow_az"] + 180) % 360 - 180)
    e = np.clip(el, 0, None)
    glow = 0.75 * np.exp(-(d / 30) ** 2) * np.exp(-e / 4.0) + 0.25 * np.exp(-(d / 70) ** 2) * np.exp(-e / 11.0)
    w = (T["glow_mix"] * glow)[..., None]
    c = c * (1 - w) + L(T["glow"]) * w
    c = c * (1 + 0.05 * soft_noise(dirs, 11))[..., None]
    star_w = smoothstep(3, 22, el) * (1 - 0.85 * np.clip(glow, 0, 1))
    return c, star_w


def twilight_target(dirs, T):
    """Sky-local: the sun glow at azimuth 0 (= glowAzimuth), just below the horizon."""
    el, az = elevation(dirs), azimuth(dirs)
    d = np.abs((az + 180) % 360 - 180)  # 0 = sun side, 180 = anti-sun
    e = np.clip(el, 0, None)
    w_sun = np.exp(-(d / 62) ** 2)[..., None]
    w_core = np.exp(-(d / 24) ** 2)[..., None]
    w_anti = smoothstep(95, 165, d)[..., None]
    hor = L(T["anti"]) + (L(T["sun"]) - L(T["anti"])) * w_sun + (L(T["core"]) - L(T["sun"])) * w_core
    mid = L(T["mid"]) + (L(T["mid_sun"]) - L(T["mid"])) * w_sun
    # the warm side climbs higher than the anti-sun side
    ca = two_scale(el, L(T["zenith"]), mid, hor, a=3.5, b=20.0)
    cb = two_scale(el, L(T["zenith"]), mid, hor, a=6.0, b=24.0)
    c = ca * (1 - w_sun) + cb * w_sun
    # peach band on the sun side, ~4-12 deg, between the amber horizon and the blue
    band = (w_sun * np.exp(-((e - 7) / 5) ** 2)[..., None]) * 0.5
    c = c * (1 - band) + L(T["warm"]) * band
    # the belt of Venus opposite the sun, ~3-9 deg over the blue-grey earth shadow
    belt = (w_anti * np.exp(-((e - 6) / 3.5) ** 2)[..., None]) * 0.55
    c = c * (1 - belt) + L(T["belt"]) * belt
    c = c * (1 + 0.04 * soft_noise(dirs, 21))[..., None]
    star_w = 0.35 * smoothstep(38, 70, el) * smoothstep(70, 150, d)
    return c, star_w


# ---------------------------------------------------------------------------------------------------------------
# Building a sky
# ---------------------------------------------------------------------------------------------------------------

# The night sky does not follow the sun (its city glow stays inland), but the engine's cast does: the held sun is in the
# west until the midnight jump and in the east after it. One texture cannot be right for both, so the night is built
# twice from the same target and swapped AT the jump (same instant, under its exposure dip): the frame stays the same.
SKY_DEFS = {
    "night": dict(kind="night", strength=1.0, hour=22.5, clocks=(18.2,), follow=False, celestial=False,
                  use="19:30-00:00 night (evening hold, sun west): blue-black sky, subtle stars, warm city glow at +X"),
    "nightLate": dict(kind="night", strength=1.0, hour=2.0, clocks=(5.8,), follow=False, celestial=False,
                      use="00:00-05:00 night (morning hold, sun east): the same look, compensated for the other side"),
    "nightMild": dict(kind="night", strength=MILD_STRENGTH, hour=22.5, clocks=(18.2,), follow=False,
                      celestial=False, use="A/B only (Workspace SkyOverride): 'night' at 70 % compensation"),
    "blue": dict(kind="twilight", palette="blue", strength=1.0, hour=18.9, clocks=(18.2,), follow=True, celestial=True,
                 use="18:21-19:30 dusk: amber glow on the sun side, pink belt opposite, deep blue zenith"),
    "dawn": dict(kind="twilight", palette="dawn", strength=1.0, hour=5.3, clocks=(5.8,), follow=True, celestial=True,
                 use="05:00-05:39 dawn: peach / pink glow on the sun side, deep blue zenith"),
}


def sky_gain(dirs, sdef, st_ev):
    """Engine gain for a sky's own (sky-local) directions. A fixed sky (night) is seen under both holds: geometric mean
    of the evening and morning casts. A following sky has the engine sun on its glow (sky azimuth 0) at -3 deg."""
    if sdef["follow"]:
        sun = dir_from(np.float32(0.0), np.float32(HOLD_ELEVATION))
        return engine_gain(dirs, sun, st_ev, sdef["strength"])
    gs = [engine_gain(dirs, sun_dir(c), st_ev, sdef["strength"]) for c in sdef["clocks"]]
    return np.exp(np.mean([np.log(g) for g in gs], axis=0)).astype(np.float32)


_FILL = None


def below_fill():
    """Face colour of everything below the horizon: ONE value for every sky here, so the shared Dn face meets every
    side face. It is the night horizon (anti-sun side) at 45 % in linear light: a dark blue-grey under the world."""
    global _FILL
    if _FILL is None:
        d = dir_from(np.float32(180.0), np.float32(0.0))[None]
        st = state(SKY_DEFS["night"]["hour"], 18.2)
        tgt = lc.linear_to_srgb(L(NIGHT["horizon"])[None] * 0.45)
        face, _ = inverse(tgt, sky_gain(d, SKY_DEFS["night"], st["ev"]), st["grade"])
        _FILL = np.round(face[0] * 255) / 255
    return _FILL.astype(np.float32)


def build(name, star_field):
    sdef = SKY_DEFS[name]
    st = state(sdef["hour"], sdef["clocks"][0])
    faces, clip = {}, []
    sv, samp = star_field
    for k in ("ft", "bk", "lf", "rt", "up"):
        dirs = hs.face_dirs(k, FACE, 1)
        if sdef["kind"] == "night":
            tgt, star_w = night_target(dirs)
        else:
            tgt, star_w = twilight_target(dirs, TWILIGHT[sdef["palette"]])
        tgt = tgt + splat_stars(k, sv, samp) * star_w[..., None]
        gain = sky_gain(dirs, sdef, st["ev"])
        face, over = inverse(lc.linear_to_srgb(tgt), gain, st["grade"])
        clip.append(over)
        el = elevation(dirs)[..., None]
        w = smoothstep(0.0, -3.0, el)
        faces[k] = face * (1 - w) + below_fill() * w
    faces["dn"] = np.broadcast_to(below_fill(), (FACE, FACE, 3)).copy()
    return faces, st, float(np.mean(clip))


def write_sky(name, faces, st, clip):
    sdef = SKY_DEFS[name]
    files = {}
    for k in ("ft", "bk", "lf", "rt", "up"):
        files[k] = lc.rel(lc.save_png(faces[k], os.path.join(lc.SKY_DIR, name, k + ".png")))
    if not os.path.exists(SHARED_DN) or not np.array_equal(lc.load_rgb(SHARED_DN), lc.to_u8(faces["dn"]) / 255.0):
        lc.save_png(faces["dn"], SHARED_DN)
    files["dn"] = lc.rel(SHARED_DN)
    meta_path = os.path.join(lc.SKY_DIR, "skies.json")
    meta_all = lc.read_json(meta_path, {}) or {}
    skies = meta_all.get("skies", {})
    if sdef["kind"] == "night":
        hz = NIGHT["horizon"]
        glow_az, horizon_az = 0.0, NIGHT["glow_az"]
    else:
        hz = TWILIGHT[sdef["palette"]]["anti"]
        glow_az, horizon_az = 0.0, 0.0
    skies[name] = dict(
        hdri=None, source="procedural (tools/look/procedural_sky.py), no third-party source", use=sdef["use"],
        files=files, starCount=0, followSun=sdef["follow"], celestialBodiesShown=sdef["celestial"], clouds=0.0,
        glowAzimuth=glow_az, glowElevation=HOLD_ELEVATION, horizonGlowAzimuth=horizon_az,
        grading=dict(engine=ENGINE, strength=sdef["strength"], reference_hour=sdef["hour"],
                     reference_clocks=list(sdef["clocks"]), exposure=round(st["ev"], 3), grade=st["grade"],
                     clipped_share=round(clip, 5)),
        hazeColor=list(hz), sha1={k: lc.sha1(os.path.join(lc.ROOT, f)) for k, f in files.items()})
    meta_all["skies"] = skies
    meta_all.setdefault("faceMapping", {k: dict(v) for k, v in hs.FACES.items()})
    lc.write_json(meta_path, meta_all)
    return files


# ---------------------------------------------------------------------------------------------------------------
# Evidence: what the frame should show (the forward model), from the job 0009 / 0012 cameras
# ---------------------------------------------------------------------------------------------------------------

CAMERAS = {
    "overview_low_sw": ((-700, 180, -700), (0, 20, 0)),
    "downtown_street": ((60, 12, 160), (60, 40, 0)),
    "look_up": ((0, 10, 0), (0, 1000, -0.001)),
}


def camera_dirs(w, h, pos, look, fov=70.0):
    pos, look = np.array(pos, float), np.array(look, float)
    f = look - pos
    f /= np.linalg.norm(f)
    up = np.array([0, 1, 0.0]) if abs(f[1]) < 0.99 else np.array([0, 0, -1.0])
    r = np.cross(f, up)
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    t = math.tan(math.radians(fov / 2))
    xs = (2 * (np.arange(w) + 0.5) / w - 1) * t * w / h
    ys = (1 - 2 * (np.arange(h) + 0.5) / h) * t
    X, Y = np.meshgrid(xs, ys)
    d = f + X[..., None] * r + Y[..., None] * u
    return (d / np.linalg.norm(d, axis=-1, keepdims=True)).astype(np.float32)


def rot_y(dirs, yaw):
    """World direction -> sky-local direction for Sky.SkyboxOrientation.Y = yaw (yawSign +1): local az = world + yaw."""
    t = math.radians(-yaw)
    x, y, z = dirs[..., 0], dirs[..., 1], dirs[..., 2]
    return np.stack([x * math.cos(t) + z * math.sin(t), y, -x * math.sin(t) + z * math.cos(t)], -1)


def sample_faces(faces, dirs):
    out = np.zeros(dirs.shape[:-1] + (3,), np.float32)
    names = list(hs.FACES)
    dots = np.stack([(dirs * np.array(hs.FACES[k]["c"], np.float32)).sum(-1) for k in names], -1)
    idx = dots.argmax(-1)
    for i, k in enumerate(names):
        m = idx == i
        if not m.any():
            continue
        f = hs.FACES[k]
        d = dirs[m]
        dc = dots[..., i][m]
        u = (d @ np.array(f["r"], np.float32)) / dc
        v = (d @ np.array(f["d"], np.float32)) / dc
        img = faces[k]
        n = img.shape[0]
        out[m] = hs.sample_bilinear(img, np.clip((u + 1) / 2 * n - 0.5, 0, n - 1), np.clip((v + 1) / 2 * n - 0.5, 0, n - 1))
    return out


def render_view(faces, cam, yaw, st, w=840, h=540):
    dirs = camera_dirs(w, h, *cam)
    local = rot_y(dirs, yaw)
    tex = sample_faces(faces, local)
    gain = engine_gain(dirs, st["sun"], st["ev"])
    return forward(tex, gain, st["grade"])


def render_pano(faces, yaw, st, w=1024):
    h = w // 4  # elevation -10 .. +80 deg (what matters)
    az = (np.arange(w) + 0.5) / w * 360 - 180
    el = 80 - (np.arange(h) + 0.5) / h * 90
    A, E = np.meshgrid(az, el)
    dirs = dir_from(A, E)
    tex = sample_faces(faces, rot_y(dirs, yaw))
    return forward(tex, engine_gain(dirs, st["sun"], st["ev"]), st["grade"])


def sky_yaw(name, st):
    sdef = SKY_DEFS.get(name)
    if sdef and not sdef["follow"]:
        return 0.0  # horizonGlowAzimuth 90 parked on fixedGlowAzimuth 90
    s = st["sun"]
    return ((0.0 - math.degrees(math.atan2(s[0], -s[2]))) + 180) % 360 - 180  # glowAzimuth 0 -> sun azimuth


def tile(images, labels, cols, title, path, scale=1.0):
    h, w = images[0].shape[:2]
    pad, top = 8, 34
    rows = (len(images) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (w + pad) + pad, top + rows * (h + pad + 4)), (14, 14, 16))
    lc.label(sheet, (pad, 8), title, size=15, fill=(255, 214, 140))
    for i, (im, lab) in enumerate(zip(images, labels)):
        x = pad + (i % cols) * (w + pad)
        y = top + (i // cols) * (h + pad + 4)
        sheet.paste(Image.fromarray(lc.to_u8(im)), (x, y))
        lc.label(sheet, (x + 5, y + 5), lab, size=12)
    if scale != 1.0:
        sheet = sheet.resize((int(sheet.width * scale), int(sheet.height * scale)), Image.LANCZOS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path, optimize=True)
    return path


def evidence(built):
    out = []
    rows = [("night", 18.2, "game 22.5, evening hold"), ("nightLate", 5.8, "game 2.0, morning hold"),
            ("nightMild", 18.2, "game 22.5, A/B"), ("night", 5.8, "WRONG HOLD: why there are two")]
    rows = [r for r in rows if r[0] in built]
    if rows:
        imgs, labs = [], []
        for nm, clock, what in rows:
            st = state(22.5 if clock > 12 else 2.0, clock)
            for cam in ("overview_low_sw", "downtown_street", "look_up"):
                imgs.append(render_view(built[nm], CAMERAS[cam], sky_yaw(nm, st), st))
                labs.append("%s  %s  (%s, EV %+.2f)" % (nm, cam, what, st["ev"]))
        out.append(tile(imgs, labs, 3, "Night skies, SIMULATED in-game (engine transfer measured at the held clock + the "
                        "night grade). Sky only: the city covers the lower part in game.",
                        os.path.join(EVIDENCE_DIR, "night_sim_views.png"), 0.75))
    tw = [n for n in ("blue", "dawn") if n in built]
    if tw:
        imgs, labs = [], []
        for nm in tw:
            hour, clock = (18.9, 18.2) if nm == "blue" else (5.3, 5.8)
            st = state(hour, clock)
            yaw = sky_yaw(nm, st)
            sun_az = math.degrees(math.atan2(st["sun"][0], -st["sun"][2]))
            for lab, look in (("sunward", sun_az), ("anti-sun", sun_az + 180)):
                a = math.radians(look)
                cam = ((0, 30, 0), (1000 * math.sin(a), 30 + 1000 * math.tan(math.radians(12)), -1000 * math.cos(a)))
                imgs.append(render_view(built[nm], cam, yaw, st))
                labs.append("%s  %s  (game %.1f, EV %+.2f)" % (nm, lab, hour, st["ev"]))
            imgs.append(render_view(built[nm], CAMERAS["look_up"], yaw, st))
            labs.append("%s  look_up" % nm)
        out.append(tile(imgs, labs, 3, "Blue hour (dusk) and dawn skies, SIMULATED in-game at the engine hold (sun -3 deg)."
                        " Sky only.", os.path.join(EVIDENCE_DIR, "twilight_sim_views.png"), 0.75))
    # panoramas of every sky, simulated
    imgs, labs = [], []
    for nm, faces in built.items():
        sdef = SKY_DEFS[nm]
        hour, clock = sdef["hour"], sdef["clocks"][0]
        st = state(hour, clock)
        imgs.append(render_pano(faces, sky_yaw(nm, st), st))
        labs.append("%s  simulated, game %.1f (world azimuth -180..180, el -10..80; centre = -Z)" % (nm, hour))
        raw = np.zeros_like(imgs[-1])
        az = (np.arange(raw.shape[1]) + 0.5) / raw.shape[1] * 360 - 180
        el = 80 - (np.arange(raw.shape[0]) + 0.5) / raw.shape[0] * 90
        A, E = np.meshgrid(az, el)
        raw = sample_faces(faces, rot_y(dir_from(A, E), sky_yaw(nm, st)))
        imgs.append(raw)
        labs.append("%s  RAW faces as uploaded (pre-compensated: the engine turns this cyan back into blue)" % nm)
    out.append(tile(imgs, labs, 2, "Panoramas: simulated in-game vs the raw uploaded texture",
                    os.path.join(EVIDENCE_DIR, "panoramas.png"), 0.8))
    for nm, faces in built.items():
        sdef = SKY_DEFS[nm]
        meta = dict(hdri="procedural", sunAzimuth=None, sunElevation=None)
        st = state(sdef["hour"], sdef["clocks"][0])
        eq = render_pano(faces, 0.0, st, w=1024)
        p = os.path.join(EVIDENCE_DIR, "cross_%s.png" % nm)
        hs.cross_sheet(nm, faces, eq, meta, p)
        out.append(p)
    return out


# ---------------------------------------------------------------------------------------------------------------
# Calibration: refit the engine transfer from a real-engine screenshot of a known sky
# ---------------------------------------------------------------------------------------------------------------


def calibrate(a):
    img = lc.load_rgb(a.shot)
    h, w = img.shape[:2]
    cam = [float(v) for v in a.camera.split(",")]
    dirs = camera_dirs(w, h, cam[:3], cam[3:], a.fov)
    faces = {k: lc.load_rgb(os.path.join(a.faces, k + ".png")) for k in hs.FACES}
    tex = sample_faces(faces, rot_y(dirs, a.yaw))
    g = dict(tint=[float(v) for v in a.tint.split(",")], saturation=a.saturation, contrast=a.contrast)
    el = elevation(dirs)
    mask = (el > 2.0) & (img.max(-1) > 3 / 255)
    for box in filter(None, a.mask.split(";")):
        x0, y0, x1, y1 = (int(v) for v in box.split(","))
        mask[y0:y1, x0:x1] = False
    rl0 = lc.srgb_to_linear(np.clip(ungrade(img, g), 0, 1))[mask]
    tl0 = lc.srgb_to_linear(tex)[mask]
    print("gamma scan (relative residual R G B of rendered = A * face ** gamma):")
    for gam in (1.0, 1.1, 1.2, 1.3, 1.35, 1.4, 1.5, 1.6):
        tg = tl0 ** gam
        A = (rl0 * tg).sum(0) / (tg * tg).sum(0)
        res = np.sqrt(((rl0 - tg * A) ** 2).mean(0)) / rl0.mean(0)
        print("  gamma %.2f  resid %s  R/G %.2f B/G %.2f" % (gam, res.round(3), A[0] / A[1], A[2] / A[1]))
    gam = a.gamma
    rl = rl0 / 2.0 ** (gam * (a.exposure - ENGINE["ref_ev"]))
    tl = tl0 ** gam
    gain = (rl * tl).sum(0) / (tl * tl).sum(0)
    corr = [float(np.corrcoef(tl[:, c], rl[:, c])[0, 1]) for c in range(3)]
    sun = sun_dir(a.clock)
    psi = np.degrees(np.arccos(np.clip((dirs[mask] * sun).sum(-1), -1, 1)))
    e = el[mask]
    print("pixels %d  gamma %.2f  A at EV %+.1f: R %.4f G %.4f B %.4f  (R/G %.2f, B/G %.2f)  corr %s" % (
        mask.sum(), gam, ENGINE["ref_ev"], *gain, gain[0] / gain[1], gain[2] / gain[1], [round(c, 3) for c in corr]))
    # how much of the face's own hue comes through: inside narrow windows, slope of log rendered R/G vs log face R/G
    # (1 = exactly what `gamma` predicts; more = the engine boosts sky chroma beyond it)
    slopes = []
    for plo, phi in ((100, 125), (125, 150), (150, 180)):
        for elo, ehi in ((3, 10), (10, 18), (18, 30), (30, 60)):
            m = (psi >= plo) & (psi < phi) & (e >= elo) & (e < ehi) & (rl[:, 0] > 0) & (rl[:, 1] > 0)
            if m.sum() < 3000:
                continue
            x = np.log(tl[m, 0] / tl[m, 1])
            y = np.log(rl[m, 0] / rl[m, 1])
            if np.std(x) < 0.02:
                continue
            (s, _), *_ = np.linalg.lstsq(np.stack([x, np.ones_like(x)], -1), y, rcond=None)
            slopes.append(s)
    if slopes:
        print("chroma slope beyond gamma, median of %d windows: %.2f" % (len(slopes), float(np.median(slopes))))
    print("rows: elevation; cols: degrees from the sun; cells: R/G | B/G | G (A, gamma domain)")
    for elo, ehi in ((2, 8), (8, 16), (16, 26), (26, 45), (45, 90)):
        row = []
        for plo, phi in ((0, 60), (60, 100), (100, 130), (130, 150), (150, 180)):
            m = (e >= elo) & (e < ehi) & (psi >= plo) & (psi < phi)
            if m.sum() < 300:
                row.append("       --       ")
                continue
            gg = (rl[m] * tl[m]).sum(0) / (tl[m] * tl[m]).sum(0)
            row.append("%.2f|%.2f|%.3f" % (gg[0] / gg[1], gg[2] / gg[1], gg[1]))
        print("  el %2d-%2d: %s" % (elo, ehi, "  ".join(row)))


# ---------------------------------------------------------------------------------------------------------------


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "calibrate":
        ap = argparse.ArgumentParser(prog="procedural_sky.py calibrate")
        ap.add_argument("--shot", required=True)
        ap.add_argument("--faces", required=True, help="dir with the sky's ft/bk/lf/rt/up/dn.png")
        ap.add_argument("--yaw", type=float, required=True, help="Sky.SkyboxOrientation.Y in the shot")
        ap.add_argument("--exposure", type=float, required=True)
        ap.add_argument("--tint", required=True)
        ap.add_argument("--contrast", type=float, required=True)
        ap.add_argument("--saturation", type=float, required=True)
        ap.add_argument("--camera", default="-700,180,-700,0,20,0")
        ap.add_argument("--fov", type=float, default=70.0)
        ap.add_argument("--clock", type=float, default=18.2, help="engine ClockTime of the shot")
        ap.add_argument("--gamma", type=float, default=ENGINE["gamma"])
        ap.add_argument("--mask", default="620,80,1050,205;535,245,1150,430;0,400,380,1080",
                        help="x0,y0,x1,y1;... HUD boxes to ignore")
        calibrate(ap.parse_args(sys.argv[2:]))
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--evidence", action="store_true")
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    star_field = stars(5200, 7)
    built = {}
    for name in SKY_DEFS:
        if only and name not in only:
            continue
        faces, st, clip = build(name, star_field)
        write_sky(name, faces, st, clip)
        built[name] = {k: lc.load_rgb(os.path.join(lc.ROOT, f)) for k, f in
                       lc.read_json(os.path.join(lc.SKY_DIR, "skies.json"))["skies"][name]["files"].items()}
        print("%-9s EV %+.2f tint %s  clipped %.3f%%" % (name, st["ev"], st["grade"]["tint"], 100 * clip))
    if a.evidence:
        for p in evidence(built):
            print("evidence", lc.rel(p))


if __name__ == "__main__":
    main()
