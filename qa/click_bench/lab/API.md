# Click accuracy lab protocol

The standalone window uses a loopback-only Python server (port 8766 by default).
Run `python qa/click_bench/lab/server.py --port 8766` after installing
`qa/click_bench/lab/requirements.txt` in a virtual environment. The existing Woi
research environment also works. No frontend dependencies or asset downloads.

## GET /api/connection and POST /api/connection

The page can select Codex login or API-key authentication without restarting the
lab. GET returns `auth_mode` (also `mode`), `configured`, `source`, `revision`,
`session_key` (a boolean), and `speed_tiers`. When credentials are missing,
`configured:false` and `reason` explain what is needed. Availability here means
credentials are present, not proof of provider acceptance.

POST accepts only `auth_mode:"codex"|"api"` and optional `api_key`. A nonempty key
is held in server process memory. Omitting `api_key` keeps the temporary key;
sending an empty string clears it and returns to the existing configured key.
No key is returned, written to Woi/Codex settings, or added to evidence logs.
Switching to Codex keeps the temporary API key available for switching back.
Restarting the server clears both runtime overrides.

The endpoint uses the same loopback, Host, Origin, and JSON protections as trials.
Changes are rejected with `connection_busy` (HTTP 409) while a trial or catalog
lookup is running. The model catalog is scoped to the connection and credential;
changing the connection never reuses another account's cached model list.

## GET /api/models

Returns `models`, `auth`, `connection`, `speed_tiers`, `source`, `warnings`, and `discovered_at`. Every model has
`id`, `name`, `kind` (`audio`, `text`, `other`), `transport`, `available`, `reason`,
`source`, `availability`, `test_status`, `reasoning_effort`, `image_detail`, and
`supports_image_detail_original` (true, false, or unknown/null). `available` means
eligible to attempt, not a claim that the current account has proven access.
`test_status` and `last_error` describe Normal-tier calls. Per-tier outcomes are returned in `tier_results`, so a rejected experimental tier does not mark the model itself unavailable. Refresh with `?refresh=1`.

The live Codex catalog is queried with the current Woi credentials. Public API
model discovery is also attempted. When that scope is unavailable, audio
candidates come from Woi's existing model registry and are labeled as such.
Every returned model is shown, including hidden catalog entries. Live audio
models are shown as unsupported for direct screenshot input; no delegated text
model is silently substituted or credited to Live.

## POST /api/trial

```json
{
  "model": "gpt-realtime-2.1",
  "instruction": "Click the Cedar button.",
  "screenshot": "data:image/png;base64,...",
  "width": 1280,
  "height": 720,
  "screen": {"width": 1920, "height": 1080, "devicePixelRatio": 1},
  "request_id": "unique-request-id",
  "speed_tier": "normal",
  "connection_revision": 0
}
```

Only these fields are allowed. `speed_tier` and `connection_revision` are
optional for existing clients. Omitted speed means Normal. A supplied revision
must match the current connection, otherwise the server returns
`connection_changed` (HTTP 409) before sending a model request. PNG dimensions
and checksums are verified.
The screenshot is the controlled target surface, not the whole operating system.
`screen.width/height` report browser Screen CSS dimensions; screenshot `width`
and `height` are authoritative for coordinates. DPR is reported, not multiplied.
No target names list, target rectangles, expected action, prior messages, or
history can be sent to this endpoint. A fresh one-message Responses request or
fresh WebSocket session with `conversation: none` and explicit one-message input
is used each time. Existing Woi credentials are only read, never refreshed here.

Successful API calls return `action: click|move`, `x`, `y`, `request_id`, `model`,
`resolved_model`, `latency_ms` (including handshake), `usage`, `error: null`, and
metadata including image hash, resolution, endpoint, reasoning, selected image
detail/policy, protocol version, and raw final function-call output. Coordinates are screenshot pixels. Invalid, non-finite,
or out-of-bounds coordinates produce an explicit error and are never clamped.
Models are required to produce exactly one `screen_action` tool call.

All model responses are parsed under the same schema. Catalog models advertising
low reasoning are tested with low effort; no tiny output-token cap can consume
the reasoning budget before the tool call. API rejection, timeout, rate limits,
unsupported image input, invalid output, and wrong coordinates remain distinct.
No coordinate correction, accessibility lookup, or real OS input occurs here.

## Speed tiers and provider evidence

All four choices remain selectable for both connection types. Responses requests
send the exact `service_tier` below, with no retry or fallback to another tier.

| UI choice | Responses `service_tier` | Behavior |
| --- | --- | --- |
| Normal | `default` | Explicit standard processing; omission would be provider Auto. |
| Fast | `priority` | Fast/Priority processing; provider may report `priority` or `fast`. |
| Ultrafast | `ultrafast` | Attempted on the selected model/account; rejection remains visible. |
| Flex | `flex` | Attempted on Codex and API alike; up to 600 seconds for slower processing. |

