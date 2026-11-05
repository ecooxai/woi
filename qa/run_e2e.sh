#!/usr/bin/env bash
# End-to-end QA suite for the Woi release build (real network, real login).
#
#   qa/run_e2e.sh                       # default phases
#   PHASES="live direct" qa/run_e2e.sh  # subset: live full direct barge compact ux media extras
#   PHASES=hello qa/run_e2e.sh          # smoke: 01_hello on Direct realtime only
#   PHASES=deleg DELEG_REPEAT=3 qa/run_e2e.sh  # 02 click + 08 delegate, repeated
#   QA_BIN=/path/to/bundle/woi qa/run_e2e.sh
#   QA_DISPLAY=:12 qa/run_e2e.sh        # test display (default :11; :0 is refused)
#   QA_PRIVATE_PW=1 qa/run_e2e.sh       # audio on a private, hardware-free PipeWire
#                                       # (qa/private_pw.sh; runtime in $QA_OUT-pw),
#                                       # torn down on exit; the host daemons are untouched
#
# Phases: live = fixtures 01-15 on gpt-live; full = the same list on Direct
# realtime (when gpt-live is unavailable); direct = the direct subset;
# compact = compaction (COMPACT_BACKEND=direct for Direct realtime); extras =
# typed checks of camera, send_keys copy, note auto-apply + undo and "what is
# in the video now" (EXTRAS_BACKEND=live for gpt-live, default direct).
# MEDIA_BACKEND=direct / UX_BACKEND=direct run media / ux on Direct realtime.
#
# By default it builds HEAD into a throw-away git worktree (/tmp/woi-qa) so a
# parallel `flutter build` in the main checkout cannot swap the binary under
# the test. Set QA_BIN to skip that.
#
# Safety: everything runs on the nested display $QA_DISPLAY, never the user's
# desktop. The app runs with HOME=$QA_SANDBOX (relative paths and `~` resolve
# there; CODEX_HOME keeps the real login), clicks/typing land in a dedicated
# xterm in the screen centre, the camera is a synthetic test card, a neutral backdrop window hides the rest of the
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
# Default: Direct realtime only (gpt-realtime-2.1 is free; gpt-live costs
# quota): add "live" explicitly to test gpt-live.
PHASES=${PHASES:-full barge compact ux media extras}
export QA_OUT=${QA_OUT:-/tmp/woi-qa-out}
QA_REALTIME_MODEL=${QA_REALTIME_MODEL:-gpt-realtime-2.1}
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

PRIVATE_PW=0
if [ "${QA_PRIVATE_PW:-0}" = 1 ]; then
  export QA_PW_BASE=${QA_PW_BASE:-${QA_OUT%/}-pw}
  pw_env=$("$QA_DIR/private_pw.sh" start) || { echo "private pipewire failed to start" >&2; exit 1; }
  PRIVATE_PW=1
  eval "$pw_env" # XDG_RUNTIME_DIR, PIPEWIRE_RUNTIME_DIR, PULSE_SERVER...: every client, the app included
  qa_log "audio: private pipewire at $PULSE_SERVER"
fi

