#!/usr/bin/env python3
"""Renders the 512x512 store icons for every item in tools/monetization/spec.json.

Look (gta_ui_language.md §3): a dark charcoal panel, one bold off-white pictogram, Ignition Orange (#FF8A3D) as the
single accent, an orange rule under the pictogram, no words (tiny numerals only), no real brands. Game-pass icons
are shown circle-cropped by Roblox, so everything important stays inside a 230 px radius.

Each pictogram is drawn as SVG layers and composited with PIL:
  fill  - the pictogram (white, greys, orange)
  cut   - shapes erased from the fill, so seams and holes show the real background (not a painted-on dark colour)
  over  - badges drawn after the cut (numeral pill, gift badge)

Needs: pip install cairosvg pillow   (cairosvg uses the system libcairo)
Usage: python3 tools/monetization/icons.py [--only key,key]   -> assets/monetization/<key>.png + contact sheet
"""
import io
import json
import math
import os
import random
import sys

import cairosvg
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC = os.path.join(ROOT, "tools", "monetization", "spec.json")
SHEET = os.path.join(ROOT, "docs", "v2", "early", "monetization", "icons_sheet.png")

S = 512
SS = 2  # supersample factor
W = "#F0F0F0"  # Theme Text
G1 = "#B4B5BA"  # light grey (second plane)
G2 = "#7C7D83"  # mid grey (third plane)
G3 = "#4A4B50"  # dark grey (tyres, caps)
OR = "#FF8A3D"  # Accent (Ignition Orange)
ORD = "#C9621F"  # accent shade
INK = "#141517"  # ink on orange badges
RED = "#E03232"
BLUE = "#5DB6E5"
CX, CY = 256, 240  # pictogram centre (the rule sits under it)


def svg(body, defs=""):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{S * SS}" height="{S * SS}" viewBox="0 0 {S} {S}">'
        f"<defs>{defs}</defs>{body}</svg>"
    )


def render(body, defs=""):
    png = cairosvg.svg2png(bytestring=svg(body, defs).encode("utf-8"))
    return Image.open(io.BytesIO(png)).convert("RGBA")


# ---------------------------------------------------------------------------------------------------------------
# Shared parts
# ---------------------------------------------------------------------------------------------------------------


def bill(cx, cy, w, h, rot=0, fill=W, band=False, oval=True):
    """A banknote. Returns (fill, cut)."""
    f = f'<g transform="translate({cx},{cy}) rotate({rot})">'
    f += f'<rect x="{-w / 2}" y="{-h / 2}" width="{w}" height="{h}" rx="{h * 0.09}" fill="{fill}"/>'
    if band:
        f += f'<rect x="{-w * 0.09}" y="{-h / 2 - 5}" width="{w * 0.18}" height="{h + 10}" rx="3" fill="{OR}"/>'
    f += "</g>"
    c = f'<g transform="translate({cx},{cy}) rotate({rot})">'
    inset = h * 0.11
    sw = max(3.5, h * 0.045)
    c += (
        f'<rect x="{-w / 2 + inset}" y="{-h / 2 + inset}" width="{w - 2 * inset}" height="{h - 2 * inset}" '
        f'rx="{h * 0.05}" fill="none" stroke="#000" stroke-width="{sw}"/>'
    )
    if oval and not band:
        c += f'<ellipse cx="0" cy="0" rx="{h * 0.22}" ry="{h * 0.22}" fill="none" stroke="#000" stroke-width="{sw * 1.3}"/>'
    dx = w / 2 - inset - h * 0.2
    c += f'<circle cx="{-dx}" cy="0" r="{h * 0.07}" fill="#000"/><circle cx="{dx}" cy="0" r="{h * 0.07}" fill="#000"/>'
    c += "</g>"
    return f, c


def car_side(scale=1.0, cy=CY):
    """Low sports coupe facing right, centred on (CX, cy). Returns (body d, window d, details, wheels, wheel r, x0, y0).

    Local box: x 0..322, roof y 16, sill y 104, wheels r 26 at y 98 (ground 124)."""
    x0 = CX - 161 * scale
    y0 = cy - 70 * scale

    def p(x, y):
        return f"{x0 + x * scale:.1f} {y0 + y * scale:.1f}"

    body = (
        f"M {p(8, 104)} L {p(2, 76)} Q {p(2, 64)} {p(14, 62)} L {p(60, 58)} Q {p(100, 28)} {p(146, 24)} "
        f"L {p(184, 24)} Q {p(214, 26)} {p(240, 52)} L {p(300, 62)} Q {p(320, 66)} {p(322, 82)} L {p(318, 104)} Z"
    )
    window = f"M {p(84, 58)} Q {p(112, 34)} {p(146, 31)} L {p(182, 31)} Q {p(204, 33)} {p(224, 54)} Z"
    sw = 3.5 * scale
    details = (
        f'<line x1="{x0 + 112 * scale:.1f}" y1="{y0 + 92 * scale:.1f}" x2="{x0 + 214 * scale:.1f}" y2="{y0 + 92 * scale:.1f}" '
        f'stroke="#000" stroke-width="{sw:.1f}" stroke-linecap="round"/>'
        f'<line x1="{x0 + 14 * scale:.1f}" y1="{y0 + 69 * scale:.1f}" x2="{x0 + 312 * scale:.1f}" y2="{y0 + 71 * scale:.1f}" '
        f'stroke="#000" stroke-width="{sw:.1f}" stroke-linecap="round"/>'
    )
    wheels = [(x0 + 66 * scale, y0 + 98 * scale), (x0 + 258 * scale, y0 + 98 * scale)]
    pillar = (
        f'<rect x="{x0 + 112 * scale:.1f}" y="{y0 + 34 * scale:.1f}" width="{8 * scale:.1f}" height="{24 * scale:.1f}" '
        f'fill="{W}"/>'
    )
    return body, window, details + "|" + pillar, wheels, 26 * scale, x0, y0


