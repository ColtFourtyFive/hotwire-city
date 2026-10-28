#!/usr/bin/env python3
"""Procedural night, dusk and dawn skies, pre-compensated for what the engine does to a skybox at the held night clock
(backlog item 14; the diagnosis is in docs/v2/research/lighting_lab.md, round 5).

Why procedural and why pre-compensated
  LightingService holds Lighting.ClockTime at 18.2 / 5.8 (engine sun -3 deg) all night and fakes the night with the
  presets (Look.EngineClock). At that clock the engine renders the skybox ~8x darker than the face at Exposure +2 (~20x
  at the night's +0.8) and strongly red. Fitted on TWO real-engine shots of known faces (`fit`, tools/look/
  sky_calibration.json: job 0009's night HDRI at Exposure +2, and job 0011's night shot, which showed the cached DAY
  faces at Exposure +0.8), after undoing each shot's ColorCorrection:
      rendered_lin = A(el, psi) * face_lin ** gamma,   A = G(el) * 2 ** (gamma * (EV - 2)) * (R/G, 1, B/G(el))
    * R/G = 2.8, flat over everything measured (2..27 deg elevation, 78..180 deg from the sun), in both shots;
    * B/G falls with elevation: ~1.1 at the horizon, ~0.95 at 12 deg, ~0.83 at 21 deg;
    * G falls slowly with elevation; the two shots agree within ~3 % once the exposure is accounted for.
  So the navy-grey night HDRI (faces R < G < B) rendered reddish-brown, and the blue grade cannot pull it back without
  turning the whole city blue. Here every face is the INVERSE of that transfer applied to the look we want on screen
  (the target, display sRGB after the preset's ColorCorrection). A deep blue night needs a face that looks pale cyan-blue
  on its own; the engine's red cast turns it back into blue. A clean gradient, not a photo: the engine dims the sky so
  far that photo detail (clouds) is lost anyway, and a gradient has no colour noise to go muddy.

  Unmeasured, so hedged: the zenith (B/G continues its measured fall to bg_high) and the sun's side (< 75 deg from the
  sun, R/G rg_near = 2.3 instead of 2.8: an error either way turns the dusk glow orange or yellow, never olive). The
  night sky is one texture for both holds (sun west before midnight, east after): built for the geometric mean of the
  two casts. Job 0012 shoots every one of these regions; add its shots to sky_calibration.json and re-run `fit`.

  The ceiling: a white face renders at most ~(80, 50, 40) at the night zenith and less at dusk (G and B are the
  limits). Targets stay under it; a pixel that would still clip is scaled down as a whole (hue kept).

Skies (six 1024 px faces each, the engine-verified mapping of hdri_to_skybox.py; one shared Dn face):
  night  clear night: blue-black zenith, cool blue-grey horizon, subtle stars, faint warm city glow at sky azimuth 90
         (= +X: the night sky does not follow the sun; LightingService parks horizonGlowAzimuth on +X, inland)
  blue   dusk: amber glow on the sun side (sky azimuth 0 = glowAzimuth, kept on the engine sun), mauve belt opposite,
         deep blue zenith, a few first stars
  dawn   dawn: the same build, pale peach-gold instead of amber

Commands
  python3 -I tools/look/procedural_sky.py [--only night,blue] [--evidence]
      faces -> assets/sky/<sky>/{ft,bk,lf,rt,up}.png + assets/sky/shared/dn_twilight.png (every sky's Dn),
      metadata -> assets/sky/skies.json (other skies untouched), previews -> docs/v2/evidence/look_night/
  python3 -I tools/look/procedural_sky.py fit [--spec tools/look/sky_calibration.json]
      refits ENGINE from every listed real-engine shot and prints the per-region residuals
  python3 -I tools/look/procedural_sky.py calibrate --shot <png> --faces <dir> --yaw <deg> --exposure <EV>
      --tint R,G,B --contrast C --saturation S [--camera x,y,z,lx,ly,lz] [--clock 18.2]
      one shot's transfer per region (diagnostic table)
"""

import argparse
import io
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
SPEC = os.path.join(HERE, "sky_calibration.json")
OLD_REV = "3d0a965"  # the last commit with the HDRI night / blue faces (before / after evidence)

# ---------------------------------------------------------------------------------------------------------------
# The engine transfer at the held clock (sun -3 deg), fitted by `fit` on tools/look/sky_calibration.json
# ---------------------------------------------------------------------------------------------------------------

