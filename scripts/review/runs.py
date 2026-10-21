"""Find horizontal runs of 'ink' (pixels far from the background) inside a band, with each run's vertical extent.
usage: runs.py img y0 y1 x0 x1 [tolerance=12] [mingap=1.5]   (all in points)"""
import sys
from PIL import Image
img = sys.argv[1]; y0, y1, x0, x1 = map(float, sys.argv[2:6])
tol = float(sys.argv[6]) if len(sys.argv) > 6 else 12
mingap = float(sys.argv[7]) if len(sys.argv) > 7 else 1.5
im = Image.open(img).convert("RGB")
Y0, Y1, X0, X1 = int(y0*2), int(y1*2), int(x0*2), int(x1*2)
# background = most common color in the band
from collections import Counter
cnt = Counter(im.getpixel((x, y)) for x in range(X0, X1, 2) for y in range(Y0, Y1, 2))
bg = cnt.most_common(1)[0][0]
def ink(p): return max(abs(p[i]-bg[i]) for i in range(3)) > tol
cols = []
for x in range(X0, X1):
    ys = [y for y in range(Y0, Y1) if ink(im.getpixel((x, y)))]
    cols.append((x, ys))
runs = []; cur = None; gap = 0
for x, ys in cols:
    if ys:
        if cur and (x - cur['x1']) <= mingap*2:
            cur['x1'] = x; cur['ymin'] = min(cur['ymin'], min(ys)); cur['ymax'] = max(cur['ymax'], max(ys))
        else:
            cur = {'x0': x, 'x1': x, 'ymin': min(ys), 'ymax': max(ys)}; runs.append(cur)
print("bg", bg)
for r in runs:
    print(f"x {r['x0']/2:7.1f}-{(r['x1']+1)/2:7.1f} (w {(r['x1']+1-r['x0'])/2:5.1f})  y {r['ymin']/2:6.1f}-{(r['ymax']+1)/2:6.1f} (h {(r['ymax']+1-r['ymin'])/2:5.1f})")