def wheels_svg(wheels, r):
    f, c = "", ""
    for wx, wy in wheels:
        c += f'<circle cx="{wx}" cy="{wy}" r="{r * 1.24:.1f}" fill="#000"/>'
    over = ""
    for wx, wy in wheels:
        over += f'<circle cx="{wx}" cy="{wy}" r="{r}" fill="{G3}"/>'
        over += f'<circle cx="{wx}" cy="{wy}" r="{r * 0.55}" fill="{G1}"/>'
        over += f'<circle cx="{wx}" cy="{wy}" r="{r * 0.16}" fill="{G3}"/>'
    return f, c, over


def star(cx, cy, r_out, r_in, n=5, rot=-90):
    pts = []
    for i in range(n * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(rot + i * 180 / n)
        pts.append(f"{cx + r * math.cos(a):.1f},{cy + r * math.sin(a):.1f}")
    return " ".join(pts)


def sparkle(cx, cy, r, fill=W):
    k = r * 0.22
    d = (
        f"M {cx} {cy - r} Q {cx + k} {cy - k} {cx + r} {cy} Q {cx + k} {cy + k} {cx} {cy + r} "
        f"Q {cx - k} {cy + k} {cx - r} {cy} Q {cx - k} {cy - k} {cx} {cy - r} Z"
    )
    return f'<path d="{d}" fill="{fill}"/>'


def arrow_arc(cx, cy, r, a0, a1, width, color, head=26):
    """Arc from a0 to a1 (degrees, clockwise in screen space) with an arrowhead at a1."""
    x0, y0 = cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0))
    a1s = a1 - math.degrees(head * 0.55 / r)
    x1, y1 = cx + r * math.cos(math.radians(a1s)), cy + r * math.sin(math.radians(a1s))
    large = 1 if (a1s - a0) % 360 > 180 else 0
    s = (
        f'<path d="M {x0:.1f} {y0:.1f} A {r} {r} 0 {large} 1 {x1:.1f} {y1:.1f}" fill="none" stroke="{color}" '
        f'stroke-width="{width}" stroke-linecap="round"/>'
    )
    # head: tangent direction at a1 (clockwise)
    ax, ay = cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1))
    t = math.radians(a1 + 90)
    n = math.radians(a1)
    tipx, tipy = ax + math.cos(t) * head * 0.6, ay + math.sin(t) * head * 0.6
    bx, by = ax - math.cos(t) * head * 0.6, ay - math.sin(t) * head * 0.6
    p1 = (bx + math.cos(n) * head * 0.85, by + math.sin(n) * head * 0.85)
    p2 = (bx - math.cos(n) * head * 0.85, by - math.sin(n) * head * 0.85)
    s += (
        f'<polygon points="{tipx:.1f},{tipy:.1f} {p1[0]:.1f},{p1[1]:.1f} {p2[0]:.1f},{p2[1]:.1f}" '
        f'fill="{color}" stroke="{color}" stroke-width="6" stroke-linejoin="round"/>'
    )
    return s


# ---------------------------------------------------------------------------------------------------------------
# Pictograms: each returns dict(fill=, cut=, over=, defs=)
# ---------------------------------------------------------------------------------------------------------------


def g_cash_stack():
    f, c = "", ""
    for i, (dx, dy, col) in enumerate([(-22, -30, G2), (-11, -15, G1), (0, 0, W)]):
        bf, bc = bill(CX + 4 + dx, CY + 26 + dy, 250, 128, 0, col, band=(i == 2))
        f += bf
        if i == 2:
            c += bc
        else:
            # back bills only show their top/left edge; a seam separates them from the next one
            pass
    # seams between stacked bills (outline of the bill in front, slightly larger)
    for dx, dy in [(-11, -15), (0, 0)]:
        c += (
            f'<rect x="{CX + 4 + dx - 125 - 5}" y="{CY + 26 + dy - 64 - 5}" width="260" height="138" rx="14" '
            f'fill="none" stroke="#000" stroke-width="6"/>'
        )
    return dict(fill=f, cut=c)


def g_cash2x():
    f1, c1 = bill(CX - 26, CY - 10, 230, 120, -14, G1)
    f2, c2 = bill(CX + 10, CY + 22, 230, 120, 6, W)
    seam = (
        f'<g transform="translate({CX + 10},{CY + 22}) rotate(6)"><rect x="-121" y="-66" width="242" height="132" '
        f'rx="14" fill="none" stroke="#000" stroke-width="8"/></g>'
    )
    return dict(fill=f1 + f2, cut=seam + c2, badge="2×")


def g_crown():
    f = (
        f'<path d="M 150 300 L 130 178 L 198 232 L 256 146 L 314 232 L 382 178 L 362 300 Z" fill="{W}" '
        f'stroke="{W}" stroke-width="10" stroke-linejoin="round"/>'
    )
    f += f'<circle cx="130" cy="170" r="17" fill="{W}"/><circle cx="256" cy="136" r="17" fill="{W}"/>'
    f += f'<circle cx="382" cy="170" r="17" fill="{W}"/>'
    f += f'<rect x="146" y="314" width="220" height="42" rx="8" fill="{W}"/>'
    f += f'<polygon points="256,236 282,266 256,296 230,266" fill="{OR}"/>'
    c = '<circle cx="196" cy="272" r="11" fill="#000"/><circle cx="316" cy="272" r="11" fill="#000"/>'
    c += '<rect x="160" y="330" width="192" height="8" rx="4" fill="#000"/>'
    return dict(fill=f, cut=c)


