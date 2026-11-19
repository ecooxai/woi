# WOI continuation — automatic Luna agents and retained audio — 2026-11-19

## User request
- App tools for searching/editing files or notes and running Python/Bash automatically start a GPT Luna agent without an extra confirmation, and return results to the requesting conversation.
- Show all Luna agent runs in a top-level Agents tab.
- Give the add-file button a circular background matching the audio buttons.
- Compaction preserves the latest five user audio messages and summarizes text only.
- After verification, merge to main, push source, and publish a NEW APK on GitHub.

## Repository and baseline
- Public repository: https://github.com/ecooxai/woi. Worktree: /mnt/p3/project/claude/woi (alias /home/a/project/claude/woi).
- Task branch: gpt-6-astra-pro/root-luna-agents-audio-context-20261119.
- Starting revision: 33f7e53bf95338ace020466cbd775802cf8fe820. Prior app/release v0.22.2 code: 50954bdca7d21179df5a1701b069dce9b9267e7d.
- Fresh origin/main: 23b935da226b4198f69236bf3abd927058ee251c, ancestor of starting HEAD (0 main-only / 23 task-only commits). Recheck before integration; no merge/push yet.
- Tracked source was clean at task start. Existing untracked .claude, output and QA files remain untouched; never broad-stage them.
- Previous continuation archived to agent/archive/continue-context-handoff-20261119-before-luna.md.

## Ownership
- android_context_fix: automatic Luna tool delegation, run tracking/results, corresponding controller/runtime tests. Coordinate shared controller interfaces.
- context_document_ui: Agents navigation/view, circular add-file control and UI tests using agreed run tracking interface.
- audio_compaction: latest-five-user-audio retention and text-only summarization, context/media tests.
- workspace_inspector: initial branch, instructions and continuation only.
- Main coordinates integration, review and subsequent build/release specialist.

## Verified architecture
- Existing model ID: app/lib/core/usage/model_guard.dart kCheapModel = gpt-6-luna. Do not guess a replacement ID.
- app/lib/core/delegate/responses_delegate.dart and delegate_backend.dart; GuardedDelegate in model_guard.dart.
- app/lib/core/app_controller.dart connects application behavior.
- Context: app/lib/core/context/context_manager.dart, responses_compressor.dart, compressor.dart and image_tiers.dart.
- Media: app/lib/core/models/message.dart, app/lib/core/media/media_context.dart and app/lib/core/voice/context_sync.dart.
- UI: app/lib/ui/screens/home_screen.dart and app/lib/ui/widgets/input_bar.dart.
- Preserve Android assistant handoff and context_document.dart/context_meter.dart from v0.22.2.

## Build and validation
- SDK /home/a/.local/flutter, Flutter 3.47.9 / Dart 3.13.7. Android SDK /home/a/Android/Sdk.
- From app: flutter build apk --release --flavor arm64 --target-platform android-arm64. Existing Linux command: flutter build linux --release.
- No Flutter tests/analyzer concurrently with APK build. Normal pub refresh is required after tests; --no-pub previously left stale test plugin registration.
- Sample CPU/RAM every second and record elapsed times. Investigate abnormal tasks exceeding five minutes.
- Previously verified host: x86_64, 8 CPU threads, 41.96 GB RAM; no Android device attached. Recheck before claiming hardware verification.
- Credentials/private endpoint remain outside repo in temporary transport configuration. /tmp/woi_mcp.py existed and connection was reverified.

## Current state
Branch and preparation complete; implementation and validation ongoing. No new APK, merge to main, push, release or live-provider verification is yet complete.
