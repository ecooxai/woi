"""Canceller latency from pw_latency.sh recordings (FL raw mic, FR canceller
output, same graph cycle). The near-end bursts (100 ms, f0 200 Hz, one per
second) are located by matched filtering in each channel: the lag between a
burst in the mic and in the canceller output is the canceller's latency, the
level ratio how much of the near-end it kept (double talk when far is on)."""
import os
import sys
import wave

import numpy as np

R = 48000
L = 4800
t = np.arange(L)
TEMPLATE = sum(np.sin(2 * np.pi * 200 * k * t / R) / k for k in range(1, 16)) * np.sin(np.pi * t / L)


def load(p):
    with wave.open(p) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)
    return x[0::2], x[1::2]


def matched(x):
    return np.correlate(x, TEMPLATE, mode="valid") / np.dot(TEMPLATE, TEMPLATE)


for p in sys.argv[1:]:
    mic, aec = load(p)
    mm, ma = matched(mic), matched(aec)
    lags, kept, onset = [], [], []
    # Bursts: matched-filter peaks above half the maximum, >= 0.5 s apart.
    peaks, k = [], 0
    hi = 0.5 * mm.max()
    while k < len(mm):
        if mm[k] > hi:
            pm = k + int(np.argmax(mm[k:k + L]))
            peaks.append(pm)
            k = pm + R // 2
        else:
            k += 1
    for pm in peaks:
        seg = ma[pm:pm + R * 4 // 10]
        if len(seg) < R * 4 // 10:
            break
        pa = pm + int(np.argmax(seg))
        lags.append(round((pa - pm) / 48, 1))
        kept.append(round(float(20 * np.log10((abs(ma[pa]) + 1e-3) / (abs(mm[pm]) + 1e-3))), 1))
        # first 50 ms of the burst: how much of the onset survives
        on_m = np.sqrt(np.mean(mic[pm:pm + 2400] ** 2)) + 1e-3
        on_a = np.sqrt(np.mean(aec[pa:pa + 2400] ** 2)) + 1e-3
        onset.append(round(float(20 * np.log10(on_a / on_m)), 1))
    med = sorted(lags)[len(lags) // 2] if lags else "n/a"
    print(f"{os.path.basename(p)[4:-4]:>12}: canceller latency ms median {med} {lags}; near-end burst kept dB {kept}; first 50 ms kept dB {onset}")