def g_garage():
    f = f'<path d="M 124 214 L 256 134 L 388 214 L 388 362 L 124 362 Z" fill="{W}" stroke="{W}" stroke-width="12" stroke-linejoin="round"/>'
    c = '<rect x="166" y="232" width="180" height="136" rx="4" fill="#000"/>'
    over = ""
    for i, y in enumerate([244, 268, 292, 316]):
        over += f'<rect x="178" y="{y}" width="156" height="16" rx="3" fill="{G1 if i < 3 else G2}"/>'
    c += '<rect x="226" y="176" width="60" height="16" rx="4" fill="#000"/>'
    return dict(fill=f, cut=c, over=over, badge="+2")


def g_vault():
    f = f'<rect x="124" y="112" width="264" height="256" rx="26" fill="{W}"/>'
    f += f'<rect x="146" y="362" width="48" height="20" rx="4" fill="{G2}"/><rect x="318" y="362" width="48" height="20" rx="4" fill="{G2}"/>'
    hx, hy = CX + 12, CY
    c = f'<circle cx="{hx}" cy="{hy}" r="98" fill="none" stroke="#000" stroke-width="12"/>'
    c += f'<circle cx="{hx}" cy="{hy}" r="72" fill="none" stroke="#000" stroke-width="5"/>'
    c += '<rect x="134" y="150" width="18" height="50" rx="5" fill="#000"/><rect x="134" y="280" width="18" height="50" rx="5" fill="#000"/>'
    over = ""
    for k in range(3):
        a = math.radians(-90 + k * 120)
        ex, ey = hx + 56 * math.cos(a), hy + 56 * math.sin(a)
        over += f'<line x1="{hx}" y1="{hy}" x2="{ex:.1f}" y2="{ey:.1f}" stroke="{G3}" stroke-width="15" stroke-linecap="round"/>'
        over += f'<circle cx="{ex:.1f}" cy="{ey:.1f}" r="12" fill="{G3}"/>'
    over += f'<circle cx="{hx}" cy="{hy}" r="24" fill="{OR}"/>'
    return dict(fill=f, cut=c, over=over)


def g_autocollect():
    bf, bc = bill(CX, CY, 184, 100, 0, W)
    f = bf
    f += arrow_arc(CX, CY, 146, 198, 334, 22, OR, head=38)
    f += arrow_arc(CX, CY, 146, 18, 154, 22, OR, head=38)
    return dict(fill=f, cut=bc)


def g_neon():
    sc = 1.16
    body, window, details, wheels, r, x0, y0 = car_side(sc, CY - 4)
    glow = (
        '<radialGradient id="glow" cx="50%" cy="50%" r="50%">'
        f'<stop offset="0" stop-color="{OR}" stop-opacity="0.95"/>'
        f'<stop offset="0.5" stop-color="{OR}" stop-opacity="0.42"/>'
        f'<stop offset="1" stop-color="{OR}" stop-opacity="0"/></radialGradient>'
    )
    gy = y0 + 120 * sc
    under = f'<ellipse cx="{CX}" cy="{gy:.1f}" rx="214" ry="42" fill="url(#glow)"/>'
    under += f'<rect x="{CX - 96}" y="{gy - 12:.1f}" width="192" height="6" rx="3" fill="{OR}"/>'
    details, pillar = details.split("|")
    f = f'<path d="{body}" fill="{W}"/>'
    c = f'<path d="{window}" fill="#000"/>' + details
    wf, wc, wo = wheels_svg(wheels, r)
    return dict(fill=f, cut=c + wc, over=wo + pillar, under=under, defs=glow, rule=False)


def g_plate():
    f = f'<rect x="100" y="150" width="312" height="164" rx="20" fill="{W}"/>'
    c = '<rect x="114" y="164" width="284" height="136" rx="12" fill="none" stroke="#000" stroke-width="6"/>'
    c += '<circle cx="146" cy="184" r="7" fill="#000"/><circle cx="366" cy="184" r="7" fill="#000"/>'
    c += '<rect x="208" y="178" width="96" height="10" rx="4" fill="#000"/>'  # region line
    c += '<rect x="196" y="282" width="120" height="7" rx="3" fill="#000"/>'  # frame line
    # main characters: 3 + 3 slim blocks (no letters)
    for x in (134, 166, 198, 262, 294, 326):
        c += f'<rect x="{x}" y="204" width="24" height="66" rx="6" fill="#000"/>'
    c += '<rect x="234" y="232" width="12" height="10" rx="3" fill="#000"/>'
    # orange pen writing the plate
    t = "translate(404,336) rotate(-38)"
    pen = f'<g transform="{t}">'
    pen += f'<rect x="-14" y="-108" width="28" height="100" rx="5" fill="{OR}"/>'
    pen += f'<rect x="-14" y="-122" width="28" height="16" rx="5" fill="{ORD}"/>'
    pen += f'<polygon points="-14,-8 14,-8 0,22" fill="{W}"/><polygon points="-5,12 5,12 0,22" fill="{G3}"/></g>'
    penc = (
        f'<g transform="{t}"><rect x="-24" y="-132" width="48" height="124" rx="10" '
        'fill="#000"/><polygon points="-24,-8 24,-8 0,36" fill="#000"/></g>'
    )
    return dict(fill=f, cut=c + penc, over=pen)


