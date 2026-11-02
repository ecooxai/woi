# OpenAI realtime voice + Responses API via the ChatGPT/Codex login

Verified 2026-11-02 using `~/.codex/auth.json` (`auth_mode: chatgpt`, Plus plan, `OPENAI_API_KEY: null`).
Every section marked **VERIFIED** was observed in real runs of the scripts in this directory; sections marked
**UNTESTED** are not verified. Tokens never appear in logs (`codex_auth.redact`).

| File | Purpose |
|---|---|
| `codex_auth.py` | load / redact / refresh the Codex login; `chatgpt_headers()`, `live_headers()`, `api_key_headers()` |
| `probe_realtime.py` | realtime probe: `--transport ws` (gpt-realtime-*) or `--transport live` (gpt-live-*), click_screen tool, wav/text/image input, `--barge-in`, `--scenario interrupt / errors`, latency; audio saved to `out/` |
| `probe_responses.py` | Responses API probe (`--matrix` runs every check below) |
| `make_fixtures.py` | TTS fixtures via the realtime model, then transcript verification and an intent check |
| `fixtures/*.wav`, `fixtures/manifest.json` | 10 utterances (24 kHz mono s16), file → text → expected tool/args → verified transcript → observed tool |
| `fixtures/test_screen.png` | 256x256 test image (white background, red circle in the center, blue bar at the top) |

Setup: `uv venv .venv && uv pip install websockets httpx numpy aiortc` (aiortc is only needed for `--transport live`).

---

## 0. TL;DR

There are **two working voice paths** with a ChatGPT login and **no API key**:

| | **A. Realtime WS** (recommended default) | **B. gpt-live over WebRTC** |
|---|---|---|
| Models | `gpt-realtime-1.5` (Codex default), `gpt-realtime`, `gpt-realtime-2`, `gpt-realtime-mini`, `gpt-realtime-2025-08-28` | `gpt-live-1.1`, `gpt-live-1`, `gpt-live-1-codex` |
| Connect | `wss://api.openai.com/v1/realtime?model=M` + `Authorization: Bearer <access_token>` | `POST https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas` (SDP offer in JSON) → WebRTC; plus sideband `wss://api.openai.com/v1/live/{call_id}` |
| Mic audio | `input_audio_buffer.append` (base64 pcm16 24 kHz) | **RTP only** (Opus track). Cannot be sent as WS events |
| Function tools | yes (`session.tools`) | **no**. The model emits `delegation.created`; the client answers with `delegation.context.append` |
| Images | yes (`input_image`) | **no** (context is text only) |
| Token usage | `response.done.response.usage` (exact) | **none** (only `audio_duration_ms`) |
| Barge-in | server VAD + client `conversation.item.truncate` | native full duplex |
| Speech-end → first audio | ~1.7–2.0 s (server_vad 500 ms) | ~1.0–1.1 s |
| Connect time | ~1.2–1.5 s | ~1.9–2.1 s (one run 4.2 s) |
| Session lifetime | `expires_at` = +3600 s | `expires_at` = +7200 s |

`gpt-live-*` on the plain `/v1/realtime` WebSocket returns `invalid_model` ("not supported in realtime mode").
Direct `wss://api.openai.com/v1/live?model=gpt-live-1.1` is access-gated: "Voice session access denied."
gpt-live works with ChatGPT auth **only** through the WebRTC call path (what Codex voice mode does).

Text models through the same login: `POST https://chatgpt.com/backend-api/codex/responses` with `gpt-6-luna`
and `gpt-6.1-sol`, `stream: true` and `store: false` (both mandatory); `instructions` is optional; images work.

---

## 1. Auth (VERIFIED)

`~/.codex/auth.json` → `tokens.access_token` (JWT, `aud: https://api.openai.com/v1`,
`client_id: app_EMoamEEZ73f0CkXaXp7hrann`, about 9 days of validity) and `tokens.account_id`.

```
Authorization: Bearer <access_token>
chatgpt-account-id: <account_id>          # required for chatgpt.com, optional for api.openai.com/v1/realtime
originator: codex_cli_rs
version: 0.166.0
User-Agent: codex_cli_rs/0.166.0 (...)
openai-alpha: quicksilver=v2              # only for the gpt-live paths (call creation + /v1/live sideband)
```

