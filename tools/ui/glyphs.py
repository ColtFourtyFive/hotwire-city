"""White-on-transparent HUD glyphs (tinted in game with ImageColor3) and the GTA-style phone app icons.

Every glyph is drawn as vectors on a supersampled canvas in a 64 px cell; `outline` bakes the dark 2-3 px edge GTA
puts on radar / HUD glyphs so they read on any background.
"""
import math

from PIL import Image, ImageChops

from common import C, Canvas, font, outline_alpha, star_points

W = (255, 255, 255, 255)
K = (0, 0, 0, 255)


def _cell(draw_fn, size=64, ss=6, edge=3):
    cv = Canvas(size, size, ss)
    draw_fn(cv, size)
    img = cv.done()
    return outline_alpha(img, edge) if edge else img


# --- HUD -------------------------------------------------------------------------------------------------------------


def star_fill():
    def d(cv, s):
        cv.poly(star_points(32, 34, 27, 0.47), fill=W)
    return _cell(d, edge=3)


def star_hollow():
    def outer(cv, s):
        cv.poly(star_points(32, 34, 27, 0.47), fill=W)

    def inner(cv, s):
        cv.poly(star_points(32, 34, 19, 0.47), fill=W)
    a = _cell(outer, edge=0)
    b = _cell(inner, edge=0)
    ring = ImageChops.subtract(a.split()[3], b.split()[3])
    img = Image.new("RGBA", a.size, (255, 255, 255, 0))
    img.putalpha(ring)
    return outline_alpha(img, 2)


def player_arrow():
    def d(cv, s):
        cv.poly([(32, 5), (54, 57), (32, 45), (10, 57)], fill=W)
    return _cell(d, edge=3)


def north_disc():
    cv = Canvas(64, 64, 6)
    cv.circle(32, 32, 28, fill=(12, 12, 12, 255), outline=(240, 240, 240, 255), width=2.5)
    cv.text((32, 33), "N", "Oswald-600", 34, (240, 240, 240, 255))
    return cv.done()


def chevron():
    def d(cv, s):
        cv.poly([(6, 14), (32, 40), (58, 14), (58, 30), (32, 56), (6, 30)], fill=W)
    return _cell(d, edge=3)


def dot():
    def d(cv, s):
        cv.circle(32, 32, 20, fill=W)
    return _cell(d, edge=3)


def ring():
    def d(cv, s):
        cv.circle(32, 32, 24, outline=W, width=6)
    return _cell(d, edge=2)


def square():
    def d(cv, s):
        cv.rect((14, 14, 50, 50), fill=W)
    return _cell(d, edge=3)


# --- touch / phone glyphs (no outline: they sit on dark buttons) -----------------------------------------------------


def g_phone(cv, s):
    cv.rect((20, 6, 44, 58), outline=W, width=4, radius=6)
    cv.line([(28, 13), (36, 13)], W, 3)
    cv.circle(32, 50, 3, fill=W)


def g_map(cv, s):
    pts = [(8, 16), (24, 10), (40, 16), (56, 10), (56, 50), (40, 56), (24, 50), (8, 56)]
    cv.poly(pts, outline=W, width=4)
    cv.line([(24, 10), (24, 50)], W, 3)
    cv.line([(40, 16), (40, 56)], W, 3)


def _flame(cx, base, w, h):
    """Teardrop flame: a round bottom of radius w/2 and a pointed, slightly curled top."""
    pts = []
    r = w / 2
    for i in range(180, -1, -10):  # bottom half-circle, left to right (screen y down)
        a = math.radians(i)
        pts.append((cx + r * math.cos(a), base - r + r * math.sin(a)))
    # right flank up to the tip, left flank back down
    tip = (cx + w * 0.08, base - h)
    pts += [(cx + r * 0.98, base - r * 1.4), (cx + r * 0.62, base - h * 0.62), tip,
            (cx - r * 0.2, base - h * 0.7), (cx - r * 0.55, base - h * 0.58), (cx - r * 0.98, base - r * 1.35)]
    return pts