cleanup() {
  qa_teardown
  [ "$PRIVATE_PW" = 1 ] && "$QA_DIR/private_pw.sh" stop
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

# Phone-width window on the left; the click/type target sits in the centre.
APP_X=0 APP_Y=0 APP_W=$((QA_CX - 200 < 650 ? QA_CX - 200 : 650)) APP_H=$((QA_SCREEN_H - 40 < 1000 ? QA_SCREEN_H - 40 : 1000))
park_pointer() { xdotool mousemove $((QA_SCREEN_W - 100)) 150; } # away from the centre, so a click is visible

# run_fixture MODE NAME WAV [approve|reject] [QUIET_S] [MAX_S]
# Plays WAV into the virtual mic, handles an approval dialog if one shows up,
# waits until the assistant has been quiet for QUIET_S, then screenshots.
# AI file/note edits show an inline diff card with an auto-apply countdown
# instead of a dialog: approve lets the countdown apply it, reject presses Esc.
# Sets LAST_LAT (ms from end of playback to first assistant audio, -1 = none),
# LAST_DIALOG (0/1: a dialog or an edit card was shown) and LAST_CARD (0/1).
run_fixture() {
  local mode=$1 name=$2 wav=$3 action=${4:-approve} quiet=${5:-7} max=${6:-60}
  local tag="${mode}_${name}"
  local geom; geom=$(qa_app_geom)
  [ "$geom" != "${APP_W}x${APP_H}" ] && qa_log "app window is $geom (expected ${APP_W}x${APP_H}); re-placing"
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  qa_audio_reassert
  local lines0; lines0=$(wc -l <"$APP_LOG")
  qa_log "play $tag"
  paplay -d qa_fixture_sink "$wav"
  local t_end; t_end=$(date +%s.%N)
  LAST_DIALOG=0 LAST_CARD=0
  local handled=0 shown cards cards_done=0
  local prev; prev=$(qa_brightness "$APP_WID") ; local t_last=$t_end waited=0
  while :; do
    sleep 0.5; waited=$((waited + 1))
    qa_app_alive || { qa_log "APP DIED during $tag"; break; }
    local b; b=$(qa_brightness "$APP_WID")
    # The app logs "approval dialog shown" (one per dialog: a delegated task
    # can ask several times); the brightness drop is a fallback for the first
    # (a fading-in dialog can dim over two samples and slip past it).
    shown=$(tail -n +$((lines0 + 1)) "$APP_LOG" | grep -c 'approval dialog shown')
    if [ "$shown" -gt "$handled" ] || { [ "$handled" = 0 ] && awk -v b="$b" -v p="$prev" 'BEGIN{exit !(b < 0.62 * p)}'; }; then
      handled=$((handled + 1)); [ "$shown" -gt "$handled" ] && handled=$shown
      LAST_DIALOG=1
      sleep 0.6
      qa_shot "$APP_WID" "${tag}_dialog$( [ $handled -gt 1 ] && echo $handled)" >/dev/null
      qa_log "approval dialog #$handled in $tag after $((waited / 2))s (active window $(xdotool getactivewindow 2>/dev/null), app $APP_WID) -> $action"
      qa_focus_app
      case $action in
        reject) xdotool key Escape ;;
        approve) xdotool key Return ;;
        *) ;; # none: a dialog is not expected here (e.g. the context popover); just record it
      esac
      t_last=$(date +%s.%N)
      sleep 0.5; b=$(qa_brightness "$APP_WID")
    fi
    cards=$(tail -n +$((lines0 + 1)) "$APP_LOG" | grep -c 'edit preview shown')
    if [ "$cards" -gt "$cards_done" ]; then
      cards_done=$cards; LAST_DIALOG=1 LAST_CARD=1
      sleep 0.6
      qa_shot "$APP_WID" "${tag}_card$( [ "$cards" -gt 1 ] && echo "$cards")" >/dev/null
      qa_log "edit card #$cards in $tag after $((waited / 2))s -> $action"
      if [ "$action" = reject ]; then qa_focus_app; xdotool key Escape; fi
      t_last=$(date +%s.%N)
    fi
    prev=$b
    if [ $waited -ge $((max * 2)) ]; then qa_log "max wait reached in $tag"; break; fi
    # WAIT_LOG: not done before this pattern shows up in the app log (e.g. the
    # end of a long delegation that is silent for a while)
    if [ -n "${WAIT_LOG:-}" ] && ! tail -n +$((lines0 + 1)) "$APP_LOG" | grep -qE "$WAIT_LOG"; then continue; fi
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
  park_pointer
}

# "|word|word..." from the titles of visible top-level windows (words of 5+
# letters), plus "browser" when a web browser is visible.
visible_words() {
  local wid names="" classes=""
  for wid in $(xdotool search --onlyvisible --name . 2>/dev/null); do
    names+=" $(xdotool getwindowname "$wid" 2>/dev/null)"
    classes+=" $(xprop -id "$wid" WM_CLASS 2>/dev/null)"
  done
  echo "$names" | grep -oE '[A-Za-z]{5,}' | grep -viE '^(window|untitled|google|mozilla)$' |
    sort -u | sed 's/^/|/' | tr -d '\n'
  echo "$classes" | grep -qiE 'chrom|firefox|brave|vivaldi' && echo -n '|browser'
}

# X input idle time in ms, reported with the click/type checks (pointer or
# focus moved by something else during the fixture fails them without an app
# fault).
user_idle() { command -v xprintidle >/dev/null && echo " xidle=$(xprintidle)ms"; }

check_click() { # mode
  local loc; loc=$(xdotool getmouselocation --shell | tr '\n' ' ')
  eval "$(xdotool getmouselocation --shell)"
  local act; act=$(xdotool getactivewindow 2>/dev/null)
  local ok=FAIL
  [ $((X > QA_CX - 10 && X < QA_CX + 10 && Y > QA_CY - 10 && Y < QA_CY + 10)) = 1 ] && ok=PASS
  result "$1" 02_click_center "$LAST_LAT" "$LAST_DIALOG" "$ok" "mouse=$X,$Y active=$( [ "$act" = "$TARGET_WID" ] && echo target || echo "$act")$(user_idle)"
  # make sure the typing test has the target focused even if the click missed
  [ "$act" = "$TARGET_WID" ] || xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null
}

check_type() {
  sleep 1
  local typed; typed=$(tr -d '\000' <"$QA_SANDBOX/typed.txt")
  qa_shot "$TARGET_WID" "$1_03_type_target" 500 >/dev/null
  local ok=FAIL; echo "$typed" | grep -qi 'hello,\? world' && ok=PASS
  result "$1" 03_type_hello_world "$LAST_LAT" "$LAST_DIALOG" "$ok" "typed=$(printf %q "$typed") active=$(a=$(xdotool getactivewindow 2>/dev/null); [ "$a" = "$TARGET_WID" ] && echo target || echo "$a")$(user_idle)"
}

log_has() { grep -qiE "$1" "$QA_OUT/log_$2.txt" 2>/dev/null; }

