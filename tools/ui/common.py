"""Shared helpers for the UI art + mockup scripts (PIL only, supersampled vector drawing)."""
import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FONT_DIR = os.path.join(ROOT, "assets", "ui", "fonts")
OUT_DIR = os.path.join(ROOT, "assets", "ui")

# Theme.Colors (src/client/UI/Theme.luau) for the art + mockups
C = {
    "text": (240, 240, 240),
    "pure": (255, 255, 255),
    "dim": (155, 155, 155),
    "muted": (140, 140, 140),
    "disabled": (77, 77, 77),
    "black": (0, 0, 0),
    "menu_hi": (30, 30, 30),
    "menu_dark": (60, 60, 60),
    "red": (224, 50, 50),
    "red_dark": (112, 25, 25),
    "damage": (235, 36, 39),
    "blue": (93, 182, 229),
    "blue_dark": (47, 92, 115),
    "yellow": (240, 200, 80),
    "yellow_dark": (126, 107, 41),
    "green": (114, 204, 114),
    "health": (53, 154, 71),
    "health_track": (27, 77, 36),
    "waypoint": (164, 76, 242),
    "gold": (214, 181, 99),
    "accent": (255, 138, 61),
    "accent_dark": (122, 58, 18),
    "wasted": (179, 33, 47),
    "freemode": (45, 110, 185),
    "purple": (132, 102, 226),
}
INK = (30, 20, 48)  # loading-art ink outlines (deep violet)
BRAND = [(58, 46, 110), (164, 92, 142), (242, 149, 110), (255, 194, 122)]

_fonts = {}


def font(name, size):
    """font('Kanit-900', 40) from assets/ui/fonts."""
    key = (name, size)
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype(os.path.join(FONT_DIR, name + ".ttf"), size)
    return _fonts[key]


class Canvas:
    """A supersampled RGBA canvas: draw in final-pixel units, `done()` downsamples with LANCZOS."""

    def __init__(self, w, h, ss=4, bg=(0, 0, 0, 0)):
        self.w, self.h, self.ss = w, h, ss
        self.img = Image.new("RGBA", (w * ss, h * ss), bg)
        self.d = ImageDraw.Draw(self.img)

    def p(self, pts):
        return [(x * self.ss, y * self.ss) for x, y in pts]

    def r(self, box):
        x0, y0, x1, y1 = box
        return [x0 * self.ss, y0 * self.ss, x1 * self.ss, y1 * self.ss]

    def poly(self, pts, fill=None, outline=None, width=0):
        self.d.polygon(self.p(pts), fill=fill)
        if outline and width:
            pts2 = self.p(pts) + [self.p(pts)[0]]
            self.d.line(pts2, fill=outline, width=int(width * self.ss), joint="curve")

    def ellipse(self, box, fill=None, outline=None, width=0):
        self.d.ellipse(self.r(box), fill=fill, outline=outline, width=int(width * self.ss))

    def circle(self, cx, cy, rad, fill=None, outline=None, width=0):
        self.ellipse((cx - rad, cy - rad, cx + rad, cy + rad), fill, outline, width)

    def rect(self, box, fill=None, outline=None, width=0, radius=0):
        if radius:
            self.d.rounded_rectangle(self.r(box), radius=radius * self.ss, fill=fill, outline=outline,
                                     width=int(width * self.ss))
        else:
            self.d.rectangle(self.r(box), fill=fill, outline=outline, width=int(width * self.ss))

    def line(self, pts, fill, width, joint="curve"):
        self.d.line(self.p(pts), fill=fill, width=max(1, int(width * self.ss)), joint=joint)

    def arc(self, box, start, end, fill, width):
        self.d.arc(self.r(box), start, end, fill=fill, width=int(width * self.ss))

    def text(self, xy, s, fnt_name, size, fill, anchor="mm", stroke=0, stroke_fill=None):
        f = font(fnt_name, int(size * self.ss))
        self.d.text((xy[0] * self.ss, xy[1] * self.ss), s, font=f, fill=fill, anchor=anchor,
                    stroke_width=int(stroke * self.ss), stroke_fill=stroke_fill)

    def done(self):
        return self.img.resize((self.w, self.h), Image.LANCZOS)


def star_points(cx, cy, outer, inner_ratio=0.45, points=5, rot=-90):
    pts = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else outer * inner_ratio
        a = math.radians(rot + i * 180 / points)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def lerp(a, b, t):
    return a + (b - a) * t


def lerp_col(a, b, t):
    return tuple(int(round(lerp(a[i], b[i], t))) for i in range(len(a)))


def gradient_stops(stops, t):
    """stops: [(pos, color)], t in 0..1"""
    t = max(0.0, min(1.0, t))
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if t <= p1:
            return lerp_col(c0, c1, (t - p0) / max(1e-9, p1 - p0))
    return stops[-1][1]


def vertical_gradient(w, h, stops):
    img = Image.new("RGB", (1, h))
    for y in range(h):
        img.putpixel((0, y), gradient_stops(stops, y / max(1, h - 1)))
    return img.resize((w, h), Image.BILINEAR).convert("RGBA")


def horizontal_gradient(w, h, stops):
    img = Image.new("RGB", (w, 1))
    for x in range(w):
        img.putpixel((x, 0), gradient_stops(stops, x / max(1, w - 1)))
    return img.resize((w, h), Image.BILINEAR).convert("RGBA")


def outline_alpha(img, px, color=(0, 0, 0)):
    """Adds a `px` outline around an RGBA glyph (dilated alpha behind it)."""
    a = img.split()[3]
    grown = a.filter(ImageFilter.MaxFilter(px * 2 + 1))
    out = Image.new("RGBA", img.size, color + (0,))
    out.putalpha(grown)
    out.alpha_composite(img)
    return out


def save(img, name, out_dir=OUT_DIR):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    img.save(path, optimize=True)
    return path