ENGINE = dict(
    ref_ev=2.0,  # A is quoted at ExposureCompensation +2 and scales by 2 ** (gamma * (EV - ref_ev))
    gamma=1.2,  # best joint fit of the two shots (1.1-1.35 all fit within a few %)
    # G(el) = g_high + g_low * exp(-el / g_scale). `fit`: 0.0953 + 0.0328 exp(-el / 30) over 2-30 deg; the zenith is
    # extrapolated (0.096 by the fit, 0.110 if flat above 25 deg: 0.101 here)
    g_high=0.100,
    g_low=0.027,
    g_scale=25.0,
    # B/G(el) = bg_high + bg_low * exp(-el / bg_scale). `fit`: 0.38 + 0.904 exp(-el / 32) over 2-30 deg (within 4 % of
    # this there); the zenith is extrapolated: 0.44 by the fit, 0.79 if flat above 25 deg, 0.54 here
    bg_high=0.52,
    bg_low=0.72,
    bg_scale=26.0,
    # R/G: rg_far measured (`fit` 2.774, flat over 78-171 deg from the sun in both shots); rg_near is the hedge for the
    # unmeasured sun side (< psi1): halfway (in log) between the measured 2.8 and job 0009's dubious 1.8
    rg_far=2.78,
    rg_near=2.3,
    psi0=40.0,
    psi1=75.0,
)
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


def sun_angle(dirs, sun):
    return np.degrees(np.arccos(np.clip((dirs * sun).sum(-1), -1, 1)))


def engine_gain(dirs, sun, ev, E=None):
    """Per-channel A_c of the engine transfer (rendered_lin = A_c * face_lin ** gamma, before the ColorCorrection) for
    face texels seen in `dirs` (sun = engine sun direction, ev = ExposureCompensation)."""
    E = E or ENGINE
    el = np.clip(elevation(dirs), 0, None)
    g = E["g_high"] + E["g_low"] * np.exp(-el / E["g_scale"])
    s = smoothstep(E["psi0"], E["psi1"], sun_angle(dirs, sun))
    rg = E["rg_near"] + (E["rg_far"] - E["rg_near"]) * s
    bg = E["bg_high"] + E["bg_low"] * np.exp(-el / E["bg_scale"])
    ratio = np.stack([rg, np.ones_like(rg), bg], -1)
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


KNEE = 0.85  # face-space peak where the soft roll-off toward the ceiling starts


def inverse(target_srgb, gain, g):
    """Wanted display sRGB -> face sRGB, and the share of pixels over the ceiling (a white face). Pixels whose largest
    channel would pass KNEE are scaled down as a whole in face space (a smooth roll-off that reaches 1.0 only at
    infinity), which scales the rendered colour uniformly too: the hue is kept, only darker, and the noise and stars
    near the ceiling are compressed, never flattened."""
    need = (lc.srgb_to_linear(np.clip(ungrade(target_srgb, g), 0, 1)) / gain) ** (1.0 / ENGINE["gamma"])
    peak = np.maximum(need.max(-1, keepdims=True), 1e-6)
    over = float((peak > 1.0).mean())
    need = need * lc.soft_clip(peak, KNEE) / peak
    return lc.linear_to_srgb(np.clip(need, 0, 1)), over


# ---------------------------------------------------------------------------------------------------------------
# Render states (the presets at a GAME hour, from Config/Look via tools/look/export_look.luau)
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


def swap_dip(hour):
    """LightingService.swapDipAt (same maths)."""
    L = look_data()
    swap = L["SkySwap"]
    dips = [(swap["exposureDip"], L["EngineClock"]["jumpHour"])]
    dips += [(e.get("dip", swap["exposureDip"]), e["hour"]) for e in L["SkySchedule"]]
    best = 0.0
    for depth, at in dips:
        d = abs(hour % 24 - at % 24)
        d = min(d, 24 - d)
        best = max(best, depth * math.exp(-(d / swap["width"]) ** 2))
    return best


def preset_at(hour):
    """LightingService.lookAt without the caps / overrides, plus the swap dip (same maths)."""
    L = look_data()
    h = hour % 24
    keys = L["Keys"]
    a, b = keys[0], keys[-1]
    for i in range(len(keys) - 1):
        if keys[i]["hour"] <= h <= keys[i + 1]["hour"]:
            a, b = keys[i], keys[i + 1]
            break
    span = b["hour"] - a["hour"]
    t = (h - a["hour"]) / span if span > 0 else 0.0
    t = t * t * (3 - 2 * t)
    p = _lerp(L["Presets"][a["preset"]], L["Presets"][b["preset"]], t)
    p["exposure"] -= swap_dip(h)
    return p


