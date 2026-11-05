#!/usr/bin/env python3
"""Latency helpers over speaker_monitor.py output.

  latency.py first  ACTIVE T [TIMEOUT]   first speaker audio after epoch T (ms after T, or -1)
  latency.py quiet  ACTIVE T GAP         1 if no speaker audio in the last GAP s before now and after T
  latency.py stop   ACTIVE T [GAP]       last audio chunk after T before a >=GAP s silence (ms after T)
  latency.py speaking ACTIVE WINDOW      1 if speaker audio within the last WINDOW s
  latency.py active ACTIVE T0 T1         ms of speaker audio between epochs T0 and T1 (~10 ms chunks)
"""
import sys, time

def load(path):
    out = []
    with open(path) as f:
        for line in f:
            try:
                out.append(float(line.split()[0]))
            except (ValueError, IndexError):
                pass
    return out

cmd, path = sys.argv[1], sys.argv[2]
ts = load(path)
if cmd == "first":
    t0 = float(sys.argv[3]); timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 1e9
    xs = [t for t in ts if t0 < t < t0 + timeout]
    print(round((xs[0] - t0) * 1000) if xs else -1)
elif cmd == "quiet":
    t0 = float(sys.argv[3]); gap = float(sys.argv[4]); now = time.time()
    last = max([t for t in ts if t > t0], default=t0)
    print(1 if now - last >= gap else 0)
elif cmd == "speaking":
    w = float(sys.argv[3]); now = time.time()
    print(1 if any(now - w < t for t in ts) else 0)
elif cmd == "stop":
    t0 = float(sys.argv[3]); gap = float(sys.argv[4]) if len(sys.argv) > 4 else 1.5
    xs = [t for t in ts if t >= t0]
    prev = t0
    for t in xs:
        if t - prev >= gap:
            break
        prev = t
    print(round((prev - t0) * 1000))
elif cmd == "active":
    t0, t1 = float(sys.argv[3]), float(sys.argv[4])
    xs = sorted(t for t in ts if t0 < t <= t1)
    # chunk length from the spacing of consecutive chunks (gaps capped at 20 ms)
    print(round(sum(min(b - a, 0.02) for a, b in zip(xs, xs[1:])) * 1000) + (10 if xs else 0))

