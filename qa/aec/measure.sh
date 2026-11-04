#!/bin/bash
# Measures Woi's PipeWire echo canceller on virtual devices (no sound reaches
# the real speakers, the real mic is not used).
#
#   qa_aec_speaker   null sink = "the speakers" (default sink during the run)
#   qa_aec_room      null sink = the air at the microphone
#   qa_aec_mic       remap of qa_aec_room.monitor = "the microphone" (default source)
#   echo path        loopback qa_aec_speaker.monitor -> qa_aec_room, 60 ms, -3 dB
#   near-end talker  pw-play --target qa_aec_room
#
# The canceller runs the exact config the app generates (tool/aec_conf.dart),
# hosted the same way (pipewire -c). Raw mic and canceller output are recorded
# side by side (24 kHz s16 like the app) through a timeline of far-end music,
# far-end speech, near-end speech alone and double talk; analyze.py reports the
# echo attenuation and near-end preservation in dB. Every qa_aec_* module is
# unloaded and the original default sink/source restored on exit (trap).
#
# usage: qa/aec/measure.sh [out-dir]     (default /tmp/woi-aec-measure)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/../../app" && pwd)
OUT=${1:-/tmp/woi-aec-measure}
DART=${DART:-/home/a/.local/flutter/bin/dart}
mkdir -p "$OUT"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }

pactl list short modules | cut -f1,2 >"$OUT/modules.before"
pactl info | grep -E '^Default (Sink|Source)' >"$OUT/info.before"
ORIG_SOURCE=$(pactl get-default-source)
ORIG_SINK=$(pactl get-default-sink)
MODS=()
PIDS=()

