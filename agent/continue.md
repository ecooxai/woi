# WOI continuation — context handoff release

## Source and release coordinates
- Task branch: gpt-6-astra-pro/root-context-handoff-20261119.
- Frozen application/build/tag revision: 50954bdca7d21179df5a1701b069dce9b9267e7d.
- Frozen application tree: 165b49c7e6182fc60bb000f8f5105dc3db59ec45.
- Version 0.22.2+25; arm64 Android versionCode 2025.
- Release coordinates: https://github.com/ecooxai/woi/releases/tag/v0.22.2.
- Application code is pushed. This handoff/report commit is documentation-only; release archives and uploads follow this checkpoint. Check the release and provenance before repeating distribution work.

## Changes completed
- Android assistant -> main-app handoff is distinct from dismissal, preserves the shared session/context and queued/in-flight work, and guards stale Activity/session events.
- The context indicator opens a titled document with every section collapsed on opening. It includes instructions, tool definitions, pinned note, summary, complete active messages, images and playable audio. Error feedback stays visible above the modal.
- Pre-existing local message/markdown improvements were preserved in baseline commit d2dd544.

## Verification
- 27 assistant/controller tests, 19 document/indicator tests, 69 broader context/lifecycle tests: 115 distinct passes.
- Analyzer clean. Decoded synthetic image pixels and mobile/desktop layouts reviewed.
- Linux and signed Android release builds pass; Linux relocated GUI startup verified.
- APK signer matches published v0.22.1, package dev.woi.woi; update installation retains app data.
- No physical/emulated Android runtime available. Linux fresh-profile default live-provider call returned HTTP404; live-provider end-to-end remains unverified.
- Full evidence/timings: agent/validation-20261119-context-handoff.md and release provenance.

## Build operations
- Flutter SDK: /home/a/.local/flutter, Flutter3.47.9/Dart3.13.7.
- From app: flutter build linux --release; flutter build apk --release --flavor arm64 --target-platform android-arm64.
- Do not run Flutter tests/analyzer during APK build. Use normal pub refresh for APK after tests; --no-pub left test plugin registration stale during this task.
- Monitor CPU/RAM each second and record wall time. Do not broad-stage .claude, previous QA artifacts or output folders.
- Linux x86_64 requires GLIBC2.38 and GLIBCXX_3.4.32; see release README for core vs optional JNI dependencies.

## Future work
No requested feature implementation remains. Optional follow-up is a real Android assistant->main lifecycle run and live-provider verification in the user's configured environment. Preserve the existing worktree and review actual release/branch state before continuing.
