#!/bin/bash
# Latency of the PipeWire WebRTC canceller (the module Woi hosts) on virtual
# devices only, without touching the default sink/source (safe while Woi runs):
#
#   qa_lat_far    null sink: the speaker (the canceller's playback target)
#   qa_lat_mic    null sink: the air at the mic; its monitor is the mic
#   echo path     loopback qa_lat_far.monitor -> qa_lat_mic (-6 dB)
#   qa_lat_rec    2-channel null sink: FL = raw mic, FR = canceller output,
#                 linked in the same graph cycle, recorded side by side
#
# The canceller runs in its own `pipewire -c` (like the app) in sink mode
# (the app uses monitor mode, which follows the default sink) with explicit
# targets. Near-end clicks are played into qa_lat_mic with and without far
# speech-like noise into the canceller's sink; the lag between FL and FR is the
# canceller's own latency. Repeated for each node.latency in LATS.
#
# usage: qa/aec/pw_latency.sh [out-dir]   (LATS="480/48000 256/48000 1024/48000")
set -u
OUT=${1:-${TMPDIR:-/tmp}/woi-pw-latency}
LATS=${LATS:-"480/48000 256/48000 1024/48000"}
mkdir -p "$OUT"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }

ORIG_SOURCE=$(pactl get-default-source)
ORIG_SINK=$(pactl get-default-sink)
MODS=()
PIDS=()
cleanup() {
  local p m
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 0.3
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  for ((i = ${#MODS[@]} - 1; i >= 0; i--)); do pactl unload-module "${MODS[$i]}" 2>/dev/null; done
  for m in $(pactl list short modules | awk '/qa_lat_/ {print $1}'); do pactl unload-module "$m" 2>/dev/null; done
  [ "$(pactl get-default-source)" = "$ORIG_SOURCE" ] || pactl set-default-source "$ORIG_SOURCE"
  [ "$(pactl get-default-sink)" = "$ORIG_SINK" ] || pactl set-default-sink "$ORIG_SINK"
  log "cleaned up (defaults: $(pactl get-default-sink) / $(pactl get-default-source))"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

load() { local id; id=$(pactl load-module "$@") || { log "load failed: $*"; exit 1; }; MODS+=("$id"); }
load module-null-sink sink_name=qa_lat_far channels=1 rate=48000 sink_properties=node.description=qa_lat_far
load module-null-sink sink_name=qa_lat_mic channels=1 rate=48000 sink_properties=node.description=qa_lat_mic
load module-null-sink sink_name=qa_lat_rec channels=2 rate=48000 sink_properties=node.description=qa_lat_rec
load module-loopback source=qa_lat_far.monitor sink=qa_lat_mic latency_msec=40 source_dont_move=true sink_dont_move=true

# Signals: 8 s of 48 kHz mono s16. Near: 100 ms voiced bursts every second;
# far: speech-like noise (syllable-modulated pink-ish noise) at -20 dBFS.
python3 -I - "$OUT" <<'EOF'
import math, random, struct, sys, wave
out = sys.argv[1]; r = 48000; n = 8 * r
def save(name, x):
    with wave.open(f"{out}/{name}", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(r)
        w.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(v * 32767)))) for v in x))
near = [0.0] * n
L = 4800  # 100 ms voiced burst (f0 200 Hz, harmonics to 3 kHz)
for s in range(1, 8):
    for i in range(L):
        v = sum(math.sin(2 * math.pi * 200 * k * i / r) / k for k in range(1, 16))
        near[s * r + i] = 0.25 * v * math.sin(math.pi * i / L)
save("near.wav", near)
rnd = random.Random(1); far = []; b = 0.0
for i in range(n):
    b = 0.97 * b + rnd.uniform(-1, 1) * 0.3
    env = 0.5 + 0.5 * math.sin(2 * math.pi * 4 * i / r)
    far.append(0.1 * env * b)
save("far.wav", far)
EOF

host() { # $1 node.latency -> starts the canceller host
  cat >"$OUT/ec.conf" <<EOF
context.properties = { log.level = 2 core.daemon = false core.name = qa-lat-aec }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [
  { name = libpipewire-module-rt args = { } flags = [ ifexists nofail ] }
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  { name = libpipewire-module-echo-cancel
    args = {
      library.name = aec/libspa-aec-webrtc
      aec.args = { webrtc.gain_control = false }
      audio.channels = 1
      audio.position = [ MONO ]
      node.latency = $1
      capture.props = { node.name = qa_lat_aec_capture target.object = qa_lat_mic stream.capture.sink = true
                        node.dont-reconnect = true node.latency = $1 }
      source.props = { node.name = qa_lat_aec_source priority.session = 0 priority.driver = 0 node.latency = $1 }
      sink.props = { node.name = qa_lat_aec_sink priority.session = 0 priority.driver = 0 node.latency = $1 }
      playback.props = { node.name = qa_lat_aec_playback target.object = qa_lat_far node.dont-reconnect = true node.latency = $1 }
    }
  }
]
EOF
  pipewire -c "$OUT/ec.conf" >"$OUT/ec.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 50); do pw-link -o 2>/dev/null | grep -q '^qa_lat_aec_source:' && return 0; sleep 0.1; done
  log "canceller did not come up (node.latency $1)"; tail -3 "$OUT/ec.log" >&2; return 1
}

link() { # source-node, dest port suffix (FL/FR)
  local port; port=$(pw-link -o | grep "^$1:" | head -1)
  pw-link "$port" "qa_lat_rec:playback_$2" || log "link $port -> $2 failed"
}

for lat in $LATS; do
  for far in 0 1; do
    tag="${lat%/*}_far$far"
    host "$lat" || { echo "$tag: canceller failed to start" >>"$OUT/failures.txt"; PIDS=(); continue; }
    pw-link -o -l 2>/dev/null | grep -q 'qa_lat_rec:playback_FL' || link qa_lat_mic FL  # the mic sink's monitor
    link qa_lat_aec_source FR
    pw-record --target qa_lat_rec -P stream.capture.sink=true --rate 48000 --channels 2 --format s16 "$OUT/rec_$tag.wav" 2>/dev/null &
    rp=$!; PIDS+=($rp)
    sleep 0.5
    [ "$far" = 1 ] && { pw-play --target qa_lat_aec_sink "$OUT/far.wav" 2>/dev/null & PIDS+=($!); }
    pw-play --target qa_lat_mic "$OUT/near.wav" 2>/dev/null
    sleep 0.6
    kill -INT $rp; wait $rp 2>/dev/null
    # stop the host for the next run
    kill "${PIDS[0]}" 2>/dev/null
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    PIDS=()
    timeout 3 bash -c 'while pw-link -o 2>/dev/null | grep -q "^qa_lat_aec_"; do sleep 0.1; done'
  done
done

python3 -I "$(dirname "$0")/lat_analyze.py" "$OUT"/rec_*.wav