def g_horn():
    f = f'<rect x="110" y="170" width="52" height="148" rx="14" fill="{W}"/>'
    f += f'<path d="M 156 178 L 252 178 L 336 140 Q 346 136 346 148 L 346 234 Q 346 246 336 242 L 252 204 L 156 204 Z" fill="{W}" stroke="{W}" stroke-width="6" stroke-linejoin="round"/>'
    f += f'<path d="M 156 274 L 216 274 L 284 246 Q 294 242 294 254 L 294 326 Q 294 338 284 334 L 216 306 L 156 306 Z" fill="{G1}" stroke="{G1}" stroke-width="6" stroke-linejoin="round"/>'
    c = '<rect x="156" y="170" width="8" height="148" fill="#000"/>'
    c += '<rect x="124" y="226" width="24" height="8" rx="3" fill="#000"/><rect x="124" y="250" width="24" height="8" rx="3" fill="#000"/>'
    over = ""
    for r in (34, 64):
        a0 = math.radians(40)
        x0, y0 = 354 + r * math.cos(-a0), 192 + r * math.sin(-a0)
        x1, y1 = 354 + r * math.cos(a0), 192 + r * math.sin(a0)
        over += (
            f'<path d="M {x0:.1f} {y0:.1f} A {r} {r} 0 0 1 {x1:.1f} {y1:.1f}" fill="none" stroke="{OR}" '
            f'stroke-width="13" stroke-linecap="round"/>'
        )
    for r in (30,):
        a0 = math.radians(40)
        x0, y0 = 302 + r * math.cos(-a0), 290 + r * math.sin(-a0)
        x1, y1 = 302 + r * math.cos(a0), 290 + r * math.sin(a0)
        over += (
            f'<path d="M {x0:.1f} {y0:.1f} A {r} {r} 0 0 1 {x1:.1f} {y1:.1f}" fill="none" stroke="{OR}" '
            f'stroke-width="12" stroke-linecap="round"/>'
        )
    return dict(fill=f, cut=c, over=over)


def g_emote():
    sw = 32
    pl = f'fill="none" stroke="{W}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"'
    f = f'<circle cx="252" cy="128" r="32" fill="{W}"/>'
    f += f'<polyline points="254,186 250,268" {pl}/>'
    f += f'<polyline points="252,196 198,168 178,112" {pl}/>'
    f += f'<polyline points="254,196 312,178 342,132" {pl}/>'
    f += f'<polyline points="250,268 218,314 204,362" {pl}/>'
    f += f'<polyline points="250,268 302,302 338,284" {pl}/>'
    over = ""
    for r in (28, 52):
        over += (
            f'<path d="M {354 + r * math.cos(math.radians(-150)):.1f} {120 + r * math.sin(math.radians(-150)):.1f} '
            f'A {r} {r} 0 0 1 {354 + r * math.cos(math.radians(-30)):.1f} {120 + r * math.sin(math.radians(-30)):.1f}" '
            f'fill="none" stroke="{OR}" stroke-width="10" stroke-linecap="round"/>'
        )
    over += f'<path d="M 144 96 A 40 40 0 0 0 136 152" fill="none" stroke="{OR}" stroke-width="10" stroke-linecap="round"/>'
    c = '<circle cx="252" cy="128" r="44" fill="none" stroke="#000" stroke-width="10"/>'
    return dict(fill=f, cut=c, over=over)


def g_briefcase():
    f = (
        f'<path d="M 212 184 V 158 Q 212 140 230 140 H 282 Q 300 140 300 158 V 184" fill="none" stroke="{W}" '
        f'stroke-width="18"/>'
    )
    f += f'<rect x="112" y="176" width="288" height="180" rx="24" fill="{W}"/>'
    c = '<rect x="112" y="222" width="288" height="8" fill="#000"/>'
    c += '<rect x="158" y="208" width="44" height="36" rx="8" fill="#000"/><rect x="310" y="208" width="44" height="36" rx="8" fill="#000"/>'
    c += '<rect x="112" y="168" width="288" height="8" fill="#000"/>'
    over = f'<rect x="164" y="214" width="32" height="24" rx="5" fill="{OR}"/><rect x="316" y="214" width="32" height="24" rx="5" fill="{OR}"/>'
    return dict(fill=f, cut=c, over=over)


def g_armored_case():
    grad = (
        '<linearGradient id="alu" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="#FAFAFA"/><stop offset="1" stop-color="#B7B9BE"/></linearGradient>'
    )
    f = f'<rect x="196" y="140" width="120" height="44" rx="14" fill="{W}"/>'
    f += f'<rect x="100" y="172" width="312" height="196" rx="18" fill="url(#alu)"/>'
    c = '<rect x="218" y="154" width="76" height="22" rx="8" fill="#000"/><rect x="196" y="170" width="120" height="8" fill="#000"/>'
    # ribs
    for y in (210, 324):
        c += f'<rect x="100" y="{y}" width="312" height="6" fill="#000"/>'
    # corner protector seams
    for x, y in [(100, 172), (412, 172), (100, 368), (412, 368)]:
        c += f'<circle cx="{x}" cy="{y}" r="44" fill="none" stroke="#000" stroke-width="6"/>'
    c += '<rect x="214" y="240" width="84" height="62" rx="10" fill="#000"/>'
    over = ""
    for x, y in [(100, 172), (412, 172), (100, 368), (412, 368)]:
        over += f'<circle cx="{x}" cy="{y}" r="40" fill="{G2}" clip-path="url(#caseclip)"/>'
    over += f'<rect x="220" y="246" width="72" height="50" rx="7" fill="{OR}"/>'
    over += f'<circle cx="256" cy="266" r="8" fill="{INK}"/><rect x="252" y="268" width="8" height="18" rx="2" fill="{INK}"/>'
    defs = grad + '<clipPath id="caseclip"><rect x="100" y="172" width="312" height="196" rx="18"/></clipPath>'
    return dict(fill=f, cut=c, over=over, defs=defs)


def g_key():
    t = f"translate({CX + 6},{CY + 4}) rotate(-35)"
    f = f'<g transform="{t}">'
    f += f'<rect x="-58" y="-128" width="116" height="168" rx="46" fill="{W}"/>'
    f += f'<path d="M -16 40 L 16 40 L 16 150 L 0 168 L -16 150 Z" fill="{G1}"/>'
    f += "</g>"
    c = f'<g transform="{t}">'
    c += '<circle cx="0" cy="-104" r="11" fill="#000"/>'
    c += '<rect x="-36" y="-72" width="72" height="34" rx="12" fill="#000"/>'
    c += '<rect x="-36" y="-28" width="72" height="34" rx="12" fill="#000"/>'
    c += '<rect x="-58" y="34" width="116" height="10" fill="#000"/>'
    c += '<rect x="-4" y="70" width="8" height="74" rx="3" fill="#000"/>'
    c += "</g>"
    over = f'<g transform="{t}"><rect x="-28" y="-64" width="56" height="18" rx="7" fill="{OR}"/></g>'
    over += sparkle(150, 136, 26)
    over += sparkle(372, 330, 16, G1)
    return dict(fill=f, cut=c, over=over)


