"""Click-grounding benchmark helpers (realtime WS + Responses API via the Codex login).

Never prints tokens. CODEX_HOME is read-only here (no refresh is ever persisted).
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import math
import os
import re
import time
import urllib.request
from pathlib import Path

import websockets
from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parents[2]
# Rendered pages + layouts (targets.py --render-only) and results live outside the repo by default.
BENCH = Path(os.environ.get("WOI_BENCH_PAGES", str(Path(__file__).resolve().parent / "pages")))
RESULTS = Path(os.environ.get("WOI_BENCH_RESULTS", os.path.join(os.environ.get("TMPDIR", "/tmp"), "click_bench_results")))
RESULTS.mkdir(parents=True, exist_ok=True)
AUTH_PATH = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "auth.json"
REALTIME_WS = "wss://api.openai.com/v1/realtime"
RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses"
FORBIDDEN = ("gpt-live", "gpt-6.1-sol")

_auth = None


def auth() -> dict:
    global _auth
    if _auth is None:
        _auth = json.loads(AUTH_PATH.read_text())
    return _auth


def headers() -> dict:
    t = auth()["tokens"]
    return {
        "Authorization": f"Bearer {t['access_token']}",
        "chatgpt-account-id": t["account_id"],
        "originator": "codex_cli_rs",
        "version": "0.166.0",
        "User-Agent": "codex_cli_rs/0.166.0 (Linux; x86_64) woi-click-bench",
    }


def redact(s: str) -> str:
    t = auth()["tokens"]
    for k in ("access_token", "refresh_token", "id_token", "account_id"):
        if t.get(k):
            s = s.replace(t[k], "<redacted>")
    return re.sub(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+", "<jwt>", s)


def check_model(m: str):
    if any(f in m for f in FORBIDDEN):
        raise SystemExit(f"model {m} is not allowed")


def app_instructions() -> str:
    src = (REPO / "app/lib/core/app_controller.dart").read_text()
    m = re.search(r"const kAssistantInstructions = '''\n(.*?)''';", src, re.S)
    return m.group(1)


# ---------------------------------------------------------------- images

def png_bytes(img: Image.Image) -> bytes:
    b = io.BytesIO()
    img.save(b, "PNG", compress_level=1)
    return b.getvalue()


def app_scale(img: Image.Image, max_w: int) -> Image.Image:
    """Same geometry as the app's ffmpeg filter scale='min(W,iw)':-2 (bicubic)."""
    if img.width <= max_w:
        return img.copy()
    w = max_w
    h = int(round(img.height * w / img.width / 2.0)) * 2
    return img.resize((w, h), Image.BICUBIC)