* A bad or expired token on `/v1/realtime` produces `error.code = "invalid_api_key"`.
* Refresh (verified against `codex-rs/login/src/auth/manager.rs`): `POST https://auth.openai.com/oauth/token`
  with JSON `{"client_id","grant_type":"refresh_token","refresh_token"}`. A bad refresh token gives
  401 `invalid_refresh_token`.
* **Refresh tokens rotate, and auth.json is shared with the Codex CLI.** Refresh only when `exp` is close, and
  write the new tokens back (`codex_auth.refresh_tokens(auth, persist=True)`); otherwise you log Codex out.
  `codex_auth.ensure_fresh()` does exactly this.

### API-key variant (UNTESTED: no key available)

```
wss://api.openai.com/v1/realtime?model=gpt-realtime-1.5
Authorization: Bearer sk-...
```
Same events and schema as Path A (Path A is the public GA Realtime API, just authenticated by the ChatGPT JWT).
From the Codex sources: with an API key, Codex uses `POST /v1/realtime/calls` (multipart SDP) for WebRTC and
`wss://api.openai.com/v1/live` (with `openai-alpha: quicksilver=v2`) for gpt-live. Whether a key gets past the
"Voice session access denied" gate on `/v1/live` is unknown.

---

## 2. Path A: `/v1/realtime` WebSocket (VERIFIED)

### 2.1 Connect
```
wss://api.openai.com/v1/realtime?model=gpt-realtime-1.5
Authorization: Bearer <chatgpt access_token>
```
The first server event is `session.created`. Its defaults: voice `alloy`, `server_vad` (threshold 0.5, prefix 300 ms,
silence 200 ms), no transcription, `max_output_tokens: "inf"`, `truncation: "auto"`, `expires_at` = now + 3600 s.

Models that **work**: `gpt-realtime-1.5`, `gpt-realtime`, `gpt-realtime-2`, `gpt-realtime-mini`,
`gpt-realtime-2025-08-28`. Models that **fail**:
- `gpt-realtime-1.5-mini`, `gpt-4o-realtime-preview` and `gpt-4o-mini-realtime-preview` return `model_not_found`.
- `gpt-live-*` returns the error below, then close code 4000:
  ```
  {"type":"invalid_request_error","code":"invalid_model","message":"Model \"gpt-live-1.1\" is not supported in realtime mode..."}
  ```

Voices: `alloy ash ballad coral echo sage shimmer verse marin cedar` (`marin` / `cedar` recommended).
An unknown voice returns `invalid_value` with exactly this list.

### 2.2 session.update (accepted and echoed by `session.updated`)
```json
{"type": "session.update", "session": {
  "type": "realtime",
  "instructions": "You are a concise voice assistant ...",
  "output_modalities": ["audio"],
  "audio": {
    "input": {
      "format": {"type": "audio/pcm", "rate": 24000},
      "noise_reduction": {"type": "near_field"},
      "transcription": {"model": "gpt-4o-mini-transcribe"},
      "turn_detection": {"type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300,
                         "silence_duration_ms": 500, "create_response": true, "interrupt_response": true}
    },
    "output": {"format": {"type": "audio/pcm", "rate": 24000}, "voice": "marin"}
  },
  "tools": [{"type": "function", "name": "click_screen",
             "description": "Click the mouse at absolute screen pixel coordinates. The screen is 1920x1080.",
             "parameters": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
                            "required": ["x", "y"], "additionalProperties": false}}],
  "tool_choice": "auto"
}}
```
* `turn_detection: null` disables VAD. The client then calls `input_audio_buffer.commit` + `response.create`
  (this is how `make_fixtures.py` transcribes).
* `{"type": "semantic_vad", "eagerness": "low|medium|high|auto"}` is also accepted.
* `"output_modalities": ["text"]` gives text-only responses (`response.output_text.*`).
* Unknown keys produce `unknown_parameter` (`"param": "session.bogus"`).
* Per OpenAI docs, the voice cannot be changed after the session has produced audio (not re-tested here). `make_fixtures.py` opens one session per utterance.

### 2.3 Client events
Supported client events, according to the server's own error message:
`session.update, session.close, input_audio_buffer.append, session.input_audio_buffer.append,
input_audio_buffer.commit, input_audio_buffer.clear, conversation.item.create, conversation.item.truncate,
conversation.item.delete, conversation.item.retrieve, response.create, response.cancel`.