def g_padlock():
    f = (
        f'<path d="M 196 232 V 180 A 60 60 0 0 1 316 180 V 232" fill="none" stroke="{W}" stroke-width="32" '
        f'stroke-linecap="butt"/>'
    )
    f += f'<rect x="160" y="220" width="192" height="152" rx="24" fill="{W}"/>'
    c = '<rect x="160" y="212" width="192" height="8" fill="#000"/>'
    c += '<rect x="226" y="262" width="60" height="72" rx="12" fill="#000"/>'
    over = f'<rect x="232" y="268" width="48" height="60" rx="9" fill="{OR}"/>'
    over += f'<circle cx="256" cy="290" r="9" fill="{INK}"/><rect x="252" y="292" width="8" height="22" rx="2" fill="{INK}"/>'
    return dict(fill=f, cut=c, over=over)


def g_siren_off():
    f = f'<rect x="112" y="252" width="288" height="44" rx="12" fill="{W}"/>'
    f += f'<rect x="96" y="296" width="320" height="20" rx="6" fill="{G1}"/>'
    f += f'<path d="M 128 252 V 214 Q 128 176 166 176 H 250 V 252 Z" fill="{RED}"/>'
    f += f'<path d="M 262 252 V 176 H 346 Q 384 176 384 214 V 252 Z" fill="{BLUE}"/>'
    c = '<rect x="250" y="170" width="12" height="90" fill="#000"/>'
    c += '<rect x="112" y="246" width="288" height="8" fill="#000"/>'
    # rays
    over = ""
    for x1, y1, x2, y2 in [(170, 150, 160, 118), (210, 146, 210, 112), (302, 146, 302, 112), (342, 150, 352, 118)]:
        over += f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{G2}" stroke-width="10" stroke-linecap="round"/>'
    # the "off" slash
    slash_c = '<line x1="128" y1="372" x2="384" y2="116" stroke="#000" stroke-width="58" stroke-linecap="round"/>'
    over += f'<line x1="134" y1="366" x2="378" y2="122" stroke="{OR}" stroke-width="30" stroke-linecap="round"/>'
    return dict(fill=f, cut=c + slash_c, over=over)


def g_barrier():
    f = f'<rect x="120" y="196" width="36" height="170" rx="8" fill="{W}"/>'
    f += f'<rect x="104" y="356" width="68" height="20" rx="5" fill="{G1}"/>'
    arm = '<g transform="translate(138,214) rotate(-48)">'
    arm += f'<rect x="-16" y="-17" width="276" height="34" rx="17" fill="{W}"/>'
    for x in (44, 114, 184):
        arm += f'<polygon points="{x},-17 {x + 34},-17 {x + 20},17 {x - 14},17" fill="{OR}"/>'
    arm += "</g>"
    f += arm
    c = '<circle cx="138" cy="214" r="12" fill="#000"/>'
    c += '<g transform="translate(138,214) rotate(-48)"><rect x="-26" y="-27" width="296" height="54" rx="27" fill="none" stroke="#000" stroke-width="6"/></g>'
    # car front driving out
    car = f'<path d="M 232 374 V 318 Q 232 300 250 296 L 270 262 Q 276 252 290 252 L 346 252 Q 360 252 366 262 L 386 296 Q 404 300 404 318 V 374 Z" fill="{W}"/>'
    car += f'<rect x="242" y="366" width="34" height="22" rx="5" fill="{G3}"/><rect x="360" y="366" width="34" height="22" rx="5" fill="{G3}"/>'
    carc = '<path d="M 276 294 L 290 266 L 346 266 L 360 294 Z" fill="#000"/>'
    carc += '<circle cx="258" cy="326" r="12" fill="#000"/><circle cx="378" cy="326" r="12" fill="#000"/>'
    carc += '<rect x="290" y="318" width="56" height="16" rx="4" fill="#000"/>'
    return dict(fill=f + car, cut=c + carc)


def g_wrench():
    t = f"translate({CX + 4},{CY + 6}) rotate(45)"
    f = f'<g transform="{t}"><rect x="-22" y="-60" width="44" height="200" rx="22" fill="{W}"/>'
    f += f'<circle cx="0" cy="-92" r="62" fill="{W}"/></g>'
    c = f'<g transform="{t}"><rect x="-21" y="-168" width="42" height="84" rx="6" fill="#000"/>'
    c += '<circle cx="0" cy="112" r="12" fill="#000"/></g>'
    bolt = f'<polygon points="368,98 318,190 352,190 330,268 396,158 360,158 384,98" fill="{OR}" stroke="{OR}" stroke-width="6" stroke-linejoin="round"/>'
    boltc = '<polygon points="368,98 318,190 352,190 330,268 396,158 360,158 384,98" fill="#000" stroke="#000" stroke-width="30" stroke-linejoin="round"/>'
    return dict(fill=f, cut=c + boltc, over=bolt)


def g_clover():
    f = ""
    leaf = (
        "M 0 -6 C -18 -24 -62 -44 -62 -88 C -62 -116 -34 -128 -16 -116 C -8 -110 -2 -102 0 -94 "
        "C 2 -102 8 -110 16 -116 C 34 -128 62 -116 62 -88 C 62 -44 18 -24 0 -6 Z"
    )
    for a in (45, 135, 225, 315):
        f += f'<g transform="translate({CX},{CY - 8}) rotate({a})"><path d="{leaf}" fill="{W}"/></g>'
    f += f'<path d="M {CX} {CY - 8} Q {CX + 14} {CY + 80} {CX + 58} {CY + 132}" fill="none" stroke="{W}" stroke-width="18" stroke-linecap="round"/>'
    c = ""
    for a in (0, 90):
        c += f'<g transform="translate({CX},{CY - 8}) rotate({a})"><rect x="-4" y="-140" width="8" height="280" fill="#000"/></g>'
    c += f'<circle cx="{CX}" cy="{CY - 8}" r="10" fill="#000"/>'
    return dict(fill=f, cut=c, badge="×2")


