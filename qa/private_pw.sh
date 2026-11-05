#!/usr/bin/env bash
# Private, hardware-free PipeWire instance for the QA suite.
#
#   qa/private_pw.sh start      # launch, self-test, print export lines
#   eval "$(qa/private_pw.sh env)"
#   qa/private_pw.sh selftest   # null sink + 1 s tone -> record monitor
#   qa/private_pw.sh status
#   qa/private_pw.sh stop       # kill only the pids recorded by `start`
#
# Runs pipewire + pipewire-pulse + wireplumber under $QA_PW_BASE (default
# ${TMPDIR:-/tmp}/woi-private-pw), fully separate from the user's session
# daemons, so the E2E suite works even when the host PipeWire is hung and can
# never disturb it (QA_PRIVATE_PW=1 qa/run_e2e.sh uses this).
#
# Isolation:
#  - own XDG_RUNTIME_DIR ($QA_PW_BASE/run, mode 700): sockets pipewire-0 and
#    pulse/native live there; clients get PIPEWIRE_RUNTIME_DIR, PULSE_SERVER
#    and PULSE_RUNTIME_PATH pointing at it, so nothing falls back to the host.
#  - no hardware: the daemons run with SPA_PLUGIN_DIR = a symlink farm without
#    the alsa, bluez5, v4l2 and libcamera plugins (they cannot be loaded), and
#    wireplumber's hardware.* / monitor.* features are disabled. The graph is
#    driven by the Dummy-Driver (timer) node.
#  - no host D-Bus: the daemons get a private dbus-daemon as session bus and an
#    unreachable system bus; wireplumber's dbus, reservation, logind, portal,
#    mpris and modem-manager features are disabled; pipewire-pulse does not
#    claim org.pulseaudio.Server; module-rt (RTKit over D-Bus) is not loaded.
#  - own config and state: PIPEWIRE_CONFIG_DIR, XDG_CONFIG_HOME and
#    XDG_STATE_HOME point into $QA_PW_BASE, so the user's
#    ~/.local/state/wireplumber (default devices, volumes) is never written.
set -u
BASE=${QA_PW_BASE:-${TMPDIR:-/tmp}/woi-private-pw}
RUN=$BASE/run
PIDS=$BASE/pids
LOG=$BASE/log

env_lines() {
  cat <<EOF
export XDG_RUNTIME_DIR=$RUN
export PIPEWIRE_RUNTIME_DIR=$RUN
export PIPEWIRE_REMOTE=pipewire-0
export PULSE_SERVER=unix:$RUN/pulse/native
export PULSE_RUNTIME_PATH=$RUN/pulse
EOF
}

write_configs() {
  mkdir -p "$BASE/config/pipewire" "$BASE/config/wireplumber/wireplumber.conf.d" "$BASE/state" "$LOG" "$BASE/spa"
  # SPA plugins without any hardware access
  rm -f "$BASE"/spa/*
  local d
  for d in /usr/lib/spa-0.2/*; do
    case ${d##*/} in alsa | bluez5 | v4l2 | libcamera | jack | avb | vulkan) continue ;; esac
    ln -s "$d" "$BASE/spa/${d##*/}"
  done
  cat >"$BASE/config/pipewire/pipewire.conf" <<'EOF'
# Woi QA private PipeWire daemon (qa/private_pw.sh). No hardware, no module-rt.
context.properties = {
    core.daemon = true
    core.name = pipewire-0
    log.level = 2
    link.max-buffers = 16
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum = 1024
    default.clock.min-quantum = 32
    default.clock.max-quantum = 2048
    mem.allow-mlock = false
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    audio.adapt     = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-profiler }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-spa-device-factory }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-client-device }
    { name = libpipewire-module-access args = { } }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
    { name = libpipewire-module-session-manager }
]
context.objects = [
    { factory = spa-node-factory
        args = {
            factory.name    = support.node.driver
            node.name       = Dummy-Driver
            node.group      = pipewire.dummy
            node.sync-group = sync.dummy
            priority.driver = 200000
        }
    }
    { factory = spa-node-factory
        args = {
            factory.name    = support.node.driver
            node.name       = Freewheel-Driver
            priority.driver = 190000
            node.group      = pipewire.freewheel
            node.sync-group = sync.dummy
            node.freewheel  = true
        }
    }
]
EOF
  cat >"$BASE/config/pipewire/pipewire-pulse.conf" <<'EOF'
