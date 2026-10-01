# Renders Resources/AppIcon.png (1024², no transparency).
from PIL import Image, ImageDraw, ImageFilter
S = 1024
img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
for y in range(S):  # background gradient
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(40 - 30 * t), int(12 - 8 * t), int(70 - 50 * t)))
cx, top, bot = S / 2, 170, 900
tw, bw = 90, 820
# highway
d.polygon([(cx - bw / 2, bot + 80), (cx - tw / 2, top), (cx + tw / 2, top), (cx + bw / 2, bot + 80)], fill=(14, 14, 22))
for i in range(1, 5):
    f = i / 5
    d.line([(cx - bw / 2 + bw * f, bot + 80), (cx - tw / 2 + tw * f, top)], fill=(60, 60, 80), width=4)
for k in range(1, 9):  # beat lines
    z = k / 9
    y = bot - (bot - top) * (1 - 1 / (1 + z * 2.3)) / (1 - 1 / 3.3)
    w = tw + (bw - tw) * (y - top) / (bot + 80 - top)
    d.line([(cx - w / 2, y), (cx + w / 2, y)], fill=(70, 70, 95), width=3)
glow = Image.new("RGB", (S, S))
g = ImageDraw.Draw(glow)
cols = [(40, 220, 70), (240, 45, 50), (255, 215, 25), (45, 130, 255), (255, 135, 20)]
# rails
d.line([(cx - bw / 2, bot + 80), (cx - tw / 2, top)], fill=(255, 150, 40), width=10)
d.line([(cx + bw / 2, bot + 80), (cx + tw / 2, top)], fill=(255, 150, 40), width=10)
# gems on the strikeline and a few coming down
for i, c in enumerate(cols):
    x = cx - bw / 2 + bw * (i + 0.5) / 5 * 0.96 + bw * 0.02
    for (y, r) in [(bot - 10, 70)]:
        g.ellipse([x - r, y - r * 0.5, x + r, y + r * 0.5], fill=c)
        d.ellipse([x - r, y - r * 0.5, x + r, y + r * 0.5], fill=c, outline=(255, 255, 255), width=6)
        d.ellipse([x - r * 0.45, y - r * 0.22, x + r * 0.45, y + r * 0.22], fill=(245, 245, 245))
for (lane, z) in [(1, 0.35), (3, 0.55), (0, 0.8), (4, 0.25)]:
    y = bot - 10 - (bot - top) * (1 - 1 / (1 + z * 2.3)) / (1 - 1 / 3.3)
    w = tw + (bw - tw) * (y - top) / (bot + 80 - top)
    x = cx - w / 2 + w * (lane + 0.5) / 5
    r = 70 * w / bw
    d.ellipse([x - r, y - r * 0.5, x + r, y + r * 0.5], fill=cols[lane], outline=(255, 255, 255), width=4)
glow = glow.filter(ImageFilter.GaussianBlur(40))
img = Image.blend(img, glow, 0.0)
img = Image.composite(img, img, Image.new("L", (S, S), 255))
out = Image.new("RGB", (S, S))
out.paste(img)
# add glow additively
from PIL import ImageChops
out = ImageChops.add(out, glow.point(lambda v: int(v * 0.6)))
out.save("Resources/AppIcon.png")
