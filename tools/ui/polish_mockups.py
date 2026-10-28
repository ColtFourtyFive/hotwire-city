#!/usr/bin/env python3
"""C4b polish evidence mockups (PIL), drawn from the game's own layout numbers and copy.

    python3 -I tools/ui/polish_mockups.py [outdir]          (default docs/v2/early/ui)

Inputs: the HUD layout (tools/ui/export_layout.luau, via mockups.load_layout) and the polish numbers + strings
(tools/ui/export_polish.luau: Shard band / title metrics, DeathScreenController subtitles, EventsClient rows,
PromptStyle help text and touch rects). Reuses tools/ui/mockups.py for the backdrop, radar and type.

Outputs, each at desktop 1280x720 and phone 844x390:
    shard_wasted_*.png    WASTED with the band always drawn (19.5% H at 48.8% H, 50% black), a subtitle, the bill in red
    shard_busted_*.png    BUSTED, bail in red, the impounded car named
    shard_*_night_*.png   the same over a night street under the game's grade (Shard.GRADE: grey, not black), so the
                          band's edges must read (review: job 0006's shard shots were night scenes)
    event_feed_*.png      server events as quiet rows at the feed position (no mid-screen pills, crosshair clear); the
                          hot drop's distance first; touch: timed events as GTA Online timer bars top-centre and at
                          most 2 entries (one card + the hot drop row) in the column under the help box
    prompt_help_*.png     a ProximityPrompt as GTA help text (PromptStyle), hold rule filling; touch: the HOTWIRE
                          button as it draws once job 0017 step 10 turns PromptStyle.TOUCH_ENABLED on (until then
                          touch keeps the engine's bubbles)
And at desktop only:
    vehicle_name_desktop.png   the car name in line 1 of the driving location block (VehicleClient.nameRect), the
                               district / street in lines 2-3 and a delivery timer bar above: nothing overlaps
"""
import json
import os
import re
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mockups as mk  # noqa: E402
from common import C, ROOT  # noqa: E402

POLISH_JSON = os.path.join(ROOT, "build", "ui_polish.json")
RED = (224, 50, 50)
GOLD = (214, 181, 99)
WASTED = C["wasted"]
BLUE = C["blue"]