def engine_clock(hour):
    """LightingService.engineClockAt (same maths)."""
    E = look_data()["EngineClock"]
    h = hour % 24
    ease = E["ease"]
    eve0 = E["eveningHold"] - ease / 2
    eve1 = eve0 + ease
    morn1 = E["morningHold"] + ease / 2
    morn0 = morn1 - ease
    if morn1 <= h <= eve0:
        return h
    if eve0 < h < eve1:
        d = h - eve0
        return eve0 + d - d * d / (2 * ease)
    if morn0 < h < morn1:
        u = morn1 - h
        return morn1 - u + u * u / (2 * ease)
    if (h - eve1) % 24 < (E["jumpHour"] - eve1) % 24:
        return E["eveningHold"]
    return E["morningHold"]


def sky_at(hour):
    """LightingService.skyAt (same maths)."""
    sched = look_data()["SkySchedule"]
    h = hour % 24
    name = sched[-1]["sky"]
    for e in sched:
        if h >= e["hour"]:
            name = e["sky"]
    return name


def state(hour, clock=None):
    """Exposure + grade at a game hour; the engine sun at `clock` (default: the engine clock of that hour)."""
    p = preset_at(hour)
    cc = p["colorCorrection"]
    clock = engine_clock(hour) if clock is None else clock
    return dict(ev=p["exposure"], sun=sun_dir(clock), grade=dict(tint=cc["tint"], saturation=cc["saturation"],
                                                                 contrast=cc["contrast"]), hour=hour, clock=clock,
                haze=p["atmosphere"]["haze"])


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
    amp = 0.0016 + 0.026 * m  # linear display add at the peak texel
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


# Control colours (display sRGB 0..255: what the frame should show at the sky's reference state). GTA V's clear night
# over the city: a deep blue (not black) zenith, a lighter cool blue-grey band at the horizon, stars, and a dim
# sodium glow only just above the city; its dusk: amber on the sun's side under a pale teal band, deep blue overhead,
# a cool mauve belt over the blue-grey earth shadow opposite. Both are far darker here than in GTA: the engine caps the
# sky at about G 50 / B 40 at night (module docstring), so the targets keep the hue relations, not GTA's brightness.
NIGHT = dict(
    zenith=(6, 10, 24),  # blue-black (the B ceiling there is ~32; stars need headroom)
    mid=(12, 18, 36),  # at 12 deg
    horizon=(28, 36, 52),  # cool blue-grey
    glow=(72, 50, 32),  # warm sodium city glow the horizon blends toward, centred on glow_az ...
    glow_mix=0.75,  # ... at most this much, right at the horizon, gone by ~8 deg
    glow_az=90.0,
)
TWILIGHT = {
    "blue": dict(
        # deep blue overhead, about the night's zenith: the blue -> night swap at 19:30 (under its exposure dip) is
        # mostly the sun-side glow going, not a jump of the whole dome
        zenith=(5, 10, 22),  # (the B ceiling there is ~26 at dusk)
        mid=(11, 21, 36),  # 12 deg, away from the sun
        mid_sun=(20, 30, 38),  # 12 deg on the sun's side: a paler, slightly teal blue above the glow
        anti=(30, 36, 48),  # anti-sun horizon: blue-grey earth shadow
        belt=(40, 33, 46),  # the cool mauve belt just above it
        sun=(70, 40, 16),  # sun-side horizon: saturated amber-orange (at the R and G ceilings there)
        core=(72, 41, 16),  # right under the sun
        warm=(60, 42, 30),  # sun side at ~5 deg: peach-orange, between the amber and the blue
    ),
    "dawn": dict(
        zenith=(5, 10, 21),
        mid=(10, 20, 35),
        mid_sun=(21, 31, 39),  # a touch more cyan than dusk
        anti=(29, 35, 47),
        belt=(38, 32, 45),
        sun=(64, 43, 22),  # pale peach-gold: softer and less orange than dusk (pink reads maroon this dark)
        core=(66, 44, 22),
        warm=(56, 45, 34),
    ),
}