def g_nitro(cv, s):
    cv.poly(_flame(32, 58, 34, 54), fill=W)


def h_nitro(cv, s):
    cv.poly(_flame(32, 54, 16, 26), fill=W)


def g_drift(cv, s):
    cv.arc((10, 10, 54, 54), 200, 340, W, 6)
    cv.poly([(50, 12), (58, 26), (44, 26)], fill=W)
    cv.line([(14, 44), (24, 52)], W, 5)
    cv.line([(26, 42), (36, 50)], W, 5)


def g_horn(cv, s):
    cv.poly([(8, 26), (20, 26), (36, 12), (36, 52), (20, 38), (8, 38)], fill=W)
    cv.arc((30, 18, 50, 46), 300, 60, W, 4)
    cv.arc((30, 10, 60, 54), 305, 55, W, 4)


def g_exit(cv, s):
    cv.rect((10, 8, 34, 56), outline=W, width=4)
    cv.line([(26, 32), (54, 32)], W, 5)
    cv.poly([(48, 22), (60, 32), (48, 42)], fill=W)


def g_camera(cv, s):
    cv.rect((6, 18, 58, 52), fill=W, radius=6)
    cv.rect((22, 10, 42, 20), fill=W, radius=2)
    cv.circle(32, 35, 11, fill=(0, 0, 0, 0))
    cv.circle(32, 35, 11, outline=(0, 0, 0, 0), width=1)


def _knock(img, draw_fn):
    """Cut holes (drawn white in draw_fn) out of img's alpha."""
    cv = Canvas(img.width, img.height, 6)
    draw_fn(cv, img.width)
    hole = cv.done().split()[3]
    a = ImageChops.subtract(img.split()[3], hole)
    out = img.copy()
    out.putalpha(a)
    return out


def g_cab(cv, s):
    cv.rect((22, 8, 42, 16), fill=W)
    cv.poly([(10, 34), (18, 20), (46, 20), (54, 34)], fill=W)
    cv.rect((6, 32, 58, 48), fill=W, radius=4)
    cv.circle(18, 50, 6, fill=W)
    cv.circle(46, 50, 6, fill=W)


def g_lock(cv, s):
    cv.arc((18, 6, 46, 36), 180, 360, W, 5)
    cv.line([(20, 20), (20, 28)], W, 5)
    cv.line([(44, 20), (44, 28)], W, 5)
    cv.rect((12, 26, 52, 58), fill=W, radius=4)


def g_cash(cv, s):
    cv.circle(32, 32, 26, outline=W, width=4)
    cv.text((32, 33), "$", "Kanit-900", 34, W)


def g_check(cv, s):
    cv.line([(12, 34), (26, 48), (54, 16)], W, 8, joint="curve")


def g_back(cv, s):
    cv.line([(50, 32), (16, 32)], W, 6)
    cv.poly([(8, 32), (26, 16), (26, 48)], fill=W)


def g_signal(cv, s):
    for i, h in enumerate([10, 18, 26, 34]):
        x = 12 + i * 11
        cv.rect((x, 50 - h, x + 7, 50), fill=W)


def g_battery(cv, s):
    cv.rect((8, 20, 52, 44), outline=W, width=4, radius=3)
    cv.rect((52, 27, 57, 37), fill=W)
    cv.rect((13, 25, 40, 39), fill=W)


def g_plus(cv, s):
    cv.line([(32, 12), (32, 52)], W, 8)
    cv.line([(12, 32), (52, 32)], W, 8)


def g_minus(cv, s):
    cv.line([(12, 32), (52, 32)], W, 8)


def g_car(cv, s):
    cv.poly([(12, 30), (20, 18), (44, 18), (52, 30)], fill=W)
    cv.rect((6, 28, 58, 44), fill=W, radius=4)
    cv.circle(18, 46, 6, fill=W)
    cv.circle(46, 46, 6, fill=W)


def g_cctv(cv, s):
    cv.poly([(8, 18), (44, 10), (50, 26), (14, 34)], fill=W)
    cv.line([(30, 30), (34, 46)], W, 5)
    cv.line([(22, 50), (46, 50)], W, 5)


