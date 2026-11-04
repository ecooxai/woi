"""Measures echo attenuation of a canceller run on the render_echo.py rig.

usage: python3 -I qa/aec/erle.py <rig-dir> <processed.wav|.f32> [--rate 48000] [--label X]

<rig-dir> holds far/mic/near/echo.wav + timeline.json from render_echo.py.
The processed file is the canceller output aligned with mic.wav (same start).
Prints per-segment ERLE (echo-only input energy / output energy), residual
level, near-end loss, and a server-VAD proxy: 20 ms frames above -45 dBFS for
>= 200 ms are a "speech start" (roughly what threshold 0.5 server VAD reacts
to); during far-only stretches each one is a false user turn.
"""
import argparse
import json
import wave

import numpy as np

R = 24000


def load_wav(path):
    with wave.open(path) as w:
        r = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768
    return x, r


def resample(x, r_from, r_to):
    if r_from == r_to:
        return x
    n = int(round(len(x) * r_to / r_from))
    X = np.fft.rfft(x)
    m = n // 2 + 1
    Y = np.zeros(m, dtype=complex)
    k = min(m, len(X))
    Y[:k] = X[:k]
    return np.fft.irfft(Y, n) * (n / len(x))


def load_any(path, rate):
    if path.endswith(".f32"):
        return resample(np.fromfile(path, dtype="<f4").astype(np.float64), rate, R)
    x, r = load_wav(path)
    return resample(x, r, R)


def frames(x, ms=20):
    k = R * ms // 1000
    m = len(x) // k
    return np.mean(x[: m * k].reshape(m, k) ** 2, axis=1)


def db(e):
    return 10 * np.log10(max(float(e), 1e-12))


