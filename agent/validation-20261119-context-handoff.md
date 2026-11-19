# WOI context handoff and document viewer — validation

## Frozen application source

- Build/source/tag revision: 50954bdca7d21179df5a1701b069dce9b9267e7d
- Application tree: 165b49c7e6182fc60bb000f8f5105dc3db59ec45
- Version: 0.22.2+25; Android arm64 flavor versionCode 2025.
- Task branch: gpt-6-astra-pro/root-context-handoff-20261119.
- The application revision was pushed to the existing public GitHub repository before this report.
- Release v0.22.2 and the source archive target this exact application commit. This report is a later documentation-only checkpoint.

## Verified behavior

27 Android assistant/controller regression tests passed, including same conversation/backend, retained model-request summary and text/image/audio history, continuing response streaming, queued sends, ordinary dismissal and keepalive cancellation.
19 context indicator/document tests passed, including collapsed defaults on every open, complete selectable context/tool content, images, audio controls and stop-on-collapse, missing-media feedback, and 320/400/1280 layouts.
69 broader context/lifecycle tests passed. These cover context management, pinned notes, generated-image context, live-context delivery, clipboard lifecycle and media capture.
The final analyzer reported no issues. Total distinct tests across the three groups: 115.

Image evidence checks actual decoded 240x140 image dimensions, exact synthetic pixel values and nonzero layout bounds before screenshots. Screenshots use synthetic context and media. Mobile and desktop visuals were independently reviewed.

## Native artifacts

Linux release build passed. The relocated bundle rendered a live GUI with fresh task XDG directories, an isolated DBus session and Xvfb software rendering. The app stayed alive until intentional cleanup. Executable mode is 0755; ldd found no missing libraries across 13 native files on the build host.
Android arm64 release build passed. Package dev.woi.woi, versionName 0.22.2, versionCode 2025, minSDK 24, targetSDK 36. APK Signature Scheme v2 verification passed.
The signing certificate matches the prior v0.22.1 APK, whose bytes were independently matched to the checksum published with that GitHub release. Installing as an update preserves the existing app's data; do not uninstall merely to install this release.

## Limits of verification

No Android handset, emulator, AVD or system image was available. Android lifecycle tests exercise simulated platform events and model-context requests; native device lifecycle ordering was not executed.
The isolated Linux GUI smoke attempted the default live provider and received HTTP 404. Live-provider end-to-end behavior was therefore not validated; the application remained running and rendered the error. No real chat history was used. This release does not change unrelated backend/authentication defaults.
Linux was built on CachyOS/Arch x86_64. Packaged ELF objects require GLIBC 2.38 and GLIBCXX_3.4.32 (CXXABI_1.3.9), plus GTK3/GLib, graphics/window-system and audio libraries. The bundled JNI FFI asset links an OpenJDK21 libjvm, but neither libdartjni nor libjvm was mapped during basic startup. Java is not claimed as a basic-launch dependency.

## Timings and resources

The monitor sampled /proc CPU/RAM every second. RSS values below are MiB for the observed process tree; reused Gradle daemon memory can be outside that tree. Host memory was also sampled. The successful Android rebuild peaked at 18029.90 MiB total host memory in use and averaged 44.59% host CPU; Linux build averaged 25.34% host CPU.
Every test/build completed under five minutes. A known failing UI fixture run was stopped after a fake-async file deletion stalled; it was fixed before later passing runs.

| Run | Exit | Wall seconds | Peak process-tree RSS MiB |
|---|---:|---:|---:|
| android-regression-1 | 1 | 30.830 | 1230.02 |
| context-ui-regression-1 | 130 | 93.251 | 1207.52 |
| android-regression-2 | 0 | 19.566 | 982.57 |
| context-ui-regression-2 | 1 | 16.468 | 1214.45 |
| context-ui-regression-3 | 0 | 7.200 | 1058.77 |
| analyze-1 | 1 | 10.267 | 647.62 |
| analyze-2 | 0 | 6.185 | 578.29 |
| context-lifecycle-regression | 0 | 6.169 | 1099.09 |
| context-ui-image-proof | 0 | 8.239 | 993.29 |
| analyze-final | 0 | 6.166 | 659.27 |
| linux-build | 0 | 84.540 | 2077.43 |
| android-build | 1 | 121.553 | 2573.36 |
| android-build-2 | 0 | 142.580 | 196.11 |
| linux-runtime-smoke | 0 | 9.285 | 390.99 |

## Corrections made during verification

- Corrected test setup that deliberately reconnected before asserting handoff session counts, and received platform events in the proper test async zone; behavior assertions were retained.
- Corrected lazy heading hit testing and real-async file IO in widget fixtures.
- Added a local modal ScaffoldMessenger so audio failure feedback is visible above the context viewer, and ensured a 48-pixel audio touch target.
- Waited for decoded image pixels before capture instead of treating an Image widget's existence as proof of rendering.
- Fixed two analyzer info lints.
- The first APK build used --no-pub after tests and failed because test-generated plugin registration referenced integration_test. The exact documented build command regenerated release metadata and passed. Do not use that shortcut after tests; do not run Flutter tests/analyzer concurrently with APK builds.

## Iteration self-assessment

These are engineering self-assessments, not an objective certification.
- 60/100: initial regressions exposed incorrect harness setup and an incomplete media-error test.
- 70/100: handoff assertions passed; two UI fixture failures remained.
- 84/100: 115 tests and analyzer passed, but actual image pixels still required visual proof.
- 87/100: decoded pixels and mobile/desktop visuals were verified; native builds remained.
- 93/100: native builds and APK update-signing checks passed.
- 94/100 at this documentation checkpoint: Linux GUI startup accepted and source pushed; archive/publication verification follows in the release provenance.

## Distribution

Release coordinates: https://github.com/ecooxai/woi/releases/tag/v0.22.2
Artifact names include gpt-6-astra-pro-build-release-flutter.
The APK, Linux tar bundle, exact-commit source archive, provenance JSON and SHA256SUMS are prepared and verified by the release pipeline after this documentation checkpoint. The release metadata and provenance are the authority for uploaded artifact hashes and publication status.
