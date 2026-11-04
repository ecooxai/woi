"""Echo attenuation / near-end preservation of qa/aec/measure.sh recordings.

usage: python3 -I qa/aec/analyze.py <out-dir>
       (raw.raw, aec.raw: 24 kHz s16 mono; t0.txt: bytes each file held at T0;
        sig/near.wav: the near-end talker)

The virtual devices drop/insert ~10-20 ms now and then under load, so all
metrics are level based (100 ms frames), never sample-exact waveform fits.
"""
import sys
import wave

import numpy as np

R = 24000
out = sys.argv[1]
t0 = dict(line.split() for line in open(f"{out}/t0.txt"))


def load(name):
    x = np.fromfile(f"{out}/{name}.raw", dtype="<i2").astype(np.float64) / 32768
    return x[int(t0[name]) // 2:]  # timeline 0 = T0


raw, aec = load("raw"), load("aec")
with wave.open(f"{out}/sig/near.wav") as w:
    near = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768


def seg(x, a, b):
    return x[int(a * R):int(b * R)]


def db(p):
    return 10 * np.log10(max(p, 1e-12))


def power(x):
    return float(np.mean(x * x)) if len(x) else 0.0


def env(x, k=2400):
    m = len(x) // k
    return np.mean(x[: m * k].reshape(m, k) ** 2, axis=1)


def locate(x, a, b):
    """Time (s) where near.wav starts in x between a and b (envelope correlation)."""
    k = 240
    e, r = np.sqrt(env(seg(x, a, b), k)), np.sqrt(env(near, k))
    cc = np.correlate(e - e.mean(), r - r.mean(), mode="valid")
    return a + int(np.argmax(cc)) * k / R


voiced = env(near) > 10 ** (-40 / 10)  # 100 ms frames of near.wav with speech


def near_level(x, start):
    """Mean power (dBFS) of x over the frames where near.wav (placed at start) is voiced."""
    e = env(seg(x, start, start + len(near) / R + 0.1))[: len(voiced)]
    v = voiced[: len(e)]
    return db(float(np.mean(e[v]))) if v.any() else -120.0


print("== Woi PipeWire echo cancellation (virtual devices, 24 kHz) ==")
for name, a, b in [("music, first 2 s", 2.1, 4), ("music, 4-14 s", 4, 13.9), ("far-end speech", 15.2, 33)]:
    pr, pa = power(seg(raw, a, b)), power(seg(aec, a, b))
    fr, fa = db(env(seg(raw, a, b)).max()), db(env(seg(aec, a, b)).max())
    print(f"{name:18s} raw {db(pr):6.1f} dBFS  aec {db(pa):6.1f} dBFS  attenuation {db(pr) - db(pa):5.1f} dB"
          f"  (loudest 100 ms: raw {fr:6.1f}, aec {fa:6.1f} dBFS, {fr - fa:5.1f} dB)")

s_raw, s_aec = locate(raw, 33.5, 42), locate(aec, 33.5, 42)
n_raw, n_aec = near_level(raw, s_raw), near_level(aec, s_aec)
print(f"near-end alone     raw {n_raw:6.1f} dBFS  aec {n_aec:6.1f} dBFS  change {n_aec - n_raw:+5.1f} dB"
      f"  (aec latency {1000 * (s_aec - s_raw):+.0f} ms)")

d_raw, d_aec = locate(raw, 44.3, 53), locate(aec, 44.3, 53)
res_aec = db(power(seg(aec, 42.6, 44.8)))  # music only, before the talker
res_raw = db(power(seg(raw, 42.6, 44.8)))
dt_aec = near_level(aec, d_aec)
print(f"double talk        music alone: raw {res_raw:6.1f}, aec {res_aec:6.1f} dBFS;"
      f" talker over music in aec {dt_aec:6.1f} dBFS")
print(f"                   near-end level vs talking alone: {dt_aec - n_aec:+5.1f} dB;"
      f" talker-to-echo ratio raw {n_raw - res_raw:+5.1f} dB -> aec {dt_aec - res_aec:+5.1f} dB")
print(f"silence (tail)     raw {db(power(seg(raw, 55, 56.5))):6.1f} dBFS  aec {db(power(seg(aec, 55, 56.5))):6.1f} dBFS")
