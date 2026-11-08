# Woi 0.19.0 acceptance record

Branch: `gpt-6-astra-pro/woi-chat-input-shortcuts-20261108`.
Base: `1ae9c76` (Woi 0.18.0). App version: `0.19.0+20`.

## Requested behavior

- Place the assistant profile icon above its message instead of at the left.
- Use white user message bubbles and very pale green assistant bubbles.
- Start applicable tool calls before explanatory text, especially pointer and keyboard actions.
- Preserve literal typing and support explicit keyboard shortcuts, including Ctrl+C/V/X/A and multiple modifiers such as Ctrl+Alt+Shift+A.
- Support Android typing and shortcuts against the underlying app in background and assistant modes, with clear errors when the platform cannot deliver an action.

## Chat presentation

Assistant avatars now sit above the bubble. User bubbles are white; assistant bubbles use `#F4FAF2`. Both themes use readable foreground colors for body text, metadata, timestamps, source links, audio controls, status labels, and message actions. The screenshot preview palette is scoped to these bubbles so tool/system previews retain their existing theme. User text remains above images; generated image dimensions, file size, and generation time remain available.

Focused widget coverage checks vertical avatar/bubble placement at desktop and 360-pixel widths, light/dark themes, readable foreground contrast, streaming/listening states, image completion/failure, and metadata/source/action content.

## Input timing and keyboard behavior

All relevant assistant/delegate prompts request needed tool calls before acknowledgements, explanations, or plans. Completed streamed Responses function calls enter the existing validated tool registry immediately, while the remainder of the model response can still be arriving. Calls run serially and are deduplicated by call ID across stream events and final-response fallback. Partial JSON is never executed.

Explicit shortcut requests take the deterministic route without a planning-model round trip. Unquoted `type Ctrl+C` and `Ctrl+C` use `send_keys`; `type "Ctrl+C"` and `type the text Ctrl+C` remain literal text. Explanations, questions, and mixed requests keep the normal interpretation path. Existing pointer routing, Luna settings, voice timing preferences, and control indicators are preserved.

The shared parser retains Ctrl, Alt, Shift, and Meta/Super combinations. Multi-chord sequences are validated before any input. Single modifier taps remain supported; incomplete combinations of several modifiers fail clearly. Linux's legacy key-combo entry point uses the same parser and releases modifiers consistently.

Stop, chat changes/deletion, and shutdown invalidate queued delegated calls. Explicit Stop also cancels silent pending tools and rejects pending edit countdowns. Interrupting speech alone does not invalidate background tasks; the separate explicit-Stop hook owns tool cancellation. Spoken Apply suppresses its redundant response without cancelling the accepted edit or the rest of its task. Incomplete responses, premature stream EOF, and cancellation do not automatically replay actions that were already dispatched.

## Android input path

Android uses one structured, prevalidated native batch per `send_keys` request. It preserves exact modifiers, pins the external target and editor generation, steps the assistant panel aside for the batch, and restores the panel afterward. Readiness polling does not send input, and a partially delivered sequence is never blindly retried. An immediate native cancellation epoch covers the assistant handoff, editor-readiness waits, and later batch operations, independently of queued indicator cleanup.

On Android 13/API 33 and later, Woi's existing accessibility input method delivers literal Unicode text through `commitText` and exact chords through modifier/key down/up events. Text entry does not overwrite the clipboard. Focused-editor connections also support editors that do not expose an editable accessibility node. Semantic copy/cut/paste/select-all actions can use editor context-menu operations or accessibility-node fallbacks. Older Android versions retain supported editable-node operations; arbitrary raw chords require the newer input-connection API.

All modifiers are released in cleanup paths, including cancellation, focus changes, and errors. Unknown targets, missing external focus, stale input connections, unsupported keys, and invalid mixed navigation/editor batches return errors. A successful void Android API call is reported as dispatched, not as proof that the target application handled the shortcut. Explicit app targets are checked instead of silently ignored.

No new keyboard selection, permissions, or default-assistant changes are introduced. Existing accessibility-service recovery policy remains unchanged. Password/opaque-node fallback does not reconstruct masked text or silently replace the clipboard.

## Validation

The focused gate passed with zero analyzer issues and **147 passing Flutter tests**. After the final cancellation corrections, a separate **46-test voice/backend/edit/streaming suite** passed, including Apply during active narration and preservation of work during ordinary input and echo suppression. Its final evidence is `qa/out/acceptance-0.19.0/audio-cancellation-focused.log`; the initial muted-microphone fixture failure is preserved separately. After the native Stop fix, the Android platform suite passed **18 tests** and the standalone native keyboard helper passed **16 JVM tests**, covering immediate cancellation despite queued indicator cleanup, stale focus-handoff requests, fresh approved actions, modifiers, cleanup, target matching, batch validation, and Unicode/reversed-selection insertion. Evidence: `qa/out/acceptance-0.19.0/android-keyboard-stop-focused.log` and `android-keyboard-jvm-stop.json`/`.log`; the earlier 13-test native run is retained separately.

