import asyncio, sys, json
from PIL import Image
from common import *

async def main():
    page = Image.open(BENCH / "page0.png").convert("RGB")
    res = []
    for w in (1280, 1600, 640):
        img = app_scale(page, w)
        for det in (None, "low", "high", "auto", "original"):
            if w != 1280 and det not in (None,):
                continue
            r = await realtime_trial("gpt-realtime-2.1", "Reply with the single word OK.", [], 
                                     [image_item(png_bytes(img), f"Image {img.width}x{img.height}", det), text_item("Say OK")],
                                     want=(), modalities=("text",), timeout=30)
            print(w, det, r["image_tokens"], r["error"], r["text"][:40], flush=True)
asyncio.run(main())
