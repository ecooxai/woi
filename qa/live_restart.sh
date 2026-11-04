#!/usr/bin/env bash
# Rebuild main in the ../woi-live worktree and (re)start Woi on the real desktop.
# Usage: qa/live_restart.sh [--no-build]. Log: /tmp/woi-live.log, pid: /tmp/woi-live.pid
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIVE=$(cd "$ROOT/.." && pwd)/woi-live
FLUTTER=${FLUTTER:-/home/a/.local/flutter/bin/flutter}
[ -d "$LIVE" ] || git -C "$ROOT" worktree add -q --detach "$LIVE" main
if [ "${1:-}" != "--no-build" ]; then
  git -C "$LIVE" checkout -q --detach main
  (cd "$LIVE/app" && "$FLUTTER" build linux --release 2>&1 | tail -1)
fi
PIDF=/tmp/woi-live.pid
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  kill "$(cat "$PIDF")"; for _ in $(seq 50); do kill -0 "$(cat "$PIDF")" 2>/dev/null || break; sleep 0.1; done
fi
cd "$HOME"
DISPLAY=${LIVE_DISPLAY:-:0} setsid "$LIVE/app/build/linux/x64/release/bundle/woi" >/tmp/woi-live.log 2>&1 < /dev/null &
echo $! > "$PIDF"
echo "woi live pid $(cat "$PIDF") on ${LIVE_DISPLAY:-:0} ($(git -C "$LIVE" log --oneline -1))"
