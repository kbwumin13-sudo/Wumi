"""Print pixel colors along a horizontal or vertical line. usage: px.py img h|v fixed_pt start_pt end_pt"""
import sys
from PIL import Image
img, mode, fixed, a, b = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:6])
im = Image.open(img).convert("RGB")
prev = None
for p in range(int(a * 2), int(b * 2)):
    xy = (p, int(fixed * 2)) if mode == "h" else (int(fixed * 2), p)
    c = im.getpixel(xy)
    if c != prev:
        print(f"{p/2:7.1f}pt  {c}")
        prev = c
