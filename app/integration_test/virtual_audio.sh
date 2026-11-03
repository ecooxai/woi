# Sourced helper: PipeWire/Pulse virtual devices for live voice tests.
#
#   woi_audio_setup [--default-source]   creates
#     woi_fixture_sink  (null sink you `paplay -d` fixtures into)
#     woi_virtual_mic   (source "WoiVirtualMic" = monitor of that sink)
#     woi_speaker       (null sink "WoiSpeaker" for the assistant's audio)
#   and, with --default-source, makes woi_virtual_mic the default source.
#
# The original default source/sink are recorded first and restored, and the
# modules unloaded, by an EXIT/INT/TERM/HUP trap, so the desktop's audio
# setup comes back even when the test crashes or is interrupted.

WOI_ORIG_SOURCE=""
WOI_ORIG_SINK=""
WOI_MODULES=()

woi_audio_cleanup() {
  local i m
  for ((i = ${#WOI_MODULES[@]} - 1; i >= 0; i--)); do
    pactl unload-module "${WOI_MODULES[i]}" 2>/dev/null
  done
  WOI_MODULES=()
  # Leftovers from an earlier run that was killed hard.
  for m in $(pactl list short modules | awk '/woi_(fixture_sink|virtual_mic|speaker)/ {print $1}'); do
    pactl unload-module "$m" 2>/dev/null
  done
  [ -n "$WOI_ORIG_SOURCE" ] && pactl set-default-source "$WOI_ORIG_SOURCE" 2>/dev/null
  [ -n "$WOI_ORIG_SINK" ] && pactl set-default-sink "$WOI_ORIG_SINK" 2>/dev/null
  echo "audio restored: source=$(pactl get-default-source) sink=$(pactl get-default-sink)" >&2
}

woi_audio_setup() {
  woi_audio_cleanup 2>/dev/null # stale modules only (nothing recorded yet)
  WOI_ORIG_SOURCE=$(pactl get-default-source) || return 1
  WOI_ORIG_SINK=$(pactl get-default-sink) || return 1
  trap 'woi_audio_cleanup' EXIT
  trap 'exit 130' INT TERM HUP
  WOI_MODULES+=("$(pactl load-module module-null-sink sink_name=woi_fixture_sink \
    sink_properties=device.description=WoiFixtureSink)") || return 1
  WOI_MODULES+=("$(pactl load-module module-remap-source master=woi_fixture_sink.monitor \
    source_name=woi_virtual_mic source_properties=device.description=WoiVirtualMic)") || return 1
  WOI_MODULES+=("$(pactl load-module module-null-sink sink_name=woi_speaker \
    sink_properties=device.description=WoiSpeaker)") || return 1
  if [ "${1:-}" = "--default-source" ]; then
    pactl set-default-source woi_virtual_mic || return 1
  fi
  echo "virtual audio ready (modules ${WOI_MODULES[*]}; original source $WOI_ORIG_SOURCE)" >&2
}
