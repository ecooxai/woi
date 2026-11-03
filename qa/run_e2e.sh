#!/usr/bin/env bash
# End-to-end QA suite for the Woi release build (real network, real login).
#
#   qa/run_e2e.sh                       # all phases
#   PHASES="live direct" qa/run_e2e.sh  # subset: live direct barge compact ux media
#   QA_BIN=/path/to/bundle/woi qa/run_e2e.sh
#
# By default it builds HEAD into a throw-away git worktree (/tmp/woi-qa) so a
# parallel `flutter build` in the main checkout cannot swap the binary under
# the test. Set QA_BIN to skip that.
#
# Safety: the app runs with HOME=$QA_SANDBOX (relative paths and `~` resolve
# there; CODEX_HOME keeps the real login), clicks/typing land in a dedicated
# xterm in the screen centre, a neutral backdrop window hides the rest of the
# desktop from the app's screenshots, and an EXIT/INT/TERM trap restores the
# default source/sink, unloads the qa_* modules and kills everything started.
#
# Output: $QA_OUT (default /tmp/woi-qa-out): results.tsv, app-*.log,
# transcripts-*.txt, shots/*.jpg, run.log.
set -u
QA_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$QA_DIR/.." && pwd)
FIX=${WOI_FIXTURES:-$REPO/research/fixtures}
QFIX=$QA_DIR/fixtures
PHASES=${PHASES:-live direct barge compact ux}
export QA_OUT=${QA_OUT:-/tmp/woi-qa-out}
rm -rf "$QA_OUT" && mkdir -p "$QA_OUT/shots"
. "$QA_DIR/lib/common.sh"
LAT="python3 $QA_DIR/lib/latency.py"
SPK="$QA_OUT/spk.active"

WORKTREE=""
if [ -z "${QA_BIN:-}" ]; then
  WORKTREE=/tmp/woi-qa
  if [ ! -d "$WORKTREE" ]; then git -C "$REPO" worktree add --detach "$WORKTREE" HEAD >&2 || exit 1; fi
  (cd "$WORKTREE/app" && ${FLUTTER:-/home/a/.local/flutter/bin/flutter} build linux --release >"$QA_OUT/build.log" 2>&1) ||
    { echo "build failed, see $QA_OUT/build.log" >&2; exit 1; }
  QA_BIN=$WORKTREE/app/build/linux/x64/release/bundle/woi
fi
export QA_BIN

