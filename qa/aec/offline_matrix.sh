#!/usr/bin/env bash
# Offline canceller matrix on the render_echo.py rig: no audio devices touched.
# usage: qa/aec/offline_matrix.sh [work-dir]   (needs g++, numpy, webrtc-audio-processing-1)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
W=${1:-${TMPDIR:-/tmp}/woi-aec-offline}
mkdir -p "$W"
B="$W/aec3_offline"
[ -x "$B" ] || g++ -O2 -std=c++17 "$here/aec3_offline.cc" -o "$B" $(pkg-config --cflags --libs webrtc-audio-processing-1)
python3 -I "$here/render_echo.py" "$repo/research/fixtures" "$W" ${RENDER_ARGS:-}
python3 -I - "$W" <<'PY'
import sys, wave, numpy as np
W = sys.argv[1]
for nm in ("far", "mic"):
    w = wave.open(f"{W}/{nm}.wav"); x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2") / 32768.0
    X = np.fft.rfft(x); n2 = len(x) * 2; Y = np.zeros(n2 // 2 + 1, complex); Y[:len(X)] = X
    (np.fft.irfft(Y, n2) * 2).astype("<f4").tofile(f"{W}/{nm}48.f32")
PY
run() {  # label, args...
  local label=$1; shift
  local tag; tag=$(echo "$label" | tr -c 'a-zA-Z0-9' _)
  "$B" "$W/far48.f32" "$W/mic48.f32" "$W/out_$tag.f32" 48000 "$@"
  python3 -I "$here/erle.py" "$W" "$W/out_$tag.f32" --label "$label" --json "$W/res_$tag.json" 2>/dev/null
}
python3 -I "$here/erle.py" "$W" "$W/mic.wav" --rate 24000 --label "raw mic (no canceller)" 2>/dev/null
run "defaults (Woi today: gain_control=0)" webrtc.gain_control=0
run "ns off" webrtc.noise_suppression=0
run "reference 20 ms late" ref_lead_ms=-20
run "reference 60 ms late" ref_lead_ms=-60
run "reference 150 ms late" ref_lead_ms=-150
run "reference 300 ms early" ref_lead_ms=300
run "reference 600 ms early" ref_lead_ms=600
