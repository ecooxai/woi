"""Renders a non-ideal loudspeaker -> microphone echo path offline.

usage: python3 -I qa/aec/render_echo.py <fixtures-dir> <out-dir> [--seed N]
       [--delay-ms A,B] [--ppm P] [--echo-dbfs E] [--near-dbfs N] [--drive D] [--rt60 S]

Writes (24 kHz mono s16 WAV):
  far.wav     what Woi plays (the AEC reference = default-sink monitor)
  mic.wav     what the microphone hears: far.wav through a small laptop speaker
              (high-pass + soft clip + 2nd harmonic), a room (synthetic
              impulse response, RT60 ~0.35 s), a delay that jumps from A to B
              ms half way (buffer re-sizing / xrun), ~P ppm clock drift
              between speaker and mic, plus the near-end talker and noise
  near.wav    the near-end talker alone, placed on the mic timeline
  timeline.json  segments (far-only / near-only / double-talk / silence)

The echo is louder than the talker at the mic (laptop: speakers centimetres
from the mic, user half a metre away): echo -22 dBFS rms vs talker -30 dBFS by
default, the levels seen in the user's recordings (assistant clips about
-23 dBFS, the user's own speech after the canceller about -30 dBFS).
"""
import argparse
import json
import wave

import numpy as np

R = 24000


def load(path):
    with wave.open(path) as w:
        assert w.getframerate() == R and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768


def save(path, x):
    y = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(R)
        w.writeframes(y.tobytes())


def rms_db(x):
    return 10 * np.log10(max(float(np.mean(x * x)), 1e-12))


def active_rms_db(x, floor_db=-50):
    """RMS over the 20 ms frames that are within 30 dB of the loudest (speech level)."""
    k = R // 50
    m = len(x) // k
    e = np.mean(x[: m * k].reshape(m, k) ** 2, axis=1)
    on = e > max(e.max() * 1e-3, 10 ** (floor_db / 10))
    return 10 * np.log10(max(float(np.mean(e[on])), 1e-12))


def biquad_hp(x, fc, q=0.707):
    """2nd-order Butterworth high-pass (magnitude + phase), applied in the frequency domain."""
    nf = 1 << int(np.ceil(np.log2(len(x))))
    f = np.fft.rfftfreq(nf, 1 / R)
    s_ = 1j * f / fc
    h = s_ * s_ / (s_ * s_ + s_ / q + 1)
    return np.fft.irfft(np.fft.rfft(x, nf) * h, nf)[: len(x)]


def room_ir(rng, rt60, length_s=0.6):
    n = int(length_s * R)
    t = np.arange(n) / R
    decay = np.exp(-6.9 * t / rt60)  # -60 dB at rt60
    ir = rng.standard_normal(n) * decay * 0.18
    ir[:int(0.002 * R)] = 0  # nothing before the direct sound
    ir[0] = 1.0  # direct path
    for d_ms, g in [(3.1, 0.55), (5.7, -0.4), (8.9, 0.3), (13.4, 0.22), (19.0, -0.15)]:  # desk, screen, walls
        ir[int(d_ms * R / 1000)] += g
    # Air/wall absorption: soften the tail's highs (one-pole low-pass, applied twice).
    k = int(0.02 * R)
    for _ in range(2):
        tail = ir[k - 1:].copy()
        ir[k:] = 0.6 * tail[1:] + 0.4 * tail[:-1]
    return ir


def speaker(x, drive):
    """Small laptop speaker: no bass, soft clipping on peaks, some 2nd harmonic."""
    y = biquad_hp(x, 280)
    peak = np.max(np.abs(y)) + 1e-9
    z = y / peak
    z = np.tanh(drive * z) / np.tanh(drive) + 0.08 * (z * z - np.mean(z * z))
    return z * peak


