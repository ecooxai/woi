# Woi 0.15.0 acceptance record

Branch: `gpt-6-astra-pro/woi-audio-ui-control-20261107`.
Base: `23b935d` (`v0.14.0`). The working tree was clean before this work.

## Changes

### Linux audio and held recording

Native WebRTC capture now leases the same PipeWire echo-cancelled microphone
used by PCM capture. A reconnect checks that the source still exists; cancelled
startup and shutdown use unique generation names and serialized ownership.
Requested cancellation never silently falls back to a raw microphone.

A held recording explicitly captures microphone plus system output. Ordinary
listening is suspended before this separate capture opens, including reconnects
and in-flight native device opens. Release submits the bounded clip; cancellation,
backgrounding, errors, and pending-consent cancellation discard it. The two-minute
limit waits for release instead of sending automatically. Native release is
acknowledged before normal capture resumes; failed release leaves listening
paused and permits a later hold to retry cleanup.

Android uses a separate AudioRecord pair, confirmed microphone foreground service,
MediaProjection consent, explicit OS microphone-silencing detection, per-session
callbacks and release acknowledgment. Eligible source applications can disallow
playback capture; this implementation does not bypass Android's capture policy.

### Chat UI

The composer has text above a single row containing status, circular context
usage, camera, microphone, and send at the far right. Status offers hover and
click details. Context details open on click and scroll on narrow screens.
The old input-mode selector and composer model badge are removed. A tap toggles
normal microphone listening; holding records. Replies retain the model of their
producing session in persisted metadata. Older messages with no attribution say
“Model not recorded”.

### Computer input

`move_pointer` positions the pointer without a click. Mouse and keyboard tools
share a serialized guard with a one-second warning and one-second trailing
indicator. Light-blue native overlays preserve input focus and allow clicks
through. Keyboard operations show the keyboard icon and transient key text.
Physical takeover latches cancellation until a new user request. Linux XInput2
separates physical events from XTEST events. Android uses a non-consuming
outside-touch watcher; global external-mouse hover is not observed on Android.

### Python

The `python` tool is available to assistant and delegation flows, and model
instructions require Python for calculations. It returns bounded stdout/stderr,
exit status and timeout information, using the existing command approval setting.
Linux runs installed Python 3 in a timed process group. Android embeds CPython
3.11 in a separate service, validates a private worker group before execution,
and cleans up ordinary inheriting children. Native, binary, and subprocess output
are captured. This is process isolation for execution and cleanup, not a hostile
code sandbox.

Android ABI flavors (`arm64`, `armv7`, `x64`) select matching Python assets and JNI
libraries. They preserve the prior split-APK version offsets for upgrades.

## Completed source verification

- `flutter analyze --no-pub`: no issues.
- Full Flutter suite: **776 passed, 15 skipped**, including the narrow context-sheet regressions.
- Embedded Python host suite: **16 passed**.
- Held recording tests include delayed native teardown, reconnect during a hold,
  failed suspension, failed release, retry recovery, final PCM tail, cancellation,
  first-time consent races, and duration bounds.
- `git diff --check`: clean at the source freeze.

## Native UI acceptance

The final Linux binary was inspected at desktop 1400 × 900 and narrow 360 × 740
and 400 × 860 layouts. Composer ordering, model attribution, status hover/click,
and desktop context details passed. A real clipped narrow-sheet action was fixed
with a scroll container; both narrow layouts then exposed the full explanation,
“Compact now” action, and padding. The final private app log has no Flutter
overflow or exception patterns. Only synthetic history and masked/offline auth
were used for this visual pass, and the private display was stopped afterward.

## Isolated Linux audio evidence

The reproducible hardware-free PipeWire rig measured system-reference attenuation:

| Scenario | Attenuation |
| --- | ---: |
| Initial capture | 49.88 dB |
| Warm reconnect | 75.42 dB |
| Cold reconnect | 64.10 dB |
| Shutdown/start race | 62.16 dB |

Independent near-end signal attenuation was 0.52 dB. These are deterministic
virtual-loop measurements, not physical room measurements. The host's default
source and sink were preserved. See `qa/aec/RECONNECT.md`.

The native Linux overlay harness on nested displays verified click-through,
preserved keyboard focus, rejection of physical takeover, and acceptance of the
app's own XTEST input. See `qa/control_overlay_native.py`.

## Build and device acceptance

The Linux release and arm64 Android release compile successfully. The Android
APK declares version `0.15.0`, version code `2015`, API minimum 24, and only the
`arm64-v8a` JNI ABI. The release optimizer preserves the handwritten native bridge
API so the separately compiled instrumentation APK can test the shipped release.

The built Linux app passed **34/34 live end-to-end checks**, covering realtime
voice, click/type input, approval/rejection, file and note edits/undo, image/audio/
video viewers, synthetic camera, clipboard, compaction, and current-video context.
The arithmetic check recorded a successful `python` call with `print(2+2)`.
Barge-in stopped audible output 36 ms after the fixture's “Stop” onset, with no
later resumed audio in that check. These are isolated automated fixture timings.
The display, network session and hardware-free PipeWire environment were closed
after the run; production desktop and audio defaults were not used.

### Android release device checks

The installed R8 release APK passed on the Xiaomi MI 8 running Android 15/API 35:

| Native group | Result |
| --- | ---: |
| Embedded Python | 10/10 |
| Pointer, touch takeover and keyboard overlays | 4/4 |
| Held microphone/system capture and release | 10/10 |

Python checks include arithmetic, verified private process groups, native/binary
and subprocess output, errors, bounded output, timeouts, ordinary child cleanup,
and recovery after timeout and worker exit. Android release processes can hide
peer `/proc` metadata. Worker verification therefore uses the authenticated
Binder connection, sender UID and per-job token with worker-local identity/group
checks, main-process exclusions, and optional readable peer-identity checks.

Native control tests verify move-only positioning, click-through, AI taps without
self-cancellation, user touch takeover blocking later input, keyboard focus and
actual typing. Device testing corrected an inner View coordinate shadowing bug.

Held capture used known capturable media and discarded every PCM callback. First,
second and reconsented captures delivered 48,960 / 48,000 / 48,480 samples per
source, with system RMS 0.0336818 / 0.0338499 / 0.0336700. Microphone RMS was 0 /
0.0000926404 / 0.00000770082. All had active unsilenced VOICE_COMMUNICATION input;
MI8 noise suppression may gate a quiet room to exact zeros. No independent
acoustic stimulus was supplied, so these are source-lifecycle and capture checks,
not calibrated near-end acoustic measurements.

Each completed hold confirmed native release, no active or closing recorder, and
no later PCM delivery. Immediate cancel produced zero samples. Missing consent,
cancellation during actual consent, revocation/reconsent, and ordinary microphone
restoration passed. Normal capture returned 7,680 discarded bytes afterward. No
Flutter chat engine or active MediaProjection remained after native test cleanup.

### Release artifacts

- `woi-0.15.0-android-arm64.apk` — application ID `dev.woi.woi`, version code 2015.
- `woi-0.15.0-linux-x64.tar.gz` — complete executable, libraries, assets and pinned
  Codex bundle; archive structure and executable permissions validated.
- `SHA256SUMS` — SHA-256 for both downloadable application packages.

The branch and release retain the existing main branch as their base; deployment
uses the tested artifacts and preserves application data. The temporary Android
test package is not part of the published application downloads.

Evidence logs and synthetic screenshots are generated under ignored `qa/out/`.
No credentials, user conversation data, microphone recordings, or build binaries
are committed to source control.
