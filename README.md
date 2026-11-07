# Woi — voice-first AI assistant (Linux first)

Stack: Flutter (Dart), Linux and Android. Realtime voice via gpt-live (Codex ChatGPT auth or OpenAI API key).
See docs/PLAN.md.

## Build

    cd app
    flutter build linux --release
    # Android: install the arm64-v8a APK on 64-bit phones (e.g. the MI 8):
    flutter build apk --release --flavor arm64 --target-platform android-arm64
    adb install -r build/app/outputs/flutter-apk/app-arm64-release.apk

Build the `armv7` flavor with `--target-platform android-arm`, or the `x64`
flavor with `--target-platform android-x64`, for the other supported ABIs.
Use ABI flavors instead of `--split-per-abi`: they also select the embedded
Python native assets and retain the existing per-ABI upgrade version codes.
Don't run `flutter test`/`analyze` while an APK build runs (pub get regenerates
the plugin registrant with dev dependencies and javac fails).

## Audio and chat controls

The microphone button toggles listening on a tap. Hold it to record, then release
to submit. Android records the microphone only and never starts screen sharing
for a held recording. Held recording on Android requires Android 10 or newer.
Linux records microphone plus system audio. A cancelled hold sends nothing. At the two-minute limit, the clip waits for release or cancel.

Status and context usage are compact icons below the text field. Hover or click
status for connection details; click the context ring for usage. Each assistant
reply records its producing session model underneath the message. The camera is
immediately left of the microphone, and the black send button is at the far right.

On Linux, the native WebRTC microphone uses the PipeWire echo-cancelled source
when echo cancellation is enabled. Reconnecting rebuilds missing nodes and waits
for old capture owners to release before reusing audio resources.

## Computer input and Python

Computer input displays a light-blue mouse pointer for one second before an
action and keeps the indicator visible for three seconds afterward. Left clicks
turn the pointer darker blue; right clicks turn it light red. On Android, right
click means a touch long-press. Keyboard actions show a keyboard icon and the
keys at the top right. User takeover stops further input until a new
user request. `move_pointer` positions the pointer without clicking. Linux uses
XInput2 to distinguish physical input from injected events; Android detects touch
takeover through an input-transparent accessibility overlay and outside-touch
watcher. Android external-mouse hover takeover is not currently observed globally.

The `python` tool runs Python 3 code, returns bounded stdout/stderr and exit status,
and enforces a timeout. Assistant instructions require it for calculations. It
uses the existing command-approval preference. Linux uses installed `python3`;
Android embeds CPython 3.11 in a separate worker process and cleans up ordinary
child processes inheriting its private process group. Calls do not share Python
variables. The worker is not a security sandbox for hostile code.

Linux development requires the XInput2 headers (`libxi-dev`) as well as the normal
Flutter/GTK and PipeWire dependencies. Android's embedded Python requires API 24
or later.

## Verification

    cd app
    flutter analyze
    WOI_LIVE=0 flutter test --reporter expanded
    python3 -m unittest discover -s android/app/src/test/python -v

Build the release APK before its native instrumentation APK, without running
Flutter tests or analysis concurrently:

    cd android
    ./gradlew -PwoiTestBuildType=release :app:assembleArm64ReleaseAndroidTest

The native instrumentation exercises embedded Python output, process cleanup,
timeouts, and recovery on a device. See `qa/aec/RECONNECT.md` for the isolated
PipeWire reconnect test, and `qa/control_overlay_native.py` for Linux overlay and
physical-takeover verification on nested displays.
