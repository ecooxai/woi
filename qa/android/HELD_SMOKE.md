# Android held microphone/system-audio smoke

The target is the installed release on MI 8 (API 35), serial `2d4f6bc0`.
ADB currently uses the libusb host backend. These checks require the parent's
explicit phone interaction lock after APK installation and Python instrumentation.
Preparation and log summarization below do not call ADB.

## Privacy and test boundary

Use short captures that are cancelled and discarded. Do not release a completed
hold into the send path, do not ask a model to identify the recording, and do not
save or pull microphone PCM. Record only the native per-source counts/RMS,
release/error state, timestamps, and screenshots of neutral UI/consent.

Production startup deliberately changes a saved muted mode back to hands-free.
A new production launch is therefore unsuitable as an offline audio test without
an explicit way to suppress normal voice input. Prefer a native test-APK harness
that invokes `WoiHeldAudio` with an EventSink which drops ByteArray data, using
`WoiBridge.ensureContext(targetContext)` and no Flutter engine. Such a harness
can play an AudioTrack with USAGE_MEDIA and ALLOW_CAPTURE_BY_ALL, and can test
normal WoiAudio recorder restoration with another discard-only sink. It avoids
network/model calls altogether. The existing custom `PythonInstrumentation`
runner supports this pattern; adding an audio group would require test-APK-only
wiring and a native activity that obtains real projection consent under the
target app UID. A production hook is not needed.

If testing gestures in the already-running production UI, the parent must hand
over with normal listening muted and the app left running. Verify that state
from a fresh screenshot before every trial. Cancel an active hold with an
actual pointer CANCEL, or background the app before pointer UP so lifecycle
cancellation executes first. The current mic button does not cancel merely
because a held pointer moves outside its bounds. Do not send a normal UP at the
end of a completed held recording.

## Fixture

Run `python3 qa/android/held_smoke.py prepare` on the host. It creates an ignored
16-second stereo PCM WAV with two low-amplitude tones alternating with silence.
It contains no speech or recorded audio. A known eligible player must use media
usage and permit playback capture. Prefer an explicit test AudioTrack because an
arbitrary installed player may opt out. Keep the device's volume unchanged.

## Scenarios and acceptance

| Scenario | Procedure | Evidence required |
| --- | --- | --- |
| Cold consent | Start with no projection; request it through the real Android consent UI. | No native recorder before approval; the approved projection becomes ready. |
| Release during consent | Cancel the hold before approving; then approve the dialog. | No recorded clip or send; no lingering held recorder; the next hold can use consent. |
| Capturable media | Play the fixture; capture for about 3 seconds; cancel. | Both source sample counts advance; system RMS is nonzero during the tone window; record mic RMS without making a speech-quality claim. |
| Repeat hold | Repeat twice with the same projection, cancelling each. | New generations, a readiness event each time, confirmed release, no held mic left active. |
| Cancel during startup | Cancel before native readiness. | No late recording delivery; closing count returns to zero; a subsequent hold succeeds. |
| Projection revocation | Revoke the approved projection during a short held capture. | Explicit recording cancellation, no send, both recorders released, and fresh consent works afterward. |
| Restore normal mic | After held capture release acknowledgment, open the ordinary native mic with a discard sink. | No held capture remains, normal recorder gets frames and is not OS-silenced, then closes cleanly. |

For a native test harness, collect `WoiHeldAudio.status()` after each stop and
assert `active=false`, `closing=0`, and `released=true`. Revoke with the actual
MediaProjection stop path. For UI smoke, correlate the restricted native log
`held audio released: {...}` with each scenario; do not clear the global device
log. `python3 qa/android/held_smoke.py summarize <restricted-log>` extracts numeric
metrics into ignored `qa/out/android-held/native-summary.json`.

Microphone/system RMS alone cannot prove accurate speech or universal playback
capture. Playback policy, protected content, and silence must be distinguished
from a missing recorder. This smoke supplements the Flutter gesture, cancellation,
and reconnect-ordering regressions; native-only checks do not substitute for the
actual Flutter consent/gesture path.

## Handoff

Restore the pre-test foreground activity, microphone mode, media playback state,
and projection state where applicable. Remove only this fixture/test state.
Return the phone lock to root for the overlay agent. Do not restart the ADB
server while another owner has the lock.

## Release device result

On MI8 (Android 15), the release-native instrumentation passed all 10 checks:
missing consent, cancellation while real consent is pending, repeated held
capture, immediate cancellation, projection revocation/reconsent, normal mic
restoration, and absence of a Flutter chat engine. The known capturable media
fixture measured system RMS 0.03368/0.03385 on consecutive holds and 0.03367
after renewed consent. Each completed hold reported `released=true`,
`active=false`, `closing=0`; no PCM callback arrived after the release
acknowledgement. Immediate cancellation produced zero samples. The normal
microphone subsequently delivered 7,680 bytes, discarded by the test sink.

The first hold had microphone RMS 0 with an active, unsilenced native
configuration. Existing MI8 noise suppression can gate a quiet room to exact
zeros; the next holds measured approximately 0.00009264 and 0.000007701.
No independent acoustic stimulus was supplied, so these checks establish
native lifecycle and OS capture eligibility, not calibrated near-end acoustic
performance. The test explicitly reports `mic_signal_observed` for each hold.

Evidence is in `qa/out/acceptance/android-audio-instrumentation.log` and
`android-audio-measurements.json`. All captured PCM was discarded; only
numeric diagnostics were retained. The initial overly strict quiet-room
assertion and its failure are retained separately for traceability.