# typed_turn TAG TEXT [QUIET_S] [MAX_S]: sends TEXT through the composer, then
# waits like run_fixture (reply audio, then QUIET_S of silence). Sets
# LAST_LAT (ms from Enter to the first reply audio) and writes log_TAG.txt.
typed_turn() {
  local tag=$1 text=$2 quiet=${3:-6} max=${4:-60}
  local lines0; lines0=$(wc -l <"$APP_LOG")
  qa_audio_reassert
  qa_log "type $tag: $text"
  qa_type_in_app "$text"
  local t0; t0=$(date +%s.%N) waited=0
  while :; do
    sleep 0.5; waited=$((waited + 1))
    qa_app_alive || { qa_log "APP DIED during $tag"; break; }
    [ $waited -ge $((max * 2)) ] && { qa_log "max wait reached in $tag"; break; }
    if [ "$($LAT first "$SPK" "$t0")" != -1 ] && [ "$($LAT quiet "$SPK" "$t0" "$quiet")" = 1 ] &&
       [ $waited -ge $((quiet * 2)) ]; then break; fi
  done
  LAST_LAT=$($LAT first "$SPK" "$t0" 60)
  qa_shot "$APP_WID" "$tag" >/dev/null
  tail -n +$((lines0 + 1)) "$APP_LOG" | grep -vE '^\s*$' | cut -c1-400 >"$QA_OUT/log_$tag.txt"
  qa_log "$tag latency=${LAST_LAT}ms"
}

# Last assistant message text in the saved conversation of MODE.
last_reply() {
  python3 - "$QA_OUT/data-$1" <<'PY'
import glob, json, os, sys
fs = sorted(glob.glob(os.path.join(sys.argv[1], "woi", "conversations", "*.json")), key=os.path.getmtime)
msgs = json.load(open(fs[-1])).get("messages", []) if fs else []
said = [m.get("text") or "" for m in msgs if m.get("kind") == "assistant" and m.get("text")]
print((said[-1] if said else "").replace("\n", " ")[:300])
PY
}

# Tool calls (name and args) after the last user message of MODE.
recent_tools() {
  python3 - "$QA_OUT/data-$1" <<'PY'
import glob, json, os, sys
fs = sorted(glob.glob(os.path.join(sys.argv[1], "woi", "conversations", "*.json")), key=os.path.getmtime)
msgs = json.load(open(fs[-1])).get("messages", []) if fs else []
last_user = max([i for i, m in enumerate(msgs) if m.get("kind") == "user"] or [0])
# tool calls, and context images attached to the turn ([img:media "Image from the viewer"])
print(" ".join(f"{m['tool'].get('name')}{m['tool'].get('args', '')[:80]}->{m['tool'].get('status')}" if m.get("tool")
               else f"[img:{(m.get('meta') or {}).get('imageKind', '?')} {m.get('text', '')[:40]!r}]"
               for m in msgs[last_user:] if m.get("tool") or "image" in m))
PY
}

transcripts() { python3 "$QA_DIR/lib/summarize.py" "$QA_OUT/data-$1" >"$QA_OUT/transcripts-$1.txt" 2>&1; }

# barge MODE: long answer, then "Stop" while it is speaking
barge() {
  local mode=$1 tag="$1_barge"
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  if [ "${BARGE_PRE:-0}" = 1 ]; then
    # iter4c sequence: the request itself interrupts a reply that is playing
    qa_log "play $tag pre (long story, then interrupt it with the same request)"
    paplay -d qa_fixture_sink "$QFIX/11_long_story.wav"
    local tp; tp=$(date +%s.%N) t=0
    while [ "$($LAT first "$SPK" "$tp")" = -1 ] && [ $t -lt 60 ]; do sleep 0.5; t=$((t + 1)); done
    sleep 3
  fi
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
  local ok=FAIL note=""
  # Detection alone needs 80 ms of voiced audio, so 0 means the reply had
  # already gone silent before "Stop" (a stalled or finished reply), not a
  # barge-in.
  if [ "$stop_ms" -le 0 ]; then note=" (reply was already silent before the onset)"
  elif [ "$stop_ms" -le 500 ]; then ok=PASS; fi
  result "$mode" 11_barge_in "$lat" 0 "$ok" "audio stopped ${stop_ms}ms after 'Stop' onset$note; next audio after stop: ${resumed}ms"
}