cleanup() {
  qa_teardown
  if [ -n "$WORKTREE" ] && [ "${QA_KEEP_WORKTREE:-0}" != 1 ]; then
    git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null && echo "worktree removed" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

printf 'mode\tfixture\tlatency_ms\tdialog\tcheck\tdetail\n' >"$QA_OUT/results.tsv"
result() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$QA_OUT/results.tsv"; qa_log "RESULT $*"; }

[ -s "$QFIX/11_long_story.wav" ] || echo "missing qa/fixtures (run research/.venv/bin/python qa/lib/make_qa_fixtures.py)" >&2

qa_make_sandbox || exit 1
qa_audio_setup || exit 1
qa_start_backdrop || exit 1
python3 "$QA_DIR/lib/speaker_monitor.py" qa_speaker.monitor "$QA_OUT/spk" >/dev/null 2>&1 &
qa_track_pid $!

APP_X=0 APP_Y=0 APP_W=650 APP_H=1000

# run_fixture MODE NAME WAV [approve|reject] [QUIET_S] [MAX_S]
# Plays WAV into the virtual mic, handles an approval dialog if one shows up,
# waits until the assistant has been quiet for QUIET_S, then screenshots.
# Sets LAST_LAT (ms from end of playback to first assistant audio, -1 = none)
# and LAST_DIALOG (0/1).
run_fixture() {
  local mode=$1 name=$2 wav=$3 action=${4:-approve} quiet=${5:-7} max=${6:-60}
  local tag="${mode}_${name}"
  local geom; geom=$(qa_app_geom)
  [ "$geom" != "${APP_W}x${APP_H}" ] && qa_log "app window is $geom (expected ${APP_W}x${APP_H}); re-placing"
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  local lines0; lines0=$(wc -l <"$APP_LOG")
  qa_log "play $tag"
  paplay -d qa_fixture_sink "$wav"
  local t_end; t_end=$(date +%s.%N)
  LAST_DIALOG=0
  local prev; prev=$(qa_brightness "$APP_WID") ; local t_last=$t_end waited=0
  while :; do
    sleep 0.5; waited=$((waited + 1))
    qa_app_alive || { qa_log "APP DIED during $tag"; break; }
    local b; b=$(qa_brightness "$APP_WID")
    if [ "$LAST_DIALOG" = 0 ] && awk -v b="$b" -v p="$prev" 'BEGIN{exit !(b < 0.62 * p)}'; then
      LAST_DIALOG=1
      sleep 0.6
      qa_shot "$APP_WID" "${tag}_dialog" >/dev/null
      qa_log "approval dialog in $tag after $((waited / 2))s (active window $(xdotool getactivewindow 2>/dev/null), app $APP_WID) -> $action"
      qa_focus_app
      case $action in
        reject) xdotool key Escape ;;
        approve) xdotool key Return ;;
        *) ;; # none: a dialog is not expected here (e.g. the context popover); just record it
      esac
      t_last=$(date +%s.%N)
      sleep 0.5; b=$(qa_brightness "$APP_WID")
    fi
    prev=$b
    if [ $waited -ge $((max * 2)) ]; then qa_log "max wait reached in $tag"; break; fi
    # done when there was a reply and nothing has been heard for $quiet s
    if [ "$($LAT first "$SPK" "$t_end")" != -1 ] && [ "$($LAT quiet "$SPK" "$t_last" "$quiet")" = 1 ] &&
       [ $waited -ge $((quiet * 2)) ]; then break; fi
  done
  LAST_LAT=$($LAT first "$SPK" "$t_end" 60)
  qa_shot "$APP_WID" "$tag" >/dev/null
  tail -n +$((lines0 + 1)) "$APP_LOG" | grep -vE '^\s*$' | cut -c1-400 >"$QA_OUT/log_$tag.txt"
  qa_log "$tag latency=${LAST_LAT}ms dialog=$LAST_DIALOG"
}

# The WM has no EWMH client list (wmctrl fails), so close via Escape in the
# viewer (the app hides it for reuse); also kill external players. No
# `xdotool windowclose`: that is XDestroyWindow, which kills the whole app.
close_viewers() {
  local w try
  for try in 1 2; do
    for w in $(qa_viewer_wids); do
      xdotool windowactivate --sync "$w" key Escape 2>/dev/null; sleep 0.5
    done
  done
  qa_kill_players
  sleep 1
}

