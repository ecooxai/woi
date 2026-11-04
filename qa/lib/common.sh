# Sourced helpers for the Woi QA suite (qa/run_e2e.sh).
#
# State that must survive across shells (loaded module ids, the original
# default source/sink, pids we started) lives in $QA_OUT/state.*, so
# `qa_teardown` can always restore the desktop, even from a fresh shell.
#
# Module names are prefixed qa_ (not woi_) on purpose: app/integration_test/
# virtual_audio.sh unloads any leftover woi_* module, so a concurrent
# app_smoke.sh run by another engineer would otherwise tear down our mic.

QA_OUT=${QA_OUT:-/tmp/woi-qa-out}
QA_SANDBOX=${QA_SANDBOX:-/tmp/woi-qa-sandbox}
QA_REAL_HOME=${QA_REAL_HOME:-$HOME}
QA_LIB=${QA_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# The suite clicks, types and screenshots: it runs on a nested test display
# (Xephyr/Xvfb), never on the user's desktop. QA_DISPLAY picks it (default
# :11); :0 is refused.
QA_DISPLAY=${QA_DISPLAY:-:11}
case ${QA_DISPLAY#unix} in
  :0 | :0.* | localhost:0 | localhost:0.*)
    echo "refusing QA_DISPLAY=$QA_DISPLAY: that is the user's desktop; start a nested display (Xephyr :11)" >&2
    exit 2 ;;
esac
export DISPLAY=$QA_DISPLAY
export XAUTHORITY=${XAUTHORITY:-$QA_REAL_HOME/.Xauthority}
xdotool getdisplaygeometry >/dev/null 2>&1 || { echo "no X display at $DISPLAY" >&2; exit 2; }
mkdir -p "$QA_OUT"

# Screen size and centre: the click target, the backdrop and the click check
# follow the test display (1600x900 Xephyr, 1920x1080 Xvfb...).
read -r QA_SCREEN_W QA_SCREEN_H < <(xdotool getdisplaygeometry)
QA_CX=$((QA_SCREEN_W / 2)) QA_CY=$((QA_SCREEN_H / 2))

qa_log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$QA_OUT/run.log" >&2; }

# ---------------------------------------------------------------- audio
qa_audio_setup() {
  qa_audio_teardown 2>/dev/null # stale state from an earlier run
  [ -s "$QA_OUT/state.orig_source" ] || pactl get-default-source >"$QA_OUT/state.orig_source" || return 1
  [ -s "$QA_OUT/state.orig_sink" ] || pactl get-default-sink >"$QA_OUT/state.orig_sink" || return 1
  : >"$QA_OUT/state.modules"
  local m
  m=$(pactl load-module module-null-sink sink_name=qa_fixture_sink sink_properties=device.description=QaFixtureSink) || return 1
  echo "$m" >>"$QA_OUT/state.modules"
  m=$(pactl load-module module-remap-source master=qa_fixture_sink.monitor source_name=qa_virtual_mic \
    source_properties=device.description=QaVirtualMic) || return 1
  echo "$m" >>"$QA_OUT/state.modules"
  m=$(pactl load-module module-null-sink sink_name=qa_speaker sink_properties=device.description=QaSpeaker) || return 1
  echo "$m" >>"$QA_OUT/state.modules"
  pactl set-default-source qa_virtual_mic || return 1
  pactl set-default-sink qa_speaker || return 1
  qa_log "audio: modules $(tr '\n' ' ' <"$QA_OUT/state.modules"); default source/sink -> qa_virtual_mic/qa_speaker"
}

# The harness shares the real desktop: if the default source/sink were switched
# away from the QA devices (by a person, or a device change) the app would hear
# the real mic and play to the real speakers. Log it and switch back.
qa_audio_reassert() {
  local src sink; src=$(pactl get-default-source) sink=$(pactl get-default-sink)
  if [ "$src" != qa_virtual_mic ] || [ "$sink" != qa_speaker ]; then
    qa_log "WARNING default audio devices were changed outside the harness ($src / $sink); restoring QA devices"
    pactl set-default-source qa_virtual_mic; pactl set-default-sink qa_speaker
  fi
}

qa_audio_teardown() {
  local m
  if [ -f "$QA_OUT/state.modules" ]; then
    for m in $(tac "$QA_OUT/state.modules"); do pactl unload-module "$m" 2>/dev/null; done
    rm -f "$QA_OUT/state.modules"
  fi
  for m in $(pactl list short modules | awk '/qa_(fixture_sink|virtual_mic|speaker)/ {print $1}'); do
    pactl unload-module "$m" 2>/dev/null
  done
  if [ -s "$QA_OUT/state.orig_source" ]; then
    pactl set-default-source "$(cat "$QA_OUT/state.orig_source")" 2>/dev/null && rm -f "$QA_OUT/state.orig_source"
  fi
  if [ -s "$QA_OUT/state.orig_sink" ]; then
    pactl set-default-sink "$(cat "$QA_OUT/state.orig_sink")" 2>/dev/null && rm -f "$QA_OUT/state.orig_sink"
  fi
  echo "audio restored: source=$(pactl get-default-source) sink=$(pactl get-default-sink)" >&2
}

# ---------------------------------------------------------------- processes
qa_track_pid() { echo "$1" >>"$QA_OUT/state.pids"; }

qa_kill_all() {
  local p
  [ -f "$QA_OUT/state.pids" ] || return 0
  for p in $(cat "$QA_OUT/state.pids"); do kill "$p" 2>/dev/null; done
  sleep 1
  for p in $(cat "$QA_OUT/state.pids"); do kill -9 "$p" 2>/dev/null; done
  rm -f "$QA_OUT/state.pids"
}

qa_teardown() {
  qa_kill_all
  qa_kill_players
  qa_audio_teardown
}

# ---------------------------------------------------------------- sandbox
qa_make_sandbox() {
  rm -rf "$QA_SANDBOX" && mkdir -p "$QA_SANDBOX" || return 1
  cat >"$QA_SANDBOX/README.md" <<'EOF'
# Woi QA sandbox

This README lives in /tmp/woi-qa-sandbox. If Woi shows this text, relative paths resolved into the sandbox.
EOF
  printf 'QA notes\n- first line\n' >"$QA_SANDBOX/notes.txt"
  (cd "$QA_SANDBOX" &&
    ffmpeg -loglevel error -y -f lavfi -i testsrc=size=320x240:rate=1 -frames:v 1 sample.png &&
    ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3" tone.wav &&
    ffmpeg -loglevel error -y -f lavfi -i testsrc=size=320x240:rate=25 -f lavfi -i "sine=frequency=660:duration=4" \
      -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest demo.mp4)
}

# ---------------------------------------------------------------- windows
# Harmless click/type target, centred on the screen: an xterm whose input
# goes (non-canonical, so per keystroke) into $QA_SANDBOX/typed.txt.
qa_start_target() {
  [ -n "${QA_TARGET_PID:-}" ] && kill "$QA_TARGET_PID" 2>/dev/null && sleep 0.5
  : >"$QA_SANDBOX/typed.txt"
  xterm -T WOI-QA-TARGET -fa Monospace -fs 12 -geometry 40x8 \
    -e bash -c "echo 'Woi QA click/type target'; stty -icanon; exec cat > '$QA_SANDBOX/typed.txt'" &
  QA_TARGET_PID=$!
  qa_track_pid $!
  local wid="" t=0
  while [ -z "$wid" ] && [ $t -lt 20 ]; do sleep 0.3; wid=$(xdotool search --name '^WOI-QA-TARGET$' 2>/dev/null | head -1); t=$((t + 1)); done
  [ -n "$wid" ] || return 1
  qa_center_target "$wid"
  echo "$wid" >"$QA_OUT/state.target_wid"
}

# Neutral full-screen window behind everything, so the app's automatic
# screenshots (sent to the model, and shown in the transcript thumbnails we
# commit) contain only the QA windows, not the rest of the desktop.
qa_start_backdrop() {
  xterm -T WOI-QA-BACKDROP -bg '#1d2630' -fg '#8aa' -fa Monospace -fs 14 -geometry 100x30 \
    -e bash -c "echo 'Woi QA run in progress (backdrop window)'; exec sleep infinity" &
  qa_track_pid $!
  local wid="" t=0
  while [ -z "$wid" ] && [ $t -lt 20 ]; do sleep 0.3; wid=$(xdotool search --name '^WOI-QA-BACKDROP$' 2>/dev/null | head -1); t=$((t + 1)); done
  [ -n "$wid" ] || return 1
  xdotool windowsize "$wid" "$QA_SCREEN_W" "$QA_SCREEN_H" windowmove "$wid" 0 0
  sleep 0.3
}

qa_center_target() {
  local wid=$1 w h
  eval "$(xdotool getwindowgeometry --shell "$wid")"
  xdotool windowmove "$wid" $((QA_CX - WIDTH / 2)) $((QA_CY - HEIGHT / 2))
  xdotool windowraise "$wid" 2>/dev/null
}

# Screenshot of one window (not the whole desktop: keeps unrelated windows
# out of the repo), downscaled and compressed.
qa_shot() { # wid name [maxwidth]
  local wid=$1 name=$2 mw=${3:-900}
  mkdir -p "$QA_OUT/shots"
  timeout 10 import -window "$wid" "$QA_OUT/shots/$name.png" 2>/dev/null || return 1
  convert "$QA_OUT/shots/$name.png" -resize "${mw}x>" -strip -quality 72 "$QA_OUT/shots/$name.jpg" 2>/dev/null
  echo "$QA_OUT/shots/$name.jpg"
}

# Mean brightness (0..1) of a window; used to spot the modal barrier of an
# approval dialog.
qa_brightness() {
  timeout 10 import -window "$1" -resize 64x64! -colorspace gray -format '%[fx:mean]' info: 2>/dev/null || echo 1
}

# ---------------------------------------------------------------- app
# qa_launch_app NAME [settings-json] [VAR=value...]  -> sets APP_PID, APP_WID, APP_LOG
qa_launch_app() {
  local name=$1 settings=${2:-}
  shift; [ $# -gt 0 ] && shift
  local data="$QA_OUT/data-$name"
  rm -rf "$data" && mkdir -p "$data/woi"
  [ -n "$settings" ] && printf '%s\n' "$settings" >"$data/woi/settings.json"
  APP_LOG="$QA_OUT/app-$name.log"
  ln -sf "$QA_BIN" "$QA_OUT/woi-qa"
  # stdbuf: stdout to a file is block-buffered and the tail was lost when the
  # app is stopped; line buffering keeps the log complete.
  # HOME points at the sandbox: the app resolves relative paths (and `~`)
  # against $HOME, not the working directory. CODEX_HOME keeps the real login.
  (cd "$QA_SANDBOX" && exec env HOME="$QA_SANDBOX" CODEX_HOME="$QA_REAL_HOME/.codex" \
    XDG_DATA_HOME="$data" "$@" stdbuf -oL -eL "$QA_OUT/woi-qa" >"$APP_LOG" 2>&1) &
  APP_PID=$!
  qa_track_pid "$APP_PID"
  APP_WID="" ; local t=0
  while [ -z "$APP_WID" ] && [ $t -lt 40 ]; do
    sleep 0.5; t=$((t + 1))
    APP_WID=$(xdotool search --onlyvisible --pid "$(qa_app_pid)" 2>/dev/null | head -1)
    # _NET_WM_PID can be missing on the main window: fall back to the title
    [ -z "$APP_WID" ] && [ $t -ge 16 ] && APP_WID=$(xdotool search --onlyvisible --name '^Woi$' 2>/dev/null | head -1)
  done
  [ -n "$APP_WID" ] || { qa_log "app window not found"; return 1; }
  qa_log "app $name pid=$APP_PID wid=$APP_WID log=$APP_LOG"
}

# The subshell exec's the binary, so $APP_PID is the app itself.
qa_app_pid() { echo "$APP_PID"; }

qa_app_alive() { kill -0 "$APP_PID" 2>/dev/null; }

qa_stop_app() {
  [ -n "${APP_PID:-}" ] || return 0
  # direct children too (pw-record, pw-play): they outlived the app before
  local kids; kids=$(pgrep -P "$APP_PID")
  kill "$APP_PID" 2>/dev/null
  local t=0
  while kill -0 "$APP_PID" 2>/dev/null && [ $t -lt 15 ]; do sleep 0.3; t=$((t + 1)); done
  kill -9 "$APP_PID" 2>/dev/null
  [ -n "$kids" ] && kill $kids 2>/dev/null
  APP_PID=""
}

qa_wait_log() { # pattern timeout_s
  local t=0
  until grep -qE "$1" "$APP_LOG" 2>/dev/null; do
    sleep 0.5; t=$((t + 1))
    qa_app_alive || { qa_log "app exited while waiting for /$1/"; return 1; }
    [ $t -ge $(($2 * 2)) ] && { qa_log "timeout waiting for /$1/"; return 1; }
  done
  return 0
}

qa_place_app() { # x y w h
  xdotool windowsize "$APP_WID" "$3" "$4" 2>/dev/null
  xdotool windowmove "$APP_WID" "$1" "$2" 2>/dev/null
  sleep 0.3
  return 0
}

qa_app_geom() { xdotool getwindowgeometry "$APP_WID" 2>/dev/null | awk '/Geometry/ {print $2}'; }

# Visible windows of the app process other than the main one (viewer popups),
# ignoring the small helper windows Flutter/GTK map (< 200 px).
qa_viewer_wids() {
  local w
  for w in $(xdotool search --onlyvisible --pid "$APP_PID" 2>/dev/null | grep -vx "$APP_WID"); do
    eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)" || continue
    [ "${WIDTH:-0}" -ge 200 ] && [ "${HEIGHT:-0}" -ge 200 ] && echo "$w"
  done
}

# Screenshot of a screen region covering a window. `import -window` returns a
# blank frame for the GL-backed secondary Flutter windows, so crop the root.
qa_shot_screen() { # wid name [maxwidth]
  local wid=$1 name=$2 mw=${3:-900}
  eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || return 1
  xdotool windowraise "$wid" 2>/dev/null; sleep 0.5
  timeout 10 import -window root -crop "${WIDTH}x${HEIGHT}+${X}+${Y}" +repage "$QA_OUT/shots/$name.png" 2>/dev/null || return 1
  convert "$QA_OUT/shots/$name.png" -resize "${mw}x>" -strip -quality 72 "$QA_OUT/shots/$name.jpg" 2>/dev/null
  echo "$QA_OUT/shots/$name.jpg"
}

# Players the app spawns detached for video (not children of the app).
qa_kill_players() { pkill -f "(vlc|mpv|xdg-open) $QA_SANDBOX" 2>/dev/null; return 0; }

qa_reset_notes() { printf 'QA notes\n- first line\n' >"$QA_SANDBOX/notes.txt"; }

qa_focus_app() { xdotool windowactivate --sync "$APP_WID" 2>/dev/null || xdotool windowfocus "$APP_WID"; sleep 0.3; }

# Type into the app's composer (Ctrl+K focuses it) and send with Enter.
qa_type_in_app() {
  qa_focus_app
  xdotool key ctrl+k; sleep 0.4
  xdotool type --delay 15 "$1"; sleep 0.3
  xdotool key Return
}

qa_play() { paplay -d qa_fixture_sink "$1"; }

# ---------------------------------------------------------------- camera
# Synthetic camera: the app reads V4L2 through `ffmpeg -f v4l2 ... pipe:1`.
# qa_fake_camera puts an ffmpeg wrapper (qa/lib/fake_camera_ffmpeg.sh) first
# on PATH that serves a still test card as MJPEG instead, so camera turns are
# deterministic and no image of the real room leaves the machine. Echoes the
# VAR=value list for qa_launch_app.
qa_fake_camera() {
  local dir=$QA_OUT/fakecam
  mkdir -p "$dir"
  # 1280x720, the size the app requests (LinuxCameraService defaults)
  convert -size 1280x720 xc:'#f4f1e8' -fill '#d62828' -draw 'circle 340,420 340,240' \
    -fill '#1d4ed8' -draw 'rectangle 760,250 1100,590' -fill black -pointsize 88 \
    -annotate +290+150 'WOI QA CAMERA' -quality 85 "$dir/card.jpg" 2>/dev/null || return 1
  ln -sf "$QA_LIB/fake_camera_ffmpeg.sh" "$dir/ffmpeg"
  : >"$dir/device"
  echo "PATH=$dir:$PATH" "WOI_CAMERA=$dir/device" "WOI_DEBUG_CAMERA=1" "QA_CAMERA_CARD=$dir/card.jpg" \
    "QA_REAL_FFMPEG=$(command -v ffmpeg)"
}
