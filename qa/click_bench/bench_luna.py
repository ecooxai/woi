"""Responses-API grounding benchmark (gpt-6-luna) on the same pages.

  python bench_luna.py --variant base|native --layouts 0 1 2 [--limit N] [--effort low]
"""
from __future__ import annotations

import argparse
import json
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

from common import *

ap = argparse.ArgumentParser()
ap.add_argument("--variant", default="base")
ap.add_argument("--model", default="gpt-6-luna")
ap.add_argument("--layouts", type=int, nargs="+", default=[0, 1, 2])
ap.add_argument("--limit", type=int, default=0)
ap.add_argument("--every", type=int, default=1, help="use every Nth target")
ap.add_argument("--conc", type=int, default=3)
ap.add_argument("--effort", default=None)
ap.add_argument("--tag", default="")
a = ap.parse_args()
INSTR = app_instructions()
CLICK = {k: v for k, v in CLICK_SPEC.items()}


def job(li, t, img, sw, sh):
    note = (f"Screen when the user spoke. Image is {img.width}x{img.height} of a {sw}x{sh} screen; "
            "click_screen uses image pixel coordinates.")
    content = [{"type": "input_image", "image_url": data_url(png_bytes(img))},
               {"type": "input_text", "text": note},
               {"type": "input_text", "text": f"Click {t['ask']}."}]
    r = responses_call(a.model, INSTR, content, tools=[CLICK], reasoning=a.effort)
    args = next((c[1] for c in r.get("calls", []) if c[0] == "click_screen"), None)
    sx = sy = None
    if args and "x" in args:
        sx = min(max(round(args["x"] * sw / img.width), 0), sw - 1)
        sy = min(max(round(args["y"] * sh / img.height), 0), sh - 1)
    row = {"layout": li, "id": t["id"], "args": args, "sx": sx, "sy": sy, "lat": r.get("lat"),
           "err_msg": r.get("error"), "text": (r.get("text") or "")[:120], "small": min(t["w"], t["h"]) <= 24,
           "usage_in": (r.get("usage") or {}).get("input_tokens"), **score(t, sx, sy)}
    print(f"L{li} {t['id']:16s} {'HIT ' if row['hit'] else 'miss'} err={row['err'] and round(row['err'])} "
          f"args={args} lat={round(r['lat'], 2)} {r.get('error') or ''}", flush=True)
    return row


def main():
    jobs, pages = [], {}
    for li in a.layouts:
        layout = json.loads((BENCH / f"layout{li}.json").read_text())
        page = Image.open(BENCH / f"page{li}.png").convert("RGB")
        img = app_scale(page, 1280 if a.variant == "base" else 10 ** 6)
        pages[li] = (layout, page)
        for t in layout["targets"][:: a.every][: a.limit or None]:
            jobs.append((li, t, img, page.width, page.height))
    with ThreadPoolExecutor(a.conc) as ex:
        rows = list(ex.map(lambda j: job(*j), jobs))
    tag = f"resp_{a.model}_{a.variant}{'_' + a.effort if a.effort else ''}{a.tag}"
    out = RESULTS / tag
    out.mkdir(parents=True, exist_ok=True)
    for li, (layout, page) in pages.items():
        draw_marks(page, layout, [r for r in rows if r["layout"] == li], out / f"layout{li}.png")
    s = summarize(rows)
    (out / "rows.json").write_text(json.dumps(rows, indent=1))
    (out / "summary.json").write_text(json.dumps(s, indent=1))
    print(tag, json.dumps(s))


main()
