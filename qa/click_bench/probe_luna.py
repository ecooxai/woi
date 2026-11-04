from PIL import Image
from common import *
page = Image.open(BENCH / "page0.png").convert("RGB")
for w, det in ((1280, None), (1280, "high"), (1600, "original"), (1600, None), (640, None)):
    img = app_scale(page, w)
    part = {"type": "input_image", "image_url": data_url(png_bytes(img))}
    if det: part["detail"] = det
    r = responses_call("gpt-6-luna", "Reply OK.", [part, {"type": "input_text", "text": "Say OK"}])
    print(w, det, r.get("error"), (r.get("usage") or {}).get("input_tokens"), round(r["lat"],2), r.get("text","")[:20])
