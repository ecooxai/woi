# Android held microphone smoke

Android held recording is microphone-only from 0.15.1. A hold requests only
`RECORD_AUDIO`, starts the dedicated microphone foreground service, and waits
for native readiness. It neither starts nor stops screen sharing. Linux held
recording continues to mix microphone and system output.

The target device is MI8 (Android 15 / API 35), serial `2d4f6bc0`. Device work
requires the parent's phone lock after installing the matching release and test
APKs. New evidence belongs in `qa/out/acceptance-0.15.1`; preserve the archived
0.15.0 evidence in `qa/out/acceptance`.

## Native test boundary

Run the existing test-only runner with `-e group audio`. Its substituted native
Activity starts no Flutter engine or chat connection. Every captured PCM callback
is discarded immediately; only microphone count/RMS, source names, error, and
release state are reported. It requests no projection consent and plays no media
fixture. The test requires an already-granted microphone permission; Flutter
adapter regressions cover permission denial and no screen-share method calls.

The updated native harness has eight checks: neutral startup; two consecutive
microphone captures; cancellation before startup; explicit native cancellation;
recovery after cancellation; ordinary microphone restoration; and final absence
of a chat engine or projection. Each check asserts that Woi screen sharing and
its projection foreground flag stay off. Test cleanup closes only microphones,
restores audio preferences, and finishes the native Activity. It never stops an
independently owned projection.

| Scenario | Required evidence |
| --- | --- |
| Cold hold without screen sharing | Native microphone becomes ready without projection or screen consent. |
| Repeated holds | Fresh generations, `sources=[microphone]`, at least 24,000 mic samples, and an active unsilenced `VOICE_COMMUNICATION` configuration. |
| Immediate cancel | Zero mic samples, no readiness/late PCM event, and confirmed release. |
| Native cancellation | Error reaches the sink, capture closes, and the next microphone hold works. |
| Ordinary mic restoration | Held release is acknowledged before normal capture opens; normal PCM arrives and is discarded. |
| Cleanup | `released=true`, `active=false`, `closing=0`, no callbacks after acknowledgement, and no screen share or Flutter engine created. |

Zero microphone RMS can be expected from MI8 noise suppression in a quiet room.
The harness records `mic_signal_observed` honestly and verifies Android has not
silenced the client. Without an independent acoustic stimulus, these checks prove
lifecycle and OS eligibility, not calibrated near-end speech performance.

## Dart regressions and UI checks

Adapter tests require microphone permission only and assert that no `share*`
method is called during open, failure, close, or release acknowledgement. They
also preserve an independently active share and keep microphone capture alive
when that share ends. Recorded-turn tests cover microphone-only and mixed-source
history labels across reconnect, clip persistence, and no screenshot capture on
submission. Existing managed-capture tests retain native mic release ordering
and suspension across reconnect.

For an actual Flutter gesture smoke, root must hand over an already-running
app with normal listening muted. Cancel or discard short holds; do not send
ambient microphone audio to a model. A native check does not validate the
Flutter gesture itself. Explicit camera and screen-share controls keep their
own behavior and are not activated by holding the microphone.

The numeric log helper remains available:

```sh
python3 qa/android/held_smoke.py summarize path/to/restricted-native.log
```

Its `prepare` command is retained only for reproducing the archived dual-source
0.15.0 media fixture. The current microphone-only harness does not use it.

## Current validation status

The 0.15.1 native harness and Dart regressions are implemented. Release-build and
real-device verification are pending the root coordinator's build/device lock.
Do not apply the historical dual-source pass below to the new microphone-only
implementation.

## Historical 0.15.0 dual-source device result

These archived results apply to the previous dual-source Android implementation.
The original logs and numeric measurements remain unchanged.


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
