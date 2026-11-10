# Woi 0.22.0 release verification

Release date: 2026-11-10. Package version: **0.22.0+23**. Android ARM64 version code: **2023**.

## Changes

- Add clipboard history for text and images, durable note image attachments, clipboard-aware chat drafts, and compact clipboard actions.
- Improve note editing, image previews, composer layout, selection behavior, and large-text settings layout.
- Add Android touch keyboard and bounded scrolling controls with explicit receiver and visibility results.
- Unify Android camera and screen capture status, pending/cancel controls, foreground ownership, and front/back camera switching.
- Improve live context delivery, saved-analysis follow-up answers, Stop cancellation, and explicit Reconnect recovery after capture-release failures.

## Fresh verification

| Check | Result |
|---|---|
| Full default Flutter suite | **1,358 passed, 15 skipped, 0 failed** |
| Flutter ARM64 release APK | Built successfully, 08:46:00–08:50:02 UTC |
| Matched release AndroidTest APK | Built successfully, 08:50:03–08:50:12 UTC |
| Frozen source before/after tests and builds | Exact match |
| Main APK after instrumentation build | Unchanged; Flutter and Gradle copies identical |
| Main R8 mapping after instrumentation build | Unchanged |
| APK ZIP integrity | Passed |
| Package/architecture | `dev.woi.woi`, version `0.22.0`, code `2023`, ARM64 only |
| APK signer | Verified; matches the accepted previous build |
| Independent publication-scope review | Application source/tests and selected reusable QA helpers; no private profiles, credential material, binary artifacts, or raw evidence dumps staged |

The 15 skips are existing optional provider, desktop/native-library, and offline-AEC cases. The source matched the previously accepted application snapshot exactly before the release version change. This session reran the complete default Flutter suite and rebuilt the APK rather than reusing the earlier artifact.

## Package identity

| Field | Value |
|---|---|
| Asset | `woi-0.22.0-android-arm64.apk` |
| Bytes | `102140811` |
| APK SHA-256 | `d0d1684e8dfd112731c65b266ae36844095e5d3f80b0a455635e6b42f7e616fe` |
| APK signer certificate SHA-256 | `54921a3a54191e8545842cdf135b7603043f58e9e392c77fb484c0cccd8e3f4f` |
| Source/test manifest SHA-256 (548 files) | `b01bb98a100f1d872b2ab2f7f6c8934cc2b1d3432ef43df8d698b72cf5e1172a` |
| Production manifest SHA-256 (400 files) | `1130c205ffce84b1bde2b69ef7c4521b5bead71ae19dc548227adad58611b1d0` |

The package uses the project's existing development signing configuration. The GitHub prerelease includes checksums and a provenance record bound to the release commit. APKs and R8 mappings are release/build artifacts, not Git source files.

## Device acceptance scope

An ordinary ADB inventory returned no connected device. This rebuilt package was not installed or run on a physical Android device in this release session. The matching instrumentation APK and R8 mappings were retained for the next available device session.

Physical acceptance still includes separate-UID clipboard image access, assistant file-picker select/cancel and draft return, keyboard with multiple attachments, note/chat image Paste, transcript/latest-answer Copy, and ordinary assistant/full-app transitions. Automated regressions and successful compilation do not establish these physical results.

## Reproduce the Android build

Run from `app` with the project Flutter SDK:

```sh
WOI_LIVE=0 flutter test --reporter expanded
flutter build apk --release --flavor arm64 --target-platform android-arm64
cd android
./gradlew -PwoiTestBuildType=release -Ptarget-platform=android-arm64 :app:assembleArm64ReleaseAndroidTest
```

Run the main build and instrumentation build consecutively. Do not run Flutter tests, analysis, or dependency regeneration between them; that can register development-only plugins in the release build. The reusable `source_snapshot.py`, `run_full_suite_gate.py`, and `build_android_pair.py` helpers under `qa/clipboard-editor-20261109` record and verify the source and paired artifact identities.
