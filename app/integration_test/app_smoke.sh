#!/usr/bin/env bash
# Smoke test of the REAL release app in its default mode (gpt-live):
#   flutter build linux --release && integration_test/app_smoke.sh
#
# * fresh settings/history (XDG_DATA_HOME=$OUT/data), so defaults apply;
# * the virtual mic is the default source only while this runs (restored by
#   a trap, also on failure / Ctrl-C);
# * fixtures 01 (chat) and 05 ("Show me the file README.md") are played
#   into the mic; a temporary ~/README.md exists only during the run;
# * logs and screenshots go to $OUT; the app is closed at the end.
set -u
cd "$(dirname "$0")/.."
APP_DIR=$PWD
OUT=${OUT:-/tmp/woi_app_smoke}
FIX=${WOI_FIXTURES:-$APP_DIR/../research/fixtures}
BIN=$APP_DIR/build/linux/x64/release/bundle/woi
export DISPLAY=${DISPLAY:-:0}
[ -x "$BIN" ] || { echo "build first: flutter build linux --release" >&2; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT/data"

. integration_test/virtual_audio.sh
APP_PID=""
TEMP_README=""
smoke_cleanup() {
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.3; done
    kill -9 "$APP_PID" 2>/dev/null
    echo "app closed" >&2
  fi
  [ -n "$TEMP_README" ] && rm -f "$TEMP_README"
  woi_audio_cleanup
}
woi_audio_setup --default-source || exit 1
trap smoke_cleanup EXIT

if [ ! -e "$HOME/README.md" ]; then
  printf '# README\n\nTemporary file for the Woi app smoke test.\n' >"$HOME/README.md"
  TEMP_README=$HOME/README.md
fi

# Launch through a symlink: same binary, but its process name is not "woi",
# so a concurrent `pkill -x woi` elsewhere does not close it.
ln -sf "$BIN" "$OUT/woi-smoke"
XDG_DATA_HOME=$OUT/data "$OUT/woi-smoke" >"$OUT/app.log" 2>&1 &
APP_PID=$!

wait_log() { # pattern timeout_s
  local t=0
  until grep -qE "$1" "$OUT/app.log"; do
    sleep 0.5; t=$((t + 1))
    kill -0 "$APP_PID" 2>/dev/null || { echo "app exited" >&2; return 1; }
    if [ $t -ge $(($2 * 2)) ]; then echo "timeout waiting for /$1/" >&2; return 1; fi
  done
  return 0
}
shot() { import -window root "$OUT/$1.png" && echo "screenshot $OUT/$1.png" >&2; }

STATUS=0
if wait_log 'gpt-live connected' 30; then
  grep -E 'gpt-live connected' "$OUT/app.log"
  sleep 2
  shot 00_connected
  for f in 01_hello 05_show_readme; do
    n_before=$(grep -c 'gpt-live assistant:' "$OUT/app.log")
    paplay -d woi_fixture_sink "$FIX/$f.wav"
    # Wait for an assistant turn after the playback (delegations take longer).
    t=0
    while [ "$(grep -c 'gpt-live assistant:' "$OUT/app.log")" -le "$n_before" ] && [ $t -lt 40 ]; do sleep 0.5; t=$((t + 1)); done
    sleep 4
    shot "$f"
  done
  sleep 6
  shot 05_show_readme_later # the viewer window takes a moment to render
else
  STATUS=1
fi
xdotool search --pid "$APP_PID" getwindowname %@ 2>/dev/null | sed 's/^/window: /'
echo "---- app log (gpt-live / delegation / errors)"
grep -E 'gpt-live|delegation|webrtc|rror|xception' "$OUT/app.log" | cut -c1-300
grep -q 'gpt-live user: .*[Hh]ello' "$OUT/app.log" || STATUS=1
grep -qiE 'gpt-live user: .*read ?me' "$OUT/app.log" || STATUS=1
grep -q 'tools=\[[^]]*show_file' "$OUT/app.log" || STATUS=1
echo "smoke status: $STATUS (logs and screenshots in $OUT)"
exit $STATUS