An isolated real Linux editor on display `:76` verified production text entry, Ctrl+A selection, Ctrl+C copy, Ctrl+X cut, Ctrl+V paste, semantic edit actions, Ctrl+Alt+Shift+A, Meta+Ctrl+Alt+Shift+F9, legacy Ctrl+Alt+Shift+F8, all modifiers released afterward, and rejection of malformed sequences before any valid prefix is delivered. Its temporary editor, Openbox, and Xvfb processes were cleaned up. Evidence: `qa/out/acceptance-0.19.0/linux-keyboard/native-report.json` and `native.log`.

The final frozen-source Flutter gate passed with **zero analyzer issues, 1,002 passing tests, and 15 opt-in checks skipped** (`WOI_LIVE=0`). Analysis took 7.02 seconds and the full test command took 109.85 seconds. All six final gates passed on that same source; build, native UI, and artifact results follow. The app-source fingerprint covers all tracked and nonignored app sources, configuration, and tests, including the new Android native implementation.

## Final build and artifact gates

| Gate | Result |
| --- | --- |
| Final static analysis | Passed; zero issues |
| Full offline Flutter suite | 1,002 passed; 15 opt-in checks skipped |
| Linux x64 release build | Passed in 88.75 seconds; source unchanged |
| Android ARM64 release build | Passed in 177.09 seconds; source unchanged |
| Android device fixture compilation | Passed in 16.85 seconds; Kotlin, Java, and test APK packaged; no installation |
| Native Android Gradle unit tests | 16 passed; zero failures/errors/skips; completed in 75.46 seconds |
| Native Linux UI inspection | Passed; nine release-binary screenshots, both themes and widths; no render/overflow/unhandled-exception matches |
| Release package verification | Both archives and versioned checksum manifest passed; source files and binaries unchanged |

Frozen app source: **455 files**, SHA-256 `4e2d409695c04cf619668018629337b5906eab1686531c59ba2c2baf004e6828`.

Root independently inspected `01-desktop-light-messages.png`, `03-desktop-light-images.png`, and `06-narrow-dark-messages.png` in `qa/out/ui-native-019/shots/`. They show the assistant avatar above the bubble, white user surfaces, very pale green assistant surfaces, readable dark-theme text and metadata, user text above an image, and the retained image generation time/file-size caption. The cropped older message at the top of the narrow view is normal bottom-following scroll, not a layout overflow. The native inspection also verified the enlarged image view (`09-narrow-dark-image-large.png`), showing 1024 × 1024 px, 63.9 KB, and 15.7 seconds for the reused QA image. Both isolated sessions were fully stopped; no QA process, display socket, or session-state file remains. Evidence: `qa/out/acceptance-0.19.0/native-final.json` and `.md`.

## Verified downloads

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `woi-0.19.0-android-arm64.apk` | 101,340,724 | `ed635e1ed36132d02125415ebed67e731ed3c505671d38d39159aee47ddc06fd` |
| `woi-0.19.0-linux-x64.tar.gz` | 168,818,775 | `691d6fe14055ac972235ace18f1460678f1a8ab330504dd680114a89150e27c5` |
| `woi-0.19.0-SHA256SUMS.txt` | 189 | `480b2b6e53030963c3043343c95889470b828a8272bb8405e1fe611350c7bf96` |

The Linux archive was checked against all 54 bundle entries, including 38 files, their contents and modes. `libapp.so` SHA-256: `72ee8fd2555775dcb61949d14f5e890e7742c447fe24590d7b117bbcde165522`.

The Android APK is `dev.woi.woi`, version `0.19.0`, version code `2020`, ARM64 only. All 117 ZIP entries passed integrity checks; all 22 native libraries are ELF64 AArch64. Its signature verifies and matches the 0.18.0 signer, SHA-256 `54921a3a54191e8545842cdf135b7603043f58e9e392c77fb484c0cccd8e3f4f`. The versioned checksum file verifies both downloads. Evidence: `qa/out/acceptance-0.19.0/release-artifacts.json` and the individual Linux/Android artifact records.

## Device validation scope

The connected Android phone's existing application session, accessibility configuration, keyboard selection, and default assistant were preserved. An instrumentation fixture targets a neutral editor and covers Unicode insertion, exact Ctrl shortcuts, combined modifiers, atomic rejection, and target mismatch. Its Kotlin and Java sources compiled and the instrumentation APK was packaged successfully. It is prepared for later on-device execution; this release does not claim that background/assistant mode was exercised on that phone. Compilation and native helper tests are recorded separately from live-device behavior.

## Platform references

Android's [AccessibilityInputConnection API](https://developer.android.com/reference/android/accessibilityservice/InputMethod.AccessibilityInputConnection) documents the Android 13/API 33 text and key-event methods and their asynchronous delivery semantics. The existing service uses [FLAG_INPUT_METHOD_EDITOR](https://developer.android.com/reference/android/accessibilityservice/AccessibilityServiceInfo#FLAG_INPUT_METHOD_EDITOR).
