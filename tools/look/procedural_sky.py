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
  night has one sky per hold (sun west before midnight: `night`; east after it: `nightLate`), swapped with the clock
  jump. Job 0012 shoots every one of these regions; add its shots to sky_calibration.json and re-run `fit`.
  A third check: job 0018's n02 (place v33, v2 world) shows the old night HDRI at (5, 1, 1), and the model of those
  faces at that view predicts (0-7, 0, 0): the "dark reddish-brown" night is that near-black red cast.

  The ceiling: a white face renders at most ~(65, 40, 32) at the night zenith and ~(74, 47, 59) at the horizon; at the
  blue hour's EV +1.0 ~(77, 43, 29) and ~(87, 51, 62) (G and B are the limits; `ceiling` prints the table). Targets stay
  under it; a pixel that would still clip is scaled down as a whole (hue kept).

Skies (six 1024 px faces each, the engine-verified mapping of hdri_to_skybox.py; one shared Dn face):
  night      clear night (evening hold): blue-black zenith, cool blue-grey horizon, subtle stars, faint warm city glow
             at sky azimuth 90 (= +X: the night sky does not follow the sun; LightingService parks horizonGlowAzimuth
             on +X, inland)
  nightLate  the same for the morning hold (00:00-05:00): a touch deeper, a fainter glow, more stars
  blue       dusk: amber glow on the sun side (sky azimuth 0 = glowAzimuth, kept on the engine sun), pale teal above
             it, a clear blue mid-sky, deep blue zenith, a few first stars
  dawn       dawn: the same build, pale peach-gold instead of amber

Commands
  python3 -I tools/look/procedural_sky.py [--only night,blue] [--evidence]
      faces -> assets/sky/<sky>/{ft,bk,lf,rt,up}.png + assets/sky/shared/dn_twilight.png (every sky's Dn),
      metadata -> assets/sky/skies.json (other skies untouched), previews -> docs/v2/evidence/look_night/
  python3 -I tools/look/procedural_sky.py fit [--spec tools/look/sky_calibration.json]
      refits ENGINE from every listed real-engine shot and prints the per-region residuals
  python3 -I tools/look/procedural_sky.py calibrate --shot <png> --faces <dir> --yaw <deg> --exposure <EV>
      --tint R,G,B --contrast C --saturation S [--camera x,y,z,lx,ly,lz] [--clock 18.2]
      one shot's transfer per region (diagnostic table)
  python3 -I tools/look/procedural_sky.py ceiling [--hours 18.9,22.5,2,5.3]
      what a WHITE face renders as (the brightest any texture can be) per elevation and side, at those game hours
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
from PIL import Image, ImageFilter  # noqa: E402

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


# Colour mixing happens in Oklab (perceptual), not in linear light: a linear-light blend of a warm glow and a cool
# blue passes through mauve / dull purple (R and B both stay up while G sags), and this dark that reads as the
# "reddish-brown" the sky must lose. In Oklab the same blend goes through a neutral grey.
_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]], np.float32)
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]], np.float32)
_M2I = np.linalg.inv(_M2).astype(np.float32)
_M1I = np.linalg.inv(_M1).astype(np.float32)


def oklab(lin):
    return np.cbrt(np.clip(lin, 0, None) @ _M1.T) @ _M2.T


def from_oklab(lab):
    return np.clip(((lab @ _M2I.T) ** 3) @ _M1I.T, 0, None)


def mix(a_lin, b_lin, w):
    """Blend two linear colours by w (0 = a, 1 = b) in Oklab."""
    a, b = oklab(a_lin), oklab(b_lin)
    return from_oklab(a + (b - a) * w)


def stop_profile(el, stops):
    """Vertical gradient through (elevation, display sRGB colour) stops, smoothstepped in Oklab; returns Oklab."""
    e = np.clip(el, 0, 90)[..., None]
    out = np.broadcast_to(oklab(L(stops[0][1])), e.shape[:-1] + (3,)).astype(np.float32)
    for (e0, _), (e1, c1) in zip(stops[:-1], stops[1:]):
        t = smoothstep(e0, e1, e)
        out = out + (oklab(L(c1)) - out) * t
    return out