def g_money_rain():
    f, c = "", ""
    notes = [
        (176, 134, -20, G2), (320, 124, 18, G2),
        (250, 206, 8, G1), (126, 250, 26, G1), (392, 236, -28, G1),
        (330, 304, -14, W), (190, 318, -4, W),
    ]
    for i, (x, y, r, col) in enumerate(notes):
        bf, bc = bill(x, y, 120, 64, r, col, band=(i == 6))
        f += bf
        if col == W:
            c += bc
        else:
            # simple centre mark on the far notes
            c += f'<g transform="translate({x},{y}) rotate({r})"><circle cx="0" cy="0" r="10" fill="none" stroke="#000" stroke-width="4"/></g>'
    # speed streaks
    over = ""
    for x, y in [(118, 190), (396, 170), (252, 150), (262, 270)]:
        over += f'<line x1="{x}" y1="{y - 22}" x2="{x}" y2="{y}" stroke="{G2}" stroke-width="6" stroke-linecap="round"/>'
    return dict(fill=f, cut=c, over=over)


def g_duffel():
    f = f'<path d="M 200 214 Q 200 150 256 150 Q 312 150 312 214" fill="none" stroke="{W}" stroke-width="20" stroke-linecap="round"/>'
    f += f'<rect x="104" y="204" width="304" height="152" rx="66" fill="{W}"/>'
    c = '<ellipse cx="164" cy="280" rx="26" ry="70" fill="none" stroke="#000" stroke-width="7"/>'
    c += '<ellipse cx="348" cy="280" rx="26" ry="70" fill="none" stroke="#000" stroke-width="7"/>'
    c += '<rect x="176" y="230" width="160" height="7" rx="3" fill="#000"/>'
    c += '<rect x="192" y="198" width="128" height="12" rx="4" fill="#000"/>'
    over = f'<rect x="300" y="226" width="22" height="40" rx="6" fill="{OR}"/>'
    over += f'<rect x="196" y="300" width="120" height="10" rx="4" fill="{G1}"/>'
    return dict(fill=f, cut=c, over=over, badge="×2")


def g_tint(metal):
    if metal == "gold":
        stops = ("#FFE9A8", "#D6B563", "#8E6E28")
    else:
        stops = ("#FFFFFF", "#C9D1D9", "#7D8791")
    grad = (
        '<linearGradient id="metal" x1="0" y1="0" x2="0.35" y2="1">'
        f'<stop offset="0" stop-color="{stops[0]}"/><stop offset="0.5" stop-color="{stops[1]}"/>'
        f'<stop offset="1" stop-color="{stops[2]}"/></linearGradient>'
    )
    gun = (
        "M 104 186 Q 104 174 116 174 L 384 174 Q 396 174 396 186 L 396 226 Q 396 236 386 236 L 380 236 "
        "L 404 352 Q 408 370 390 372 L 330 376 Q 314 376 312 362 L 300 300 Q 290 318 262 318 Q 230 316 226 280 "
        "L 226 252 L 150 252 L 150 236 L 116 236 Q 104 236 104 224 Z"
    )
    # swatch fan (top right), clear of the pistol
    chips = ""
    chipsc = ""
    for rot, col in [(-26, stops[2]), (-8, stops[1]), (10, stops[0])]:
        chips += (
            f'<g transform="translate(372,184) rotate({rot})"><rect x="-22" y="-96" width="44" height="96" '
            f'rx="9" fill="{col}"/><circle cx="0" cy="-14" r="5" fill="{G3}"/></g>'
        )
    for rot in (-8, 10):
        chipsc += (
            f'<g transform="translate(372,184) rotate({rot})"><rect x="-26" y="-100" width="52" height="104" '
            f'rx="12" fill="none" stroke="#000" stroke-width="5"/></g>'
        )
    f = chips
    T = "translate(-34,40) scale(0.94)"
    gunf = f'<g transform="{T}"><path d="{gun}" fill="url(#metal)"/></g>'
    gunc = f'<g transform="{T}">'
    gunc += f'<path d="{gun}" fill="none" stroke="#000" stroke-width="18" stroke-linejoin="round"/>'
    gunc += "</g>"
    det = f'<g transform="{T}">'
    det += '<rect x="226" y="186" width="56" height="18" rx="4" fill="#000"/>'
    for x in range(326, 380, 12):
        det += f'<rect x="{x}" y="184" width="5" height="40" rx="2" fill="#000"/>'
    det += '<ellipse cx="262" cy="280" rx="22" ry="20" fill="#000"/>'
    det += '<rect x="150" y="236" width="230" height="5" fill="#000"/>'
    det += "</g>"
    return dict(fill=f, cut=chipsc + gunc, over=gunf, over_cut=det, defs=grad)