cleanup() {
  local p m
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 0.5
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  for ((i = ${#MODS[@]} - 1; i >= 0; i--)); do pactl unload-module "${MODS[$i]}" 2>/dev/null; done
  for m in $(pactl list short modules | awk '/qa_aec_/ {print $1}'); do pactl unload-module "$m" 2>/dev/null; done
  # Always set them: the session manager remembers the *configured* default
  # (qa_aec_*) even after the module is gone and the effective default fell back.
  pactl set-default-source "$ORIG_SOURCE"
  pactl set-default-sink "$ORIG_SINK"
  pactl list short modules | cut -f1,2 >"$OUT/modules.after"
  pactl info | grep -E '^Default (Sink|Source)' >"$OUT/info.after"
  if diff -q "$OUT/modules.before" "$OUT/modules.after" >/dev/null && diff -q "$OUT/info.before" "$OUT/info.after" >/dev/null; then
    log "PipeWire state restored (modules and defaults identical)"
  else
    log "WARNING PipeWire state differs:"; diff "$OUT/modules.before" "$OUT/modules.after"; diff "$OUT/info.before" "$OUT/info.after"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

REC=(--rate 24000 --channels 1 --format s16 --latency 20ms --raw)
probe() { # bytes a new capture from $1 delivers in 1.5 s
  local f n; f=$(mktemp)
  pw-record "${REC[@]}" --target "$1" - >"$f" 2>/dev/null & local p=$!
  sleep 1.5; kill -INT $p; wait $p 2>/dev/null; n=$(stat -c %s "$f"); rm -f "$f"; echo "$n"
}
load() { local m; m=$(pactl load-module "$@") || { log "load-module $* failed"; exit 1; }; MODS+=("$m"); }

"$HERE/make_signals.sh" "$OUT/sig" || exit 1
(cd "$APP" && "$DART" run tool/aec_conf.dart qa) >"$OUT/aec.conf" 2>/dev/null || exit 1
grep -q libpipewire-module-echo-cancel "$OUT/aec.conf" || { log "no config"; exit 1; }

load module-null-sink sink_name=qa_aec_speaker sink_properties=device.description=QaAecSpeaker
load module-null-sink sink_name=qa_aec_room sink_properties=device.description=QaAecRoom
load module-remap-source master=qa_aec_room.monitor source_name=qa_aec_mic source_properties=device.description=QaAecMic
load module-loopback source=qa_aec_speaker.monitor sink=qa_aec_room latency_msec=60 source_dont_move=true sink_dont_move=true
sleep 0.5
# Echo path gain: ECHO_VOL (pactl %, cubic: 89% ~ -3 dB, 63% ~ -12 dB).
LOOP_IN=$(pactl -f json list sink-inputs | python3 -I -c 'import json,sys; m=sys.argv[1]
print(next((str(i["index"]) for i in json.load(sys.stdin) if str(i.get("owner_module")) == m), ""))' "${MODS[3]}")
[ -n "$LOOP_IN" ] || { log "echo-path loopback sink-input not found"; exit 1; }
pactl set-sink-input-volume "$LOOP_IN" "${ECHO_VOL:-89%}"
pactl set-default-sink qa_aec_speaker
pactl set-default-source qa_aec_mic
sleep 0.5

n=$(probe qa_aec_mic)
[ "$n" -gt 1000 ] || { log "virtual mic delivers $n bytes before the AEC starts; PipeWire graph not running"; exit 1; }
# The canceller, hosted like the app does.
pipewire -c "$OUT/aec.conf" 2>"$OUT/aec.log" &
AEC_PID=$!
PIDS+=("$AEC_PID")
for _ in $(seq 60); do pw-cli ls Node | grep -q 'node.name = "woi_aec_source_qa"' && break; sleep 0.05; done
pw-cli ls Node | grep -q 'node.name = "woi_aec_source_qa"' || { log "AEC source did not appear"; cat "$OUT/aec.log"; exit 1; }
sleep 0.5
# Abort early if the graph does not run (nothing would be measured).
n=$(probe qa_aec_mic)
[ "$n" -gt 1000 ] || { log "capture from qa_aec_mic produced $n bytes; PipeWire graph not running"; exit 1; }
log "defaults while AEC runs: $(pactl get-default-source) / $(pactl get-default-sink)"
pw-link -l >"$OUT/links.txt" 2>&1

pw-record "${REC[@]}" --target woi_aec_source_qa - >"$OUT/aec.raw" &
PIDS+=($!)
pw-record "${REC[@]}" --target qa_aec_mic - >"$OUT/raw.raw" &
PIDS+=($!)
# T0 = once both recorders deliver; t0.txt keeps how much each held then.
for _ in $(seq 100); do [ -s "$OUT/aec.raw" ] && [ -s "$OUT/raw.raw" ] && break; sleep 0.05; done
T0=$(date +%s.%N)
printf 'aec %s\nraw %s\n' "$(stat -c %s "$OUT/aec.raw")" "$(stat -c %s "$OUT/raw.raw")" >"$OUT/t0.txt"
at() { local now; now=$(date +%s.%N); sleep "$(echo "$1 - ($now - $T0)" | bc)"; }
far() { pw-play --target qa_aec_speaker "$1" & PIDS+=($!); }
near() { pw-play --target qa_aec_room "$1" & PIDS+=($!); }

# Timeline (s): 0-2 silence | 2-14 music | 15-33.2 far speech | 34.5-41 near alone
#               | 42-54 music + near at 45 | 55-57 silence
CPU0=$(awk '{print $14+$15}' /proc/$AEC_PID/stat)
at 2;    far "$OUT/sig/music.wav"
at 15;   far "$OUT/sig/farspeech.wav"
at 34.5; near "$OUT/sig/near.wav"
at 42;   far "$OUT/sig/music.wav"
at 45;   near "$OUT/sig/near.wav"
at 57
CPU1=$(awk '{print $14+$15}' /proc/$AEC_PID/stat)
echo "scale=2; ($CPU1-$CPU0)*100/$(getconf CLK_TCK)/55" | bc >"$OUT/cpu.txt"
log "AEC host CPU while processing: $(cat "$OUT/cpu.txt")% of one core"
grep VmRSS /proc/$AEC_PID/status | tee "$OUT/rss.txt" >&2

python3 -I "$HERE/analyze.py" "$OUT" | tee "$OUT/result.txt"