# wait_viewer TAG: screenshot a viewer popup (app window >= 200 px, or an
# external player) if one opened. Echoes "window:<geom>", "external:<cmd>"
# or "no-viewer". A blank capture (< 3 colours) is reported as "blank".
wait_viewer() {
  local t=0 ws="" pl=""
  while [ $t -lt 10 ]; do
    ws=$(qa_viewer_wids); pl=$(pgrep -af "(vlc|mpv|xdg-open) $QA_SANDBOX" | head -1)
    [ -n "$ws$pl" ] && break; sleep 0.5; t=$((t + 1))
  done
  if [ -n "$ws" ]; then
    sleep 2
    local w; w=$(echo "$ws" | head -1)
    qa_shot_screen "$w" "$1_viewer" 700 >/dev/null
    local colours; colours=$(identify -format '%k' "$QA_OUT/shots/$1_viewer.png" 2>/dev/null || echo 0)
    echo "window:$(xdotool getwindowgeometry "$w" | awk '/Geometry/{print $2}')$( [ "${colours:-0}" -lt 3 ] && echo ' blank')"
  elif [ -n "$pl" ]; then
    sleep 2
    local pw; pw=$(xdotool search --onlyvisible --pid "${pl%% *}" 2>/dev/null | tail -1)
    [ -n "$pw" ] && qa_shot_screen "$pw" "$1_viewer" 700 >/dev/null
    echo "external:$(echo "${pl#* }" | cut -c1-60)"
  else
    echo "no-viewer"
  fi
}

prep_click_target() {
  qa_start_target || return 1
  TARGET_WID=$(cat "$QA_OUT/state.target_wid")
  xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null
  xdotool mousemove 1500 150   # away from the centre, so a click is visible
}

check_click() { # mode
  local loc; loc=$(xdotool getmouselocation --shell | tr '\n' ' ')
  eval "$(xdotool getmouselocation --shell)"
  local act; act=$(xdotool getactivewindow 2>/dev/null)
  local ok=FAIL
  [ $((X > 950 && X < 970 && Y > 530 && Y < 550)) = 1 ] && ok=PASS
  result "$1" 02_click_center "$LAST_LAT" "$LAST_DIALOG" "$ok" "mouse=$X,$Y active=$( [ "$act" = "$TARGET_WID" ] && echo target || echo "$act")"
  # make sure the typing test has the target focused even if the click missed
  [ "$act" = "$TARGET_WID" ] || xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null
}

check_type() {
  sleep 1
  local typed; typed=$(tr -d '\000' <"$QA_SANDBOX/typed.txt")
  qa_shot "$TARGET_WID" "$1_03_type_target" 500 >/dev/null
  local ok=FAIL; echo "$typed" | grep -qi 'hello,\? world' && ok=PASS
  result "$1" 03_type_hello_world "$LAST_LAT" "$LAST_DIALOG" "$ok" "typed=$(printf %q "$typed")"
}

log_has() { grep -qiE "$1" "$QA_OUT/log_$2.txt" 2>/dev/null; }

transcripts() { python3 "$QA_DIR/lib/summarize.py" "$QA_OUT/data-$1" >"$QA_OUT/transcripts-$1.txt" 2>&1; }

# barge MODE: long answer, then "Stop" while it is speaking
barge() {
  local mode=$1 tag="$1_barge"
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  qa_log "play $tag (long story)"
  paplay -d qa_fixture_sink "$QFIX/11_long_story.wav"
  local t_end; t_end=$(date +%s.%N) t=0
  while [ "$($LAT first "$SPK" "$t_end")" = -1 ] && [ $t -lt 60 ]; do sleep 0.5; t=$((t + 1)); done
  local lat; lat=$($LAT first "$SPK" "$t_end")
  sleep 5
  if [ "$($LAT speaking "$SPK" 1.0)" != 1 ]; then
    result "$mode" 11_barge_in "$lat" 0 FAIL "assistant was not speaking 5 s into the long answer"
    return
  fi
  qa_shot "$APP_WID" "${tag}_speaking" >/dev/null
  local t0; t0=$(date +%s.%N)
  paplay -d qa_fixture_sink "$FIX/10_stop.wav"
  # speech in 10_stop.wav starts 0.30 s into the file
  local onset; onset=$(echo "$t0 + 0.30" | bc)
  sleep 6
  local stop_ms; stop_ms=$($LAT stop "$SPK" "$onset" 1.5)
  local resumed; resumed=$($LAT first "$SPK" "$(echo "$onset + $stop_ms/1000 + 1.5" | bc)" 10)
  qa_shot "$APP_WID" "${tag}_after" >/dev/null
  local ok=FAIL; [ "$stop_ms" -le 500 ] && ok=PASS
  result "$mode" 11_barge_in "$lat" 0 "$ok" "audio stopped ${stop_ms}ms after 'Stop' onset; next audio after stop: ${resumed}ms"
}

# ------------------------------------------------------------------ phases
phase_live() {
  local mode=live
  prep_click_target
  qa_launch_app $mode || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  qa_wait_log 'gpt-live connected' 40 || { result $mode connect -1 0 FAIL "no gpt-live connection"; return 1; }
  result $mode connect - - PASS "$(grep -m1 'gpt-live connected' "$APP_LOG" | grep -oE 'session.started=[0-9]+ms')"
  sleep 2; qa_shot "$APP_WID" "${mode}_00_connected" >/dev/null

  run_fixture $mode 01_hello "$FIX/01_hello.wav"
  local ok=FAIL; log_has 'assistant:' ${mode}_01_hello && ok=PASS
  result $mode 01_hello "$LAST_LAT" "$LAST_DIALOG" $ok "$(grep -m1 'assistant:' "$QA_OUT/log_${mode}_01_hello.txt")"

  xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null; xdotool mousemove 1500 150
  run_fixture $mode 02_click_center "$FIX/02_click_center.wav"
  check_click $mode
  run_fixture $mode 03_type_hello_world "$FIX/03_type_hello_world.wav"
  check_type $mode

  run_fixture $mode 04_run_ls_home "$FIX/04_run_ls_home.wav" approve 8
  ok=FAIL; log_has 'tools=\[[^]]*run_bash' ${mode}_04_run_ls_home && ok=PASS
  result $mode 04_run_ls_home "$LAST_LAT" "$LAST_DIALOG" $ok "$(grep -m1 'delegation' "$QA_OUT/log_${mode}_04_run_ls_home.txt" | cut -c1-200)"

  run_fixture $mode 05_show_readme "$FIX/05_show_readme.wav"
  local v; v=$(wait_viewer ${mode}_05_show_readme)
  ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 05_show_readme "$LAST_LAT" "$LAST_DIALOG" $ok "$v; $(grep -m1 'delegation' "$QA_OUT/log_${mode}_05_show_readme.txt" | cut -c1-160)"
  close_viewers

  qa_reset_notes; local before; before=$(grep -c . "$QA_SANDBOX/notes.txt")
  run_fixture $mode 06_edit_notes "$FIX/06_edit_notes.wav" approve 8
  ok=FAIL; grep -qi 'buy milk' "$QA_SANDBOX/notes.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_notes "$LAST_LAT" "$LAST_DIALOG" $ok "lines $before -> $(grep -c . "$QA_SANDBOX/notes.txt")"
  # reject case: restore the original notes first, otherwise the model sees
  # "buy milk" is already there and answers without proposing an edit
  qa_reset_notes; cp "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_approve.txt"
  run_fixture $mode 06_edit_reject "$FIX/06_edit_notes.wav" reject 8
  ok=FAIL; cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_approve.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_reject "$LAST_LAT" "$LAST_DIALOG" $ok "file unchanged after Esc: $(cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_approve.txt" && echo yes || echo no)"

  run_fixture $mode 07_whats_on_screen "$FIX/07_whats_on_screen.wav"
  result $mode 07_whats_on_screen "$LAST_LAT" "$LAST_DIALOG" REVIEW "$(grep 'assistant:' "$QA_OUT/log_${mode}_07_whats_on_screen.txt" | tail -1 | cut -c1-200)"

  run_fixture $mode 08_complex_task "$FIX/08_complex_task.wav" approve 25 150
  ok=FAIL; log_has 'delegation' ${mode}_08_complex_task && ok=REVIEW
  result $mode 08_complex_task "$LAST_LAT" "$LAST_DIALOG" $ok "$(grep -m1 'delegation' "$QA_OUT/log_${mode}_08_complex_task.txt" | cut -c1-220)"

  run_fixture $mode 09_play_video "$FIX/09_play_video.wav"
  v=$(wait_viewer ${mode}_09_play_video)
  # VLC instead of the in-app viewer is a finding, not a failure of the fixture
  ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS; [[ $v == external:* ]] && ok=REVIEW
  result $mode 09_play_video "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers

  run_fixture $mode 10_stop "$FIX/10_stop.wav" none 5 20
  ok=FAIL; qa_app_alive && ok=PASS
  result $mode 10_stop "$LAST_LAT" "$LAST_DIALOG" $ok "idle 'Stop': app alive, reply: $(grep 'assistant:' "$QA_OUT/log_${mode}_10_stop.txt" | tail -1 | cut -c1-120)"

  # extra media types (QA fixtures)
  run_fixture $mode 13_show_image "$QFIX/13_show_image.wav"
  v=$(wait_viewer ${mode}_13_show_image); ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 13_show_image "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers
  run_fixture $mode 14_play_tone "$QFIX/14_play_tone.wav"
  v=$(wait_viewer ${mode}_14_play_tone); ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 14_play_tone "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers

  # typed input through the composer (text fallback)
  local lines0; lines0=$(wc -l <"$APP_LOG"); local t0; t0=$(date +%s.%N)
  qa_type_in_app "What is two plus two?"
  sleep 15
  local tl; tl=$($LAT first "$SPK" "$t0" 15)
  qa_shot "$APP_WID" "${mode}_15_typed_text" >/dev/null
  ok=FAIL; [ "$tl" != -1 ] && ok=PASS
  result $mode 15_typed_text "$tl" 0 $ok "reply audio after typed message: ${tl}ms"
  xdotool key Escape

  if [[ " $PHASES " == *" barge "* ]]; then barge $mode; fi
  transcripts $mode
  qa_stop_app
}

