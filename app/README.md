# Woi

A voice-first desktop assistant (Flutter, Linux X11 first). See `../research/REALTIME_API.md`
for the API findings these notes build on.

```sh
flutter run -d linux                              # dev
flutter build linux --release                     # release bundle
flutter analyze && flutter test                   # unit tests (no network)
WOI_LIVE=1 flutter test --tags live test/live     # real OpenAI end-to-end tests
```

## Voice backends

Pick the backend under **Settings → Voice backend**. `lib/core/voice/backend_factory.dart`
(`createVoiceBackend`) builds it, and `AppController` calls the factory on every (re)connect.

| Mode | Backend | Auth |
|---|---|---|
| **gpt-live (WebRTC)**, the default | Whatever is registered with `GptLiveHook` (the WebRTC backend, `live_*.dart`). If nothing is registered, Woi falls back to Direct realtime and shows an amber notice in the conversation. | ChatGPT login |
| **Direct realtime (gpt-realtime-2)** | `RealtimeWsBackend` on `wss://api.openai.com/v1/realtime`. The model is configurable. | ChatGPT login |
| **OpenAI API key** | `RealtimeWsBackend` | API key from settings, or `OPENAI_API_KEY` |

### Auth (`lib/core/auth/auth.dart`)
- `CodexAuthManager` reads `~/.codex/auth.json` and sends the Codex headers: `Authorization`,
  `chatgpt-account-id`, `originator: codex_cli_rs`, `version`, and `User-Agent`. For gpt-live
  it also sends `openai-alpha: quicksilver=v2`.
- When the access token is within 5 minutes of expiry, it re-reads the file and refreshes
  through `auth.openai.com/oauth/token`.
- Refresh tokens rotate and the file is shared with Codex CLI, so the new tokens are written
  back the same way Codex does it: tmp file, chmod 600, then rename, with `last_refresh` in UTC.
- Concurrent callers share a single refresh.
- Tokens are never logged. Every error string goes through `redactSecrets`.

### RealtimeWsBackend (`lib/core/voice/realtime_ws_backend.dart`)
- `session.update` sets up:
  - the tool registry specs
  - server VAD: threshold 0.5, prefix padding 300 ms, silence 500 ms, `interrupt_response`
  - transcription with `gpt-4o-mini-transcribe`
  - PCM16 at 24 kHz in both directions
- Screenshots are sent as `input_image` items.
- Function calls: the backend sends the `function_call_output` items, then a single
  `response.create` once every pending call has been answered.
- `response.done` usage becomes `Usage` events.
- **Interruption.** The server generates audio 3–10x faster than real time, so
  `PlaybackTracker` models what the user has actually heard. On `speech_started` (or
  `cancelResponse`) the backend does the following:
  - local playback stops at once
  - the rest of the response is suppressed
  - `conversation.item.truncate` is sent with the played milliseconds, *after* the
    cancelled `response.done`
  - `response_cancel_not_active` errors are ignored
  - no response is created while another one is active, tool calls are pending, the user
    is talking, or compaction is in progress
- **Reconnect.** After an unexpected close, the backend retries with exponential backoff
  (5 tries) and restores the summary plus a text mirror of the recent turns. Tool results
  for calls from the old socket are passed in as context.
- **Compaction** (`LiveContextSync.applySummary`). Runs between responses and never
  interrupts playback:
  - adds a system item holding the summary, placed before the last 3 user turns
    (`previous_item_id`, or `root`)
  - waits for `item.added`
  - deletes the older items with `conversation.item.delete`
  - never separates a `function_call` from its output
  - if anything fails, reconnects with the summary instead

  The pipeline's "Context compacted: X → Y tokens" banner fires when the compressor
  finishes.

### Context size and compaction (`lib/core/context/context_manager.dart`)
`ContextManager.estimatedTokens` is the only context figure. The input bar's meter, the
compaction trigger and the "Context compacted: X → Y" note all read it. Each backend
declares its `contextAccounting`:
- **usage** (direct realtime): the last `response.done` usage, plus a calibrated
  estimate of what changed since (new messages, minus compacted ones, plus summary growth).
- **textEstimate** (gpt-live, which reports no usage): instructions, tool and delegation
  prompts, summary, transcripts, typed text and tool output, plus the latest screenshot
  (the delegation input). Audio is not counted.

When the context passes the threshold, compaction summarizes everything before the last 3
user turns, screenshots included. `gpt-6-luna` describes the screenshots in words and
they leave the context. Compaction is skipped if it would free less than 25% of the
compressible part, and rejected if the summary is not smaller than what it replaces.

