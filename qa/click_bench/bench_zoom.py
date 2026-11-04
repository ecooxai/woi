"""Two-stage zoom: stage 1 = the click of an earlier run (rows.json); stage 2 =
a crop around it (cw x ch screen px, clamped to the screen, upscaled by
--zoom) sent to --model, which answers in crop pixels.

  python bench_zoom.py --from rt_gpt-realtime-2.1_base --model gpt-realtime-2.1 --cw 480 --ch 270 --zoom 2
  python bench_zoom.py --from rt_gpt-realtime-2.1_base --model gpt-6-luna --cw 640 --ch 400 --zoom 1
"""
from __future__ import annotations

import argparse
import asyncio
import json
import re
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

from common import *

ap = argparse.ArgumentParser()
ap.add_argument("--from", dest="src", required=True)
ap.add_argument("--model", default="gpt-realtime-2.1")
ap.add_argument("--cw", type=int, default=480)
ap.add_argument("--ch", type=int, default=270)
ap.add_argument("--zoom", type=float, default=2.0)
ap.add_argument("--every", type=int, default=1)
ap.add_argument("--conc", type=int, default=4)
ap.add_argument("--effort", default=None)
ap.add_argument("--tag", default="")
a = ap.parse_args()

rows0 = json.loads((RESULTS / a.src / "rows.json").read_text())[:: a.every]
layouts = {i: json.loads((BENCH / f"layout{i}.json").read_text()) for i in {r["layout"] for r in rows0}}
pages = {i: Image.open(BENCH / f"page{i}.png").convert("RGB") for i in layouts}
INSTR = app_instructions()
LOC = ('You locate UI elements in a screenshot for a click tool. Reply with JSON only: {"x": <int>, "y": <int>} '
       '= the pixel at the centre of the element the user means, in this image\'s pixel coordinates (origin '
       'top-left), or {"error": "not visible"} if it is not in the image.')


def crop_box(sx, sy, sw, sh):
    cw, ch = min(a.cw, sw), min(a.ch, sh)
    x0 = min(max(round(sx - cw / 2), 0), sw - cw)
    y0 = min(max(round(sy - ch / 2), 0), sh - ch)
    return x0, y0, cw, ch


def build(r):
    page = pages[r["layout"]]
    t = next(t for t in layouts[r["layout"]]["targets"] if t["id"] == r["id"])
    sx, sy = (r["sx"], r["sy"]) if r.get("sx") is not None else (page.width // 2, page.height // 2)
    x0, y0, cw, ch = crop_box(sx, sy, *page.size)
    img = page.crop((x0, y0, x0 + cw, y0 + ch))
    if a.zoom != 1:
        img = img.resize((round(cw * a.zoom), round(ch * a.zoom)), Image.LANCZOS)
    return t, img, (x0, y0, cw, ch)


def finish(r, t, img, box, args, lat, stage1_lat, extra=None):
    x0, y0, cw, ch = box
    sx = sy = None
    if args and "x" in args:
        sx = round(x0 + args["x"] * cw / img.width)
        sy = round(y0 + args["y"] * ch / img.height)
    inside = box[0] <= t["x"] + t["w"] / 2 <= box[0] + cw and box[1] <= t["y"] + t["h"] / 2 <= box[1] + ch
    row = {"layout": r["layout"], "id": r["id"], "args": args, "sx": sx, "sy": sy, "lat": (lat or 0) + (stage1_lat or 0),
           "lat2": lat, "in_crop": inside, "small": min(t["w"], t["h"]) <= 24, **score(t, sx, sy), **(extra or {})}
    print(f"L{r['layout']} {r['id']:16s} {'HIT ' if row['hit'] else 'miss'} in_crop={inside} err={row['err'] and round(row['err'])} "
          f"args={args} lat2={lat and round(lat, 2)}", flush=True)
    return row


async def rt_all():
    sem = asyncio.Semaphore(a.conc)

    async def one(r):
        async with sem:
            t, img, box = build(r)
            note = (f"Zoomed view ({a.zoom:g}x) of part of the screen. This image is {img.width}x{img.height}; "
                    "click_screen uses this image's pixel coordinates.")
            res = await realtime_trial(a.model, INSTR, [CLICK_SPEC], [image_item(png_bytes(img), note),
                                       text_item(f"Click {t['ask']}.")])
            return finish(r, t, img, box, res["args"], res["lat"], r.get("lat"), {"err_msg": res["error"]})

    return await asyncio.gather(*(one(r) for r in rows0))


def luna_one(r):
    t, img, box = build(r)
    content = [{"type": "input_image", "image_url": data_url(png_bytes(img))},
               {"type": "input_text", "text": f"Image size: {img.width}x{img.height} pixels. Target: {t['ask']}"}]
    res = responses_call(a.model, LOC, content, reasoning=a.effort)
    m = re.search(r"\{.*\}", res.get("text") or "", re.S)
    try:
        args = json.loads(m.group(0)) if m else None
    except Exception:
        args = None
    return finish(r, t, img, box, args, res.get("lat"), r.get("lat"),
                  {"err_msg": res.get("error"), "usage_in": (res.get("usage") or {}).get("input_tokens")})


if a.model.startswith("gpt-realtime"):
    rows = asyncio.run(rt_all())
else:
    with ThreadPoolExecutor(a.conc) as ex:
        rows = list(ex.map(luna_one, rows0))
tag = f"zoom_{a.model}_{a.cw}x{a.ch}_z{a.zoom:g}{a.tag}"
out = RESULTS / tag
out.mkdir(parents=True, exist_ok=True)
for li in layouts:
    draw_marks(pages[li], layouts[li], [r for r in rows if r["layout"] == li], out / f"layout{li}.png")
s = summarize(rows)
s["in_crop"] = sum(r["in_crop"] for r in rows) / len(rows)
lat2 = sorted(r["lat2"] for r in rows if r["lat2"])
s["med_lat2"] = lat2[len(lat2) // 2] if lat2 else None
(out / "rows.json").write_text(json.dumps(rows, indent=1))
(out / "summary.json").write_text(json.dumps(s, indent=1))
print(tag, json.dumps(s))
