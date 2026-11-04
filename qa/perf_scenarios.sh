#!/usr/bin/env bash
# Runs the perf scenarios against a Woi bundle on a test display and stores
# one CSV + summary per scenario (qa/perf_monitor.sh does the sampling).
#
#   qa/perf_scenarios.sh BIN OUT_DIR [scenario...]
#
#   BIN       path to the bundle's `woi` binary
#   OUT_DIR   CSVs / summaries / app logs land here
#   scenarios idle listen typing scroll video camera   (default: the first five)
#             idle10 = 10 min idle (RSS growth check)
#             tab-note tab-chat tab-terminal tab-settings = idle (muted) on that tab
#             reply = a typed question answered with a long spoken reply (needs a connection)
#
# Env: QA_DISPLAY (default :11; :0 refused), SECS (seconds per scenario, default 60),
#      SANDBOX (default /tmp/woi-perf-sandbox), PNAME (process name, default woi-perf),
#      SIZE (window size, default "1600 900").
#      PERF_SETTINGS (extra settings.json members, e.g. '"backendMode": "direct"'
#      to stay off gpt-live while its quota is exhausted).
#      PERF_SILENT_MIC=1 records from a silent virtual source (a PipeWire null
#      source loaded for this run, unloaded at exit) so "listen" measures
#      listening in silence, not the room.
# The mic mode is forced with WOI_MIC_MODE (a muted mic otherwise comes back on at launch).
# Each scenario starts the app fresh with HOME and XDG_DATA_HOME in a
# sandbox seeded by qa/lib/make_perf_seed.py (200-message chat + notes);
# CODEX_HOME keeps the real login. Only processes started here are killed.
set -u
QA_DIR=$(cd "$(dirname "$0")" && pwd)
BIN=${1:?usage: perf_scenarios.sh BIN OUT_DIR [scenario...]}
OUT=${2:?usage: perf_scenarios.sh BIN OUT_DIR [scenario...]}
shift 2
SCENARIOS=${*:-idle listen typing scroll video}
# Test display: QA_DISPLAY (default :11); the user's desktop (:0) is refused.
QA_DISPLAY=${QA_DISPLAY:-:11}
case ${QA_DISPLAY#unix} in
  :0 | :0.* | localhost:0 | localhost:0.*) echo "refusing QA_DISPLAY=$QA_DISPLAY (the user's desktop)" >&2; exit 2 ;;
esac
export DISPLAY=$QA_DISPLAY
SECS=${SECS:-60}
SIZE=${SIZE:-1600 900}
REAL_HOME=$HOME
SANDBOX=${SANDBOX:-/tmp/woi-perf-sandbox}
# Process/binary name (<= 15 chars); change it to run beside another perf run.
PNAME=${PNAME:-woi-perf}
mkdir -p "$OUT"
# Frame counts every 10 s in each app log (summarized after each scenario).
export WOI_FRAME_STATS=${WOI_FRAME_STATS-1}
APP_PID=""

SILENT_MOD=""
if [ "${PERF_SILENT_MIC:-0}" = 1 ]; then
  src="$PNAME-silence"
  SILENT_MOD=$(pactl load-module module-null-sink media.class=Audio/Source/Virtual sink_name="$src" channel_map=mono) ||
    { echo "cannot load a null source" >&2; exit 1; }
  shim=$SANDBOX/silent-mic-bin
  mkdir -p "$shim"
  printf '#!/bin/sh\nexec %s --target %s "$@"\n' "$(command -v pw-record)" "$src" >"$shim/pw-record"
  chmod +x "$shim/pw-record"
  export PATH="$shim:$PATH"
fi

cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  wait 2>/dev/null
  [ -n "$SILENT_MOD" ] && pactl unload-module "$SILENT_MOD"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

video() {
  local v=$SANDBOX/perf-video.mp4
  [ -s "$v" ] || ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30 \
    -f lavfi -i "sine=frequency=440:duration=120" -t 120 -c:v libx264 -pix_fmt yuv420p -c:a aac "$v"
  echo "$v"
}

# launch NAME MICMODE [extra env...]
launch() {
  local name=$1 mic=$2; shift 2
  local data=$SANDBOX/data-$name
  rm -rf "$data" && mkdir -p "$data/woi"
  python3 "$QA_DIR/lib/make_perf_seed.py" "$data/woi" --messages 200 --notes 8 >/dev/null
  printf '{"micMode": "%s", "autoScreenshot": false%s}\n' "$mic" "${PERF_SETTINGS:+, $PERF_SETTINGS}" >"$data/woi/settings.json"
  ln -sf "$BIN" "$SANDBOX/$PNAME"
  (cd "$SANDBOX" && exec env HOME="$SANDBOX" CODEX_HOME="$REAL_HOME/.codex" XDG_DATA_HOME="$data" WOI_MIC_MODE="$mic" "$@" \
    "$SANDBOX/$PNAME" >"$OUT/app-$name.log" 2>&1) &
  APP_PID=$!
  local wid="" t=0
  while [ -z "$wid" ] && [ $t -lt 60 ]; do
    sleep 0.5; t=$((t + 1))
    wid=$(xdotool search --onlyvisible --pid "$APP_PID" --name '^Woi$' 2>/dev/null | head -1)
  done
  [ -n "$wid" ] || { echo "no window for $name" >&2; return 1; }
  WID=$wid
  # shellcheck disable=SC2086
  xdotool windowmove "$WID" 0 0 windowsize "$WID" $SIZE
  sleep 12 # connect + settle
}

