#!/usr/bin/env python3
"""Host-only numeric summary for Android held-microphone QA.

No ADB or phone actions are performed. `summarize LOG` reads native diagnostics.
`prepare` only reproduces the archived 0.15.0 dual-source media fixture; the
current microphone-only device harness does not use playback or projection.
"""
from __future__ import annotations

import argparse
import array
import json
import math
from pathlib import Path
import re
import sys
import wave

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "qa/out/acceptance-0.15.1"


def prepare() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "capturable_tones.wav"
    rate = 48000
    pcm = array.array("h")
    # Repeated 1.5 s tone / 0.5 s silence cycles, with short click-free fades.
    # Low amplitude, no speech, no recorded microphone, and no external API.
    for i in range(16 * rate):
        t = i / rate
        within = t % 2.0
        gain = 0.0 if within >= 1.5 else min(1.0, within / 0.02, (1.5 - within) / 0.02)
        value = gain * 0.04 * (math.sin(2 * math.pi * 731 * t) + math.sin(2 * math.pi * 1097 * t))
        sample = round(value * 32767)
        pcm.extend((sample, sample))
    if sys.byteorder != "little":
        pcm.byteswap()
    with wave.open(str(path), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(pcm.tobytes())
    print(json.dumps({"fixture": str(path), "seconds": 16, "rate": rate,
                      "channels": 2, "peak_bound": 0.08, "phone_actions": 0}, indent=2))


def summarize(log: Path) -> None:
    records = []
    marker = "held audio released: "
    for line in log.read_text(errors="replace").splitlines():
        if marker not in line:
            continue
        text = line.split(marker, 1)[1]
        fields = dict(re.findall(r"([a-z_]+)=([^,{}]+)", text))
        record = {}
        for name in ("generation", "mic_samples", "samples_per_source"):
            if name in fields:
                record[name] = int(fields[name].strip())
        for name in ("mic_rms", "system_rms"):
            if name in fields:
                record[name] = float(fields[name].strip())
        if "sources" in fields:
            record["sources"] = fields["sources"].strip().strip("[]").split()
        record["released"] = fields.get("released", "").strip() == "true"
        record["error"] = None if fields.get("error", "null").strip() == "null" else fields["error"].strip()
        record["seconds"] = round(record.get("mic_samples", record.get("samples_per_source", 0)) / 24000, 3)
        records.append(record)
    report = {
        "captures": records,
        "all_reported_released": bool(records) and all(r["released"] for r in records),
        "note": "Android 0.15.1 holds record only the microphone. Zero RMS may be quiet-room noise gating; samples alone do not prove speech quality. Match generations to scenario labels and OS silencing checks. Legacy dual-source fields are preserved only when present in older logs.",
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "android-audio-native-summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("prepare")
    summary = sub.add_parser("summarize")
    summary.add_argument("log", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        prepare()
    else:
        summarize(args.log)


if __name__ == "__main__":
    main()
