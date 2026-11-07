# Woi 0.15.1 acceptance record

Base: `261f91ee` (`v0.15.0`). This patch completes the composer, held-audio and
input-indicator follow-up before the separate settings task.

## Behavior

- The enabled send button is black with a white arrow. Camera is immediately
  left of microphone; send remains at the far right. Disabled controls retain
  their readable themed styling.
- Android holds capture microphone only, without starting, reading, stopping or
  changing MediaProjection. An independent screen share remains separate.
  Linux holds still capture microphone plus system audio.
- Status/accessibility text, transcription context and saved message metadata
  identify the actual sources, including clips queued across reconnects.
  Recorded submission does not request an automatic screenshot.
- The microphone permission, microphone foreground service, startup readiness,
  generation checks and awaited native release remain enforced. Android held
  recording retains its existing Android 10+ availability floor.
- Native overlays use a light-blue cursor arrow with an accurate tip/hotspot.
  Left click darkens the cursor blue; right click turns it light red. Android
  right click performs a touch long-press; unsupported button combinations fail
  explicitly. Linux cursor windows also work without a compositor.
- The warning remains one second. Indicators and takeover monitoring continue
  for three seconds after input. Late takeover cancels queued input without
  extending the original trailing deadline.

## Completed source and Linux native gates

- Flutter analysis: no issues.
- Full Flutter suite: **785 passed, 15 skipped**.
- Native Linux private-display harness: passed arrow rendering, colors, hotspot,
  neutral reset, click-through, focus preservation, ignored XTEST input and
  physical takeover 2.3 seconds after input. Both private displays were closed.
- Dart regressions cover both control kinds, the exact warning/trailing timing,
  late takeover, Android button forwarding/rejection, move-only behavior,
  microphone-only startup and active-share independence, native release races,
  and both recorded source labels through queued reconnects and persistence.

## Build, visual and device gates

- Linux release and Android arm64 release builds succeeded.
- The installed APK is version **0.15.1 / 2016** and exactly matches the release
  artifact's SHA-256 digest.
- Native UI checks passed at 1400 × 900, 360 × 740 and 400 × 860 in light/dark
  themes. Camera → microphone → send ordering, far-right send and inactive-state
  readability passed without overflow. The offline pass source-verifies the
  enabled send colors; it does not claim an enabled-state native observation.
- Linux archive structure and executable permissions were validated.
- Android microphone-only native checks: **8/8 passed** on the installed release.
  Repeated and recovery holds each returned 24,480 samples / 48,960 discarded
  bytes with `sources=[microphone]`, an unsilenced OS input, release acknowledged,
  no remaining recorder and no post-release PCM. Immediate cancel returned zero
  samples; normal microphone capture was restored. MediaProjection remained null.
  Quiet-room RMS was zero; these checks establish lifecycle/OS eligibility, not
  calibrated acoustic performance.
- Android native control checks: **6/6 passed**. Actual move-only positioning,
  click colors, right long-press delivery, unsupported-button rejection, touch
  pass-through/cancellation, third-second takeover and keyboard focus/typing
  passed on the installed release.
- Both device groups completed with instrumentation result `-1`.

New evidence belongs under ignored `qa/out/acceptance-0.15.1/`. Earlier 0.15.0
evidence remains intact. Device audio checks discard PCM and never send it to a
model. Existing Android external-mouse-hover limitations remain documented in
the 0.15.0 acceptance record; touch takeover is the supported phone interaction.