**Audio** (pcm16 LE, mono, 24 kHz, base64; we send 100 ms chunks at mic pace):
```json
{"type": "input_audio_buffer.append", "audio": "<base64>"}
```
**Text**:
```json
{"type": "conversation.item.create", "item": {"type": "message", "role": "user",
  "content": [{"type": "input_text", "text": "Click the center of the screen"}]}}
{"type": "response.create"}
```
**Image** (VERIFIED: the model described `test_screen.png` correctly: "a large red circle ... and a solid blue
horizontal rectangle positioned near the top ... The background is white." The image cost 194 `image_tokens`):
```json
{"type": "conversation.item.create", "item": {"type": "message", "role": "user", "content": [
  {"type": "input_image", "image_url": "data:image/png;base64,...."},
  {"type": "input_text", "text": "Describe this image"}]}}
{"type": "response.create"}
```

### 2.4 Server events (observed)
| Event | Use |
|---|---|
| `session.created`, `session.updated` | full session object |
| `input_audio_buffer.speech_started` `{audio_start_ms, item_id}` | user started talking. Stop local playback (barge-in) |
| `input_audio_buffer.speech_stopped` `{audio_end_ms}` → `input_audio_buffer.committed` `{item_id}` | end of user turn |
| `conversation.item.added` / `conversation.item.done` | items (user audio item, function_call, assistant message) |
| `conversation.item.input_audio_transcription.delta` / **`.completed`** `{item_id, transcript, usage}` | **user transcript** (arrives asynchronously, often *after* the response has started) |
| `response.created` | |
| `response.output_item.added` / `.done`, `response.content_part.added` / `.done` | |
| **`response.output_audio.delta`** `{response_id, item_id, delta}` | assistant audio (pcm16 24 kHz base64) |
| `response.output_audio.done` | |
| `response.output_audio_transcript.delta` / **`.done`** `{transcript}` | **assistant transcript** |
| `response.function_call_arguments.delta` / **`.done`** `{name, call_id, arguments}` | tool call |
| **`response.done`** `{response: {id, status, status_details, output[], usage}}` | `status` is `completed`, `cancelled` (`status_details.reason` = `client_cancelled` or `turn_detected`), etc. |
| `rate_limits.updated` | `[{name:"tokens", limit:15000000, remaining, reset_seconds}]` |
| `conversation.item.truncated`, `conversation.item.retrieved` | |
| `error` `{error: {type, code, message, param, event_id}}` | see 2.8 |

### 2.5 Function-call round trip (VERIFIED with `fixtures/02_click_center.wav`)
```
<- response.function_call_arguments.done  name=click_screen call_id=call_GJU... args={"x": 960, "y": 540}
<- response.done (output = [function_call], no audio)
-> {"type":"conversation.item.create","item":{"type":"function_call_output","call_id":"call_GJU...","output":"{\"ok\":true,...}"}}
-> {"type":"response.create"}
<- ... response.output_audio.delta ...  transcript "Done, I clicked the center of the screen."
```
* `gpt-realtime-1.5` calls the tool silently. `gpt-realtime-2` speaks first ("Okay, I'll click the center of the
  screen now."), then calls the tool, then says "Done."
* The user transcript `.completed` event often arrives **after** the function call.
* With the 9-tool desktop toolset in `make_fixtures.py`, all 10 fixtures produced the expected tool, including
  `delegate_task` for the "complex task" sentence and `stop` for "Stop". See the `observed_*` fields in
  `manifest.json`.

### 2.6 Interruption (VERIFIED)
* **Server-side**: with `interrupt_response: true`, user speech during an *in-progress* response cancels it.
  The result is `response.done` with `status: "cancelled"`, `status_details.reason: "turn_detected"`.
  **Gotcha:** a mid-sentence pause (e.g. "This is a complex task: ...") makes server VAD split the utterance. The
  first auto-response gets cancelled with `turn_detected`, and a second response follows for the full turn.
  Always wait for a `response.done` that was not cancelled.
* **Client-side**: `{"type":"response.cancel"}` produces `response.done` with `status: "cancelled"` and
  `reason: "client_cancelled"`.
  **Gotcha:** the server generates audio about 3–10x faster than real time (a 6 s reply is fully generated in
  about 1.5 s). By the time the user interrupts, the response is usually already `completed`, and
  `response.cancel` then returns `response_cancel_not_active`. The client therefore has to:
  1. stop local playback,
  2. send `{"type":"conversation.item.truncate","item_id":<assistant item>,"content_index":0,"audio_end_ms":<ms actually played>}`
     and receive `conversation.item.truncated`.
  `conversation.item.retrieve` confirmed that truncation cuts the stored audio to `audio_end_ms` **and clears the
  transcript**. The model then only "remembers" what was played. In the run, the follow-up was:
  "You interrupted right after I said, 'I can share a story.'"
* **Ordering gotcha:** send `truncate` **after** the cancelled `response.done`. In one run where it was sent right
  after `response.cancel` (before the done event), the item kept its full audio (187 audio tokens, roughly 9 s,
  were billed on the next turn), and the model quoted words that had never been played.
* `probe_realtime.py --barge-in --wav fixtures/10_stop.wav`: the story is "played" for 2.8 s, the user says "Stop",
  the client truncates to 2782 ms, and the model replies "Sure, I'll stop the story here."

### 2.7 Usage / context meter (VERIFIED)
Every `response.done.response.usage`:
```json
{"total_tokens": 316, "input_tokens": 192, "output_tokens": 124,
 "input_token_details": {"text_tokens": 167, "audio_tokens": 25, "image_tokens": 0, "cached_tokens": 128,
                         "cached_tokens_details": {"text_tokens": 128, "audio_tokens": 0, "image_tokens": 0}},
 "output_token_details": {"text_tokens": 20, "audio_tokens": 104}}
```
`input_tokens` is the whole context the model saw for that response, so it works directly as a **context meter**
(the context grows with each turn; truncated audio shrinks it). Audio costs about 10 tokens/s for input and
about 20 tokens/s for output. Transcription usage is reported separately on
`conversation.item.input_audio_transcription.completed.usage`. `rate_limits.updated` gives the token bucket
(15M).

### 2.8 Error shapes (VERIFIED, `--scenario errors`)
```json
{"type":"error","event_id":"...","error":{"type":"invalid_request_error","code":"...","message":"...","param":...,"event_id":null}}
```
| Trigger | `code` | `message` (abridged) |
|---|---|---|
| unknown event type | `invalid_value` | "Invalid value: 'bogus.event'. Supported values are: 'session.update', ..." (`param: "type"`) |
| bad voice | `invalid_value` | "Supported values are: 'alloy', ..., 'marin', and 'cedar'." (`param: session.audio.output.voice`) |
| unknown session key | `unknown_parameter` | "Unknown parameter: 'session.bogus'." |
| function_call_output with unknown call_id | `invalid_tool_call_id` | "Tool call ID 'nope' not found in conversation." |
| cancel with nothing running | `response_cancel_not_active` | "Cancellation failed: no active response found" |
| truncate unknown item | `item_truncate_invalid_item_id` | "Item with item_id not found: item_missing" |
| commit empty buffer | `input_audio_buffer_commit_empty` | "buffer too small. Expected at least 100ms of audio ..." |
| gpt-live model on /v1/realtime | `invalid_model` | "... is not supported in realtime mode" (then close 4000) |
| unknown model | `model_not_found` | |
| bad token | `invalid_api_key` | |

Errors do not close the session (except at model/auth level during connect).

### 2.9 Limits
* `session.expires_at` = creation + 3600 s (60 min max session; not run to expiry).
* `max_output_tokens: "inf"`, `truncation: "auto"` (the server drops old context when full).
* Rate limit bucket of 15,000,000 tokens (`rate_limits.updated`). ChatGPT plan usage shows up in the
  `x-codex-*` headers of the Responses API (§4), not here.

---

## 3. Path B: gpt-live-* via WebRTC "AVAS" (VERIFIED for gpt-live-1.1, gpt-live-1, gpt-live-1-codex)

This is a "frameless" full-duplex model (quicksilver v2). It is always listening and always emitting a continuous
24 kHz stream (silence included). There are no responses to create and no VAD to configure.

### 3.1 Create the call
1. Create an `RTCPeerConnection` with **`iceServers=[]`**. With aiortc defaults, STUN gathering takes about 6 s;
   with no ICE servers it takes 20–50 ms, and host candidates are enough.
2. Add a sendrecv audio track (mic). Create a data channel `oai-events`, which carries the same JSON events as
   the sideband minus audio.
3. Send the offer:
```
POST https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas
Authorization / chatgpt-account-id / originator / version / User-Agent   (chatgpt headers)
openai-alpha: quicksilver=v2
Content-Type: application/json

{"sdp": "<offer sdp>",
 "session": {"model": "gpt-live-1.1",
             "instructions": "...",
             "audio": {"output": {"voice": "cove"}},
             "delegation": {"type": "client"}}}
```
→ `201`. The body is the **SDP answer**, and `Location: /v1/realtime/calls/rtc_u23_...` gives the call_id.
* `openai-alpha: quicksilver=v1` returns 400 "AVAS requires OpenAI-Alpha: quicksilver=v2."
* **Gotcha:** an invalid session (e.g. `tools`, a v2 voice such as `marin` or `alloy`, unknown fields) still
  returns 201, but the session dies silently. The sideband then gets HTTP 404 or a handshake timeout, and no
  audio arrives.
* Voices (v3): `cove` (default), `juniper maple spruce ember vale breeze arbor sol aube bubbie haetsal hanul
  himari leher miko neer porto rindo rio rivage selva sonna tinta viola`.

### 3.2 Sideband WebSocket
```
wss://api.openai.com/v1/live/{call_id}     (same headers incl. openai-alpha: quicksilver=v2)
```
Server events:
| Event | Notes |
|---|---|
| `session.started` `{session:{id, status:"active", expires_at}}` | `expires_at` = +7200 s |
| `session.output_audio.delta` `{delta, start_ms, end_ms}` | continuous 200 ms frames (9600 bytes, 24 kHz s16) including silence. The first frame has `start_ms = 200` |
| `session.input_audio.append` `{audio}` | echo of the mic as the server heard it (200 ms frames) |
| `input_transcript.added`, `output_transcript.added` `{item:{text}, start_ms, end_ms}` | incremental words |
| **`turn.created` / `turn.delta` / `turn.done`** `{turn:{id, role:"user"\|"assistant", start_ms, end_ms, transcript}}` | **user / assistant transcripts**. `turn.done.transcript` is the final text. On barge-in it is cut to what was spoken |
| **`delegation.created`** `{item:{id, type:"delegation", content:[{type:"input_text", text}], handoff_id, target:"client", user_bidi_turn_id}, offset_ms}` | the model wants an action done ("tool call") |
| `delegation.context.appended`, `session.context.appended` `{start_ms, end_ms}` | ack |
| `session.updated` | |
| `session.usage.updated` `{usage:{audio_duration_ms, backend_model_usage:[]}, usage_limit}` | **no token counts**. Seen only in longer sessions |
| `error` `{error:{type, code, message, param}}` | |

Supported client events (from the server's error list):
`session.update, output_audio.playback.play, session.feedback, input_audio.pause, input_audio.resume,
session.context.append, response.item.create, response.create, delegation.context.append,
delegation.function_call_output.create, transport.dtmf.send, session.close`.

* **Mic audio must go over RTP.** `input_audio.append` on the sideband is rejected with an error.
* `session.context.append` `{"content":[{"type":"input_text","text":...}], "channel": "speakable"|"commentary"|"developer"}`
  injects text, and the model reacts to it. Content must have `text`, so **no images**. We used it to make
  gpt-live read text verbatim.
* `instructions` and `voice` are **immutable** after creation (`immutable_field_update`). `session.tools`,
  `session.audio.input`, `session.model` and `session.initial_items` are unknown fields.
* `response.create` errors with "requires a session with Responses delegation".
* `input_audio.pause` / `input_audio.resume` mute and unmute the mic server-side.

### 3.3 Tools = client delegation (VERIFIED)
There are no function tools. The voice model decides an action is needed and hands off a natural-language task:
```
<- delegation.created  item.id=item_EfsvZ...  content[0].text="Click on the center of the screen"
   (model keeps talking: "On it, checking your screen now.")
   client resolves it: probe uses Responses API gpt-6-luna with the click_screen tool -> click_screen({"x":960,"y":540})
-> {"type":"delegation.context.append","delegation_item_id":"item_EfsvZ...",
    "content":[{"type":"input_text","text":"Done. click_screen -> {\"ok\": true, ...}"}]}
<- delegation.context.appended
   model: "... Clicked the center of your screen."
```
* Small talk ("Hello, how are you?") is answered directly, without delegation.
* All three gpt-live models delegated the click and spoke the result.
* `delegation.function_call_output.create` (needs `item.type` and `item.call_id`) exists but is meant for
  Responses delegation.
* **BROKEN: server-side Responses delegation.** Session config
  `delegation: {type:"responses", responses:{model, instructions, tools, reasoning}}` is accepted. It supports
  tool types function, web_search, file_search, code_interpreter, shell, image_generation, mcp, custom, namespace,
  tool_search, programmatic_tool_calling, computer and apply_patch. But on the first user turn, every model
  tried (`gpt-6-luna`, `gpt-6.1-sol`, `gpt-5.4-mini`) gives:
  `{"code":"invalid_request_error","message":"Cannot connect to host responsesapi.openai.svc.cluster.local.:8081 ssl:default [Domain name not found]"}`
  This is an internal OpenAI DNS failure. Use client delegation.

### 3.4 Interruption (VERIFIED)
It is natively full duplex: just keep streaming the mic. In `--barge-in`, the assistant was telling a story when
"Stop" was played after 2.5 s. The assistant turn ended with transcript "All right. Settle in. There was once a",
followed by user turn "Stop", followed by "Sure. Stopping the story." Nothing needs to be truncated or cancelled.
The client must still flush its own playback buffer.

### 3.5 Saving audio
The sideband stream is continuous. An assistant turn's audio is
`stream[(turn.start_ms - first_delta.start_ms) * 48 : (turn.end_ms - first_delta.start_ms) * 48]` (bytes at
24 kHz s16). The remote WebRTC track (48 kHz Opus) carries the same audio.

---

## 4. Responses API (text) via the ChatGPT login (VERIFIED, `probe_responses.py --matrix`)

```
POST https://chatgpt.com/backend-api/codex/responses
chatgpt headers + Content-Type: application/json + Accept: text/event-stream

{"model": "gpt-6-luna",
 "instructions": "...",                      # optional (omitted or "" both work)
 "input": [{"type":"message","role":"user","content":[
     {"type":"input_image","image_url":"data:image/png;base64,..."},
     {"type":"input_text","text":"..."}]}],
 "tools": [ {function...} ], "tool_choice": "auto",     # optional
 "reasoning": {"effort": "high"},                       # optional
 "stream": true, "store": false}
```
| Check | Result |
|---|---|
| `gpt-6-luna` text | 200, "pong", TTFT about 0.95–1.2 s |
| `gpt-6.1-sol` text | 200, "pong", TTFT about 1.6 s |
| `instructions` omitted / empty | **works** (not required) |
| `store: true` | 400 `{"detail":"Store must be set to false"}` |
| `stream: false` | 400 `{"detail":"Stream must be set to true"}` |
| image input (luna and sol) | correct: "A dark blue horizontal rectangle sits near the top, with a red circle centered below it on a white background." 80 input tokens for 256x256 |
| function tool (luna) | `click_screen({"x":960,"y":540})` from "Click on the center of the screen" |
| compression prompt (luna) | "Opened `README.md`, added `buy milk` to `notes.txt`, and couldn't check the weather." |
| `gpt-6.1-sol` + `reasoning.effort: high` | "391", `reasoning_tokens: 11` |
| unknown model | 400 `model_not_found`: "The 'gpt-nope' model is not supported when using Codex with a ChatGPT account." |

SSE events: `response.created, response.in_progress, response.output_item.added, response.content_part.added,
response.output_text.delta, response.metadata, response.output_text.done, response.content_part.done,
response.output_item.done, response.completed`. Tool calls appear as
`response.function_call_arguments.delta/.done` and `output_item.done` with item type `function_call`.
* **Gotcha:** the SSE response has **no `Content-Type` header**, so don't gate on it.
* `response.completed.response.usage` has `{input_tokens, input_tokens_details{cached_tokens, cache_write_tokens},
  output_tokens, output_tokens_details{reasoning_tokens}, total_tokens, attribution{items{...}, request_fields{instructions, tools}}}`.
* Response headers include plan quota: `x-codex-plan-type`, `x-codex-primary-used-percent` (5 h window),
  `x-codex-secondary-used-percent` (7 day window), `*-window-minutes`, `*-reset-after-seconds`, `*-reset-at`.
  Do not log `x-codex-turn-state`.
* `store:false` means there is no `previous_response_id` chaining. Resend the full history (as Codex does).

---

## 5. Latency (VERIFIED; 24 kHz fixtures streamed at mic pace from this machine)

"Speech end" is the wall-clock time the last voiced 20 ms frame was sent (RMS > 400), not the end of the file.

| Path / model | connect | speech end → VAD `speech_stopped` | → tool call | → first assistant audio |
|---|---|---|---|---|
| A `gpt-realtime-1.5`, server_vad 500 ms, "Hello, how are you?" | 1.18–1.29 s | 1.13 s | – | **1.71–2.02 s** |
| A `gpt-realtime-1.5`, "Click on the center..." | 1.22–1.54 s | 1.17 s | 1.67–1.73 s | 2.56–2.71 s (after tool round trip) |
| A `gpt-realtime-2`, click | – | 1.09 s | 2.27 s (speaks first) | 1.66 s |
| A server_vad 200 ms | | 0.80 s | 1.37–1.41 s | splits "Hello, / how are you?" into 2 turns |
| A semantic_vad high | | 1.19–1.30 s | 1.6–1.9 s | 2.5–3.2 s (no gain) |
| B `gpt-live-1.1` hello | 1.93–1.95 s (call 1.15 s + sideband 0.74 s) | – | – | **1.14 s** |
| B `gpt-live-1` hello | 2.06 s | – | – | 1.11 s |
| B `gpt-live-1-codex` hello | 4.23 s (sideband 2.9 s, one run) | – | – | 0.98 s |
| B click (all three) | | | delegation.created at about +1.7 s; luna resolve 0.7–1.6 s | ack audio ("On it") 1.7–1.9 s |

Text → first audio on Path A (no VAD) is about 0.4 s after `response.create`. Responses API TTFT is about
1.0 s (luna) and 1.6 s (sol).

---

## 6. Gotchas (summary)
1. gpt-live-* works **only** via WebRTC call creation on chatgpt.com plus the `/v1/live/{call_id}` sideband.
   - `/v1/realtime` returns `invalid_model`.
   - `/v1/live?model=` returns "Voice session access denied".
   - `wss://chatgpt.com/backend-api/codex/realtime` returns HTTP 403.
2. gpt-live has no tools, no images, no token usage. Its mic audio must be RTP. An invalid session config still
   returns 201 and dies silently.
3. gpt-live server-side Responses delegation fails with an OpenAI-internal DNS error. Use `delegation.type=client`.
4. aiortc: use `RTCConfiguration(iceServers=[])`, otherwise call setup takes about 6 s longer.
5. Path A: generation outruns playback, so barge-in = stop playback + `conversation.item.truncate`
   (after the cancelled `response.done`, if any). `response.cancel` usually returns `response_cancel_not_active`.
6. Path A: pauses inside an utterance split the turn. Expect `response.done` with `status=cancelled`,
   `reason=turn_detected`.
7. Path A: the user transcript (`...input_audio_transcription.completed`) is asynchronous and can arrive after
   the tool call or the assistant audio.
8. Responses API: `stream:true` and `store:false` are mandatory; there is no Content-Type header on the SSE.
9. Never refresh tokens casually. The refresh token rotates and is shared with Codex CLI; persist it back.
10. TTS via realtime: filenames are read as "readme dot m d". The transcriber still writes `README.md`.
    In 1 of 20 attempts the model answered instead of reading ("What is on my screen right now?"), so retry
    on transcript mismatch.

## 7. Fixtures
`make_fixtures.py` builds them with `gpt-realtime-1.5`: TTS with voices marin and cedar alternating, the text
wrapped in `<read>` tags, retry on mismatch, silence trimmed, 0.25 s lead-in and 0.6 s tail added. Each wav was
then verified in a VAD-off session with `gpt-4o-mini-transcribe`, and all 10 matched (normalized similarity 1.0).
Each was also run through `gpt-realtime-1.5` with a 9-tool desktop toolset, and all 10 produced the expected
tool (`01_hello` → no tool, spoken reply).
