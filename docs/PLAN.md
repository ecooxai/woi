# Plan (CTO)

## Architecture
- `app/` Flutter (Dart) app — Linux first, later Android/macOS/iOS from same codebase. NO Rust, NO TypeScript, NO Tauri.
  Core (`app/lib/core`): auth (codex ~/.codex/auth.json or OpenAI API key), realtime WS client,
  audio capture/playback, turn detection, screenshot (X11), input injection (xdotool), bash runner,
  file read/edit with user confirmation, sub-model delegation (Responses API), background context compression (gpt-6-luna).
  Platform specifics behind interfaces in `app/lib/platform/` so mobile ports swap implementations.
- UI (`app/lib/ui`): transcript history (text, images, audio clips), context-size meter, settings, confirm dialogs,
  media popup windows (image/audio/video/text viewer).
- `research/` protocol probes and TTS test fixtures.

## Workstreams
1. Realtime API discovery via Codex auth (research/).
2. App scaffold + platform layer.
3. Integration: voice loop + tools.
4. Context compression + delegation.
5. UI polish, E2E tests with TTS fixtures.
