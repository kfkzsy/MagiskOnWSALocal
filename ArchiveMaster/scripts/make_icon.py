"""Draws the app icon (an orange zipper document) and writes every size the bundle needs.
Usage: python3 make_icon.py <out-dir>"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 2048  # draw at 2x of 1024 and downsample for clean edges


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw():
    top, bottom = (255, 184, 0), (255, 102, 0)
    img = Image.new("RGB", (S, S))
    px = ImageDraw.Draw(img)
    for y in range(S):
        px.line([(0, y), (S, y)], fill=lerp(top, bottom, y / (S - 1)))

    # Document with a soft shadow.
    x0, y0, x1, y1, r, fold = 600, 380, 1448, 1668, 120, 260
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x0, y0 + 40, x1, y1 + 40], r, fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(50))
    img.paste((150, 50, 0), (0, 0), shadow)

    doc = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(doc)
    d.rounded_rectangle([x0, y0, x1, y1], r, fill=255)
    d.polygon([(x1 - fold, y0 - 2), (x1 + 2, y0 - 2), (x1 + 2, y0 + fold)], fill=0)  # cut the folded corner
    img.paste((255, 255, 255), (0, 0), doc)
    g = ImageDraw.Draw(img)
    flap = Image.new("L", (S, S), 0)
    ImageDraw.Draw(flap).rounded_rectangle([x1 - fold - 200, y0 - 200, x1, y0 + fold], 50, fill=255)
    tri = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tri).polygon([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)], fill=255)
    flap = Image.composite(flap, Image.new("L", (S, S), 0), tri)
    img.paste((255, 214, 150), (0, 0), flap)

    # Zipper teeth down the middle.
    cx, tooth_w, tooth_h, step = (x0 + x1) // 2 - 40, 92, 44, 88
    teeth = (255, 140, 0)
    y = y0 + 70
    left = True
    while y < 1180:
        if left:
            g.rounded_rectangle([cx - tooth_w, y, cx + 8, y + tooth_h], 18, fill=teeth)
        else:
            g.rounded_rectangle([cx - 8, y, cx + tooth_w, y + tooth_h], 18, fill=teeth)
        left = not left
        y += step // 2 + 10

    # Pull tab.
    pull = (230, 96, 0)
    g.rounded_rectangle([cx - 78, 1200, cx + 78, 1300], 30, fill=pull)
    g.rounded_rectangle([cx - 62, 1290, cx + 62, 1530], 56, fill=pull)
    g.rounded_rectangle([cx - 28, 1380, cx + 28, 1480], 28, fill=(255, 255, 255))
    return img.resize((1024, 1024), Image.LANCZOS)


SIZES = {
    "AppIcon29x29@2x.png": 58, "AppIcon29x29@3x.png": 87,
    "AppIcon40x40@2x.png": 80, "AppIcon40x40@3x.png": 120,
    "AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180,
    "AppIcon29x29~ipad.png": 29, "AppIcon29x29@2x~ipad.png": 58,
    "AppIcon40x40~ipad.png": 40, "AppIcon40x40@2x~ipad.png": 80,
    "AppIcon76x76~ipad.png": 76, "AppIcon76x76@2x~ipad.png": 152,
    "AppIcon83.5x83.5@2x~ipad.png": 167,
}


def main(out):
    os.makedirs(out, exist_ok=True)
    icon = draw()
    icon.save(os.path.join(out, "AppIcon1024.png"))
    for name, size in SIZES.items():
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(out, name))


if __name__ == "__main__":
    main(sys.argv[1])
