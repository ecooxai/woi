import asyncio
from PIL import Image
from common import *
async def main():
    page = Image.open(BENCH / "page0.png").convert("RGB")
    for (w,h) in [(128,72),(256,144),(320,180),(480,270),(512,288),(256,256),(512,512),(1024,1024),(2048,1152),(405,900),(1200,400)]:
        img = page.resize((w,h), Image.BICUBIC)
        r = await realtime_trial("gpt-realtime-2.1", "Reply with the single word OK.", [],
                                 [image_item(png_bytes(img), None), text_item("Say OK")], want=(), modalities=("text",), timeout=30)
        print(w, h, r["image_tokens"], r["error"], flush=True)
asyncio.run(main())