def night_target(dirs):
    el, az = elevation(dirs), azimuth(dirs)
    T = NIGHT
    c = two_scale(el, L(T["zenith"]), L(T["mid"]), L(T["horizon"]))
    d = np.abs((az - T["glow_az"] + 180) % 360 - 180)
    e = np.clip(el, 0, None)
    glow = 0.8 * np.exp(-(d / 30) ** 2) * np.exp(-e / 3.0) + 0.2 * np.exp(-(d / 70) ** 2) * np.exp(-e / 7.0)
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
    # peach band on the sun side, ~2-9 deg, between the amber horizon and the blue (the engine's own haze band covers
    # 0-2 deg at dusk, job 0011 D, so the warmth has to reach above it; higher or wider, this dark, it reads brown)
    band = (w_sun * np.exp(-((e - 5) / 4) ** 2)[..., None]) * 0.4
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
# west until the midnight jump and in the east after it. Where the cast differs (only the hedged sun side, < 75 deg
# from the sun), the night is built for the geometric mean of both holds: one texture all night, no swap at the jump.
SKY_DEFS = {
    "night": dict(kind="night", hour=22.5, clocks=(18.2, 5.8), follow=False, celestial=False,
                  use="19:30-05:00 night: blue-black sky, cool horizon, subtle stars, faint warm city glow at +X"),
    "blue": dict(kind="twilight", palette="blue", hour=18.9, clocks=(18.2,), follow=True, celestial=True,
                 use="18:21-19:30 dusk: amber glow on the sun side, mauve belt opposite, deep blue zenith"),
    "dawn": dict(kind="twilight", palette="dawn", hour=5.3, clocks=(5.8,), follow=True, celestial=True,
                 use="05:00-05:39 dawn: pale peach-gold glow on the sun side, deep blue zenith"),
}


def sky_gain(dirs, sdef, st_ev):
    """Engine gain for a sky's own (sky-local) directions. A fixed sky (night) is seen under both holds: geometric mean
    of the evening and morning casts. A following sky has the engine sun on its glow (sky azimuth 0) at -3 deg."""
    if sdef["follow"]:
        sun = dir_from(np.float32(0.0), np.float32(HOLD_ELEVATION))
        return engine_gain(dirs, sun, st_ev)
    gs = [engine_gain(dirs, sun_dir(c), st_ev) for c in sdef["clocks"]]
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
        grading=dict(engine=ENGINE, reference_hour=sdef["hour"], reference_clocks=list(sdef["clocks"]),
                     exposure=round(st["ev"], 3), grade=st["grade"], clipped_share=round(clip, 5)),
        hazeColor=list(hz), sha1={k: lc.sha1(os.path.join(lc.ROOT, f)) for k, f in files.items()})
    meta_all["skies"] = skies
    meta_all.setdefault("faceMapping", {k: dict(v) for k, v in hs.FACES.items()})
    lc.write_json(meta_path, meta_all)
    return files


def drop_skies(names):
    """Removes skies this tool no longer builds from skies.json (their PNGs are deleted by the caller / git)."""
    meta_path = os.path.join(lc.SKY_DIR, "skies.json")
    meta_all = lc.read_json(meta_path, {}) or {}
    for n in names:
        meta_all.get("skies", {}).pop(n, None)
    lc.write_json(meta_path, meta_all)


# ---------------------------------------------------------------------------------------------------------------
# Inputs from git (calibration shots and the old faces live on other commits / branches)
# ---------------------------------------------------------------------------------------------------------------


def read_bytes(ref):
    """`git:<rev>:<path>` via git show (read-only), else a path relative to the repo root."""
    if ref.startswith("git:"):
        rev, path = ref[4:].split(":", 1)
        return subprocess.run(["git", "show", "%s:%s" % (rev, path)], cwd=lc.ROOT, capture_output=True,
                              check=True).stdout
    with open(os.path.join(lc.ROOT, ref), "rb") as f:
        return f.read()


def load_image(ref):
    return np.asarray(Image.open(io.BytesIO(read_bytes(ref))).convert("RGB"), dtype=np.float32) / 255.0


def load_faces(ref):
    sep = "/" if not ref.endswith("/") else ""
    return {k: load_image(ref + sep + k + ".png") for k in hs.FACES}


# ---------------------------------------------------------------------------------------------------------------
# Evidence: what the frame should show (the forward model), from the job 0009 / 0011 / 0012 cameras
# ---------------------------------------------------------------------------------------------------------------