# Control colours (display sRGB 0..255: what the frame should show at the sky's reference state). GTA V's clear night
# over the city: a deep blue (not black) zenith, a lighter cool blue-grey band at the horizon, stars, and a dim
# sodium glow only just above the city; its dusk: amber on the sun's side, a warm-grey then pale blue band above it,
# a clear blue mid-sky, deep blue overhead, a lighter blue earth shadow opposite. Both are far darker here than in GTA:
# the engine caps the sky at about G 45-55 / B 30-65 (module docstring), so the targets keep GTA's hue relations and
# use most of that ceiling, not GTA's brightness. `ceiling` prints it per region.
NIGHTS = {
    # 19:30-00:00 under the EVENING hold (engine sun -3 deg in the west)
    "night": dict(
        zenith=(6, 10, 24),  # blue-black (the B ceiling there is ~32; stars need headroom)
        mid=(12, 18, 36),  # at 12 deg
        horizon=(28, 36, 52),  # cool blue-grey
        glow=(70, 50, 28),  # warm sodium city glow the horizon blends toward (Oklab), centred on glow_az ...
        glow_mix=0.75,  # ... at most this much, right at the horizon, gone by ~8 deg
        glow_az=90.0,
        stars=1.0,
    ),
    # 00:00-05:00 under the MORNING hold (engine sun -3 deg in the east, on the city-glow side: cast less red there).
    # The late night: a slightly deeper dome, the city glow fainter (the city sleeps), a few more stars.
    "nightLate": dict(
        zenith=(5, 9, 22),
        mid=(11, 16, 33),
        horizon=(26, 33, 49),
        glow=(66, 48, 28),
        glow_mix=0.55,
        glow_az=90.0,
        stars=1.3,
    ),
}
NIGHT = NIGHTS["night"]
# Twilight: vertical stops (elevation deg, colour) on the sun side, right under the sun (core) and opposite (anti),
# blended by azimuth in Oklab. Job 0018 / 0011: the first build (zenith (5, 10, 22), mid (11, 21, 36), amber
# (70, 40, 16) at EV +0.6, mixed in linear light) read as night with a thin brown line and a dull purple belt. Now, at
# the blue hour's EV +1.0 (Config/Look), each band sits at ~85-95 % of the ceiling at its elevation (B ~65 at the
# horizon, ~44 at 30 deg, ~34 overhead), and the sequence is GTA's: amber -> warm grey -> pale blue -> clear blue ->
# deep blue. Overhead it stays about the night's zenith, so blue -> night is mostly the glow going.
TWILIGHT = {
    "blue": dict(
        sun=((0, (78, 49, 18)), (3.5, (72, 47, 24)), (8, (54, 46, 40)), (14, (25, 35, 48)), (30, (11, 22, 36)),
             (50, (8, 17, 30)), (90, (6, 12, 25))),
        core=((0, (80, 50, 17)), (3.5, (75, 48, 22)), (8, (56, 47, 40)), (14, (25, 35, 48)), (30, (11, 22, 36)),
              (50, (8, 17, 30)), (90, (6, 12, 25))),
        anti=((0, (28, 40, 58)), (5, (31, 38, 56)), (12, (17, 30, 47)), (30, (11, 22, 36)), (50, (8, 17, 30)),
              (90, (6, 12, 25))),
    ),
    "dawn": dict(  # pale peach-gold: softer and less orange than dusk (pink reads maroon this dark)
        sun=((0, (70, 48, 24)), (3.5, (66, 47, 30)), (8, (51, 46, 42)), (14, (24, 35, 46)), (30, (11, 21, 34)),
             (50, (8, 16, 29)), (90, (6, 12, 24))),
        core=((0, (72, 49, 23)), (3.5, (68, 48, 29)), (8, (52, 47, 42)), (14, (24, 35, 46)), (30, (11, 21, 34)),
              (50, (8, 16, 29)), (90, (6, 12, 24))),
        anti=((0, (27, 39, 56)), (5, (30, 37, 54)), (12, (16, 29, 45)), (30, (11, 21, 34)), (50, (8, 16, 29)),
              (90, (6, 12, 24))),
    ),
}