def load_polish():
    os.makedirs(os.path.dirname(POLISH_JSON), exist_ok=True)
    subprocess.run(["lune", "run", "tools/ui/export_polish.luau", POLISH_JSON], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    return json.load(open(POLISH_JSON))


# ---------------------------------------------------------------------------------------------------------------------
# The game's rich text -> runs: <b>..</b> bold, <key>X</key> key cap, <r>..</r> red, <font color="#RRGGBB">..</font>
# ---------------------------------------------------------------------------------------------------------------------
TOKEN = re.compile(r'<key>(.*?)</key>|<b>(.*?)</b>|<r>(.*?)</r>|<font color="#([0-9A-Fa-f]{6})">(.*?)</font>')


def runs_of(line, base=None):
    base = base or C["text"]
    out, pos = [], 0
    for m in TOKEN.finditer(line):
        if m.start() > pos:
            out.append((line[pos:m.start()], base, False))
        if m.group(1) is not None:
            out.append((m.group(1), "key", False))
        elif m.group(2) is not None:
            out.append((m.group(2), base, True))
        elif m.group(3) is not None:
            out.append((m.group(3), RED, False))
        else:
            hexc = m.group(4)
            out.append((m.group(5), tuple(int(hexc[i:i + 2], 16) for i in (0, 2, 4)), False))
        pos = m.end()
    if pos < len(line):
        out.append((line[pos:], base, False))
    return out


def draw_runs(m, x, y, runs, size, anchor="l", shadow=False):
    """y is the text middle; anchor l / m / r. Returns the width."""
    widths = []
    for text, col, bold in runs:
        if col == "key":
            widths.append(m.measure(text, "Montserrat-600", size * 0.85) + size * 0.7)
        else:
            widths.append(m.measure(text, "Montserrat-600" if bold else "Montserrat-500", size))
    total = sum(widths)
    cx = x - (total / 2 if anchor == "m" else (total if anchor == "r" else 0))
    for (text, col, bold), w in zip(runs, widths):
        if col == "key":
            kh = size * 1.25
            m.box(cx + 1, y - kh / 2, w - 2, kh, mk.rgba(C["text"]))
            m.text(cx + w / 2, y, text, "Montserrat-600", size * 0.85, (0, 0, 0, 255), anchor="mm")
        else:
            m.text(cx, y, text, "Montserrat-600" if bold else "Montserrat-500", size, mk.rgba(col), anchor="lm",
                   shadow=shadow)
        cx += w
    return total


# ---------------------------------------------------------------------------------------------------------------------
# Shards
# ---------------------------------------------------------------------------------------------------------------------
def vignette(m, W, H, edge_transparency):
    """DeathScreenController's four edge gradients: 20% H top / bottom, 16% W left / right, black at `edge` -> clear."""
    a0 = 1 - edge_transparency
    sw, sh = m.img.size
    th, tw = int(0.2 * H * mk.K), int(0.16 * W * mk.K)
    alpha = Image.new("L", (sw, sh), 0)
    ad = ImageDraw.Draw(alpha)
    for i in range(th):
        v = int(255 * a0 * (1 - i / th))
        ad.line([(0, i), (sw, i)], fill=v)
        ad.line([(0, sh - 1 - i), (sw, sh - 1 - i)], fill=v)
    side = Image.new("L", (sw, sh), 0)
    sd = ImageDraw.Draw(side)
    for i in range(tw):
        v = int(255 * a0 * (1 - i / tw))
        sd.line([(i, 0), (i, sh)], fill=v)
        sd.line([(sw - 1 - i, 0), (sw - 1 - i, sh)], fill=v)
    alpha = ImageChops.lighter(alpha, side)
    black = Image.new("RGBA", (sw, sh), (0, 0, 0, 255))
    black.putalpha(alpha)
    m.img.alpha_composite(black)


def graded_backdrop(view, P, night):
    """The street under Shard.GRADE (ColorCorrection: Saturation -1, Contrast, Brightness) plus the light blur. A night
    pass first darkens the street to roughly a lit city at night (job 0006's shard shots)."""
    real = view["canvas"]["real"]
    b = mk.backdrop(real[0], real[1]).convert("RGB")
    if night:
        b = ImageEnhance.Brightness(b).enhance(0.28)
        b = Image.blend(b, Image.new("RGB", b.size, (10, 16, 34)), 0.25)
    g = P["shard"]["grade"]
    out = ImageEnhance.Color(b).enhance(max(0.0, 1 + g["saturation"]))
    out = ImageEnhance.Contrast(out).enhance(1 + g["contrast"])
    out = ImageEnhance.Brightness(out).enhance(1 + g["brightness"])
    return out.filter(ImageFilter.GaussianBlur(1.5)).convert("RGBA")


def scene_shard(view, P, dev, kind):
    W, H = view["canvas"]["real"]
    S = P["shard"]
    m = mk.Mock(W, H)
    vignette(m, W, H, S["vignetteEdge"])
    # the guaranteed plain band (UI/Shard: always drawn; the keystone sprite only once it has loaded)
    bh = S["frameHeight"] * H
    cy = S["centre"] * H
    m.blend_box(0, cy - bh / 2, W, bh, (0, 0, 0, int(255 * (1 - S["alpha"][kind]))))
    scale = P[dev]["shardTitleScale"]
    size = 100 * scale
    color = WASTED if kind == "wasted" else BLUE
    m.text(W / 2, S["titleY"] * H, kind, "Kanit-900", size, mk.rgba(color), anchor="mm")
    sub = S["wastedSubtitle"] if kind == "wasted" else S["bustedSubtitle"]
    sub_size = min(P[dev]["shardSubtitleMax"], 0.034 * H)
    draw_runs(m, W / 2, (S["subtitleY"] + 0.017) * H, runs_of(sub), sub_size, anchor="m")
    return m


# ---------------------------------------------------------------------------------------------------------------------
# HUD scenes
# ---------------------------------------------------------------------------------------------------------------------
def panel(m, x, y, w, h):
    m.blend_box(x, y, w, h, (0, 0, 0, mk.alpha_of(0.27)))


def event_row(m, x, y, w, touch, label, value, rule, sub_runs=None, urgent=False):
    line_h = 28 if touch else 26
    h = line_h + 16 if sub_runs else line_h
    panel(m, x, y, w, h)
    m.box(x, y, 3, h, mk.rgba(rule))
    m.text(x + 11, y + line_h / 2, label, "Montserrat-500", 14 if touch else 13, mk.rgba(C["text"]), anchor="lm")
    m.text(x + w - 8, y + line_h / 2, value, "Kanit-900", 17 if touch else 16, mk.rgba(RED if urgent else C["text"]),
           anchor="rm")
    if sub_runs:
        size = 13 if touch else 12
        draw_runs(m, x + 11, y + line_h - 6 + 9, truncate(m, sub_runs, w - 19, size), size)
    return h


def truncate(m, runs, width, size):
    """TextTruncate.AtEnd for a run list: cut the overflowing run and end it with an ellipsis."""
    out, used = [], 0
    for text, col, bold in runs:
        fname = "Montserrat-600" if bold else "Montserrat-500"
        w = m.measure(text, fname, size)
        if used + w <= width:
            out.append((text, col, bold))
            used += w
            continue
        while text and used + m.measure(text + "…", fname, size) > width:
            text = text[:-1]
        out.append((text.rstrip() + "…", col, bold))
        break
    return out


def announce_card(m, x, y, w, title, body, touch):
    size = 13
    lay = mk.Mock(m.cw, m.ch)
    used = lay.wrap_rich(x + 8, y + 28, w - 16, [(body, C["text"])], "Montserrat-500", size, 16)
    h = 28 + used + 8
    panel(m, x, y, w, h)
    m.text(x + 8, y + 15, title, "Oswald-600", 15, mk.rgba(C["text"]), anchor="lm")
    m.img.alpha_composite(lay.img)
    return h


def crosshair(m, L):
    cx, cy = L["w"] / 2, L["h"] / 2
    m.blend_ellipse(cx, cy, 2.6, (255, 255, 255, 230), outline=(0, 0, 0, 160), width=1)


def help_rich(m, L, text, touch, progress=None):
    """UI/HelpText: black 27% box top-left, padding 10/12, Montserrat 16 (touch 18), LineHeight 1.1, a 3 px hold rule."""
    r = L["help"]
    size = 18 if touch else 16
    line_h = size * 1.45
    lines = text.split("\n")
    h = 10 + line_h * len(lines) + (6 + 3 if progress is not None else 0) + 10
    panel(m, r["x"], r["y"], r["w"], h)
    for i, ln in enumerate(lines):
        draw_runs(m, r["x"] + 12, r["y"] + 10 + line_h * (i + 0.5), runs_of(ln), size)
    if progress is not None:
        py = r["y"] + 10 + line_h * len(lines) + 6
        m.box(r["x"] + 12, py, r["w"] - 24, 3, mk.rgba(C["disabled"], int(255 * 0.7)))
        m.box(r["x"] + 12, py, (r["w"] - 24) * progress, 3, mk.rgba(C["accent"]))
    return h


def base_hud(view, blips_extra=()):
    c = view["canvas"]
    L = view["layout"]
    m = mk.Mock(c["w"], c["h"])
    mk.hud_base(m, view, {"blips": mk.BLIPS + list(blips_extra), "bars": (1.0, 0.0, 0.85), "heading": 20,
                          "face": 35})
    mk.cash(m, L, "$57,686")
    return m, L, L["touch"]


def scene_events(view, P):
    m, L, touch = base_hud(view, [((420, -620), "hud.ring", C["yellow"], 14)])
    E = P["events"]
    help_h = mk.help_box(m, L, [("Walk up to the ", C["text"]), ("car", C["blue"]), (" and hold ", C["text"]),
                                ("E" if not touch else "HOTWIRE", "key"), (" to hotwire it.", C["text"])], touch)
    f = L["feed"]
    w = f["w"]
    # the distance first (EventsClient.hotDropView): a long car name truncates, never the distance
    drop_sub = [(E["distance"] + "  ·  ", C["dim"], False), ("Legendary", GOLD, False),
                (" Rossetti Ardente Oro", C["dim"], False)]
    timed = [
        (E["rushHour"]["label"], E["rushHour"]["value"], tuple(E["rushHour"]["color"]), None),
        (E["doubleCash"]["label"], E["doubleCash"]["value"], tuple(E["doubleCash"]["color"]), None),
    ]
    bars = touch and E["timedAsBarsTouch"]
    rows = [("Hot drop", "2:31", GOLD, drop_sub)] + ([] if bars else timed)
    if bars:
        # GTA Online timer bars (HUDController.setTimer uppercases the label), top-centre on touch
        T = E["timer"]
        for i, (label, value, _rule, _sub) in enumerate(timed):
            Li = dict(L)
            Li["timers"] = dict(L["timers"], y=L["timers"]["y"] + i * (T["h"] + T["gap"]))
            mk.timer_bar(m, Li, label.upper(), value, False)
    line_h = 28 if touch else 26
    heights = [line_h + 16 if r[3] else line_h for r in rows]
    card_title = "HOT DROP"
    card_body = "A Legendary Rossetti Ardente Oro lands in 30 seconds. It's marked on your map."
    if touch:
        y = L["help"]["y"] + help_h + 6
        y += announce_card(m, f["x"], y, w, card_title, card_body, touch) + 4
        for (label, value, rule, sub), h in zip(rows, heights):
            event_row(m, f["x"], y, w, touch, label, value, rule, sub)
            y += h + 4
    else:
        y = f["y"] + f["h"]
        for (label, value, rule, sub), h in reversed(list(zip(rows, heights))):
            y -= h
            event_row(m, f["x"], y, w, touch, label, value, rule, sub)
            y -= 4
        lay = mk.Mock(m.cw, m.ch)
        body_h = lay.wrap_rich(0, 0, w - 16, [(card_body, C["text"])], "Montserrat-500", 13, 16)
        card_h = 28 + body_h + 8
        announce_card(m, f["x"], y - card_h, w, card_title, card_body, touch)
    mk.objective(m, L, [("Steal a ", C["text"]), ("car", C["blue"]), (".", C["text"])], touch)
    crosshair(m, L)
    if touch:
        mk.thumbstick_hint(m, L)
        mk.jump_button(m, L)
        mk.circle_button(m, L["buttons"]["phone"], "Phone", "hud.phone")
        mk.circle_button(m, L["buttons"]["map"], "Map", "hud.map")
    return m


def scene_vehicle_name(view, P, dev):
    """Desktop: the name in line 1 of the driving location block, district / street in lines 2-3, a timer above."""
    m, L, touch = base_hud(view)
    mk.location(m, L, ["", "Downtown", "Crown Boulevard"], True, touch)
    mk.timer_bar(m, L, "DELIVERY", "1:42", True)
    r = P[dev]["vehicleNameRect"]
    size = P["vehicleNameSize"]
    cy = r["y"] + r["h"] / 2
    right = r["x"] + r["w"]
    m.text(right, cy, "K8", "Damion-400", size, mk.rgba(C["text"]), anchor="rm", stroke=1, stroke_fill=(0, 0, 0, 102))
    model_w = m.measure("K8", "Damion-400", size)
    m.text(right - model_w - 8, cy, "KRONBERG", "Oswald-500", 14, mk.rgba(C["text"], 230), anchor="rm")
    mk.speed(m, L, 64)
    return m


def scene_prompt(view, P, dev):
    m, L, touch = base_hud(view)
    text = P["prompt"]["stealTouch"] if touch else P["prompt"]["steal"]
    help_rich(m, L, text, touch, progress=0.45)
    mk.objective(m, L, [("Steal a ", C["text"]), ("car", C["blue"]), (".", C["text"])], touch)
    mk.location(m, L, ["", "Downtown", "Crown Boulevard"], False, touch)
    if touch:
        mk.thumbstick_hint(m, L)
        mk.jump_button(m, L)
        mk.circle_button(m, L["buttons"]["phone"], "Phone", "hud.phone")
        mk.circle_button(m, L["buttons"]["map"], "Map", "hud.map")
        r = P[dev]["promptRects"][0]
        cx, cy, rad = r["x"] + r["w"] / 2, r["y"] + r["h"] / 2, r["w"] / 2
        m.blend_ellipse(cx, cy, rad, (0, 0, 0, mk.alpha_of(0.1)), outline=mk.rgba(C["text"], 77), width=1.5)
        m.text(cx, cy, "HOTWIRE", "Oswald-500", 14, mk.rgba(C["text"]), anchor="mm")
    return m


# ---------------------------------------------------------------------------------------------------------------------
def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "v2", "early", "ui")
    os.makedirs(out_dir, exist_ok=True)
    layout = mk.load_layout()
    P = load_polish()
    written = []
    for dev in ("desktop", "phone"):
        view = layout[dev]
        real = view["canvas"]["real"]
        for kind in ("wasted", "busted"):
            for night in (False, True):
                m = scene_shard(view, P, dev, kind)
                back = graded_backdrop(view, P, night)
                back.alpha_composite(m.img.resize((real[0], real[1]), Image.LANCZOS))
                suffix = "_night" if night else ""
                path = os.path.join(out_dir, f"shard_{kind}{suffix}_{dev}.png")
                back.convert("RGB").save(path, optimize=True)
                written.append(path)
        scenes = [("event_feed", lambda v: scene_events(v, P)), ("prompt_help", lambda v: scene_prompt(v, P, dev))]
        if dev == "desktop":
            scenes.append(("vehicle_name", lambda v: scene_vehicle_name(v, P, dev)))
        for name, fn in scenes:
            # the shared v1 street render, desaturated so the UI under review reads first (it is not the v2 world)
            back = ImageEnhance.Color(mk.backdrop(real[0], real[1])).enhance(0.35)
            img = mk.compose(view, fn(view), back)
            mk.roblox_topbar(img, view)
            path = os.path.join(out_dir, f"{name}_{dev}.png")
            img.convert("RGB").save(path, optimize=True)
            written.append(path)
    for p in written:
        print("wrote", os.path.relpath(p, ROOT))


if __name__ == "__main__":
    main()