def place(sig_len, items):
    out = np.zeros(sig_len)
    for start_s, x in items:
        a = int(start_s * R)
        out[a:a + len(x)] += x[: max(0, min(len(x), sig_len - a))]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fixtures")
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--delay-ms", default="140,260")
    ap.add_argument("--ppm", type=float, default=100)
    ap.add_argument("--echo-dbfs", type=float, default=-22)
    ap.add_argument("--near-dbfs", type=float, default=-30)
    ap.add_argument("--drive", type=float, default=2.2)
    ap.add_argument("--rt60", type=float, default=0.35)
    ap.add_argument("--scenario", choices=["stress", "turns"], default="stress",
                    help="stress: back-to-back speech; turns: replies separated by 3-6 s pauses "
                         "(the user talks in some of them), like a conversation")
    ap.add_argument("--jitter-ms", type=float, default=0,
                    help="random +-N ms delay steps every 2-6 s (xrun / resync)")
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    fx = lambda n: load(f"{a.fixtures}/{n}.wav")

    # Woi (far end): the fixtures are gpt-realtime TTS in Woi's voice.
    woi = ["02_click_center", "05_show_readme", "08_complex_task", "03_type_hello_world",
           "06_edit_notes", "09_play_video", "07_whats_on_screen", "02_click_center",
           "05_show_readme", "06_edit_notes"]
    # The user (near end): other fixtures, pitched down ~2 semitones (another voice).
    def user(n):
        x = fx(n)
        idx = np.arange(0, len(x) - 1, 0.89)
        return np.interp(idx, np.arange(len(x)), x)

    total = 64.0
    if a.scenario == "stress":
        # Timeline (s): far-only 1-20 (converge + measure) | double talk 20-34 (user at 22, 28)
        # | near-only 35-41 | far-only 42-63 with the delay jump at 52.
        far_items, t = [], 1.0
        for n in woi * 3:
            x = fx(n)
            if 34.5 < t + len(x) / R and t < 41.5:
                t = 42.0
            if t + len(x) / R > total - 1:
                continue
            far_items.append((t, x))
            t += len(x) / R + 0.35
        near_items = [(22.0, user("01_hello")), (28.0, user("10_stop")), (35.2, user("04_run_ls_home")),
                      (39.8, user("10_stop"))]
    else:
        # Conversation: Woi replies (2-7 s) separated by 3-6 s pauses; the user speaks in every
        # other pause and barges in once (at 0.8 s into a reply).
        far_items, near_items, t, k = [], [], 1.0, 0
        users = ["01_hello", "04_run_ls_home", "10_stop", "03_type_hello_world"]
        while True:
            x = fx(woi[k % len(woi)])
            if t + len(x) / R > total - 1:
                break
            far_items.append((t, x))
            if k == 4:
                near_items.append((t + 0.8, user("10_stop")))
            t += len(x) / R
            gap = float(rng.uniform(3, 6))
            if k % 2 == 1:
                near_items.append((t + 0.8, user(users[(k // 2) % len(users)])))
                gap = max(gap, len(near_items[-1][1]) / R + 1.6)
            t += gap
            k += 1
    n_total = int(total * R)
    far = place(n_total, far_items)
    far *= 10 ** ((-23 - active_rms_db(far)) / 20)  # Woi's clips: about -23 dBFS
    near = place(n_total, near_items)

    # Echo path.
    e = speaker(far, a.drive)
    ir = room_ir(rng, a.rt60)
    nf = 1 << int(np.ceil(np.log2(n_total + len(ir))))
    e = np.fft.irfft(np.fft.rfft(e, nf) * np.fft.rfft(ir, nf), nf)[:n_total]
    d0, d1 = (float(v) / 1000 for v in a.delay_ms.split(","))
    n = np.arange(n_total)
    jump = int(52.0 * R)
    delay = np.where(n < jump, d0, d1) * R
    jumps = []
    if a.jitter_ms:
        tj = float(rng.uniform(2, 6))
        while tj < total:
            step = float(rng.uniform(-a.jitter_ms, a.jitter_ms)) / 1000
            delay[int(tj * R):] += step * R
            jumps.append(round(tj, 2))
            tj += float(rng.uniform(2, 6))
        delay = np.maximum(delay, 0.01 * R)
    src = n * (1 - a.ppm * 1e-6) - delay  # mic clock runs fast by `ppm`
    echo = np.interp(src, n, e, left=0, right=0)
    echo *= 10 ** ((a.echo_dbfs - active_rms_db(echo)) / 20)
    near *= 10 ** ((a.near_dbfs - active_rms_db(near)) / 20)
    noise = rng.standard_normal(n_total)
    noise = np.convolve(noise, np.ones(8) / 8, mode="same")  # fan-like
    noise *= 10 ** ((-62 - rms_db(noise)) / 20)
    mic = echo + near + noise

    save(f"{a.out}/far.wav", far)
    save(f"{a.out}/mic.wav", mic)
    save(f"{a.out}/near.wav", near)
    save(f"{a.out}/echo.wav", echo)
    segs = {
        "far_items": [[s, s + len(x) / R] for s, x in far_items],
        "near_items": [[s, s + len(x) / R] for s, x in near_items],
        "scenario": a.scenario, "jitter_jumps_s": jumps,
        "delay_ms": [d0 * 1000, d1 * 1000], "delay_jump_s": 52.0, "ppm": a.ppm,
        "echo_dbfs": a.echo_dbfs, "near_dbfs": a.near_dbfs, "drive": a.drive, "rt60": a.rt60,
        "total_s": total,
    }
    with open(f"{a.out}/timeline.json", "w") as f:
        json.dump(segs, f, indent=1)
    print(f"far {active_rms_db(far):.1f} dBFS, echo at mic {active_rms_db(echo):.1f}, "
          f"near {active_rms_db(near):.1f}, noise {rms_db(noise):.1f} dBFS; delay {d0*1000:.0f}->{d1*1000:.0f} ms, "
          f"{a.ppm:.0f} ppm, rt60 {a.rt60} s")


if __name__ == "__main__":
    main()
