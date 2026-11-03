#!/usr/bin/env python3
"""Records a PulseAudio/PipeWire source (the monitor of the app's output sink)
and logs, with wall-clock timestamps, every 10 ms chunk that is not silent.

  speaker_monitor.py SOURCE OUT_PREFIX

Writes OUT_PREFIX.active (lines "epoch_seconds rms") and OUT_PREFIX.raw
(s16le mono 24 kHz).  Timestamps are taken when a chunk arrives, so they
include ~10-20 ms of capture latency.  Stdlib only.
"""
import array, math, signal, subprocess, sys, time

src, prefix = sys.argv[1], sys.argv[2]
RATE, CHUNK = 24000, 240  # 10 ms
THRESH = 300  # RMS on int16 scale (~-40 dBFS)
p = subprocess.Popen(
    ["parecord", f"--device={src}", "--raw", "--format=s16le", f"--rate={RATE}",
     "--channels=1", "--latency-msec=10"], stdout=subprocess.PIPE)
signal.signal(signal.SIGTERM, lambda *_: (p.terminate(), sys.exit(0)))
with open(prefix + ".active", "w", buffering=1) as act, open(prefix + ".raw", "wb") as raw:
    while True:
        b = p.stdout.read(CHUNK * 2)
        if not b:
            break
        t = time.time()
        raw.write(b)
        a = array.array("h", b)
        rms = math.sqrt(sum(x * x for x in a) / len(a)) if a else 0
        if rms > THRESH:
            act.write(f"{t:.3f} {rms:.0f}\n")
