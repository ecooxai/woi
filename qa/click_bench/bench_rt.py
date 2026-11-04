"""Realtime click-grounding benchmark.

  python bench_rt.py --variant base --layouts 0 1 2 [--limit N] [--conc 4]

Each trial: fresh realtime session with the app's instructions + tool schema,
a screenshot item (as the app sends it), then the user request as text.
The click_screen args are mapped to screen pixels like Screenshot.toScreen.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import time

from PIL import Image, ImageDraw

from common import *

ap = argparse.ArgumentParser()
ap.add_argument("--variant", default="base")
ap.add_argument("--model", default="gpt-realtime-2.1")
ap.add_argument("--layouts", type=int, nargs="+", default=[0, 1, 2])
ap.add_argument("--limit", type=int, default=0)
ap.add_argument("--conc", type=int, default=4)
ap.add_argument("--tag", default="")
a = ap.parse_args()

INSTR = app_instructions()


def app_note(iw, ih, sw, sh):
    return (f"Screen when the user spoke. Image is {iw}x{ih} of a {sw}x{sh} screen; "
            "click_screen uses image pixel coordinates.")


def grid_overlay(img: Image.Image, step: int) -> Image.Image:
    g = img.convert("RGB").copy()
    d = ImageDraw.Draw(g, "RGBA")
    f = font(10)
    for x in range(step, g.width, step):
        d.line([x, 0, x, g.height], fill=(255, 0, 180, 90), width=1)
        d.text((x + 2, 2), str(x), fill=(200, 0, 140, 255), font=f)
    for y in range(step, g.height, step):
        d.line([0, y, g.width, y], fill=(255, 0, 180, 90), width=1)
        d.text((2, y + 1), str(y), fill=(200, 0, 140, 255), font=f)
    return g


class Variant:
    """Builds the items for a trial and maps the returned args to screen px."""

    def __init__(self, name, page, layout):
        self.name, self.page, self.layout = name, page, layout
        self.sw, self.sh = page.size
        self.tools = [CLICK_SPEC, SHOT_SPEC]
        self.instr = INSTR
        self.want = ("click_screen",)
        self.items_extra = []
        n = name
        if n in ("base", "native", "img512", "grid", "note_scale", "detail_low", "base_text"):
            mw = {"native": 10 ** 6, "img512": int(round(self.sw * 512 / self.sh))}.get(n, 1280)
            img = app_scale(page, mw)
            if n == "grid":
                img = grid_overlay(img, 100)
            self.img = img
            note = app_note(img.width, img.height, self.sw, self.sh)
            if n == "note_scale":
                note = (f"Screen when the user spoke. This image is exactly {img.width} pixels wide and {img.height} "
                        f"pixels tall; (0,0) is its top-left corner. click_screen x/y are pixels of THIS image "
                        f"(x from 0 to {img.width - 1}, y from 0 to {img.height - 1}); the app converts them to the screen.")
            if n == "grid":
                note += (" A thin magenta grid is drawn every 100 image pixels, labelled with its x (top) and y (left)"
                         " pixel values; use it to read exact coordinates.")
            self.detail = "low" if n == "detail_low" else None
            self.note = note
            self.scale = (self.sw / img.width, self.sh / img.height)
        elif n in ("som_text", "som"):
            img = app_scale(page, 1280)
            self.scale = (self.sw / img.width, self.sh / img.height)
            self.els = elements(layout)
            if n == "som":
                img = img.copy()
                d = ImageDraw.Draw(img)
                f = font(10, True)
                for e in self.els:
                    x0, y0 = e["x"] / self.scale[0], e["y"] / self.scale[1]
                    d.rectangle([x0, y0, x0 + e["w"] / self.scale[0], y0 + e["h"] / self.scale[1]], outline="#ff00aa")
                    lbl = str(e["id"])
                    tw = d.textlength(lbl, font=f)
                    d.rectangle([x0, y0 - 11, x0 + tw + 3, y0], fill="#ff00aa")
                    d.text((x0 + 1.5, y0 - 11), lbl, fill="#fff", font=f)
            self.img = img
            lines = []
            for e in self.els:
                cx, cy = round((e["x"] + e["w"] / 2) / self.scale[0]), round((e["y"] + e["h"] / 2) / self.scale[1])
                lines.append(f"{e['id']}: {e['role']} '{e['name']}' at ({cx},{cy})")
            self.note = (app_note(img.width, img.height, self.sw, self.sh) +
                         (" Each listed element is outlined and labelled with its number in the image." if n == "som" else "") +
                         " Clickable elements from the accessibility tree (id: role 'name' at centre x,y in image pixels):\n"
                         + "\n".join(lines) + "\nTo click one of them, call click_screen with its element id.")
            self.detail = None
            spec = json.loads(json.dumps(CLICK_SPEC))
            spec["description"] = ("Click an element: pass `element` (id from the latest element list) when the target is listed, "
                                   "else x/y in the latest screenshot's pixels.")
            spec["parameters"]["properties"]["element"] = {"type": "integer", "description": "Element id from the list"}
            spec["parameters"]["required"] = []
            self.tools = [spec, SHOT_SPEC]
        else:
            raise SystemExit(f"unknown variant {n}")

    def items(self, ask):
        png = png_bytes(self.img)
        return [image_item(png, self.note, self.detail), *self.items_extra, text_item(ask)]

    def on_call(self, name, args, call_id):
        if name == "take_screenshot":
            return [{"type": "function_call_output", "call_id": call_id, "output": json.dumps(
                {"ok": True, "image": f"{self.img.width}x{self.img.height}", "screen": f"{self.sw}x{self.sh}"})},
                image_item(png_bytes(self.img), self.note.replace("Screen when the user spoke.", "Screenshot requested by tool"), self.detail)]
        return [{"type": "function_call_output", "call_id": call_id, "output": json.dumps({"ok": True})}]

    def to_screen(self, args):
        if "element" in args and getattr(self, "els", None):
            e = next((e for e in self.els if e["id"] == args["element"]), None)
            if e:
                return e["x"] + e["w"] / 2, e["y"] + e["h"] / 2
        try:
            x, y = float(args["x"]), float(args["y"])
        except Exception:
            return None, None
        sx = min(max(round(x * self.scale[0]), 0), self.sw - 1)
        sy = min(max(round(y * self.scale[1]), 0), self.sh - 1)
        return sx, sy


async def run_layout(li, sem):
    layout = json.loads((BENCH / f"layout{li}.json").read_text())
    page = Image.open(BENCH / f"page{li}.png").convert("RGB")
    v = Variant(a.variant, page, layout)
    targets = layout["targets"][: a.limit or None]

    async def one(t):
        async with sem:
            ask = f"Click {t['ask']}."
            r = await realtime_trial(a.model, v.instr, v.tools, v.items(ask), want=v.want, on_call=v.on_call)
            sx, sy = v.to_screen(r["args"]) if r["args"] else (None, None)
            row = {"layout": li, "id": t["id"], "ask": ask, "args": r["args"], "sx": sx, "sy": sy,
                   "lat": r["lat"], "calls": r["calls"], "err_msg": r["error"], "text": r["text"][:120],
                   "small": min(t["w"], t["h"]) <= 24, **score(t, sx, sy)}
            e = row["err"]
            print(f"L{li} {t['id']:16s} {'HIT ' if row['hit'] else 'miss'} err={e if e is None else round(e)} "
                  f"args={r['args']} lat={r['lat'] and round(r['lat'], 2)} {r['error'] or ''}", flush=True)
            return row

    rows = await asyncio.gather(*(one(t) for t in targets))
    return layout, page, rows


async def main():
    sem = asyncio.Semaphore(a.conc)
    res = await asyncio.gather(*(run_layout(li, sem) for li in a.layouts))
    tag = f"rt_{a.model}_{a.variant}{a.tag}"
    out = RESULTS / tag
    out.mkdir(parents=True, exist_ok=True)
    allrows = []
    for layout, page, rows in res:
        draw_marks(page, layout, rows, out / f"layout{layout['layout']}.png")
        allrows += rows
    s = summarize(allrows)
    (out / "rows.json").write_text(json.dumps(allrows, indent=1))
    (out / "summary.json").write_text(json.dumps(s, indent=1))
    print(tag, json.dumps(s))


asyncio.run(main())
