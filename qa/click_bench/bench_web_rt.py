"""Stage A of the end-to-end web bench: gpt-realtime-2.1 sees the app-scaled
capture of the Chromium page on :11 and answers "Click <ask>" with
click_screen. --spec old: x/y-only tool + the instructions before the fix;
--spec target: the current app tool (target + x/y) and instructions.

  python bench_web_rt.py --spec target
"""
from __future__ import annotations

import argparse
import asyncio
import json
import re
import subprocess

from PIL import Image

from common import *

ap = argparse.ArgumentParser()
ap.add_argument("--spec", default="target")
ap.add_argument("--model", default="gpt-realtime-2.1")
ap.add_argument("--conc", type=int, default=3)
ap.add_argument("--shot", default=str(RESULTS / "web/shot_web.png"))
a = ap.parse_args()

layout = json.loads((RESULTS / "web/web_layout.json").read_text())
page = Image.open(a.shot).convert("RGB")
SW, SH = page.size
img = app_scale(page, 1280)

if a.spec == "old":
    src = subprocess.run(["git", "-C", str(REPO), "show", "f6c66be~1:app/lib/core/app_controller.dart"],
                         capture_output=True, text=True, check=True).stdout
    INSTR = re.search(r"const kAssistantInstructions = '''\n(.*?)''';", src, re.S).group(1)
    SPEC = CLICK_SPEC
else:
    INSTR = app_instructions()
    SPEC = {
        "type": "function", "name": "click_screen",
        "description": ("Click a UI element on screen. Always give target: the element's visible label in quotes, its kind and "
                        "where it is (e.g. \"'Save' button in the Profile dialog\", \"'Search' field in the toolbar\", "
                        "\"gear icon at the top right\"); Woi then finds it precisely. Also give x/y, your estimate in pixels "
                        "of the latest screenshot (a hint, and the click point if the target cannot be found)."),
        "parameters": {"type": "object", "properties": {
            "target": {"type": "string", "description": "What to click: quoted visible label + kind + location"},
            "x": {"type": "integer", "description": "X in screenshot pixels (estimate)"},
            "y": {"type": "integer", "description": "Y in screenshot pixels (estimate)"},
            "button": {"type": "string", "enum": ["left", "right", "middle"]},
            "double": {"type": "boolean", "description": "Double-click"}},
            "required": [], "additionalProperties": False},
    }
NOTE = (f"Screen when the user spoke. Image is {img.width}x{img.height} of a {SW}x{SH} screen; "
        "click_screen uses image pixel coordinates.")


async def main():
    sem = asyncio.Semaphore(a.conc)

    async def one(t):
        async with sem:
            res = await realtime_trial(a.model, INSTR, [SPEC], [image_item(png_bytes(img), NOTE), text_item(f"Click {t['ask']}.")])
            args = res["args"] or {}
            sx = sy = None
            if "x" in args and "y" in args:
                sx = min(max(round(args["x"] * SW / img.width), 0), SW - 1)
                sy = min(max(round(args["y"] * SH / img.height), 0), SH - 1)
            row = {"layout": "web", "id": t["id"], "ask": t["ask"], "args": res["args"], "sx": sx, "sy": sy,
                   "lat": res["lat"], "err_msg": res["error"], "small": min(t["w"], t["h"]) <= 24, **score(t, sx, sy)}
            print(f"{t['id']:14s} {'HIT ' if row['hit'] else 'miss'} err={row['err'] and round(row['err'])} "
                  f"args={args} lat={res['lat'] and round(res['lat'], 2)} {res['error'] or ''}", flush=True)
            return row

    return await asyncio.gather(*(one(t) for t in layout["targets"]))


rows = asyncio.run(main())
out = RESULTS / f"web_rt_{a.model}_{a.spec}"
out.mkdir(parents=True, exist_ok=True)
draw_marks(page, layout, rows, out / "marks.png")
s = summarize(rows)
(out / "rows.json").write_text(json.dumps(rows, indent=1))
(out / "summary.json").write_text(json.dumps(s, indent=1))
print(out.name, json.dumps(s))
