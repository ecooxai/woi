# Plan (CTO)

## Architecture
- `app/` Tauri 2 app. Rust core (`app/src-tauri`): auth (codex ~/.codex/auth.json or OpenAI API key), realtime WS client,
  audio capture/playback (cpal), VAD/turn detection, screenshot (X11), input injection (xdotool/enigo), bash runner,
  file read/edit with user confirmation, sub-model delegation (Responses API), background context compression (gpt-6-luna).
- Web UI (`app/src`): transcript history (text, images, audio clips), context-size meter, settings, confirm dialogs,
  media popup windows (image/audio/video/text viewer).
- `research/` protocol probes and TTS test fixtures.

## Workstreams
1. Realtime API discovery via Codex auth (research/).
2. App scaffold + platform layer.
3. Integration: voice loop + tools.
4. Context compression + delegation.
5. UI polish, E2E tests with TTS fixtures.
