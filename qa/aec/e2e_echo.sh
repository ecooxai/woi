#!/usr/bin/env bash
# End-to-end self-talk test: the release build on the nested display, Direct
# realtime (gpt-realtime-2.1), its voice fed back into its own mic through a
# virtual room. Nothing reaches the real speakers or comes from the real mic,
# and the default sink/source are never changed (the app is pinned with
# WOI_AUDIO_SINK / WOI_AUDIO_SOURCE), so a Woi running on the desktop is not
# disturbed.
#
#   qa_e2e_speaker   null sink: Woi plays here
#   echo path        private pipewire -c filter-chain: speaker monitor ->
#                    gain x3, hard clip at +-0.25 (speaker nonlinearity),
#                    room IR (direct + 300 ms decaying tail), delay -> room
#   qa_e2e_room      null sink: the air; user fixtures are played here
#   qa_e2e_mic       remap of qa_e2e_room.monitor: Woi's microphone
#
# Script per run: two prompts with long answers (self-talk window), a
# "Stop" barge-in and a question barge-in while Woi speaks, then idle.
# Reports user turns that are not ours (self-talk), echo turns dropped,
# cut replies, barge-in stop latency.
#
# usage: QA_BIN=<bundle/woi> qa/aec/e2e_echo.sh <run-name>
#        (QA_OUT, QA_SANDBOX, QA_DISPLAY=:11, ECHO_GAIN=0.3, ECHO_DELAY=0.15)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
NAME=${1:-run}
export QA_OUT=${QA_OUT:-${TMPDIR:-/tmp}/woi-e2e-echo}/$NAME
export QA_SANDBOX=${QA_SANDBOX:-${TMPDIR:-/tmp}/home}
: "${QA_BIN:?set QA_BIN to the woi binary of a release bundle}"
FIX=$REPO/research/fixtures
QFIX=$REPO/qa/fixtures
GAIN=${ECHO_GAIN:-0.3}
DELAY=${ECHO_DELAY:-0.15}
rm -rf "$QA_OUT"; mkdir -p "$QA_OUT"
. "$REPO/qa/lib/common.sh"
LAT="python3 -I $REPO/qa/lib/latency.py"
SPK="$QA_OUT/spk.active"