phase_direct() {
  local mode=direct
  prep_click_target
  qa_launch_app $mode '{"backendMode":"direct"}' || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  sleep 8  # the WebSocket backend logs nothing on connect
  qa_shot "$APP_WID" "${mode}_00_connected" >/dev/null
  run_fixture $mode 01_hello "$FIX/01_hello.wav"
  local ok=FAIL; [ "$LAST_LAT" != -1 ] && ok=PASS
  result $mode 01_hello "$LAST_LAT" "$LAST_DIALOG" $ok ""
  xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null; xdotool mousemove 1500 150
  run_fixture $mode 02_click_center "$FIX/02_click_center.wav"
  check_click $mode
  run_fixture $mode 03_type_hello_world "$FIX/03_type_hello_world.wav"
  check_type $mode
  run_fixture $mode 04_run_ls_home "$FIX/04_run_ls_home.wav" approve 8
  transcripts $mode
  ok=FAIL; grep -q 'TOOL run_bash.*success' "$QA_OUT/transcripts-$mode.txt" && ok=PASS
  result $mode 04_run_ls_home "$LAST_LAT" "$LAST_DIALOG" $ok "$(grep -m1 'TOOL run_bash' "$QA_OUT/transcripts-$mode.txt" | cut -c1-200)"
  run_fixture $mode 05_show_readme "$FIX/05_show_readme.wav"
  local v; v=$(wait_viewer ${mode}_05_show_readme); ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 05_show_readme "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers
  if [[ " $PHASES " == *" barge "* ]]; then barge $mode; fi
  transcripts $mode
  qa_stop_app
}