def vad_onsets(x, start_s, end_s, thr_db=-45, min_ms=200, hang_ms=500):
    """Speech starts like a threshold VAD with prefix/silence handling."""
    e = frames(x)
    a, b = int(start_s * 50), int(end_s * 50)
    on = e[a:b] > 10 ** (thr_db / 10)
    starts, run, quiet, speaking = [], 0, 0, False
    for i, v in enumerate(on):
        if not speaking:
            run = run + 1 if v else 0
            if run * 20 >= min_ms:
                speaking, quiet = True, 0
                starts.append(start_s + (i - run + 1) * 0.02)
        else:
            quiet = 0 if v else quiet + 1
            if quiet * 20 >= hang_ms:
                speaking, run = False, 0
    return starts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rig")
    ap.add_argument("processed")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--label", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--save-wav", default="", help="also write the processed signal as 24 kHz s16 WAV")
    a = ap.parse_args()
    tl = json.load(open(f"{a.rig}/timeline.json"))
    mic, _ = load_wav(f"{a.rig}/mic.wav")
    echo, _ = load_wav(f"{a.rig}/echo.wav")
    near, _ = load_wav(f"{a.rig}/near.wav")
    out = load_any(a.processed, a.rate)
    if a.save_wav:
        with wave.open(a.save_wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(R)
            w.writeframes(np.clip(np.round(out * 32767), -32768, 32767).astype("<i2").tobytes())
    n = min(len(mic), len(out))
    mic, echo, near, out = mic[:n], echo[:n], near[:n], out[:n]

    ee, eo, en = frames(echo), frames(out), frames(near)
    far_on = np.zeros(len(ee), bool)
    for s, t in tl["far_items"]:
        far_on[int(s * 50):int(t * 50) + 25] = True  # + 0.5 s echo tail/delay
    near_on = np.zeros(len(ee), bool)
    for s, t in tl["near_items"]:
        near_on[int(s * 50):int(t * 50)] = True
    echo_act = ee > ee.max() * 1e-4

    def erle_idx(idx):
        idx = idx[(idx < len(ee))]
        idx = idx[echo_act[idx] & ~near_on[idx]]
        if len(idx) == 0:
            return float("nan"), float("nan")
        return db(np.mean(ee[idx])) - db(np.mean(eo[idx])), db(np.mean(eo[idx]))

    def erle(s, t):
        return erle_idx(np.arange(int(s * 50), int(t * 50)))

    res = {"label": a.label, "segments": {}}
    print(f"== {a.label or a.processed}")
    if tl.get("scenario", "stress") == "stress":
        segs = [("converge 1-5s", 1, 5), ("far-only 5-20s", 5, 20), ("double-talk 20-34s", 20, 34),
                ("far-only 42-52s", 42, 52), ("after delay jump 52-56s", 52, 56), ("far-only 56-63s", 56, 63)]
    else:
        segs = []
    for name, s, t in segs:
        g, lvl = erle(s, t)
        res["segments"][name] = {"erle_db": round(g, 1), "residual_dbfs": round(lvl, 1)}
        print(f"  {name:26s} ERLE {g:5.1f} dB  residual {lvl:6.1f} dBFS")
    # Per reply: the first 1.5 s (where the user's recordings show the leaks) vs the rest.
    starts = np.concatenate([np.arange(int(s * 50), int(min(s + 1.5, t) * 50)) for s, t in tl["far_items"]])
    bodies = np.concatenate([np.arange(int((s + 1.5) * 50), int((t + 0.3) * 50)) for s, t in tl["far_items"]
                             if t > s + 1.5])
    gs, ls = erle_idx(starts)
    gb, lb = erle_idx(bodies)
    worst = max((erle_idx(np.arange(int(s * 50), int((s + 1.5) * 50)))[1], s) for s, _ in tl["far_items"])
    print(f"  reply starts (first 1.5 s) ERLE {gs:5.1f} dB  residual {ls:6.1f} dBFS (worst {worst[0]:.1f} at {worst[1]:.1f}s)")
    print(f"  reply bodies               ERLE {gb:5.1f} dB  residual {lb:6.1f} dBFS")
    res.update(reply_start_erle_db=round(gs, 1), reply_start_residual_dbfs=round(ls, 1),
               reply_body_erle_db=round(gb, 1), reply_body_residual_dbfs=round(lb, 1))
    # Near-end: output energy vs near-end energy where only the talker is active.
    idx = np.where(near_on & ~far_on)[0]
    loss = db(np.mean(en[idx])) - db(np.mean(eo[idx]))
    idx2 = np.where(near_on & far_on)[0]
    # Double-talk: correlate output with the near-end to see how much of it survives.
    k = R // 50
    nn = near[: len(ee) * k].reshape(-1, k)[idx2].ravel()
    oo = out[: len(ee) * k].reshape(-1, k)[idx2].ravel()
    lag_best, c_best = 0, 0
    for lag in range(0, 24 * 12, 24):  # canceller delay 0..12 ms
        c = float(np.dot(nn[: len(nn) - lag], oo[lag:])) / (np.linalg.norm(nn) * np.linalg.norm(oo) + 1e-12)
        if c > c_best:
            lag_best, c_best = lag, c
    gain = float(np.dot(nn[: len(nn) - lag_best], oo[lag_best:])) / (float(np.dot(nn, nn)) + 1e-12)
    print(f"  near-only loss {loss:5.1f} dB; double-talk near-end kept {20*np.log10(max(gain,1e-6)):5.1f} dB "
          f"(corr {c_best:.2f})")
    res["near_only_loss_db"] = round(loss, 1)
    res["double_talk_near_gain_db"] = round(20 * np.log10(max(gain, 1e-6)), 1)

    # Server-VAD proxy: speech starts while Woi is audible (+0.5 s tail) that are not the talker.
    def far_only_starts(x):
        out_ = []
        for s, t in tl["far_items"]:
            for st in vad_onsets(x, s, t + 0.5):
                if not any(ns - 0.3 <= st <= ne for ns, ne in tl["near_items"]):
                    out_.append(round(st, 2))
        return out_
    false_starts, raw_false = far_only_starts(out), far_only_starts(mic)
    far_secs = round(sum(t - s + 0.5 for s, t in tl["far_items"]), 1)
    hits = []
    for s, t in tl["near_items"]:
        st = vad_onsets(out, s - 0.2, t)
        hits.append(round(st[0] - s, 2) if st else None)
    print(f"  VAD proxy: false starts in {far_secs}s of Woi speech: {len(false_starts)} {false_starts} "
          f"(raw mic {len(raw_false)}); near-end detected after {hits} s")
    res.update(false_starts=len(false_starts), raw_false_starts=len(raw_false), far_seconds=far_secs,
               near_detect_s=hits)
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