Normal/Fast/Ultrafast have a 120-second request deadline. `timeout_ms` records the
chosen deadline. Flex is never silently retried as Standard if unavailable.
Realtime currently has no documented service-tier field: Normal uses its normal
session without a tier field; the other choices return
`tier_unsupported_transport` visibly without sending a model request. No model or
transport substitution occurs.

Every structured result includes `speed_tier`, `requested_service_tier`,
`actual_service_tier`, `tier_status`, `tier_note`, `auth_mode`, and
`connection_revision`. `actual_service_tier` comes only from provider response
events; missing reporting stays null. `tier_status` is `reported` when confirmed
(`priority` and `fast` are accepted Fast aliases), `different` when the provider
reports another tier, `unreported` when absent, `rejected` for explicit provider
tier errors, or `unsupported` when the transport has no tier control. A successful
model response alone does not establish that a requested faster tier was used.

This change uses protocol `screenshot-only-v3-tiers`. Older v1/v2 benchmark records
retain their original implicit-tier behavior and must not be combined into a
speed comparison without labeling that difference.

## Request size and measured timeline

Timing fields are additive to `screenshot-only-v3-tiers`; the model prompt,
screenshot, speed-tier mapping, and fresh-session rules are unchanged. These
fields describe the server-to-provider request. They do not measure the browser's
upload to the local lab server, screenshot rendering, or the final local click.

`request_image_bytes` is the exact decoded PNG size and aliases existing
`image_bytes`. `request_payload_bytes` is the actual serialized UTF-8 JSON byte
count sent to the provider: it includes the base64 image and request instructions,
but excludes transport headers, WebSocket framing, and TLS overhead. For Responses
it is the one HTTP request body. For Realtime it is the sum of the
`session.update` and `response.create` message bodies. No byte count is estimated
from elapsed time. A request that never constructs a provider payload returns
`request_payload_bytes: null`.

Every structured trial response includes a `timing` object:

```json
{
  "origin": "provider_request_start",
  "upload_complete_ms": 410.125,
  "upload_duration_ms": 6.25,
  "first_token_ms": 1800.75,
  "first_output_ms": 1800.75,
  "first_output_source": "stream_delta",
  "finish_ms": 2400.5,
  "status": "completed",
  "upload_measurement": "http.client.body_send_returned",
  "note": "Client-side upload completion is not provider receipt."
}
```

These example values are illustrative. All measured milestones use the same
monotonic client clock, in milliseconds relative to the start of the actual
provider call. Request discovery and JSON encoding happen before this origin.
The UI can display `Upload +0.410 s`, `First reply +1.801 s`, and
`Finished +2.401 s`; the stages are offsets, not durations to add together.

| Field | Meaning |
| --- | --- |
| `upload_complete_ms` | Time when the client's request-body send has returned. It includes preceding connection setup; it does not establish provider receipt. |
| `upload_duration_ms` | Time spent dispatching the request body itself, separate from the upload milestone offset. For Realtime it covers only the image/prompt `response.create` send. |
| `first_token_ms` | Time when the client observes the first nonempty streamed output text or tool-argument delta. It is a received delta measurement, not the provider's internal token-generation timestamp. |
| `first_output_ms` | First observed meaningful output, whether streamed or supplied only as a completed output item. |
| `first_output_source` | `stream_delta`, `final_only`, or null when no meaningful output was observed. |
| `finish_ms` | Time of the terminal provider response, or the observed request failure. It excludes local prediction parsing and click dispatch. |
| `status` | `completed`, `error`, or `not_started`. An unsupported tier or local validation error has no provider timings. |

For Responses, a single-use iterable supplies the unchanged JSON bytes to
Python's normal `urllib` path with an explicit `Content-Length`. The upload
milestone is recorded when the real `http.client` send loop resumes after sending
that body chunk; its `socket.sendall` has returned. Existing proxy and TLS
behavior is preserved. The iterator cannot replay the body. For Realtime, the
origin is before opening the fresh WebSocket, and the upload milestone is after
`await ws.send(response.create)` returns. Its offset includes connection and
session setup. This measures client dispatch/flow control, not a provider
acknowledgement. `upload_measurement` identifies the method as
`http.client.body_send_returned` or `websocket.send_returned`; `note` explains the
scope in every started request.

Session creation, response creation/in-progress, reasoning events, audio data,
and empty output deltas never count as the first token. If the provider only
returns a final output item, `first_token_ms` stays null and `first_output_ms` is
recorded with `first_output_source: "final_only"`. The UI must label that as
**First output (final only)**. Unknown stages remain null, rather than using zero,
API latency, or the first setup event as a substitute. Errors preserve any
completed upload or output milestones; failed sends leave upload completion
unknown. A measured `finish_ms` on an error is the failure end, not a successful
response. Local pre-request errors retain `status: "not_started"` and null stages.