phase_compact() {
  local mode=compact
  qa_launch_app $mode '{"compressionThreshold":2000}' || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  qa_wait_log 'gpt-live connected' 40 || return 1
  sleep 2
  local i f n=0
  for f in "$FIX/01_hello.wav" "$QFIX/12_mars_facts.wav" "$FIX/07_whats_on_screen.wav" "$QFIX/12_mars_facts.wav" "$FIX/01_hello.wav" "$QFIX/12_mars_facts.wav"; do
    n=$((n + 1))
    run_fixture $mode "turn$n" "$f" approve 6
    result $mode "turn$n" "$LAST_LAT" 0 "$( [ "$LAST_LAT" != -1 ] && echo PASS || echo FAIL)" "$(basename "$f")"
  done
  sleep 5; qa_shot "$APP_WID" "${mode}_final" >/dev/null
  transcripts $mode
  local ok=FAIL
  grep -qE 'compaction applied|Context compacted' "$APP_LOG" "$QA_OUT/transcripts-$mode.txt" && ok=PASS
  result $mode banner - - $ok "$(grep -E 'compaction' "$APP_LOG" | head -2 | tr '\n' ' ' | cut -c1-250)"
  qa_stop_app
}

# media: viewers (text, image, video) and the edit approve/reject pair only
phase_media() {
  local mode=media v ok
  qa_launch_app $mode || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  qa_wait_log 'gpt-live connected' 40 || { result $mode connect -1 0 FAIL "no gpt-live connection"; return 1; }
  sleep 2
  run_fixture $mode 05_show_readme "$FIX/05_show_readme.wav"
  v=$(wait_viewer ${mode}_05_show_readme); ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 05_show_readme "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers
  run_fixture $mode 13_show_image "$QFIX/13_show_image.wav"
  v=$(wait_viewer ${mode}_13_show_image); ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 13_show_image "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers
  run_fixture $mode 09_play_video "$FIX/09_play_video.wav"
  v=$(wait_viewer ${mode}_09_play_video); ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS; [[ $v == external:* ]] && ok=REVIEW
  result $mode 09_play_video "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers
  qa_reset_notes; cp "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_orig.txt"
  run_fixture $mode 06_edit_reject "$FIX/06_edit_notes.wav" reject 8
  ok=FAIL; cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_orig.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_reject "$LAST_LAT" "$LAST_DIALOG" $ok "dialog=$LAST_DIALOG unchanged=$(cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_orig.txt" && echo yes || echo no)"
  cp "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_reject.txt"
  run_fixture $mode 06_edit_notes "$FIX/06_edit_notes.wav" approve 8
  ok=FAIL; grep -qi 'buy milk' "$QA_SANDBOX/notes.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_after_reject "$LAST_LAT" "$LAST_DIALOG" $ok "notes now: $(tr '\n' '|' <"$QA_SANDBOX/notes.txt")"
  transcripts $mode
  qa_stop_app
}

