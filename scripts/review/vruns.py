"""Vertical runs of ink in a column band: rows of content with their x extents. usage: vruns.py img x0 x1 y0 y1 [tol] [mingap]"""
import sys
from PIL import Image
from collections import Counter
img = sys.argv[1]; x0, x1, y0, y1 = map(float, sys.argv[2:6])
tol = float(sys.argv[6]) if len(sys.argv) > 6 else 14
mingap = float(sys.argv[7]) if len(sys.argv) > 7 else 2
im = Image.open(img).convert("RGB")
X0, X1, Y0, Y1 = int(x0*2), int(x1*2), int(y0*2), int(y1*2)
cnt = Counter(im.getpixel((x, y)) for x in range(X0, X1, 2) for y in range(Y0, Y1, 2))
bg = cnt.most_common(1)[0][0]
def ink(p): return max(abs(p[i]-bg[i]) for i in range(3)) > tol
runs = []; cur = None
for y in range(Y0, Y1):
    xs = [x for x in range(X0, X1) if ink(im.getpixel((x, y)))]
    if xs:
        if cur and y - cur['y1'] <= mingap*2:
            cur['y1'] = y; cur['xmin'] = min(cur['xmin'], min(xs)); cur['xmax'] = max(cur['xmax'], max(xs))
        else:
            cur = {'y0': y, 'y1': y, 'xmin': min(xs), 'xmax': max(xs)}; runs.append(cur)
print("bg", bg)
for r in runs:
    print(f"y {r['y0']/2:6.1f}-{(r['y1']+1)/2:6.1f} (h {(r['y1']+1-r['y0'])/2:5.1f})  x {r['xmin']/2:6.1f}-{(r['xmax']+1)/2:6.1f}")