CAMERAS = {
    "downtown_street": ((60, 12, 160), (60, 40, 0)),
    "overview_low_sw": ((-700, 180, -700), (0, 20, 0)),
    "look_up": ((60, 12, 160), (60, 1000, 160)),  # image top = -Z (job 0012: CFrame.lookAt(pos, pos + Y, -Z))
}
JOB_HOURS = (19.0, 20.5, 22.5, 2.0, 5.5)  # studio/jobs/0012-night-sky.md


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


# The engine's own haze band at the horizon (measured, job 0011 D at dusk: Haze 0.7, Atmosphere colour (120, 124, 134);
# 0-1 deg (51, 55, 75), 1-2 deg (44, 39, 54), gone by ~3 deg; on the anti-sun side only, the sun side is unmeasured).
# Overlaid on the twilight previews in proportion to the preset's haze above the night's 0.35 (where none was seen).
DUSK_HAZE = (52, 56, 76)


def haze_overlay(img, dirs, st):
    k = np.clip((st["haze"] - 0.35) / (0.7 - 0.35), 0, 1)
    if k <= 0:
        return img
    el = elevation(dirs)
    w = (0.85 * k * smoothstep(2.5, 0.0, el) * smoothstep(-1.5, -0.5, el))[..., None]
    return img * (1 - w) + np.array(DUSK_HAZE, np.float32) / 255.0 * w


def render_view(faces, cam, yaw, st, w=840, h=540):
    dirs = camera_dirs(w, h, *cam)
    tex = sample_faces(faces, rot_y(dirs, yaw))
    out = forward(tex, engine_gain(dirs, st["sun"], st["ev"]), st["grade"])
    return haze_overlay(out, dirs, st)


def render_pano(faces, yaw, st, w=1024):
    h = w // 4  # elevation -10 .. +80 deg (what matters)
    az = (np.arange(w) + 0.5) / w * 360 - 180
    el = 80 - (np.arange(h) + 0.5) / h * 90
    A, E = np.meshgrid(az, el)
    dirs = dir_from(A, E)
    tex = sample_faces(faces, rot_y(dirs, yaw))
    return haze_overlay(forward(tex, engine_gain(dirs, st["sun"], st["ev"]), st["grade"]), dirs, st)


def sun_azimuth(st):
    s = st["sun"]
    return math.degrees(math.atan2(s[0], -s[2]))


def sky_yaw(name, st, old=False):
    """SkyboxOrientation.Y LightingService writes for a sky (SKY_DEFS) or, with old=True, for the HDRI skies at OLD_REV
    (night: horizon glow 17.4 parked on +X; blue: glow 32.7 on the sun)."""
    if old:
        raw = (17.4 - 90.0) if name == "night" else (32.7 - sun_azimuth(st))
        return (raw + 180) % 360 - 180
    if not SKY_DEFS[name]["follow"]:
        return 0.0  # horizonGlowAzimuth 90 parked on fixedGlowAzimuth 90
    return ((0.0 - sun_azimuth(st)) + 180) % 360 - 180  # glowAzimuth 0 -> sun azimuth


def tile(images, labels, cols, title, path, scale=1.0, notes=()):
    h, w = images[0].shape[:2]
    pad, top = 8, 34 + 18 * len(notes)
    rows = (len(images) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (w + pad) + pad, top + rows * (h + pad + 4)), (14, 14, 16))
    lc.label(sheet, (pad, 8), title, size=15, fill=(255, 214, 140))
    for i, n in enumerate(notes):
        lc.label(sheet, (pad, 30 + 18 * i), n, size=12, fill=(200, 200, 200))
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


def mean_sky(faces, yaw, st, n=96):
    """Mean display colour (0..255) of the whole sky above 2 deg, as rendered (for the swap steps)."""
    az = (np.arange(4 * n) + 0.5) / (4 * n) * 360 - 180
    el = 2 + (np.arange(n) + 0.5) / n * 88
    A, E = np.meshgrid(az, el)
    dirs = dir_from(A, E)
    img = haze_overlay(forward(sample_faces(faces, rot_y(dirs, yaw)), engine_gain(dirs, st["sun"], st["ev"]),
                               st["grade"]), dirs, st)
    wts = np.cos(np.radians(E))[..., None]
    return (img * wts).sum((0, 1)) / wts.sum() * 255


