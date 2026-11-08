# Woi 0.20.0 — Android Media audio, input and clipboard

Date: 2026-11-08 (UTC). Branch: `gpt-6-astra-pro/woi-android-audio-input-20261108`.
Base: `a80f25c` (0.19.0). Android version: `0.20.0`, ARM64 version code `2021`.

## Media echo cancellation

Android Media retains `MODE_NORMAL`, `USAGE_MEDIA`, and media volume. Direct realtime capture now has a software echo canceller supplied with the assistant's streamed PCM bytes accepted by its output AudioTrack. Monotonic capture/playback clocks seed the reference once per playback epoch, with a bounded startup estimate when timestamps are not yet valid. A continuous sample cursor then advances by the captured sample count. New tracks, flushes, idle pause/resume and observed underruns deliberately re-anchor that cursor without resetting the microphone stream or its DSP overlap. The packaged SpeexDSP canceller uses 20 ms frames and a 200 ms adaptive tail. Processing delay stays at 20 ms through silent intervals. After a complete echo tail with no render reference, delayed raw microphone samples preserve ordinary near-end speech unchanged. Raw samples continue to drive the recorder's dead-microphone check, avoiding false restart loops after successful cancellation. Incomplete recorder blocks terminate capture with an explicit error; native processing rejects partial frames before mutating output or filter history. Reset clears both the adaptive filter and the preprocessor's overlap history. Focused regressions verify that rejected fragments leave processing unchanged and reset produces the same output as a new instance.

The native microphone no longer relies on sharing a session with a media AudioTrack as proof of hardware AEC. Cleanup synchronizes the DSP lifetime with capture/render use; stop/flush drops future reference data while retaining the audible tail. Media stays full duplex when echo cancellation is enabled. The previous direct-PCM half-duplex fallback remains when it is disabled.

The saved Media/Phone route now reaches gpt-live. WebRTC initializes with software audio processing and the selected Android audio configuration. Route changes reconnect the live call and update the next AudioTrack attributes. Android AEC/NS/AGC values use the native plugin's supported constraint lists, including explicit false values. A closed transport cannot continue applying obsolete routing after asynchronous initialization.

The first device synthetic check exposed a real convergence defect in the initial 10 ms configuration: a different excitation signal left later reflections incompletely learned, yielding about 14.9 dB on both ARM64 and the exact host replay. The corrected 20 ms configuration retains the 200 ms tail, halves the adaptive partition count, and passes both signals without changing the upstream DSP, suppression settings or acceptance thresholds.

| Host regression | Original host signal | Exact device signal |
| --- | ---: | ---: |
| Echo attenuation | 72.81 dB | 73.68 dB |
| Near-end correlation during double talk | 0.9402 | 0.9247 |
| Near-end gain during double talk | 0.9467 | 0.9090 |
| Attenuation after reset | 72.81 dB | 73.68 dB |
| Near-only speech gain without playback | — | 1.0000 |

These are synthetic measurements, separate from physical phone results. Digital-zero residuals use a conservative half-int16-LSB RMS floor instead of a division epsilon; they are reported as quantization-limited attenuation, not unlimited suppression.

Physical testing exposed a separate timing defect in per-block clock alignment. The reference had 99.97% sample coverage with no missing future samples, but timestamp jitter made its position jump while the actual acoustic correspondence remained stable. In a controlled comparison using identical captured samples, the old mapping achieved 0.180 dB reduction and the continuous cursor achieved 29.847 dB. Playback used the built-in speaker and microphone, with no captured clipping or playback underruns. The production cursor was then corrected; its startup acceptance result is recorded in Validation below.

## Typing, keyboard display and clipboard

Literal typing prefers the currently selected editable accessibility node when it advertises text replacement, exposes readable text and a usable caret, and is not a password field. This path works with a hidden keyboard and avoids dependence on an input connection that Android may retain after invalidation. It preserves selection replacement, Unicode and surrounding text. Password, opaque and unsupported editors retain the input-connection path. An explicitly accessibility-selected editor can be used without choosing a new field; genuine input focus takes priority. The selected app, window and editor are pinned, refreshed before each operation, and checked for cancellation or target changes. A failed action is never replayed through another backend.

Exact key chords still require the Android 13+ input-connection API. `show_keyboard` requests Android's existing soft keyboard without clicking or focusing a field. It distinguishes a request being accepted from a keyboard actually becoming visible, and reports refusal as an error. Missing-target typing attempts that recovery once, then reports that an editor is still needed.

The new `clipboard` tool supports text read/write/paste. Pure semantic editing batches prefer the pinned editor's accessibility actions when every requested action is advertised; exact chords still use the input connection. Paste can use the existing clipboard or write exact supplied text first. Empty strings never turn into a paste of stale content. Reads are explicit; URI/Intent clips are not dereferenced. Background Android reads briefly use a visible focused Woi activity, then restore the previous app/assistant state. Stop closes an in-flight reader, and a captured input epoch prevents a pending write from becoming a stale paste after cancellation.