ORIG_SOURCE=$(pactl get-default-source)
ORIG_SINK=$(pactl get-default-sink)
MODS=()
cleanup() {
  qa_stop_app
  qa_kill_all
  local i m
  for ((i = ${#MODS[@]} - 1; i >= 0; i--)); do pactl unload-module "${MODS[$i]}" 2>/dev/null; done
  for m in $(pactl list short modules | awk '/qa_e2e_/ {print $1}'); do pactl unload-module "$m" 2>/dev/null; done
  [ "$(pactl get-default-source)" = "$ORIG_SOURCE" ] || { qa_log "default source changed; restoring"; pactl set-default-source "$ORIG_SOURCE"; }
  [ "$(pactl get-default-sink)" = "$ORIG_SINK" ] || { qa_log "default sink changed; restoring"; pactl set-default-sink "$ORIG_SINK"; }
  qa_log "cleaned up (defaults $(pactl get-default-sink) / $(pactl get-default-source))"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

load() { local id; id=$(pactl load-module "$@") || { qa_log "load failed: $*"; exit 1; }; MODS+=("$id"); }
load module-null-sink sink_name=qa_e2e_speaker channels=1 rate=48000 sink_properties=device.description=QaE2eSpeaker
load module-null-sink sink_name=qa_e2e_room channels=1 rate=48000 sink_properties=device.description=QaE2eRoom
load module-remap-source master=qa_e2e_room.monitor source_name=qa_e2e_mic source_properties=device.description=QaE2eMic

# Room impulse response: direct path + decaying noise tail (about -8 dB).
python3 -I - "$QA_OUT/ir.wav" <<'EOF'
import math, random, struct, sys, wave
r = 48000; n = int(0.3 * r); rnd = random.Random(7)
h = [0.0] * n; h[0] = 1.0
for i in range(48, n):
    h[i] = 0.05 * rnd.uniform(-1, 1) * math.exp(-i / (0.06 * r))
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(4); w.setframerate(r)
    w.writeframes(b"".join(struct.pack("<i", int(v * 2147483000)) for v in h))
EOF
cat >"$QA_OUT/echo.conf" <<EOF
context.properties = { log.level = 2 core.daemon = false core.name = qa-e2e-echo }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [
  { name = libpipewire-module-rt args = { } flags = [ ifexists nofail ] }
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  { name = libpipewire-module-filter-chain
    args = {
      node.description = "qa_e2e echo path"
      filter.graph = {
        nodes = [
          { type = builtin name = drive label = linear control = { "Mult" = 3.0 "Add" = 0.0 } }
          { type = builtin name = clip label = clamp control = { "Min" = -0.25 "Max" = 0.25 } }
          { type = builtin name = room label = convolver config = { filename = "$QA_OUT/ir.wav" gain = $GAIN } }
          { type = builtin name = late label = delay config = { "max-delay" = 1.0 } control = { "Delay (s)" = $DELAY } }
        ]
        links = [
          { output = "drive:Out" input = "clip:In" }
          { output = "clip:Out" input = "room:In" }
          { output = "room:Out" input = "late:In" }
        ]
      }
      audio.channels = 1
      audio.position = [ MONO ]
      capture.props = { node.name = qa_e2e_echo_in target.object = qa_e2e_speaker stream.capture.sink = true node.dont-reconnect = true }
      playback.props = { node.name = qa_e2e_echo_out target.object = qa_e2e_room node.dont-reconnect = true }
    }
  }
]
EOF
pipewire -c "$QA_OUT/echo.conf" >"$QA_OUT/echo.log" 2>&1 &
qa_track_pid $!
for _ in $(seq 50); do pw-link -o 2>/dev/null | grep -q '^qa_e2e_echo_out:' && break; sleep 0.1; done
pw-link -o 2>/dev/null | grep -q '^qa_e2e_echo_out:' || { qa_log "echo path did not start"; cat "$QA_OUT/echo.log" >&2; exit 1; }

python3 -I "$REPO/qa/lib/speaker_monitor.py" qa_e2e_speaker.monitor "$QA_OUT/spk" >/dev/null 2>&1 &
qa_track_pid $!
# What Woi's mic hears (echo + user), for levels.
pw-record --target qa_e2e_mic --rate 24000 --channels 1 --format s16 "$QA_OUT/mic.wav" 2>/dev/null &
qa_track_pid $!
user() { qa_log "user: $(basename "$1")"; date +%s.%N >>"$QA_OUT/user_times"; pw-play --target qa_e2e_room "$1"; }
wait_quiet() { # gap max: until Woi was silent for gap s (max s)
  local t=0
  while [ $t -lt $(($2 * 2)) ]; do
    sleep 0.5; t=$((t + 1))
    [ -s "$SPK" ] && [ "$($LAT quiet "$SPK" "$T_PROMPT" "$1")" = 1 ] && [ "$($LAT first "$SPK" "$T_PROMPT")" != -1 ] && return 0
  done
  return 1
}

qa_make_sandbox || exit 1
qa_launch_app "$NAME" '{"backendMode":"direct","realtimeModel":"gpt-realtime-2.1"}' \
  WOI_AUDIO_SINK=qa_e2e_speaker WOI_AUDIO_SOURCE=qa_e2e_mic WOI_MIC_MODE=handsFree || exit 1
sleep 8

for f in "$QFIX/12_mars_facts.wav" "$QFIX/11_long_story.wav"; do
  T_PROMPT=$(date +%s.%N); user "$f"
  wait_quiet 5 120 || qa_log "still talking after 120 s"
done

barge_at() { # fixture onset_s label
  T_PROMPT=$(date +%s.%N); user "$QFIX/11_long_story.wav"
  local t=0
  while [ "$($LAT first "$SPK" "$T_PROMPT")" = -1 ] && [ $t -lt 60 ]; do sleep 0.5; t=$((t + 1)); done
  sleep 5
  if [ "$($LAT speaking "$SPK" 1.0)" != 1 ]; then echo "$3 not-speaking" >>"$QA_OUT/barge.txt"; return; fi
  local t0; t0=$(date +%s.%N)
  user "$1"
  local onset; onset=$(echo "$t0 + $2" | bc)
  sleep 6
  echo "$3 $($LAT stop "$SPK" "$onset" 1.5)" >>"$QA_OUT/barge.txt"
  T_PROMPT=$onset; wait_quiet 4 90
}
barge_at "$FIX/10_stop.wav" 0.30 stop
barge_at "$FIX/01_hello.wav" 0.30 question
sleep 10
qa_stop_app

python3 -I - "$QA_OUT" "$NAME" <<'EOF'
import glob, json, math, struct, sys, wave
out, name = sys.argv[1], sys.argv[2]
import difflib, re
said = ["Tell me three interesting facts about Mars.",
        "Tell me a long story about a lighthouse keeper. Make it at least one minute long.",
        "Stop", "Hello, how are you?"]
norm = lambda t: re.sub(r"[^a-z ]", "", (t or "").lower()).strip()
def is_ours(t):  # one of the played fixtures (not Woi heard back)
    return any(difflib.SequenceMatcher(None, norm(t), norm(f)).ratio() >= 0.7 for f in said)
convs = sorted(glob.glob(f"{out}/data-{name}/woi/conversations/*.json"))
msgs = []
for c in convs:
    msgs += json.load(open(c)).get("messages", [])
users = [m for m in msgs if m.get("kind") == "user"]
mine = [m for m in users if is_ours(m.get("text"))]
other = [m for m in users if m not in mine]
asst = [m for m in msgs if m.get("kind") == "assistant"]
log = open(f"{out}/app-{name}.log", errors="replace").read()
barge = open(f"{out}/barge.txt").read().split("\n") if glob.glob(f"{out}/barge.txt") else []
with wave.open(f"{out}/mic.wav") as w:
    b = w.readframes(w.getnframes())
x = struct.unpack(f"<{len(b)//2}h", b)
fr = [math.sqrt(sum(v * v for v in x[i:i+2400]) / 2400) for i in range(0, len(x) - 2400, 2400)]
act = sorted(v for v in fr if v > 30)
lvl = lambda q: round(20 * math.log10(act[int(q * (len(act) - 1))] / 32768), 1) if act else None
print(json.dumps({
    "run": name,
    "user_turns": len(users), "fixture_turns": len(mine),
    "self_talk_turns": [m.get("text") for m in other],
    "assistant_replies": len(asst), "replies_interrupted": sum(1 for m in asst if m.get("interrupted")),
    "echo_turns_dropped": log.count("echo turn dropped"),
    "local_onsets_resumed": log.count("onset not confirmed"),
    "self_talk_pauses": log.count("self-talk: pausing"),
    "barge_stop_ms": [l for l in barge if l],
    "mic_level_dbfs_p50_p90": [lvl(0.5), lvl(0.9)],
}, indent=1))
EOF