def evidence(built):
    out = []
    old = {"night": load_faces("git:%s:assets/sky/night" % OLD_REV), "blue": load_faces("git:%s:assets/sky/blue" % OLD_REV)}
    hud = "Sky only: the city covers the lower part in game; the engine's dusk haze band (0-2 deg) is overlaid."
    # 1. what job 0012 should see, at its five lock hours and three cameras
    imgs, labs = [], []
    for hour in JOB_HOURS:
        name = sky_at(hour)
        st = state(hour)
        for cam in ("downtown_street", "overview_low_sw", "look_up"):
            imgs.append(render_view(built[name], CAMERAS[cam], sky_yaw(name, st), st))
            labs.append("%04.1f  %s  sky %s  EV %+.2f  clock %.2f" % (hour, cam, name, st["ev"], st["clock"]))
    out.append(tile(imgs, labs, 3, "Job 0012 preview: the NEW skies SIMULATED in-game (fitted engine transfer + the "
                    "preset's exposure and grade at each lock hour)", os.path.join(EVIDENCE_DIR, "job0012_sim.png"),
                    0.75, notes=(hud,)))
    # 2. before / after at the same hours
    imgs, labs = [], []
    for hour in (19.0, 22.5, 5.5):
        name = sky_at(hour)
        oname = "night" if name == "night" else "blue"
        st = state(hour)
        for cam in ("overview_low_sw", "look_up"):
            imgs.append(render_view(old[oname], CAMERAS[cam], sky_yaw(oname, st, old=True), st))
            labs.append("BEFORE %04.1f %s (HDRI '%s' faces)" % (hour, cam, oname))
            imgs.append(render_view(built[name], CAMERAS[cam], sky_yaw(name, st), st))
            labs.append("AFTER  %04.1f %s (procedural '%s')" % (hour, cam, name))
    out.append(tile(imgs, labs, 4, "Before / after, both SIMULATED with the same fitted engine transfer and grade",
                    os.path.join(EVIDENCE_DIR, "before_after.png"), 0.6, notes=(hud,)))
    # 3. twilight: sunward / anti-sun / straight up
    imgs, labs = [], []
    for nm, hour in (("blue", 18.9), ("dawn", 5.3)):
        st = state(hour)
        yaw = sky_yaw(nm, st)
        sa = sun_azimuth(st)
        for lab, look in (("sunward", sa), ("anti-sun", sa + 180)):
            a = math.radians(look)
            cam = ((0, 30, 0), (1000 * math.sin(a), 30 + 1000 * math.tan(math.radians(12)), -1000 * math.cos(a)))
            imgs.append(render_view(built[nm], cam, yaw, st))
            labs.append("%s  %s  (game %.1f, EV %+.2f)" % (nm, lab, hour, st["ev"]))
        imgs.append(render_view(built[nm], CAMERAS["look_up"], yaw, st))
        labs.append("%s  look_up" % nm)
    out.append(tile(imgs, labs, 3, "Dusk ('blue') and dawn skies, SIMULATED in-game at the engine hold (sun -3 deg)",
                    os.path.join(EVIDENCE_DIR, "twilight_sim_views.png"), 0.75, notes=(hud,)))
    # 4. panoramas, simulated vs raw texture
    imgs, labs = [], []
    for nm, faces in built.items():
        sdef = SKY_DEFS[nm]
        st = state(sdef["hour"], sdef["clocks"][0])
        yaw = sky_yaw(nm, st)
        imgs.append(render_pano(faces, yaw, st))
        labs.append("%s  simulated, game %.1f (world azimuth -180..180, el -10..80; centre = -Z)" % (nm, sdef["hour"]))
        az = (np.arange(1024) + 0.5) / 1024 * 360 - 180
        el = 80 - (np.arange(256) + 0.5) / 256 * 90
        A, E = np.meshgrid(az, el)
        imgs.append(sample_faces(faces, rot_y(dir_from(A, E), yaw)))
        labs.append("%s  RAW faces as uploaded (pre-compensated: the engine turns this cyan back into blue)" % nm)
    out.append(tile(imgs, labs, 2, "Panoramas: simulated in-game vs the raw uploaded texture",
                    os.path.join(EVIDENCE_DIR, "panoramas.png"), 0.8))
    # 5. the model against the real engine: every calibration shot next to the model's render of the same faces
    imgs, labs = [], []
    for s in json.load(open(SPEC))["shots"]:
        real = load_image(s["shot"])
        h, w = real.shape[:2]
        h2, w2 = h // 2, w // 2
        dirs = camera_dirs(w2, h2, s["camera"][:3], s["camera"][3:], s.get("fov", 70.0))
        g = dict(tint=s["tint"], saturation=s["saturation"], contrast=s["contrast"])
        model = forward(sample_faces(load_faces(s["faces"]), rot_y(dirs, s["yaw"])),
                        engine_gain(dirs, sun_dir(s["clock"]), s["exposure"]), g)
        model = np.where((elevation(dirs) > 0)[..., None], model, 0.0)
        imgs.append(np.asarray(Image.fromarray(lc.to_u8(real)).resize((w2, h2), Image.LANCZOS)) / 255.0)
        labs.append("REAL: " + s["name"][:70])
        imgs.append(model)
        labs.append("MODEL: same faces / yaw / exposure %+.1f / grade, fitted transfer (sky only)" % s["exposure"])
    out.append(tile(imgs, labs, 2, "The fitted engine transfer reproduces the reddish-brown sky of both real-engine "
                    "shots (tools/look/sky_calibration.json)", os.path.join(EVIDENCE_DIR, "model_validation.png"), 0.8))
    # 6. cross sheets
    for nm, faces in built.items():
        sdef = SKY_DEFS[nm]
        st = state(sdef["hour"], sdef["clocks"][0])
        p = os.path.join(EVIDENCE_DIR, "cross_%s.png" % nm)
        hs.cross_sheet(nm, faces, render_pano(faces, 0.0, st, w=1024), dict(hdri="procedural"), p)
        out.append(p)
    # 7. the swap steps (printed; job 0012 judges them)
    if {"night", "blue", "dawn"} <= set(built):
        for hour, a, b in ((19.5, "blue", "night"), (5.0, "night", "dawn")):
            st = state(hour)
            ma = mean_sky(built[a], sky_yaw(a, st), st)
            mb = mean_sky(built[b], sky_yaw(b, st), st)
            print("swap %04.1f %s -> %s: mean sky %s -> %s (EV dip %.2f)" % (hour, a, b, ma.round(1), mb.round(1),
                                                                            swap_dip(hour)))
    return out


