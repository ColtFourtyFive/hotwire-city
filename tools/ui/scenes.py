"""Loading-screen key art (gta_ui_language §5.14 / §6): six full-bleed illustrated panels of our own city in the
box-art spirit (flat cel-shaded silhouettes, heavy ink outlines, the brand sunset gradient), no text, no GTA tracing.

    python3 -I tools/ui/scenes.py        # assets/ui/loading_1.png .. loading_6.png (1920x1080)
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(__file__))
from common import INK, OUT_DIR, font, lerp_col, save, vertical_gradient  # noqa: E402

W, H = 1920, 1080
SS = 2
INK_A = INK + (255,)


class Scene:
    def __init__(self, sky, seed):
        self.rnd = random.Random(seed)
        self.img = vertical_gradient(W * SS, H * SS, sky)
        self.d = ImageDraw.Draw(self.img)

    def P(self, pts):
        return [(x * SS, y * SS) for x, y in pts]

    def poly(self, pts, fill, ink=4):
        self.d.polygon(self.P(pts), fill=fill)
        if ink:
            p = self.P(pts)
            self.d.line(p + [p[0]], fill=INK_A, width=int(ink * SS), joint="curve")

    def rect(self, x0, y0, x1, y1, fill, ink=3):
        self.poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], fill, ink)

    def circle(self, cx, cy, r, fill, ink=0, outline=None):
        self.d.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS], fill=fill,
                       outline=outline or (INK_A if ink else None), width=int(ink * SS))

    def line(self, pts, fill, width):
        self.d.line(self.P(pts), fill=fill, width=int(width * SS), joint="curve")

    def glow(self, cx, cy, r, color, blur=60, alpha=200):
        layer = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS],
                                      fill=color + (alpha,))
        self.img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur * SS)))
        self.d = ImageDraw.Draw(self.img)

    def haze(self, y0, y1, color, alpha=120):
        layer = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        g = vertical_gradient(W * SS, int((y1 - y0) * SS), [(0, color), (1, color)])
        mask = vertical_gradient(W * SS, int((y1 - y0) * SS), [(0, (0, 0, 0)), (0.5, (alpha,) * 3), (1, (0, 0, 0))])
        g.putalpha(mask.split()[0])
        layer.alpha_composite(g, (0, int(y0 * SS)))
        self.img.alpha_composite(layer)
        self.d = ImageDraw.Draw(self.img)

    # --- props ----------------------------------------------------------------------------------------------------

    def skyline(self, base, x0, x1, hmin, hmax, fill, ink=3, windows=0.0, win=(255, 196, 120, 255), towers=0.25):
        x = x0
        while x < x1:
            bw = self.rnd.randint(40, 110)
            bh = self.rnd.randint(hmin, hmax)
            top = base - bh
            if self.rnd.random() < towers:
                # stepped tower with a spire
                self.poly([(x, base), (x, top + 40), (x + bw * 0.2, top + 40), (x + bw * 0.2, top),
                           (x + bw * 0.8, top), (x + bw * 0.8, top + 40), (x + bw, top + 40), (x + bw, base)], fill, ink)
                self.line([(x + bw / 2, top), (x + bw / 2, top - 50)], INK_A, 4)
            else:
                self.rect(x, top, x + bw, base, fill, ink)
            if windows > 0:
                for wy in range(int(top + 16), int(base - 8), 18):
                    for wx in range(int(x + 10), int(x + bw - 10), 16):
                        if self.rnd.random() < windows:
                            self.d.rectangle([wx * SS, wy * SS, (wx + 7) * SS, (wy + 9) * SS], fill=win)
            x += bw + self.rnd.randint(-6, 10)

    def palm(self, x, base, height, lean, color=INK_A, frond=1.0):
        pts = []
        for i in range(21):
            t = i / 20
            pts.append((x + lean * t * t * height, base - t * height))
        for i in range(len(pts) - 1):
            w = 26 - 14 * (i / len(pts))
            self.line([pts[i], pts[i + 1]], color, w)
        tx, ty = pts[-1]
        for k in range(11):
            ang = math.radians(-190 + k * 20 + self.rnd.uniform(-6, 6))
            length = height * 0.46 * frond * self.rnd.uniform(0.85, 1.1)
            droop = length * (0.35 + 0.35 * abs(math.cos(ang)))
            spine = []
            for i in range(15):
                t = i / 14
                lx = tx + math.cos(ang) * length * t
                ly = ty + math.sin(ang) * length * t * 0.55 + droop * t * t
                spine.append((lx, ly))
            width = height * 0.05
            upper, lower = [], []
            for i in range(len(spine)):
                a = spine[max(0, i - 1)]
                b = spine[min(len(spine) - 1, i + 1)]
                dx, dy = b[0] - a[0], b[1] - a[1]
                n = math.hypot(dx, dy) or 1
                nx, ny = -dy / n, dx / n
                wv = width * math.sin(math.pi * min(1, (i / 14) * 1.15)) + 1
                upper.append((spine[i][0] + nx * wv, spine[i][1] + ny * wv))
                lower.append((spine[i][0] - nx * wv * 0.6, spine[i][1] - ny * wv * 0.6))
            self.poly(upper + lower[::-1], color, 0)
        self.circle(tx, ty, height * 0.03, color)

    def car(self, x, base, length, body, glass=(40, 50, 80, 255), facing=1, rim=(255, 220, 170, 255)):
        L = length
        f = facing

        def X(t):
            return x + f * t * L
        h = L * 0.24
        body_pts = [(X(0.0), base - h * 0.35), (X(0.02), base - h * 0.62), (X(0.22), base - h * 0.72),
                    (X(0.36), base - h * 1.18), (X(0.66), base - h * 1.2), (X(0.8), base - h * 0.78),
                    (X(0.98), base - h * 0.66), (X(1.0), base - h * 0.4), (X(0.97), base - h * 0.12),
                    (X(0.03), base - h * 0.12)]
        self.poly(body_pts, body, 5)
        self.poly([(X(0.39), base - h * 1.1), (X(0.64), base - h * 1.12), (X(0.75), base - h * 0.8),
                   (X(0.31), base - h * 0.8)], glass, 3)
        self.line([(X(0.05), base - h * 0.6), (X(0.95), base - h * 0.62)], rim, 3)
        for t in (0.2, 0.8):
            self.circle(X(t), base - h * 0.12, h * 0.36, (20, 18, 24, 255), ink=4)
            self.circle(X(t), base - h * 0.12, h * 0.18, (150, 150, 160, 255))

    def crane(self, x, base, height, color, lights=True):
        self.rect(x - 14, base - height, x + 14, base, color, 3)
        for y in range(int(base - height), int(base), 36):
            self.line([(x - 14, y), (x + 14, y + 36)], INK_A, 2)
        arm_y = base - height
        self.rect(x - 240, arm_y - 22, x + 120, arm_y, color, 3)
        for xx in range(int(x - 240), int(x + 120), 30):
            self.line([(xx, arm_y), (xx + 15, arm_y - 22)], INK_A, 2)
        self.line([(x, arm_y - 70), (x - 230, arm_y - 22)], INK_A, 3)
        self.line([(x, arm_y - 70), (x + 110, arm_y - 22)], INK_A, 3)
        self.rect(x - 8, arm_y - 72, x + 8, arm_y - 22, color, 3)
        self.line([(x - 160, arm_y), (x - 160, arm_y + 180)], INK_A, 2)
        if lights:
            self.glow(x, arm_y - 72, 14, (255, 60, 60), blur=8, alpha=255)

    def finish(self, grain=7, vignette=0.55):
        img = self.img.resize((W, H), Image.LANCZOS).convert("RGB")
        # print grain
        noise = Image.effect_noise((W, H), grain * 4).convert("L")
        img = Image.blend(img, Image.merge("RGB", (noise, noise, noise)), 0.035)
        # vignette
        vg = Image.new("L", (W, H), 0)
        d = ImageDraw.Draw(vg)
        for i in range(40):
            t = i / 40
            d.ellipse([-W * 0.25 + t * W * 0.25, -H * 0.3 + t * H * 0.3, W * 1.25 - t * W * 0.25,
                       H * 1.3 - t * H * 0.3], fill=int(255 * t))
        vg = vg.filter(ImageFilter.GaussianBlur(60))
        dark = Image.new("RGB", (W, H), (10, 6, 18))
        mask = vg.point(lambda v: int((255 - v) * vignette))
        img.paste(dark, (0, 0), mask)
        return img


def sky_sunset():
    return [(0, (58, 46, 110)), (0.42, (164, 92, 142)), (0.68, (242, 149, 110)), (0.84, (255, 194, 122)),
            (1, (255, 214, 150))]


def scene_skyline():
    s = Scene(sky_sunset(), 11)
    s.glow(1180, 380, 300, (255, 210, 150), blur=100, alpha=230)
    s.circle(1180, 380, 130, (255, 226, 170, 255))
    s.haze(520, 760, (255, 190, 160), 140)
    s.skyline(760, -40, 1960, 120, 330, (150, 92, 140, 255), ink=0, windows=0.0, towers=0.3)
    s.haze(600, 800, (240, 150, 140), 120)
    s.skyline(790, -40, 1960, 120, 380, (74, 44, 92, 255), ink=4, windows=0.14, towers=0.35)
    # water with sun glints
    s.d.rectangle([0, 790 * SS, W * SS, H * SS], fill=(56, 36, 82, 255))
    for i in range(40):
        y = 800 + i * 7
        half = 30 + i * 9 + s.rnd.randint(-10, 10)
        s.d.rectangle([(1180 - half) * SS, y * SS, (1180 + half) * SS, (y + 3) * SS],
                      fill=(255, 210, 150, max(0, 210 - i * 5)))
    s.palm(150, 1100, 620, 0.25)
    s.palm(330, 1120, 470, 0.4)
    s.palm(1790, 1110, 560, -0.3)
    return s.finish()


def scene_street():
    s = Scene([(0, (70, 50, 120)), (0.5, (220, 120, 120)), (0.8, (255, 180, 120)), (1, (255, 200, 140))], 22)
    vx, vy = 960, 560
    s.glow(vx, vy - 20, 200, (255, 210, 160), blur=70, alpha=220)
    # buildings both sides in perspective
    for side in (-1, 1):
        for k in range(7):
            near = 1 - k / 7
            x_out = vx + side * (980 * near + 60)
            x_in = vx + side * (980 * (1 - (k + 1) / 7) + 60)
            top_out = vy - 520 * near - 80
            top_in = vy - 520 * (1 - (k + 1) / 7) - 80
            col = lerp_col((60, 34, 74), (170, 100, 130), k / 7) + (255,)
            s.poly([(x_out, 1080 * near + vy * (1 - near)), (x_out, top_out), (x_in, top_in),
                    (x_in, 1080 * (1 - (k + 1) / 7) + vy * ((k + 1) / 7))], col, 3)
    # road
    s.poly([(vx - 20, vy), (vx + 20, vy), (1700, 1080), (220, 1080)], (52, 40, 70, 255), 0)
    for i in range(10):
        t0, t1 = (i / 10) ** 2, ((i + 0.5) / 10) ** 2
        s.poly([(vx - 2 - 8 * t0, vy + 520 * t0), (vx + 2 + 8 * t0, vy + 520 * t0),
                (vx + 2 + 8 * t1, vy + 520 * t1), (vx - 2 - 8 * t1, vy + 520 * t1)], (255, 210, 120, 255), 0)
    # street lights
    for side in (-1, 1):
        for k in range(4):
            t = 1 - k / 4
            x = vx + side * (700 * t + 40)
            y = vy + 480 * t
            hgt = 520 * t + 40
            s.line([(x, y), (x, y - hgt)], INK_A, 6 * t + 2)
            s.line([(x, y - hgt), (x - side * 70 * t, y - hgt)], INK_A, 5 * t + 2)
            s.glow(x - side * 70 * t, y - hgt + 8, 30 * t + 8, (255, 220, 160), blur=12, alpha=255)
    s.haze(480, 700, (255, 180, 150), 110)
    s.car(560, 1010, 820, (214, 66, 40, 255))
    s.glow(1360, 900, 50, (255, 240, 200), blur=20, alpha=200)
    return s.finish()


def scene_hills():
    s = Scene([(0, (40, 30, 80)), (0.45, (120, 70, 130)), (0.75, (230, 130, 120)), (1, (255, 190, 130))], 33)
    s.glow(420, 640, 180, (255, 200, 150), blur=80, alpha=200)

    def ridge(base, amp, freq, phase, col, ink):
        pts = [(-20, 1100)]
        for x in range(-20, 1960, 20):
            y = base - amp * (0.6 * math.sin(x * freq + phase) + 0.4 * math.sin(x * freq * 2.3 + phase * 1.7))
            pts.append((x, y))
        pts.append((1960, 1100))
        s.poly(pts, col, ink)
    ridge(560, 90, 0.004, 1.0, (150, 90, 140, 255), 0)
    ridge(700, 120, 0.003, 2.2, (92, 56, 110, 255), 4)
    # the sign on the near ridge
    f = font("Kanit-900", 120 * SS)
    letters = "HOTWIRE"
    x = 640
    for i, ch in enumerate(letters):
        y = 470 + i * 9
        s.line([(x - 18, y + 40), (x - 18, y + 96)], INK_A, 5)
        s.line([(x + 18, y + 40), (x + 18, y + 96)], INK_A, 5)
        s.d.text((x * SS, y * SS), ch, font=f, fill=(245, 240, 235, 255), anchor="mm", stroke_width=5 * SS,
                 stroke_fill=INK_A)
        x += 112
    # mansions with lit windows
    for k in range(9):
        mx = 120 + k * 210 + s.rnd.randint(-30, 30)
        my = 790 + s.rnd.randint(-30, 40)
        s.rect(mx, my - 50, mx + 110, my, (210, 190, 200, 255), 3)
        s.poly([(mx - 10, my - 50), (mx + 55, my - 82), (mx + 120, my - 50)], (120, 60, 70, 255), 3)
        for wx in range(mx + 12, mx + 100, 24):
            s.rect(wx, my - 38, wx + 12, my - 22, (255, 210, 130, 255), 2)
    ridge(900, 60, 0.005, 0.4, (48, 30, 62, 255), 4)
    s.palm(1650, 1120, 600, -0.2)
    s.palm(1800, 1130, 470, -0.35)
    s.palm(90, 1120, 520, 0.3)
    return s.finish()


def scene_port():
    s = Scene([(0, (14, 18, 46)), (0.5, (52, 40, 96)), (0.8, (150, 80, 120)), (1, (230, 130, 110))], 44)
    s.circle(1560, 220, 60, (250, 236, 210, 255))
    s.glow(1560, 220, 120, (200, 200, 255), blur=50, alpha=90)
    for i in range(200):
        s.circle(s.rnd.uniform(0, 1920), s.rnd.uniform(0, 520), s.rnd.uniform(1, 2.5), (255, 255, 255, 180))
    s.skyline(760, -40, 1960, 60, 200, (60, 44, 90, 255), ink=0, windows=0.05)
    s.crane(420, 840, 520, (230, 120, 60, 255))
    s.crane(1100, 840, 600, (230, 120, 60, 255))
    s.crane(1650, 840, 460, (230, 120, 60, 255))
    s.d.rectangle([0, 840 * SS, W * SS, H * SS], fill=(26, 24, 46, 255))
    cols = [(178, 54, 50, 255), (40, 90, 140, 255), (216, 150, 50, 255), (60, 120, 80, 255), (120, 110, 120, 255)]
    for row in range(3):
        x = -20 + row * 30
        while x < 1960:
            cw = s.rnd.choice([120, 240])
            stack = s.rnd.randint(1, 4)
            for k in range(stack):
                y1 = 1000 - row * 30 - k * 58
                s.rect(x, y1 - 58, x + cw, y1, s.rnd.choice(cols), 3)
                for rib in range(int(x + 10), int(x + cw - 6), 12):
                    s.line([(rib, y1 - 52), (rib, y1 - 6)], (0, 0, 0, 60), 2)
            x += cw + s.rnd.randint(6, 30)
    s.haze(700, 900, (120, 80, 140), 90)
    return s.finish()


def scene_chase():
    s = Scene([(0, (50, 36, 100)), (0.55, (190, 100, 130)), (0.85, (255, 170, 110)), (1, (255, 200, 140))], 55)
    s.glow(1500, 520, 220, (255, 200, 150), blur=80, alpha=210)
    s.skyline(640, -40, 1960, 120, 380, (120, 74, 128, 255), ink=0, windows=0.06, towers=0.4)
    s.haze(480, 680, (240, 160, 150), 120)
    # freeway deck
    s.poly([(-20, 640), (1960, 560), (1960, 640), (-20, 720)], (78, 52, 96, 255), 4)
    s.poly([(-20, 720), (1960, 640), (1960, 1100), (-20, 1100)], (44, 30, 64, 255), 0)
    for x in range(0, 1960, 260):
        s.rect(x, 700 - x * 0.04, x + 40, 1100, (60, 40, 80, 255), 3)
    # cars on the deck
    s.car(1000, 612, 420, (40, 40, 48, 255), facing=-1)
    s.glow(840, 520, 60, (255, 40, 40), blur=24, alpha=230)
    s.glow(920, 520, 60, (40, 110, 255), blur=24, alpha=230)
    s.car(1420, 596, 380, (234, 200, 70, 255), facing=-1)
    for k in range(8):
        y = 560 + k * 9
        s.line([(1820, y), (1960, y - 4)], (255, 240, 220, 140), 3)
    s.palm(120, 1120, 560, 0.25)
    return s.finish()


def scene_pier():
    s = Scene([(0, (64, 52, 120)), (0.4, (170, 100, 150)), (0.7, (250, 150, 110)), (1, (255, 210, 140))], 66)
    s.glow(560, 640, 230, (255, 220, 160), blur=80, alpha=230)
    s.circle(560, 660, 110, (255, 230, 180, 255))
    s.d.rectangle([0, 700 * SS, W * SS, 900 * SS], fill=(90, 70, 130, 255))
    for i in range(28):
        y = 706 + i * 7
        half = 20 + i * 7
        s.d.rectangle([(560 - half) * SS, y * SS, (560 + half) * SS, (y + 3) * SS], fill=(255, 220, 160, 190 - i * 6))
    # pier + ferris wheel
    s.rect(900, 690, 1960, 712, (60, 40, 70, 255), 3)
    for x in range(920, 1960, 70):
        s.line([(x, 712), (x, 780)], INK_A, 6)
    cx, cy, r = 1460, 470, 200
    s.circle(cx, cy, r, None, ink=8)
    for k in range(16):
        a = math.radians(k * 22.5)
        s.line([(cx, cy), (cx + r * math.cos(a), cy + r * math.sin(a))], INK_A, 3)
        s.rect(cx + r * math.cos(a) - 14, cy + r * math.sin(a) - 4, cx + r * math.cos(a) + 14,
               cy + r * math.sin(a) + 18, (230, 120, 80, 255), 2)
    s.line([(cx, cy), (cx - 110, 690)], INK_A, 8)
    s.line([(cx, cy), (cx + 110, 690)], INK_A, 8)
    # beach
    s.poly([(-20, 880), (900, 860), (1960, 900), (1960, 1100), (-20, 1100)], (230, 180, 130, 255), 4)
    s.poly([(-20, 880), (900, 860), (1960, 900), (1960, 912), (900, 874), (-20, 894)], (255, 240, 220, 255), 0)
    s.palm(250, 1100, 640, 0.2)
    s.palm(1780, 1110, 500, -0.3)
    s.car(980, 1040, 520, (93, 182, 229, 255))
    return s.finish()


SCENES = [scene_skyline, scene_street, scene_hills, scene_port, scene_chase, scene_pier]


def main():
    for i, fn in enumerate(SCENES):
        save(fn(), f"loading_{i + 1}.png")
        print("loading", i + 1)


if __name__ == "__main__":
    main()
