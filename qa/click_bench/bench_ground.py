"""Grounding-only requests (what the app's locator does): screenshot + target
description -> {"x","y"} JSON from a Responses model.

  python bench_ground.py --effort none --res native --every 2
"""
from __future__ import annotations

import argparse
import json
import re
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

from common import *

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="gpt-6-luna")
ap.add_argument("--effort", default=None)
ap.add_argument("--res", default="native")  # native | 1280 | crop
ap.add_argument("--layouts", type=int, nargs="+", default=[0, 1, 2])
ap.add_argument("--every", type=int, default=2)
ap.add_argument("--conc", type=int, default=3)
ap.add_argument("--prompt", default=None, help="file with the instructions (default: the app's kLocateInstructions)")
ap.add_argument("--tag", default="")
a = ap.parse_args()


def app_locate_instr():
    src = (REPO / "app/lib/core/vision/click_locator.dart")
    if src.exists():
        m = re.search(r"const kLocateInstructions = '''\n(.*?)''';", src.read_text(), re.S)
        if m:
            return m.group(1)
    return ("You locate UI elements in a screenshot for a click tool. Reply with JSON only: "
            '{"x": <int>, "y": <int>} = the pixel at the centre of the element the user means, in this image\'s '
            'pixel coordinates (origin top-left), or {"error": "<why>"} if it is not visible.')


INSTR = open(a.prompt).read() if a.prompt else app_locate_instr()


def job(li, t, img, sw, sh):
    content = [{"type": "input_image", "image_url": data_url(png_bytes(img))},
               {"type": "input_text", "text": f"Image size: {img.width}x{img.height} pixels. Target: {t['ask']}"}]
    r = responses_call(a.model, INSTR, content, reasoning=a.effort)
    m = re.search(r"\{.*\}", r.get("text") or "", re.S)
    args = None
    try:
        args = json.loads(m.group(0)) if m else None
    except Exception:
        pass
    sx = sy = None
    if args and "x" in args:
        sx = round(args["x"] * sw / img.width)
        sy = round(args["y"] * sh / img.height)
    row = {"layout": li, "id": t["id"], "args": args, "sx": sx, "sy": sy, "lat": r.get("lat"),
           "err_msg": r.get("error"), "small": min(t["w"], t["h"]) <= 24,
           "usage": r.get("usage"), **score(t, sx, sy)}
    print(f"L{li} {t['id']:16s} {'HIT ' if row['hit'] else 'miss'} err={row['err'] and round(row['err'])} "
          f"args={args} lat={round(r['lat'], 2)} {r.get('error') or ''}", flush=True)
    return row


def main():
    jobs, pages = [], {}
    for li in a.layouts:
        layout = json.loads((BENCH / f"layout{li}.json").read_text())
        page = Image.open(BENCH / f"page{li}.png").convert("RGB")
        img = app_scale(page, 1280 if a.res == "1280" else 10 ** 6)
        pages[li] = (layout, page)
        for t in layout["targets"][:: a.every]:
            jobs.append((li, t, img, page.width, page.height))
    with ThreadPoolExecutor(a.conc) as ex:
        rows = list(ex.map(lambda j: job(*j), jobs))
    tag = f"ground_{a.model}_{a.res}_{a.effort or 'default'}{a.tag}"
    out = RESULTS / tag
    out.mkdir(parents=True, exist_ok=True)
    for li, (layout, page) in pages.items():
        draw_marks(page, layout, [r for r in rows if r["layout"] == li], out / f"layout{li}.png")
    s = summarize(rows)
    (out / "rows.json").write_text(json.dumps(rows, indent=1))
    (out / "summary.json").write_text(json.dumps(s, indent=1))
    print(tag, json.dumps(s))


main()