# ---------------------------------------------------------------------------------------------------------------
# Fitting the engine transfer to real-engine shots of known faces
# ---------------------------------------------------------------------------------------------------------------


def shot_samples(s, gamma, step=2):
    """Per-pixel (dirs, rendered_lin at ref EV, face_lin ** gamma) for one calibration shot (HUD, unloaded / black
    pixels and everything outside 2..30 deg elevation masked)."""
    img = load_image(s["shot"])
    h, w = img.shape[:2]
    cam = s["camera"]
    dirs = camera_dirs(w, h, cam[:3], cam[3:], s.get("fov", 70.0))
    el = elevation(dirs)
    mask = (el > 2.0) & (el < 30.0) & (img.max(-1) > 3 / 255)
    for x0, y0, x1, y1 in s.get("hud", []):
        mask[y0:y1, x0:x1] = False
    sub = np.zeros_like(mask)
    sub[::step, ::step] = True
    mask &= sub
    faces = load_faces(s["faces"])
    g = dict(tint=s["tint"], saturation=s["saturation"], contrast=s["contrast"])
    r = lc.srgb_to_linear(np.clip(ungrade(img, g), 0, 1))[mask] / 2.0 ** (gamma * (s["exposure"] - ENGINE["ref_ev"]))
    t = lc.srgb_to_linear(sample_faces(faces, rot_y(dirs[mask], s["yaw"]))) ** gamma
    return dirs[mask], r, t


def _lsq(cols, y, wts):
    M = np.stack(cols, -1) * wts[:, None]
    sol, *_ = np.linalg.lstsq(M, y * wts, rcond=None)
    res = (np.stack(cols, -1) @ sol - y) * wts
    return sol, float(np.sqrt((res ** 2).mean()))