# ------------------------------------------------------------------ phases
# phase_live [live|full]: fixtures 01-15 on gpt-live (live) or Direct realtime
# (full: the same list when gpt-live is unavailable).
phase_live() {
  local mode=${1:-live}
  prep_click_target
  if [ $mode = live ]; then
    qa_launch_app $mode || return 1
    qa_place_app $APP_X $APP_Y $APP_W $APP_H
    if ! qa_wait_log 'gpt-live connected' 40; then
      sleep 2; qa_focus_app; xdotool key ctrl+2; sleep 1; qa_shot "$APP_WID" "${mode}_00_no_connection" >/dev/null
      result $mode connect -1 0 FAIL "no gpt-live connection (see shots/${mode}_00_no_connection.jpg)"
      qa_stop_app; return 1
    fi
    result $mode connect - - PASS "$(grep -m1 'gpt-live connected' "$APP_LOG" | grep -oE 'offer=[0-9]+ms?')"
  else
    qa_launch_app $mode '{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1
    qa_place_app $APP_X $APP_Y $APP_W $APP_H
    sleep 8 # the WebSocket backend logs nothing on connect
  fi
  sleep 2; qa_shot "$APP_WID" "${mode}_00_connected" >/dev/null

  run_fixture $mode 01_hello "$FIX/01_hello.wav"
  local ok=FAIL
  if [ $mode = live ]; then log_has 'assistant:' ${mode}_01_hello && ok=PASS; else [ "$LAST_LAT" != -1 ] && ok=PASS; fi
  result $mode 01_hello "$LAST_LAT" "$LAST_DIALOG" $ok "$(last_reply $mode | cut -c1-120)"

  xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null; park_pointer
  run_fixture $mode 02_click_center "$FIX/02_click_center.wav"
  check_click $mode
  run_fixture $mode 03_type_hello_world "$FIX/03_type_hello_world.wav"
  check_type $mode

  run_fixture $mode 04_run_ls_home "$FIX/04_run_ls_home.wav" approve 8
  ok=FAIL
  if [ $mode = live ]; then
    log_has 'tools=\[[^]]*run_bash' ${mode}_04_run_ls_home && ok=PASS
    result $mode 04_run_ls_home "$LAST_LAT" "$LAST_DIALOG" $ok "$(grep -m1 'delegation' "$QA_OUT/log_${mode}_04_run_ls_home.txt" | cut -c1-200)"
  else
    local tl; tl=$(recent_tools $mode); [[ $tl == *run_bash*success* ]] && ok=PASS
    result $mode 04_run_ls_home "$LAST_LAT" "$LAST_DIALOG" $ok "$(echo "$tl" | cut -c1-200)"
  fi

  run_fixture $mode 05_show_readme "$FIX/05_show_readme.wav"
  local v; v=$(wait_viewer ${mode}_05_show_readme)
  ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 05_show_readme "$LAST_LAT" "$LAST_DIALOG" $ok "$v; $(grep -m1 'delegation' "$QA_OUT/log_${mode}_05_show_readme.txt" | cut -c1-160)"
  close_viewers

  qa_reset_notes; local before; before=$(grep -c . "$QA_SANDBOX/notes.txt")
  run_fixture $mode 06_edit_notes "$FIX/06_edit_notes.wav" approve 8
  ok=FAIL; grep -qi 'buy milk' "$QA_SANDBOX/notes.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_notes "$LAST_LAT" "$LAST_DIALOG" $ok "card=$LAST_CARD $(grep -m1 -oE 'edit (applied|rejected)[^\"]*' "$QA_OUT/log_${mode}_06_edit_notes.txt") lines $before -> $(grep -c . "$QA_SANDBOX/notes.txt")"
  # typed "undo that" restores the backup of the applied edit
  typed_turn ${mode}_06_undo "undo that" 4 12
  ok=FAIL; grep -qi 'buy milk' "$QA_SANDBOX/notes.txt" || ok=PASS
  result $mode 06_undo_typed "$LAST_LAT" 0 $ok "$(grep -m1 -E '^undo' "$QA_OUT/log_${mode}_06_undo.txt" | cut -c1-120); lines now $(grep -c . "$QA_SANDBOX/notes.txt")"
  # reject case: restore the original notes first, otherwise the model sees
  # "buy milk" is already there and answers without proposing an edit
  qa_reset_notes; cp "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_approve.txt"
  run_fixture $mode 06_edit_reject "$FIX/06_edit_notes.wav" reject 8
  ok=FAIL; cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_approve.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_reject "$LAST_LAT" "$LAST_DIALOG" $ok "card=$LAST_CARD file unchanged after Esc: $(cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_approve.txt" && echo yes || echo no)"

  # Other windows on the real :0 display (a browser someone is using) are on
  # screen too, so their titles count as visible things as well.
  local seen; seen=$(visible_words)
  run_fixture $mode 07_whats_on_screen "$FIX/07_whats_on_screen.wav"
  # The reply must name something that is really on screen: the target xterm
  # (title WOI-QA-TARGET, banner "Woi QA click/type target", the typed
  # "hello world"), the backdrop banner, Woi's own window / conversation, or
  # another visible window.
  local said; said=$(grep 'assistant:' "$QA_OUT/log_${mode}_07_whats_on_screen.txt" | tr '\n' ' ')
  [ -n "$said" ] || said=$(last_reply $mode)
  ok=FAIL
  echo "$said" | grep -qiE "hello,? world|WOI-QA|QA (target|run)|click/type|backdrop|run in progress|terminal|xterm|woi|conversation|chat|notes|buy milk$seen" && ok=PASS
  result $mode 07_whats_on_screen "$LAST_LAT" "$LAST_DIALOG" $ok "$(echo "$said" | cut -c1-200)"

  # delegate_task (gpt-6-luna, the default; never sol in tests) writes the script via write_file (approval),
  # may ask to run a check (approval), then the result is voiced. The
  # delegation is silent for minutes, so wait for its log line, then quiet.
  local py0; py0=$(ls "$QA_SANDBOX"/*.py 2>/dev/null | wc -l)
  if [ $mode = live ]; then
    WAIT_LOG='live delegation "[^"]*complex task' run_fixture $mode 08_complex_task "$FIX/08_complex_task.wav" approve 10 300
  else
    WAIT_LOG='edit (applied|rejected)|delegat.*(fail|error)' run_fixture $mode 08_complex_task "$FIX/08_complex_task.wav" approve 12 300
  fi
  local py1; py1=$(ls -t "$QA_SANDBOX"/*.py 2>/dev/null | head -1)
  local dl said08
  if [ $mode = live ]; then
    dl=$(grep -m1 'live delegation "[^"]*complex task' "$QA_OUT/log_${mode}_08_complex_task.txt")
    said08=$(sed -n '/live delegation "[^"]*complex task/,$p' "$QA_OUT/log_${mode}_08_complex_task.txt" | grep -m1 'assistant:' | cut -c1-120)
  else
    dl=$(recent_tools $mode); said08=$(last_reply $mode | cut -c1-120)
  fi
  ok=FAIL
  [[ $dl == *delegate_task* ]] && [ "$(ls "$QA_SANDBOX"/*.py 2>/dev/null | wc -l)" -gt "$py0" ] && [ "$LAST_DIALOG" = 1 ] && [ -n "$said08" ] && ok=PASS
  result $mode 08_complex_task "$LAST_LAT" "$LAST_DIALOG" $ok "file=$(basename "${py1:-none}") $(echo "$dl" | grep -oE 'tools=\[[^]]*\]|tools_done=[0-9]+ms|delegate_task[^ ]*' | head -2 | tr '\n' ' ')reply: $said08"

  run_fixture $mode 09_play_video "$FIX/09_play_video.wav"
  v=$(wait_viewer ${mode}_09_play_video)
  # in-app (fvp) viewer window only; an external player is a failure
  ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 09_play_video "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers

  run_fixture $mode 10_stop "$FIX/10_stop.wav" none 5 20
  ok=FAIL; qa_app_alive && ok=PASS
  result $mode 10_stop "$LAST_LAT" "$LAST_DIALOG" $ok "idle 'Stop': app alive, reply: $(last_reply $mode | cut -c1-120)"

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

# Smoke: Direct realtime, 01_hello only (heard + spoken reply + latency).
# Repeat the slow/flaky pair: 02_click_center (latency) and 08_complex_task
# (delegate must save the script). DELEG_REPEAT times (default 3), Direct realtime.
phase_deleg() {
  local mode=deleg n=${DELEG_REPEAT:-3} i ok
  prep_click_target
  qa_launch_app $mode '{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  sleep 8
  for i in $(seq 1 "$n"); do
    xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null; park_pointer
    run_fixture $mode 02_click_center "$FIX/02_click_center.wav"
    check_click $mode
    local py0; py0=$(ls "$QA_SANDBOX"/*.py 2>/dev/null | wc -l)
    WAIT_LOG='edit (applied|rejected)|delegat.*(fail|error)' run_fixture $mode 08_complex_task "$FIX/08_complex_task.wav" approve 12 300
    local py1; py1=$(ls -t "$QA_SANDBOX"/*.py 2>/dev/null | head -1)
    local dl; dl=$(recent_tools $mode); local said08; said08=$(last_reply $mode | cut -c1-100)
    ok=FAIL
    [[ $dl == *delegate_task* ]] && [ "$(ls "$QA_SANDBOX"/*.py 2>/dev/null | wc -l)" -gt "$py0" ] && [ -n "$said08" ] && ok=PASS
    result $mode "08_complex_task#$i" "$LAST_LAT" "$LAST_DIALOG" $ok "file=$(basename "${py1:-none}") $(echo "$dl" | grep -oE 'delegate_task.{0,160}' | head -1) reply: $said08"
    # a fresh sandbox file count per round: move this round's scripts aside
    mkdir -p "$QA_SANDBOX/.done$i"; mv "$QA_SANDBOX"/*.py "$QA_SANDBOX/.done$i/" 2>/dev/null
  done
  transcripts $mode
  qa_stop_app
}

phase_hello() {
  local mode=hello
  qa_launch_app $mode '{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  sleep 8  # the WebSocket backend logs nothing on connect
  run_fixture $mode 01_hello "$FIX/01_hello.wav"
  local ok=FAIL; [ "$LAST_LAT" != -1 ] && ok=PASS
  result $mode 01_hello "$LAST_LAT" "$LAST_DIALOG" $ok ""
  transcripts $mode
  qa_stop_app
}

phase_direct() {
  local mode=direct
  prep_click_target
  qa_launch_app $mode '{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  sleep 8  # the WebSocket backend logs nothing on connect
  qa_shot "$APP_WID" "${mode}_00_connected" >/dev/null
  run_fixture $mode 01_hello "$FIX/01_hello.wav"
  local ok=FAIL; [ "$LAST_LAT" != -1 ] && ok=PASS
  result $mode 01_hello "$LAST_LAT" "$LAST_DIALOG" $ok ""
  xdotool windowactivate --sync "$TARGET_WID" 2>/dev/null; park_pointer
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
  if [ "${COMPACT_BACKEND:-direct}" = direct ]; then
    qa_launch_app $mode '{"compressionThreshold":2000,"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1
    qa_place_app $APP_X $APP_Y $APP_W $APP_H
    sleep 8
  else
    qa_launch_app $mode '{"compressionThreshold":2000}' || return 1
    qa_place_app $APP_X $APP_Y $APP_W $APP_H
    qa_wait_log 'gpt-live connected' 40 || { result $mode connect -1 0 FAIL "no gpt-live connection"; qa_stop_app; return 1; }
  fi
  sleep 2
  local i f n=0
  # Compaction only runs once the context is over the threshold AND the older
  # turns would free >= 25% of the conversational tokens, so with short replies
  # six turns are sometimes not enough: keep talking (up to 10 turns) until it
  # has been applied.
  for f in "$FIX/01_hello.wav" "$QFIX/12_mars_facts.wav" "$FIX/07_whats_on_screen.wav" "$QFIX/12_mars_facts.wav" "$FIX/01_hello.wav" "$QFIX/12_mars_facts.wav" \
           "$FIX/07_whats_on_screen.wav" "$QFIX/12_mars_facts.wav" "$FIX/01_hello.wav" "$QFIX/12_mars_facts.wav"; do
    [ $n -ge 6 ] && grep -qE 'compaction applied|Context compacted' "$APP_LOG" && break
    n=$((n + 1))
    run_fixture $mode "turn$n" "$f" approve 6
    result $mode "turn$n" "$LAST_LAT" 0 "$( [ "$LAST_LAT" != -1 ] && echo PASS || echo FAIL)" "$(basename "$f")"
  done
  sleep 5; qa_shot "$APP_WID" "${mode}_final" >/dev/null
  transcripts $mode
  local ok=FAIL
  grep -qE 'compaction applied|Context compacted' "$APP_LOG" "$QA_OUT/transcripts-$mode.txt" && ok=PASS
  result $mode banner - - $ok "after $n turns: $(grep -E 'compaction' "$APP_LOG" | head -2 | tr '\n' ' ' | cut -c1-250)"
  qa_stop_app
}

# media: viewers (text, image, video) and the edit approve/reject pair only
phase_media() {
  local mode=media v ok
  if [ "${MEDIA_BACKEND:-direct}" = direct ]; then
    qa_launch_app $mode '{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1
    qa_place_app $APP_X $APP_Y $APP_W $APP_H
    sleep 8
  else
    qa_launch_app $mode || return 1
    qa_place_app $APP_X $APP_Y $APP_W $APP_H
    qa_wait_log 'gpt-live connected' 40 || { result $mode connect -1 0 FAIL "no gpt-live connection"; qa_stop_app; return 1; }
  fi
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
  v=$(wait_viewer ${mode}_09_play_video); ok=FAIL; [[ $v == window:* && $v != *blank ]] && ok=PASS
  result $mode 09_play_video "$LAST_LAT" "$LAST_DIALOG" $ok "$v"
  close_viewers
  qa_reset_notes; cp "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_orig.txt"
  run_fixture $mode 06_edit_reject "$FIX/06_edit_notes.wav" reject 8
  ok=FAIL; cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_orig.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_reject "$LAST_LAT" "$LAST_DIALOG" $ok "card=$LAST_CARD unchanged=$(cmp -s "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_orig.txt" && echo yes || echo no)"
  cp "$QA_SANDBOX/notes.txt" "$QA_OUT/notes_after_reject.txt"
  run_fixture $mode 06_edit_notes "$FIX/06_edit_notes.wav" approve 8
  ok=FAIL; grep -qi 'buy milk' "$QA_SANDBOX/notes.txt" && [ "$LAST_DIALOG" = 1 ] && ok=PASS
  result $mode 06_edit_after_reject "$LAST_LAT" "$LAST_DIALOG" $ok "notes now: $(tr '\n' '|' <"$QA_SANDBOX/notes.txt")"
  transcripts $mode
  qa_stop_app
}

phase_ux() {
  local mode=ux
  if [ "${UX_BACKEND:-direct}" = direct ]; then
    qa_launch_app $mode '{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1; sleep 8
  else
    qa_launch_app $mode || return 1
    qa_wait_log 'gpt-live connected' 40
  fi
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

# livebarge / directbarge: only the barge-in measurement (quick iteration)
phase_barge_only() {
  local mode=$1
  if [ "$mode" = live ]; then
    qa_launch_app $mode || return 1
    qa_wait_log 'gpt-live connected' 40 || { result $mode connect -1 0 FAIL "no gpt-live connection"; return 1; }
  else
    qa_launch_app $mode '{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' || return 1
    sleep 8
  fi
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  sleep 2
  if [ "${BARGE_VIEWER:-0}" = 1 ]; then
    # open (and close) a media viewer first, as the full live phase does
    run_fixture $mode 13_show_image "$QFIX/13_show_image.wav"
    local v; v=$(wait_viewer ${mode}_13_show_image); local vok=FAIL; [[ $v == window:* ]] && vok=PASS
    result $mode 13_show_image "$LAST_LAT" "$LAST_DIALOG" $vok "$v"
    close_viewers
  fi
  barge $mode
  sleep 3
  transcripts $mode
  qa_stop_app
}

# wait_since LINES0 REGEX SECS: REGEX in the app log after line LINES0.
wait_since() {
  local t=0
  until tail -n +$(($1 + 1)) "$APP_LOG" | grep -qE "$2"; do
    sleep 0.5; t=$((t + 1))
    qa_app_alive || return 1
    [ $t -ge $(($3 * 2)) ] && return 1
  done
}

# Text of the last user message of MODE (shows what a typed turn sent).
last_user() {
  python3 - "$QA_OUT/data-$1" <<'PY'
import glob, json, os, sys
fs = sorted(glob.glob(os.path.join(sys.argv[1], "woi", "conversations", "*.json")), key=os.path.getmtime)
msgs = json.load(open(fs[-1])).get("messages", []) if fs else []
said = [m.get("text") or "" for m in msgs if m.get("kind") == "user"]
print((said[-1] if said else "").replace("\n", " ")[:400])
PY
}

# Markdown of the newest note of MODE.
note_text() {
  python3 - "$QA_OUT/data-$1" <<'PY'
import glob, json, os, sys
fs = sorted(glob.glob(os.path.join(sys.argv[1], "woi", "notes", "*.json")), key=os.path.getmtime)
n = json.load(open(fs[-1])) if fs else {}
print(n.get("content") or n.get("text") or n.get("markdown") or "")
PY
}

# extras: typed checks of the newer features on one app instance.
#   camera   synthetic test card; "what do you see" must name what is on it
#   copy     send_keys copy in a zenity editor, checked with xclip
#   note     an AI note edit auto-applies after the 5 s countdown; typed
#            "undo that" restores the note
#   video    a test-pattern video in the viewer; "what is happening in the
#            video right now" answers from the current frame
phase_extras() {
  local mode=extras ok r settings='{"backendMode":"direct","realtimeModel":"'"$QA_REALTIME_MODEL"'"}' cam
  [ "${EXTRAS_BACKEND:-direct}" = live ] && settings=''
  cam=$(qa_fake_camera) || { result $mode camera - - FAIL "could not build the test card"; return 1; }
  # shellcheck disable=SC2086
  qa_launch_app $mode "$settings" $cam || return 1
  qa_place_app $APP_X $APP_Y $APP_W $APP_H
  if [ -z "$settings" ]; then
    qa_wait_log 'gpt-live connected' 40 || { result $mode connect -1 0 FAIL "no gpt-live connection"; qa_stop_app; return 1; }
  else
    sleep 8
  fi

  # --- camera
  qa_wait_log 'debug camera ->' 20
  sleep 2; qa_shot "$APP_WID" ${mode}_camera_on >/dev/null
  typed_turn ${mode}_camera "What do you see on the camera right now?" 6 60
  r=$(last_reply $mode); ok=FAIL
  [ "$(echo "$r" | grep -ciE 'red|circle|blue|square|woi|qa camera')" -gt 0 ] && ok=PASS
  result $mode camera_what_do_you_see "$LAST_LAT" 0 $ok "$(grep -m1 -o 'debug camera -> .*' "$APP_LOG" | cut -c1-60); reply: $(echo "$r" | cut -c1-160)"
  qa_focus_app; xdotool key ctrl+k; sleep 0.3
  typed_turn ${mode}_camera_off "Turn the camera off." 4 40

  # --- send_keys copy
  local ed="$QA_SANDBOX/qa_editor.txt" want="WOI QA copy check $(date +%s)" zpid zw t=0
  printf '%s\n' "$want" >"$ed"
  zenity --text-info --editable --title WOI-QA-EDITOR --width 500 --height 300 --filename "$ed" >/dev/null 2>&1 &
  zpid=$!; qa_track_pid $zpid
  while [ -z "${zw:-}" ] && [ $t -lt 20 ]; do sleep 0.5; t=$((t + 1)); zw=$(xdotool search --onlyvisible --name '^WOI-QA-EDITOR$' 2>/dev/null | head -1); done
  if [ -n "${zw:-}" ]; then
    xdotool windowmove "$zw" $((QA_CX + 50)) 120
    printf 'QA-CLIPBOARD-PRESET' | xclip -selection clipboard -loops 1 & local xcp=$!
    sleep 0.3
    xdotool windowactivate --sync "$zw"; sleep 0.5
    # click into the text, select all (the app copies the selection)
    eval "$(xdotool getwindowgeometry --shell "$zw")"
    xdotool mousemove $((X + 100)) $((Y + 60)) click 1; sleep 0.3; xdotool key ctrl+a; sleep 0.5
    park_pointer
    typed_turn ${mode}_copy "Copy the selected text in the editor window." 5 45
    sleep 1
    local clip; clip=$(timeout 3 xclip -o -selection clipboard 2>/dev/null)
    ok=FAIL; [ "$clip" = "$want" ] && ok=PASS
    result $mode send_keys_copy "$LAST_LAT" 0 $ok "clipboard='$(echo "$clip" | head -1 | cut -c1-60)' tools: $(recent_tools $mode | cut -c1-160)"
    kill $xcp 2>/dev/null
  else
    result $mode send_keys_copy - - FAIL "zenity editor window did not show"
  fi
  kill $zpid 2>/dev/null

  # --- note edit: auto-apply after the countdown, then typed "undo that"
  qa_focus_app; xdotool key ctrl+1; sleep 1 # Note tab
  qa_shot "$APP_WID" ${mode}_note_tab >/dev/null
  local before l0; before=$(note_text $mode)
  l0=$(wc -l <"$APP_LOG")
  typed_turn ${mode}_note "Add a checklist item 'buy oat milk' to my note." 8 60
  local shown applied
  wait_since $l0 'edit preview shown' 5 && shown=yes || shown=no
  wait_since $l0 'edit applied' 12 && applied=yes || applied=no
  sleep 1.5 # autosave
  local after; after=$(note_text $mode)
  ok=FAIL; [ $applied = yes ] && echo "$after" | grep -qi 'oat milk' && ok=PASS
  result $mode note_auto_apply "$LAST_LAT" 1 $ok "card=$shown $(tail -n +$((l0 + 1)) "$APP_LOG" | grep -m1 -oE 'edit preview shown: [^(]*\([^)]*\)' | cut -c20-120) applied=$applied; note has oat milk: $(echo "$after" | grep -qi 'oat milk' && echo yes || echo no)"
  qa_shot "$APP_WID" ${mode}_note_applied >/dev/null
  typed_turn ${mode}_note_undo "undo that" 4 12
  sleep 1.5
  after=$(note_text $mode)
  ok=FAIL; echo "$after" | grep -qi 'oat milk' || ok=PASS
  result $mode note_undo_typed "$LAST_LAT" 0 $ok "$(grep -m1 -iE 'undo' "$QA_OUT/log_${mode}_note_undo.txt" | cut -c1-100); oat milk gone: $( [ $ok = PASS ] && echo yes || echo no)"
  qa_focus_app; xdotool key ctrl+2; sleep 0.5 # back to Chat

  # --- current video frame
  local vid="$QA_SANDBOX/qa_testcard.mp4"
  [ -s "$vid" ] || ffmpeg -loglevel error -y -f lavfi -i testsrc=size=640x360:rate=25 -t 180 \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p "$vid"
  typed_turn ${mode}_video_open "Play the video qa_testcard.mp4 from my home folder in the viewer." 5 45
  local v; v=$(wait_viewer ${mode}_video_open)
  result $mode video_open "$LAST_LAT" 0 "$( [[ $v == window:* && $v != *blank ]] && echo PASS || echo FAIL)" "$v"
  sleep 4
  typed_turn ${mode}_video_now "What's happening in the video right now?" 6 60
  r=$(last_reply $mode); local u; u=$(last_user $mode)
  ok=FAIL
  local rt; rt=$(recent_tools $mode)
  [[ $u == *"attached the media"* || $rt == *inspect_media* || $rt == *"[img:media"* ]] &&
    [ "$(echo "$r" | grep -ciE 'test|pattern|colou?r|bar|number|count|frame|gradient')" -gt 0 ] && ok=PASS
  result $mode video_current_frame "$LAST_LAT" 0 $ok "context: $(echo "$rt" | cut -c1-80) reply: $(echo "$r" | cut -c1-160)"
  close_viewers

  transcripts $mode
  qa_stop_app
}

for ph in $PHASES; do
  case $ph in
    live) phase_live live ;;
    full) phase_live full ;;
    extras) phase_extras ;;
    direct) phase_direct ;;
    hello) phase_hello ;;
    deleg) phase_deleg ;;
    compact) phase_compact ;;
    ux) phase_ux ;;
    media) phase_media ;;
    barge) ;; # runs inside live/direct
    livebarge) phase_barge_only live ;;
    directbarge) phase_barge_only direct ;;
    *) echo "unknown phase $ph" >&2 ;;
  esac
done

echo "---- results ($QA_OUT/results.tsv)"
column -t -s $'\t' "$QA_OUT/results.tsv"
pass=$(awk -F'\t' 'NR>1 && $5=="PASS"' "$QA_OUT/results.tsv" | wc -l)
total=$(awk -F'\t' 'NR>1 && $5!="-"' "$QA_OUT/results.tsv" | wc -l)
echo "automated PASS: $pass / $total (REVIEW rows need a human look at the shots/transcripts)"