stop_app() { kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""; sleep 1; }

monitor() { "$QA_DIR/perf_monitor.sh" -d "$1" -l "$2" -c "${3:-^$PNAME\$}" -o "$OUT/$2.csv" >/dev/null; }

center() {
  local w h
  read -r w h <<<"$SIZE"
  xdotool mousemove --window "$WID" $((w * ${1:-50} / 100)) $((h * ${2:-50} / 100))
}

for s in $SCENARIOS; do
  echo "== $s" >&2
  mkdir -p "$SANDBOX"
  case $s in
    idle) launch idle muted && monitor "$SECS" idle ;;
    idle10) launch idle10 muted && monitor 600 idle10 ;;
    listen) launch listen handsFree && monitor "$SECS" listen ;;
    typing)
      launch typing muted || continue
      xdotool windowactivate --sync "$WID" 2>/dev/null; xdotool key --window "$WID" ctrl+1; sleep 1
      center 60 55; xdotool click 1; sleep 0.5; xdotool key ctrl+End
      monitor "$SECS" typing &
      mon=$!
      end=$((SECONDS + SECS))
      while [ $SECONDS -lt $end ]; do
        xdotool type --delay 90 "- typing perf check, the quick brown fox jumps over the lazy dog "
        xdotool key Return
      done
      wait $mon
      ;;
    scroll)
      launch scroll muted || continue
      xdotool windowactivate --sync "$WID" 2>/dev/null; xdotool windowraise "$WID"; xdotool key --window "$WID" ctrl+2; sleep 1
      center 60 50
      monitor "$SECS" scroll &
      mon=$!
      end=$((SECONDS + SECS))
      while [ $SECONDS -lt $end ]; do
        xdotool click --repeat 25 --delay 40 4
        xdotool click --repeat 25 --delay 40 5
      done
      wait $mon
      ;;
    video)
      v=$(video)
      launch video muted WOI_DEBUG_SHOW="$v" || continue
      sleep 4
      monitor "$SECS" video
      ;;
    camera)
      # Camera on (preview tile + frames kept for turns). Default: the QA
      # synthetic camera (same ffmpeg MJPEG-copy path at 1280x720, 30 -> 8 fps,
      # no image of the room); PERF_REAL_CAMERA=1 uses /dev/video0.
      if [ "${PERF_REAL_CAMERA:-0}" = 1 ]; then
        launch camera muted WOI_DEBUG_CAMERA=1 || continue
      else
        # shellcheck disable=SC2046
        launch camera muted $(QA_OUT=$OUT QA_DISPLAY=$QA_DISPLAY bash -c '. "$1/lib/common.sh" && qa_fake_camera' _ "$QA_DIR") || continue
      fi
      sleep 6
      monitor "$SECS" camera   # ffmpeg (the camera reader) is a child: included
      ;;
    tab-note | tab-chat | tab-terminal | tab-settings)
      launch "$s" muted || continue
      n=$(case $s in tab-note) echo 1 ;; tab-chat) echo 2 ;; tab-terminal) echo 3 ;; *) echo 4 ;; esac)
      xdotool windowactivate --sync "$WID" 2>/dev/null; xdotool key --window "$WID" "ctrl+$n"; sleep 3
      center 50 50 # pointer parked inside the window (hover effects)
      monitor "$SECS" "$s"
      ;;
    reply)
      launch reply muted || continue
      xdotool windowactivate --sync "$WID" 2>/dev/null; xdotool key --window "$WID" ctrl+k; sleep 1
      xdotool type --delay 20 "${REPLY_PROMPT:-Tell me a calm story about a lighthouse keeper, about one minute long.}"
      xdotool key Return
      monitor "$SECS" reply
      ;;
    *) echo "unknown scenario $s" >&2; continue ;;
  esac
  stop_app
  if [ -f "$OUT/$s.summary.txt" ]; then
    # Frames per second while monitored (WOI_FRAME_STATS lines, 10 s each).
    awk '/frames\[main\]/ { split($2, a, "f/"); f += a[1]; t += a[2] + 0 } END { if (t) printf "frames/s %.1f (%d frames in %d s)\n", f / t, f, t }' \
      "$OUT/app-$s.log" >>"$OUT/$s.summary.txt"
  fi
  cat "$OUT/$s.summary.txt" 2>/dev/null
done