phase_ux() {
  local mode=ux
  qa_launch_app $mode || return 1
  qa_wait_log 'gpt-live connected' 40
  qa_place_app 100 40 1280 860; sleep 2
  qa_shot "$APP_WID" ux_desktop_empty 1280 >/dev/null
  run_fixture $mode hello "$FIX/01_hello.wav"
  APP_X=100 APP_Y=40 APP_W=1280 APP_H=860
  run_fixture $mode readme "$FIX/05_show_readme.wav"
  close_viewers
  qa_shot "$APP_WID" ux_desktop_chat 1280 >/dev/null
  qa_focus_app; xdotool key ctrl+comma; sleep 1.5; qa_shot "$APP_WID" ux_desktop_settings 1280 >/dev/null
  xdotool key Escape; sleep 1
  APP_W=400 APP_H=860
  qa_place_app 100 40 400 860; sleep 2
  qa_shot "$APP_WID" ux_phone_chat 400 >/dev/null
  qa_reset_notes
  run_fixture $mode phone_edit "$FIX/06_edit_notes.wav" reject 6
  qa_focus_app; xdotool key ctrl+comma; sleep 1.5; qa_shot "$APP_WID" ux_phone_settings 400 >/dev/null
  xdotool key Escape; sleep 1
  qa_focus_app; xdotool key ctrl+n; sleep 1.5; qa_shot "$APP_WID" ux_phone_new_chat 400 >/dev/null
  transcripts $mode
  qa_stop_app
}

for ph in $PHASES; do
  case $ph in
    live) phase_live ;;
    direct) phase_direct ;;
    compact) phase_compact ;;
    ux) phase_ux ;;
    media) phase_media ;;
    barge) ;; # runs inside live/direct
    *) echo "unknown phase $ph" >&2 ;;
  esac
done

echo "---- results ($QA_OUT/results.tsv)"
column -t -s $'\t' "$QA_OUT/results.tsv"
pass=$(awk -F'\t' 'NR>1 && $5=="PASS"' "$QA_OUT/results.tsv" | wc -l)
total=$(awk -F'\t' 'NR>1 && $5!="-"' "$QA_OUT/results.tsv" | wc -l)
echo "automated PASS: $pass / $total (REVIEW rows need a human look at the shots/transcripts)"