def g_diamond_car():
    sc = 1.16
    body, window, details, wheels, r, x0, y0 = car_side(sc, CY - 4)
    details, pillar = details.split("|")

    def P(x, y):
        return (x0 + x * sc, y0 + y * sc)

    top = [P(-4, 66), P(36, 60), P(84, 40), P(146, 14), P(188, 14), P(236, 44), P(292, 58), P(330, 72)]
    mid = [P(-4, 84), P(52, 80), P(112, 74), P(168, 72), P(222, 74), P(276, 78), P(330, 86)]
    bot = [P(-4, 112), P(44, 112), P(108, 112), P(166, 112), P(226, 112), P(286, 112), P(330, 112)]
    shades = ["#F4FBFF", "#9ED6F1", "#D2EEFB", "#64BBE5", "#E6F6FE", "#B9E2F6"]
    tris = []
    for i in range(len(mid) - 1):
        tris.append((top[i], top[i + 1], mid[i]))
        tris.append((top[i + 1], mid[i + 1], mid[i]))
        tris.append((mid[i], mid[i + 1], bot[i]))
        tris.append((mid[i + 1], bot[i + 1], bot[i]))
    tris.append((top[-2], top[-1], mid[-1]))
    fills, lines = "", ""
    for k, tri in enumerate(tris):
        pts = " ".join(f"{q[0]:.1f},{q[1]:.1f}" for q in tri)
        col = shades[(k * 5 + k // 4) % len(shades)]
        fills += f'<polygon points="{pts}" fill="{col}" stroke="{col}" stroke-width="1"/>'
        lines += f'<polygon points="{pts}" fill="none" stroke="#000" stroke-width="3.2" stroke-linejoin="round"/>'
    defs = f'<clipPath id="carclip"><path d="{body}"/></clipPath>'
    f = f'<g clip-path="url(#carclip)">{fills}</g>'
    c = f'<g clip-path="url(#carclip)">{lines}</g>'
    c += f'<path d="{window}" fill="#000" opacity="0.5"/>'
    wf, wc, wo = wheels_svg(wheels, r)
    over = wo + sparkle(330, 132, 24) + sparkle(374, 162, 12, BLUE)
    return dict(fill=f, cut=c + wc, over=over, defs=defs)


def g_ticket():
    t = f"translate({CX},{CY + 4}) rotate(-10)"
    f = f'<g transform="{t}"><rect x="-160" y="-84" width="320" height="168" rx="16" fill="{W}"/></g>'
    c = f'<g transform="{t}">'
    c += '<circle cx="-160" cy="0" r="24" fill="#000"/><circle cx="160" cy="0" r="24" fill="#000"/>'
    for y in range(-70, 80, 20):
        c += f'<rect x="-66" y="{y}" width="6" height="11" rx="2" fill="#000"/>'
    for i, (y, w) in enumerate([(-38, 120), (-8, 150), (22, 96)]):
        c += f'<rect x="-30" y="{y}" width="{w}" height="14" rx="5" fill="#000"/>'
    c += "</g>"
    over = f'<g transform="{t}"><polygon points="{star(-112, 0, 38, 16)}" fill="{OR}" stroke="{OR}" stroke-width="4" stroke-linejoin="round"/></g>'
    return dict(fill=f, cut=c, over=over)


GLYPHS = {
    "cash2x": g_cash2x,
    "vip": g_crown,
    "slots": g_garage,
    "vault": g_vault,
    "autocollect": g_autocollect,
    "neon": g_neon,
    "plates": g_plate,
    "horns": g_horn,
    "emotes": g_emote,
    "cash_small": g_cash_stack,
    "cash_big": g_briefcase,
    "cash_huge": g_armored_case,
    "starter_pack": g_key,
    "lockdown": g_padlock,
    "lose_cops": g_siren_off,
    "impound_release": g_barrier,
    "rush_repair": g_wrench,
    "server_luck": g_clover,
    "make_it_rain": g_money_rain,
    "double_it": g_duffel,
    "tint_gold": lambda: g_tint("gold"),
    "tint_platinum": lambda: g_tint("platinum"),
    "diamond_dragster": g_diamond_car,
    "street_pass": g_ticket,
}

# ---------------------------------------------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------------------------------------------

BADGE_POS = (380, 128)
GIFT_POS = (384, 360)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
]


def background():
    defs = (
        '<radialGradient id="bg" cx="50%" cy="42%" r="70%">'
        '<stop offset="0" stop-color="#303136"/><stop offset="0.55" stop-color="#1A1B1E"/>'
        '<stop offset="1" stop-color="#0B0B0D"/></radialGradient>'
        '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.05"/><stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>'
        "</linearGradient>"
    )
    body = f'<rect width="{S}" height="{S}" fill="url(#bg)"/><rect width="{S}" height="{S}" fill="url(#sheen)"/>'
    body += f'<circle cx="256" cy="256" r="236" fill="none" stroke="#FFFFFF" stroke-opacity="0.06" stroke-width="2"/>'
    return render(body, defs)


def numeral_badge(text):
    x, y = BADGE_POS
    w = 46 + 30 * len(text)
    h = 64
    cut = f'<rect x="{x - w / 2 - 9}" y="{y - h / 2 - 9}" width="{w + 18}" height="{h + 18}" rx="{h / 2 + 9}" fill="#000"/>'
    pill = f'<rect x="{x - w / 2}" y="{y - h / 2}" width="{w}" height="{h}" rx="{h / 2}" fill="{OR}"/>'
    return cut, pill, (x, y, text)


def gift_badge():
    x, y = GIFT_POS
    r = 48
    cut = f'<circle cx="{x}" cy="{y}" r="{r + 9}" fill="#000"/>'
    g = f'<circle cx="{x}" cy="{y}" r="{r}" fill="{OR}"/>'
    # gift box glyph in ink
    g += f'<rect x="{x - 26}" y="{y - 8}" width="52" height="34" rx="4" fill="{INK}"/>'
    g += f'<rect x="{x - 30}" y="{y - 20}" width="60" height="14" rx="3" fill="{INK}"/>'
    g += f'<rect x="{x - 4}" y="{y - 20}" width="8" height="46" fill="{OR}"/>'
    g += f'<rect x="{x - 26}" y="{y - 8}" width="52" height="4" fill="{OR}"/>'
    g += (
        f'<path d="M {x} {y - 21} C {x - 6} {y - 36} {x - 26} {y - 38} {x - 22} {y - 26} C {x - 20} {y - 21} {x - 10} {y - 21} {x} {y - 21} Z" '
        f'fill="none" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>'
    )
    g += (
        f'<path d="M {x} {y - 21} C {x + 6} {y - 36} {x + 26} {y - 38} {x + 22} {y - 26} C {x + 20} {y - 21} {x + 10} {y - 21} {x} {y - 21} Z" '
        f'fill="none" stroke="{INK}" stroke-width="5" stroke-linejoin="round"/>'
    )
    return cut, g


def font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw_numerals(img, x, y, text):
    """Condensed bold numerals in ink, centred at (x, y) (512 space)."""
    size = 46 * SS
    f = font(size)
    tmp = Image.new("L", (size * len(text) * 2, size * 2), 0)
    d = ImageDraw.Draw(tmp)
    d.text((size // 2, size // 2), text, font=f, fill=255)
    bbox = tmp.getbbox()
    glyph = tmp.crop(bbox)
    gw, gh = glyph.size
    glyph = glyph.resize((int(gw * 0.86), gh), Image.LANCZOS)  # condense
    gw, gh = glyph.size
    ink = Image.new("RGBA", glyph.size, INK)
    img.paste(ink, (int(x * SS - gw / 2), int(y * SS - gh / 2)), glyph)


def icon(key, gift=False):
    spec = GLYPHS[key]()
    defs = spec.get("defs", "")
    bg = background()
    under = render(spec["under"], defs) if spec.get("under") else None
    fill = render(spec["fill"], defs)
    cut_body = spec.get("cut", "")
    over_body = spec.get("over", "")
    numer = None
    if spec.get("badge"):
        bcut, pill, numer = numeral_badge(spec["badge"])
        cut_body += bcut
    if gift:
        gcut, gbody = gift_badge()
        cut_body += gcut
    cut = render(cut_body, defs) if cut_body else None
    over = render(over_body, defs) if over_body else None
    if over is not None and spec.get("over_cut"):
        oc = render(spec["over_cut"], defs)
        over.putalpha(ImageChops.multiply(over.getchannel("A"), ImageChops.invert(oc.getchannel("A"))))
    glyph = Image.alpha_composite(fill, over) if over is not None else fill
    if cut is not None:
        keep = ImageChops.invert(cut.getchannel("A"))
        glyph.putalpha(ImageChops.multiply(glyph.getchannel("A"), keep))
        if over is not None:
            # parts of `over` that sit inside cuts on purpose (wheels, lock plates) come back on top
            glyph = Image.alpha_composite(glyph, over) if spec.get("over_after_cut", True) else glyph
    if spec.get("rule", True):
        glyph = Image.alpha_composite(glyph, render(f'<rect x="220" y="404" width="72" height="7" rx="3.5" fill="{OR}"/>'))
    if spec.get("badge"):
        glyph = Image.alpha_composite(glyph, render(pill))
        draw_numerals(glyph, *numer)
    if gift:
        glyph = Image.alpha_composite(glyph, render(gbody))

    # soft drop shadow for depth
    alpha = glyph.getchannel("A")
    shadow = Image.new("RGBA", glyph.size, (0, 0, 0, 0))
    shadow.putalpha(alpha.point(lambda a: int(a * 0.55)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(9 * SS))
    shadow = ImageChops.offset(shadow, 0, 8 * SS)
    out = Image.alpha_composite(bg, shadow)
    if under is not None:
        out = Image.alpha_composite(out, under)
    out = Image.alpha_composite(out, glyph)
    return out.resize((S, S), Image.LANCZOS).convert("RGB")


def contact_sheet(items, paths):
    cols = 6
    tile = 200
    pad = 24
    cap = 46
    rows = math.ceil(len(items) / cols)
    head = 70
    W_ = cols * tile + (cols + 1) * pad
    H_ = head + rows * (tile + cap) + (rows + 1) * pad
    sheet = Image.new("RGB", (W_, H_), (14, 15, 17))
    d = ImageDraw.Draw(sheet)
    d.text((pad, 22), "Hotwire City store icons (512 px, shown at 200 px; game passes are circle-cropped on Roblox)",
           font=font(22), fill=(240, 240, 240))
    small = font(16)
    for idx, (item, path) in enumerate(zip(items, paths)):
        r, c = divmod(idx, cols)
        x = pad + c * (tile + pad)
        y = head + pad + r * (tile + cap + pad)
        im = Image.open(path).resize((tile, tile), Image.LANCZOS)
        if item["kind"] == "pass":
            mask = Image.new("L", (tile * 4, tile * 4), 0)
            ImageDraw.Draw(mask).ellipse((0, 0, tile * 4 - 1, tile * 4 - 1), fill=255)
            mask = mask.resize((tile, tile), Image.LANCZOS)
            sheet.paste(im, (x, y), mask)
        else:
            sheet.paste(im, (x, y))
        d.text((x, y + tile + 6), item["key"], font=small, fill=(220, 220, 220))
        sub = f"{item['kind']} · {item['price']} R$" + ("" if item["onSale"] else " · OFF SALE")
        d.text((x, y + tile + 26), sub, font=font(14), fill=(255, 138, 61) if not item["onSale"] else (140, 140, 140))
    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    sheet.save(SHEET, optimize=True)
    return SHEET


def main():
    spec = json.load(open(SPEC, encoding="utf-8"))
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    paths = []
    for item in spec["items"]:
        path = os.path.join(ROOT, item["icon"])
        paths.append(path)
        if only and item["key"] not in only:
            continue
        base = item.get("giftOf") or item["key"]
        img = icon(base, gift=bool(item.get("giftOf")))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img.save(path, optimize=True)
    if all(os.path.exists(p) for p in paths):
        print("sheet:", os.path.relpath(contact_sheet(spec["items"], paths), ROOT))
    print(f"icons: {len(paths)} in assets/monetization/")


if __name__ == "__main__":
    main()