# Woi QA private pipewire-pulse (qa/private_pw.sh). No D-Bus name, no module-rt.
context.properties = {
    log.level = 2
    mem.allow-mlock = false
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-protocol-pulse args = { } }
]
pulse.properties = {
    server.address = [ "unix:native" ]
    server.dbus-name = ""
}
stream.properties = { }
EOF
  cat >"$BASE/config/wireplumber/wireplumber.conf.d/90-woi-qa-private.conf" <<'EOF'
# Woi QA private wireplumber (qa/private_pw.sh): no hardware, no D-Bus, no state.
context.properties = {
    log.level = 2
}
override.context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
wireplumber.profiles = {
  main = {
    hardware.audio = disabled
    hardware.bluetooth = disabled
    hardware.video-capture = disabled
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.alsa.reserve-device = disabled
    monitor.bluez = disabled
    monitor.bluez-midi = disabled
    monitor.bluez.seat-monitoring = disabled
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
    support.dbus = disabled
    support.system-dbus = disabled
    support.reserve-device = disabled
    support.logind = disabled
    support.portal-permissionstore = disabled
    script.client.access-portal = disabled
    support.mpris = disabled
    support.modem-manager = disabled
    hooks.device.profile.state = disabled
    hooks.device.routes.state = disabled
    hooks.default-nodes.state = disabled
    hooks.stream.state = disabled
  }
}
EOF
}

alive() { kill -0 "$1" 2>/dev/null; }

running() {
  [ -s "$PIDS" ] || return 1
  local name pid
  while read -r name pid; do alive "$pid" || return 1; done <"$PIDS"
  return 0
}

# exec: `func &` forks a subshell; exec makes $! the daemon itself.
# GIO_USE_VFS=local: GLib in wireplumber would otherwise D-Bus-activate gvfsd,
# which mounts a FUSE fs in XDG_RUNTIME_DIR.
daemon_env() { # common env of the private daemons
  exec env -i GIO_USE_VFS=local GVFS_DISABLE_FUSE=1 NO_AT_BRIDGE=1 HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG="${LANG:-C}" \
    XDG_RUNTIME_DIR="$RUN" PIPEWIRE_RUNTIME_DIR="$RUN" PULSE_RUNTIME_PATH="$RUN/pulse" \
    PIPEWIRE_CONFIG_DIR="$BASE/config/pipewire" XDG_CONFIG_HOME="$BASE/config" \
    XDG_STATE_HOME="$BASE/state" XDG_DATA_HOME="$BASE/state" SPA_PLUGIN_DIR="$BASE/spa" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN/bus" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$RUN/no-system-bus" \
    "$@"
}

spawn() { # name cmd...
  local name=$1; shift
  daemon_env setsid "$@" </dev/null >>"$LOG/$name.log" 2>&1 &
  echo "$name $!" >>"$PIDS"
}

wait_for() { # test-cmd... ; up to 10 s
  local t=0
  until "$@" 2>/dev/null; do sleep 0.2; t=$((t + 1)); [ $t -ge 50 ] && return 1; done
  return 0
}

