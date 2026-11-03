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

## Decisions log
- 2026-11-02: gpt-live-* only reachable via WebRTC (AVAS) + sideband WS; no client tools/images → actions via
  delegation.created → client DelegationExecutor (gpt-6-luna + tools + screenshot, escalate to gpt-6.1-sol).
- Direct mode: /v1/realtime WS with gpt-realtime-1.5 (native tools + images) — also the OpenAI-API-key path.
- Default backend: gpt-live-1.1 (user requirement); Direct mode selectable for lowest tool latency.

## Iteration log
- Iter 0 (scaffold + research): UI, platform layer, tools, mock backend; protocol verified; 10 TTS fixtures. Score 22/100.
- Iter 1 (direct WS backend, Responses compressor+delegate, live 9/9): 48/100.
- Iter 2 (gpt-live live 10/10, premium UI desktop+phone): 64/100. Defects: missing user transcripts, context accounting, black viewer, ~2.7s latency.
