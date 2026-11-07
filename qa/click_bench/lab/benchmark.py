#!/usr/bin/env python3
"""Paired screenshot-only grounding benchmark for the WOI Click Lab.

Uses the lab's local API and a fresh, isolated Chromium profile. Ground-truth
button rectangles stay in this evaluator; the model endpoint receives only the
image, dimensions, current instruction, model and a unique request ID. Actual
browser mouse events verify each prediction. No desktop input is generated.

Run with the research Python (websockets dependency):
  ../woi/research/.venv/bin/python qa/click_bench/lab/benchmark.py --help
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import statistics
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

import websockets

HERE = Path(__file__).resolve().parent
DATE = "20261107"
WORDS = ("Aqua Birch Cove Dawn Elm Fern Gold Haze Iris Jade Kite Lake Mint Nova "
         "Opal Pine Quay Rose Sage Tide Vale Wave Yew Zinc Amber Coral Hazel Maple "
         "Olive Pearl River Stone").split()
REQUEST_KEYS = {"model", "instruction", "screenshot", "width", "height", "screen", "request_id"}
FATAL_CODES = {"unavailable", "unsupported", "authentication"}


def png_dimensions(raw: bytes) -> tuple[int, int]:
    if raw[:8] != b"\x89PNG\r\n\x1a\n" or len(raw) < 24:
        raise ValueError("Screenshot is not a PNG")
    return struct.unpack(">II", raw[16:24])


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def redact(value: str) -> str:
    value = re.sub(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+", "<redacted JWT>", value)
    return re.sub(r"\bsk-[A-Za-z0-9_-]{12,}\b", "<redacted key>", value)[:2000]


def error_category(error) -> str:
    s = json.dumps(error, ensure_ascii=False).lower() if not isinstance(error, str) else error.lower()
    if any(x in s for x in ("unauthorized", "authentication", "invalid_api_key", "expired token", "401", "missing credential", "no credential")):
        return "authentication"
    if any(x in s for x in ("rate_limit", "rate limit", "429", "quota", "too many requests")):
        return "rate_limited"
    if any(x in s for x in ("unsupported", "not support", "no image", "image input", "not compatible", "incompatible")):
        return "unsupported"
    if any(x in s for x in ("model_not_found", "not available", "not found", "does not exist", "access to", "permission", "403", "404", "unavailable")):
        return "unavailable"
    if any(x in s for x in ("timeout", "timed out", "deadline")):
        return "timeout"
    return "api_error"


def json_http(base: str, path: str, payload=None, timeout=150):
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    req = urllib.request.Request(base.rstrip("/") + path, data=data,
                                 headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read(8192).decode(errors="replace")
        try:
            obj = json.loads(body)
            if isinstance(obj, dict):
                obj.setdefault("error", {"code": f"http_{exc.code}", "message": redact(body)})
                return obj
        except ValueError:
            pass
        return {"error": {"code": f"http_{exc.code}", "message": redact(body)}}
    except Exception as exc:
        return {"error": {"code": type(exc).__name__, "message": redact(str(exc))}}


class CDP:
    """Minimal sequential Chrome DevTools client, avoiding extra dependencies."""
    def __init__(self, ws):
        self.ws, self.sequence = ws, 0

    @classmethod
    async def connect(cls, url):
        return cls(await websockets.connect(url, max_size=32 * 1024 * 1024, open_timeout=20))

    async def close(self):
        await self.ws.close()

    async def command(self, method, params=None):
        self.sequence += 1
        call_id = self.sequence
        await self.ws.send(json.dumps({"id": call_id, "method": method, "params": params or {}}))
        end = time.monotonic() + 35
        while True:
            event = json.loads(await asyncio.wait_for(self.ws.recv(), end - time.monotonic()))
            if event.get("id") != call_id:
                continue
            if event.get("error"):
                raise RuntimeError(f"{method}: {event['error']}")
            return event.get("result", {})

    async def evaluate(self, expression):
        result = await self.command("Runtime.evaluate", {
            "expression": expression, "returnByValue": True, "awaitPromise": True,
        })
        if result.get("exceptionDetails"):
            raise RuntimeError(str(result["exceptionDetails"]))
        return result.get("result", {}).get("value")


class Browser:
    def __init__(self, directory: Path):
        self.directory = directory
        self.proc = None
        self.cdp = None
        self.tmp = None
        self.log = None

    async def __aenter__(self):
        executable = os.environ.get("WOI_CHROMIUM") or next((shutil.which(n) for n in ("chromium", "chromium-browser", "google-chrome") if shutil.which(n)), None)
        if not executable:
            raise RuntimeError("Chromium executable not found")
        self.directory.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="woi-click-lab-")
        self.log = (self.directory / "chromium.log").open("w")
        self.proc = subprocess.Popen([
            executable, "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
            "--no-first-run", "--no-default-browser-check", "--hide-scrollbars",
            "--disable-background-networking", "--disable-component-update", "--disable-sync",
            "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
            f"--user-data-dir={self.tmp.name}", "about:blank",
        ], stdout=self.log, stderr=self.log)
        active = Path(self.tmp.name) / "DevToolsActivePort"
        for _ in range(200):
            if active.exists():
                break
            if self.proc.poll() is not None:
                raise RuntimeError(f"Chromium exited {self.proc.returncode}; see {self.directory / 'chromium.log'}")
            await asyncio.sleep(0.1)
        if not active.exists():
            raise RuntimeError("Chromium did not expose its debugging port")
        port = active.read_text().splitlines()[0]
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list") as response:
            targets = json.load(response)
        page = next(t for t in targets if t.get("type") == "page")
        self.cdp = await CDP.connect(page["webSocketDebuggerUrl"])
        await self.cdp.command("Page.enable")
        return self

    async def __aexit__(self, *exc):
        if self.cdp:
            await self.cdp.close()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=6)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
        if self.log:
            self.log.close()
        if self.tmp:
            self.tmp.cleanup()


def layout(seed: int, width: int, height: int):
    rng = random.Random(seed)
    labels = rng.sample(WORDS, 16)
    out = []
    cell_w, cell_h = (width - 48) / 4, (height - 104) / 4
    for i, word in enumerate(labels):
        col, row = i % 4, i // 4
        size = (i + seed) % 3
        w, h = [(72, 26), (112, 42), (156, 58)][size]
        # Place several targets at the extent of the screen; jitter the rest.
        x = 24 + col * cell_w + rng.uniform(4, max(5, cell_w - w - 8))
        y = 76 + row * cell_h + rng.uniform(4, max(5, cell_h - h - 8))
        if i == 0:
            x, y = 12, 72
        elif i == 15:
            x, y = width - w - 12, height - h - 12
        out.append({"id": f"b{i}", "label": f"{word} {rng.randrange(10, 100)}", "x": round(x, 2), "y": round(y, 2), "w": w, "h": h,
                    "size": ("small", "normal", "large")[size], "color": i % 5})
    return out


def board_html(case):
    config = {"identity": f"{case["seed"]}:{case["css_width"]}:{case["css_height"]}", "width": case["css_width"], "height": case["css_height"], "buttons": case["buttons"]}
    return '''<!doctype html><meta charset="utf-8"><title>WOI paired click benchmark</title>
<style>*{box-sizing:border-box}html,body{margin:0;overflow:hidden;font-family:Arial,sans-serif}body{background:#f3f6fa}h1{position:absolute;left:24px;top:15px;margin:0;font-size:22px;color:#182437;font-weight:600}p{position:absolute;left:24px;top:39px;margin:0;font-size:12px;color:#67748a}button{position:absolute;border:1px solid #abb9cd;border-radius:6px;color:#192a40;font-family:Arial,sans-serif;font-size:12px;white-space:nowrap;cursor:default;outline:none;padding:0;box-shadow:0 1px 2px #18344a12}button:focus{outline:none}</style>
<h1>Click accuracy lab</h1><p>Randomized button board</p><main id="board"></main>
<script>const config=''' + json.dumps(config, separators=(",", ":")) + ''';
const colors=['#d9ecff','#e4f2dc','#ffe8d1','#eae2ff','#ffe2e8'];
for(const b of config.buttons){let e=document.createElement('button');e.id=b.id;e.dataset.target=b.id;e.textContent=b.label;Object.assign(e.style,{left:b.x+'px',top:b.y+'px',width:b.w+'px',height:b.h+'px',background:colors[b.color]});document.querySelector('#board').appendChild(e)}
window.labIdentity=config.identity;window.labEvents=[];for(const type of ['mousemove','mousedown','mouseup','click'])document.addEventListener(type,e=>window.labEvents.push({type,x:e.clientX,y:e.clientY,target:e.target.closest('[data-target]')?.dataset.target||null,isTrusted:e.isTrusted}),true);
window.labBoxes=()=>Array.from(document.querySelectorAll('[data-target]'),e=>{const r=e.getBoundingClientRect();return {id:e.id,label:e.textContent,x:r.x,y:r.y,w:r.width,h:r.height}});
window.labReady=document.fonts.ready.then(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
</script>'''


def make_cases(count=12, offset=0):
    cases = []
    variants = [(1280, 720, 1), (960, 720, 1), (1280, 720, 2)]
    indices = [0, 5, 10, 15, 1, 6, 11, 12, 2, 7, 8, 13]
    for index in range(offset, offset + count):
        width, height, dpr = variants[(index // 4) % len(variants)]
        seed = 8731 + index // 4
        buttons = layout(seed, width, height)
        chosen = buttons[indices[index % len(indices)]]
        action = "click" if index % 2 == 0 else "move"
        instruction = (f'Click the button labeled "{chosen["label"]}".' if action == "click" else
                       f'Move the pointer to the button labeled "{chosen["label"]}". Do not click.')
        cases.append({"case_id": f"case-{index:03d}", "seed": seed, "css_width": width, "css_height": height,
                      "device_pixel_ratio": dpr, "buttons": buttons, "target_id": chosen["id"],
                      "target_label": chosen["label"], "target_size": chosen["size"],
                      "instruction": instruction, "expected_action": action})
    return cases


async def show_case(cdp, case):
    await cdp.command("Emulation.setDeviceMetricsOverride", {
        "width": case["css_width"], "height": case["css_height"], "deviceScaleFactor": case["device_pixel_ratio"],
        "mobile": False, "screenWidth": case["css_width"], "screenHeight": case["css_height"],
    })
    html = base64.b64encode(board_html(case).encode()).decode()
    await cdp.command("Page.navigate", {"url": "data:text/html;base64," + html})
    # Navigation may acknowledge before the new document commits.
    identity = f"{case['seed']}:{case['css_width']}:{case['css_height']}"
    for _ in range(100):
        try:
            ready = await cdp.evaluate("window.labIdentity === " + json.dumps(identity))
        except RuntimeError:
            ready = False
        if ready:
            break
        await asyncio.sleep(0.02)
    else:
        raise AssertionError("Requested board document did not load")
    await cdp.evaluate("window.labReady.then(()=>true)")
    await cdp.command("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": 1, "y": 1})
    await cdp.evaluate("window.labEvents=[]; true")
    return await cdp.evaluate("({boxes:window.labBoxes(),width:innerWidth,height:innerHeight,dpr:devicePixelRatio})")


async def capture_cases(cdp, cases, directory):
    directory.mkdir(parents=True, exist_ok=True)
    for case in cases:
        geometry = await show_case(cdp, case)
        shot = await cdp.command("Page.captureScreenshot", {"format": "png", "fromSurface": True, "captureBeyondViewport": False})
        raw = base64.b64decode(shot["data"])
        width, height = png_dimensions(raw)
        if width != round(case["css_width"] * case["device_pixel_ratio"]) or height != round(case["css_height"] * case["device_pixel_ratio"]):
            raise AssertionError(f"DPR screenshot geometry mismatch for {case['case_id']}: {width}x{height}")
        case.update({"width": width, "height": height, "boxes": geometry["boxes"],
                     "screenshot_sha256": hashlib.sha256(raw).hexdigest(),
                     "screenshot_path": str(directory / (case["case_id"] + ".png"))})
        Path(case["screenshot_path"]).write_bytes(raw)
        (directory / (case["case_id"] + ".json")).write_text(json.dumps(case, indent=2) + "\n")
    return cases


def make_ui_cases(count=30, offset=12, ui_url="http://127.0.0.1:8766"):
    """Cases rendered by the shipping ClickLab UI, not an alternate fixture."""
    variants = [(1280, 480, 1440, 1100, 1), (960, 720, 1200, 1100, 1), (2560, 1440, 1440, 1100, 2)]
    cases = []
    for index in range(offset, offset + count):
        width, height, vw, vh, dpr = variants[(index // 4) % len(variants)]
        cases.append({"case_id": f"ui-case-{index:03d}", "fixture": "interactive-lab", "ui_url": ui_url,
                      "seed": 12017 + index // 4, "capture_width": width, "capture_height": height,
                      "viewport_width": vw, "viewport_height": vh, "device_pixel_ratio": dpr,
                      "button_count": 12, "target_index": (index * 5 + index // 4) % 12,
                      "expected_action": "click" if index % 2 == 0 else "move"})
    return cases


async def show_ui_case(cdp, case):
    await cdp.command("Emulation.setDeviceMetricsOverride", {
        "width": case["viewport_width"], "height": case["viewport_height"],
        "deviceScaleFactor": case["device_pixel_ratio"], "mobile": False,
        "screenWidth": case["viewport_width"], "screenHeight": case["viewport_height"],
    })
    loaded = await cdp.evaluate("typeof window.ClickLab !== 'undefined'")
    if not loaded:
        await cdp.command("Page.navigate", {"url": case["ui_url"].rstrip("/") + "/?seed=" + str(case["seed"])})
        for _ in range(150):
            try:
                loaded = await cdp.evaluate("typeof window.ClickLab !== 'undefined'")
            except RuntimeError:
                loaded = False
            if loaded:
                break
            await asyncio.sleep(0.1)
        else:
            raise AssertionError("Interactive ClickLab did not initialize")
        await cdp.evaluate(r'''(()=>{
          window.__qaTrustedEvents=[];
          for(const type of ['mousemove','mousedown','mouseup','click'])document.addEventListener(type,e=>{
            __qaTrustedEvents.push({type,x:e.clientX,y:e.clientY,target:e.target.closest('[data-target]')?.dataset.target||null,isTrusted:e.isTrusted});
          },true);return true;
        })()''')
    options = {"seed": case["seed"], "width": case["capture_width"], "height": case["capture_height"], "count": case["button_count"]}
    await cdp.evaluate("ClickLab.setLayout(" + json.dumps(options) + ")")
    await cdp.evaluate("document.fonts.ready.then(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))))")
    await cdp.evaluate("document.getElementById('board-frame').scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});true")
    await cdp.command("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": 1, "y": 1})
    await cdp.evaluate("window.__qaTrustedEvents=[];ClickLab.clearEvents();true")
    return await cdp.evaluate(r'''(()=>{
      const capture=ClickLab.capture(),layout=ClickLab.getLayout();
      const rect=document.getElementById('board').getBoundingClientRect();
      const boxes=Array.from(document.querySelectorAll('#hit-layer [data-target]'),e=>{
        const r=e.getBoundingClientRect();return {id:e.dataset.target,label:e.getAttribute('aria-label'),x:r.x-rect.x,y:r.y-rect.y,w:r.width,h:r.height};
      });
      return {capture,layout,boxes,rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}};
    })()''')


async def capture_ui_cases(cdp, cases, directory):
    directory.mkdir(parents=True, exist_ok=True)
    for case in cases:
        geometry = await show_ui_case(cdp, case)
        capture, targets = geometry["capture"], geometry["layout"]["targets"]
        selected = targets[case["target_index"]]
        raw = base64.b64decode(capture["screenshot"].split(",", 1)[1])
        width, height = png_dimensions(raw)
        if (width, height) != (case["capture_width"], case["capture_height"]):
            raise AssertionError("Interactive canvas capture has unexpected native dimensions")
        instruction = (f'Click the button labeled "{selected["label"]}".' if case["expected_action"] == "click" else
                       f'Move the pointer to the button labeled "{selected["label"]}". Do not click.')
        case.update({"width": width, "height": height, "css_width": geometry["rect"]["width"],
                     "css_height": geometry["rect"]["height"], "boxes": geometry["boxes"],
                     "native_targets": targets, "target_id": selected["id"], "target_label": selected["label"],
                     "target_size": selected["size"], "instruction": instruction, "screen_metadata": capture["screen"],
                     "screenshot_sha256": hashlib.sha256(raw).hexdigest(),
                     "screenshot_path": str(directory / (case["case_id"] + ".png"))})
        Path(case["screenshot_path"]).write_bytes(raw)
        (directory / (case["case_id"] + ".json")).write_text(json.dumps(case, indent=2) + "\n")
    return cases


def request_payload(case, model, request_id=None):
    raw = Path(case["screenshot_path"]).read_bytes()
    if hashlib.sha256(raw).hexdigest() != case["screenshot_sha256"]:
        raise AssertionError("Screenshot bytes changed since capture")
    return {"model": model, "instruction": case["instruction"],
            "screenshot": "data:image/png;base64," + base64.b64encode(raw).decode(),
            "width": case["width"], "height": case["height"],
            "screen": case.get("screen_metadata") or {"width": case["css_width"], "height": case["css_height"], "devicePixelRatio": case["device_pixel_ratio"]},
            "request_id": request_id or str(uuid.uuid4())}


def prediction_status(response, case):
    if response.get("error"):
        code = response.get("error_code")
        categories = {"invalid_output": "malformed", "invalid_coordinates": "malformed", "out_of_bounds": "out_of_bounds",
                      "authentication_error": "authentication", "auth_missing": "authentication",
                      "access_denied": "unavailable", "model_unavailable": "unavailable", "unknown_model": "unavailable",
                      "unsupported_capability": "unsupported", "image_unsupported": "unsupported", "rate_limit": "rate_limited"}
        return categories.get(code) or error_category(response["error"])
    if response.get("action") not in ("click", "move"):
        return "malformed"
    if not finite_number(response.get("x")) or not finite_number(response.get("y")):
        return "malformed"
    if not (0 <= response["x"] < case["width"] and 0 <= response["y"] < case["height"]):
        return "out_of_bounds"
    return "prediction"


def score_prediction(case, response, events):
    status = prediction_status(response, case)
    if status != "prediction":
        return {"status": status, "hit": False, "coordinate_hit": False, "action_correct": False,
                "center_error_px": None, "events": []}
    scale_x, scale_y = case["width"] / case["css_width"], case["height"] / case["css_height"]
    x, y = response["x"] / scale_x, response["y"] / scale_y
    target = next(b for b in case["boxes"] if b["id"] == case["target_id"])
    coord_hit = target["x"] <= x < target["x"] + target["w"] and target["y"] <= y < target["y"] + target["h"]
    error = math.hypot(response["x"] - (target["x"] + target["w"] / 2) * scale_x,
                       response["y"] - (target["y"] + target["h"] / 2) * scale_y)
    action_correct = response["action"] == case["expected_action"]
    clicks = [e for e in events if e["type"] == "click"]
    moves = [e for e in events if e["type"] == "mousemove"]
    if response["action"] == "click":
        actual_hit = len(clicks) == 1 and clicks[0]["target"] == case["target_id"]
    else:
        actual_hit = bool(moves) and moves[-1]["target"] == case["target_id"] and not clicks
    trusted = all(e.get("isTrusted") for e in events)
    return {"status": "hit" if coord_hit and actual_hit and action_correct and trusted else "miss",
            "hit": bool(coord_hit and actual_hit and action_correct and trusted), "coordinate_hit": coord_hit,
            "action_correct": action_correct, "center_error_px": round(error, 3),
            "actual_event_hit": actual_hit, "trusted_events": trusted, "events": events,
            "css_x": x, "css_y": y}


async def execute_prediction(cdp, case, response):
    status = prediction_status(response, case)
    if status != "prediction":
        return score_prediction(case, response, [])
    interactive = case.get("fixture") == "interactive-lab"
    geometry = await (show_ui_case(cdp, case) if interactive else show_case(cdp, case))
    if geometry["boxes"] != case["boxes"]:
        raise AssertionError("Replayed layout differs from screenshot geometry")
    if interactive and geometry["layout"]["targets"] != case["native_targets"]:
        raise AssertionError("Interactive target layout changed since capture")
    x = response["x"] * case["css_width"] / case["width"]
    y = response["y"] * case["css_height"] / case["height"]
    if interactive:
        x += geometry["rect"]["x"]
        y += geometry["rect"]["y"]
    await cdp.command("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y})
    if response["action"] == "click":
        await cdp.command("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": 1})
        await cdp.command("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": 1})
    events = await cdp.evaluate("window.__qaTrustedEvents" if interactive else "window.labEvents")
    return score_prediction(case, response, events)


async def oracle_check(cdp, cases):
    rows = []
    for case in cases:
        b = next(b for b in case["boxes"] if b["id"] == case["target_id"])
        response = {"action": case["expected_action"], "x": (b["x"] + b["w"] / 2) * case["width"] / case["css_width"],
                    "y": (b["y"] + b["h"] / 2) * case["height"] / case["css_height"]}
        score = await execute_prediction(cdp, case, response)
        rows.append({"case_id": case["case_id"], "dpr": case["device_pixel_ratio"], **score})
        if not score["hit"]:
            raise AssertionError(f"Oracle action missed: {rows[-1]}")
    return rows


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    at = (len(values) - 1) * fraction
    lo, hi = math.floor(at), math.ceil(at)
    return round(values[lo] + (values[hi] - values[lo]) * (at - lo), 3)


def summarize(rows):
    groups = {}
    for row in rows:
        groups.setdefault(row["model"], []).append(row)
    out = []
    for model, items in groups.items():
        valid = [r for r in items if r["status"] in ("hit", "miss")]
        hits = sum(r["hit"] for r in items)
        errors = {}
        for row in items:
            if row["status"] not in ("hit", "miss"):
                errors[row["status"]] = errors.get(row["status"], 0) + 1
        latency = [r["latency_ms"] for r in items if finite_number(r.get("latency_ms"))]
        distances = [r["center_error_px"] for r in valid if finite_number(r.get("center_error_px"))]
        wall_times = [r["wall_time_ms"] for r in items if finite_number(r.get("wall_time_ms"))]
        resolution_groups = {}
        size_groups = {}
        for row in items:
            response = row.get("response", {})
            resolution = f"{response.get('width', '?')}x{response.get('height', '?')}"
            group = resolution_groups.setdefault(resolution, {"trials": 0, "hits": 0, "errors": 0})
            group["trials"] += 1
            group["hits"] += bool(row["hit"])
            group["errors"] += row["status"] not in ("hit", "miss")
            size = size_groups.setdefault(row.get("target_size", "unknown"), {"trials": 0, "hits": 0, "errors": 0})
            size["trials"] += 1
            size["hits"] += bool(row["hit"])
            size["errors"] += row["status"] not in ("hit", "miss")
        n = len(valid)
        if n:
            p, z = hits / n, 1.95996398454
            center = (p + z*z/(2*n)) / (1 + z*z/n)
            half = z*math.sqrt(p*(1-p)/n+z*z/(4*n*n)) / (1+z*z/n)
            ci = [round(center-half, 4), round(center+half, 4)]
        else:
            ci = None
        out.append({"model": model, "kind": items[0].get("kind"), "trials": len(items), "valid_predictions": n,
                    "hits": hits, "operational_hit_rate": round(hits/len(items), 4),
                    "accuracy_given_prediction": round(hits/n, 4) if n else None, "accuracy_wilson_95": ci,
                    "click_hits": sum(r["hit"] for r in items if r["expected_action"] == "click"),
                    "click_trials": sum(r["expected_action"] == "click" for r in items),
                    "move_hits": sum(r["hit"] for r in items if r["expected_action"] == "move"),
                    "move_trials": sum(r["expected_action"] == "move" for r in items),
                    "median_error_px": statistics.median(distances) if distances else None,
                    "error_p90_px": percentile(distances, 0.9),
                    "latency_median_ms": statistics.median(latency) if latency else None,
                    "latency_p90_ms": percentile(latency, 0.9),
                    "wall_time_median_ms": statistics.median(wall_times) if wall_times else None,
                    "wall_time_p90_ms": percentile(wall_times, 0.9),
                    "by_capture_resolution": resolution_groups, "by_target_size": size_groups, "errors": errors})
    return sorted(out, key=lambda r: (-r["operational_hit_rate"], r["latency_median_ms"] or float("inf")))


async def trial(base, model, case):
    payload = request_payload(case, model["id"])
    assert set(payload) == REQUEST_KEYS
    start = time.monotonic()
    result = await asyncio.to_thread(json_http, base, "/api/trial", payload)
    if not isinstance(result, dict):
        result = {"error": {"code": "malformed", "message": "Non-object API response"}}
    return {"model": model["id"], "kind": model.get("kind"), "case_id": case["case_id"],
            "expected_action": case["expected_action"], "target_size": case["target_size"],
            "screenshot_sha256": case["screenshot_sha256"], "request_id": payload["request_id"],
            "request_keys": sorted(payload), "latency_ms": result.get("latency_ms", round((time.monotonic()-start)*1000, 2)),
            "wall_time_ms": round((time.monotonic()-start)*1000, 2), "response": result}


async def run(args):
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    catalog = await asyncio.to_thread(json_http, args.url, "/api/models")
    (out / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")
    if catalog.get("error"):
        raise RuntimeError(f"Model catalog unavailable: {catalog['error']}")
    inventory = catalog.get("models", [])
    print(json.dumps({"catalog_count": len(inventory), "models": [{k: m.get(k) for k in ("id", "kind", "available", "reason")} for m in inventory]}, ensure_ascii=False), flush=True)
    if args.catalog_only:
        return
    if args.models:
        ids = args.models.split(",")
        by_id = {m["id"]: m for m in inventory}
        models = [by_id.get(model, {"id": model, "kind": "unknown", "available": True}) for model in ids]
    else:
        models = [m for m in inventory if m.get("available") is not False]
    if len(models) > 50 and not args.allow_large_catalog:
        raise RuntimeError(f"Catalog has {len(models)} available candidates; select distinct aliases explicitly before a broad run")
    phase = out / args.phase
    phase.mkdir(parents=True, exist_ok=True)
    rows = []
    result_file = phase / "rows.jsonl"
    existing = {}
    if args.resume and result_file.exists():
        for line in result_file.read_text().splitlines():
            row = json.loads(line)
            rows.append(row)
            existing[(row["model"], row["case_id"])] = row
    elif result_file.exists():
        raise RuntimeError(f"Refusing to overwrite {result_file}; use --resume or another phase")
    async with Browser(phase) as browser:
        if args.fixture == "interactive":
            cases = make_ui_cases(args.count, args.offset, args.ui_url or args.url)
            await capture_ui_cases(browser.cdp, cases, phase / "cases")
        else:
            cases = make_cases(args.count, args.offset)
            await capture_cases(browser.cdp, cases, phase / "cases")
        by_case = {case["case_id"]: case for case in cases}
        if args.match_cases:
            for case in cases:
                prior = json.loads((Path(args.match_cases) / (case["case_id"] + ".json")).read_text())
                for key in ("screenshot_sha256", "instruction", "target_id", "width", "height", "seed"):
                    if case[key] != prior[key]:
                        raise AssertionError(f"Matched-case mismatch for {case['case_id']}: {key}")
        for row in rows:
            if row["case_id"] in by_case and row["screenshot_sha256"] != by_case[row["case_id"]]["screenshot_sha256"]:
                raise AssertionError("Resumed screenshot differs from the recorded paired trial")
        oracle = await oracle_check(browser.cdp, cases)
        (phase / "oracle.json").write_text(json.dumps({"passed": len(oracle), "total": len(oracle), "cases": oracle}, indent=2) + "\n")
        print(f"ORACLE {len(oracle)}/{len(oracle)} (real trusted Chromium events, DPR 1/2, click and move)", flush=True)
        if args.oracle_only:
            return
        for model in models:
            if model.get("available") is False:
                print(f"SKIP {model['id']}: {model.get('reason')}", flush=True)
                continue
            pending = [c for c in cases if (model["id"], c["case_id"]) not in existing]
            fatal = next((r for r in rows if r["model"] == model["id"] and r["status"] in FATAL_CODES), None)
            if fatal:
                print(f"SKIP {model['id']} remaining trials: prior {fatal['status']}", flush=True)
                continue
            # A first probe avoids repeating a known endpoint/auth incompatibility.
            batches = [pending[:1]] + [pending[i:i+args.concurrency] for i in range(1, len(pending), args.concurrency)] if pending else []
            for batch in batches:
                results = await asyncio.gather(*(trial(args.url, model, case) for case in batch))
                for case, row in zip(batch, results):
                    if args.expect_protocol and row["response"].get("protocol") != args.expect_protocol:
                        raise AssertionError(f"Provider protocol mismatch: expected {args.expect_protocol}, got {row['response'].get('protocol')}")
                    if args.expect_text_detail and model.get("kind") == "text" and row["response"].get("image_detail") != args.expect_text_detail:
                        raise AssertionError(f"Image detail mismatch: expected {args.expect_text_detail}, got {row['response'].get('image_detail')}")
                    score = await execute_prediction(browser.cdp, case, row["response"])
                    row.update(score)
                    rows.append(row)
                    with result_file.open("a") as stream:
                        stream.write(json.dumps(row, separators=(",", ":")) + "\n")
                    summary = summarize(rows)
                    (phase / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
                    print(f"{model['id']} {case['case_id']} {case['expected_action']} {row['status']} error_px={row.get('center_error_px')} latency_ms={row['latency_ms']}", flush=True)
                    if row["status"] in FATAL_CODES:
                        fatal = row
                if fatal:
                    break
    metadata = {"generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "phase": args.phase, "fixture": args.fixture, "trials_per_model_requested": args.count, "case_offset": args.offset,
                "model_ids": [m["id"] for m in models], "request_fields": sorted(REQUEST_KEYS),
                "expected_protocol": args.expect_protocol, "expected_text_image_detail": args.expect_text_detail,
                "observed_protocols": sorted({str(row["response"].get("protocol")) for row in rows}),
                "observed_prompt_hashes": sorted({str(row["response"].get("prompt_sha256")) for row in rows}),
                "matched_case_reference": args.match_cases,
                "reported_model_alias_changes": [{"requested": row["model"], "reported": row["response"].get("resolved_model"), "case_id": row["case_id"]} for row in rows if row["response"].get("resolved_model") and row["response"]["resolved_model"] != row["model"]],
                "observed_image_details": sorted({str(row["response"].get("image_detail", "high (v1 baseline)")) for row in rows}),
                "fresh_request": True, "history_included": False, "ground_truth_sent_to_model": False,
                "execution": "Chromium CDP real trusted pointer events in isolated synthetic page; no OS input",
                "input_mode": "Text instruction plus screenshot for every model, including audio models",
                "scoring": "Correct action and actual event inside target; out-of-range predictions rejected, never clamped",
                "summary": summarize(rows)}
    (phase / "report.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata["summary"], indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8766")
    parser.add_argument("--fixture", choices=["standardized", "interactive"], default="standardized")
    parser.add_argument("--ui-url", help="Shipping ClickLab UI origin for interactive fixture; defaults to --url")
    parser.add_argument("--out", default=str(HERE / "results" / DATE))
    parser.add_argument("--phase", default="screening")
    parser.add_argument("--expect-protocol", help="Abort if a response comes from another protocol version")
    parser.add_argument("--expect-text-detail", help="Abort if text-model response reports another image detail policy")
    parser.add_argument("--count", type=int, default=12)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--models", help="Comma-separated exact model IDs, default all available catalog candidates")
    parser.add_argument("--match-cases", help="Prior case directory; require identical PNG hashes and instructions before any model calls")
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--catalog-only", action="store_true")
    parser.add_argument("--oracle-only", action="store_true")
    parser.add_argument("--allow-large-catalog", action="store_true")
    args = parser.parse_args()
    if args.count < 1 or not 1 <= args.concurrency <= 4:
        parser.error("count must be positive; concurrency must be between 1 and 4")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