def night_target(dirs, T=NIGHT):
    el, az = elevation(dirs), azimuth(dirs)
    c = two_scale(el, L(T["zenith"]), L(T["mid"]), L(T["horizon"]))
    d = np.abs((az - T["glow_az"] + 180) % 360 - 180)
    e = np.clip(el, 0, None)
    glow = 0.8 * np.exp(-(d / 30) ** 2) * np.exp(-e / 3.0) + 0.2 * np.exp(-(d / 70) ** 2) * np.exp(-e / 7.0)
    c = mix(c, L(T["glow"]), (T["glow_mix"] * glow)[..., None])
    c = c * (1 + 0.05 * soft_noise(dirs, 11))[..., None]
    star_w = T.get("stars", 1.0) * smoothstep(3, 22, el) * (1 - 0.85 * np.clip(glow, 0, 1))
    return c, star_w


def twilight_target(dirs, T):
    """Sky-local: the sun glow at azimuth 0 (= glowAzimuth), just below the horizon."""
    el, az = elevation(dirs), azimuth(dirs)
    d = np.abs((az + 180) % 360 - 180)  # 0 = sun side, 180 = anti-sun
    w_sun = np.exp(-(d / 62) ** 2)[..., None]
    w_core = np.exp(-(d / 24) ** 2)[..., None]
    sun, core, anti = (stop_profile(el, T[k]) for k in ("sun", "core", "anti"))
    lab = anti + (sun - anti) * w_sun
    lab = lab + (core - lab) * w_core
    c = from_oklab(lab)
    c = c * (1 + 0.04 * soft_noise(dirs, 21))[..., None]
    star_w = 0.35 * smoothstep(38, 70, el) * smoothstep(70, 150, d)
    return c, star_w


# ---------------------------------------------------------------------------------------------------------------
# Building a sky
# ---------------------------------------------------------------------------------------------------------------