def g_face(cv, s):
    cv.ellipse((16, 6, 48, 44), fill=W)
    cv.poly([(8, 60), (16, 46), (48, 46), (56, 60)], fill=W)


def g_shirt(cv, s):
    cv.poly([(20, 10), (26, 14), (38, 14), (44, 10), (58, 20), (50, 30), (46, 26), (46, 56), (18, 56), (18, 26),
             (14, 30), (6, 20)], fill=W)


def g_wrench(cv, s):
    cv.line([(18, 46), (40, 24)], W, 9)
    cv.circle(44, 20, 12, fill=W)
    cv.circle(48, 16, 6, fill=(0, 0, 0, 0))


def g_person(cv, s):
    cv.circle(32, 20, 11, fill=W)
    cv.ellipse((12, 34, 52, 70), fill=W)


def g_bubble(cv, s):
    cv.rect((6, 10, 58, 44), fill=W, radius=10)
    cv.poly([(16, 40), (12, 56), (30, 42)], fill=W)


def g_briefcase(cv, s):
    cv.rect((22, 8, 42, 18), outline=W, width=4, radius=3)
    cv.rect((6, 16, 58, 52), fill=W, radius=5)


def g_calendar(cv, s):
    cv.rect((8, 12, 56, 56), fill=W, radius=5)
    cv.line([(20, 6), (20, 16)], W, 5)
    cv.line([(44, 6), (44, 16)], W, 5)


def g_gift(cv, s):
    cv.rect((8, 24, 56, 56), fill=W)
    cv.rect((6, 18, 58, 28), fill=W)
    cv.arc((14, 6, 32, 24), 120, 360, W, 4)
    cv.arc((32, 6, 50, 24), 180, 60, W, 4)


def g_ticket(cv, s):
    cv.rect((6, 16, 58, 48), fill=W, radius=4)


def g_gear(cv, s):
    teeth = 8
    pts = []
    for i in range(teeth * 4):
        a = math.radians(i * 360 / (teeth * 4))
        r = 26 if (i % 4) in (0, 1) else 19
        pts.append((32 + r * math.cos(a), 32 + r * math.sin(a)))
    cv.poly(pts, fill=W)


def g_pin(cv, s):
    cv.circle(32, 24, 16, fill=W)
    cv.poly([(18, 30), (32, 58), (46, 30)], fill=W)


def g_laurel(cv, s):
    cv.poly(star_points(32, 30, 18, 0.45), fill=W)
    cv.arc((6, 8, 58, 60), 100, 170, W, 4)
    cv.arc((6, 8, 58, 60), 10, 80, W, 4)
    cv.line([(20, 54), (44, 54)], W, 4)


def g_bag(cv, s):
    cv.arc((20, 6, 44, 30), 180, 360, W, 4)
    cv.poly([(10, 20), (54, 20), (58, 58), (6, 58)], fill=W)


def glyph(fn, size=64, holes=None):
    img = _cell(fn, size=size, edge=0)
    if holes:
        img = _knock(img, holes)
    return img


def h_camera(cv, s):
    cv.circle(32, 35, 11, fill=W)
    cv.circle(32, 35, 6, fill=(0, 0, 0, 0))


def h_ticket(cv, s):
    cv.circle(6, 32, 6, fill=W)
    cv.circle(58, 32, 6, fill=W)
    for y in range(18, 48, 6):
        cv.rect((40, y, 43, y + 3), fill=W)


def h_calendar(cv, s):
    cv.rect((12, 22, 52, 52), fill=W)


def h_gear(cv, s):
    cv.circle(32, 32, 8, fill=W)


def h_pin(cv, s):
    cv.circle(32, 24, 6, fill=W)


def h_briefcase(cv, s):
    cv.rect((6, 30, 58, 33), fill=W)


def h_gift(cv, s):
    cv.rect((29, 18, 35, 56), fill=W)


def h_face(cv, s):
    pass


# --- phone apps --------------------------------------------------------------------------------------------------------

