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
#
# Env: QA_DISPLAY (default :11; :0 refused), SECS (seconds per scenario, default 60),
#      SANDBOX (default /tmp/woi-perf-sandbox), PNAME (process name, default woi-perf),
#      SIZE (window size, default "1600 900").
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
APP_PID=""

cleanup() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; wait 2>/dev/null; }
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
  printf '{"micMode": "%s", "autoScreenshot": false}\n' "$mic" >"$data/woi/settings.json"
  ln -sf "$BIN" "$SANDBOX/$PNAME"
  (cd "$SANDBOX" && exec env HOME="$SANDBOX" CODEX_HOME="$REAL_HOME/.codex" XDG_DATA_HOME="$data" "$@" \
    "$SANDBOX/$PNAME" >"$OUT/app-$name.log" 2>&1) &
  APP_PID=$!
  local wid="" t=0
  while [ -z "$wid" ] && [ $t -lt 60 ]; do
    sleep 0.5; t=$((t + 1))
    wid=$(xdotool search --pid "$APP_PID" --name '^Woi$' 2>/dev/null | head -1)
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
      # Camera on (preview tile + frames kept for turns); needs /dev/video0.
      launch camera muted WOI_DEBUG_CAMERA=1 || continue
      sleep 6
      monitor "$SECS" camera   # ffmpeg (the camera reader) is a child: included
      ;;
    *) echo "unknown scenario $s" >&2; continue ;;
  esac
  stop_app
  cat "$OUT/$s.summary.txt" 2>/dev/null
done