# The night skies do not follow the sun (their city glow stays inland), but the engine's cast does: the held sun is in
# the west until the midnight jump and in the east after it (the sun side, < 75 deg from it, is cast less red). So
# there are two night skies, each built for its own hold, swapped in the same tick as the clock jump (Look.SkySchedule):
# `night` for the evening hold and `nightLate` for the morning hold. (A sky with several `clocks` would be built for
# the geometric mean of their casts; the first build did that for one all-night sky, and it was exact for neither.)
SKY_DEFS = {
    "night": dict(kind="night", palette="night", hour=22.5, clocks=(18.2,), follow=False, celestial=False,
                  use="19:30-00:00 night: blue-black sky, cool horizon, subtle stars, faint warm city glow at +X"),
    "nightLate": dict(kind="night", palette="nightLate", hour=2.0, clocks=(5.8,), follow=False, celestial=False,
                      use="00:00-05:00 late night (morning hold): deeper blue-black, fainter city glow, more stars"),
    "blue": dict(kind="twilight", palette="blue", hour=18.9, clocks=(18.2,), follow=True, celestial=True,
                 use="18:21-19:30 dusk: amber glow on the sun side, clear blue mid-sky, deep blue zenith"),
    "dawn": dict(kind="twilight", palette="dawn", hour=5.3, clocks=(5.8,), follow=True, celestial=True,
                 use="05:00-05:39 dawn: pale peach-gold glow on the sun side, clear blue mid-sky, deep blue zenith"),
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
            tgt, star_w = night_target(dirs, NIGHTS[sdef["palette"]])
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
        hz = NIGHTS[sdef["palette"]]["horizon"]
        glow_az, horizon_az = 0.0, NIGHTS[sdef["palette"]]["glow_az"]
    else:
        hz = TWILIGHT[sdef["palette"]]["anti"][0][1]  # the anti-sun horizon stop
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

# Job 0012's cameras on the v2 world (job 0018's t02 / t13 framings; studio/jobs/0012-night-sky.md CAMERA). Only the
# view directions matter for a sky-only render.
CAMERAS = {
    "downtown_street": ((-342, 20.6, -222), (-100, 40, -222)),  # Crown Blvd, facing +X (east, toward the city glow)
    "overview_low_sw": ((-1400, 260, 1400), (-250, 30, -150)),  # the low south-west aerial (job 0018 t13 / g13)
    "sky_up": ((-330, 18, -222), (-330, 1018, -222)),  # straight up; image top = -Z (north)
}
JOB_HOURS = (19.0, 20.5, 22.5, 2.0, 5.5)  # studio/jobs/0012-night-sky.md (17.6 is under the day HDRI, not modelled)

# Real-engine frames whose sky is replaced by the model's render of the NEW faces (in-context previews). `faces` /
# `yaw` / `exposure` / grade describe what was on screen then; `mask` picks the old sky pixels: geometry (elevation
# above `min_el`), outside the HUD boxes, inside `box`, and the old sky's colour rule. `ev_now` is the exposure the
# current preset gives that hour (the city is rescaled by 2 ** (ev_now - exposure), linear; approximate).
CONTEXT_SHOTS = [
    dict(name="job 0018 n02_downtown_street (v2 world, 22.5)", sky="night", hour=22.5,
         shot="git:origin/studio-results:studio/results/0018/n02_downtown_street.png", exposure=0.8,
         # a chase camera ~12 back / 4 up facing +X, pitched ~17.6 deg down (the street's vanishing point at y ~295)
         camera=(-342, 20.6, -222, 658, 20.6 - 1000 * math.tan(math.radians(17.6)), -222), fov=70.0,
         box=(700, 0, 940, 292), rule="dark", hud=[]),
    dict(name="job 0011 B_n_default_overview_low_sw (v1 world, 22.5)", sky="night", hour=22.5,
         shot="git:origin/studio-results:studio/results/0011/B_n_default_overview_low_sw.png", exposure=0.8,
         camera=(-700, 180, -700, 0, 20, 0), fov=70.0, box=None, rule="reddish", hud=[[0, 400, 380, 1080]]),
    dict(name="job 0011 D_b_default_overview_low_sw (v1 world, blue hour 18.8)", sky="blue", hour=18.8,
         shot="git:origin/studio-results:studio/results/0011/D_b_default_overview_low_sw.png", exposure=0.6,
         camera=(-700, 180, -700, 0, 20, 0), fov=70.0, box=None, rule="reddish", hud=[[0, 405, 375, 690]]),
]


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


def old_name(name):
    """The HDRI sky at OLD_REV that a procedural sky replaced (before / after)."""
    return "night" if NIGHTS.get(name) else "blue"


def region_table(built):
    """Mean rendered colour (display 0..255) per sky region at each sky's reference state: the numbers behind "is it
    brown / does the gradient read". Sky-local azimuth 0 = the sun side (twilight) or the city-glow side (night)."""
    rows = []
    regions = (("zenith (60-90 deg)", 60, 90, None), ("mid, away (12-30)", 12, 30, "away"),
               ("mid, glow side (12-30)", 12, 30, "toward"), ("low, away (3-8)", 3, 8, "away"),
               ("low, glow side (3-8)", 3, 8, "toward"), ("horizon, glow side (0.5-3)", 0.5, 3, "toward"),
               ("horizon, away (0.5-3)", 0.5, 3, "away"))
    for nm, faces in built.items():
        sdef = SKY_DEFS[nm]
        st = state(sdef["hour"], sdef["clocks"][0])
        yaw = sky_yaw(nm, st)
        glow_world = (NIGHTS[nm]["glow_az"] - yaw) if nm in NIGHTS else sun_azimuth(st)
        for label, lo, hi, side in regions:
            az = (np.arange(180) + 0.5) * 2 - 180
            el = lo + (np.arange(24) + 0.5) / 24 * (hi - lo)
            A, E = np.meshgrid(az, el)
            rel = np.abs((A - glow_world + 180) % 360 - 180)
            keep = np.ones_like(rel, bool) if side is None else (rel < 45 if side == "toward" else rel > 135)
            dirs = dir_from(A[keep], E[keep])
            img = haze_overlay(forward(sample_faces(faces, rot_y(dirs, yaw)), engine_gain(dirs, st["sun"], st["ev"]),
                                       st["grade"]), dirs, st)
            c = img.mean(0) * 255
            h, s, v = colorsys_hsv(c / 255)
            rows.append("%-10s %-28s rgb (%5.1f %5.1f %5.1f)  hue %3.0f  sat %.2f  val %3.0f" % (
                nm, label, c[0], c[1], c[2], h * 360, s, v * 255))
    return rows


def colorsys_hsv(c):
    import colorsys
    return colorsys.rgb_to_hsv(*[float(x) for x in c])


def context_mask(img, dirs, spec):
    el = elevation(dirs)
    m = el > 0.4
    if spec["box"]:
        x0, y0, x1, y1 = spec["box"]
        box = np.zeros_like(m)
        box[y0:y1, x0:x1] = True
        m &= box
    for x0, y0, x1, y1 in spec["hud"]:
        m[y0:y1, x0:x1] = False
    r, g, b = img[..., 0], img[..., 1], img[..., 2]
    if spec["rule"] == "dark":
        m &= (img.max(-1) < 16 / 255) & (r >= g - 1 / 255) & (r >= b - 1 / 255)
    else:  # the maroon sky of jobs 0009 / 0011 (dark: the HUD's bright red / orange / magenta stays)
        m &= (r >= 1.08 * g) & (r >= b) & (img.max(-1) < 0.33)
    return m


def context_composite(spec, faces):
    """Real frame, sky pixels replaced by the model's render of `faces` at the CURRENT preset for that hour (the rest
    rescaled to the current exposure, linear, approximate)."""
    real = load_image(spec["shot"])
    h, w = real.shape[:2]
    c = spec["camera"]
    dirs = camera_dirs(w, h, c[:3], c[3:], spec["fov"])
    m = context_mask(real, dirs, spec)
    st = state(spec["hour"])
    new_sky = render_dirs(faces, dirs, sky_yaw(spec["sky"], st), st)
    gain = 2.0 ** (st["ev"] - spec["exposure"])
    city = lc.linear_to_srgb(np.clip(lc.srgb_to_linear(real) * gain, 0, 1))
    soft = np.asarray(Image.fromarray(lc.to_u8(m.astype(np.float32))).filter(ImageFilter.GaussianBlur(1.2)),
                      np.float32)[..., None] / 255.0
    out = city * (1 - soft) + new_sky * soft
    old_mean = real[m].mean(0) * 255 if m.any() else np.zeros(3)
    new_mean = new_sky[m].mean(0) * 255 if m.any() else np.zeros(3)
    return real, out, m, old_mean, new_mean, st


def render_dirs(faces, dirs, yaw, st):
    tex = sample_faces(faces, rot_y(dirs, yaw))
    return haze_overlay(forward(tex, engine_gain(dirs, st["sun"], st["ev"]), st["grade"]), dirs, st)


def evidence(built):
    out = []
    old = {"night": load_faces("git:%s:assets/sky/night" % OLD_REV), "blue": load_faces("git:%s:assets/sky/blue" % OLD_REV)}
    hud = "Sky only: the city covers the lower part in game; the engine's dusk haze band (0-2 deg) is overlaid."
    # 1. what job 0012 should see, at its five lock hours and three cameras
    imgs, labs = [], []
    for hour in JOB_HOURS:
        name = sky_at(hour)
        st = state(hour)
        for cam in ("downtown_street", "overview_low_sw", "sky_up"):
            imgs.append(render_view(built[name], CAMERAS[cam], sky_yaw(name, st), st))
            labs.append("%04.1f  %s  sky %s  EV %+.2f  clock %.2f" % (hour, cam, name, st["ev"], st["clock"]))
    out.append(tile(imgs, labs, 3, "Job 0012 preview: the NEW skies SIMULATED in-game (fitted engine transfer + the "
                    "preset's exposure and grade at each lock hour)", os.path.join(EVIDENCE_DIR, "job0012_sim.png"),
                    0.75, notes=(hud,)))
    # 2. before / after at the same hours
    imgs, labs = [], []
    for hour in (19.0, 22.5, 2.0, 5.5):
        name = sky_at(hour)
        oname = old_name(name)
        st = state(hour)
        for cam in ("overview_low_sw", "sky_up"):
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
        imgs.append(render_view(built[nm], CAMERAS["sky_up"], yaw, st))
        labs.append("%s  sky_up" % nm)
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
    # 6. in context: real engine frames (jobs 0011 / 0018) with the old sky replaced by the model's render of the new
    imgs, labs, notes = [], [], []
    for spec in CONTEXT_SHOTS:
        real, comp, m, old_mean, new_mean, st = context_composite(spec, built[spec["sky"]])
        h, w = real.shape[:2]
        size = (w // 2, h // 2)
        imgs.append(np.asarray(Image.fromarray(lc.to_u8(real)).resize(size, Image.LANCZOS)) / 255.0)
        labs.append("REAL  " + spec["name"])
        imgs.append(np.asarray(Image.fromarray(lc.to_u8(comp)).resize(size, Image.LANCZOS)) / 255.0)
        labs.append("NEW SKY '%s' (model), EV %+.2f now" % (spec["sky"], st["ev"]))
        notes.append("%s: old sky pixels mean (%.0f, %.0f, %.0f) -> new (%.0f, %.0f, %.0f), %d px" % (
            spec["name"], *old_mean, *new_mean, int(m.sum())))
        print("context", notes[-1])
    out.append(tile(imgs, labs, 2, "In context: real engine frames, the sky pixels replaced by the model's render of the "
                    "new faces at the current preset (rest of the frame rescaled to the new exposure; approximate)",
                    os.path.join(EVIDENCE_DIR, "in_context.png"), 0.85, notes=notes))
    # 7. cross sheets
    for nm, faces in built.items():
        sdef = SKY_DEFS[nm]
        st = state(sdef["hour"], sdef["clocks"][0])
        p = os.path.join(EVIDENCE_DIR, "cross_%s.png" % nm)
        hs.cross_sheet(nm, faces, render_pano(faces, 0.0, st, w=1024), dict(hdri="procedural"), p)
        out.append(p)
    # 8. the swap steps (printed; job 0012 judges them): what is on screen just before and just after each swap
    lines = []
    if set(SKY_DEFS) <= set(built):
        for hour, a, b in ((19.5, "blue", "night"), (0.0, "night", "nightLate"), (5.0, "nightLate", "dawn")):
            sa, sb = state(hour - 0.002), state(hour + 0.002)
            ma = mean_sky(built[a], sky_yaw(a, sa), sa)
            mb = mean_sky(built[b], sky_yaw(b, sb), sb)
            lines.append("swap %04.1f %s -> %s: mean sky %s -> %s (EV dip %.2f; engine clock %.2f -> %.2f)" % (
                hour, a, b, ma.round(1), mb.round(1), swap_dip(hour), sa["clock"], sb["clock"]))
    # 9. the region table
    lines += region_table(built)
    p = os.path.join(EVIDENCE_DIR, "regions.txt")
    with open(p, "w") as f:
        f.write("Rendered sky colours (model) per region at each sky's reference state; written by "
                "tools/look/procedural_sky.py --evidence\n")
        f.write("\n".join(lines) + "\n")
    for ln in lines:
        print(ln)
    out.append(p)
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


def ceiling(a):
    """Rendered display colour of a white face (the engine's ceiling) per elevation and side of the held sun."""
    for hour in (float(h) for h in a.hours.split(",")):
        st = state(hour)
        name = sky_at(hour)
        print("game %.2f  sky %s  EV %+.2f  engine clock %.2f  tint %s" % (hour, name, st["ev"], st["clock"],
                                                                         np.round(st["grade"]["tint"], 1).tolist()))
        sa = sun_azimuth(st)
        for el in (1, 5, 10, 20, 35, 60, 89):
            cells = []
            for rel in (0, 60, 120, 180):
                d = dir_from(np.float32(sa + rel), np.float32(el))[None]
                c = forward(np.ones((1, 3), np.float32), engine_gain(d, st["sun"], st["ev"]), st["grade"])[0] * 255
                cells.append("(%3.0f %3.0f %3.0f)" % tuple(c))
            print("  el %2d   %s" % (el, "  ".join(cells)))
        print("  (columns: 0 / 60 / 120 / 180 deg of azimuth from the held sun)")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "ceiling":
        ap = argparse.ArgumentParser(prog="procedural_sky.py ceiling")
        ap.add_argument("--hours", default="18.9,22.5,2,5.3")
        ceiling(ap.parse_args(sys.argv[2:]))
        return
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
    drop_skies([n for n in ("nightMild",) if n not in SKY_DEFS])
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