The existing `latency_ms` and browser `send_to_click_ms` remain separate metrics
with their original scopes. In particular, the provider `finish_ms` precedes
WebSocket teardown; API total and send-to-click time can include that teardown
and therefore exceed the provider completion offset. Timeline measurements are returned when the trial
finishes; they are not live streamed to the browser. The UI may show its own
pending elapsed clock without asserting unobserved provider stages.

## POST /api/result

Stores a client-generated scoring record with `request_id`. This is separate
from `/api/trial`; target truth and hit evidence are never passed to a model.
Its content can include actual local button click / pointer event results.

The server stores private evidence in `qa/out/click_lab/` by default: one PNG per
image hash, a `trials.jsonl` request/response log, and optional `results.jsonl`.
The JSON logs omit credentials and base64 images. Model errors are structured
trial results with `error_code`; malformed local requests have an HTTP 4xx code.

## Image detail and benchmark versions

`screenshot-only-v2` defaults to `WOI_LAB_IMAGE_DETAIL=auto`. This sends
`detail: "original"` to Responses models whose catalog explicitly advertises
`supports_image_detail_original: true`, and `detail: "high"` to Realtime and
other candidates. The PNG bytes and declared dimensions do not change.

Use `--image-detail high` (or `WOI_LAB_IMAGE_DETAIL=high`) to reproduce the
initial all-high configuration. Use `--image-detail original` to require original
mode for Responses models; an explicitly unsupported capability or Realtime
transport is rejected without fallback. When the public catalog omits capability
metadata, an explicit original override is attempted and the provider response
is recorded. Auto never assumes missing capability metadata means support.

Every trial records `image_detail`, `image_detail_policy`, and `protocol`.
The original `screenshot-only-v1` all-high screening is preserved as a separate
configuration; do not merge its hit rates with the native-detail rerun.

OpenAI's [image guide](https://developers.openai.com/api/docs/guides/images-vision)
and [computer-use integration guide](https://developers.openai.com/api/docs/guides/tools-computer-use-integration)
recommend original detail for precise coordinates when supported. High detail
can resize internally, so identical source PNG bytes alone do not establish that
the model is reasoning in the original coordinate space. Resolution diagnostics
must keep each configuration labeled rather than silently correcting points.

## Authentication and boundaries

On server start, default authentication follows Woi's `~/.local/share/woi/settings.json` selected
backend. Codex login uses `~/.codex/auth.json` read-only. API mode uses Woi's key,
`OPENAI_API_KEY`, or the existing Codex API key in that order. Explicit overrides
are `WOI_LAB_AUTH=codex|api`, `WOI_LAB_SETTINGS`, `CODEX_HOME`, and
`WOI_LAB_API_BASE` (HTTPS only). Saved secrets never enter the page or evidence logs. A key entered by the user is sent only to the loopback connection endpoint, then remains in server memory; the UI clears its entry field.

The server binds only to loopback. It validates Host, Origin, Sec-Fetch-Site,
JSON content type, request length, and request IDs; rejects cross-origin CORS
preflights; serves an explicit static-file allowlist; and limits concurrent
model requests. Use the launcher for a separate Chromium app window.

## Installed-app host and native timing

Settings → Advanced launches an app-owned Dart loopback server on an ephemeral
IPv4 loopback port. It uses the same static UI and API schema. The launcher puts
`woi_lab_token` in the URL fragment; all `/api/` requests must present the matching
`X-Woi-Lab-Token`. The host also validates Host, Origin and Fetch Metadata, bounds
JSON bodies (9 MiB for trials; 128 KiB for scored results), limits trials to three
at once, and rejects duplicate request identifiers. Browser actions remain inside
the synthetic test surface. No provider output can invoke Woi's real input tools.

The app adapter resolves the selected authentication mode once per trial and
uses the resulting credential snapshot for discovery and the provider request.
A connection revision change rejects stale trial submissions. Temporary API keys
are memory-only; switching back to Codex uses the Codex account, even when a
temporary API key is retained for a later switch. Credentials and authorization
headers are excluded from all public responses and evidence.

The provider request timer begins after payload serialization. The native HTTP
transport measures `request.flush()` returning, identified as
`dart_io.request_flush_returned`. This is a **client sink flush** boundary, not
network transmission, a TCP acknowledgement, provider receipt, or an equivalent
to Python's socket-send completion. `upload_complete_ms` and
`upload_duration_ms` describe that explicit client boundary.

Dart's `WebSocket.add` only enqueues data. The native Realtime adapter therefore
keeps `upload_complete_ms` and `upload_duration_ms` null and records the separate
`upload_enqueued_ms`, with `dart_io.websocket_add_enqueued` as its mechanism.
Every result includes the mechanism and explanatory timing note. The UI calls
these client-dispatch measurements and preserves unavailable stages as unavailable.

Only nonempty text or function-argument stream deltas establish first-token time.
Session setup, response creation, empty deltas and reasoning-only events do not.
If output arrives only as a final item, `first_output_source` is `final_only` and
`first_token_ms` remains null. All payload byte counts are the exact serialized
UTF-8 JSON sizes. No model or service-tier fallback is attempted.