def font(sz: int, bold=False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    return ImageFont.truetype("/usr/share/fonts/TTF/" + name, sz)


# ---------------------------------------------------------------- scoring

def score(t: dict, sx: float | None, sy: float | None) -> dict:
    if sx is None:
        return {"hit": False, "err": None}
    cx, cy = t["x"] + t["w"] / 2, t["y"] + t["h"] / 2
    hit = t["x"] <= sx <= t["x"] + t["w"] and t["y"] <= sy <= t["y"] + t["h"]
    return {"hit": hit, "err": math.hypot(sx - cx, sy - cy)}


def summarize(rows: list[dict]) -> dict:
    n = len(rows)
    hits = sum(1 for r in rows if r.get("hit"))
    errs = sorted(r["err"] for r in rows if r.get("err") is not None)
    lats = sorted(r["lat"] for r in rows if r.get("lat") is not None)
    med = lambda a: a[len(a) // 2] if a else None
    small = [r for r in rows if r.get("small")]
    return {
        "n": n,
        "hit": hits / n if n else 0,
        "hit_small": (sum(1 for r in small if r.get("hit")) / len(small)) if small else None,
        "med_err": med(errs),
        "med_lat": med(lats),
        "no_click": sum(1 for r in rows if r.get("err") is None),
    }


def draw_marks(page: Image.Image, layout: dict, rows: list[dict], out: Path):
    img = page.convert("RGB").copy()
    d = ImageDraw.Draw(img)
    f = font(11)
    by = {t["id"]: t for t in layout["targets"]}
    for r in rows:
        t = by[r["id"]]
        cx, cy = t["x"] + t["w"] / 2, t["y"] + t["h"] / 2
        d.rectangle([t["x"], t["y"], t["x"] + t["w"], t["y"] + t["h"]], outline="#00a000", width=2)
        if r.get("sx") is None:
            d.text((t["x"], t["y"] - 12), f"{t['id']}: no click", fill="#c00000", font=f)
            continue
        col = "#00a000" if r["hit"] else "#e00000"
        d.line([cx, cy, r["sx"], r["sy"]], fill=col, width=1)
        x, y = r["sx"], r["sy"]
        d.line([x - 6, y, x + 6, y], fill=col, width=2)
        d.line([x, y - 6, x, y + 6], fill=col, width=2)
        if not r["hit"]:
            d.text((x + 6, y + 2), t["id"], fill=col, font=f)
    img.save(out)


# ---------------------------------------------------------------- realtime

CLICK_SPEC = {
    "type": "function",
    "name": "click_screen",
    "description": "Click at a position given in the coordinates of the latest screenshot.",
    "parameters": {
        "type": "object",
        "properties": {
            "x": {"type": "integer", "description": "X in screenshot pixels"},
            "y": {"type": "integer", "description": "Y in screenshot pixels"},
            "button": {"type": "string", "enum": ["left", "right", "middle"]},
            "double": {"type": "boolean", "description": "Double-click"},
        },
        "required": ["x", "y"],
        "additionalProperties": False,
    },
}
SHOT_SPEC = {
    "type": "function",
    "name": "take_screenshot",
    "description": "Capture the whole screen. The image is attached to the conversation. "
    "Coordinates for click_screen refer to this image.",
    "parameters": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
}


def image_item(png: bytes, note: str | None, detail: str | None = None) -> dict:
    part = {"type": "input_image", "image_url": "data:image/png;base64," + base64.b64encode(png).decode()}
    if detail:
        part["detail"] = detail
    content = [part]
    if note:
        content.append({"type": "input_text", "text": note})
    return {"type": "message", "role": "user", "content": content}


def text_item(text: str) -> dict:
    return {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}


async def realtime_trial(*args, **kw) -> dict:
    for attempt in range(4):
        r = await _realtime_trial(*args, **kw)
        e = r.get("error") or ""
        if "handshake" in e or "ConnectionClosed" in e or "rate_limit" in e or "server_error" in e:
            await asyncio.sleep(2 + 3 * attempt)
            continue
        return r
    return r


async def _realtime_trial(model: str, instructions: str, tools: list, items: list[dict], *,
                         want=("click_screen",), on_call=None, timeout=40, modalities=("audio",)) -> dict:
    """Opens a session, adds [items], asks for a response and returns the
    first call whose name is in [want] (args), latency from response.create,
    image tokens and transcript. [on_call](name, args) -> list of items to add
    (tool output etc.) for other calls; the trial then continues."""
    check_model(model)
    out = {"call": None, "args": None, "lat": None, "image_tokens": None, "calls": [], "text": "", "error": None}
    try:
        async with websockets.connect(f"{REALTIME_WS}?model={model}", additional_headers=headers(),
                                      max_size=None, open_timeout=20) as ws:
            async def send(ev):
                await ws.send(json.dumps(ev))

            async def recv_until(pred, tmo):
                end = time.monotonic() + tmo
                while True:
                    left = end - time.monotonic()
                    if left <= 0:
                        raise TimeoutError("timeout")
                    ev = json.loads(await asyncio.wait_for(ws.recv(), left))
                    if ev["type"] == "error":
                        raise RuntimeError(redact(json.dumps(ev["error"]))[:300])
                    if pred(ev):
                        return ev

            await recv_until(lambda e: e["type"] == "session.created", 15)
            await send({"type": "session.update", "session": {
                "type": "realtime", "instructions": instructions, "output_modalities": list(modalities),
                "tools": tools, "tool_choice": "auto",
            }})
            await recv_until(lambda e: e["type"] == "session.updated", 15)
            for it in items:
                await send({"type": "conversation.item.create", "item": it})
            t0 = time.monotonic()
            await send({"type": "response.create"})
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                ev = await recv_until(lambda e: e["type"] in (
                    "response.function_call_arguments.done", "response.done",
                    "response.output_audio_transcript.done", "response.output_text.done"), end - time.monotonic())
                ty = ev["type"]
                if ty == "response.function_call_arguments.done":
                    name = ev.get("name")
                    try:
                        args = json.loads(ev.get("arguments") or "{}")
                    except Exception:
                        args = {}
                    out["calls"].append([name, args, round(time.monotonic() - t0, 3)])
                    if name in want:
                        out.update(call=name, args=args, lat=time.monotonic() - t0)
                        await send({"type": "response.cancel"})
                        return out
                    if on_call:
                        for it in on_call(name, args, ev.get('call_id')):
                            await send({"type": "conversation.item.create", "item": it})
                        continue
                elif ty in ("response.output_audio_transcript.done", "response.output_text.done"):
                    out["text"] += (ev.get("transcript") or ev.get("text") or "") + " "
                elif ty == "response.done":
                    r = ev["response"]
                    u = (r.get("usage") or {}).get("input_token_details") or {}
                    out["image_tokens"] = u.get("image_tokens")
                    calls = [o for o in r.get("output", []) if o.get("type") == "function_call"]
                    pending = [o for o in calls if o.get("name") not in want]
                    if pending and on_call:
                        await send({"type": "response.create"})
                        continue
                    return out
    except Exception as e:  # noqa
        out["error"] = redact(f"{type(e).__name__}: {e}")[:300]
    return out


# ---------------------------------------------------------------- responses (luna)

def responses_call(model: str, instructions: str, content: list, tools: list | None = None,
                   reasoning: str | None = None, timeout=90) -> dict:
    check_model(model)
    body = {"model": model, "instructions": instructions,
            "input": [{"type": "message", "role": "user", "content": content}],
            "stream": True, "store": False}
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    if reasoning:
        body["reasoning"] = {"effort": reasoning}
    h = dict(headers(), **{"Content-Type": "application/json", "Accept": "text/event-stream"})
    req = urllib.request.Request(RESPONSES_URL, data=json.dumps(body).encode(), headers=h, method="POST")
    t0 = time.monotonic()
    text, calls, usage = "", [], None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if not data or data == "[DONE]":
                    continue
                ev = json.loads(data)
                ty = ev.get("type")
                if ty == "response.output_text.delta":
                    text += ev.get("delta", "")
                elif ty == "response.output_item.done" and ev["item"].get("type") == "function_call":
                    it = ev["item"]
                    calls.append((it["name"], json.loads(it.get("arguments") or "{}")))
                elif ty == "response.completed":
                    usage = ev["response"].get("usage")
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {redact(e.read().decode()[:300])}", "lat": time.monotonic() - t0}
    except Exception as e:  # noqa
        return {"error": redact(f"{type(e).__name__}: {e}")[:300], "lat": time.monotonic() - t0}
    return {"text": text, "calls": calls, "usage": usage, "lat": time.monotonic() - t0}


def data_url(png: bytes) -> str:
    return "data:image/png;base64," + base64.b64encode(png).decode()


# ---------------------------------------------------------------- oracle accessibility tree

_NAMES = {"close": "Close", "maximize": "Maximize", "minimize": "Minimize", "menu": "Menu", "back": "Back",
          "forward": "Forward", "reload": "Reload", "star": "Bookmark", "settings": "Settings", "music": "Music",
          "more": "More options", "help": "Help", "wifi": "", "search": "Search", "name": "Name", "email": "Email",
          "remember": "Remember me", "newsletter": "Send newsletter", "save": "Save", "cancel": "Cancel",
          "delete": "Delete account", "upgrade": "Upgrade to Pro", "download": "Download", "share": "Share",
          "export": "Export as PDF"}
_ROLES = {"icon": "push button", "button": "push button", "field": "entry", "row": "list item",
          "checkbox": "check box", "link": "link"}


def elements(layout: dict) -> list[dict]:
    """What an accessibility tree would expose: targets + distractors, shuffled ids."""
    import random
    ts = {t["id"]: t for t in layout["targets"]}
    out = []
    for t in layout["targets"]:
        tid = t["id"]
        name = _NAMES.get(tid) or (tid[6:].capitalize() if tid.startswith("folder_") else tid[4:] if tid.startswith("page") else "")
        out.append({"tid": tid, "role": _ROLES[t["kind"]], "name": name, "x": t["x"], "y": t["y"], "w": t["w"], "h": t["h"]})
    p3, p5 = ts["page3"], ts["page5"]
    step = (p5["x"] - p3["x"]) / 2
    for n in (1, 2, 4, 6, 7):
        out.append({"tid": f"page{n}", "role": "push button", "name": str(n), "x": round(p3["x"] + (n - 3) * step),
                    "y": p3["y"], "w": p3["w"], "h": p3["h"]})
    d, a_ = ts["folder_drafts"], ts["folder_archive"]
    rh = (a_["y"] - d["y"]) / 2
    for i, f in ((-1, "Inbox"), (1, "Sent"), (3, "Spam")):
        out.append({"tid": "folder_" + f.lower(), "role": "list item", "name": f, "x": d["x"], "y": round(d["y"] + i * rh),
                    "w": d["w"], "h": d["h"]})
    random.Random(7 + layout["layout"]).shuffle(out)
    for i, e in enumerate(out, 1):
        e["id"] = i
    return out
