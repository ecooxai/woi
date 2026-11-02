#!/usr/bin/env python3
"""Probe the text Responses API through the ChatGPT/Codex login (same auth as Codex CLI).

  POST https://chatgpt.com/backend-api/codex/responses   (stream=true, store=false; SSE)

Examples:
  probe_responses.py                                   # gpt-6-luna + gpt-6.1-sol, text
  probe_responses.py --model gpt-6.1-sol --text "Write a haiku"
  probe_responses.py --image fixtures/test_screen.png
  probe_responses.py --matrix                          # instructions required? store? stream? image? tools?

Tokens are never printed; x-codex-turn-state is dropped from the logged headers.
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import httpx  # noqa: E402

import codex_auth as ca  # noqa: E402

URL = f"{ca.CHATGPT_BASE}/responses"
SAFE_HEADER_PREFIXES = ("x-codex-plan", "x-codex-primary", "x-codex-secondary", "openai-model", "x-request-id")


def image_part(path: str | Path) -> dict:
    p = Path(path)
    mime = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}[p.suffix.lower()]
    return {"type": "input_image", "image_url": f"data:{mime};base64,{base64.b64encode(p.read_bytes()).decode()}"}


def build_body(model, instructions, user_text, image=None, tools=None, stream=True, store=False, reasoning=None):
    content = []
    if image:
        content.append(image_part(image))
    content.append({"type": "input_text", "text": user_text})
    body = {"model": model, "input": [{"type": "message", "role": "user", "content": content}],
            "stream": stream, "store": store}
    if instructions is not None:
        body["instructions"] = instructions
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    if reasoning:
        body["reasoning"] = reasoning
    return body


def call_responses(auth, model="gpt-6-luna", instructions="You are a helpful assistant.", user_text="Hello",
                   image=None, tools=None, stream=True, store=False, reasoning=None, quiet=False, raw_body=None) -> dict:
    """Run one request. Returns {status, text, function_calls, usage, ttft_s, total_s, headers, error, events}."""
    body = raw_body or build_body(model, instructions, user_text, image, tools, stream, store, reasoning)
    hdrs = dict(ca.chatgpt_headers(auth), **{"Content-Type": "application/json", "Accept": "text/event-stream"})
    res = {"model": body.get("model"), "status": None, "text": "", "function_calls": [], "usage": None,
           "ttft_s": None, "total_s": None, "headers": {}, "error": None, "events": []}
    t0 = time.perf_counter()
    with httpx.Client(timeout=180) as c, c.stream("POST", URL, headers=hdrs, json=body) as r:
        res["status"] = r.status_code
        res["headers"] = {k: v for k, v in r.headers.items() if k.lower().startswith(SAFE_HEADER_PREFIXES)}
        if r.status_code != 200:
            res["error"] = ca.redact(r.read().decode(errors="replace")[:800])
            res["total_s"] = time.perf_counter() - t0
            return res
        # NB: the server streams SSE but sends no Content-Type header - don't gate on it.
        for line in r.iter_lines():
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            ev = json.loads(data)
            t = ev.get("type", "")
            if t not in res["events"]:
                res["events"].append(t)
            if t == "response.output_text.delta":
                if res["ttft_s"] is None:
                    res["ttft_s"] = time.perf_counter() - t0
                res["text"] += ev["delta"]
                if not quiet:
                    print(ev["delta"], end="", flush=True)
            elif t == "response.output_item.done" and ev["item"].get("type") == "function_call":
                it = ev["item"]
                if res["ttft_s"] is None:
                    res["ttft_s"] = time.perf_counter() - t0
                res["function_calls"].append({"name": it["name"], "arguments": it["arguments"], "call_id": it["call_id"]})
            elif t in ("response.completed", "response.incomplete", "response.failed"):
                resp = ev["response"]
                res["usage"] = resp.get("usage")
                res["final_status"] = resp.get("status")
                if resp.get("error"):
                    res["error"] = resp["error"]
            elif t == "error":
                res["error"] = ev
    res["total_s"] = time.perf_counter() - t0
    if not quiet and res["text"]:
        print()
    return res


def show(label, res):
    s = {k: v for k, v in res.items() if k not in ("events",)}
    if isinstance(s.get("usage"), dict):
        s["usage"] = {k: v for k, v in s["usage"].items() if k != "attribution"}  # per-item breakdown, verbose
    s["text"] = (s["text"][:300] + "...") if len(s["text"]) > 300 else s["text"]
    for k in ("ttft_s", "total_s"):
        if s.get(k) is not None:
            s[k] = round(s[k], 3)
    print(f"--- {label}")
    print(ca.redact(json.dumps(s, indent=2)))
    print(f"    events: {res['events']}")


CLICK_TOOL = {"type": "function", "name": "click_screen", "description": "Click at screen pixel x,y (1920x1080).",
              "parameters": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
                             "required": ["x", "y"], "additionalProperties": False}}


def matrix(auth, image):
    cases = [
        ("luna: text", dict(model="gpt-6-luna", user_text="Reply with exactly: pong")),
        ("luna: NO instructions field", dict(model="gpt-6-luna", instructions=None, user_text="Reply with exactly: pong")),
        ("luna: empty instructions", dict(model="gpt-6-luna", instructions="", user_text="Reply with exactly: pong")),
        ("luna: store=true", dict(model="gpt-6-luna", store=True, user_text="Reply with exactly: pong")),
        ("luna: stream=false", dict(model="gpt-6-luna", stream=False, user_text="Reply with exactly: pong")),
        ("luna: image", dict(model="gpt-6-luna", image=image,
                             user_text="Describe this image precisely in one sentence: shapes, colors, positions.")),
        ("luna: tool click_screen", dict(model="gpt-6-luna", tools=[CLICK_TOOL],
                                         user_text="Click on the center of the screen")),
        ("luna: compression task", dict(model="gpt-6-luna",
                                        instructions="Compress the conversation into a terse summary that preserves facts.",
                                        user_text="User: open README.md. Assistant: opened. User: add a line 'buy milk' to "
                                                  "notes.txt. Assistant: done. User: what's the weather? Assistant: I can't check.")),
        ("sol: text", dict(model="gpt-6.1-sol", user_text="Reply with exactly: pong")),
        ("sol: image", dict(model="gpt-6.1-sol", image=image,
                            user_text="Describe this image precisely in one sentence: shapes, colors, positions.")),
        ("sol: reasoning effort high", dict(model="gpt-6.1-sol", reasoning={"effort": "high"},
                                            user_text="What is 17*23? Answer with the number only.")),
        ("bogus model", dict(model="gpt-nope", user_text="hi")),
    ]
    out = {}
    for label, kw in cases:
        r = call_responses(auth, quiet=True, **kw)
        show(label, r)
        out[label] = {k: r.get(k) for k in ("status", "text", "function_calls", "usage", "ttft_s", "error", "final_status")}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", action="append", help="default: gpt-6-luna and gpt-6.1-sol")
    ap.add_argument("--text", default="In one sentence: what is a realtime voice API?")
    ap.add_argument("--instructions", default="You are a helpful assistant.")
    ap.add_argument("--no-instructions", action="store_true", help="omit the instructions field entirely")
    ap.add_argument("--image")
    ap.add_argument("--tool", action="store_true", help="register click_screen")
    ap.add_argument("--matrix", action="store_true")
    a = ap.parse_args()
    auth = ca.load_auth()
    if a.matrix:
        matrix(auth, a.image or str(HERE / "fixtures" / "test_screen.png"))
        return
    for m in a.model or ["gpt-6-luna", "gpt-6.1-sol"]:
        print(f"=== {m}")
        r = call_responses(auth, model=m, instructions=None if a.no_instructions else a.instructions, user_text=a.text,
                           image=a.image, tools=[CLICK_TOOL] if a.tool else None)
        show(m, r)


if __name__ == "__main__":
    main()