On gpt-live, applying a compaction works like this. Instructions are immutable and there
are no initial items (spec §3.2). Delegations get the summary as memory right away. Once
the call has been idle for 1.5 s, a new call is prepared muted with instructions,
summary and the recent turns. It is swapped in between turns. If anyone spoke in the
meantime it is discarded and prepared again, so a response is never interrupted.

### Responses API (`lib/core/responses/responses_client.dart`)
- ChatGPT login: `chatgpt.com/backend-api/codex/responses`. API key: `api.openai.com/v1/responses`.
- Requests always use `stream: true` and `store: false`, with the full history resent on
  each call.
- The SSE parser works on raw bytes and doesn't check Content-Type, because the ChatGPT
  endpoint doesn't send one.
- `ResponsesCompressor` (`gpt-6-luna`) produces Facts / Tasks / Files / Decisions / Screen
  lines and turns the latest screenshots into text.
- `ResponsesDelegate` (`gpt-6.1-sol`) runs a tool loop over the same `ToolRegistry`, so
  writes and commands still go through the confirmation dialogs. Its final answer is short
  enough to be spoken.

### Codex usage (`lib/core/usage/`)
- `CodexUsage` tracks the ChatGPT plan's 5-hour ("primary") and weekly ("secondary") windows: used %,
  remaining, reset time, plan. Sources: `GET chatgpt.com/backend-api/wham/usage` (what Codex CLI's `/status`
  reads; free, no model quota) at launch and every 10 min while the app is active (not while backgrounded or
  hidden, not with an API key), plus the `x-codex-primary/secondary-used-percent`, `-window-minutes`,
  `-reset-at` / `-reset-after-seconds` and `x-codex-plan-type` headers of every Responses API call
  (`ResponsesClient.onQuotaHeaders`). A 429 usage limit triggers a refetch.
- `guardModel`: when either window has less than `usageGuardPercent` (default 20, 0 = off) left, delegation
  (`GuardedDelegate`, `model_note` in the tool result) and compaction / screenshot descriptions use gpt-6-luna
  even if gpt-6.1-sol is selected. `AppController.compactionChoice` / `delegationChoice` give the model and why.
- UI: `CodexUsageMeter` (Settings → Context & models) shows "5h 34% used · week 71% used", reset times and the
  override reason; the chat gets one notice per low period. Voice: `app_control` `usage`, and
  `set_setting usage_guard`.

## UI (`lib/ui/screens/home_screen.dart`)
One top-level tab strip at the left edge: **Note, Chat, Terminal, Settings** (Ctrl+1..4;
Ctrl+, also opens Settings and Esc leaves it). `AppActions.view` owns the selected tab, so
clicks, shortcuts and voice (`app_control` `show_view`, fast paths like "open settings")
behave the same. Settings is inline in its tab (`SettingsView`), not a separate route.
All tabs share `WoiTab` (`lib/ui/widgets/tab_strip.dart`): label plus accent underline. The
note's file tabs (New, 4 recent, More) and the terminal's tabs are the quieter secondary
row inside their tab. On windows ≥1280 px wide, Ctrl+\ shows Note and Chat side by side;
Terminal and Settings stay full size and going back to Note or Chat restores the split.
Status (connection, voice phase, mic mode, context meter, camera) lives in the input bar.

Note editor (`lib/ui/notes/note_editor.dart`): one **Format** dropdown holds every Markdown
action with its shortcut (Ctrl+B, Ctrl+I, Ctrl+Alt+1..3, Ctrl+Shift+L/O/X/Q/E/H...) and
Preview (Ctrl+Shift+P; Esc goes back). **Copy** copies the whole note (Ctrl+Shift+C);
long-press or right-click picks the line, paragraph (between blank lines) or H1 section at
the cursor (`lib/core/notes/note_copy.dart`). It goes through `AppActions.copyNote`, which
voice also uses (`note_control` `copy` + `what`, fast path "copy this paragraph").

### Tests
- `test/realtime_ws_backend_test.dart` uses a fake WebSocket to cover:
  - handshake and headers
  - event parsing
  - the tool round trip
  - truncate/cancel ordering
  - reconnect
  - compaction and its reconnect fallback
- `test/auth_test.dart`: refresh against a local server, the atomic 0600 write, and redaction.
- `test/responses_test.dart`: SSE parsing, the client, delegate and compressor against a
  local server, and the factory.
- `test/live/realtime_live_test.dart` (tag `live`):
  - streams every `research/fixtures/*.wav` at real-time pace through the real pipeline,
    backend and registry, with fake clicks, typing, shell and viewer and auto-approved
    confirmations
  - a barge-in/truncate test
  - live compaction tests
  - real compressor and delegate calls
  - prints latencies; set `WOI_REALTIME_MODEL` to try another model
