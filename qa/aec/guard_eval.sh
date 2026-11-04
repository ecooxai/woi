#!/usr/bin/env bash
# Echo-guard evaluation matrix on the offline rig (no audio devices touched):
# renders rigs (scenario x seed x near-end level), runs the offline WebRTC
# AEC3 (PipeWire's config), replays each through the app's EchoGuard
# (app/test/echo_guard_rig_test.dart) and scores raw mic / canceller / gated
# stream with the server-VAD proxy (erle.py).
# usage: qa/aec/guard_eval.sh [work-dir]   env: SEEDS="1 2 3" NEARS="-26 -30" SCENARIOS="turns stress"
#        EXTRA_MS=200 RENDER_ARGS=...
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
W=${1:-${TMPDIR:-/tmp}/woi-guard-eval}
FLUTTER=${FLUTTER:-flutter}
mkdir -p "$W"
B="$W/aec3_offline"
[ -x "$B" ] || g++ -O2 -std=c++17 "$here/aec3_offline.cc" -o "$B" $(pkg-config --cflags --libs webrtc-audio-processing-1)
dirs=()
for sc in ${SCENARIOS:-turns stress}; do
  for seed in ${SEEDS:-1 2 3}; do
    for near in ${NEARS:--26 -30}; do
      d="$W/${sc}_s${seed}_n${near#-}"
      mkdir -p "$d"
      python3 -I "$here/render_echo.py" "$repo/research/fixtures" "$d" --scenario "$sc" --seed "$seed" \
        --near-dbfs "$near" --jitter-ms 30 ${RENDER_ARGS:-} >/dev/null
      python3 -I - "$d" <<'PY'
import sys, wave, numpy as np
W = sys.argv[1]
for nm in ("far", "mic"):
    w = wave.open(f"{W}/{nm}.wav"); x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2") / 32768.0
    X = np.fft.rfft(x); n2 = len(x) * 2; Y = np.zeros(n2 // 2 + 1, complex); Y[:len(X)] = X
    (np.fft.irfft(Y, n2) * 2).astype("<f4").tofile(f"{W}/{nm}48.f32")
PY
      "$B" "$d/far48.f32" "$d/mic48.f32" "$d/aec.f32" 48000
      python3 -I "$here/erle.py" "$d" "$d/aec.f32" --save-wav "$d/aec.wav" --json "$d/aec.json" >/dev/null 2>&1
      python3 -I "$here/erle.py" "$d" "$d/mic.wav" --rate 24000 --json "$d/raw.json" >/dev/null 2>&1
      rm -f "$d"/*.f32
      dirs+=("$d")
    done
  done
done
(cd "$repo/app" && WOI_AEC_RIG=$(IFS=,; echo "${dirs[*]}") WOI_AEC_EXTRA_MS=${EXTRA_MS:-200} \
  "$FLUTTER" test test/echo_guard_rig_test.dart >"$W/flutter.log" 2>&1) || { tail -30 "$W/flutter.log"; exit 1; }
for d in "${dirs[@]}"; do
  python3 -I "$here/erle.py" "$d" "$d/gated.wav" --rate 24000 --json "$d/gated.json" >/dev/null 2>&1
done
python3 -I - "${dirs[@]}" <<'PY'
import json, sys
tot = {k: 0 for k in ("raw", "aec", "gated", "gfalse", "ofalse", "far_s", "bi", "bi_hit", "bi_old")}
lat = []
print(f"{'rig':18s} {'Woi s':>6s} | VAD false turns raw/aec/gated | onsets false guard/old | barge-ins hit guard/old (latency ms)")
for d in sys.argv[1:]:
    r, a, g, q = (json.load(open(f"{d}/{n}.json")) for n in ("raw", "aec", "gated", "guard"))
    name = d.rstrip("/").split("/")[-1]
    first = {}
    for o in q["guard_onsets_true"]:
        if o["over_woi"]: first.setdefault(o["item"], o["latency_ms"])
    hits = list(first.values())  # first onset per near-end item
    print(f"{name:18s} {a['far_seconds']:6.1f} | {r['false_starts']:3d} {a['false_starts']:3d} {g['false_starts']:3d} "
          f"            | {len(q['guard_onsets_false']):3d} {len(q['old_onsets_false']):3d}            "
          f"| {len(hits)}/{q['near_items_over_woi']} {len(q['old_onsets_true'])}/{q['near_items_over_woi']} {hits}")
    tot["raw"] += r["false_starts"]; tot["aec"] += a["false_starts"]; tot["gated"] += g["false_starts"]
    tot["gfalse"] += len(q["guard_onsets_false"]); tot["ofalse"] += len(q["old_onsets_false"])
    tot["far_s"] += a["far_seconds"]; tot["bi"] += q["near_items_over_woi"]; tot["bi_hit"] += len(hits)
    tot["bi_old"] += len(q["old_onsets_true"]); lat += hits
m = tot["far_s"] / 60
print(f"TOTAL {tot['far_s']:.0f} s of Woi speech: VAD false turns raw {tot['raw']} ({tot['raw']/m:.1f}/min), "
      f"canceller {tot['aec']} ({tot['aec']/m:.2f}/min), gated {tot['gated']} ({tot['gated']/m:.2f}/min); "
      f"false onsets guard {tot['gfalse']} / old detector {tot['ofalse']}; "
      f"barge-ins detected guard {tot['bi_hit']}/{tot['bi']} / old {tot['bi_old']}/{tot['bi']}; "
      f"guard detection ms after speech start (capture time, + EXTRA_MS of capture/canceller delay) {sorted(lat)}")
PY