def fit(a):
    spec = json.load(open(a.spec))
    shots = spec["shots"]
    best = None
    for gamma in (1.0, 1.1, 1.2, 1.3, 1.4):
        data = [shot_samples(s, gamma) for s in shots]
        D = np.concatenate([d for d, _, _ in data])
        R = np.concatenate([r for _, r, _ in data])
        T = np.concatenate([t for _, _, t in data])
        # every shot weighs the same, and inside a shot every pixel relative to the shot's mean
        W = np.concatenate([np.full(len(r), 1.0 / (len(r) ** 0.5 * r[:, 1].mean())) for _, r, _ in data])
        el = elevation(D)
        for gs in (6.0, 10.0, 14.0, 20.0, 30.0):
            (gh, gl), err = _lsq([T[:, 1], np.exp(-el / gs) * T[:, 1]], R[:, 1], W)
            if best is None or err < best[0]:
                best = (err, gamma, gs, gh, gl, D, R, T, W, el)
    err, gamma, gs, gh, gl, D, R, T, W, el = best
    G = gh + gl * np.exp(-el / gs)
    sun = sun_dir(shots[0]["clock"])
    psi = sun_angle(D, sun)
    far = psi >= ENGINE["psi1"]
    (rg,), _ = _lsq([(G * T[:, 0])[far]], R[far, 0], W[far])
    bbest = None
    for bs in (6.0, 10.0, 14.0, 18.0, 24.0, 32.0):
        (bh, bl), berr = _lsq([G * T[:, 2], np.exp(-el / bs) * G * T[:, 2]], R[:, 2], W)
        if bbest is None or berr < bbest[0]:
            bbest = (berr, bs, bh, bl)
    _, bs, bh, bl = bbest
    print("pixels %d over %d shots, psi %.0f..%.0f deg from the sun" % (len(R), len(shots), psi.min(), psi.max()))
    print("fit: gamma %.2f  G = %.4f + %.4f exp(-el / %.0f)  R/G %.3f  B/G = %.3f + %.3f exp(-el / %.0f)" % (
        gamma, gh, gl, gs, rg, bh, bl, bs))
    print("ENGINE in use: gamma %.2f g %.4f + %.4f / %.0f  rg %.2f (sun side %.2f)  bg %.3f + %.3f / %.0f" % (
        ENGINE["gamma"], ENGINE["g_high"], ENGINE["g_low"], ENGINE["g_scale"], ENGINE["rg_far"], ENGINE["rg_near"],
        ENGINE["bg_high"], ENGINE["bg_low"], ENGINE["bg_scale"]))
    # residual check of ENGINE per shot and band: rendered / modelled (1 = exact)
    for s in shots:
        d, r, t = shot_samples(s, ENGINE["gamma"])
        A = engine_gain(d, sun_dir(s["clock"]), ENGINE["ref_ev"])
        e = elevation(d)
        print(" ", s["name"][:60])
        for lo, hi in ((2, 6), (6, 12), (12, 20), (20, 30)):
            m = (e >= lo) & (e < hi)
            if m.sum() < 500:
                continue
            ratio = (r[m] * (A[m] * t[m])).sum(0) / ((A[m] * t[m]) ** 2).sum(0)
            print("    el %2d-%2d  data / ENGINE  R %.2f  G %.2f  B %.2f  (n %d)" % (lo, hi, *ratio, m.sum()))


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
    psi = sun_angle(dirs[mask], sun_dir(a.clock))
    e = el[mask]
    print("pixels %d  gamma %.2f  A at EV %+.1f: R %.4f G %.4f B %.4f  (R/G %.2f, B/G %.2f)  corr %s" % (
        mask.sum(), gam, ENGINE["ref_ev"], *gain, gain[0] / gain[1], gain[2] / gain[1], [round(c, 3) for c in corr]))
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
    if len(sys.argv) > 1 and sys.argv[1] == "fit":
        ap = argparse.ArgumentParser(prog="procedural_sky.py fit")
        ap.add_argument("--spec", default=SPEC)
        fit(ap.parse_args(sys.argv[2:]))
        return
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
    drop_skies([n for n in ("nightLate", "nightMild") if n not in SKY_DEFS])
    star_field = stars(6500, 7)
    built = {}
    for name in SKY_DEFS:
        if only and name not in only:
            continue
        faces, st, clip = build(name, star_field)
        write_sky(name, faces, st, clip)
        built[name] = {k: lc.load_rgb(os.path.join(lc.ROOT, f)) for k, f in
                       lc.read_json(os.path.join(lc.SKY_DIR, "skies.json"))["skies"][name]["files"].items()}
        print("%-6s EV %+.2f tint %s  clipped %.3f%%" % (name, st["ev"], st["grade"]["tint"], 100 * clip))
    if a.evidence:
        for p in evidence(built):
            print("evidence", lc.rel(p))


if __name__ == "__main__":
    main()
