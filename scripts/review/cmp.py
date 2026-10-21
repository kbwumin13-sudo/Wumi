"""Crop the same region (in points) from two 2x captures and stack them for side-by-side review.
usage: cmp.py ref.png ours.png x y w h out.png [--side]"""
import sys
from PIL import Image, ImageDraw
ref, ours, x, y, w, h, out = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:7]), sys.argv[7]
side = "--side" in sys.argv
box = tuple(int(v * 2) for v in (x, y, x + w, y + h))
a = Image.open(ref).convert("RGB").crop(box)
b = Image.open(ours).convert("RGB").crop(box)
gap = 12
if side:
    canvas = Image.new("RGB", (a.width + b.width + gap, max(a.height, b.height)), (255, 0, 255))
    canvas.paste(a, (0, 0)); canvas.paste(b, (a.width + gap, 0))
else:
    canvas = Image.new("RGB", (max(a.width, b.width), a.height + b.height + gap), (255, 0, 255))
    canvas.paste(a, (0, 0)); canvas.paste(b, (0, a.height + gap))
canvas.save(out)
print(out, canvas.size)
