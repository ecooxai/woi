"""Draw stage B clicks on the page screenshot: target boxes (green = hit, red = miss)
and the real click point coloured by how it was located.

  python marks_stageb.py RESULTS/web   # writes stageb_<tag>_marks.png next to each json
"""
import glob, json, sys
from pathlib import Path
from PIL import Image, ImageDraw

d = Path(sys.argv[1])
layout = {t["id"]: t for t in json.load(open(d / "web_layout.json"))["targets"]}
base = Image.open(d / "shot_web.png").convert("RGB")
col = {"element": (0, 120, 255), "vision": (200, 0, 200), "model_xy": (255, 140, 0), "xy": (255, 140, 0)}
for f in sorted(glob.glob(str(d / "stageb_*.json"))):
    rows = json.load(open(f))
    im = base.resize((1600, 900)) if base.size != (1600, 900) else base.copy()
    g = ImageDraw.Draw(im)
    for r in rows:
        t = layout[r["id"]]
        g.rectangle([t["x"], t["y"], t["x"] + t["w"], t["y"] + t["h"]], outline=(0, 170, 0) if r["hit"] else (230, 0, 0), width=2)
        if r.get("sx") is not None:
            x, y, c = r["sx"], r["sy"], col.get(r.get("located_by", "xy"), (0, 0, 0))
            g.line([x - 6, y, x + 6, y], fill=c, width=2)
            g.line([x, y - 6, x, y + 6], fill=c, width=2)
            g.text((x + 5, y + 3), r["id"], fill=c)
    g.text((10, 880), f"{Path(f).stem}: {sum(r['hit'] for r in rows)}/{len(rows)}  blue=element magenta=vision orange=model x/y", fill=(0, 0, 0))
    im.save(f[:-5] + "_marks.png")
    print(f[:-5] + "_marks.png")
