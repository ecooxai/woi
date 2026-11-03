#!/usr/bin/env bash
# Runs the REAL gpt-live integration test (network, ChatGPT login, PipeWire).
#
#   integration_test/run_live.sh                 # all fixtures
#   WOI_ONLY=02,05 integration_test/run_live.sh  # a subset
#
# Virtual devices exist (and the virtual mic is the default source) only
# while the test runs; see virtual_audio.sh for the restore guarantees.
# Needs an X display (xvfb does not work with `flutter test -d linux`).
set -u
cd "$(dirname "$0")/.."
FLUTTER=${FLUTTER:-$(command -v flutter || echo /home/a/.local/flutter/bin/flutter)}
. integration_test/virtual_audio.sh
woi_audio_setup --default-source || exit 1
export WOI_VIRTUAL_AUDIO=1
DISPLAY=${DISPLAY:-:0} "$FLUTTER" test integration_test/live_gpt_live_test.dart -d linux "$@"