start() {
  if running; then echo "already running ($BASE)" >&2; env_lines; return 0; fi
  [ -s "$PIDS" ] && stop >/dev/null 2>&1
  mkdir -p "$RUN" && chmod 700 "$RUN" || return 1
  rm -rf "$RUN"/* "$LOG"
  write_configs
  : >"$PIDS"
  # private session bus without service activation: nothing is auto-started
  cat >"$BASE/config/dbus-session.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$RUN/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
XML
  spawn dbus dbus-daemon --config-file="$BASE/config/dbus-session.conf" --nofork --nopidfile
  wait_for test -S "$RUN/bus" || { echo "private dbus did not start" >&2; stop; return 1; }
  spawn pipewire pipewire
  wait_for test -S "$RUN/pipewire-0" || { echo "pipewire did not start, see $LOG" >&2; stop; return 1; }
  spawn wireplumber wireplumber
  spawn pipewire-pulse pipewire-pulse
  wait_for test -S "$RUN/pulse/native" || { echo "pipewire-pulse did not start, see $LOG" >&2; stop; return 1; }
  eval "$(env_lines)"
  wait_for timeout 3 pactl info >/dev/null || { echo "pactl cannot reach the private server" >&2; stop; return 1; }
  # wireplumber needs a moment to publish the default metadata
  wait_for sh -c 'timeout 3 pw-cli ls Client 2>/dev/null | grep -qi wireplumber' ||
    { echo "wireplumber did not connect, see $LOG" >&2; stop; return 1; }
  if ! hardware_free; then echo "private instance exposes hardware objects: stopping" >&2; stop; return 1; fi
  echo "private pipewire up in $BASE (pids: $(awk '{printf "%s=%s ", $1, $2}' "$PIDS"))" >&2
  env_lines
}

# No Device objects and no ALSA/bluez/v4l2/libcamera nodes in the private graph.
hardware_free() {
  eval "$(env_lines)"
  local dump; dump=$(timeout 5 pw-dump 2>/dev/null) || { echo "pw-dump failed" >&2; return 1; }
  local bad; bad=$(printf '%s' "$dump" | python3 -c '
import json, sys
for o in json.load(sys.stdin):
    p = (o.get("info") or {}).get("props") or {}
    hw = [k for k in p if k.split(".")[:2] in (["api", "alsa"], ["api", "bluez5"], ["api", "v4l2"], ["api", "libcamera"])]
    if o.get("type") == "PipeWire:Interface:Device" or hw or str(p.get("factory.name", "")).startswith("api."):
        print(o.get("id"), o.get("type"), p.get("node.name") or p.get("device.name") or p.get("factory.name"), *hw)
')
  [ -z "$bad" ] && return 0
  echo "hardware objects in the private graph:" >&2; echo "$bad" >&2
  return 1
}

stop() {
  [ -f "$PIDS" ] || { echo "not running" >&2; return 0; }
  local name pid
  # reverse order: pulse, wireplumber, pipewire, dbus
  for pid in $(tac "$PIDS" | awk '{print $2}'); do kill "$pid" 2>/dev/null; done
  local t=0
  while [ $t -lt 25 ]; do
    local any=0
    while read -r name pid; do alive "$pid" && any=1; done <"$PIDS"
    [ $any = 0 ] && break
    sleep 0.2; t=$((t + 1))
  done
  while read -r name pid; do alive "$pid" && { echo "SIGKILL $name $pid" >&2; kill -9 "$pid" 2>/dev/null; }; done <"$PIDS"
  rm -f "$PIDS"
  rm -rf "${RUN:?}"/*
  echo "private pipewire stopped" >&2
}

status() {
  [ -s "$PIDS" ] || { echo "not running"; return 1; }
  local name pid
  while read -r name pid; do printf '%-15s %-8s %s\n' "$name" "$pid" "$(alive "$pid" && echo alive || echo DEAD)"; done <"$PIDS"
  eval "$(env_lines)"
  timeout 3 pactl info | grep -E 'Server (String|Name)|Default (Sink|Source)'
}

# Null sink, 1 s 440 Hz tone with pw-play, pw-record of its monitor: non-silent?
selftest() {
  eval "$(env_lines)"
  local dir=$BASE/selftest; rm -rf "$dir"; mkdir -p "$dir"
  python3 - "$dir/tone.wav" <<'PY' || return 1
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(48000)))
w.close()
PY
  local m; m=$(timeout 5 pactl load-module module-null-sink sink_name=qa_selftest_sink) || { echo "selftest: load null sink failed" >&2; return 1; }
  timeout 8 pw-record --target qa_selftest_sink -P "{ stream.capture.sink = true }" --rate 48000 --channels 1 --format s16 "$dir/rec.wav" &
  local rec=$!
  sleep 0.7
  local rc=0
  timeout 5 pw-play --target qa_selftest_sink "$dir/tone.wav" || rc=$?
  sleep 0.5
  kill -TERM $rec 2>/dev/null; wait $rec 2>/dev/null
  timeout 5 pactl unload-module "$m"
  [ $rc = 0 ] || { echo "selftest FAIL: pw-play exit $rc (124 = hung)" >&2; return 1; }
  python3 - "$dir/rec.wav" <<'PY'
import array, sys, wave
w = wave.open(sys.argv[1]); a = array.array("h", w.readframes(w.getnframes()))
loud = sum(1 for x in a if abs(x) > 1000)
peak = max((abs(x) for x in a), default=0)
print(f"selftest: recorded {len(a)/48000:.2f}s, peak {peak}, {loud/48000:.2f}s above -30 dBFS")
sys.exit(0 if loud > 0.5 * 48000 else 1)
PY
  local ok=$?
  [ $ok = 0 ] && echo "selftest PASS" >&2 || echo "selftest FAIL: monitor recording is silent" >&2
  return $ok
}

case ${1:-} in
  start) start && selftest >&2 || { stop; exit 1; } ;;
  start-nocheck) start ;;
  stop) stop ;;
  env) env_lines ;;
  status) status ;;
  selftest) selftest ;;
  *) echo "usage: $0 start|stop|env|status|selftest" >&2; exit 2 ;;
esac
