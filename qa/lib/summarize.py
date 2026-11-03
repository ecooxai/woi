#!/usr/bin/env python3
"""Prints the saved conversations of a QA app instance (XDG data dir) as a
compact transcript: role, time, text, image/audio markers, tool calls.

  summarize.py DATA_DIR
"""
import glob, json, os, sys

for f in sorted(glob.glob(os.path.join(sys.argv[1], "woi", "conversations", "*.json")), key=os.path.getmtime):
    c = json.load(open(f))
    print(f"## conversation {c.get('id')} title={c.get('title')!r} summary={'yes' if c.get('summary') else 'no'}")
    for m in c.get("messages", []):
        bits = [m.get("kind", "?"), (m.get("createdAt") or "")[11:19]]
        if "image" in m: bits.append("[img]")
        if "audio" in m: bits.append(f"[audio {m['audio'].get('ms')}ms]")
        if m.get("interrupted"): bits.append("[interrupted]")
        if m.get("compacted"): bits.append("[compacted]")
        t = m.get("tool")
        if t:
            res = (t.get("result") or "")[:160].replace("\n", " ")
            bits.append(f"TOOL {t.get('name')} {t.get('args','')[:160]} -> {t.get('status')} {res}")
        if m.get("text"): bits.append(repr(m["text"][:300]))
        if m.get("meta"): bits.append(f"meta={json.dumps(m['meta'])[:200]}")
        print("  " + " ".join(bits))