APPS = [
    # key, background, glyph fn, hole fn, dark glyph?
    ("contacts", (45, 110, 185), g_person, None, False),
    ("messages", (53, 154, 71), g_bubble, None, False),
    ("jobs", (255, 138, 61), g_briefcase, h_briefcase, False),
    ("daily", (224, 50, 50), g_calendar, h_calendar, False),
    ("gifts", (132, 102, 226), g_gift, h_gift, False),
    ("codes", (70, 70, 74), g_ticket, h_ticket, False),
    ("camera", (34, 34, 38), g_camera, h_camera, False),
    ("settings", (110, 110, 116), g_gear, h_gear, False),
    ("map", (47, 143, 131), g_pin, h_pin, False),
    ("prestige", (214, 181, 99), g_laurel, None, True),
    ("store", (47, 92, 115), g_bag, None, False),
    ("garage", (93, 182, 229), g_car, None, False),
    ("cab", (240, 200, 80), g_cab, None, True),
]


def app_icon(bg, glyph_fn, hole_fn, dark, size=96):
    cv = Canvas(size, size, 4)
    top = tuple(min(255, int(c * 1.18 + 12)) for c in bg)
    bot = tuple(int(c * 0.78) for c in bg)
    # body: vertical gradient inside a rounded square
    for i in range(size):
        t = i / (size - 1)
        col = tuple(int(top[k] + (bot[k] - top[k]) * t) for k in range(3)) + (255,)
        cv.d.rectangle([0, i * 4, size * 4, (i + 1) * 4], fill=col)
    mask = Canvas(size, size, 4)
    mask.rect((2, 2, size - 2, size - 2), fill=W, radius=18)
    m = mask.done().split()[3]
    body = cv.done()
    body.putalpha(m)
    # gloss on the top half
    gloss = Canvas(size, size, 4)
    gloss.ellipse((-size * 0.4, -size * 0.75, size * 1.4, size * 0.5), fill=(255, 255, 255, 46))
    g = gloss.done()
    g.putalpha(ImageChops.multiply(g.split()[3], m))
    body.alpha_composite(g)
    # glyph
    gl = glyph(glyph_fn, 64, hole_fn).resize((54, 54), Image.LANCZOS)
    if dark:
        r, gg, b, a = gl.split()
        gl = Image.merge("RGBA", (r.point(lambda v: 20), gg.point(lambda v: 20), b.point(lambda v: 20), a))
    shadow = Image.new("RGBA", gl.size, (0, 0, 0, 0))
    shadow.putalpha(gl.split()[3].point(lambda v: v * 0.35))
    body.alpha_composite(shadow, ((size - 54) // 2 + 1, (size - 54) // 2 + 2))
    body.alpha_composite(gl, ((size - 54) // 2, (size - 54) // 2))
    return body


TOUCH = [
    ("phone", g_phone, None),
    ("map", g_map, None),
    ("nitro", g_nitro, h_nitro),
    ("drift", g_drift, None),
    ("horn", g_horn, None),
    ("exit", g_exit, None),
    ("camera", g_camera, h_camera),
    ("cab", g_cab, None),
    ("lock", g_lock, None),
    ("cash", g_cash, None),
    ("check", g_check, None),
    ("back", g_back, None),
    ("signal", g_signal, None),
    ("battery", g_battery, None),
    ("plus", g_plus, None),
    ("minus", g_minus, None),
    ("car", g_car, None),
    ("cctv", g_cctv, None),
    ("face", g_face, None),
    ("shirt", g_shirt, None),
    ("wrench", g_wrench, None),
    ("person", g_person, None),
    ("bubble", g_bubble, None),
    ("pin", g_pin, h_pin),
]


def spinner(size=128):
    cv = Canvas(size, size, 4)
    steps = 48
    for i in range(steps):
        a0 = i * 360 / steps
        alpha = int(255 * (i / steps) ** 1.6)
        cv.arc((10, 10, size - 10, size - 10), a0 - 90, a0 - 90 + 360 / steps + 1, (255, 255, 255, alpha), 9)
    return cv.done()
