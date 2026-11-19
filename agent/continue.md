# WOI continuation — 2026-11-19

## Requested work
1. Preserve previous conversation context when switching Android assistant mode to the main application.
2. Make the context indicator open a document-style viewer with a title; each section starts collapsed and expands on its title. Include image and audio context.
3. Build Android APK and Linux application, then push source and release outputs to GitHub.

## Repository and baseline
- Repository: https://github.com/ecooxai/woi (public), default branch main.
- Worktree: /mnt/p3/project/claude/woi (also /home/a/project/claude/woi).
- Task branch: gpt-6-astra-pro/root-context-handoff-20261119.
- Starting upstream task branch: gpt-6-astra-pro/woi-android-input-media-20261108, HEAD 4c92bd0 (v0.22.1).
- Baseline commit d2dd54404432236bc7f270ece51b6a470d56b92f preserves five pre-existing local UI source/test changes. It does not claim these changes were authored for this task.
- Many existing untracked QA files and .claude configuration remain untouched. Never broad-stage them.
- No prior AGENTS.md or agent/continue.md existed at task start, so there was nothing to archive.

## Build setup
- App version at start: 0.22.1+24; Dart SDK requirement ^3.13.7.
- Flutter SDK resolves to /home/a/.local/flutter; its executables were absent from default PATH.
- Android SDK: /home/a/Android/Sdk. Remote GitHub CLI is authenticated as ecooxai.
- Linux: run flutter build linux --release from app.
- Android arm64: run flutter build apk --release --flavor arm64 --target-platform android-arm64 from app. armv7 and x64 flavors also exist.
- Do not run flutter test/analyze concurrently with APK builds.

## Ownership and current state
- android_context_fix: native Android lifecycle/bridge, shared controller preservation, regression tests.
- context_document_ui: context indicator document/accordion and media presentation, UI regression tests; coordinate before touching shared controller.
- workspace_inspector: initial instructions, baseline, branch, continuation setup.
- Main coordinates integration, validation, build/release assignment.
- Implementation and validation are in progress. No finished APK/Linux build or task-source push has yet been verified.

## Access note
The user supplied a working MCP tunnel after the original endpoint denied access. Credentials remain in temporary private transport configuration outside the repository. A UI source read was initially review-rejected on a presumed privacy basis; repository metadata independently confirmed the source repository is public. Main coordinates the authorized reading route. Never bypass access controls.