Typing tools now expose `delivery` and `backend`. An IME dispatch is described as input sent; an accessibility edit action is described as acknowledged by the editor. Neither an accepted keyboard-display policy nor an asynchronous key event is promoted into an unobserved result.

## Pointer, keyboard indicators and action timing

Pointer and keyboard indicators have 50% opacity on Android and Linux. Android drawing subtracts the indicator's actual on-screen origin, aligning the pointer tip with real click coordinates despite system bars or window insets. The neutral/light-blue, left/darker-blue and right/light-red states remain distinct.

The shared pre-action warning is 120 ms, down from 1000 ms. The three-second trailing indicator no longer delays the result or the next action. Takeover monitoring continues during that tail, remains latched after intervention, and old fade callbacks cannot hide a newer indicator. Checks after awaited monitor calls and before creating a new lease close reset/cancellation races.

Assistant and delegate instructions request tool calls before any spoken/written acknowledgement. Clear typing, shortcuts, clipboard commands and keyboard-show requests use deterministic dispatch where available; exact clipboard writes and write-then-paste commands require unambiguous quoted literals for this fast path. Other requests still depend on the provider following those instructions. Pointer grounding continues through the configured Luna route.

## Validation

### Automated and native checks

| Gate | Result | Evidence |
| --- | --- | --- |
| Flutter analysis | 0 issues | `qa/out/acceptance-0.20.0/flutter-analyze.log` |
| Full Flutter suite | 1,051 passed, 15 opt-in skipped, 0 failed; 97 s | `flutter-gates.json`, `flutter-tests.log` |
| Native JVM unit checks | 21 passed: 16 keyboard/parser and 5 continuous-reference cursor cases | `android-unit-tests.json` |
| Linux native overlay checks | 2 scenarios passed, including half-alpha rendering, click-through, focus retention, coordinates and takeover during the third second | `linux-overlay-results.json` |
| Android overlay checks | 6 passed; 13 screenshots reviewed | `android-control-device.json`, `android-control-screenshots/` |
| Android production Media AEC | 3 checks passed: packaged DSP, route attributes and physical speaker/microphone path | `android-media-aec-device.json` |
| Android keyboard and clipboard | 15 passed on the final installed APK | `android-keyboard-device.json`, `android-keyboard-device.log` |

The five cursor tests exercise sample continuity despite timestamp jitter, waiting for an initial anchor, resuming within existing track frame numbering, flushes that restart track numbering, and the rule that only an explicit epoch reset can move an established cursor. Source review also covered underrun epochs and rejection of timestamps from before an epoch. The Flutter suite includes clipboard truncation and empty-text behavior, Android error propagation, cancellation between clipboard write and paste, input receipts, overlay takeover races, and cancelled live-transport route initialization. Live-provider integration tests remain opt-in; no external live-provider acoustic call was made.

### Physical Android Media result

The production app was tested on the connected Xiaomi MI8 running Android 15 / API 35. It used the built-in speaker and microphone, `MODE_NORMAL` and `USAGE_MEDIA`, at media volume 8. Over the final approximately five seconds of a ten-second stimulus, raw microphone RMS was 0.099989 and cleaned RMS was 0.003503: **29.110 dB echo attenuation** after adaptation. The first approximately one-second window measured 2.99 dB; later windows rose through 15.39, 17.15, 21.02 and 24.50 dB, reaching 27.91–30.15 dB. The result therefore describes convergence during continuous playback, not immediate full suppression at startup.

The reference cursor skipped or repeated **zero samples across 124 block transitions**. It had no missing future reference samples, no observed playback underruns at six probes, and no clipped captured samples among the 120,960 samples in the measurement interval. The microphone stream was processed through the production wrapper from startup. The test exported aggregate metrics only, and restored media volume and audio mode afterward.

The packaged ARM64 synthetic case separately measured 73.683 dB attenuation before and after reset, near-end correlation 0.92473 and near-end gain 0.90900 during synthetic double talk, with a 20 ms processing delay. These synthetic double-talk measurements are not a physical conversation test. Native WebRTC AudioTrack configuration passed Media → Phone → Media switching; this verifies route attributes rather than end-to-end provider-call acoustics.

### Build and package evidence

The Linux x64 release bundle built successfully, its shared-library dependencies resolved, and all 38 archived files matched the bundle's contents and executable modes. The archive contains 54 entries under `woi-0.20.0-linux-x64/`. All 411 non-Android source and asset files remained unchanged after that build. Linux overlay checks ran on private X displays without changing the user's desktop; alpha was checked on RGBA render surfaces because those test displays had no compositor. Visible Linux translucency requires the desktop compositor.

The final Android release build completed in 64.05 s; the matching instrumentation APK and native unit suite completed in 65.40 s. All 495 application source files were unchanged across the build. The final APK passed ZIP integrity and signing verification, contains 23 ELF64 AArch64 JNI libraries, and includes the full SpeexDSP license notice. Its signing certificate matches the existing project signer (`54921a3a54191e8545842cdf135b7603043f58e9e392c77fb484c0cccd8e3f4f`).

The physical audio run used APK `00b022fbfef0a71ab2aeffeca31348e9515ef4449a535739db4ceaaeef34d6b5`. The final input-only build inherits that component evidence through **33 unchanged audio source files, 10 identical compiled Kotlin audio classes, the identical compiled Java route bridge, all 35 identical packaged shared-library entries (including native assets), and unchanged audio build configuration**. The final whole APK was not independently subjected to another acoustic run. This identity check is recorded in `audio-final-identity.json`.

| Release asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `woi-0.20.0-android-arm64.apk` | 101,669,651 | `528da677dfa505e68f8c19ca0d49550c9573142f34e3a264dd85205e7649185b` |
| `woi-0.20.0-linux-x64.tar.gz` | 168,822,430 | `6d750262b24700b0989f0871ad404e0414db97da2c13c2e09cc0716f1000ffaf` |
| `woi-0.20.0-SHA256SUMS.txt` | 189 | `a8215d223fb3e060535b1181c221e1fa3534ba2a28ee44db14fe895257e4599d` |

### Final input acceptance and phone handoff

All **15 input and clipboard cases passed on the final installed production APK**. Coverage includes Unicode insertion with the keyboard hidden, acknowledged node insertion and semantic paste, explicit clipboard write/read, cancellation of an in-flight read, exact empty-text behavior, live-connection Ctrl+A/C/V and Ctrl+X/V, combined modifiers, atomic rejection of an unsupported key, target mismatch, node-only typing, accessibility-selected editing and ordinary focus priority, blocking a stale editor behind another window, keyboard requests without focus movement, and safe refusal when no editor is selected. The fixture asserts the literal `set_text` receipt and paste's `applied/android_accessibility_action` receipt.

Exact-chord setup encountered the separately documented stale framework connection twice. The test app restarted its own served view through the public API before dispatching any keys, then verified the connection; those setup operations took 149 ms and 187 ms, with 2–3 ms probes. This is fixture preparation, not recovery provided for foreign applications and not additional production tool latency. The application ships no service-flag renewal, per-call text query, or speculative retry.

The original clipboard was restored locally without exporting its contents. The default keyboard, assistant, enabled accessibility-service list and disabled touch-exploration setting matched their original values. The existing microphone and secure-settings grants remained present. After instrumentation stopped the target process, the already-enabled Woi service was rebound; final inspection confirmed it was bound and not crashed. Woi's main activity was resumed, and the installed base APK's SHA-256 exactly matched the packaged release. No application data was cleared. The final state is recorded in `device-final.json`.

Full logs and intermediate failure records remain under `qa/out/acceptance-0.20.0/`; this report records their relevant results for review.

## Practical limits

An actual selected editor is still required to receive text. Android cannot guarantee a software keyboard will appear when no served editor exists. Arbitrary chords need a live input connection; supported accessibility text edits do not. During the device fixture, Android sometimes retained a connection whose non-mutating queries never reached the editor and whose key events were silently dropped. This is consistent with the Android 15 AOSP session-ID mismatch path: a fresh accessibility wrapper starts at session zero, while an existing editor binder may already expect a later session. The device's private session counter was not inspected, so this is a source-supported explanation, not direct proof of that counter's value. Toggling Woi's IME flag did not reliably repair the test connection and is not included in production. The fixture can restart its own served editor through the public API before exact-chord checks; Woi cannot perform that editor-owned restart for an arbitrary foreign app without changing focus. Asynchronous dispatch receipts therefore remain distinct from acknowledged editor actions.

The direct Media canceller references the assistant's streamed PCM AudioTrack; gpt-live references the live call's WebRTC render stream. Local MediaPlayer clips, viewer video, and other Android applications do not supply a reference to these paths. Physical attenuation depends on the device, speaker level, reference availability and acoustic environment; device measurements are reported separately from the synthetic regression.

## Sources and licensing

- Android [accessibility input connection](https://developer.android.com/reference/android/accessibilityservice/InputMethod.AccessibilityInputConnection), including asynchronous key dispatch.
- Android [soft keyboard controller](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService.SoftKeyboardController), which sets visibility policy.
- Android [clipboard access restrictions](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data).
- Android 15 AOSP [accessibility connection session initialization](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/com/android/internal/inputmethod/IRemoteAccessibilityInputConnectionInvoker.java), [editor session invalidation and command checks](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/android/view/inputmethod/RemoteInputConnectionImpl.java), and [accessibility input-method invalidation](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/android/accessibilityservice/InputMethod.java).
- SpeexDSP 1.2.1 upstream archive: `https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz`, SHA-256 `8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d`. The minimal source subset includes its original BSD-style license and provenance. The Android APK also bundles the full notice at `assets/licenses/SpeexDSP-1.2.1.txt`.
